"""W46.layout-order-newspapers-pp: region order on PP-DocLayoutV3's own regions, on L9.

    uv run --offline --with numpy --with scikit-learn python layout_order_pp.py orders   # region orders -> cache
    uv run --offline --with rapidfuzz --with numpy python layout_order_pp.py run         # score them
    uv run --offline --with numpy python -m unittest test_layout_order_pp

(Two steps because on 2026-11-11 no offline Python held both scikit-learn and a compiled rapidfuzz; any one with
both runs ``orders`` then ``run``.)

W46.layout-order's L9 panel ordered Vision's lines inside DocLayout-YOLO's regions with every geometric rule, and
gave PP-DocLayoutV3 only its native order. The app runs PP-DocLayoutV3, so this panel holds its regions fixed and
asks which order to read them in: its own (``pp_native``), the app region sort (``app_regions``, ``LayoutModel.crops``),
HDBSCAN, and the other geometric orderers of ``layout_order.py`` for reference. Inputs are the ones W46.layout-order
left in the cache (Vision lines, PP-DocLayoutV3 regions, NewsBench truth), so nothing is detected or read again.

Two line sets, both the same for every arm:

* ``own`` — Vision lines that fall in a PP-DocLayoutV3 body region (the stream the app reads when the detector runs).
* ``all`` — every Vision line on the page; the lines outside PP-DocLayoutV3's body regions go last, top to bottom,
  in every arm, as W46.layout-order's ``pp_native`` arm did with YOLO's lines.

Scores as ``layout_order.l9_panel``: tau over lines placed in the truth (15-line floor), word accuracy, bag-of-words
F1, their gap, and reading-order edit; each arm is paired against ``pp_native`` over the 15 pages (page bootstrap, as
``layout_pair_newspapers.paired``). Output ``segbench-results/layout-order-pp.json`` (aggregates and per-page
figures, no text).
"""
from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import layout_order as L  # noqa: E402
from layout_pair_newspapers import paired  # noqa: E402

OUT = HERE.parent.parent / "segbench-results/layout-order-pp.json"
BASE = "pp_native"
METRICS = ("tau", "word_acc", "bow_f1", "gap", "roe")


def arm_orders(lines, owner, regs, region_orders_k, line_columns_k) -> dict[str, list[int]]:
    """Each arm's order of ``lines``: owned lines by their region's place then top to bottom, unowned lines last."""
    n = len(lines)
    rest = lambda i: (len(regs), L._cy(lines[i]), L._cx(lines[i]))
    native = sorted(range(len(regs)), key=lambda j: regs[j]["order"])
    arms = {}
    for arm, order in {BASE: native, **region_orders_k}.items():
        rank = L.region_rank(lines, owner, order)
        arms[arm] = sorted(range(n), key=lambda i: rank.get(i, rest(i)))
    if line_columns_k is not None:
        arms["app_columns_lines"] = line_columns_k
    return arms


def score(order, texts, truth, pos, ocr_scorers) -> dict:
    hyp_text = "\n".join(texts[i] for i in order)
    ref, hyp = L.words(truth), L.words(hyp_text)
    seq = [pos[i] for i in order if i in pos]
    acc, bow = 1 - L.wer(ref, hyp), L.bow_f1(ref, hyp)
    roe = ocr_scorers.reading_order_edit(truth, hyp_text)
    return {"placed": len(seq), "valid": len(seq) >= L.MIN_N, "tau": round(L.kendall(seq), 4),
            "word_acc": round(acc, 4), "bow_f1": round(bow, 4), "gap": round(bow - acc, 4),
            "roe": None if roe is None or roe.get("edit") is None else round(roe["edit"], 4)}


ORDERS = L.WORK / "pp-region-orders.json"


def load_pages():
    keys = sorted(p.stem for p in (L.WORK / "vision").glob("newsbench__*.json"))
    pages = []
    for key in keys:
        v = json.loads((L.WORK / "vision" / f"{key}.json").read_text())
        w, h = v["width"], v["height"]
        lines = [[b[0] * w, b[1] * h, b[2] * w, b[3] * h] for b in (l["box"] for l in v["lines"])]
        texts = [l["text"] for l in v["lines"]]
        regs = L.read_regions("pp", key, L.PP_BODY)
        owner = L.assign(lines, [r["box"] for r in regs])
        keep = [i for i in range(len(lines)) if owner[i] is not None]
        truth = (L.NEWSBENCH_TXT / f"{key.split('__', 1)[1]}.txt").read_text()
        pages.append({"key": key, "w": w, "h": h, "regs": regs, "truth": truth,
                      "sets": {"all": (lines, texts, owner),
                               "own": ([lines[i] for i in keep], [texts[i] for i in keep],
                                       [owner[i] for i in keep])}})
    return pages


