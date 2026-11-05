#!/usr/bin/env python3
"""Whether marks can be found: detectors scored on the marks set's owner core (W46.marks-detect).

  <lab venv>/bin/python marks_detect.py detect pp          # PP-DocLayoutV3 regions on the 32 truth pages
  python3 marks_detect.py report                          # segbench-results/marks-detect.{json,md}
  python3 marks_detect.py pack --out DIR                  # the Sherlock pack (YOLO11m training, sherlock/marks-detect)

Truth is the reconciled owner core (W46.fix-marks-sheet-feedback): the 32 detector-eligible pages and their
rough boxes. Excluded pages are never read as no-mark negatives. Boxes are matched one to one, class-agnostic
(each detector has its own vocabulary), greedily by IoU; recall is reported per truth class, touching print or
not, and A-core and B-core apart. Two match rules: IoU >= 0.5 (the filed rule) and a loose hit, IoU >= 0.1,
because the truth boxes are rough drafts, not tight geometry. Intervals are a page bootstrap.

MRK-1: no model is ranked on pages it drafted or pre-flagged. Every core page was drafted by Gemini 3.7 Flash
and Qwen3-VL 8B, and the B-core was drawn from Qwen3.6-27B's pre-flag, so a Qwen3.6-27B arm is scored on the
A-core only. Regions and counts only: no text, no pixels, no network, no corpus write.
"""
from __future__ import annotations

import json
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SUPPORT = Path.home() / "Library/Application Support/ArchiveSuiteRehearsal"
RECORD = SUPPORT / "marks-set-reconciled-da388b05c388-dac79c80c2f6"
IMAGES = SUPPORT / "marks-set-frozen-da388b05c388/images"
WORK = Path.home() / "Library/Caches/ArchiveSuiteRehearsal/marks-detect"
# The collected Sherlock results (sherlock/packs/W46.marks-detect.json "mac"): public.json, pilot.json, runs/.
CLUSTER = Path.home() / ".local/state/archive-autonomous/artifacts/marks-detect-20261104"
RESULTS = HERE.parent.parent / "segbench-results"

# Which of each detector's classes count as a mark. Anything else it emits is ignored, not a false positive.
ARMS = {
    "pp": dict(name="PP-DocLayoutV3 Seal + Aside Text", file="pp.json",
               labels={"seal", "aside_text"}, pages="all"),
    "pp-any": dict(name="PP-DocLayoutV3, any region (coverage only)", file="pp-any.json", labels=None, pages="all"),
    # Every YOLO class is a mark class. Its boxes were kept down to conf 0.05; 0.25 is Ultralytics' default.
    "yolo": dict(name="YOLO11m, AnnoPage + SignverOD (conf 0.25)", file=CLUSTER / "public.json", labels=None,
                 pages="all", conf=0.25),
    "yolo-pilot": dict(name="YOLO11m one-epoch pilot (conf 0.25)", file=CLUSTER / "pilot.json", labels=None,
                       pages="all", conf=0.25, sweep=False),
}
SWEEP = (0.05, 0.1, 0.15, 0.25, 0.4, 0.5, 0.6)
RULES = {"iou50": 0.5, "hit": 0.1}


def truth(record=RECORD):
    """{page: {"core": A-core|B-core, "marks": [{box, cls, overlaps}]}} for detector-eligible pages."""
    pages = json.loads((Path(record) / "reconciled.json").read_text())["pages"]
    out = {}
    for pid, p in sorted(pages.items()):
        if not p["detector_evaluable"]:
            continue
        out[pid] = dict(core=p["core_support"],
                        marks=[dict(box=m["box"], cls=m["cls"], overlaps=bool(m["overlaps"]))
                               for m in p["marks"]])
    return out


def iou(a, b):
    w = min(a[2], b[2]) - max(a[0], b[0])
    h = min(a[3], b[3]) - max(a[1], b[1])
    if w <= 0 or h <= 0:
        return 0.0
    inter = w * h
    return inter / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter)


def match(gt, pred, thr):
    """One-to-one greedy match by IoU, highest first; returns the matched truth indices and the matched count."""
    pairs = sorted(((iou(g, p), i, j) for i, g in enumerate(gt) for j, p in enumerate(pred)), reverse=True)
    used_g, used_p = set(), set()
    for v, i, j in pairs:
        if v < thr:
            break
        if i not in used_g and j not in used_p:
            used_g.add(i)
            used_p.add(j)
    return used_g, len(used_p)


def page_counts(t, preds, thr):
    """Per page: truth rows (cls, overlaps, found) and the number of predictions and of matched predictions."""
    rows = {}
    for pid, p in t.items():
        gt = [m["box"] for m in p["marks"]]
        pr = preds.get(pid, [])
        hit, n_match = match(gt, pr, thr)
        rows[pid] = dict(core=p["core"], pred=len(pr), matched=n_match,
                         marks=[(m["cls"], m["overlaps"], i in hit) for i, m in enumerate(p["marks"])])
    return rows


def ratio(rows, sel):
    found = total = 0
    for r in rows:
        for cls, ov, ok in r["marks"]:
            if sel(cls, ov):
                total += 1
                found += ok
    return found, total


