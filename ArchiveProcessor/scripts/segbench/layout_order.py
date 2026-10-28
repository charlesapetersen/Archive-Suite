"""W46.layout-order: which ordering stage, with detection held fixed (gap audit §5 item 28; E-layout test 2).

    uv run --offline --with rapidfuzz --with numpy --with scikit-learn python layout_order.py run
    uv run --offline --with rapidfuzz --with numpy --with scikit-learn python -m unittest test_layout_order

Three panels, every one free and on the Mac:

* ``bench-lines`` — the 40 scored pages of the historical reading-order benchmark (Jha, MIT,
  github.com/AbhiPandit1/historical-reading-order-benchmark, cloned into the cache) on the benchmark's own
  YOLOv8m line boxes, so its published numbers (top-to-bottom 0.50, column clustering 0.99 on multi-column
  pages) check this scorer. kraken blla's native order from the benchmark's bundled predictions.
* ``bench-regions`` — the same 40 pages on DocLayout-YOLO's regions (DocStructBench ONNX, run here through the
  Vision OCR lab's ``layout-regions.py``). The ordering stage orders the regions; each ground-truth body line
  takes its region's place and is read top to bottom inside it, so tau and the word error are over the
  benchmark's own lines and text (perfect recognition, as the benchmark assumes). PP-DocLayoutV3's coupled order
  is the native arm on its own regions.
* ``l9`` — NewsBench's 15 Library of Congress newspaper pages. Apple Vision's lines (the app's settings) inside
  DocLayout-YOLO's body regions are the one line set every arm orders, so recognition is identical and only order
  differs. Scored against the volunteer transcription: word accuracy (1 - WER), the order-free bag-of-words F1,
  their gap, OmniDocBench's reading-order edit, and tau over the lines found in the truth. kraken blla's native
  order from the W43.script-specialists segmentation already in the cache; the lab app's line column sort
  (``SearchableWriter.columnOrdered``) on Vision's lines as the app reads a page with no detector.

Orderers on a fixed set of boxes: ``topbottom`` (naive), ``columns`` and ``xycut`` (the benchmark's
``experiments/ordering.py``, ported), ``xycut_yfirst`` (XY-cut as MinerU and PaddleX run it), ``app_regions`` (the lab app's region sort, ``LayoutModel.crops``: columns by
x-centre, top to bottom in each), ``app_columns`` (the app's line column sort, run as the app's own Swift through
``layout_order.swift``) and ``hdbscan`` (Harvard's IDI rule as its paper describes it, HDBSCAN on x-centres plus
rules; the paper's code is not published, so this is our reading of it).

Body stream only: DocLayout-YOLO's ``plain text`` and ``title``; PP-DocLayoutV3's text and title classes; the
benchmark's MainZone, TitlePageZone and CustomZone lines (running heads, folios, margins, stamps, quire marks and
drop capitals left out). Tau is Kendall's over matched lines, reported only for a page passing the benchmark's
validity guard (60% of the truth lines and at least 15). Raw text stays in the cache; the repo gets
``segbench-results/layout-order.json`` (aggregates and per-page figures, no text).
"""
from __future__ import annotations

import json
import os
import re
import statistics
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
CACHE = Path(os.environ.get("ARCHIVE_SEGBENCH_CACHE", Path.home() / "Library/Caches/ArchiveSuiteRehearsal"))
WORK = CACHE / "layout-order"
HROB = WORK / "hrob"
LAB = Path.home() / "Claude/vision-ocr"
NEWSBENCH_TXT = Path.home() / ".local/share/visionocr-ocrlab/newsbench/txt"
KRAKEN_SEG = CACHE / "bench-corpus/specialists/seg"
HELPER = WORK / "bin/layout-order"
OUT = HERE.parent.parent / "segbench-results/layout-order.json"

MULTICOL = ["eng", "swe", "frm"]
SINGLECOL = ["spa", "ita", "fra", "frp", "cat"]
MIN_FRAC, MIN_N = 0.60, 15          # the benchmark's reading-order validity guard

