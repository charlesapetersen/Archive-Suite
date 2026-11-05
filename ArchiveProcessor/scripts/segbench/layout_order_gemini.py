#!/usr/bin/env python3
"""W46.layout-order-paid: Gemini asked for its text blocks in reading order, scored as one more detector with a
native order beside the free arms of W46.layout-order and W46.layout-order-marks.

    python3 layout_order_gemini.py run [bench|l9|owner|all]   # the gateway calls (cached; ledger and cap below)
    python3 layout_order_gemini.py rerun all                  # the same calls again, for the rerun floor
    uv run --offline --with rapidfuzz --with numpy --with scikit-learn --with pillow python layout_order_gemini.py score
    uv run --offline --with rapidfuzz --with numpy --with scikit-learn --with pillow python -m unittest test_layout_order_gemini

Three page sets, each scored exactly as its free arms were, so the rows compare:

* ``bench`` — the 40 scored pages of the historical reading-order benchmark. Each truth body line takes its Gemini
  block's place (``layout_order.bench_regions_panel``'s rule); tau with the guard, order-induced word error.
* ``l9`` — NewsBench's 15 newspaper pages. The same Vision lines inside DocLayout-YOLO's body regions that every L9
  arm orders; lines Gemini's blocks miss go last, top to bottom, as for PP-DocLayoutV3's native arm.
* ``owner`` — the owner's 96 truth pages. Vision's lines at the app's settings; the arm keeps the lines inside
  Gemini's blocks and orders them (``layout_order_marks.page_arms``).

Each set runs Gemini's own order (``gemini/native``) and the geometric orderers on Gemini's blocks, and is paired
against the free arms' cached per-page figures with a page-bootstrap interval.

Money: Gemini 3.7 Flash through the Stanford AI API gateway (``gateway_gemini``), real money on the PTA. This item's
ledger is CACHE/calls.jsonl and CAP its whole; every call checks the cap first. Images and replies stay in CACHE;
the repo gets ``segbench-results/layout-order-paid.json`` (boxes' scores, no text).
"""
from __future__ import annotations

import json
import re
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import gateway_gemini as G  # noqa: E402
import layout_order as LO  # noqa: E402
import layout_order_marks as LOM  # noqa: E402

CACHE = G.REHEARSAL / "layout-order-gemini"
CAP = 3.00            # the item's total; under the $7 rule
MAX_TOKENS = 16384    # a newspaper page can hold 100+ blocks, and 3.7 reasons first
NEWS_IMAGES = LO.CACHE / "bench-corpus/pages/newsbench"
OUT = HERE.parent.parent / "segbench-results/layout-order-paid.json"
LABELS = ["heading", "paragraph", "list", "table", "caption", "handwriting", "marginalia", "header", "footer",
          "page_number", "figure"]
PROMPT = (
    "This is a scanned archival page. List its blocks of text (each paragraph, heading, list, table, caption, "
    "handwritten note or marginal annotation, plus running headers, footers and page numbers) in the order a person "
    "would read the page. Give one box per block; a box never spans two columns. Return JSON only, first block read "
    'first: {"blocks": [{"label": one of ' + json.dumps(LABELS) + ', '
    '"box_2d": [ymin, xmin, ymax, xmax] on a 0-1000 scale of the image}]}. No transcription.')
PAIR_WITH = {"bench": ["app_regions", "pp_native"],
             "l9": ["app_regions", "pp_native", "hdbscan"],
             "owner": [LOM.DEFAULT, "pp/native", "none/vision_lines", "none/app_columns"]}


def _own_ledger():
    G.CACHE, G.CAP, G.MAX_TOKENS = CACHE, CAP, MAX_TOKENS


# ---------------------------------------------------------------- pages and calls

def jobs(which: str) -> list[tuple[str, Path]]:
    out = []
    if which in ("bench", "all"):
        out += [(f"bench/{p}", LO.HROB / "bench" / f"{p}.jpg") for p, _, _ in LO.bench_pages()]
    if which in ("l9", "all"):
        out += [(f"l9/{k}", NEWS_IMAGES / f"{k.split('__', 1)[1]}.jpg") for k in l9_keys()]
    if which in ("owner", "all"):
        out += [(f"owner/{p['id']}", Path(p["image"])) for p in LOM.owner_pages()]
    return out


def l9_keys() -> list[str]:
    return sorted(p.stem for p in (LO.WORK / "vision").glob("newsbench__*.json"))


