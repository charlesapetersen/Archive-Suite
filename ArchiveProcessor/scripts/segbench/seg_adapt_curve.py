"""W46.seg-adapt-curve: what a user's corrections buy, and whether doc-split-v1 is the laptop segmenter.

    <lab venv>/bin/python doc_split.py embed owner; doc_split.py embed public ROOT     # once, CPU, ~30 min
    <lab venv>/bin/python seg_adapt_curve.py owner                                     # -> seg-adapt-curve-owner.json
    SEGBENCH_CACHE=ROOT/cache <lab venv>/bin/python seg_adapt_curve.py public ROOT     # -> seg-adapt-curve-public.json
    <lab venv>/bin/python seg_adapt_curve.py report                                    # -> seg-adapt-curve.md

NO CALLS, NO MONEY. Every model answer is read from its committed cache (``rescore.no_network``); doc-split-v1 runs
from its cached page embeddings (doc_split.py). Owner and public boxes run in separate processes because the response
caches are chosen by SEGBENCH_CACHE at import.

THE SOURCES, per document gap (two adjacent document pages; a gap beside a label photo is a boundary by construction
and is never counted or reviewed): P(new) from the trained Qwen3.5 2B (FarmShare, ``window-or-fs-seg-2b``), the
Qwen3.5 27B teacher (``window-or-fs-qwen3.5-27b``), a cloud partner (Gemini 3.8 Flash low on the owner boxes; on
Lincoln and CREST, where no Gemini answer exists, Claude Sonnet 5.5 c1 from W46.seg-lincoln-cloud, labelled as such),
and doc-split-v1's CRF marginal that the page after the gap starts a document.

DOC-SPLIT-V1, ZERO-SHOT AND REFIT. Zero-shot is the card's code unchanged (decision: marginal >= 0.5). The refit has
six parameters, the head logit's scale and bias and the CRF's four transitions, fitted by the marginal likelihood of
the labelled gaps, then the beta calibration's three refit by logistic regression on the refit marginals. On the
development boxes it is fitted leave-one-box-out; for Stanton, RG165, Lincoln and CREST it is fitted on all three
development boxes. Nothing is fitted on a test box except in the learning curve, and then only on its labelled gaps.

THE LEARNING CURVE (Lincoln and Stanton headline; every box is run). k in 0, 25, 50, 100, 200 labelled gaps, drawn
two ways: at random (30 draws) and as the first k gaps of the box (a user who reviews the start of a box). For each
draw, each method is refit on the k gaps only and judged on the remaining gaps: errors per 100 held-out gaps, and
pages in an exactly right document over the whole box with the k gaps set to the truth. The "no refit" row is the
same k gaps corrected with the model unchanged, so the difference is what the corrections buy beyond themselves.
Methods: threshold-and-prior refit of the 2B and of the teacher (Platt, p' = sigmoid(a logit p + b), with a pull of
weight LAMBDA toward a = 1, b = 0, so a handful of labels moves it little); the doc-split-v1 refit above, starting from
the development-box fit and pulled toward it with the same weight. LAMBDA was set to 1 before any curve was read.

THE SELECTION RULES for the review screen. The 2B's decisions are the base (the laptop route); a rule orders the gaps,
the reviewer checks the first B (B = 10, 25, 50 per 100 pages), each checked gap takes the truth's decision. Rules:
random (mean of 50 orders); the 2B's own confidence, lowest first; the 2B against the cloud partner, against
doc-split-v1, against the teacher (disagreements first, by the 2B's confidence; then the rest by the 2B's
confidence); a Vision page-kind change across the gap (the shipped kind classifier, owner boxes only, the rest as
before); and doc-split-v1's calibrated confidence. Also the checks per 100 pages each rule needs to reach 98%.
"""
from __future__ import annotations

import json
import random
import sys
from pathlib import Path

import numpy as np

import data
import doc_split as DS
from score import PHOTO, derived, score_labels, segment_ids