def boot(rows, stat, n=2000, seed=46):
    """95% page-bootstrap interval of stat(rows) -> (num, den); None where a resample has no denominator."""
    rng = random.Random(seed)
    vals = []
    for _ in range(n):
        s = [rows[rng.randrange(len(rows))] for _ in rows]
        num, den = stat(s)
        if den:
            vals.append(num / den)
    if not vals:
        return None
    vals.sort()
    return [round(vals[int(0.025 * len(vals))], 3), round(vals[int(0.975 * len(vals)) - 1], 3)]


def summarise(rows):
    rows = list(rows)
    if not rows:
        return None

    def cell(sel):
        num, den = ratio(rows, sel)
        return dict(found=num, of=den, rate=round(num / den, 3) if den else None,
                    ci=boot(rows, lambda s: ratio(s, sel)) if den else None)

    classes = sorted({c for r in rows for c, _, _ in r["marks"]})
    pred = sum(r["pred"] for r in rows)
    matched = sum(r["matched"] for r in rows)
    return dict(pages=len(rows), marks=sum(len(r["marks"]) for r in rows),
                recall=cell(lambda c, o: True),
                touching_print=cell(lambda c, o: o), clear_of_print=cell(lambda c, o: not o),
                by_class={c: cell(lambda cc, o, c=c: cc == c) for c in classes},
                predictions=pred, precision=round(matched / pred, 3) if pred else None,
                precision_ci=boot(rows, lambda s: (sum(r["matched"] for r in s), sum(r["pred"] for r in s)))
                if pred else None,
                unmatched_per_page=round((pred - matched) / len(rows), 2))


def score(t, preds, arm):
    out = {}
    for rule, thr in RULES.items():
        rows = page_counts(t, preds, thr)
        pick = rows.values() if arm["pages"] == "all" else [r for r in rows.values() if r["core"] == "A-core"]
        out[rule] = dict(all=summarise(pick),
                         **{g: summarise([r for r in pick if r["core"] == g]) for g in ("A-core", "B-core")})
    return out


def boxes(pages, conf=None):
    """{page: [box]}: PP files hold bare boxes; YOLO files hold {box, cls, conf}, cut at the arm's floor."""
    return {pid: [r if isinstance(r, list) else r["box"] for r in regs
                  if conf is None or isinstance(r, list) or r["conf"] >= conf]
            for pid, regs in pages.items()}


def sweep(t, pages):
    """Recall and precision over the pooled core at each confidence floor, both match rules."""
    out = []
    for c in SWEEP:
        row = dict(conf=c)
        for rule, thr in RULES.items():
            s = summarise(page_counts(t, boxes(pages, c), thr).values())
            row[rule] = dict(recall=s["recall"], precision=s["precision"], predictions=s["predictions"])
        out.append(row)
    return out


def detect_pp(t):
    sys.path.insert(0, str(HERE))
    import layout
    from PIL import Image
    model = layout.load_model()
    store = {"model": layout.MODEL_ID, "pages": {}}
    for pid in t:
        im = Image.open(IMAGES / f"{pid}.jpg")
        im.draft("RGB", (1024, 1024))
        store["pages"][pid] = model.detect(im.convert("RGB"))
    WORK.mkdir(parents=True, exist_ok=True)
    (WORK / "pp-raw.json").write_text(json.dumps(store))
    split(store)


def split(store):
    """The raw regions as one prediction file per PP arm."""
    for key in ("pp", "pp-any"):
        labels = ARMS[key]["labels"]
        keep = {pid: [[x / 1000 for x in r["bbox"]] for r in regs if labels is None or r["label"] in labels]
                for pid, regs in store["pages"].items()}
        (WORK / ARMS[key]["file"]).write_text(json.dumps(dict(model=store["model"], pages=keep)))
        print(f"{key}: {len(keep)} pages, {sum(map(len, keep.values()))} boxes")


def pct(c):
    if not c or c["rate"] is None:
        return "–"
    ci = f" ({c['ci'][0] * 100:.0f}-{c['ci'][1] * 100:.0f})" if c["ci"] else ""
    return f"{c['found']}/{c['of']} = {c['rate'] * 100:.0f}%{ci}"


