"""W46.layout-order-marks: the ordering stage on the owner's pages, with detection held fixed per detector.

    python3 ops/autonomous/heavy-run.py run -- python3 layout_order_marks.py detect   # Vision lines, YOLO regions
    uv run --offline --with rapidfuzz --with numpy --with scikit-learn --with pillow python layout_order_marks.py run
    uv run --offline --with rapidfuzz --with numpy --with scikit-learn --with pillow python -m unittest test_layout_order_marks

The item asked for tau on the 30 annotated marks-set pages. The marks set's truth (the reconciled owner core,
W46.fix-marks-sheet-feedback) is mark boxes with class and touches-print: it has no reading order, so no tau can be
scored on it. Two panels instead, each scored only on the truth it has:

* ``owner96`` — the order question on owner pages. The 96 owner truth pages carry the owner's adjudicated text, which
  is in reading order. Apple Vision's lines (the app's settings) are the one line set every arm orders; each arm
  keeps the lines inside its detector's regions and orders them. Detection is held fixed per detector, as the
  measurement audit's LAY-2 asks: DocLayout-YOLO with picture regions kept (its ``figure`` is where it puts hands),
  PP-DocLayoutV3's text classes, and Vision's own ``RecognizeDocumentsRequest`` regions. The geometric orderers of
  ``layout_order`` run on each set of regions; the native orders are PP-DocLayoutV3's and Vision's. Two arms use no
  detector: the app's line column sort and Vision's own line order. Tau is over the lines placed in the truth text,
  valid on a page with at least 15 placed (the L9 rule); word accuracy, the order-free bag-of-words F1 and the
  reading-order edit are over the whole truth.
* ``marks`` — whether the owner's marks reach the ordered stream at all. On the 32 detector-eligible marks-core
  pages, a mark reaches a detector's stream when one of its kept regions covers at least half the mark's box. For
  Vision, a mark is read when Vision lines cover it the same way. Marks touching print and clear of print apart,
  A-core and B-core apart.

Raw text stays in the cache; the repo gets ``segbench-results/layout-order-marks.json`` (aggregates and per-page
figures, no text).
"""
from __future__ import annotations

import json
import random
import statistics
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import layout_order as LO  # noqa: E402

CACHE = LO.CACHE
WORK = CACHE / "layout-order-marks"
PHOTO = CACHE / "layout-photo"
TRUTH = CACHE / "ocr-truth/truth"
SUPPORT = Path.home() / "Library/Application Support/ArchiveSuiteRehearsal"
RECORD = SUPPORT / "marks-set-reconciled-da388b05c388-dac79c80c2f6"
MARK_IMAGES = SUPPORT / "marks-set-frozen-da388b05c388/images"
PP_MARKS = CACHE / "marks-detect/pp-raw.json"
OUT = HERE.parent.parent / "segbench-results/layout-order-marks.json"
LAB_VENV = Path.home() / ".local/share/visionocr-ocrlab/venv/bin/python"
LAB_REGIONS = Path.home() / "Claude/vision-ocr/ops/ocrlab/layout-regions.py"

# The detection sets held fixed. YOLO keeps pictures (LAY-2); every set keeps tables, which on owner pages are text.
YOLO_KEEP = LO.YOLO_BODY | {"figure", "table"}
PP_KEEP = LO.PP_BODY | {"table", "aside_text"}
VISION_KEEP = {"title", "paragraph", "list", "table"}
DETECTORS = {"yolo": YOLO_KEEP, "pp": PP_KEEP, "vision": VISION_KEEP}
NATIVE = {"pp", "vision"}
COVER = 0.5
DEFAULT = "yolo/app_regions"     # the app's region sort on DocLayout-YOLO, pictures kept: the comparison base


# ---------------------------------------------------------------- inputs

def owner_pages() -> list[dict]:
    rows = [json.loads(l) for l in (PHOTO / "pages.jsonl").read_text().splitlines()]
    return [r for r in rows if r["set"] == "owner99" and "agreement-only" not in r["groups"]]


def marks_truth() -> dict:
    pages = json.loads((RECORD / "reconciled.json").read_text())["pages"]
    return {pid: dict(core=p["core_support"], marks=[dict(box=m["box"], cls=m["cls"], overlaps=bool(m["overlaps"]))
                                                      for m in p["marks"]])
            for pid, p in sorted(pages.items()) if p["detector_evaluable"]}