YOLO_BODY = {"plain text", "title"}
PP_BODY = {"text", "paragraph_title", "doc_title", "abstract", "content"}
GT_BODY = ("MainZone", "TitlePageZone", "CustomZone")


# ---------------------------------------------------------------- orderers: boxes [x0, y0, x1, y1] in pixels

def _cx(b): return (b[0] + b[2]) / 2
def _cy(b): return (b[1] + b[3]) / 2
def _h(b): return b[3] - b[1]
def _w(b): return b[2] - b[0]


def order_topbottom(boxes, **_):
    return sorted(range(len(boxes)), key=lambda i: (_cy(boxes[i]), _cx(boxes[i])))


def order_columns(boxes, gap_mult=1.3, **_):
    """The benchmark's column clustering (experiments/ordering.py, MIT), unchanged."""
    if not boxes:
        return []
    idx = sorted(range(len(boxes)), key=lambda i: _cx(boxes[i]))
    med_h = statistics.median(_h(b) for b in boxes) or 1.0
    cols, cur, last = [], [idx[0]], _cx(boxes[idx[0]])
    for i in idx[1:]:
        if _cx(boxes[i]) - last > gap_mult * med_h * 3:
            cols.append(cur)
            cur = []
        cur.append(i)
        last = _cx(boxes[i])
    cols.append(cur)
    cols.sort(key=lambda c: min(boxes[i][0] for i in c))
    return [i for c in cols for i in sorted(c, key=lambda i: _cy(boxes[i]))]


def order_xycut(boxes, min_gap_mult=1.2, **_):
    """The benchmark's recursive XY-cut (experiments/ordering.py, MIT), unchanged: vertical cut first."""
    if not boxes:
        return []
    med_h = statistics.median(_h(b) for b in boxes) or 1.0
    med_w = statistics.median(_w(b) for b in boxes) or 1.0

    def widest_gap(intervals):
        pts = sorted(intervals)
        merged = [list(pts[0])]
        for lo, hi in pts[1:]:
            if lo <= merged[-1][1]:
                merged[-1][1] = max(merged[-1][1], hi)
            else:
                merged.append([lo, hi])
        best_gap, best_cut = 0, None
        for a, b in zip(merged, merged[1:]):
            if b[0] - a[1] > best_gap:
                best_gap, best_cut = b[0] - a[1], (a[1] + b[0]) / 2
        return best_gap, best_cut

    def rec(items):
        if len(items) <= 1:
            return items
        xg, xcut = widest_gap([(boxes[i][0], boxes[i][2]) for i in items])
        if xcut is not None and xg > min_gap_mult * med_w:
            left = [i for i in items if _cx(boxes[i]) < xcut]
            right = [i for i in items if _cx(boxes[i]) >= xcut]
            if left and right:
                return rec(left) + rec(right)
        yg, ycut = widest_gap([(boxes[i][1], boxes[i][3]) for i in items])
        if ycut is not None and yg > min_gap_mult * med_h:
            top = [i for i in items if _cy(boxes[i]) < ycut]
            bot = [i for i in items if _cy(boxes[i]) >= ycut]
            if top and bot:
                return rec(top) + rec(bot)
        return sorted(items, key=lambda i: _cy(boxes[i]))

    return rec(list(range(len(boxes))))


def order_xycut_yfirst(boxes, **_):
    """Recursive XY-cut as the layout toolkits run it (MinerU's and PaddleX's ``recursive_xy_cut``): split into
    rows at every empty band of the vertical projection, each row into columns at every empty band of the
    horizontal one, and recurse; a set neither projection splits is read top to bottom. The benchmark's own
    ``xycut`` asks for a vertical gap wider than 1.2 median box widths, which a column gutter never is, so it
    never cuts a column and equals top-to-bottom; this is the arm that tests XY-cut itself."""
    def split(items, axis):
        lo, hi = (1, 3) if axis == "y" else (0, 2)
        groups, end = [], None
        for i in sorted(items, key=lambda i: boxes[i][lo]):
            if end is None or boxes[i][lo] >= end:
                groups.append([])
                end = boxes[i][hi]
            groups[-1].append(i)
            end = max(end, boxes[i][hi])
        return groups

    def rec(items, axis, tried=False):
        if len(items) <= 1:
            return items
        groups = split(items, axis)
        if len(groups) == 1:
            if tried:
                return sorted(items, key=lambda i: (_cy(boxes[i]), _cx(boxes[i])))
            return rec(items, "x" if axis == "y" else "y", tried=True)
        nxt = "x" if axis == "y" else "y"
        return [i for g in groups for i in rec(g, nxt)]

    return rec(list(range(len(boxes))), "y")