RESULTS = data.HERE.parent.parent / "segbench-results"
OWNER_JSON = RESULTS / "seg-adapt-curve-owner.json"
PUBLIC_JSON = RESULTS / "seg-adapt-curve-public.json"
REPORT = RESULTS / "seg-adapt-curve.md"
KS = (0, 25, 50, 100, 200)
BUDGETS = (10, 25, 50)
DRAWS, RANDOM_ORDERS, LAMBDA, BAR, MIN_HELD = 30, 50, 1.0, 0.98, 20
EPS = 1e-4


# --- one box -------------------------------------------------------------------------------------

class Box:
    def __init__(self, col, src: dict[str, dict[int, float]], kinds: dict[int, str] | None = None):
        self.name, self.labels, self.pages = col.name, col.labels, len(col.labels)
        self.gaps = [i for i in range(self.pages - 1) if self.labels[i] not in PHOTO and self.labels[i + 1] not in PHOTO]
        ids = segment_ids(self.labels)
        self.truth = {i: ids[i] != ids[i + 1] for i in self.gaps}          # True = new document
        self.src = src
        self.kinds = kinds

    def pred_labels(self, new: dict[int, bool]) -> list[str]:
        out = []
        for i, t in enumerate(self.labels):
            if t in PHOTO:
                out.append(t)
            elif i == 0 or self.labels[i - 1] in PHOTO or new[i - 1]:
                out.append("New")
            else:
                out.append("Cont")
        return out

    def score(self, new: dict[int, bool]) -> dict:
        c = score_labels(self.labels, self.pred_labels(new), self.name)
        m = derived(c)
        return {"exact": m["pages_in_exact_doc"], "fs": c.false_splits, "fm": c.false_merges, "tp": c.tp,
                "bounds": c.truth_bounds, "pq": m["pq"], "kappa": m.get("kappa")}

    def exact(self, new) -> float:
        return derived(score_labels(self.labels, self.pred_labels(new), self.name))["pages_in_exact_doc"]


def decide(p: dict[int, float]) -> dict[int, bool]:
    return {i: v >= 0.5 for i, v in p.items()}


def corrected(box: Box, new: dict[int, bool], checked) -> dict[int, bool]:
    out = dict(new)
    for i in checked:
        out[i] = box.truth[i]
    return out


def to_bar(box: Box, new: dict[int, bool], order: list[int]) -> float | None:
    """Checks per 100 pages, taking gaps in `order`, until BAR of pages sit in an exact document."""
    cur = dict(new)
    for k in range(len(order) + 1):
        if box.exact(cur) >= BAR:
            return 100 * k / box.pages
        if k < len(order):
            cur[order[k]] = box.truth[order[k]]
    return None


# --- doc-split-v1 --------------------------------------------------------------------------------

HEAD = None


def ds_logits(name: str, labels) -> np.ndarray:
    global HEAD
    HEAD = HEAD or DS.Head()
    return HEAD.logits(DS.load_emb(name), labels)


CARD = None


def card_params() -> dict:
    global CARD
    if CARD is None:
        crf = json.loads((DS.model_dir() / "crf.json").read_text())
        CARD = {"scale": 1.0, "bias": 0.0, "trans": crf["trans"], "start": crf["start"], "end": crf["end"],
                "beta": list(DS.BETA)}
    return CARD


def ds_marg(bl: np.ndarray, labels, prm: dict) -> np.ndarray:
    """P(page starts a document) per page index (nan on photos), stream by stream."""
    crf = {"trans": prm["trans"], "start": prm["start"], "end": prm["end"]}
    out = np.full(len(labels), np.nan)
    for run in DS.streams(labels):
        out[run] = DS.marginals(bl[run], crf, prm["scale"], prm["bias"])
    return out


def ds_gap_p(bl, labels, gaps, prm, calibrated: bool) -> dict[int, float]:
    m = ds_marg(bl, labels, prm)
    p = {i: float(m[i + 1]) for i in gaps}
    if calibrated:
        cal = DS.beta_cal(np.array(list(p.values())), prm["beta"])
        p = dict(zip(p.keys(), map(float, cal)))
    return p


def _vec(prm):
    return np.array([prm["scale"], prm["bias"], *np.asarray(prm["trans"]).ravel()])


def _prm(x, base):
    return {**base, "scale": float(x[0]), "bias": float(x[1]), "trans": [[x[2], x[3]], [x[4], x[5]]]}