def vision_lines(pid: str) -> tuple[list[list[float]], list[str], float, float]:
    v = json.loads((WORK / "vision" / f"{pid}.json").read_text())
    w, h = v["width"], v["height"]
    return ([[l["box"][0] * w, l["box"][1] * h, l["box"][2] * w, l["box"][3] * h] for l in v["lines"]],
            [l["text"] for l in v["lines"]], w, h)


def photo_regions(det: str) -> dict:
    """layout-photo's cached regions on the 96 (0-1 boxes, the detector's order)."""
    return json.loads((PHOTO / "regions" / f"{det}.json").read_text())["pages"]


def keep(regions: list[dict], labels: set[str], w: float, h: float) -> list[dict]:
    return [{"order": r["order"], "label": r["label"],
             "box": [r["box"][0] * w, r["box"][1] * h, r["box"][2] * w, r["box"][3] * h]}
            for r in regions if r["label"] in labels]


# ---------------------------------------------------------------- detect

def detect() -> int:
    """Vision lines on the 96 and the 32 marks pages, DocLayout-YOLO on the 32. Run it inside the heavy lock."""
    (WORK / "vision").mkdir(parents=True, exist_ok=True)
    (WORK / "yolo").mkdir(parents=True, exist_ok=True)
    LO.build_helper()
    args = []
    for p in owner_pages():
        args += [p["image"], str(WORK / "vision" / f"{p['id']}.json")]
    for pid in marks_truth():
        args += [str(MARK_IMAGES / f"{pid}.jpg"), str(WORK / "vision" / f"{pid}.json")]
    subprocess.run([str(LO.HELPER), "lines", *args], check=True)
    weights = next((Path.home() / ".local/share/visionocr-ocrlab/hf/hub/models--wybxc--DocLayout-YOLO-DocStructBench-onnx"
                    "/snapshots").glob("*/doclayout_yolo_docstructbench_imgsz1024.onnx"))
    for pid in marks_truth():
        out = WORK / "yolo" / f"{pid}.tsv"
        if not out.exists() or not out.stat().st_size:
            subprocess.run([str(LAB_VENV), str(LAB_REGIONS), "--model", "yolo", "--weights", str(weights),
                            "--image", str(MARK_IMAGES / f"{pid}.jpg"), "--out", str(out)], check=True,
                           capture_output=True)
    return 0


# ---------------------------------------------------------------- owner96

def page_arms(lines, regs_by_det: dict[str, list[dict]], w: float) -> dict[str, tuple[list[int], int]]:
    """Every arm's order of the line indices it keeps, and how many it keeps: ``{arm: (order, kept)}``."""
    arms = {}
    n = len(lines)
    arms["none/vision_lines"] = (list(range(n)), n)
    arms["none/topbottom"] = (LO.order_topbottom(lines), n)
    for det, regs in regs_by_det.items():
        boxes = [r["box"] for r in regs]
        owner = LO.assign(lines, boxes)
        kept = [i for i in range(n) if owner[i] is not None]
        orders = {k: f(boxes, width=w) for k, f in LO.ORDERERS.items()}
        if det in NATIVE:
            orders["native"] = sorted(range(len(regs)), key=lambda j: regs[j]["order"])
        for name, ro in orders.items():
            rank = LO.region_rank(lines, owner, ro)
            arms[f"{det}/{name}"] = (sorted(kept, key=lambda i: rank[i]), len(kept))
    return arms


def owner96_panel(column_sort=None) -> list[dict]:
    import ocr_scorers
    pages = owner_pages()
    regions = {d: photo_regions(d) for d in DETECTORS}
    loaded = []
    for p in pages:
        lines, texts, w, h = vision_lines(p["id"])
        regs = {d: keep(regions[d][p["id"]]["regions"], DETECTORS[d], w, h) for d in DETECTORS}
        loaded.append((p, lines, texts, w, h, regs))
    cols = (column_sort or LO.app_columns)([(lines, w, h) for _, lines, _, w, h, _ in loaded])
    rows = []
    for (p, lines, texts, w, h, regs), col in zip(loaded, cols):
        truth = (TRUTH / f"{p['id']}.txt").read_text()
        arms = page_arms(lines, regs, w)
        arms["none/app_columns"] = (col, len(lines))
        pos = LO.truth_positions(texts, truth)
        ref = LO.words(truth)
        for arm, (order, kept) in arms.items():
            hyp_text = "\n".join(texts[i] for i in order)
            hyp = LO.words(hyp_text)
            seq = [pos[i] for i in order if i in pos]
            acc = 1 - LO.wer(ref, hyp)
            bow = LO.bow_f1(ref, hyp)
            roe = ocr_scorers.reading_order_edit(truth, hyp_text)
            rows.append({"page": p["id"], "groups": [g for g in p["groups"] if g != "the 96"], "arm": arm,
                         "lines": len(lines), "kept": kept, "placed": len(seq), "valid": len(seq) >= LO.MIN_N,
                         "tau": round(LO.kendall(seq), 4), "word_acc": round(acc, 4), "bow_f1": round(bow, 4),
                         "gap": round(bow - acc, 4),
                         "roe": None if roe is None or roe.get("edit") is None else round(roe["edit"], 4)})
    return rows