def order_app_regions(boxes, **_):
    """The Vision OCR app's region order (Recogniser.swift ``LayoutModel.crops``, the lab's ``column_order``):
    boxes by x-centre, a new column whenever a centre passes the running column's right edge, each column top
    to bottom by its top edge, columns left to right."""
    by_centre = sorted(range(len(boxes)), key=lambda i: (_cx(boxes[i]), i))
    columns, right = [], -1.0
    for i in by_centre:
        if not columns or _cx(boxes[i]) > right:
            columns.append([])
            right = boxes[i][2]
        columns[-1].append(i)
        right = max(right, boxes[i][2]) if len(columns[-1]) > 1 else boxes[i][2]
    return [i for c in columns for i in sorted(c, key=lambda i: (boxes[i][1], c.index(i)))]


def order_hdbscan(boxes, width=None, **_):
    """Harvard's IDI rule as its paper states it (2608.18972 §4.1: HDBSCAN on crop x-centres plus rules); the code
    is unpublished, so the rules are ours. A box over half the text block's width spans the columns and opens a
    band; inside a band the narrower boxes are clustered on x-centre (HDBSCAN, min_cluster_size 2), noise joins the
    nearest cluster, clusters are read left to right and each top to bottom."""
    n = len(boxes)
    if n < 3:
        return order_topbottom(boxes)
    from sklearn.cluster import HDBSCAN
    import numpy as np
    left, right = min(b[0] for b in boxes), max(b[2] for b in boxes)
    span = [i for i in range(n) if _w(boxes[i]) > 0.5 * (right - left)]
    rest = [i for i in range(n) if i not in span]
    label = {}
    if len(rest) >= 2:
        xs = np.array([[_cx(boxes[i]) / (width or right)] for i in rest])
        labs = HDBSCAN(min_cluster_size=2, min_samples=1, copy=True).fit(xs).labels_
        centres = {k: statistics.median(_cx(boxes[rest[j]]) for j in range(len(rest)) if labs[j] == k)
                   for k in set(labs) if k >= 0}
        for j, i in enumerate(rest):
            k = labs[j]
            if k < 0:
                k = min(centres, key=lambda c: abs(centres[c] - _cx(boxes[i]))) if centres else 0
            label[i] = k
        centres = centres or {0: 0.0}
    else:
        label = {i: 0 for i in rest}
        centres = {0: 0.0}
    cuts = sorted(span, key=lambda i: _cy(boxes[i]))
    bands = [[] for _ in range(len(cuts) + 1)]
    for i in rest:
        bands[sum(1 for c in cuts if _cy(boxes[c]) < _cy(boxes[i]))].append(i)
    out = []
    for k, band in enumerate(bands):
        if k:
            out.append(cuts[k - 1])
        for c in sorted({label[i] for i in band}, key=lambda c: centres[c]):
            out += sorted((i for i in band if label[i] == c), key=lambda i: _cy(boxes[i]))
    return out


def app_columns(pages: list[tuple[list, float, float]]) -> list[list[int]]:
    """The lab app's ``SearchableWriter.columnOrdered`` on each page's boxes, given top to bottom; ``pages`` is
    ``(boxes in pixels, width, height)``. One call to the Swift helper for the lot."""
    build_helper()
    req = []
    for boxes, w, h in pages:
        given = order_topbottom(boxes)
        req.append({"aspect": h / w, "boxes": [[boxes[i][0] / w, boxes[i][1] / h, _w(boxes[i]) / w,
                                                _h(boxes[i]) / h] for i in given], "given": given})
    out = subprocess.run([str(HELPER), "colsort"], input=json.dumps(
        [{"aspect": r["aspect"], "boxes": r["boxes"]} for r in req]).encode(), capture_output=True, check=True)
    return [[r["given"][k] for k in order] for r, order in zip(req, json.loads(out.stdout))]


