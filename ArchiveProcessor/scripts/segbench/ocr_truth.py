#!/usr/local/bin/python3
"""W41.ocr-truth: a transcription truth set for Archive Processor, drawn from across the corpus.

    ocr_truth.py index              # tags of every collection-folder PDF + the originals' names -> cache
    ocr_truth.py calibrate          # pixel size, sharpness and year-taken cut points from a random sample
    ocr_truth.py draw               # the ~100 pages: copied to scratch, measured, Vision word count checked
    ocr_truth.py ladder             # ~20 of them also at half and a quarter of their pixel size
    ocr_truth.py draft-claude       # Claude Opus 5.5 through `claude -p` (subscription, $0)
    ocr_truth.py draft-gemini       # Gemini 3.8 Flash through OpenRouter (paid, capped at CAP_USD)
    ocr_truth.py compare            # agreed text, the disputed spans, the review sheet, the summary
    ocr_truth.py apply ANSWERS.json # the owner's answers -> truth/<page>.txt and pages.tsv (W41.ocr-adjudicate)

READ ONLY on the corpus (``CORPUS``) and on the originals (``ORIGINALS``). The calls that touch them are
``os.scandir``, ``getxattr(2)`` for the Finder tags, ``os.stat``, ``sips -g`` (reads a size), and reading a
file to copy it, convert it (``sips ... --out <scratch>``) or extract a PDF's image (``pdfimages ... <scratch>``).
Everything written goes under ``CACHE`` (outside git); the committed result is aggregate numbers only,
``ArchiveProcessor/segbench-results/ocr-truth.md``, because the repo is public and the pages are the owner's.

THE DRAW RULE — written before the draw was run, and not changed after (seed ``SEED``):
  * Pool: the PDFs in the collection folders, i.e. every top-level folder of the corpus whose name does not
    start with a digit (the six numbered workflow folders are left out: partial tags, copies awaiting
    conversion). A collection is the top-level folder; a folder is the directory that holds the PDFs.
    Photos tagged Red or Purple are box/folder label photos and are left out (corpus_survey's rule).
  * Documents: each PDF is one photo, so a document is implied by the tags (corpus_survey): a run of
    consecutive page photos with the same identity tags (every tag but Unread, Read, Processed and the
    colours), a label photo ending the run. A run longer than LONG_RUN photos is a folder tagged per
    collection, which says nothing about where its documents begin, so it is cut into blocks of BLOCK photos,
    each counted as one document. A document gives at most one page, chosen at random.
  * Tag strata: the date bin from the year or decade tags (the earliest when there are several): before
    1900, 1900-1949, 1950-1984, 1985 on, else undated ("Date Uncertain" or no date tag); and three kinds:
    handwritten (tag Handwritten), clippings (Clippings), tables (Statistics, Salary Data; forms are found by
    the drafting models' TABLE label).
  * Order of the draw: (1) one page from every collection with at least COVER_MIN files; (2) each stratum,
    smallest pool first, topped up to STRATUM_MIN pages; (3) the rest, to TOTAL, from all documents. Every
    pick: at most FOLDER_MAX pages per folder and COLLECTION_MAX per collection; CANDIDATES documents drawn
    at random from those eligible, each prepared (copied, measured, Vision OCR), any under MIN_WORDS words
    replaced (covers, photographs, blanks, as Vision OCR's truth set did), and of the rest the one whose
    photo attributes are least represented so far is kept (the sum, over pixel tertile, sharpness tertile,
    year-taken tertile and camera, of the pages already drawn sharing that value; ties at random).
  * The image: the original photograph in ``ORIGINALS`` with the PDF's file name (any extension), when
    exactly one exists; otherwise the image inside the PDF, and the row says why. EXIF orientation applied.
  * Photo attributes, measured from the file: pixel size (long side), sharpness (variance of a Laplacian on
    the grey image at 1024 px), the year taken (EXIF DateTimeOriginal, else the file's mtime) and the camera
    (EXIF Make and Model). Tertile cut points come from ``calibrate``'s random sample of originals.
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures as cf
import difflib
import hashlib
import html
import json
import os
import random
import re
import shutil
import subprocess
import sys
import threading
import time
import unicodedata
from pathlib import Path

import corpus_survey as CS

CORPUS = Path.home() / "Desktop/Google Drive/Archival Photos"
ORIGINALS = Path.home() / "Desktop/Google Drive/Archival Photos JPEGS"
CACHE = Path(os.environ.get("OCR_TRUTH_CACHE", Path.home() / "Library/Caches/ArchiveSuiteRehearsal/ocr-truth"))
OCR_BIN = Path.home() / "Library/Caches/ArchiveSuiteRehearsal/segbench/bin/segbench-ocr"
RESULTS = Path(__file__).resolve().parents[2] / "segbench-results" / "ocr-truth.md"

SEED = 41
TOTAL = 100
STRATUM_MIN = 12
COVER_MIN = 30
FOLDER_MAX = 4
COLLECTION_MAX = 8
CANDIDATES = 3
MIN_WORDS = 20
LONG_RUN = 12
BLOCK = 6
LADDER = 20
DRAFT_SIDE = 2400          # px, long side, of the image the drafting models read
ORIG_EXT = {".jpg", ".jpeg", ".heic", ".png", ".tif", ".tiff"}
ID_IGNORED = CS.IGNORED | {"Read", "Processed"}
DECADE = re.compile(r"^(1[5-9]\d0|20\d0)s$")
KIND_TAGS = {"handwritten": {"Handwritten"}, "clippings": {"Clippings"}, "tables": {"Statistics", "Salary Data"}}
DATE_BINS = ("before 1900", "1900-1949", "1950-1984", "1985 on", "undated")

CLAUDE_MODEL = "claude-opus-5-5"
CLAUDE_BIN = "/Users/cp1/.local/bin/claude"
GEMINI_MODEL = ("google/gemini-3.8-flash", "google-ai-studio", "low")   # OpenRouter id, pinned provider, effort
CAP_USD = 1.00
DRAFTERS = {"claude": "Claude Opus 5.5 (claude -p, subscription)", "gemini": "Gemini 3.8 Flash (OpenRouter, Google AI Studio)"}

PROMPT = """This is a photograph of one page from a US archive: a letter, memo, report, form, table, clipping, note or similar.
Transcribe all of its text exactly.