def fit_ds(items, base: dict, lam: float | None) -> dict:
    """items: [(logits, labels, {gap: truth})]. Marginal likelihood of the labelled gaps; pull lam toward base."""
    from scipy.optimize import minimize
    x0 = _vec(base)

    def nll(x):
        prm, tot = _prm(x, base), 0.0
        for bl, labels, lab in items:
            m = ds_marg(bl, labels, prm)
            for i, y in lab.items():
                q = min(max(m[i + 1], EPS), 1 - EPS)
                tot -= np.log(q if y else 1 - q)
        return tot + (lam * float(((x - x0) ** 2).sum()) if lam else 0.0)
    x = minimize(nll, x0, method="L-BFGS-B").x
    prm = _prm(x, base)
    # Beta calibration on the refit marginals (logistic on ln p, ln(1-p)).
    ps, ys = [], []
    for bl, labels, lab in items:
        m = ds_marg(bl, labels, prm)
        ps += [m[i + 1] for i in lab]
        ys += list(lab.values())
    prm["beta"] = fit_beta(np.array(ps), np.array(ys, float), base["beta"], lam)
    return prm


def fit_beta(p, y, base, lam):
    from scipy.optimize import minimize
    p = np.clip(p, 1e-6, 1 - 1e-6)
    X = np.stack([np.log(p), np.log(1 - p), np.ones_like(p)], 1)
    b0 = np.asarray(base, float)

    def nll(w):
        z = X @ w
        return float(np.sum(np.logaddexp(0, z) - y * z)) + (lam * float(((w - b0) ** 2).sum()) if lam else 1e-3 * float((w ** 2).sum()))
    return [float(v) for v in minimize(nll, b0, method="L-BFGS-B").x]


# --- Platt (threshold and prior) refit -----------------------------------------------------------

def _logit(p):
    p = min(max(p, EPS), 1 - EPS)
    return float(np.log(p / (1 - p)))


def platt(p: dict[int, float], lab: dict[int, bool]) -> dict[int, float]:
    if not lab:
        return dict(p)
    from scipy.optimize import minimize
    x = np.array([_logit(p[i]) for i in lab])
    y = np.array([float(v) for v in lab.values()])

    def nll(w):
        z = w[0] * x + w[1]
        return float(np.sum(np.logaddexp(0, z) - y * z)) + LAMBDA * ((w[0] - 1) ** 2 + w[1] ** 2)
    a, b = minimize(nll, np.array([1.0, 0.0]), method="L-BFGS-B").x
    return {i: float(1 / (1 + np.exp(-(a * _logit(v) + b)))) for i, v in p.items()}


# --- the analyses --------------------------------------------------------------------------------

def zero_shot(box: Box, ds_rows: dict[str, dict[int, float]]) -> dict:
    out = {}
    for name, p in {**box.src, **ds_rows}.items():
        new = decide(p)
        order = sorted(box.gaps, key=lambda i: abs(p[i] - 0.5))
        out[name] = {**box.score(new), "to98": to_bar(box, new, order)}
    return out


def rule_orders(box: Box, ds_p: dict[int, float]) -> dict[str, list[int] | None]:
    b = box.src["2B"]
    conf = lambda i: abs(b[i] - 0.5)  # noqa: E731
    by_conf = sorted(box.gaps, key=conf)

    def disagree(q):
        if q is None:
            return None
        d = [i for i in by_conf if (b[i] >= .5) != (q[i] >= .5)]
        return d + [i for i in by_conf if i not in set(d)]
    out = {"2B confidence": by_conf, "2B vs cloud partner": disagree(box.src.get("cloud")),
           "2B vs doc-split-v1": disagree(ds_p), "2B vs teacher": disagree(box.src.get("teacher")),
           "doc-split-v1 confidence": sorted(box.gaps, key=lambda i: abs(ds_p[i] - 0.5))}
    if box.kinds:
        ch = [i for i in by_conf if box.kinds.get(i) is not None and box.kinds.get(i + 1) is not None
              and box.kinds[i] != box.kinds[i + 1]]
        out["Vision kind change"] = ch + [i for i in by_conf if i not in set(ch)]
    else:
        out["Vision kind change"] = None
    return out