def build_helper():
    if HELPER.exists():
        return
    HELPER.parent.mkdir(parents=True, exist_ok=True)
    build = WORK / "build"
    build.mkdir(parents=True, exist_ok=True)
    (build / "main.swift").write_text((HERE / "layout_order.swift").read_text())
    srcs = [str(p) for p in sorted((LAB / "Sources").glob("*.swift")) if p.name != "App.swift"]
    subprocess.run(["swiftc", "-O", "-o", str(HELPER), str(build / "main.swift"), *srcs], check=True)


ORDERERS = {"topbottom": order_topbottom, "columns": order_columns, "xycut": order_xycut,
            "xycut_yfirst": order_xycut_yfirst,
            "app_regions": order_app_regions, "hdbscan": order_hdbscan}


def all_orders(pages):
    """Every orderer's order for each ``(boxes, width, height)`` page: ``{name: [order per page]}``."""
    res = {k: [f(b, width=w) for b, w, _ in pages] for k, f in ORDERERS.items()}
    res["app_columns"] = app_columns(pages)
    return res


# ---------------------------------------------------------------- scoring

def kendall(seq) -> float:
    """Kendall tau of a sequence of true ranks taken in predicted order (the benchmark's ``kt``)."""
    c = d = 0
    for i in range(len(seq)):
        for j in range(i + 1, len(seq)):
            if seq[i] < seq[j]:
                c += 1
            elif seq[i] > seq[j]:
                d += 1
    return (c - d) / (c + d) if c + d else 1.0


def wer(ref: list[str], hyp: list[str]) -> float:
    if not ref:
        return 0.0
    from rapidfuzz.distance import Levenshtein
    return Levenshtein.distance(ref, hyp) / len(ref)


def iou(a, b) -> float:
    x1, y1, x2, y2 = max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])
    inter = max(0, x2 - x1) * max(0, y2 - y1)
    ua = _w(a) * _h(a) + _w(b) * _h(b) - inter
    return inter / ua if ua > 0 else 0.0


def match_lines(gt, pred, thr=0.5):
    """The benchmark's greedy IoU match (harness/bench_lib.py ``match``): ``[(gt index, pred index)]``."""
    pairs, used = [], set()
    for gi, g in enumerate(gt):
        best = (-1.0, None)
        for pj, p in enumerate(pred):
            if pj not in used:
                v = iou(g, p)
                if v > best[0]:
                    best = (v, pj)
        if best[0] >= thr:
            pairs.append((gi, best[1]))
            used.add(best[1])
    return pairs


def order_score(rank: dict[int, tuple], texts: list[str], n_truth: int) -> dict:
    """``rank`` maps a truth line (its index is its true place) to its predicted sort key. Tau over those lines,
    valid under the guard; the order-induced word error with their own text (perfect recognition)."""
    lines = sorted(rank)
    pred = sorted(lines, key=lambda g: rank[g])
    pos = {g: k for k, g in enumerate(lines)}
    tau = kendall([pos[g] for g in pred])
    ref = " ".join(texts[g] for g in lines).split()
    hyp = " ".join(texts[g] for g in pred).split()
    valid = len(lines) >= MIN_FRAC * n_truth and len(lines) >= MIN_N
    return {"matched": len(lines), "truth": n_truth, "valid": valid, "tau": round(tau, 4),
            "oiwer": round(wer(ref, hyp), 4)}


# ---------------------------------------------------------------- the benchmark pages