REPLIES = "replies"   # "replies-rerun" for the second, identical pass that gives the rerun floor


def reply_path(job: str) -> Path:
    return CACHE / REPLIES / f"{job}.json"


def run(which="all", limit=None) -> int:
    from concurrent.futures import ThreadPoolExecutor
    _own_ledger()
    todo = jobs(which)[:limit]
    for _, img in todo:
        assert img.suffix == ".jpg" and img.exists(), img
    with ThreadPoolExecutor(4) as ex:
        set_name = "layout-order" + ("-rerun" if REPLIES != "replies" else "")
        if REPLIES != "replies":
            # The gateway (LiteLLM) answers a byte-identical request from its response cache: a first rerun came
            # back in 0.9 s a page with the first pass's exact replies (kept aside as replies-rerun-gateway-cached).
            # This body field skips that cache; the request Google sees is unchanged (ocr_rerun_noise.py's fix).
            body = G.body
            G.body = lambda image, prompt: {**body(image, prompt), "cache": {"no-cache": True}}
        list(ex.map(lambda j: G.call(set_name, j[0], j[1].read_bytes(), PROMPT, reply_path(j[0])), todo))
    bad = [j for j, _ in todo if blocks(load(j)) is None]
    print(f"{len(todo) - len(bad)}/{len(todo)} parsed; unparsed: {bad}; ${G.spent():.4f} of ${CAP} spent "
          f"({G.billed_note(G.ledger())})")
    return 0


def load(job: str):
    f = reply_path(job)
    return json.loads(f.read_text()) if f.exists() else None


_OBJ = re.compile(r"\{[^{}]*")
_NUM = r"\s*(-?\d+(?:\.\d+)?)\s*"
_BOX = re.compile(r'"box(?:_2d?)?"\s*:\s*\[' + ",".join([_NUM] * 4))
_LABEL = re.compile(r'"label"\s*:\s*"([^"]*)"')


def blocks(reply) -> list[dict] | None:
    """Gemini's blocks in its order as 0-1 [x0, y0, x1, y1] boxes, or None when the reply holds no box.

    Read object by object rather than as one JSON document: 3.7 returns the list bare as often as under
    "blocks", and now and then breaks the JSON itself (a stray key, a brace for a bracket, "box_2" or
    "box" for "box_2d") while every block in it is still whole. A block whose box is not four numbers is dropped."""
    raw = (reply or {}).get("raw")
    if not raw:
        return None
    out = []
    for m in _OBJ.finditer(raw):
        b = _BOX.search(m.group(0))
        if not b:
            continue
        lab = _LABEL.search(m.group(0))
        y0, x0, y1, x1 = (min(max(float(v) / 1000, 0.0), 1.0) for v in b.groups())
        x0, x1, y0, y1 = min(x0, x1), max(x0, x1), min(y0, y1), max(y0, y1)
        if x1 > x0 and y1 > y0:
            out.append({"order": len(out), "label": lab.group(1) if lab else "", "box": [x0, y0, x1, y1]})
    return out or None


def strict_json(reply) -> bool:
    """Whether the reply, fences aside, is valid JSON (reported; ``blocks`` does not need it)."""
    raw = re.sub(r"^```(?:json)?\s*|\s*```\s*$", "", ((reply or {}).get("raw") or "").strip())
    try:
        json.loads(raw)
        return True
    except json.JSONDecodeError:
        return False


def scaled(regs: list[dict], w: float, h: float) -> list[dict]:
    return [{**r, "box": [r["box"][0] * w, r["box"][1] * h, r["box"][2] * w, r["box"][3] * h]} for r in regs]


def region_orders(regs: list[dict], w: float) -> dict[str, list[int]]:
    boxes = [r["box"] for r in regs]
    out = {"native": list(range(len(regs)))}
    out.update({k: f(boxes, width=w) for k, f in LO.ORDERERS.items()})
    return out


# ---------------------------------------------------------------- panels

def bench_panel() -> list[dict]:
    rows = []
    for page, lang, xml in LO.bench_pages():
        gt = [g for g in LO.load_gt(xml) if g["body"] and g["text"]]
        boxes, texts = [g["box"] for g in gt], [g["text"] for g in gt]
        w, h = LO.page_size(xml)
        regs = scaled(blocks(load(f"bench/{page}")) or [], w, h)
        owner = LO.assign(boxes, [r["box"] for r in regs])
        for name, ro in region_orders(regs, w).items():
            rows.append({"page": page, "lang": lang, "arm": f"gemini/{name}", "regions": len(regs),
                         **LO.order_score(LO.region_rank(boxes, owner, ro), texts, len(gt))})
    return rows


