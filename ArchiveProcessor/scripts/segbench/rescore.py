"""W46.fix-seg-scorers: the field's segmentation scorers on every cached answer, and the document-count prior.

    <lab venv>/bin/python rescore.py owner                  # the five owner boxes -> seg-scorers-owner.json
    <lab venv>/bin/python rescore.py public --root DIR      # Lincoln and CREST    -> seg-scorers-public.json
    <lab venv>/bin/python rescore.py report                 # both -> segbench-results/seg-scorers.md

NO CALLS, NO MONEY. Every answer is read from its own response cache with ``allow_call=False`` (the window and
whole-folder combiners refuse a missing window rather than make it), and the process refuses any network
connection besides, so a source with a hole in its cache is reported as incomplete, never filled in.

THE SOURCES. Every method in methods.METHODS that answers without a call, and every window cache the bench has
collected: window-claude (Sonnet 5.5, w1), the Gemini window caches of method_gemini and compare_gemini, the
three window-cues routes (claude -p Sonnet and Opus, codex exec), each OpenRouter, FarmShare and Mac-local key,
and the two whole-folder Gemini variants. Window and whole-folder sources take the truth's photo labels, as
ensemble.py and options.py score them, so their figures measure boundaries; the spring runs keep their own photo
labels. The feature models are left to features_cues.py, which refits them with the new cues.

THE TEST BOXES. Stanton and RG165 are scored here only from answers already in the caches, which exist only where
a finalist was collected under ``--final``. Nothing is fitted or chosen on them here, so re-reading those answers
with more scorers does not spend the held-out set; the figures are reported apart from the development boxes.

THE DOCUMENT-COUNT PRIOR (A-segmentation test 9). A finding aid gives a document count without labels: Lincoln's
catalogue lists 72 items for the 261 canvases (the audited truth has 81 documents) and the CREST folder 22 PDFs
(truth 31). For a source with per-gap confidences, the prior keeps exactly the count's boundaries: the
``count - streams`` document gaps with the highest P(new) become boundaries and every other gap a continuation.
On the owner boxes there is no finding aid, so the prior is run with the truth's own count as an oracle, which
bounds what any count could buy.
"""
from __future__ import annotations

import json
import socket
import sys
from dataclasses import asdict
from pathlib import Path

import data

RESULTS = data.HERE.parent.parent / "segbench-results"
OWNER_JSON = RESULTS / "seg-scorers-owner.json"
PUBLIC_JSON = RESULTS / "seg-scorers-public.json"
REPORT = RESULTS / "seg-scorers.md"
CATALOGUE_COUNT = {"Lincoln": 72, "CREST": 22}   # public-segmentation.md: catalogue items, archive PDF starts


def no_network() -> None:
    def refuse(*_a, **_k):
        raise RuntimeError("rescore.py makes no calls: a cache miss reached the network")
    socket.socket.connect = refuse
    socket.create_connection = refuse


# --- the sources ----------------------------------------------------------------------------------

def sources(public: bool) -> dict:
    """name -> (predict(col) -> Prediction, family). Imports here, after CACHE_DIR is final."""
    from methods import METHODS
    import compare_gemini as CG
    import method_gemini as G
    import method_local as L
    import method_openrouter as R
    import method_whole as WH
    import method_window as W
    import method_window_cues as WC

    def window(judge, setup=None):
        def predict(col):
            if setup:
                setup()
            return W.assemble(col, W.combine(col, judge), True)
        return predict

    out = {}
    for name in ("all-new", "no-boundaries", "rule-cues-sketch", "rule-cues"):
        out[name] = (METHODS[name].predict, "baseline")
    if not public:
        for name in ("spring-baseline", "spring-v1", "spring-v2"):
            out[name] = (METHODS[name].predict, "spring 2026 Gemini (own photo labels)")
    out["window-claude"] = (window(W.judge_window), "window, subscription")
    for route in WC.ROUTES:
        out[f"window-cues-{route}"] = (window(WC.judge(route)), "window, subscription")
    for model, thinking, p_in, p_out in [CG.BASE + (G.PRICE_IN, G.PRICE_OUT)] + CG.VARIANTS:
        tag = f"{model}-{thinking}"
        out[f"window-{tag}"] = (window(G.judge_window, lambda a=(model, thinking, p_in, p_out): CG.use(*a)),
                                "window, Gemini API")
    for key in list(R.MODELS) + list(R.CHEAP):
        out[f"window-or-{key}"] = (window(R.judge(key)), "window, OpenRouter")
    for key in R.FARMSHARE:
        out[f"window-or-{key}"] = (window(R.judge(key)), "window, FarmShare")
    for key in L.MODELS:
        out[f"window-local-{key}"] = (window(L.judge(key)), "window, Mac local")
    for variant in ("whole", "c10"):
        name = "whole-gemini" if variant == "whole" else f"whole-gemini-{variant}"
        out[name] = (lambda col, v=variant: WH.assemble(col, WH.predict_gaps(col, v)), "whole folder, Gemini API")
    return out