def selection(box: Box, ds_p: dict[int, float]) -> dict:
    new = decide(box.src["2B"])
    res = {"base": box.score(new)["exact"], "gaps": len(box.gaps), "rules": {}}
    orders = rule_orders(box, ds_p)
    rng = random.Random(7)
    rand = [rng.sample(box.gaps, len(box.gaps)) for _ in range(RANDOM_ORDERS)]
    for name, order in [("random", None), *orders.items()]:
        if name != "random" and order is None:
            res["rules"][name] = None
            continue
        row = {}
        for bud in BUDGETS:
            k = min(len(box.gaps), round(bud * box.pages / 100))
            if order is None:
                row[str(bud)] = float(np.mean([box.exact(corrected(box, new, o[:k])) for o in rand]))
            else:
                row[str(bud)] = box.exact(corrected(box, new, order[:k]))
        if order is None:
            t = [to_bar(box, new, o) for o in rand[:10]]
            row["to98"] = float(np.mean([x for x in t if x is not None])) if all(x is not None for x in t) else None
        else:
            row["to98"] = to_bar(box, new, order)
        if name == "2B vs cloud partner" or name.startswith("2B vs"):
            q = {"2B vs cloud partner": box.src.get("cloud"), "2B vs doc-split-v1": ds_p,
                 "2B vs teacher": box.src.get("teacher")}[name]
            row["disagreements_per_100p"] = 100 * sum((box.src["2B"][i] >= .5) != (q[i] >= .5) for i in box.gaps) / box.pages
        res["rules"][name] = row
    return res


def curve(box: Box, bl, ds_base: dict) -> dict:
    out = {"gaps": len(box.gaps), "ks": {}}
    rng = random.Random(11)
    for k in KS:
        if len(box.gaps) - k < MIN_HELD:
            continue
        draws = [("random", rng.sample(box.gaps, k)) for _ in range(DRAWS if k else 1)] + \
                ([("first", box.gaps[:k])] if k else [])
        rows = {}
        for kind, lab_idx in draws:
            lab = {i: box.truth[i] for i in lab_idx}
            held = [i for i in box.gaps if i not in lab]
            ms = {"2B, no refit": box.src["2B"], "2B, threshold-and-prior refit": platt(box.src["2B"], lab)}
            if "teacher" in box.src:
                ms["teacher, no refit"] = box.src["teacher"]
                ms["teacher, threshold-and-prior refit"] = platt(box.src["teacher"], lab)
            ms["doc-split-v1, dev refit"] = ds_gap_p(bl, box.labels, box.gaps, ds_base, True)
            if lab:
                prm = fit_ds([(bl, box.labels, lab)], ds_base, LAMBDA)
                ms["doc-split-v1, refit on the box"] = ds_gap_p(bl, box.labels, box.gaps, prm, True)
            else:
                ms["doc-split-v1, refit on the box"] = ms["doc-split-v1, dev refit"]
            for name, p in ms.items():
                new = decide(p)
                err = sum(new[i] != box.truth[i] for i in held)
                rows.setdefault(kind, {}).setdefault(name, []).append(
                    (100 * err / len(held), box.exact(corrected(box, new, lab_idx))))
        summ = {}
        for kind, by in rows.items():
            summ[kind] = {n: {"err_per_100_held": float(np.mean([e for e, _ in v])),
                              "exact": float(np.mean([x for _, x in v])),
                              "exact_p10": float(np.percentile([x for _, x in v], 10)),
                              "exact_p90": float(np.percentile([x for _, x in v], 90))} for n, v in by.items()}
        out["ks"][str(k)] = summ
        print(f"  {box.name} k={k} done", flush=True)
    return out


def window_p(key: str, col) -> dict[int, float]:
    import method_window as W
    if key == "gemini":
        import compare_gemini as CG
        import method_gemini as G
        CG.use("gemini-3.8-flash", "low", 0.75, 3.75)
        judge = G.judge_window
    elif key.startswith("window-cues-"):
        import method_window_cues as WC
        judge = WC.judge(key.removeprefix("window-cues-"))
    else:
        import method_openrouter as R
        judge = R.judge(key)
    comb = W.combine(col, judge)
    return {i: float(g["p_new"]) for i, g in enumerate(comb["gaps"])}