def load_gt(xmlf: Path) -> list[dict]:
    """Ground-truth lines in document (= reading) order, with text and whether each is body text."""
    r = ET.parse(xmlf).getroot()
    m = re.match(r"\{(.*)\}", r.tag)
    ns = m.group(1) if m else ""
    q = (lambda t: f"{{{ns}}}{t}") if ns else (lambda t: t)
    tags = {t.get("ID"): t.get("LABEL", "") for t in r.iter(q("OtherTag"))}
    out = []
    if r.tag.endswith("alto"):
        for block in r.iter(q("TextBlock")):
            labels = [tags.get(t, "") for t in (block.get("TAGREFS") or "").split()]
            zone = next((l for l in labels if l.endswith("Zone") or "Zone" in l), "")
            body = not zone or zone.startswith(GT_BODY)
            for L in block.iter(q("TextLine")):
                a = L.attrib
                if not all(k in a for k in ("HPOS", "VPOS", "WIDTH", "HEIGHT")):
                    continue
                x, y, w, h = (float(a[k]) for k in ("HPOS", "VPOS", "WIDTH", "HEIGHT"))
                txt = " ".join(s.get("CONTENT", "") for s in L.iter(q("String"))).strip()
                out.append({"box": [x, y, x + w, y + h], "text": txt, "body": body})
    else:
        for L in r.iter(q("TextLine")):
            c = L.find(q("Coords"))
            if c is None or not c.get("points"):
                continue
            pts = [tuple(map(float, p.split(","))) for p in c.get("points").split()]
            xs, ys = [p[0] for p in pts], [p[1] for p in pts]
            u = L.find(f".//{q('Unicode')}")
            out.append({"box": [min(xs), min(ys), max(xs), max(ys)],
                        "text": (u.text or "").strip() if u is not None else "", "body": True})
    return out


def page_size(xmlf: Path) -> tuple[float, float]:
    r = ET.parse(xmlf).getroot()
    for el in r.iter():
        if el.tag.endswith("}Page") or el.tag == "Page":
            w = el.get("WIDTH") or el.get("imageWidth")
            h = el.get("HEIGHT") or el.get("imageHeight")
            return float(w), float(h)
    raise ValueError(xmlf)


def read_regions(detector: str, key: str, body: set[str]) -> list[dict]:
    rows = (WORK / "regions" / detector / f"{key}.tsv").read_text().splitlines()[1:]
    out = []
    for row in rows:
        o, label, score, x0, y0, x1, y1, _ = row.split("\t")
        if label in body:
            out.append({"order": int(o), "label": label, "box": [float(x0), float(y0), float(x1), float(y1)]})
    return out


def assign(lines: list[list[float]], regions: list[list[float]], need=0.5) -> list[int | None]:
    """Each line's region: the one covering most of the line, if it covers at least ``need`` of it."""
    out = []
    for b in lines:
        area = max(_w(b) * _h(b), 1e-9)
        best, k = 0.0, None
        for j, r in enumerate(regions):
            inter = max(0, min(b[2], r[2]) - max(b[0], r[0])) * max(0, min(b[3], r[3]) - max(b[1], r[1]))
            if inter / area > best:
                best, k = inter / area, j
        out.append(k if best >= need else None)
    return out


def region_rank(lines, owner, region_order):
    """A line's sort key from its region's place in ``region_order``, then top to bottom inside it."""
    place = {r: k for k, r in enumerate(region_order)}
    return {i: (place[owner[i]], _cy(lines[i]), _cx(lines[i])) for i in range(len(lines)) if owner[i] is not None}


def bench_pages():
    pages = []
    for xml in sorted((HROB / "bench/gt").glob("*.xml")):
        lang = xml.stem.split("_")[0]
        if lang in MULTICOL + SINGLECOL:
            pages.append((xml.stem, lang, xml))
    return pages