def markdown(t, res):
    n = sum(len(p["marks"]) for p in t.values())
    L = ["# Marks detection on the owner core (W46.marks-detect)", "",
         f"Truth: {len(t)} detector-eligible owner-core pages, {n} rough boxes "
         f"(`marks_detect.py report`; every figure is in `marks-detect.json`). Recall, found/of with a 95% page "
         "bootstrap interval; matching is one to one and class-agnostic.", ""]
    for rule, label in (("hit", "loose hit, IoU >= 0.1"), ("iou50", "IoU >= 0.5, the filed rule")):
        L += [f"## Recall, {label}", "",
              "| Detector | All | A-core | B-core | Touching print | Clear of print | Boxes emitted | Precision |",
              "|---|---|---|---|---|---|---:|---|"]
        for key, r in res.items():
            s = r["score"][rule]
            a = s["all"]
            prec = "–" if key == "pp-any" or a["precision"] is None else f"{a['precision'] * 100:.0f}%"
            L.append(f"| {r['name']} | {pct(a['recall'])} | {pct((s['A-core'] or {}).get('recall'))} | "
                     f"{pct((s['B-core'] or {}).get('recall'))} | {pct(a['touching_print'])} | "
                     f"{pct(a['clear_of_print'])} | {a['predictions']} | {prec} |")
        L.append("")
    for key, r in res.items():
        if "sweep" not in r:
            continue
        L += [f"## {r['name'].split(' (')[0]}: confidence sweep", "",
              "| Floor | Recall, hit | Precision, hit | Recall, IoU 0.5 | Precision, IoU 0.5 | Boxes |",
              "|---:|---|---:|---|---:|---:|"]
        for w in r["sweep"]:
            h, f = w["hit"], w["iou50"]
            pr = lambda v: "–" if v is None else f"{v * 100:.0f}%"
            L.append(f"| {w['conf']} | {pct(h['recall'])} | {pr(h['precision'])} | {pct(f['recall'])} | "
                     f"{pr(f['precision'])} | {h['predictions']} |")
        L.append("")
    L += ["## Truth support by class", "", "| Class | Boxes | Touching print |", "|---|---:|---:|"]
    by = {}
    for p in t.values():
        for m in p["marks"]:
            b = by.setdefault(m["cls"], [0, 0])
            b[0] += 1
            b[1] += m["overlaps"]
    L += [f"| {c} | {b[0]} | {b[1]} |" for c, b in sorted(by.items())] + [""]
    L += Path(HERE / "marks_detect_notes.md").read_text().splitlines() if (HERE / "marks_detect_notes.md").exists() else []
    return "\n".join(L) + "\n"


def pack(t, out):
    """The Sherlock pack: the 32 evaluation images (the freeze's copies, hash-recorded), the cluster scripts and a
    copy of the Sherlock support files. No truth box, label or text leaves the Mac."""
    import hashlib
    import shutil
    out = Path(out)
    if out.exists():
        raise SystemExit(f"{out} exists")
    (out / "eval" / "images").mkdir(parents=True)
    images = {}
    for pid in t:
        dest = out / "eval" / "images" / f"{pid}.jpg"
        shutil.copyfile(IMAGES / f"{pid}.jpg", dest)
        images[pid] = hashlib.sha256(dest.read_bytes()).hexdigest()
    (out / "eval" / "pages.json").write_text(json.dumps(sorted(t)) + "\n")
    src = HERE / "sherlock" / "marks-detect"
    for f in ("marks_detect_cluster.py", "setup-job.sh", "job.sh", "submit.sh"):
        shutil.copy2(src / f, out / f)
    sup = out / "support" / "sherlock"
    sup.mkdir(parents=True)
    shutil.copy2(HERE / "sherlock" / "sh.env", sup / "sh.env")
    shutil.copytree(HERE / "sherlock" / "bin", sup / "bin")
    code = {f: hashlib.sha256((out / f).read_bytes()).hexdigest()
            for f in ("marks_detect_cluster.py", "setup-job.sh", "job.sh", "submit.sh")}
    (out / "freeze.json").write_text(json.dumps(dict(tag="W46.marks-detect", pack=out.name, record=str(RECORD),
                                                     images=images, code_sha256=code), indent=1) + "\n")
    (out / "README.md").write_text(
        f"# W46.marks-detect — a YOLO11m marks detector trained on AnnoPage and SignverOD\n\n"
        f"Submit only from an owner-started Sherlock session:\n\n    bash <pack>/submit.sh <pack>\n\n"
        f"Three jobs: CPU setup (overlay, AnnoPage 5 GB, SignverOD, dataset), a one-epoch pilot, the training "
        f"(stopped at 6 hours). {len(t)} evaluation pages.\n"
        f"Results: `$GROUP_HOME/$USER/archive-suite/sherlock-results/{out.name}/`.\n"
        "Size and necessity review: `execution-plans/items/W46.marks-detect.md` in the repo.\n")
    print(f"pack {out}: {len(t)} pages")


def main(argv):
    t = truth()
    if argv == ["detect", "pp"]:
        detect_pp(t)
        return 0
    if len(argv) == 3 and argv[:2] == ["pack", "--out"]:
        pack(t, argv[2])
        return 0
    if argv == ["split", "pp"]:
        split(json.loads((WORK / "pp-raw.json").read_text()))
        return 0
    if argv == ["report"]:
        res = {}
        for key, arm in ARMS.items():
            f = WORK / arm["file"]
            if f.exists():
                pages = json.loads(f.read_text())["pages"]
                res[key] = dict(name=arm["name"], pages=arm["pages"],
                                score=score(t, boxes(pages, arm.get("conf")), arm))
                if arm.get("sweep", "conf" in arm):
                    res[key]["sweep"] = sweep(t, pages)
        (RESULTS / "marks-detect.json").write_text(json.dumps(res, indent=1) + "\n")
        (RESULTS / "marks-detect.md").write_text(markdown(t, res))
        print(json.dumps({k: v["score"]["hit"]["all"]["recall"] for k, v in res.items()}))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