def owner_kinds(col) -> dict[int, str]:
    import kind_churn as K
    sig, fp = K.measure([col])
    return {i: K.classify(sig[f"{col.name}:{p.n}"], fp[f"{col.name}:{p.n}"])[0]
            for i, p in enumerate(col.pages) if col.labels[i] not in PHOTO}


def run_box(col, cloud_key: str, cloud_name: str, kinds, ds_base: dict, loco_base: dict | None) -> dict:
    src = {"2B": window_p("fs-seg-2b", col), "teacher": window_p("fs-qwen3.5-27b", col)}
    try:
        src["cloud"] = window_p(cloud_key, col)
    except RuntimeError as e:
        print(f"  {col.name}: no {cloud_name}: {e}")
    box = Box(col, src, kinds)
    for k in list(src):
        src[k] = {i: src[k][i] for i in box.gaps}
    bl = ds_logits(col.name, col.labels)
    base = loco_base or ds_base
    ds_rows = {"doc-split-v1, zero-shot": ds_gap_p(bl, col.labels, box.gaps, card_params(), False),
               "doc-split-v1, dev refit": ds_gap_p(bl, col.labels, box.gaps, base, True)}
    print(f"{col.name}: {len(box.gaps)} gaps", flush=True)
    return {"pages": box.pages, "gaps": len(box.gaps), "cloud": cloud_name if "cloud" in src else None,
            "zero_shot": zero_shot(box, ds_rows),
            "selection": selection(box, ds_rows["doc-split-v1, dev refit"]),
            "curve": curve(box, bl, base)}


def dev_items(names):
    items = []
    for n in names:
        col = data.load(n, with_exif=False)
        b = Box(col, {})
        items.append((ds_logits(n, col.labels), col.labels, b.truth))
    return items


def owner() -> None:
    import rescore
    rescore.no_network()
    base = card_params()
    dev = fit_ds(dev_items(data.DEV), base, None)
    loco = {n: fit_ds(dev_items([m for m in data.DEV if m != n]), base, None) for n in data.DEV}
    result = {"dev_fit": dev, "loco_fit": loco, "boxes": {}}
    for name in data.COLLECTIONS:
        col = data.load(name, with_exif=False)
        result["boxes"][name] = run_box(col, "gemini", "Gemini 3.8 Flash low", owner_kinds(col), dev,
                                        loco.get(name))
        result["boxes"][name]["split"] = "test" if name in data.TEST else "dev"
    OWNER_JSON.write_text(json.dumps(result, indent=1) + "\n")
    print(f"wrote {OWNER_JSON}")


def public(root: Path) -> None:
    if data.CACHE_DIR.resolve() != root.resolve() / "cache":
        raise SystemExit(f"set SEGBENCH_CACHE={root / 'cache'}")
    import rescore
    import public_segmentation as P
    rescore.no_network()
    dev = json.loads(OWNER_JSON.read_text())["dev_fit"]
    result = {"boxes": {}}
    for box in ("lincoln", "crest"):
        col, _ = P.load(box, root)
        result["boxes"][col.name] = run_box(col, "window-cues-claude", "Claude Sonnet 5.5 c1", None, dev, None)
    PUBLIC_JSON.write_text(json.dumps(result, indent=1) + "\n")
    print(f"wrote {PUBLIC_JSON}")


# --- the report ----------------------------------------------------------------------------------

def _p(x):
    return "—" if x is None else f"{100 * x:.1f}%"


def _n(x, nd=1):
    return "—" if x is None else f"{x:.{nd}f}"


ZNAMES = {"2B": "trained Qwen3.5 2B (FarmShare)", "teacher": "Qwen3.5 27B teacher", "cloud": "cloud partner"}