# --- the document-count prior ---------------------------------------------------------------------

def p_new(pred) -> list[float | None]:
    out = []
    for b in pred.boundaries:
        c = b.get("confidence")
        out.append(None if c is None else (c if b["decision"] == "new" else 1 - c))
    return out


def count_prior(truth: list[str], pred, count: int) -> list[str] | None:
    """Labels with exactly ``count`` documents: the gaps beside photos stay as the prediction has them (the
    sources here take truth photos), and the most probable document-gap boundaries make up the rest."""
    from score import PHOTO
    p = p_new(pred)
    if all(x is None for x in p):
        return None
    doc_gaps = [i for i in range(len(truth) - 1) if truth[i] not in PHOTO and truth[i + 1] not in PHOTO]
    streams = sum(1 for i, t in enumerate(truth) if t not in PHOTO and (i == 0 or truth[i - 1] in PHOTO))
    keep = max(0, min(len(doc_gaps), count - streams))
    chosen = set(sorted(doc_gaps, key=lambda i: -(p[i] if p[i] is not None else 0.0))[:keep])
    labels = []
    for i, t in enumerate(truth):
        if t in PHOTO:
            labels.append(t)
        elif i == 0 or truth[i - 1] in PHOTO or (i - 1) in chosen:
            labels.append("New")
        else:
            labels.append("Cont")
    return labels


# --- scoring --------------------------------------------------------------------------------------

def truth_docs(labels: list[str]) -> int:
    return sum(1 for i, t in enumerate(labels)
               if t == "New" or (t == "Cont" and (i == 0 or labels[i - 1] in ("Box", "Folder"))))


def score_box(col, srcs: dict, priors: list[tuple[str, int]]) -> dict:
    from score import check_prediction, derived, score_labels
    out = {"pages": len(col.pages), "documents": None, "sources": {}, "incomplete": {}}
    for name, (predict, family) in srcs.items():
        try:
            pred = predict(col)
        except (RuntimeError, ValueError, KeyError, FileNotFoundError) as e:
            if "makes no calls" in str(e):
                raise
            out["incomplete"][name] = str(e)[:160]
            continue
        check_prediction(pred)
        c = score_labels(col.labels, pred.labels, col.name)
        row = {"family": family, "counts": asdict(c), "metrics": derived(c)}
        out["documents"] = c.docs
        for kind, count in priors:
            labels = count_prior(col.labels, pred, count)
            if labels is not None:
                pc = score_labels(col.labels, labels, col.name)
                row.setdefault("prior", {})[kind] = {"count": count, "counts": asdict(pc), "metrics": derived(pc)}
        out["sources"][name] = row
        m = row["metrics"]
        print(f"  {col.name:10} {name:38} exact {m['pages_in_exact_doc']:.3f}  PQ {m['pq']:.3f}  "
              f"kappa {m['kappa'] if m['kappa'] is not None else float('nan'):.3f}  MNDD {m['mndd']}", flush=True)
    return out


def owner() -> None:
    no_network()
    srcs = sources(public=False)
    result = {"boxes": {}}
    for name in data.COLLECTIONS:
        col = data.load(name)
        result["boxes"][name] = score_box(col, srcs, [("oracle", truth_docs(col.labels))])
        result["boxes"][name]["split"] = "test" if name in data.TEST else "dev"
    OWNER_JSON.write_text(json.dumps(result, indent=1) + "\n")
    print(f"wrote {OWNER_JSON}")


def public(root: Path) -> None:
    data.CACHE_DIR = root / "cache"
    no_network()
    import public_segmentation as P
    srcs = sources(public=True)
    result = {"boxes": {}}
    for box in ("lincoln", "crest"):
        col, _ = P.load(box, root)
        result["boxes"][col.name] = score_box(col, srcs, [("finding aid", CATALOGUE_COUNT[col.name]),
                                                          ("oracle", truth_docs(col.labels))])
        result["boxes"][col.name]["split"] = "public"
    PUBLIC_JSON.write_text(json.dumps(result, indent=1) + "\n")
    print(f"wrote {PUBLIC_JSON}")


# --- the report -----------------------------------------------------------------------------------