- Every word on the page, in natural reading order (a multi-column page column by column). Include headings, page numbers, stamps, letterheads, and handwritten annotations or marginalia (put each where it falls in the reading order).
- Keep the original spelling, capitalisation, punctuation, hyphenation and line breaks. Do not correct, expand, modernise or summarise.
- A word you cannot read, or one hidden or cut off: write [illegible]. Leave out empty checkboxes and other symbols that are not text.
- A table: one row per line, cells separated by " | ".
- Leave out text from a neighbouring page that shows at the edge of the photograph, and anything that is not on the document itself (an archive's copyright slip, a ruler, a label on the table).
- No commentary and no Markdown formatting.

Answer in exactly this form and nothing else:
KIND: <printed, typewritten, handwritten or mixed: the writing of the page's main text; mixed when no one kind covers most of it>
TABLE: <yes if the page is mostly a table or a form with fields, else no>
TEXT:
<the transcription>"""


# ---------------------------------------------------------------- tags, documents, strata

def date_bin(tags) -> str:
    ys = [int(t) for t in tags if CS.YEAR.match(t)] or [int(t[:4]) for t in tags if DECADE.match(t)]
    if not ys:
        return "undated"
    y = min(ys)
    return "before 1900" if y < 1900 else "1900-1949" if y < 1950 else "1950-1984" if y < 1985 else "1985 on"


def kinds(tags) -> list[str]:
    s = set(tags)
    return [k for k, v in KIND_TAGS.items() if s & v]


def strata(tags) -> list[str]:
    return [date_bin(tags)] + kinds(tags)


def is_label(tags) -> bool:
    return bool(set(tags) & CS.LABEL_COLOURS)


def documents(folder: str, photos) -> list[list]:
    """photos: [(name, tags)] in capture order -> documents, each [(name, tags)] (the rule in the header)."""
    runs, cur, cur_id = [], [], None
    for name, tags in photos:
        if is_label(tags):
            if cur:
                runs.append(cur)
            cur, cur_id = [], None
            continue
        ident = frozenset(t for t in tags if t not in ID_IGNORED)
        if cur and ident != cur_id:
            runs.append(cur)
            cur = []
        cur.append((name, tags))
        cur_id = ident
    if cur:
        runs.append(cur)
    out = []
    for r in runs:
        if len(r) > LONG_RUN:
            out.extend(r[i:i + BLOCK] for i in range(0, len(r), BLOCK))
        else:
            out.append(r)
    return out


def collection_folders():
    for e in sorted(os.scandir(CORPUS), key=lambda e: e.name):
        if e.is_dir(follow_symlinks=False) and not e.name.startswith(".") and not e.name[:1].isdigit():
            yield e.name


# ---------------------------------------------------------------- index

def cmd_index(_):
    CACHE.mkdir(parents=True, exist_ok=True)
    folders = []
    for coll in collection_folders():
        for rel, pdfs in CS.walk(str(CORPUS / coll)):
            rel = coll if rel == "." else os.path.join(coll, rel)
            folders.append({"folder": rel, "collection": coll,
                            "photos": [(p, CS.read_tags(str(CORPUS / rel / p))) for p in pdfs]})
    originals = collections.defaultdict(list)
    for d, _, files in os.walk(ORIGINALS):
        for f in files:
            stem, ext = os.path.splitext(f)
            if ext.lower() in ORIG_EXT and not f.startswith("."):
                originals[stem].append(os.path.relpath(os.path.join(d, f), ORIGINALS))
    (CACHE / "index.json").write_text(json.dumps({"folders": folders, "originals": originals}))
    n = sum(len(f["photos"]) for f in folders)
    one = sum(1 for f in folders for p, _ in f["photos"] if len(originals.get(Path(p).stem, [])) == 1)
    print(f"{len(folders)} folders, {n} PDFs, {sum(map(len, originals.values()))} originals; "
          f"{one} PDFs with exactly one original")


def load_index():
    return json.loads((CACHE / "index.json").read_text())


# ---------------------------------------------------------------- one page: copy, measure, OCR

def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def source_of(folder, name, originals):
    stem = Path(name).stem
    m = originals.get(stem, [])
    if len(m) == 1:
        return "original", ORIGINALS / m[0]
    return ("pdf image (no original)" if not m else f"pdf image ({len(m)} originals)"), CORPUS / folder / name


def pdf_page(pdf: Path):
    """(width, height) in points of page 1 as displayed (its /Rotate applied), and its largest image's long side."""
    info = sh(["/opt/homebrew/bin/pdfinfo", "-f", "1", "-l", "1", str(pdf)]).stdout
    m = re.search(r"Page\s+1 size:\s*([\d.]+) x ([\d.]+)", info) or re.search(r"Page size:\s*([\d.]+) x ([\d.]+)", info)
    w, h = (float(m.group(1)), float(m.group(2))) if m else (0.0, 0.0)
    rot = re.search(r"Page\s+1 rot:\s*(\d+)", info) or re.search(r"Page rot:\s*(\d+)", info)
    if rot and int(rot.group(1)) % 180:
        w, h = h, w
    rows = [x.split() for x in sh(["/opt/homebrew/bin/pdfimages", "-list", "-f", "1", "-l", "1", str(pdf)]).stdout.splitlines()[2:]]
    rows = [r for r in rows if len(r) > 13 and r[2] in ("image", "stencil")]   # stencil: a bilevel scan's layers
    ppi = max((int(r[12]) for r in rows if r[12].isdigit()), default=0)
    return w, h, max((max(int(r[3]), int(r[4])) for r in rows), default=0), ppi


def orient_like_pdf(im, pdf: Path, tmp: Path):
    """The turn (degrees counter-clockwise) that makes `im` look most like the PDF's page 1, and its correlation.

    Each of the four turns is shrunk to a small grey render of the page and compared by correlation. (Apple
    Vision's word count was tried first and picked upside-down turns: it reads rotated text too.)"""
    import numpy as np
    from PIL import Image
    r = sh(["/opt/homebrew/bin/pdftoppm", "-f", "1", "-l", "1", "-scale-to", "160", "-gray", "-singlefile",
            str(pdf), str(tmp / "ref")])
    ref_p = tmp / "ref.pgm"
    if r.returncode or not ref_p.exists():
        return 0, 0.0
    with Image.open(ref_p) as ref:
        ref = ref.convert("L")
        size = ref.size
        a = np.asarray(ref, dtype=np.float32).ravel()
    a = (a - a.mean()) / (a.std() + 1e-6)
    small = im.convert("L")
    small.thumbnail((640, 640))
    best = (0, -2.0)
    for deg in (0, 90, 180, 270):
        b = np.asarray(small.rotate(deg, expand=True).resize(size, Image.BILINEAR), dtype=np.float32).ravel()
        b = (b - b.mean()) / (b.std() + 1e-6)
        c = float((a * b).mean())
        if c > best[1]:
            best = (deg, c)
    return best


def extract(kind, src: Path, out: Path, pdf: Path | None = None):
    """The page's full-resolution image as a JPEG under the cache.

    An original: EXIF orientation applied, then turned to match the PDF's page, since some originals were
    photographed sideways or upside down and only the PDF was rotated (``orient_like_pdf``).
    No original: page 1 of the PDF rendered at its largest image's resolution (a PDF can hold several image
    layers, so the page, not one layer, is the image)."""
    from PIL import Image, ImageOps
    tmp = out.parent / (out.stem + ".tmp")
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)
    try:
        meta = {"taken": None, "camera": None, "rotated": 0}
        if kind == "original":
            raw = tmp / "raw.jpg"
            if src.suffix.lower() in (".jpg", ".jpeg"):
                shutil.copyfile(src, raw)
            else:
                r = sh(["/usr/bin/sips", "-s", "format", "jpeg", "-s", "formatOptions", "95", str(src), "--out", str(raw)])
                if r.returncode or not raw.exists():
                    raise RuntimeError(f"sips: {r.stderr[-200:]}")
            with Image.open(raw) as im:
                exif = im.getexif()
                sub = exif.get_ifd(0x8769)
                meta["taken"] = str(sub.get(36867) or exif.get(306) or "") or None
                meta["camera"] = " ".join(str(exif.get(t) or "").strip() for t in (271, 272)).strip() or None
                im2 = ImageOps.exif_transpose(im).convert("RGB")
            if pdf is not None:
                deg, corr = orient_like_pdf(im2, pdf, tmp)
                meta["rotated"], meta["orient_corr"] = deg, round(corr, 3)
                im2.rotate(deg, expand=True).save(out, "JPEG", quality=92)
            else:
                im2.save(out, "JPEG", quality=92)
        else:
            pw, ph, side, ppi = pdf_page(src)
            if not pw or not side:
                raise RuntimeError("pdf: no page size or no image")
            # the images' own resolution; a page of several small layers is not one image's size
            dpi = max(72, min(600, ppi or round(side / (max(pw, ph) / 72))))
            r = sh(["/opt/homebrew/bin/pdftoppm", "-f", "1", "-l", "1", "-r", str(dpi), "-jpeg", "-jpegopt", "quality=92",
                    "-singlefile", str(src), str(tmp / "page")])
            if r.returncode or not (tmp / "page.jpg").exists():
                raise RuntimeError(f"pdftoppm: {r.stderr[-200:]}")
            shutil.move(tmp / "page.jpg", out)
            meta["dpi"] = dpi
        with Image.open(out) as im:
            meta["width"], meta["height"] = im.size
        return meta
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def sharpness(path: Path) -> float:
    import numpy as np
    from PIL import Image
    with Image.open(path) as im:
        g = im.convert("L")
        g.thumbnail((1024, 1024))
        a = np.asarray(g, dtype=np.float32)
    lap = a[1:-1, 1:-1] * 4 - a[:-2, 1:-1] - a[2:, 1:-1] - a[1:-1, :-2] - a[1:-1, 2:]
    return float(lap.var())


