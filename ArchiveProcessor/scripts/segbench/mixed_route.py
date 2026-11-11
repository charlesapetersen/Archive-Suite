#!/usr/bin/env python3
"""Whole page against region-routed reading on mixed pages: the Mac half of W46.mixed-route.

  <lab venv>/bin/python mixed_route.py pages                         # the 32 pages, sized for the whole-page readers
  heavy-run.py run -- <lab venv>/bin/python mixed_route.py whole vision   # Apple Vision (segbench-ocr) on each page
  heavy-run.py run -- <lab venv>/bin/python mixed_route.py whole lighton  # LightOnOCR-3 4B 8-bit (mlx-vlm), whole page
  heavy-run.py run -- <lab venv>/bin/python mixed_route.py whole lighton-rerun  # the same again: the read-to-read floor
  heavy-run.py run -- <lab venv>/bin/python mixed_route.py lines     # per-line ink signals on Vision's line boxes
  <lab venv>/bin/python mixed_route.py pack                          # the Sherlock pack (GLM-OCR, Qwen3.6-27B)
  <lab venv>/bin/python mixed_route.py report                        # segbench-results/mixed-route.{json,md}

The pages are the 32 detector-eligible pages of the owner's marks core and the marks are its 35 owner-reviewed texts,
the same set marks_read.py reads from crops (W46.marks-detect). The question for the text layer is whether a reader
given the whole page gets a mark's words, or whether the mark has to be found and read as its own region.

Whole-page mark score: each mark's text against the closest stretch of the reader's page text (rapidfuzz's partial
alignment finds the stretch; NES is 1 - Levenshtein / longer length on that stretch, NFKC, whitespace collapsed, case
kept; read at NES >= 0.8, as marks_read.py), and the share of the mark's words found anywhere in the page text. A
short mark can match the print by chance (a typed date, a name in the letterhead), so the same score is taken against
every OTHER page's text: that is the floor a whole-page figure has to clear. Region-routed: marks_read.py's crop
readings of the same marks from the owner's boxes (the oracle) and YOLO11m's boxes, re-scored here so the rows pair.

Per-line kind: there is no per-line kind label in the owner core and no Azure flags (dropped 2026-10-31: no key), so a
Vision line is labelled by its overlap with the owner's mark boxes: handwritten when at least half its box lies in an
annotation, marginal note or signature box, typed when under a tenth lies in any mark box, and left out otherwise
(stamps and "other" marks are neither). The boxes are rough drafts the owner checked, so the label is approximate
at the edges. The signal is kind-signals.swift's ink periodicity, per line, on every line (that script took lines of
15 characters or more; marks are short, so both cuts are reported). Page-bootstrap AUC.
Texts and readings stay in the private cache; the report holds aggregates only. No network, no money.
"""
from __future__ import annotations

import json
import random
import shutil
import subprocess
import sys
import time
from pathlib import Path

import marks_detect as D
import marks_read as R

WORK = Path.home() / "Library/Caches/ArchiveSuiteRehearsal/mixed-route"
PAGES = WORK / "pages"
LINES = Path.home() / "Library/Caches/ArchiveSuiteRehearsal/layout-order-marks/vision"
RESULTS = D.RESULTS
MAX_SIDE = 2048           # ocr_mac_local.HW["lightonocr-3-4b-mlx8"]["max_side"]
HAND = {"annotation", "marginal_note", "signature_initials"}
WHOLE = {"vision": "Apple Vision, whole page (the app's settings)",
         "lighton": "LightOnOCR-3 4B 8-bit, whole page (mlx-vlm, Mac)",
         "glm": "GLM-OCR, whole page (Sherlock)",
         "qwen27": "Qwen3.6-27B, whole page (Sherlock)"}
REGION = {"vision": "Apple Vision", "lighton": "LightOnOCR-3 4B 8-bit", "glm": "GLM-OCR (Sherlock)",
          "qwen27": "Qwen3.6-27B (Sherlock)"}
# MRK-1 (P10-2): the B-core was drawn from Qwen3.6-27B's pre-flag, so it is ranked on the A-core alone.
PREFLAGGED = {"qwen27"}
CORES = ("A-core", "B-core")


def page_ids():
    todo, allm = R.marks()
    return sorted(allm), todo, allm


# ---------------------------------------------------------------- pages and readers

def pages():
    from PIL import Image
    PAGES.mkdir(parents=True, exist_ok=True)
    ids, _, _ = page_ids()
    for pid in ids:
        dest = PAGES / f"{pid}.png"
        if dest.exists():
            continue
        im = Image.open(D.IMAGES / f"{pid}.jpg").convert("RGB")
        k = MAX_SIDE / max(im.size)
        if k < 1:
            im = im.resize((round(im.size[0] * k), round(im.size[1] * k)), Image.LANCZOS)
        im.save(dest)
    print(f"{len(ids)} pages in {PAGES}")


def whole_vision():
    # Vision reads the freeze's own 2,400 px copy, as it read the crops.
    out = WORK / "whole" / "vision"
    out.mkdir(parents=True, exist_ok=True)
    ids, _, _ = page_ids()
    jobs = WORK / "vision-jobs.tsv"
    jobs.write_text("".join(f"{D.IMAGES / (p + '.jpg')}\t{out / (p + '.txt')}\n" for p in ids))
    t0 = time.time()
    import vision_guard
    vision_guard.run(R.OCR_BIN, jobs)
    (WORK / "whole" / "vision-wall.json").write_text(json.dumps(dict(pages=len(ids), wall_s=round(time.time() - t0, 1))))
    print(f"vision: {time.time() - t0:.1f} s for {len(ids)} pages")