def render(boxes: dict, dev_fit: dict, notes: str) -> str:
    L = ["# What a user's corrections buy; doc-split-v1 as the laptop segmenter (W46.seg-adapt-curve)", "",
         "Generated by `scripts/segbench/seg_adapt_curve.py` (method in its docstring) from cached answers and "
         "doc-split-v1's cached page embeddings (`doc_split.py`, onnxruntime on the Mac CPU). No calls, no money. "
         "Document gaps only; a gap beside a label photo is a boundary by construction.", "", notes.strip(), "",
         "## doc-split-v1 zero-shot and refit, beside the window models", "",
         "Checks to 98%: the least-confident gaps checked first, per 100 pages. The cloud partner is Gemini 3.8 Flash "
         "low on the owner boxes and Claude Sonnet 5.5 c1 on Lincoln and CREST (no Gemini answer exists there).", "",
         "| box | source | pages exact | false splits | false merges | boundaries found | PQ | checks per 100 p to 98% |",
         "|---|---|---|---|---|---|---|---|"]
    for bx, b in boxes.items():
        for name, r in b["zero_shot"].items():
            nm = ZNAMES.get(name, name) if name != "cloud" else (b["cloud"] or "cloud")
            L.append(f"| {bx} | {nm} | {_p(r['exact'])} | {r['fs']} | {r['fm']} | {r['tp']}/{r['bounds']} | "
                     f"{_n(r['pq'], 3)} | {_n(r['to98'])} |")
    L += ["", f"The development fit (all three dev boxes): scale {dev_fit['scale']:.2f}, bias {dev_fit['bias']:.2f}, "
          f"beta ({', '.join(f'{v:.2f}' for v in dev_fit['beta'])}); the dev boxes' own rows are leave-one-box-out.", "",
          "## The learning curve: k labelled gaps", "",
          "Mean over 30 random draws of k labelled gaps (10th-90th percentile of pages exact in brackets), and the first "
          "k gaps of the box. Errors are per 100 held-out gaps; pages exact is the whole box with the k gaps set to the "
          "truth.", ""]
    for bx in ("Lincoln", "Stanton", *[k for k in boxes if k not in ("Lincoln", "Stanton")]):
        if bx not in boxes:
            continue
        c = boxes[bx]["curve"]
        L += [f"### {bx} ({c['gaps']} gaps)", "", "| method | " + " | ".join(f"k={k}" for k in c["ks"]) + " |",
              "|---|" + "---|" * len(c["ks"])]
        names = list(c["ks"]["0"]["random"])
        for kind in ("random", "first"):
            for n in names:
                cells = []
                for k, s in c["ks"].items():
                    r = s.get(kind, s["random"] if k == "0" else {}).get(n)
                    if r is None:
                        cells.append("—")
                    elif kind == "random" and k != "0":
                        cells.append(f"{_n(r['err_per_100_held'])} err · {_p(r['exact'])} "
                                     f"[{_p(r['exact_p10'])}-{_p(r['exact_p90'])}]")
                    else:
                        cells.append(f"{_n(r['err_per_100_held'])} err · {_p(r['exact'])}")
                L.append(f"| {n}{' (first k)' if kind == 'first' else ''} | " + " | ".join(cells) + " |")
        L.append("")
    L += ["## Selection rules for the review screen (the 2B's decisions corrected)", "",
          "Pages exact after B checks per 100 pages, and the checks per 100 pages each order needs for 98%.", "",
          "| box | 2B unchecked | rule | B=10 | B=25 | B=50 | to 98% | disagreements per 100 p |",
          "|---|---|---|---|---|---|---|---|"]
    for bx, b in boxes.items():
        s = b["selection"]
        for name, r in s["rules"].items():
            if r is None:
                L.append(f"| {bx} | {_p(s['base'])} | {name} | not available | | | | |")
                continue
            L.append(f"| {bx} | {_p(s['base'])} | {name} | {_p(r['10'])} | {_p(r['25'])} | {_p(r['50'])} | "
                     f"{_n(r['to98'])} | {_n(r.get('disagreements_per_100p'))} |")
    return "\n".join(L) + "\n"


def main(argv) -> int:
    if argv == ["owner"]:
        owner()
    elif argv[:1] == ["public"] and len(argv) == 2:
        public(Path(argv[1]))
    elif argv[:1] == ["report"]:
        o, p = json.loads(OWNER_JSON.read_text()), json.loads(PUBLIC_JSON.read_text())
        notes = Path(argv[1]).read_text() if len(argv) > 1 else ""
        REPORT.write_text(render({**o["boxes"], **p["boxes"]}, o["dev_fit"], notes))
        print(f"wrote {REPORT}")
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