def vision_words(path: Path) -> int:
    out = path.with_suffix(".vision.txt")
    if not out.exists():
        jobs = path.with_suffix(".jobs.tsv")
        jobs.write_text(f"{path}\t{out}\n")
        sh([str(OCR_BIN), str(jobs)], timeout=300)
        jobs.unlink(missing_ok=True)
    return len(re.findall(r"[A-Za-z0-9]{2,}", out.read_text())) if out.exists() else 0


def prepare(folder, name, tags, originals) -> dict:
    """Copy one page to scratch and measure it; cached by its corpus path."""
    key = hashlib.sha256(f"{folder}/{name}".encode()).hexdigest()[:16]
    mpath = CACHE / "prep" / f"{key}.json"
    if mpath.exists():
        rec = json.loads(mpath.read_text())
        if "error" not in rec:
            return rec
    mpath.parent.mkdir(parents=True, exist_ok=True)
    kind, src = source_of(folder, name, originals)
    img = CACHE / "prep" / f"{key}.jpg"
    try:
        meta = extract(kind, src, img, CORPUS / folder / name)
    except Exception as e:  # noqa: BLE001 — recorded, the page is passed over
        rec = {"key": key, "error": str(e)[:300]}
    else:
        year = None
        if meta["taken"] and re.match(r"^\d{4}", meta["taken"]):
            year = int(meta["taken"][:4])
        else:
            year = time.localtime(src.stat().st_mtime).tm_year
            meta["taken_from"] = "mtime"
        rec = {"key": key, "folder": folder, "name": name, "tags": tags, "source": kind,
               "source_path": str(src.relative_to(ORIGINALS if kind == "original" else CORPUS)),
               "long_side": max(meta["width"], meta["height"]), "year_taken": year,
               "sharpness": round(sharpness(img), 1), "words": vision_words(img), **meta}
    mpath.write_text(json.dumps(rec))
    return rec


# ---------------------------------------------------------------- calibrate