def bench_lines_panel():
    pages = bench_pages()
    gts = [load_gt(x) for _, _, x in pages]
    sizes = [page_size(x) for _, _, x in pages]
    yolo = [[l["bbox"] for l in json.loads((HROB / f"bench/pred/yolo/{p}.json").read_text())["lines"]]
            for p, _, _ in pages]
    orders = all_orders([(b, w, h) for b, (w, h) in zip(yolo, sizes)])
    rows = []
    for k, (page, lang, _) in enumerate(pages):
        gt = gts[k]
        boxes = [g["box"] for g in gt]
        texts = [g["text"] for g in gt]
        pairs = match_lines(boxes, yolo[k])
        for arm, per_page in orders.items():
            place = {pj: r for r, pj in enumerate(per_page[k])}
            rows.append({"page": page, "lang": lang, "arm": arm,
                         **order_score({gi: (place[pj],) for gi, pj in pairs}, texts, len(gt))})
        kb = json.loads((HROB / f"bench/pred/kraken/{page}.json").read_text())["lines"]
        kpairs = match_lines(boxes, [l["bbox"] for l in kb])
        rows.append({"page": page, "lang": lang, "arm": "kraken_native",
                     **order_score({gi: (kb[pj]["order"],) for gi, pj in kpairs}, texts, len(gt))})
    return rows


def bench_regions_panel():
    pages = bench_pages()
    rows = []
    gts, regs, sizes = [], [], []
    for page, _, xml in pages:
        gts.append([g for g in load_gt(xml) if g["body"] and g["text"]])
        regs.append(read_regions("yolo", f"hrob__{page}", YOLO_BODY))
        sizes.append(page_size(xml))
    orders = all_orders([([r["box"] for r in rg], w, h) for rg, (w, h) in zip(regs, sizes)])
    for k, (page, lang, _) in enumerate(pages):
        gt = gts[k]
        boxes = [g["box"] for g in gt]
        texts = [g["text"] for g in gt]
        owner = assign(boxes, [r["box"] for r in regs[k]])
        for arm, per_page in orders.items():
            rows.append({"page": page, "lang": lang, "arm": arm, "regions": len(regs[k]),
                         **order_score(region_rank(boxes, owner, per_page[k]), texts, len(gt))})
        pp = read_regions("pp", f"hrob__{page}", PP_BODY)
        pown = assign(boxes, [r["box"] for r in pp])
        native = sorted(range(len(pp)), key=lambda j: pp[j]["order"])
        rows.append({"page": page, "lang": lang, "arm": "pp_native", "regions": len(pp),
                     **order_score(region_rank(boxes, pown, native), texts, len(gt))})
    return rows


# ---------------------------------------------------------------- L9

_tok = re.compile(r"[0-9a-z]+")


def words(s: str) -> list[str]:
    return _tok.findall(s.lower())


def bow_f1(ref: list[str], hyp: list[str]) -> float:
    from collections import Counter
    r, h = Counter(ref), Counter(hyp)
    tp = sum((r & h).values())
    if not tp:
        return 0.0
    p, rc = tp / sum(h.values()), tp / sum(r.values())
    return 2 * p * rc / (p + rc)


def truth_positions(line_texts: list[str], truth: str, min_score=80.0, min_chars=12) -> dict[int, float]:
    """Each line's place in the truth text (start of its best partial alignment), for lines long enough to place
    and matched well enough; computed once per page, so it is the same for every arm."""
    from rapidfuzz import fuzz
    norm = lambda s: " ".join(words(s))
    t = norm(truth)
    out = {}
    for i, s in enumerate(line_texts):
        s = norm(s)
        if len(s) < min_chars:
            continue
        a = fuzz.partial_ratio_alignment(s, t)
        if a is not None and a.score >= min_score:
            out[i] = a.dest_start
    return out


def kraken_lines(key: str) -> tuple[list[list[float]], float, float]:
    r = ET.parse(KRAKEN_SEG / f"{key}.xml").getroot()
    ns = re.match(r"\{(.*)\}", r.tag).group(1)
    page = r.find(f".//{{{ns}}}Page")
    out = []
    for L in r.iter(f"{{{ns}}}TextLine"):
        pts = [tuple(map(float, p.split(","))) for p in L.find(f"{{{ns}}}Coords").get("points").split()]
        out.append([min(p[0] for p in pts), min(p[1] for p in pts), max(p[0] for p in pts), max(p[1] for p in pts)])
    return out, float(page.get("imageWidth")), float(page.get("imageHeight"))