def l9_panel() -> list[dict]:
    rows = []
    for key in l9_keys():
        v = json.loads((LO.WORK / "vision" / f"{key}.json").read_text())
        w, h = v["width"], v["height"]
        lines = [[l["box"][0] * w, l["box"][1] * h, l["box"][2] * w, l["box"][3] * h] for l in v["lines"]]
        texts = [l["text"] for l in v["lines"]]
        yown = LO.assign(lines, [r["box"] for r in LO.read_regions("yolo", key, LO.YOLO_BODY)])
        keep = [i for i in range(len(lines)) if yown[i] is not None]
        lines, texts = [lines[i] for i in keep], [texts[i] for i in keep]
        n = len(lines)
        regs = scaled(blocks(load(f"l9/{key}")) or [], w, h)
        gown = LO.assign(lines, [r["box"] for r in regs])
        truth = (LO.NEWSBENCH_TXT / f"{key.split('__', 1)[1]}.txt").read_text()
        pos = LO.truth_positions(texts, truth)
        ref = LO.words(truth)
        own = {i for i in range(n) if gown[i] is not None}
        for name, ro in region_orders(regs, w).items():
            rank = LO.region_rank(lines, gown, ro)
            order = sorted(range(n), key=lambda i: rank.get(i, (len(regs), LO._cy(lines[i]), LO._cx(lines[i]))))
            rows.append(l9_row(key, f"gemini/{name}", order, texts, pos, ref, truth, own, n, len(regs)))
    return rows


def l9_row(key, arm, order, texts, pos, ref, truth, own, n, nregs) -> dict:
    import ocr_scorers
    hyp_text = "\n".join(texts[i] for i in order)
    hyp = LO.words(hyp_text)
    seq = [pos[i] for i in order if i in pos]
    oseq = [pos[i] for i in order if i in pos and i in own]
    acc = 1 - LO.wer(ref, hyp)
    bow = LO.bow_f1(ref, hyp)
    roe = ocr_scorers.reading_order_edit(truth, hyp_text)
    return {"page": key, "arm": arm, "lines": n, "regions": nregs, "placed": len(seq),
            "covered": round(len(own) / n, 4) if n else 0.0,
            "tau_own": round(LO.kendall(oseq), 4) if len(oseq) >= LO.MIN_N else None,
            "valid": len(seq) >= LO.MIN_N, "tau": round(LO.kendall(seq), 4), "word_acc": round(acc, 4),
            "bow_f1": round(bow, 4), "gap": round(bow - acc, 4),
            "roe": None if roe is None or roe.get("edit") is None else round(roe["edit"], 4)}


def owner_panel() -> list[dict]:
    import ocr_scorers
    rows = []
    for p in LOM.owner_pages():
        lines, texts, w, h = LOM.vision_lines(p["id"])
        regs = scaled(blocks(load(f"owner/{p['id']}")) or [], w, h)
        owner = LO.assign(lines, [r["box"] for r in regs])
        kept = [i for i in range(len(lines)) if owner[i] is not None]
        truth = (LOM.TRUTH / f"{p['id']}.txt").read_text()
        pos = LO.truth_positions(texts, truth)
        ref = LO.words(truth)
        for name, ro in region_orders(regs, w).items():
            rank = LO.region_rank(lines, owner, ro)
            order = sorted(kept, key=lambda i: rank[i])
            hyp_text = "\n".join(texts[i] for i in order)
            hyp = LO.words(hyp_text)
            seq = [pos[i] for i in order if i in pos]
            acc = 1 - LO.wer(ref, hyp)
            bow = LO.bow_f1(ref, hyp)
            roe = ocr_scorers.reading_order_edit(truth, hyp_text)
            rows.append({"page": p["id"], "groups": [g for g in p["groups"] if g != "the 96"], "arm": f"gemini/{name}",
                         "lines": len(lines), "kept": len(kept), "regions": len(regs), "placed": len(seq),
                         "valid": len(seq) >= LO.MIN_N, "tau": round(LO.kendall(seq), 4),
                         "word_acc": round(acc, 4), "bow_f1": round(bow, 4), "gap": round(bow - acc, 4),
                         "roe": None if roe is None or roe.get("edit") is None else round(roe["edit"], 4)})
    return rows