def orders() -> int:
    """Every orderer on each page's PP-DocLayoutV3 regions, and the app line column sort on its own lines, to the
    cache. Needs scikit-learn (HDBSCAN) and the Swift helper, not rapidfuzz, so it can run in another Python."""
    pages = load_pages()
    res = {"pages": [p["key"] for p in pages],
           "region": L.all_orders([([r["box"] for r in p["regs"]], p["w"], p["h"]) for p in pages]),
           "line_columns": L.app_columns([(p["sets"]["own"][0], p["w"], p["h"]) for p in pages])}
    ORDERS.write_text(json.dumps(res) + "\n")
    print(f"wrote {ORDERS}")
    return 0


def panel():
    import ocr_scorers
    pages = load_pages()
    saved = json.loads(ORDERS.read_text())
    if saved["pages"] != [p["key"] for p in pages]:
        raise SystemExit(f"{ORDERS} is for other pages; rerun `orders`")
    region_orders, line_columns = saved["region"], saved["line_columns"]
    rows = []
    for k, p in enumerate(pages):
        for name, (lines, texts, owner) in p["sets"].items():
            pos = L.truth_positions(texts, p["truth"])
            arms = arm_orders(lines, owner, p["regs"], {a: o[k] for a, o in region_orders.items()},
                              line_columns[k] if name == "own" else None)
            for arm, order in arms.items():
                rows.append({"page": p["key"], "set": name, "arm": arm, "lines": len(lines),
                             "regions": len(p["regs"]), **score(order, texts, p["truth"], pos, ocr_scorers)})
    return rows


def summarise(rows) -> dict:
    out = {}
    for s in dict.fromkeys(r["set"] for r in rows):
        out[s] = {}
        base = {r["page"]: r for r in rows if r["set"] == s and r["arm"] == BASE}
        for arm in dict.fromkeys(r["arm"] for r in rows if r["set"] == s):
            sel = [r for r in rows if r["set"] == s and r["arm"] == arm]
            cell = {"pages": len(sel), "valid": sum(r["valid"] for r in sel)}
            for m in METRICS:
                src = [r for r in sel if r["valid"]] if m == "tau" else sel
                vals = [r[m] for r in src if r[m] is not None]
                if vals:
                    cell[m] = round(statistics.mean(vals), 4)
                if arm != BASE:
                    both = [(r[m], base[r["page"]][m]) for r in src
                            if r[m] is not None and base[r["page"]][m] is not None
                            and (m != "tau" or base[r["page"]]["valid"])]
                    if both:
                        d = paired([a for a, _ in both], [b for _, b in both])
                        cell[f"{m}_vs_native"] = {k: round(v, 4) for k, v in d.items()}
            out[s][arm] = cell
    return out


def run() -> int:
    rows = panel()
    res = {"item": "W46.layout-order-newspapers-pp",
           "inputs": "W46.layout-order's L9 cache: Vision lines (VNRecognizeTextRequest accurate, en-US), "
                     "PP-DocLayoutV3 MLX regions (1024 px, conf 0.5), NewsBench volunteer transcriptions",
           "base": BASE, "guard": {"min_n": L.MIN_N},
           "summary": summarise(rows), "pages": rows}
    OUT.write_text(json.dumps(res, indent=1) + "\n")
    for s, arms in res["summary"].items():
        print(f"\n{s}: tau [valid] / word_acc / gap / roe, and delta vs native [95% CI]")
        for arm, c in arms.items():
            line = (f"  {arm:<18} {c.get('tau', float('nan')):.3f} [{c['valid']}/{c['pages']}]"
                    f"  {c['word_acc']:.3f}  {c['gap']:.3f}  {c.get('roe', float('nan')):.3f}")
            for m in ("tau", "gap", "roe"):
                d = c.get(f"{m}_vs_native")
                if d:
                    line += f"  {m} {d['delta']:+.3f} [{d['lo']:+.3f},{d['hi']:+.3f}]"
            print(line)
    print(f"\nwrote {OUT}")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["orders"]:
        sys.exit(orders())
    if sys.argv[1:] == ["run"]:
        sys.exit(run())
    print(__doc__)
    sys.exit(2)