def l9_panel():
    sys.path.insert(0, str(HERE))
    import ocr_scorers
    keys = sorted(p.stem for p in (WORK / "vision").glob("newsbench__*.json"))
    pages = []
    for key in keys:
        v = json.loads((WORK / "vision" / f"{key}.json").read_text())
        w, h = v["width"], v["height"]
        lines = [[l["box"][0] * w, l["box"][1] * h, l["box"][2] * w, l["box"][3] * h] for l in v["lines"]]
        texts = [l["text"] for l in v["lines"]]
        regs = read_regions("yolo", key, YOLO_BODY)
        owner = assign(lines, [r["box"] for r in regs])
        keep = [i for i in range(len(lines)) if owner[i] is not None]
        pages.append({"key": key, "w": w, "h": h, "lines": [lines[i] for i in keep],
                      "texts": [texts[i] for i in keep], "owner": [owner[i] for i in keep], "regs": regs,
                      "all_lines": len(lines)})
    region_orders = all_orders([([r["box"] for r in p["regs"]], p["w"], p["h"]) for p in pages])
    line_columns = app_columns([(p["lines"], p["w"], p["h"]) for p in pages])
    rows = []
    for k, p in enumerate(pages):
        truth = (NEWSBENCH_TXT / f"{p['key'].split('__', 1)[1]}.txt").read_text()
        lines, texts = p["lines"], p["texts"]
        n = len(lines)
        arms = {}
        for arm, per_page in region_orders.items():
            rank = region_rank(lines, p["owner"], per_page[k])
            arms[arm] = sorted(range(n), key=lambda i: rank[i])
        arms["app_columns_lines"] = line_columns[k]
        pp = read_regions("pp", p["key"], PP_BODY)
        pown = assign(lines, [r["box"] for r in pp])
        native = sorted(range(len(pp)), key=lambda j: pp[j]["order"])
        prank = region_rank(lines, pown, native)
        arms["pp_native"] = sorted(range(n), key=lambda i: prank.get(i, (len(pp), _cy(lines[i]), _cx(lines[i]))))
        kl, kw, kh = kraken_lines(p["key"])
        sx, sy = p["w"] / kw, p["h"] / kh
        kl = [[b[0] * sx, b[1] * sy, b[2] * sx, b[3] * sy] for b in kl]
        kown = assign(lines, kl, need=0.3)
        arms["kraken_native"] = sorted(range(n), key=lambda i: (kown[i] if kown[i] is not None else len(kl),
                                                                 _cy(lines[i]), _cx(lines[i])))
        # A native arm's own detector may miss lines; those go last, top to bottom, and its tau over the lines it
        # did place is kept beside the whole-set figure.
        own = {"pp_native": {i for i in range(n) if i in prank},
               "kraken_native": {i for i in range(n) if kown[i] is not None}}
        pos = truth_positions(texts, truth)
        ref = words(truth)
        for arm, order in arms.items():
            hyp_text = "\n".join(texts[i] for i in order)
            hyp = words(hyp_text)
            seq = [pos[i] for i in order if i in pos]
            acc = 1 - wer(ref, hyp)
            bow = bow_f1(ref, hyp)
            roe = ocr_scorers.reading_order_edit(truth, hyp_text)
            extra = {}
            if arm in own:
                oseq = [pos[i] for i in order if i in pos and i in own[arm]]
                extra = {"covered": round(len(own[arm]) / n, 4) if n else 0.0,
                         "tau_own": round(kendall(oseq), 4) if len(oseq) >= MIN_N else None}
            # The volunteer transcription covers only part of some pages, so the guard's 60% share cannot be
            # asked of the lines placed in it; the 15-line floor is.
            rows.append({"page": p["key"], "arm": arm, "lines": n, "lines_all": p["all_lines"],
                         "regions": len(p["regs"]), "placed": len(seq), **extra,
                         "valid": len(seq) >= MIN_N,
                         "tau": round(kendall(seq), 4), "word_acc": round(acc, 4), "bow_f1": round(bow, 4),
                         "gap": round(bow - acc, 4), "roe": None if roe is None or roe.get("edit") is None else round(roe["edit"], 4)})
    return rows


# ---------------------------------------------------------------- report