def cmd_calibrate(_):
    """Cut points for the photo tertiles, from a random sample of originals (sizes 600, sharpness 150)."""
    idx = load_index()
    rng = random.Random(SEED + 1)
    paths = sorted(p for v in idx["originals"].values() for p in v)
    sample = rng.sample(paths, 600)
    sides = []
    for i in range(0, len(sample), 50):
        r = sh(["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight"] + [str(ORIGINALS / p) for p in sample[i:i + 50]])
        w = h = None
        for line in r.stdout.splitlines():
            if "pixelWidth" in line:
                w = int(line.split()[-1])
            elif "pixelHeight" in line:
                h = int(line.split()[-1])
                if w:
                    sides.append(max(w, h))
                w = None
    sharp, years = [], []
    tmp = CACHE / "calibrate"
    tmp.mkdir(parents=True, exist_ok=True)
    for i, p in enumerate(sample[:150]):
        out = tmp / f"{i:03d}.jpg"
        try:
            meta = extract("original", ORIGINALS / p, out)
        except Exception:  # noqa: BLE001
            continue
        sharp.append(sharpness(out))
        y = meta["taken"][:4] if meta["taken"] else None
        years.append(int(y) if y and y.isdigit() else time.localtime((ORIGINALS / p).stat().st_mtime).tm_year)
        out.unlink()
    def terts(v):
        v = sorted(v)
        return [v[len(v) // 3], v[2 * len(v) // 3]]
    cal = {"long_side": terts(sides), "sharpness": terts(sharp), "year_taken": terts(years),
           "n": {"long_side": len(sides), "sharpness": len(sharp), "year_taken": len(years)}}
    (CACHE / "calibrate.json").write_text(json.dumps(cal, indent=1))
    print(json.dumps(cal))


def tertile(v, cuts) -> int:
    """Low, middle, high. When both cut points are one value (most originals are 2592 px, one iPad camera),
    the middle is that value: below it, it, above it."""
    if cuts[0] == cuts[1]:
        return 0 if v < cuts[0] else 1 if v == cuts[0] else 2
    return 0 if v < cuts[0] else 1 if v < cuts[1] else 2


def attrs(rec, cal) -> dict:
    return {"px": tertile(rec["long_side"], cal["long_side"]), "sharp": tertile(rec["sharpness"], cal["sharpness"]),
            "year": tertile(rec["year_taken"], cal["year_taken"]), "camera": rec.get("camera") or "?"}


# ---------------------------------------------------------------- draw

def cmd_draw(_):
    idx = load_index()
    cal = json.loads((CACHE / "calibrate.json").read_text())
    originals = idx["originals"]
    rng = random.Random(SEED)
    docs, files_per_coll = [], collections.Counter()
    for f in idx["folders"]:
        files_per_coll[f["collection"]] += len(f["photos"])
        for d in documents(f["folder"], f["photos"]):
            docs.append({"id": f"{f['folder']}#{d[0][0]}", "folder": f["folder"], "collection": f["collection"],
                         "pages": d, "strata": strata(d[0][1])})
    pool = collections.Counter(s for d in docs for s in d["strata"])
    chosen, replaced, failed, used = [], [], [], set()
    per_folder, per_coll = collections.Counter(), collections.Counter()
    seen = collections.Counter()   # attribute value -> pages drawn with it

    def eligible(d):
        return d["id"] not in used and per_folder[d["folder"]] < FOLDER_MAX and per_coll[d["collection"]] < COLLECTION_MAX

    def pick(cands, why, stratum=None):
        cands = [d for d in cands if eligible(d)]
        rng.shuffle(cands)
        got = []
        for d in cands:
            if len(got) == CANDIDATES:
                break
            used.add(d["id"])
            pages = d["pages"] if stratum is None else [p for p in d["pages"] if stratum in strata(p[1])]
            name, tags = rng.choice(pages)
            rec = prepare(d["folder"], name, tags, originals)
            if "error" in rec:
                failed.append({"folder": d["folder"], "name": name, "error": rec["error"]})
                continue
            if rec["words"] < MIN_WORDS:
                replaced.append({"folder": d["folder"], "name": name, "words": rec["words"], "why": why})
                continue
            got.append((d, rec))
        if not got:
            return False
        def score(dr):
            a = attrs(dr[1], cal)
            return sum(seen[(k, v)] for k, v in a.items())
        best = min(score(g) for g in got)
        d, rec = rng.choice([g for g in got if score(g) == best])
        for k, v in attrs(rec, cal).items():
            seen[(k, v)] += 1
        per_folder[d["folder"]] += 1
        per_coll[d["collection"]] += 1
        chosen.append({**rec, "collection": d["collection"], "strata": strata(rec["tags"]), "why": why,
                       "doc_pages": len(d["pages"])})
        return True

    for coll in sorted(c for c, n in files_per_coll.items() if n >= COVER_MIN):
        pick([d for d in docs if d["collection"] == coll], f"cover {coll}")
    for s in sorted(pool, key=lambda s: pool[s]):
        while sum(s in c["strata"] for c in chosen) < STRATUM_MIN:
            if not pick([d for d in docs if s in d["strata"]], f"stratum {s}", s):
                break
    while len(chosen) < TOTAL:
        if not pick(docs, "fill"):
            break
    (CACHE / "pages").mkdir(exist_ok=True)
    for i, c in enumerate(chosen):
        c["page"] = f"p{i + 1:03d}"
        shutil.copyfile(CACHE / "prep" / f"{c['key']}.jpg", CACHE / "pages" / f"{c['page']}.jpg")
    draw = {"seed": SEED, "rule": __doc__.split("THE DRAW RULE")[1], "calibrate": cal, "pool_docs": len(docs),
            "pool_strata": pool, "files_per_collection": files_per_coll, "chosen": chosen,
            "replaced": replaced, "failed": failed}
    (CACHE / "draw.json").write_text(json.dumps(draw, indent=1))
    print(f"{len(chosen)} pages; {len(replaced)} replaced (under {MIN_WORDS} words); {len(failed)} failed")


def load_draw():
    return json.loads((CACHE / "draw.json").read_text())


# ---------------------------------------------------------------- ladder

def cmd_ladder(_):
    from PIL import Image
    draw = load_draw()
    rng = random.Random(SEED + 2)
    cal = draw["calibrate"]
    by_px = collections.defaultdict(list)
    for c in draw["chosen"]:
        by_px[tertile(c["long_side"], cal["long_side"])].append(c["page"])
    picks = []
    for t in (2, 1, 0):  # the largest first: halving a large photo is the question that matters most
        n = LADDER // 3 + (1 if t == 2 and LADDER % 3 else 0) + (1 if t == 1 and LADDER % 3 == 2 else 0)
        picks += rng.sample(sorted(by_px[t]), min(n, len(by_px[t])))
    out = CACHE / "ladder"
    out.mkdir(exist_ok=True)
    for p in picks:
        with Image.open(CACHE / "pages" / f"{p}.jpg") as im:
            for f, tag in ((2, "half"), (4, "quarter")):
                im.resize((im.width // f, im.height // f), Image.LANCZOS).save(out / f"{p}-{tag}.jpg", "JPEG", quality=92)
    (CACHE / "ladder.json").write_text(json.dumps(sorted(picks)))
    print(f"{len(picks)} pages at half and quarter size: {' '.join(sorted(picks))}")


# ---------------------------------------------------------------- drafting

def draft_image(page) -> Path:
    from PIL import Image
    out = CACHE / "draft-img" / f"{page}.jpg"
    if not out.exists():
        out.parent.mkdir(exist_ok=True)
        with Image.open(CACHE / "pages" / f"{page}.jpg") as im:
            im = im.convert("RGB")
            im.thumbnail((DRAFT_SIDE, DRAFT_SIDE), Image.LANCZOS)
            im.save(out, "JPEG", quality=90)
    return out


def parse_draft(raw: str):
    m = re.search(r"KIND:\s*(\w+)\s*\n\s*TABLE:\s*(\w+)\s*\n\s*TEXT:[ \t]*\n?(.*)\Z", raw.strip(), re.S | re.I)
    if not m:
        return None
    kind = m.group(1).lower()
    if kind not in ("printed", "typewritten", "handwritten", "mixed"):
        return None
    text = re.sub(r"^```\w*\n|\n```$", "", m.group(3).strip())
    return {"kind": kind, "table": m.group(2).lower().startswith("y"), "text": text}


_log_lock = threading.Lock()


def log(model, rec):
    with _log_lock:
        with open(CACHE / f"draft-{model}-calls.jsonl", "a") as fh:
            fh.write(json.dumps(rec) + "\n")


def draft_path(model, page):
    return CACHE / "drafts" / model / f"{page}.json"


def run_drafts(model, fn, concurrency):
    pages = [c["page"] for c in load_draw()["chosen"]]
    todo = [p for p in pages if not draft_path(model, p).exists()]
    draft_path(model, "x").parent.mkdir(parents=True, exist_ok=True)
    print(f"{model}: {len(pages) - len(todo)} cached, {len(todo)} to draft")

    def work(p):
        for attempt in range(2):
            raw, meta = fn(p, attempt)
            # a reply cut off by the provider (finish "error" or "length") still parses: it is a failed attempt
            got = parse_draft(raw) if meta.get("finish") in (None, "stop") else None
            log(model, {"page": p, "attempt": attempt, "ok": bool(got), **meta, "t": time.time()})
            if got:
                draft_path(model, p).write_text(json.dumps({**got, "raw": raw, "meta": meta}))
                return p, True
        return p, False

    with cf.ThreadPoolExecutor(concurrency) as ex:
        for p, ok in ex.map(work, todo):
            print(p, "ok" if ok else "FAILED", flush=True)


def claude_call(page, attempt):
    wd = CACHE / "claude-work" / page
    if wd.exists():
        shutil.rmtree(wd)
    wd.mkdir(parents=True)
    shutil.copyfile(draft_image(page), wd / "page.jpg")
    prompt = "Read the image file page.jpg in the current folder with the Read tool, then answer.\n\n" + PROMPT
    env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}
    cmd = [CLAUDE_BIN, "-p", prompt, "--model", CLAUDE_MODEL, "--output-format", "json",
           "--allowedTools", "Read", "--permission-mode", "default", "--no-session-persistence"]
    t0 = time.time()
    r = subprocess.run(cmd, cwd=wd, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=900)
    try:
        out = json.loads(r.stdout)
    except json.JSONDecodeError:
        msg = (r.stdout + r.stderr)[-400:]
        if re.search(r"usage limit|session limit|hit your limit|rate limit|429", msg, re.I):
            raise SystemExit(f"usage limit: {msg}")
        return "", {"error": msg, "wall_s": round(time.time() - t0, 1)}
    return out.get("result") or "", {"wall_s": round(time.time() - t0, 1), "model": CLAUDE_MODEL,
                                     "usage": out.get("usage"), "list_cost_usd": out.get("total_cost_usd")}


def gemini_spent():
    p = CACHE / "draft-gemini-calls.jsonl"
    return sum((json.loads(l).get("cost") or 0) for l in p.read_text().splitlines()) if p.exists() else 0.0


def gemini_call(page, attempt):
    import method_openrouter as OR
    if gemini_spent() >= CAP_USD - 0.03:
        raise SystemExit(f"cap: ${gemini_spent():.3f} spent of ${CAP_USD}")
    model, provider, effort = GEMINI_MODEL
    if attempt:
        # AI Studio ends some pages of reprinted published text with finish "error" and no tokens, every time
        # (two of 100 on 2026-10-14); Google's Vertex endpoint serves the same model and answers them
        provider = "google-vertex"
    body = {"model": model, "temperature": 0, "max_tokens": 16000 if attempt else 8000,
            "messages": [{"role": "user", "content": [
                {"type": "image_url", "image_url": {"url": OR.image_url(draft_image(page), DRAFT_SIDE)}},
                {"type": "text", "text": PROMPT}]}],
            "reasoning": {"effort": effort, "exclude": True}, "usage": {"include": True},
            "provider": {"order": [provider], "allow_fallbacks": False}}
    t0 = time.time()
    j = OR.post(body)
    msg = (j.get("choices") or [{}])[0].get("message") or {}
    u = j.get("usage") or {}
    return msg.get("content") or "", {"wall_s": round(time.time() - t0, 1), "provider": j.get("provider"),
                                      "model": j.get("model"), "prompt_tokens": u.get("prompt_tokens"),
                                      "gen_tokens": u.get("completion_tokens"), "cost": u.get("cost"),
                                      "finish": (j.get("choices") or [{}])[0].get("finish_reason")}


# ---------------------------------------------------------------- compare

QUOTES = str.maketrans({"‘": "'", "’": "'", "‚": "'", "“": '"', "”": '"', "„": '"',
                        "–": "-", "—": "-", "−": "-", " ": " ", "|": " ",
                        **{c: " " for c in "☐☑☒□■○●•"}})


def words(text: str) -> list[str]:
    """Comparison tokens: NFKC, straight quotes and hyphens; table bars, checkboxes, bullets and line breaks
    as spaces."""
    return unicodedata.normalize("NFKC", text).translate(QUOTES).split()


def spans(a: list[str], b: list[str]) -> list[dict]:
    """The two readings as a sequence of agreed and disputed spans (difflib over the words)."""
    out = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if op == "equal":
            out.append({"agreed": " ".join(a[i1:i2])})
        else:
            out.append({"a": " ".join(a[i1:i2]), "b": " ".join(b[j1:j2])})
    return out


def merge(sp: list[dict], answers: dict) -> str | None:
    """Truth text from the spans and the answers ({span index: "a" | "b" | typed text}); None if any is open."""
    parts = []
    for i, s in enumerate(sp):
        if "agreed" in s:
            parts.append(s["agreed"])
            continue
        ans = answers.get(str(i))
        if ans is None:
            return None
        parts.append(s["a"] if ans == "a" else s["b"] if ans == "b" else ans[1:] if ans.startswith("=") else ans)
    return " ".join(p for p in parts if p)


def cmd_compare(_):
    draw = load_draw()
    pages = []
    for c in draw["chosen"]:
        p = c["page"]
        da, db = (json.loads(draft_path(m, p).read_text()) if draft_path(m, p).exists() else None
                  for m in ("claude", "gemini"))
        if not (da and db):
            pages.append({**c, "missing": [m for m, d in (("claude", da), ("gemini", db)) if not d]})
            continue
        wa, wb = words(da["text"]), words(db["text"])
        sp = spans(wa, wb)
        disputed = [s for s in sp if "agreed" not in s]
        pages.append({**c, "spans": sp, "kind": {"claude": da["kind"], "gemini": db["kind"]},
                      "table": {"claude": da["table"], "gemini": db["table"]},
                      "words": {"claude": len(wa), "gemini": len(wb)},
                      "disputed_words": sum(max(len(s["a"].split()), len(s["b"].split())) for s in disputed),
                      "n_disputes": len(disputed), "texts": {"claude": da["text"], "gemini": db["text"]}})
    (CACHE / "compare.json").write_text(json.dumps(pages, indent=1))
    write_review(pages)
    write_summary(draw, pages)
    print(f"review sheet: {CACHE / 'review' / 'index.html'}\nsummary: {RESULTS}")


SECONDS_PER_PAGE = 10      # look at the page, confirm the kind of writing
SECONDS_PER_DISPUTE = 6    # read two short spans against the image, press a key
SECONDS_PER_TYPED = 30     # the share of disputes where neither reading is right and a correction is typed
TYPED_SHARE = 0.15


def review_minutes(pages) -> float:
    n_pages = sum(1 for p in pages if "spans" in p)
    n_disp = sum(p.get("n_disputes", 0) for p in pages)
    return (n_pages * SECONDS_PER_PAGE + n_disp * SECONDS_PER_DISPUTE + n_disp * TYPED_SHARE * SECONDS_PER_TYPED) / 60


def write_review(pages):
    out = CACHE / "review"
    out.mkdir(exist_ok=True)
    data = [{"page": p["page"], "img": f"../pages/{p['page']}.jpg", "collection": p["collection"],
             "spans": p["spans"], "kind": p["kind"], "table": p["table"]} for p in pages if "spans" in p]
    (out / "index.html").write_text(REVIEW_HTML.replace("__DATA__", json.dumps(data))
                                    .replace("__MINUTES__", f"{review_minutes(pages):.0f}"))


REVIEW_HTML = r"""<!doctype html><meta charset="utf-8"><title>W41.ocr-truth review</title>
<style>
body{font:14px -apple-system,sans-serif;margin:0}
header{position:sticky;top:0;background:#fff;border-bottom:1px solid #ccc;padding:6px 12px;z-index:2}
.page{display:flex;gap:12px;border-bottom:3px solid #999;padding:10px;min-height:90vh}
.img{flex:1 1 50%;position:sticky;top:44px;height:88vh;overflow:auto}
.img img{width:100%;cursor:zoom-in}.img img.zoom{width:250%;cursor:zoom-out}
.txt{flex:1 1 50%;white-space:pre-wrap;line-height:1.6;font-family:Georgia,serif}
.d{border:1px solid #c80;border-radius:3px;padding:0 2px;background:#fff4dd}
.d.cur{outline:3px solid #06f}.d.done{background:#e6f6e6;border-color:#4a4}
.opt{font-family:-apple-system,sans-serif;font-size:12px;display:block;margin:2px 0}
.opt.sel{font-weight:bold;color:#060}.k{color:#888}.kind{font-family:-apple-system,sans-serif;margin-bottom:8px}
.kind.cur{outline:3px solid #06f}
</style>
<header><b>Transcription truth review</b> — about __MINUTES__ minutes.
Keys: <b>1</b> Claude's reading · <b>2</b> Gemini's · <b>3</b> type the correct text · <b>n/p</b> next/previous ·
for the kind of writing <b>t</b>ypewritten <b>r</b> printed <b>h</b>andwritten <b>m</b>ixed (<b>Enter</b> keeps the proposal).
Click the image to zoom. Answers are kept in this browser; <button onclick="exportAnswers()">Export answers</button>
<span id="prog"></span></header><div id="root"></div>
<script>
const DATA=__DATA__;const KEY='w41-ocr-truth-answers';
let A=JSON.parse(localStorage.getItem(KEY)||'{}');const items=[];
function esc(s){return s.replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
function save(){localStorage.setItem(KEY,JSON.stringify(A));prog()}
function prog(){const d=items.filter(it=>ans(it)!==undefined).length;document.getElementById('prog').textContent=` ${d} / ${items.length} answered`}
function ans(it){return (A[it.page]||{})[it.key]}
function set(it,v){(A[it.page]=A[it.page]||{})[it.key]=v;save();paint(it)}
function paint(it){const el=it.el,v=ans(it);el.classList.toggle('done',v!==undefined);
 if(it.key==='kind'){el.querySelector('.v').textContent=v||it.proposal+' (proposed)';return}
 el.querySelectorAll('.opt').forEach(o=>o.classList.toggle('sel',o.dataset.v===v||(o.dataset.v==='typed'&&v&&v.startsWith('='))));
 el.querySelector('.typed').textContent=v&&v.startsWith('=')?'typed: '+v.slice(1):''}
const root=document.getElementById('root');
for(const p of DATA){const div=document.createElement('div');div.className='page';
 const prop=p.kind.claude===p.kind.gemini?p.kind.claude:'?';
 let h=`<div class="img"><img src="${p.img}" onclick="this.classList.toggle('zoom')"></div><div class="txt">`+
  `<div class="kind" data-key="kind"><b>${p.page}</b> · ${esc(p.collection)} · kind of writing: <span class="v"></span>`+
  ` <span class="k">(Claude ${p.kind.claude}, Gemini ${p.kind.gemini}; table: ${p.table.claude?'yes':'no'}/${p.table.gemini?'yes':'no'})</span></div>`;
 p.spans.forEach((s,i)=>{if('agreed' in s){h+=esc(s.agreed)+' ';return}
  h+=`<span class="d" data-key="${i}"><span class="opt" data-v="a"><span class="k">1 Claude:</span> ${esc(s.a)||'<i>(nothing)</i>'}</span>`+
   `<span class="opt" data-v="b"><span class="k">2 Gemini:</span> ${esc(s.b)||'<i>(nothing)</i>'}</span><span class="opt typed" data-v="typed"></span></span> `});
 div.innerHTML=h+'</div>';root.appendChild(div);
 div.querySelectorAll('[data-key]').forEach(el=>{const it={page:p.page,key:el.dataset.key,el,proposal:prop};items.push(it);paint(it);
  el.addEventListener('click',()=>go(items.indexOf(it)))})}
let cur=0;function go(i){if(i<0||i>=items.length)return;items[cur].el.classList.remove('cur');cur=i;
 const el=items[cur].el;el.classList.add('cur');el.scrollIntoView({block:'center'})}
function next(){go(cur+1)}
document.addEventListener('keydown',e=>{if(e.target.tagName==='INPUT')return;const it=items[cur];
 const kmap={t:'typewritten',r:'printed',h:'handwritten',m:'mixed'};
 if(e.key==='n')next();else if(e.key==='p')go(cur-1);
 else if(it.key==='kind'){if(kmap[e.key]){set(it,kmap[e.key]);next()}else if(e.key==='Enter'&&it.proposal!=='?'){set(it,it.proposal);next()}}
 else if(e.key==='1'){set(it,'a');next()}else if(e.key==='2'){set(it,'b');next()}
 else if(e.key==='3'){const t=prompt('The correct text for this span (empty = nothing):',it.el.querySelector('[data-v=a]').textContent.replace(/^1 Claude: /,''));
  if(t!==null){set(it,'='+t);next()}}});
function exportAnswers(){const b=new Blob([JSON.stringify(A,null,1)],{type:'application/json'});
 const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='ocr-truth-answers.json';a.click()}
prog();go(0);
</script>"""


# ---------------------------------------------------------------- the committed summary

def pct(k, n):
    return f"{100 * k / n:.0f}%" if n else "-"


def write_summary(draw, pages):
    ch = draw["chosen"]
    cal = draw["calibrate"]
    L = ["# W41.ocr-truth — the transcription truth set", "",
         f"Drawn {time.strftime('%Y-%m-%d')} by `ArchiveProcessor/scripts/segbench/ocr_truth.py` (seed {draw['seed']}), "
         "read only on `Archival Photos` and `Archival Photos JPEGS`. The pages, their table, both drafts and the "
         "review sheet are outside git, under `~/Library/Caches/ArchiveSuiteRehearsal/ocr-truth/`; this file holds "
         "numbers only. The draw's rule is in the script's header, fixed before the draw ran.", "",
         f"**Drafted by two models, so the truth leans toward them:** {DRAFTERS['claude']} and {DRAFTERS['gemini']}. "
         "Where their readings agree word for word (after straightening quotes and dashes and ignoring line "
         "breaks and table bars) the agreed text stands; every other span goes to the owner.", "",
         "## The draw", "",
         f"{len(ch)} pages, one per document, from {len({c['collection'] for c in ch})} collections and "
         f"{len({c['folder'] for c in ch})} folders. The pool: {draw['pool_docs']:,} implied documents. "
         f"{len(draw['replaced'])} drawn pages were replaced for having under {MIN_WORDS} words in Apple Vision's "
         f"reading; {len(draw['failed'])} could not be read from disk.", "",
         "| stratum | pool (documents) | pages | from the original photo |", "|---|---:|---:|---:|"]
    for s in list(DATE_BINS) + list(KIND_TAGS):
        rows = [c for c in ch if s in c["strata"]]
        L.append(f"| {s} | {draw['pool_strata'].get(s, 0):,} | {len(rows)} | "
                 f"{sum(c['source'] == 'original' for c in rows)} ({pct(sum(c['source'] == 'original' for c in rows), len(rows))}) |")
    L.append(f"| **all** | {draw['pool_docs']:,} | {len(ch)} | {sum(c['source'] == 'original' for c in ch)} "
             f"({pct(sum(c['source'] == 'original' for c in ch), len(ch))}) |")
    src = collections.Counter(c["source"] for c in ch)
    L += ["", "Where there was no single original, the image inside the PDF was used: " +
          ", ".join(f"{k} {v}" for k, v in src.most_common()) + ".", "",
          "Photo attributes, tertiles cut on a random sample of originals "
          f"(long side {cal['long_side'][0]}/{cal['long_side'][1]} px, sharpness "
          f"{cal['sharpness'][0]:.0f}/{cal['sharpness'][1]:.0f}, year taken {cal['year_taken'][0]}/{cal['year_taken'][1]}):", "",
          "| attribute | low | middle | high |", "|---|---:|---:|---:|"]
    for k, cuts in (("long_side", cal["long_side"]), ("sharpness", cal["sharpness"]), ("year_taken", cal["year_taken"])):
        t = collections.Counter(tertile(c[k], cuts) for c in ch)
        L.append(f"| {k.replace('_', ' ')} | {t[0]} | {t[1]} | {t[2]} |")
    cams = collections.Counter(c.get("camera") or "(no EXIF camera)" for c in ch)
    L += ["", "Cameras: " + ", ".join(f"{k} {v}" for k, v in cams.most_common()) + ".",
          "", "Per collection: " + ", ".join(f"{k} {v}" for k, v in sorted(collections.Counter(c["collection"] for c in ch).items())) + "."]
    ladder = json.loads((CACHE / "ladder.json").read_text()) if (CACHE / "ladder.json").exists() else []
    L += ["", f"Resolution ladder: {len(ladder)} pages also at half and a quarter of their pixel size "
          "(chosen across the pixel tertiles, the largest first)."]
    done = [p for p in pages if "spans" in p]
    if done:
        agree = [p for p in done if not p["n_disputes"]]
        kinds_agree = sum(p["kind"]["claude"] == p["kind"]["gemini"] for p in done)
        tw = sum(p["words"]["claude"] for p in done)
        dw = sum(p["disputed_words"] for p in done)
        nd = sum(p["n_disputes"] for p in done)
        g = [json.loads(l) for l in (CACHE / "draft-gemini-calls.jsonl").read_text().splitlines()]
        L += ["", "## The drafts", "",
              f"Both drafts for {len(done)} of {len(pages)} pages. {len(agree)} pages agree word for word. "
              f"{nd} disputed spans covering {dw:,} of {tw:,} words ({pct(dw, tw)}). The two models give the "
              f"same kind of writing on {kinds_agree} pages.", "",
              "| kind (Claude's label) | pages | words | disputed words | pages agreed |", "|---|---:|---:|---:|---:|"]
        for k in ("printed", "typewritten", "handwritten", "mixed"):
            r = [p for p in done if p["kind"]["claude"] == k]
            w = sum(p["words"]["claude"] for p in r)
            d = sum(p["disputed_words"] for p in r)
            L.append(f"| {k} | {len(r)} | {w:,} | {d:,} ({pct(d, w)}) | {sum(not p['n_disputes'] for p in r)} |")
        prov = collections.Counter(str(json.loads(draft_path("gemini", p["page"]).read_text())["meta"].get("provider"))
                                   for p in done)
        L += ["", f"Gemini 3.8 Flash cost ${sum(r.get('cost') or 0 for r in g):.3f} over {len(g)} calls, retries and "
              "probes included. Its drafts by provider: " + ", ".join(f"{k} {v}" for k, v in prov.most_common()) +
              " (AI Studio ended two pages of reprinted published text with an error and no tokens on every try; "
              "Google's Vertex endpoint, the same model, answered them). Claude: $0 (subscription).", "",
              "## The review", "",
              f"The review sheet holds {nd} spans on {len(done)} pages, about **{review_minutes(pages):.0f} minutes** "
              f"at {SECONDS_PER_PAGE} s a page (the kind of writing), {SECONDS_PER_DISPUTE} s a span and "
              f"{SECONDS_PER_TYPED} s for the {TYPED_SHARE:.0%} assumed to need a typed correction (an estimate, not "
              "measured). One keystroke per choice; the answers are exported as JSON and applied with "
              "`ocr_truth.py apply`, which writes `truth/<page>.txt` and the page table `pages.tsv` the panels group by "
              "(a kind of writing the two models agree on and the owner leaves alone counts as confirmed). The truth "
              "is a word sequence: line breaks and table bars are not kept, so a panel is scored on the words in "
              "order, with whitespace normalised (as socOCRbench's NES and chrF do)."]
    RESULTS.write_text("\n".join(L) + "\n")


# ---------------------------------------------------------------- apply the owner's answers

def cmd_apply(args):
    answers = json.loads(Path(args.answers).read_text())
    pages = json.loads((CACHE / "compare.json").read_text())
    ladder = set(json.loads((CACHE / "ladder.json").read_text()))
    (CACHE / "truth").mkdir(exist_ok=True)
    rows, open_ = [], 0
    cols = ["page", "collection", "folder", "name", "source", "date_bin", "handwritten", "clippings", "tables",
            "kind", "table_form", "long_side", "sharpness", "year_taken", "camera", "ladder", "status", "tags"]
    for p in pages:
        if "spans" not in p:
            continue
        a = answers.get(p["page"], {})
        text = merge(p["spans"], a)
        kind = a.get("kind") or (p["kind"]["claude"] if p["kind"]["claude"] == p["kind"]["gemini"] else None)
        status = "done" if text is not None and kind else "open"
        if status == "done":
            (CACHE / "truth" / f"{p['page']}.txt").write_text(text + "\n")
        else:
            open_ += 1
        s = p["strata"]
        rows.append([p["page"], p["collection"], p["folder"], p["name"], p["source"], s[0],
                     *("yes" if k in s else "" for k in KIND_TAGS), kind or "",
                     "yes" if p["table"]["claude"] and p["table"]["gemini"] else "", p["long_side"], p["sharpness"],
                     p["year_taken"], p.get("camera") or "", "yes" if p["page"] in ladder else "", status,
                     "; ".join(p["tags"])])
    with open(CACHE / "pages.tsv", "w") as fh:
        fh.write("\t".join(cols) + "\n")
        for r in rows:
            fh.write("\t".join(str(x).replace("\t", " ") for x in r) + "\n")
    print(f"{len(rows) - open_} pages settled, {open_} still open; {CACHE / 'pages.tsv'}")


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for c in ("index", "calibrate", "draw", "ladder", "draft-claude", "draft-gemini", "compare"):
        sub.add_parser(c)
    sub.add_parser("apply").add_argument("answers")
    a = ap.parse_args(argv)
    if a.cmd == "draft-claude":
        run_drafts("claude", claude_call, 3)
    elif a.cmd == "draft-gemini":
        run_drafts("gemini", gemini_call, 4)
    else:
        {"index": cmd_index, "calibrate": cmd_calibrate, "draw": cmd_draw, "ladder": cmd_ladder,
         "compare": cmd_compare, "apply": cmd_apply}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