COLS = [("pages_in_exact_doc", "pages exact", "%"), ("kappa", "kappa", "f"), ("pk", "Pk", "f"),
        ("windowdiff", "WD", "f"), ("pq", "PQ", "f"), ("rq", "RQ", "f"), ("sq", "SQ", "f"),
        ("doc_f1", "doc F1", "f"), ("stp", "STP", "%"), ("mndd_per_100_pages", "MNDD/100 p", "f1")]


def _fmt(v, kind) -> str:
    if v is None:
        return "—"
    return f"{100 * v:.1f}%" if kind == "%" else f"{v:.3f}" if kind == "f" else f"{v:.1f}"


def pool(rows: list[dict]):
    from score import Counts
    total = None
    for r in rows:
        c = Counts(**{k: v for k, v in r.items() if k != "collections"})
        total = c if total is None else total + c
    return total


def pooled_rows(boxes: dict, names: list[str], prior: str | None = None) -> dict[str, dict]:
    """source -> derived metrics pooled over ``names``, for the sources complete on every one of them."""
    from score import derived
    common = set.intersection(*(set(boxes[n]["sources"]) for n in names))
    out = {}
    for s in common:
        rows = []
        for n in names:
            row = boxes[n]["sources"][s]
            if prior is not None:
                row = row.get("prior", {}).get(prior)
                if row is None:
                    break
            rows.append(row["counts"])
        else:
            out[s] = derived(pool(rows))
    return out


def table(rows: dict[str, dict], family: dict[str, str]) -> list[str]:
    head = "| source | family | " + " | ".join(c[1] for c in COLS) + " |"
    lines = [head, "|" + "---|" * (len(COLS) + 2)]
    for s, m in sorted(rows.items(), key=lambda kv: -(kv[1]["pages_in_exact_doc"] or 0)):
        lines.append(f"| {s} | {family.get(s, '')} | " + " | ".join(_fmt(m[k], f) for k, _, f in COLS) + " |")
    return lines


def ranks(values: list[float]) -> list[float]:
    order = sorted(range(len(values)), key=lambda i: values[i])
    r = [0.0] * len(values)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
            j += 1
        for k in range(i, j + 1):
            r[order[k]] = (i + j) / 2
        i = j + 1
    return r


def spearman(a: list[float], b: list[float]) -> float | None:
    if len(a) < 3:
        return None
    ra, rb = ranks(a), ranks(b)
    ma, mb = sum(ra) / len(ra), sum(rb) / len(rb)
    cov = sum((x - ma) * (y - mb) for x, y in zip(ra, rb))
    va = sum((x - ma) ** 2 for x in ra) ** 0.5
    vb = sum((y - mb) ** 2 for y in rb) ** 0.5
    return cov / (va * vb) if va and vb else None