def summarise(rows, groups: dict[str, list[str] | None], metrics):
    out = {}
    for arm in dict.fromkeys(r["arm"] for r in rows):
        out[arm] = {}
        for g, langs in groups.items():
            sel = [r for r in rows if r["arm"] == arm and (langs is None or r.get("lang") in langs)]
            cell = {"pages": len(sel)}
            valid = [r for r in sel if r.get("valid")]
            cell["valid"] = len(valid)
            for m in metrics:
                # tau and the order-induced word error only where the guard holds (a page whose lines were
                # not found has no order to score, and its empty word error would read as perfect)
                src = valid if m in ("tau", "oiwer") else sel
                vals = [r[m] for r in src if r.get(m) is not None]
                if vals:
                    cell[m] = round(statistics.mean(vals), 4)
                    cell[m + "_median"] = round(statistics.median(vals), 4)
            if sel and "truth" in sel[0]:
                cell["coverage"] = round(statistics.mean(r["matched"] / r["truth"] if r["truth"] else 0.0
                                                         for r in sel), 4)
            out[arm][g] = cell
    return out


def run() -> int:
    groups = {"multi": MULTICOL, "single": SINGLECOL, "all": None}
    bl = bench_lines_panel()
    br = bench_regions_panel()
    l9 = l9_panel()
    res = {
        "item": "W46.layout-order",
        "sources": {
            "benchmark": "github.com/AbhiPandit1/historical-reading-order-benchmark @ "
                         + subprocess.run(["git", "-C", str(HROB), "rev-parse", "--short", "HEAD"],
                                          capture_output=True, text=True).stdout.strip(),
            "lab_sources": "vision-ocr @ " + subprocess.run(["git", "-C", str(LAB), "rev-parse", "--short", "HEAD"],
                                                           capture_output=True, text=True).stdout.strip(),
            "doclayout_yolo": "DocLayout-YOLO DocStructBench ONNX, imgsz 1024, conf 0.25 (lab layout-regions.py)",
            "pp_doclayoutv3": "PP-DocLayoutV3 MLX, 1024 px, conf 0.5 (lab layout-regions.py)",
            "vision": "VNRecognizeTextRequest accurate, language correction, en-US",
            "kraken_l9": "kraken 7.1.1 blla, W43.script-specialists segmentation (cache bench-corpus/specialists/seg)",
        },
        "guard": {"min_frac": MIN_FRAC, "min_n": MIN_N},
        "bench_lines": {"summary": summarise(bl, groups, ["tau", "oiwer"]), "pages": bl},
        "bench_regions": {"summary": summarise(br, groups, ["tau", "oiwer"]), "pages": br},
        "l9": {"summary": summarise(l9, {"all": None}, ["tau", "word_acc", "bow_f1", "gap", "roe", "covered",
                                                         "tau_own"]), "pages": l9},
    }
    OUT.write_text(json.dumps(res, indent=1) + "\n")
    for name in ("bench_lines", "bench_regions"):
        print(f"\n{name}: tau (valid pages) / order-induced WER, mean")
        for arm, c in res[name]["summary"].items():
            print(f"  {arm:<18}" + "".join(
                f"  {g}: {c[g].get('tau', float('nan')):.3f} [{c[g]['valid']}/{c[g]['pages']}]"
                f" {c[g].get('oiwer', float('nan')):.3f} cov {c[g]['coverage']:.2f}" for g in groups))
    print("\nl9: tau [valid] / word_acc / bow_f1 / gap / roe, mean")
    for arm, c in res["l9"]["summary"].items():
        a = c["all"]
        print(f"  {arm:<18}  {a.get('tau', float('nan')):.3f} [{a['valid']}/{a['pages']}]  {a['word_acc']:.3f}"
              f"  {a['bow_f1']:.3f}  {a['gap']:.3f}  {a.get('roe', float('nan')):.3f}"
              + (f"  covered {a['covered']:.3f} tau_own {a.get('tau_own', float('nan')):.3f}" if "covered" in a else ""))
    print(f"\nwrote {OUT}")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["run"]:
        sys.exit(run())
    print(__doc__)
    sys.exit(2)