def whole_lighton(name="lighton"):
    """name="lighton-rerun" reads the 32 pages again into their own folder: the read-to-read floor (W46.marks-two-pass)."""
    import os
    import ocr_mac_local as L  # first: it calls model_store.use() before huggingface_hub is imported
    import mlx.core as mx
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    spec = L.HW["lightonocr-3-4b-mlx8"]
    os.environ["HF_HUB_OFFLINE"] = "1"
    out = WORK / "whole" / name
    out.mkdir(parents=True, exist_ok=True)
    ids, _, _ = page_ids()
    todo = [p for p in ids if not (out / f"{p}.json").exists()]
    print(f"{name}: {len(todo)} pages to read", flush=True)
    if not todo:
        return
    mx.set_cache_limit(256 * 2**20)
    model, processor = load(str(spec["repo"]), trust_remote_code=True)
    chat = apply_chat_template(processor, model.config, spec["prompt"], num_images=1)
    cap = spec["max_tokens"]
    for p in todo:
        start = time.time()
        text, last = [], None
        for r in stream_generate(model, processor, chat, image=[str(PAGES / f"{p}.png")], max_tokens=cap,
                                 temperature=0.0):
            text.append(r.text)
            last = r
        (out / f"{p}.json").write_text(json.dumps(dict(
            text="".join(text).strip(), wall_s=round(time.time() - start, 2),
            finish="length" if last is not None and last.generation_tokens >= cap else "stop")))
        print(f"{name}: {p} {time.time() - start:.0f} s", flush=True)


PACK = "mixed-route-20261105"
SH_SCRATCH = "/scratch/users/cp1/fs-ocr"          # $FS_ROOT on Sherlock (sherlock/sh.env)
ARTIFACT = Path.home() / ".local/state/archive-autonomous/artifacts" / PACK   # the pack; out/ comes back into it
ROUTES_FROM = Path.home() / "Library/Caches/ArchiveSuiteRehearsal/sherlock-results/regions-20261021/routes.json"
CLUSTER_ROUTES = {"glm": "glm-ocr", "qwen27": "qwen3.6-27b"}
GROW = R.PAD - 0.004      # regions_cluster pads a box by 0.004 of the page; this brings it to marks_read's 1%
SUPPORT_FILES = {"mixed-route": ("submit.sh", "job.sh", "stage-job.sh"), "": ("sh.env", "bin/py", "bin/vllm")}


def sha256(f):
    import hashlib
    return hashlib.sha256(Path(f).read_bytes()).hexdigest()


def grown(box):
    return [max(0.0, box[0] - GROW), max(0.0, box[1] - GROW), min(1.0, box[2] + GROW), min(1.0, box[3] + GROW)]