def boot_mean(vals: list[float], n=2000, seed=46):
    if len(vals) < 2:
        return None
    rng = random.Random(seed)
    ms = sorted(statistics.mean(rng.choice(vals) for _ in vals) for _ in range(n))
    return [round(ms[int(0.025 * n)], 4), round(ms[int(0.975 * n) - 1], 4)]


def summarise_owner(rows: list[dict]) -> dict:
    groups = ["all"] + sorted({g for r in rows for g in r["groups"]})
    base = {(r["page"]): r for r in rows if r["arm"] == DEFAULT}
    out = {}
    for arm in dict.fromkeys(r["arm"] for r in rows):
        out[arm] = {}
        for g in groups:
            sel = [r for r in rows if r["arm"] == arm and (g == "all" or g in r["groups"])]
            valid = [r for r in sel if r["valid"]]
            cell = {"pages": len(sel), "valid": len(valid),
                    "kept_share": round(statistics.mean(r["kept"] / r["lines"] if r["lines"] else 0.0
                                                        for r in sel), 4) if sel else None}
            if valid:
                taus = [r["tau"] for r in valid]
                cell.update(tau=round(statistics.mean(taus), 4), tau_median=round(statistics.median(taus), 4),
                            tau_ci=boot_mean(taus), pages_tau_ge_095=sum(t >= 0.95 for t in taus))
            for m in ("word_acc", "bow_f1", "gap", "roe"):
                vals = [r[m] for r in sel if r[m] is not None]
                if vals:
                    cell[m] = round(statistics.mean(vals), 4)
            # Paired against the default on the pages both score: a tie when the interval holds zero.
            both = [(r["tau"], base[r["page"]]["tau"]) for r in valid
                    if base.get(r["page"], {}).get("valid")]
            if both and arm != DEFAULT:
                d = [a - b for a, b in both]
                cell["paired_vs_default"] = {"pages": len(d), "tau_diff": round(statistics.mean(d), 4),
                                             "ci": boot_mean(d)}
            out[arm][g] = cell
    return out


# ---------------------------------------------------------------- marks

def cover(mark, boxes) -> float:
    """The largest share of the mark's box that one box covers."""
    area = max(LO._w(mark) * LO._h(mark), 1e-12)
    best = 0.0
    for b in boxes:
        inter = max(0, min(mark[2], b[2]) - max(mark[0], b[0])) * max(0, min(mark[3], b[3]) - max(mark[1], b[1]))
        best = max(best, inter / area)
    return best


def lines_cover(mark, lines) -> float:
    """The share of the mark's box under the union of the lines that lie mostly inside it (a raster estimate)."""
    inside = []
    for b in lines:
        a = max(LO._w(b) * LO._h(b), 1e-12)
        inter = max(0, min(mark[2], b[2]) - max(mark[0], b[0])) * max(0, min(mark[3], b[3]) - max(mark[1], b[1]))
        if inter / a >= 0.5:
            inside.append(b)
    if not inside:
        return 0.0
    g = 40
    x0, y0, x1, y1 = mark
    hit = 0
    for i in range(g):
        for j in range(g):
            x, y = x0 + (i + 0.5) * (x1 - x0) / g, y0 + (j + 0.5) * (y1 - y0) / g
            hit += any(b[0] <= x <= b[2] and b[1] <= y <= b[3] for b in inside)
    return hit / (g * g)


def yolo_marks(pid: str, w: float, h: float) -> list[dict]:
    rows = (WORK / "yolo" / f"{pid}.tsv").read_text().splitlines()[1:]
    out = []
    for row in rows:
        o, label, _s, x0, y0, x1, y1, _ = row.split("\t")
        out.append({"label": label, "box": [float(x0) / w, float(y0) / h, float(x1) / w, float(y1) / h]})
    return out