# ---------------------------------------------------------------- summaries

def paired(rows, base_rows, arm, base_arm, key="tau", groups=None) -> dict | None:
    """Arm minus base over the pages both score validly; a tie when the interval holds zero."""
    base = {r["page"]: r for r in base_rows if r["arm"] == base_arm and r.get("valid")}
    d = [r[key] - base[r["page"]][key] for r in rows if r["arm"] == arm and r.get("valid") and r["page"] in base
         and (groups is None or r.get("lang") in groups)]
    if not d:
        return None
    return {"pages": len(d), "diff": round(statistics.mean(d), 4), "ci": LOM.boot_mean(d)}


def summary_cell(sel: list[dict]) -> dict:
    valid = [r for r in sel if r.get("valid")]
    cell = {"pages": len(sel), "valid": len(valid),
            "regions": round(statistics.mean(r["regions"] for r in sel), 1) if sel else None}
    if valid:
        taus = [r["tau"] for r in valid]
        cell.update(tau=round(statistics.mean(taus), 4), tau_ci=LOM.boot_mean(taus),
                    pages_tau_ge_095=sum(t >= 0.95 for t in taus))
        if "oiwer" in valid[0]:
            cell["oiwer"] = round(statistics.mean(r["oiwer"] for r in valid), 4)
    for m in ("word_acc", "bow_f1", "gap", "roe", "covered", "tau_own"):
        vals = [r[m] for r in sel if r.get(m) is not None]
        if vals:
            cell[m] = round(statistics.mean(vals), 4)
    if sel and "truth" in sel[0]:
        cell["coverage"] = round(statistics.mean(r["matched"] / r["truth"] if r["truth"] else 0.0 for r in sel), 4)
    if sel and "kept" in sel[0]:
        cell["kept_share"] = round(statistics.mean(r["kept"] / r["lines"] if r["lines"] else 0.0 for r in sel), 4)
    return cell


def summarise(rows, base_rows, groups: dict, pair_with: list[str], group_of) -> dict:
    out = {}
    for arm in dict.fromkeys(r["arm"] for r in rows):
        out[arm] = {}
        for g, test in groups.items():
            sel = [r for r in rows if r["arm"] == arm and test(group_of(r))]
            cell = summary_cell(sel)
            pages = {r["page"] for r in sel}
            cell["paired"] = {b: paired([r for r in rows if r["page"] in pages],
                                        [r for r in base_rows if r["page"] in pages], arm, b) for b in pair_with}
            out[arm][g] = cell
    return out


def usage_of(calls) -> dict:
    return {"calls": len(calls),
            "prompt_tokens": sum((c.get("usage") or {}).get("prompt_tokens") or 0 for c in calls),
            "completion_tokens": sum((c.get("usage") or {}).get("completion_tokens") or 0 for c in calls),
            "wall_s_mean": round(statistics.mean(c["wall_s"] for c in calls), 2) if calls else None,
            **G.billed(calls)}


def rerun_floor(first: dict[str, list[dict]], bases: dict[str, list[dict]]) -> dict:
    """Gemini's own order from the second, identical pass against the first: the rerun floor. A gap between two
    arms smaller than this is inside Gemini's run-to-run noise."""
    global REPLIES
    REPLIES = "replies-rerun"
    try:
        second = {"bench": bench_panel(), "l9": l9_panel(), "owner": owner_panel()}
    finally:
        REPLIES = "replies"
    sets = {"bench_multi": ("bench", LO.MULTICOL), "bench_single": ("bench", LO.SINGLECOL),
            "l9": ("l9", None), "owner": ("owner", None)}
    out = {}
    for name, (s, langs) in sets.items():
        pick = lambda rows: [r for r in rows if r["arm"] == "gemini/native" and (langs is None or r.get("lang") in langs)]
        a, b = pick(first[s]), pick(second[s])
        cell = summary_cell(b)
        p = paired(a, b, "gemini/native", "gemini/native")
        bv = {r["page"]: r for r in b if r.get("valid")}
        d = [abs(r["tau"] - bv[r["page"]]["tau"]) for r in a if r.get("valid") and r["page"] in bv]
        cell["paired"] = {x: paired(b, bases[s], "gemini/native", x) for x in PAIR_WITH[s]}
        cell["first_minus_rerun"] = p
        cell["mean_abs_page_diff"] = round(statistics.mean(d), 4) if d else None
        cell["pages_differing_by_0_01"] = sum(x > 0.01 for x in d)
        cell["unparsed"] = [r["page"] for r in b if r["regions"] == 0]
        out[name] = cell
    return out