def pack(out=ARTIFACT):
    """The Sherlock pack: the 32 pages' 2,400 px freeze copies, whole and as mark crops, for GLM-OCR and Qwen3.6-27B."""
    out = Path(out).resolve()
    if (out / "freeze.json").exists():
        raise SystemExit(f"{out} is already frozen; a new pack needs a new name")
    ids, todo, _ = page_ids()
    plan = R.plan()
    (out / "images").mkdir(parents=True, exist_ok=True)
    rows = []
    for pid in ids:
        dest = out / "images" / f"{pid}.jpg"
        shutil.copyfile(D.IMAGES / f"{pid}.jpg", dest)
        rows.append(dict(id=pid, image=f"{SH_SCRATCH}/{out.name}/images/{pid}.jpg", sha256=sha256(dest),
                         set="marks-core", stratum=None))
    (out / "pages.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
    src = json.loads(ROUTES_FROM.read_text())
    (out / "routes.json").write_text(json.dumps({r: src[r] for r in CLUSTER_ROUTES.values()}, indent=2) + "\n")
    regions = {"whole": {pid: [dict(label="page", order=1, score=1.0, box=[0.0, 0.0, 1.0, 1.0])] for pid in ids}}
    for arm, boxes in plan.items():
        got = {pid: [] for pid in ids}
        for pid, i, _ in todo:
            b = boxes[f"{pid}#{i}"]
            if b is not None:
                got[pid].append(dict(label=f"{pid}#{i}", order=len(got[pid]) + 1, score=1.0, box=grown(b)))
        regions[arm] = got
    (out / "regions").mkdir(exist_ok=True)
    for arm, pages_ in regions.items():
        (out / "regions" / f"{arm}.json").write_text(json.dumps(dict(detector=arm, pages=pages_)) + "\n")
    here = Path(__file__).resolve().parent
    code = (here / "corpus/regions_cluster.py", here / "corpus/layout_photo_cluster.py",
            here / "sherlock/mixed-route/mixed_route_cluster.py")
    for f in code:
        shutil.copyfile(f, out / f.name)
    for d, files in SUPPORT_FILES.items():
        for f in files:
            dest = out / "support" / (d or "sherlock") / f
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(here / "sherlock" / d / f, dest)
    crops = {arm: sum(len(v) for v in pg.values()) for arm, pg in regions.items()}
    freeze = dict(tag="W46.mixed-route", pack=out.name, readers=list(CLUSTER_ROUTES.values()), pages=len(ids),
                  marks=len(todo), crops=crops, requests_per_route=sum(crops.values()),
                  code_sha256={f.name: sha256(out / f.name) for f in code},
                  regions_sha256={f.name: sha256(f) for f in sorted((out / "regions").glob("*.json"))},
                  pages_sha256=sha256(out / "pages.jsonl"))
    (out / "freeze.json").write_text(json.dumps(freeze, indent=1) + "\n")
    (out / "README.md").write_text(
        "# W46.mixed-route — GLM-OCR and Qwen3.6-27B on mixed pages, whole and by mark\n\n"
        "Submit only from an owner-started Sherlock session:\n\n    bash <pack>/support/mixed-route/submit.sh <pack>\n\n"
        f"Three jobs: CPU stage, GLM-OCR, Qwen3.6-27B. {sum(crops.values())} requests a reader ({len(ids)} pages "
        "whole, the rest mark crops). The images are private corpus page copies: $GROUP_HOME and scratch only.\n"
        f"Results: `$GROUP_HOME/$USER/archive-suite/sherlock-results/{out.name}/`.\n"
        "Size and necessity review: `execution-plans/items/W46.mixed-route.md` in the repo.\n")
    print(json.dumps(crops), freeze["requests_per_route"], "requests a reader ->", out)


def receipt_text(route, rec):
    """A receipt's reading as the open sweep scores it (farmshare_results.reading, the route's recorded mode)."""
    sys.path.insert(0, str(Path(__file__).resolve().parent / "corpus"))
    import loop_rerun as L
    return L.X.reading(rec, L.ROUTES[route]["mode"])


def receipts(reader, arm, pid):
    d = ARTIFACT / "out" / CLUSTER_ROUTES[reader] / arm / pid
    return [json.loads(f.read_text()) for f in sorted(d.glob("[0-9][0-9][0-9].json"))] if d.is_dir() else None


def whole_text(reader, pid):
    d = WORK / "whole" / reader
    if reader == "vision":
        f = d / f"{pid}.txt"
        return f.read_text() if f.exists() else None
    if reader in CLUSTER_ROUTES:
        recs = receipts(reader, "whole", pid)
        return receipt_text(CLUSTER_ROUTES[reader], recs[0]) if recs else None
    f = d / f"{pid}.json"
    return json.loads(f.read_text())["text"] if f.exists() else None


def cluster_crop(reader, arm, mid):
    """The cluster reader's text for a mark's crop in an arm: None when not collected, '' when it read nothing.
    A mark with no box in a detector arm has no receipt and reads as nothing."""
    if not (ARTIFACT / "out" / CLUSTER_ROUTES[reader] / arm).is_dir():
        return None
    recs = receipts(reader, arm, mid.split("#")[0]) or []
    hit = [r for r in recs if r.get("label") == mid]
    return receipt_text(CLUSTER_ROUTES[reader], hit[0]) if hit else ""


# ---------------------------------------------------------------- per-line ink signals

def periodicity(g, x0, x1, y0, y1):
    """kind-signals.swift's periodicity(): the line's column ink profile autocorrelated at its strongest lag between
    0.3 and 0.9 line heights, and at twice that lag."""
    import numpy as np
    H, W = g.shape
    xa, xb, ya, yb = max(0, int(x0)), min(W, int(x1)), max(0, int(y0)), min(H, int(y1))
    line_h = yb - ya
    if xb - xa <= 40 or line_h < 8:
        return None
    p = (255.0 - g[ya:yb, xa:xb]).sum(axis=0)
    p = p - p.mean()
    r0 = float((p * p).sum())
    if r0 <= 0:
        return None

    def r(k):
        return float((p[:-k] * p[k:]).sum()) / r0 if 0 < k < len(p) else 0.0
    lo = max(2, int(0.3 * line_h))
    hi = max(lo + 1, int(0.9 * line_h))
    best = max(range(lo, hi + 1), key=r)
    return r(best), r(2 * best)


def inside(a, b):
    """Share of box a's area inside box b."""
    w = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    h = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    area = max(1e-12, (a[2] - a[0]) * (a[3] - a[1]))
    return w * h / area


def lines():
    import numpy as np
    from PIL import Image
    ids, _, allm = page_ids()
    rows = []
    for pid in ids:
        v = json.loads((LINES / f"{pid}.json").read_text())
        g = np.asarray(Image.open(D.IMAGES / f"{pid}.jpg").convert("L"), dtype=np.float64)
        H, W = g.shape
        if (W, H) != (v["width"], v["height"]):
            raise SystemExit(f"{pid}: Vision lines are {v['width']}x{v['height']}, the image {W}x{H}")
        for ln in v["lines"]:
            b = ln["box"]
            hand = max([inside(b, m["box"]) for m in allm[pid] if m["cls"] in HAND] or [0.0])
            anym = max([inside(b, m["box"]) for m in allm[pid]] or [0.0])
            label = "hand" if hand >= 0.5 else "typed" if anym < 0.1 else None
            per = periodicity(g, b[0] * W, b[2] * W, b[1] * H, b[3] * H)
            rows.append(dict(page=pid, label=label, chars=len(ln["text"].strip()),
                             height=round((b[3] - b[1]) * H, 1), width=round((b[2] - b[0]) * W, 1),
                             periodic=None if per is None else round(per[0], 4),
                             harmonic=None if per is None else round(per[1], 4)))
    (WORK / "lines.json").write_text(json.dumps(rows))
    print(f"{len(rows)} lines; hand {sum(r['label'] == 'hand' for r in rows)}, "
          f"typed {sum(r['label'] == 'typed' for r in rows)}")


# ---------------------------------------------------------------- marks in the text layer

LAYER_BIN = WORK / "bin" / "mixed-route-layer"
FORMS = {"none": "no marks (the control)", "run": "a labelled invisible run at the mark's box", "annot": "a FreeText annotation over the box",
         "textpage": "a text page after the image"}


def spotlight_text(pdf):
    """The text Spotlight's PDF importer takes from a file: `mdimport -t -d3` (test mode, nothing is indexed)."""
    import re
    p = subprocess.run(["/usr/bin/mdimport", "-t", "-d3", str(pdf)], capture_output=True, text=True, timeout=120)
    m = re.search(r'kMDItemTextContent = "(.*?)";\n', p.stdout + p.stderr, re.S)
    if not m:
        return ""
    s = re.sub(r"\\U([0-9a-fA-F]{4})", lambda u: chr(int(u.group(1), 16)), m.group(1))
    return s.replace("\\n", " ").replace('\\"', '"').replace("\\\\", "\\")


def layer(limit=0):
    if not LAYER_BIN.exists():
        raise SystemExit(f"build it first: swiftc -O mixed_route_layer.swift -o {LAYER_BIN}")
    ids, todo, allm = page_ids()
    ids = ids[:limit] if limit else ids
    out = {}
    for pid in ids:
        v = json.loads((LINES / f"{pid}.json").read_text())
        marks = [dict(id=f"{pid}#{i}", box=m["box"], text=m["text"], cls=m["cls"]) for p, i, m in todo if p == pid]
        d = WORK / "layer" / pid
        d.mkdir(parents=True, exist_ok=True)
        spec = d / "spec.json"
        spec.write_text(json.dumps(dict(image=str(D.IMAGES / f"{pid}.jpg"), lines=v["lines"], marks=marks)))
        subprocess.run([str(LAYER_BIN), "write", str(spec), str(d)], check=True)
        got = json.loads(subprocess.run([str(LAYER_BIN), "check", str(spec), str(d)], check=True,
                                        capture_output=True, text=True).stdout)
        for form in FORMS:
            sp = R.norm(spotlight_text(d / f"{form}.pdf")).lower()
            for row, m in zip(got[form], marks):
                row["spotlight"] = bool(R.norm(m["text"])) and R.norm(m["text"]).lower() in sp
        out[pid] = got
    (WORK / "layer.json").write_text(json.dumps(out))
    print(json.dumps({form: {k: sum(r[k] for g in out.values() for r in g[form])
                             for k in ("found", "placed", "selected", "extracted", "spotlight")} for form in FORMS}),
          sum(len(g["run"]) for g in out.values()), "marks")


# ---------------------------------------------------------------- scoring

def mark_in_page(truth, page):
    """(NES on the closest stretch, share of the mark's words anywhere in the page)."""
    from rapidfuzz import fuzz
    t, h = R.norm(truth), R.norm(page)
    if not t:
        return 1.0, 1.0
    if not h:
        return 0.0, 0.0
    al = fuzz.partial_ratio_alignment(t, h)
    stretch = h[al.dest_start:al.dest_end] if al is not None else ""
    words = set(h.split())
    tw = t.split()
    return R.nes(t, stretch), sum(w in words for w in tw) / len(tw)


def auc(pos, neg):
    if not pos or not neg:
        return None
    s = sum((p > n) + 0.5 * (p == n) for p in pos for n in neg)
    return s / (len(pos) * len(neg))


def boot_pages(rows, stat, n=2000, seed=46):
    by = {}
    for r in rows:
        by.setdefault(r["page"], []).append(r)
    pages = list(by)
    rng = random.Random(seed)
    vals = []
    for _ in range(n):
        v = stat([r for _ in pages for r in by[pages[rng.randrange(len(pages))]]])
        if v is not None:
            vals.append(v)
    vals.sort()
    return [round(vals[int(0.025 * len(vals))], 3), round(vals[int(0.975 * len(vals)) - 1], 3)] if vals else None


def score_whole(todo, text):
    ids, _, _ = page_ids()
    out = {}
    for reader in WHOLE:
        got = {pid: whole_text(reader, pid) for pid in ids}
        if any(v is None for v in got.values()):
            missing = sum(v is None for v in got.values())
            out[reader] = dict(missing=missing)
            continue
        rows, null = [], []
        for pid, i, _ in todo:
            mid = f"{pid}#{i}"
            v, wr = mark_in_page(text[mid], got[pid])
            rows.append(dict(page=pid, mark=mid, nes=v, words=wr))
            others = [mark_in_page(text[mid], got[q]) for q in ids if q != pid]
            null.append(dict(page=pid, mark=mid, read_share=sum(o[0] >= R.READ for o in others) / len(others),
                             nes_max=max(o[0] for o in others), words_mean=sum(o[1] for o in others) / len(others)))
        out[reader] = dict(rows=rows, null=null)
    return out


def score_region(todo, text):
    plan = R.plan()
    out = {}
    for reader in REGION:
        for arm, boxes in plan.items():
            rows = []
            for pid, i, _ in todo:
                mid = f"{pid}#{i}"
                box = boxes[mid]
                if reader in CLUSTER_ROUTES:
                    hyp = cluster_crop(reader, arm, mid)
                    if hyp is None:
                        break      # not collected yet: the arm is left out of the report
                else:
                    hyp = "" if box is None else R.reading(reader, pid, box)
                    if hyp is None:
                        raise SystemExit(f"{reader}/{arm}: crop for {mid} not read (marks_read.py read {reader})")
                rows.append(dict(page=pid, mark=mid, nes=R.nes(text[mid], hyp)))
            else:
                out[f"{reader}/{arm}"] = rows
    return out


# ---------------------------------------------------------------- two passes: whole page plus a region pass

def sign_p(b, c):
    """Exact two-sided sign test on b against c discordant marks."""
    from math import comb
    n = b + c
    if n == 0:
        return 1.0
    k = min(b, c)
    return min(1.0, 2 * sum(comb(n, i) for i in range(k + 1)) / 2 ** n)


COORDS = r"bbox|<loc_?\d|<\|box|<\|ref|\[\s*\d+(\.\d+)?\s*,\s*\d+(\.\d+)?\s*,\s*\d+(\.\d+)?\s*,\s*\d+(\.\d+)?\s*\]"


def two_pass(todo, text, whole, region, core):
    """W46.marks-two-pass (pass 11 P11-1). A detector would add a region pass beside the whole page, and the text
    layer can carry both readings, so its ceiling is the union: a mark is read when either reading reads it. A union
    cannot lose a mark, so the gains are set against an irrelevant second reading: the same reader's crop of a
    DIFFERENT mark on the same page (in the same arm), which tests what doubled text buys by chance. A missed mark
    counts as a floor gain when any such crop reads it at NES >= 0.8; a mark alone on its page has no same-page crop
    and gets none, so the other pages' crops are given as a rate too. The sign test pairs the real gain against the
    floor gain on each mark the whole page missed."""
    out = {}
    pages = {}
    for pid, i, _ in todo:
        pages.setdefault(pid, []).append(f"{pid}#{i}")
    plans = R.plan()
    for key, rows in region.items():
        reader, arm = key.split("/")
        w = whole.get(reader, {})
        if "rows" not in w:
            continue
        wn = {r["mark"]: r["nes"] for r in w["rows"]}
        crop = {r["mark"]: r["nes"] for r in rows}
        hyp = {}
        for mid in crop:
            box = plans[arm][mid]
            if reader in CLUSTER_ROUTES:
                hyp[mid] = cluster_crop(reader, arm, mid) or ""
            else:
                hyp[mid] = "" if box is None else (R.reading(reader, mid.split("#")[0], box) or "")
        missed = [m for m in wn if wn[m] < R.READ]
        gain = {m: crop[m] >= R.READ for m in missed}
        same_pairs = same_hits = far_pairs = far_hits = 0
        floor = {}
        for m in missed:
            pid = m.split("#")[0]
            hits = [R.nes(text[m], hyp[o]) >= R.READ for o in pages[pid] if o != m and hyp[o].strip()]
            same_pairs += len(hits)
            same_hits += sum(hits)
            floor[m] = any(hits)
            far = [R.nes(text[m], hyp[o]) >= R.READ for o in crop if o.split("#")[0] != pid and hyp[o].strip()]
            far_pairs += len(far)
            far_hits += sum(far)
        b = sum(gain[m] and not floor[m] for m in missed)
        c = sum(floor[m] and not gain[m] for m in missed)
        by_core = {}
        for g in CORES:
            ms = [m for m in wn if core[m.split("#")[0]] == g]
            by_core[g] = dict(n=len(ms), whole=sum(wn[m] >= R.READ for m in ms),
                              union=sum(wn[m] >= R.READ or crop[m] >= R.READ for m in ms),
                              floor=sum(floor.get(m, False) for m in ms))
        out[key] = dict(n=len(wn), whole=len(wn) - len(missed), region=sum(v >= R.READ for v in crop.values()),
                        union=sum(wn[m] >= R.READ or crop[m] >= R.READ for m in wn), gains=sum(gain.values()),
                        floor_gains=sum(floor.values()),
                        no_partner=sum(len(pages[m.split("#")[0]]) == 1 for m in missed), missed=len(missed),
                        same_pairs=same_pairs, same_hits=same_hits, far_pairs=far_pairs, far_hits=far_hits,
                        sign_p=round(sign_p(b, c), 4), by_core=by_core)
    return out


def rerun_floor(todo, text, core):
    """LightOnOCR-3 4B read the 32 pages twice, whole page, at temperature 0: the second reading as the union's
    partner is the read-to-read floor under the box's gains."""
    d1, d2 = WORK / "whole" / "lighton", WORK / "whole" / "lighton-rerun"
    ids, _, _ = page_ids()
    if not all((d2 / f"{p}.json").exists() for p in ids):
        return None
    t1 = {p: json.loads((d1 / f"{p}.json").read_text())["text"] for p in ids}
    t2 = {p: json.loads((d2 / f"{p}.json").read_text())["text"] for p in ids}
    a = {f"{p}#{i}": mark_in_page(text[f"{p}#{i}"], t1[p])[0] >= R.READ for p, i, _ in todo}
    b = {f"{p}#{i}": mark_in_page(text[f"{p}#{i}"], t2[p])[0] >= R.READ for p, i, _ in todo}
    walls = sorted(json.loads((d2 / f"{p}.json").read_text())["wall_s"] for p in ids)
    return dict(pages=len(ids), identical_pages=sum(t1[p] == t2[p] for p in ids),
                read_first=sum(a.values()), read_second=sum(b.values()),
                first_only=sum(a[m] and not b[m] for m in a), second_only=sum(b[m] and not a[m] for m in a),
                union=sum(a[m] or b[m] for m in a), median_s=walls[len(walls) // 2],
                by_core={g: sum((a[m] or b[m]) for m in a if core[m.split("#")[0]] == g) for g in CORES})


def placement(todo, text, whole):
    """Which whole-page replies can be placed in the layer without a box. Vision returns a box per line; a mark it
    read whole page is placed when the lines meeting the mark's own box (LINES: Vision at the same settings on the
    same copy) read it. The VLM replies are searched for any coordinate syntax."""
    import re
    ids, _, _ = page_ids()
    oracle = R.plan()["oracle"]
    out = {}
    if "rows" in whole.get("vision", {}):
        lines_ = {p: json.loads((LINES / f"{p}.json").read_text())["lines"] for p in ids}
        same = sum(R.norm(" ".join(ln["text"] for ln in lines_[p])) == R.norm(whole_text("vision", p)) for p in ids)
        reads = [r for r in whole["vision"]["rows"] if r["nes"] >= R.READ]
        placed = sum(mark_in_page(text[r["mark"]], " ".join(
            ln["text"] for ln in lines_[r["page"]] if inside(ln["box"], oracle[r["mark"]]) > 0))[0] >= R.READ
                     for r in reads)
        out["vision"] = dict(read=len(reads), placed=placed, pages_same_text=same, pages=len(ids))
    for reader in ("lighton", "glm", "qwen27"):
        got = [whole_text(reader, p) for p in ids]
        if "rows" not in whole.get(reader, {}) or any(g is None for g in got):
            continue
        out[reader] = dict(read=sum(r["nes"] >= R.READ for r in whole[reader]["rows"]), placed=0, replies=len(got),
                           with_coordinates=sum(bool(re.search(COORDS, g)) for g in got))
    return out


def summary(rows, core):
    read = lambda rs: sum(r["nes"] >= R.READ for r in rs) / len(rs) if rs else None
    mean = lambda rs: sum(r["nes"] for r in rs) / len(rs) if rs else None
    s = dict(n=len(rows), read=sum(r["nes"] >= R.READ for r in rows), read_ci=boot_pages(rows, read),
             mean_nes=round(mean(rows), 3), mean_ci=boot_pages(rows, mean))
    s["by_core"] = {g: dict(n=len(rs), pages=len({r["page"] for r in rs}), read=sum(r["nes"] >= R.READ for r in rs),
                            mean_nes=round(mean(rs), 3) if rs else None)
                    for g in CORES for rs in [[r for r in rows if core[r["page"]] == g]]}
    return s


def report():
    todo = R.marks()[0]
    text = {f"{pid}#{i}": m["text"] for pid, i, m in todo}
    cls = {f"{pid}#{i}": m["cls"] for pid, i, m in todo}
    whole = score_whole(todo, text)
    region = score_region(todo, text)
    core = {pid: p["core"] for pid, p in D.truth().items()}
    res = dict(whole={}, region={}, paired={}, lines=None)
    for reader, w in whole.items():
        if "rows" not in w:
            res["whole"][reader] = dict(missing=w["missing"])
            continue
        s = summary(w["rows"], core)
        s["words_mean"] = round(sum(r["words"] for r in w["rows"]) / len(w["rows"]), 3)
        s["null_read_mean"] = round(sum(r["read_share"] for r in w["null"]) / len(w["null"]), 4)
        s["null_marks_any"] = sum(r["nes_max"] >= R.READ for r in w["null"])
        s["read_also_elsewhere"] = sum(r["nes"] >= R.READ and n["nes_max"] >= R.READ for r, n in zip(w["rows"], w["null"]))
        s["null_words_mean"] = round(sum(r["words_mean"] for r in w["null"]) / len(w["null"]), 3)
        s["by_class"] = {c: dict(n=sum(cls[r["mark"]] == c for r in w["rows"]),
                                 read=sum(cls[r["mark"]] == c and r["nes"] >= R.READ for r in w["rows"]))
                         for c in sorted(set(cls.values()))}
        if reader == "lighton":
            walls = [json.loads(f.read_text()) for f in (WORK / "whole" / "lighton").glob("*.json")]
            s["median_s"] = sorted(x["wall_s"] for x in walls)[len(walls) // 2]
            s["length_capped"] = sum(x["finish"] == "length" for x in walls)
        res["whole"][reader] = s
    for key, rows in region.items():
        s = summary(rows, core)
        s["by_class"] = {c: dict(n=sum(cls[r["mark"]] == c for r in rows),
                                 read=sum(cls[r["mark"]] == c and r["nes"] >= R.READ for r in rows))
                         for c in sorted(set(cls.values()))}
        res["region"][key] = s
    # Paired: the same reader whole page against the owner's box, and the best whole page against the best crop.
    for reader in REGION:
        w = whole.get(reader, {})
        if "rows" not in w or f"{reader}/oracle" not in region:
            continue
        crop = {r["mark"]: r for r in region[f"{reader}/oracle"]}
        both = [(r["nes"] >= R.READ, crop[r["mark"]]["nes"] >= R.READ) for r in w["rows"]]
        res["paired"][reader] = dict(whole_only=sum(a and not b for a, b in both),
                                     crop_only=sum(b and not a for a, b in both),
                                     both=sum(a and b for a, b in both), neither=sum(not a and not b for a, b in both))
    res["two_pass"] = two_pass(todo, text, whole, region, core)
    res["rerun"] = rerun_floor(todo, text, core)
    res["placement"] = placement(todo, text, whole)
    lf = WORK / "lines.json"
    if lf.exists():
        res["lines"] = score_lines(json.loads(lf.read_text()))
    yf = WORK / "layer.json"
    if yf.exists():
        got = json.loads(yf.read_text())
        res["layer"] = {form: {k: sum(r[k] for g in got.values() for r in g[form])
                               for k in ("found", "placed", "selected", "extracted", "spotlight")}
                        for form in FORMS}
        res["layer_marks"] = sum(len(g["run"]) for g in got.values())
    (RESULTS / "mixed-route.json").write_text(json.dumps(res, indent=1) + "\n")
    (RESULTS / "mixed-route.md").write_text(markdown(res, len(todo)))
    print(json.dumps({k: (v.get("read"), v.get("n")) for k, v in res["whole"].items()}))


def score_lines(rows):
    out = {}
    for cut, keep in (("all", lambda r: True), ("15+", lambda r: r["chars"] >= 15)):
        sel = [r for r in rows if r["label"] and keep(r)]
        withp = [r for r in sel if r["periodic"] is not None]
        o = dict(hand=sum(r["label"] == "hand" for r in sel), typed=sum(r["label"] == "typed" for r in sel),
                 measured_hand=sum(r["label"] == "hand" for r in withp),
                 measured_typed=sum(r["label"] == "typed" for r in withp),
                 pages_with_hand=len({r["page"] for r in sel if r["label"] == "hand"}))
        for sig in ("periodic", "harmonic"):
            # Typed lines repeat, so a high value says typed: the AUC is P(typed line > handwritten line).
            st = lambda rs, s=sig: auc([r[s] for r in rs if r["label"] == "typed" and r[s] is not None],
                                       [r[s] for r in rs if r["label"] == "hand" and r[s] is not None])
            v = st(withp)
            o[sig] = dict(auc=None if v is None else round(v, 3), ci=boot_pages(withp, st))
        st = lambda rs: auc([-r["height"] for r in rs if r["label"] == "typed"],
                            [-r["height"] for r in rs if r["label"] == "hand"])
        v = st(sel)
        o["height"] = dict(auc=None if v is None else round(v, 3), ci=boot_pages(sel, st))
        out[cut] = o
    out["unlabelled"] = sum(r["label"] is None for r in rows)
    out["lines"] = len(rows)
    return out


def pct(k, n):
    return f"{k} of {n}"


def ci(c, scale=100, fmt="{:.0f}"):
    return "" if not c else f" ({fmt.format(c[0] * scale)}-{fmt.format(c[1] * scale)}{'%' if scale == 100 else ''})"


def markdown(res, n):
    L = ["# Whole page against region-routed reading on mixed pages (W46.mixed-route)", "",
         f"The {n} owner-reviewed mark texts on the 32 detector-eligible pages of the owner's marks core, the set "
         "`marks_read.py` reads from crops (`mixed_route.py`; figures in `mixed-route.json`). A whole-page reader's "
         "mark is scored on the closest stretch of its page text; *read* is NES >= 0.8. The floor is the same score "
         "against the other 31 pages' text (all 32 were read): a mark \"read\" there is chance agreement with print. Intervals: 95% page "
         "bootstrap.", "", "## Marks: whole page and by region", "",
         "| Route | Read | Mean NES | Mark words found | Floor: read on another page |",
         "|---|---|---|---:|---|"]
    flag = lambda reader: " ‡" if reader in PREFLAGGED else ""
    for reader, s in res["whole"].items():
        if "missing" in s:
            L.append(f"| {WHOLE[reader]} | not run yet ({s['missing']} pages missing) | | | |")
            continue
        L.append(f"| {WHOLE[reader]}{flag(reader)} | {pct(s['read'], s['n'])}{ci(s['read_ci'])} | {s['mean_nes']:.2f}"
                 f"{ci(s['mean_ci'], 1, '{:.2f}')} | {s['words_mean'] * 100:.0f}% | "
                 f"{s['null_read_mean'] * 100:.1f}% a page; {s['null_marks_any']} marks on at least one, "
                 f"{s['read_also_elsewhere']} of them among its reads |")
    for key, s in res["region"].items():
        reader, arm = key.split("/")
        L.append(f"| {REGION[reader]}, {R.ARM_NAMES[arm]}{flag(reader)} | {pct(s['read'], s['n'])}{ci(s['read_ci'])} | "
                 f"{s['mean_nes']:.2f}{ci(s['mean_ci'], 1, '{:.2f}')} | | |")
    if any(r in PREFLAGGED and "n" in s for r, s in res["whole"].items()):
        L += ["", "‡ Not ranked on all 35 (MRK-1): the B-core pages were drawn from Qwen3.6-27B's own pre-flag, so its "
              "B-core figures are chosen by its own pre-flag, and it is ranked on the A-core alone, below, which is "
              "too few marks to rank."]
    if res["paired"]:
        L += ["", "The same reader, whole page against the owner's box (marks read):", "",
              "| Reader | Both | Whole page only | Box only | Neither |", "|---|---:|---:|---:|---:|"]
        for reader, p in res["paired"].items():
            L.append(f"| {REGION[reader]}{flag(reader)} | {p['both']} | {p['whole_only']} | {p['crop_only']} | {p['neither']} |")
    if res.get("two_pass"):
        L += ["", "## Two passes: the whole page plus a region pass (W46.marks-two-pass)", "",
              "A detector would add a region pass beside the whole page, and the text layer can carry both readings, "
              "so its ceiling is the union: a mark is read when either reading reads it. A union cannot lose a mark, "
              "so each gain is set against an irrelevant second reading: the same reader's crop of a different mark on "
              "the same page, from the same boxes (a crop that read nothing is left out). *Floor* counts the marks the "
              "whole page missed that such a crop reads at 0.8; the sign test (exact, two-sided) pairs each missed "
              "mark's real gain against its floor gain. A mark alone on its page has no same-page crop; the other "
              "pages' crops are given as a rate.", "",
              "| Reader | Second pass | Whole page | Region alone | Union | Gains | Floor | Sign test p | "
              "Same-page crops that read the mark | Other pages' crops | A-core: whole, union | B-core: whole, union |",
              "|---|---|---:|---:|---:|---:|---:|---:|---|---|---|---|"]
        for key, t in res["two_pass"].items():
            reader, arm = key.split("/")
            a, b = t["by_core"]["A-core"], t["by_core"]["B-core"]
            L.append(f"| {REGION[reader]}{flag(reader)} | {R.ARM_NAMES[arm]} | {t['whole']} | {t['region']} | "
                     f"{t['union']} | +{t['gains']} | {t['floor_gains']} | {t['sign_p']:.3g} | "
                     f"{t['same_hits']} of {t['same_pairs']} | {t['far_hits']} of {t['far_pairs']} | "
                     f"{a['whole']}, {a['union']} of {a['n']} | {b['whole']}, {b['union']} of {b['n']} |")
        rr = res.get("rerun")
        if rr:
            L += ["", f"Read-to-read floor: LightOnOCR-3 4B read the {rr['pages']} pages whole a second time at the same "
                  f"settings (temperature 0). {rr['identical_pages']} of {rr['pages']} replies are identical; it reads "
                  f"{rr['read_first']} and {rr['read_second']} marks, {rr['first_only']} only the first time and "
                  f"{rr['second_only']} only the second, so the whole page read twice gives {rr['union']} of 35 "
                  f"(A-core {rr['by_core']['A-core']}, B-core {rr['by_core']['B-core']}), against "
                  f"{res['two_pass']['lighton/oracle']['union']} with the owner's box as the second reading. Median "
                  f"{rr['median_s']} s a page."]
        pl = res.get("placement")
        if pl:
            v = pl.get("vision")
            L += ["", "Placing a whole-page reading in the layer: the working form is an invisible run at the mark's box, "
                  "so a mark read whole page needs coordinates."]
            if v:
                L.append(f"Apple Vision returns a box with each line: of its {v['read']} whole-page reads, {v['placed']} "
                         "are read again from the lines meeting the mark's own box, so they can be placed without a "
                         f"detector (its line file and whole-page text agree on {v['pages_same_text']} of {v['pages']} "
                         "pages).")
            vl = [f"{WHOLE[r].split(',')[0]} ({p['read']} reads; {p['with_coordinates']} of {p['replies']} replies "
                  "with any coordinate)" for r, p in pl.items() if r != "vision"]
            if vl:
                L.append("The VLM replies are plain text with no coordinates: " + "; ".join(vl) + ". A mark they read "
                         "whole page cannot be placed on the page without a box from somewhere else.")
    rows = [(f"{WHOLE[r]}", r, s) for r, s in res["whole"].items() if "by_core" in s]
    rows += [(f"{REGION[k.split('/')[0]]}, owner's box", k.split("/")[0], s) for k, s in res["region"].items()
             if k.endswith("/oracle")]
    if rows:
        a, b = rows[0][2]["by_core"]["A-core"], rows[0][2]["by_core"]["B-core"]
        L += ["", f"By core (MRK-1): the A-core, drawn independently of any reader ({a['n']} marks on {a['pages']} "
              f"pages), and the B-core, drawn from Qwen3.6-27B's pre-flag bands ({b['n']} marks on {b['pages']} pages). "
              "Marks read, mean NES:", "", "| Route | A-core | B-core |", "|---|---|---|"]
        for name, reader, s in rows:
            g = s["by_core"]
            cell = lambda c: f"{pct(c['read'], c['n'])}, {c['mean_nes']:.2f}"
            tail = " (too few to rank)" if reader in PREFLAGGED else ""
            btail = " (chosen by its own pre-flag)" if reader in PREFLAGGED else ""
            L.append(f"| {name} | {cell(g['A-core'])}{tail} | {cell(g['B-core'])}{btail} |")
    first = next((s for s in res["whole"].values() if "by_class" in s), None)
    if first:
        classes = list(first["by_class"])
        L += ["", "Read, by class:", "", "| Route | " + " | ".join(classes) + " |", "|---|" + "---:|" * len(classes)]
        for reader, s in res["whole"].items():
            if "by_class" in s:
                L.append(f"| {WHOLE[reader]} | " + " | ".join(pct(v["read"], v["n"]) for v in s["by_class"].values()) + " |")
        for key in (f"{r}/oracle" for r in REGION):
            s = res["region"].get(key)
            if s is None:
                continue
            L.append(f"| {REGION[key.split('/')[0]]}, owner's box | " +
                     " | ".join(pct(v["read"], v["n"]) for v in s["by_class"].values()) + " |")
    lt = res["whole"].get("lighton", {})
    if "median_s" in lt:
        L += ["", f"LightOnOCR-3 4B took a median {lt['median_s']} s a page on the M3 Pro (an engine session's timing, "
              f"so an upper bound); {lt['length_capped']} of 32 pages hit its 4,096-token cap."]
    ln = res["lines"]
    if ln:
        L += ["", "## Per-line kind from Vision's line boxes", "",
              f"{ln['lines']} Vision lines on the 32 pages; {ln['unlabelled']} left unlabelled (partly in a mark box, "
              "or in a stamp or \"other\" box). AUC is the chance a typed line scores above a handwritten one.", "",
              "| Lines | Handwritten | Typed | Pages with a handwritten line | Periodicity AUC | Harmonic AUC | "
              "Line height AUC |", "|---|---:|---:|---:|---|---|---|"]
        for cut, name in (("all", "every line"), ("15+", "15 characters or more")):
            o = ln[cut]
            f = lambda d: "n/a" if d["auc"] is None else f"{d['auc']:.2f}{ci(d['ci'], 1, '{:.2f}')}"
            L.append(f"| {name} | {o['hand']} ({o['measured_hand']} measured) | {o['typed']} ({o['measured_typed']} "
                     f"measured) | {o['pages_with_hand']} | {f(o['periodic'])} | {f(o['harmonic'])} | {f(o['height'])} |")
    if res.get("layer"):
        k = res["layer_marks"]
        L += ["", "## Marks in the text layer", "",
              f"The same {k} marks written into a scratch PDF of each page (the page image, Vision's lines as the body's "
              "invisible text; `mixed_route_layer.swift`). *Found*: PDFKit `findString`, case-insensitive, the call the "
              "Reader's Find makes; *placed*: a hit on the image page that meets the mark's box; *selected*: a drag over "
              "the box selects the text; *extracted*: in `PDFDocument.string`; *Spotlight*: in the text Spotlight's PDF "
              "importer takes (`mdimport -t`, nothing indexed). The control row has no marks: what it finds is the print "
              "agreeing with a mark.", "",
              "| Form | Found | Placed | Selected | Extracted | Spotlight |", "|---|---:|---:|---:|---:|---:|"]
        for form, name in FORMS.items():
            v = res["layer"][form]
            L.append(f"| {name} | " + " | ".join(f"{v[c]} of {k}" for c in
                                                ("found", "placed", "selected", "extracted", "spotlight")) + " |")
    notes = Path(__file__).resolve().parent / "mixed_route_notes.md"
    if notes.exists():
        L += [""] + notes.read_text().splitlines()
    return "\n".join(L) + "\n"


def main(argv):
    if argv == ["pages"]:
        pages()
    elif argv == ["whole", "vision"]:
        whole_vision()
    elif argv == ["whole", "lighton"]:
        whole_lighton()
    elif argv == ["whole", "lighton-rerun"]:
        whole_lighton("lighton-rerun")
    elif argv == ["lines"]:
        lines()
    elif argv == ["pack"]:
        pack()
    elif argv[:1] == ["layer"] and len(argv) <= 2:
        layer(int(argv[1]) if len(argv) == 2 else 0)
    elif argv == ["report"]:
        report()
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