def pp_marks() -> dict[str, list[dict]]:
    """PP-DocLayoutV3's regions on the marks pages (marks-detect's run), as 0-1 boxes."""
    from PIL import Image
    raw = json.loads(PP_MARKS.read_text())["pages"]
    out = {}
    for pid, regs in raw.items():
        im = Image.open(MARK_IMAGES / f"{pid}.jpg")
        im.draft("RGB", (1024, 1024))
        w, h = im.size
        out[pid] = [{"label": r["label"], "box": [r["bbox"][0] / w, r["bbox"][1] / h, r["bbox"][2] / w,
                                                  r["bbox"][3] / h]} for r in regs]
    return out


MARK_ARMS = {
    "yolo-app-filter": ("yolo", LO.YOLO_BODY),
    "yolo-pictures-kept": ("yolo", YOLO_KEEP),
    "yolo-any": ("yolo", None),
    "pp-text": ("pp", LO.PP_BODY),
    "pp-kept": ("pp", PP_KEEP),
    "pp-any": ("pp", None),
}


def marks_panel(pp=None) -> list[dict]:
    t = marks_truth()
    pp = pp if pp is not None else pp_marks()
    rows = []
    for pid, p in t.items():
        lines, _texts, w, h = vision_lines(pid)
        nlines = [[b[0] / w, b[1] / h, b[2] / w, b[3] / h] for b in lines]
        regs = {"yolo": yolo_marks(pid, w, h), "pp": pp.get(pid, [])}
        for k, m in enumerate(p["marks"]):
            r = {"page": pid, "core": p["core"], "mark": k, "cls": m["cls"], "overlaps": m["overlaps"],
                 "vision-lines": round(lines_cover(m["box"], nlines), 3)}
            for arm, (det, labels) in MARK_ARMS.items():
                boxes = [x["box"] for x in regs[det] if labels is None or x["label"] in labels]
                r[arm] = round(cover(m["box"], boxes), 3)
            rows.append(r)
    return rows


def summarise_marks(rows: list[dict]) -> dict:
    arms = ["vision-lines", *MARK_ARMS]
    sels = {"all": lambda r: True, "A-core": lambda r: r["core"] == "A-core", "B-core": lambda r: r["core"] == "B-core",
            "touching print": lambda r: r["overlaps"], "clear of print": lambda r: not r["overlaps"]}
    pages = sorted({r["page"] for r in rows})
    out = {}
    for arm in arms:
        out[arm] = {}
        for g, f in sels.items():
            sel = [r for r in rows if f(r)]
            n = sum(r[arm] >= COVER for r in sel)
            # 95% page-bootstrap interval of the share reached
            rng = random.Random(46)
            by = {pg: [r for r in sel if r["page"] == pg] for pg in pages}
            shares = []
            for _ in range(2000):
                s = [x for _ in pages for x in by[rng.choice(pages)]]
                if s:
                    shares.append(sum(x[arm] >= COVER for x in s) / len(s))
            shares.sort()
            out[arm][g] = {"reached": n, "of": len(sel), "share": round(n / len(sel), 3) if sel else None,
                           "ci": [round(shares[int(0.025 * len(shares))], 3),
                                  round(shares[int(0.975 * len(shares)) - 1], 3)] if shares else None}
    return out


def run() -> int:
    o96 = owner96_panel()
    mk = marks_panel()
    res = {"item": "W46.layout-order-marks",
           "settings": {"vision": "layout_order.swift lines (the app's settings)",
                        "regions_96": "layout-photo cache (W46.layout-photo): DocLayout-YOLO DocStructBench ONNX 1024 px "
                                      "conf 0.25; PP-DocLayoutV3 MLX 1024 px conf 0.5; Vision RecognizeDocumentsRequest",
                        "keep": {d: sorted(v) for d, v in DETECTORS.items()}, "cover": COVER,
                        "default": DEFAULT, "valid": f"at least {LO.MIN_N} lines placed in the truth"},
           "owner96": {"summary": summarise_owner(o96), "pages": o96},
           "marks": {"summary": summarise_marks(mk), "marks": mk}}
    OUT.write_text(json.dumps(res, indent=1) + "\n")
    print("wrote", OUT)
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    sys.exit({"detect": detect, "run": run}[cmd]())