def score() -> int:
    _own_ledger()
    lo = json.loads(LO.OUT.read_text())
    lom = json.loads(LOM.OUT.read_text())
    bench, l9, owner = bench_panel(), l9_panel(), owner_panel()
    lang = lambda r: r.get("lang")
    bench_groups = {"multi": lambda l: l in LO.MULTICOL, "single": lambda l: l in LO.SINGLECOL, "all": lambda l: True}
    owner_groups = {"all": lambda gs: True}
    owner_groups.update({g: (lambda gs, g=g: g in gs) for g in sorted({g for r in owner for g in r["groups"]})})
    unparsed = [j for j, _ in jobs("all") if blocks(load(j)) is None]
    broken = [j for j, _ in jobs("all") if j not in unparsed and not strict_json(load(j))]
    # The first rerun pass was answered from the gateway's cache; its lines stay in the ledger (and the cap), and
    # are the set's first len(jobs) lines, written before the live rerun began.
    first_rerun = [c for c in G.ledger() if c["set"] == "layout-order-rerun"][:len(jobs("all"))]
    usage = {"layout-order": usage_of([c for c in G.ledger() if c["set"] == "layout-order"]),
             "rerun_gateway_cached": usage_of(first_rerun),
             "rerun_live": usage_of([c for c in G.ledger() if c["set"] == "layout-order-rerun"
                                     and c not in first_rerun])}
    usage["all"] = G.billed(G.ledger())
    rerun = rerun_floor({"bench": bench, "l9": l9, "owner": owner},
                        {"bench": lo["bench_regions"]["pages"], "l9": lo["l9"]["pages"], "owner": lom["owner96"]["pages"]})
    res = {"item": "W46.layout-order-paid",
           "settings": {"model": G.MODEL, "route": G.API, "temperature": 0, "reasoning_effort": "low",
                        "max_tokens": MAX_TOKENS, "prompt": PROMPT, "price_assumed": G.PRICE, "cap": CAP,
                        "kept_labels": "every block Gemini returns",
                        "lines": {"bench": "the benchmark's truth body lines",
                                  "l9": "Vision lines inside DocLayout-YOLO body regions (W46.layout-order's L9 set)",
                                  "owner": "Vision lines at the app's settings (W46.layout-order-marks's set)"},
                        "valid": {"bench": LO.MIN_FRAC, "min_n": LO.MIN_N}},
           "unparsed": unparsed, "json_broken_but_read": broken, "usage": usage, "rerun": rerun,
           "bench": {"summary": summarise(bench, lo["bench_regions"]["pages"], bench_groups, PAIR_WITH["bench"], lang),
                     "pages": bench},
           "l9": {"summary": summarise(l9, lo["l9"]["pages"], {"all": lambda _: True}, PAIR_WITH["l9"], lang),
                  "pages": l9},
           "owner": {"summary": summarise(owner, lom["owner96"]["pages"], owner_groups, PAIR_WITH["owner"],
                                          lambda r: r["groups"]),
                     "pages": owner}}
    OUT.write_text(json.dumps(res, indent=1) + "\n")
    for name, g in (("bench", "multi"), ("bench", "single"), ("l9", "all"), ("owner", "all")):
        for arm, c in res[name]["summary"].items():
            c = c[g]
            pr = "  ".join(f"vs {b} {v['diff']:+.3f} {v['ci']} n{v['pages']}" for b, v in c["paired"].items() if v)
            print(f"{name}/{g:<6} {arm:<20} tau {c.get('tau', float('nan')):.3f} [{c['valid']}/{c['pages']}]"
                  f" kept {c.get('kept_share', c.get('covered', c.get('coverage', float('nan')))):.2f}"
                  f" acc {c.get('word_acc', float('nan')):.3f}  {pr}")
    print(f"unparsed {unparsed}; ${G.spent():.4f} spent; wrote {OUT}")
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd in ("run", "rerun"):
        REPLIES = "replies" if cmd == "run" else "replies-rerun"
        sys.exit(run(sys.argv[2] if len(sys.argv) > 2 else "all", int(sys.argv[3]) if len(sys.argv) > 3 else None))
    if cmd == "score":
        sys.exit(score())
    print(__doc__)
    sys.exit(2)