def render(owner_res: dict, public_res: dict) -> str:
    boxes = {**owner_res["boxes"], **public_res["boxes"]}
    family = {s: r["family"] for b in boxes.values() for s, r in b["sources"].items()}
    dev, test = list(data.DEV), list(data.TEST)
    out = ["# The field's segmentation scorers on every cached answer — W46.fix-seg-scorers", "",
           "Made by `scripts/segbench/rescore.py` (owner, public, report) from the response caches, with no call and "
           "no money: a cache miss is reported as incomplete and the process refuses the network. Definitions are in "
           "`score.py`'s docstring; the figures are pooled sums over the boxes named. Window and whole-folder sources "
           "take the truth's photo labels, so their figures measure boundaries; the spring runs keep their own. "
           "Higher is better except Pk, WindowDiff and MNDD. A source appears in a table only where its cache is "
           "complete on every box of that table. On the owner boxes Pk equals WindowDiff because k, half the mean "
           "truth segment length with each label photo a segment, rounds to 1 there; on Lincoln and CREST k is 2.", ""]
    sections = [("Development boxes (Dean, Deaver, Herrnstein; 551 pages)", dev),
                ("Locked test boxes (Stanton, RG165; 363 pages), answers already cached by the finalists' --final runs",
                 test)]
    for title, names in sections:
        out += [f"## {title}", ""] + table(pooled_rows(boxes, names), family) + [""]
    for name in ("Lincoln", "CREST"):
        b = boxes[name]
        out += [f"## {name} ({b['pages']} pages, {b['documents']} documents)", ""]
        out += table({s: r["metrics"] for s, r in b["sources"].items()}, family) + [""]

    # How much of Lincoln is the metric's severity on long documents.
    out += ["## What the metric choice changes", "",
            "Pages in an exact document gives a page no credit unless its whole document is right; PQ credits a "
            "segment that overlaps its document by more than half. The gap between the two is how much of a "
            "box's score the strict metric withholds for near misses.", "",
            "| box | source | pages exact | PQ | PQ − pages exact | kappa | MNDD per 100 pages |", "|---|---|---|---|---|---|---|"]
    for name in dev + test + ["Lincoln", "CREST"]:
        for s in ("window-or-fs-seg-4b", "window-or-fs-seg-2b", "window-or-fs-qwen3.5-27b"):
            r = boxes[name]["sources"].get(s)
            if r:
                m = r["metrics"]
                out.append(f"| {name} | {s} | {_fmt(m['pages_in_exact_doc'], '%')} | {_fmt(m['pq'], 'f')} | "
                           f"{100 * (m['pq'] - m['pages_in_exact_doc']):+.1f} pts | {_fmt(m['kappa'], 'f')} | "
                           f"{_fmt(m['mndd_per_100_pages'], 'f1')} |")
    out.append("")
    devrows = pooled_rows(boxes, dev)
    keep = [s for s in devrows if family.get(s) != "baseline"]
    pe = [devrows[s]["pages_in_exact_doc"] for s in keep]
    out += [f"Rank agreement over the {len(keep)} non-baseline sources complete on the development boxes "
            "(Spearman, against pages in an exact document): "
            + ", ".join(f"{lab} {spearman(pe, [sign * devrows[s][k] for s in keep]):.3f}"
                        for k, lab, sign in (("pq", "PQ", 1), ("kappa", "kappa", 1), ("doc_f1", "doc F1", 1),
                                             ("mndd_per_100_pages", "MNDD (negated)", -1),
                                             ("windowdiff", "WindowDiff (negated)", -1)))
            + ".", ""]

    # The document-count prior.
    out += ["## The document-count prior (A-segmentation test 9)", "",
            "Each source's per-gap P(new) ranked, and exactly `count − streams` document gaps kept as boundaries. "
            "Lincoln's count is the catalogue's 72 items (truth 81) and CREST's the folder's 22 PDFs (truth 31); "
            "the oracle uses the truth's own count, which no user has, and bounds what a count can buy.", "",
            "| box | source | count | as answered: pages exact | with the prior | PQ as answered | PQ with the prior |",
            "|---|---|---|---|---|---|---|"]
    prior_sets = [(n, "finding aid") for n in ("Lincoln", "CREST")] + \
                 [(n, "oracle") for n in ("Lincoln", "CREST")]
    for name, kind in prior_sets:
        for s, r in sorted(boxes[name]["sources"].items()):
            p = r.get("prior", {}).get(kind)
            if p is None or r["family"] == "baseline":
                continue
            m, pm = r["metrics"], p["metrics"]
            out.append(f"| {name} | {s} | {p['count']} ({kind}) | {_fmt(m['pages_in_exact_doc'], '%')} | "
                       f"{_fmt(pm['pages_in_exact_doc'], '%')} | {_fmt(m['pq'], 'f')} | {_fmt(pm['pq'], 'f')} |")
    oracle_dev = pooled_rows(boxes, dev, prior="oracle")
    out += ["", "Development boxes, the oracle count (pooled):", "",
            "| source | pages exact as answered | with the oracle count | change |", "|---|---|---|---|"]
    for s in sorted(oracle_dev, key=lambda s: -(devrows[s]["pages_in_exact_doc"] or 0)):
        if family.get(s) == "baseline" or s not in devrows:
            continue
        a, b = devrows[s]["pages_in_exact_doc"], oracle_dev[s]["pages_in_exact_doc"]
        out.append(f"| {s} | {_fmt(a, '%')} | {_fmt(b, '%')} | {100 * (b - a):+.1f} pts |")
    out.append("")

    incomplete = sorted({s for b in boxes.values() for s in b["incomplete"]})
    out += ["## Sources with an incomplete cache somewhere", "",
            "Not collected on every box (each box lists only what it holds): " + ", ".join(
                f"{s} ({', '.join(n for n, b in boxes.items() if s in b['incomplete'])})" for s in incomplete) + ".", ""]
    return "\n".join(out) + "\n"


def main(argv) -> int:
    if argv[:1] == ["owner"]:
        owner()
    elif argv[:1] == ["public"] and len(argv) == 3 and argv[1] == "--root":
        public(Path(argv[2]))
    elif argv[:1] == ["report"]:
        REPORT.write_text(render(json.loads(OWNER_JSON.read_text()), json.loads(PUBLIC_JSON.read_text())))
        print(f"wrote {REPORT}")
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
