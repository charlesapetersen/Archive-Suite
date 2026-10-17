#!/usr/bin/env python3
"""W41.seg-corpus-pairs: training windows for a Mac segmenter, from the owner's tagged corpus.

Each corpus PDF is one photo with ABBYY's text layer; its higher-resolution original is a JPEG in a second tree
whose folder and file names do not mirror the PDF tree. This pairs them, then builds seven-page windows over the
per-document folders `corpus_survey.py` found, labelled by the tag rule that survey fixed.

READ ONLY on both trees: `os.scandir`, `getxattr(2)` for tags (corpus_survey.read_tags), `pdftotext` and `sips`
reading a PDF or JPEG and writing only into the cache. Nothing in either tree is written, renamed or moved.

    python3 corpus_pairs.py pair       # every PDF -> its JPEG, by method; cache pairs.tsv + the results md
    python3 corpus_pairs.py check      # a sample of each method's pairs (and every tie) compared by image
    python3 corpus_pairs.py windows    # per-document folders -> pages, labels, text, windows, split (cache)
    python3 corpus_pairs.py clean --run DIR   # W41.seg-label-clean: the teacher's answers -> cleaned labels
    python3 corpus_pairs.py checkpack         # a fresh blind pack of kept labels for the owner (cache checkpack/)
    python3 corpus_pairs.py checkscore FILE   # the owner's answers to it -> each rule's noise among kept labels
    python3 corpus_pairs.py pack --out DIR --part K --parts N   # W41.seg-label-clean: fs_seg.py's pack format,
                                       # every window with ABBYY text, images for part K's folders only (the
                                       # Mac's disk holds one part at a time; rsync each into one pack on FarmShare)

Cache (outside git): ~/Library/Caches/ArchiveSuiteRehearsal/corpus-pairs/
Committed result (numbers only): ArchiveProcessor/segbench-results/corpus-pairs.md

PAIRING, in order, first match wins (owner, 2026-10-15: "Files with the same number and almost the same name are
matches, even if the order is different"):
  mirrored   the same relative path with .jpg for .pdf
  stem       the only JPEG anywhere with the PDF's file stem
  number     the JPEGs whose numbers (every run of 3+ digits in the stem, as a set: the photo number and any
             collection number, so `01100 — Noyce 1490` meets `01100 — Noyce M1490`) are the PDF's and whose name words
             (lower-case letter runs longer than one letter, "img" dropped, digits ignored) overlap the PDF's by
             a Jaccard similarity of at least 0.5, in any order; the best one if it is the only best
  folder     a number tie settled by the folder path's words (the same Jaccard on the two folder paths): the best
             one if it is the only best
  image      a tie still standing, settled by `check`: the candidate whose difference hash is nearest the PDF
             page's, if it beats every other candidate by MARGIN bits
  none       no candidate, or a tie `check` could not settle
"""
import argparse
import collections
import concurrent.futures as cf
import hashlib
import json
import os
import random
import re
import subprocess
import sys
import tempfile
import time

import corpus_survey as CS

JPEGS = os.path.expanduser("~/Desktop/Google Drive/Archival Photos JPEGS")
CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/corpus-pairs")
RESULTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "segbench-results",
                       "corpus-pairs.md")
JPEG_EXT = (".jpg", ".jpeg")
NUMBER = re.compile(r"\d{3,}")
WORD = re.compile(r"[a-z]{2,}")
NEAR = 0.5
SAMPLE = 100              # pairs a method, checked by image
SEED = 41
PDFTOTEXT = os.path.expanduser("~/.local/bin/pdftotext")
# Locked test boxes and development boxes: their corpus copies never enter training (folder names, any depth).
EXCLUDE = re.compile(r"stanton|rg ?165|deaver|herrnstein|\bdean\b", re.I)
HOLDOUT_SHARE = 0.15      # of collections (first two path levels), by implied boundaries, held out whole
NO_TEXT_SHARE = 0.3       # of training windows sent with no page text (the app's own OCR is not ABBYY's)


def number(stem):
    """The stem's numbers of 3+ digits, as a set of ints (leading zeros ignored), or None if it has none."""
    found = frozenset(int(x) for x in NUMBER.findall(stem))
    return found or None


def words(s):
    return frozenset(WORD.findall(s.lower())) - {"img"}


def jaccard(a, b):
    return len(a & b) / len(a | b) if a | b else 1.0


def list_tree(root, exts):
    out = []
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for f in files:
            if not f.startswith(".") and f.lower().endswith(exts):
                out.append(os.path.relpath(os.path.join(dirpath, f), root))
    return out


class Index:
    def __init__(self, jpegs):
        self.rel = set(jpegs)
        self.by_stem = collections.defaultdict(list)
        self.by_number = collections.defaultdict(list)
        for j in jpegs:
            stem = os.path.splitext(os.path.basename(j))[0]
            self.by_stem[stem].append(j)
            n = number(stem)
            if n is not None:
                self.by_number[n].append(j)

    def pair(self, pdf):
        """(jpeg or None, method, tied candidates)."""
        base = os.path.splitext(pdf)[0]
        for ext in JPEG_EXT:
            if base + ext in self.rel:
                return base + ext, "mirrored", []
        stem = os.path.basename(base)
        if len(self.by_stem[stem]) == 1:
            return self.by_stem[stem][0], "stem", []
        n = number(stem)
        if n is None:
            return None, "none", []
        w = words(stem)
        scored = [(jaccard(w, words(os.path.splitext(os.path.basename(j))[0])), j) for j in self.by_number[n]]
        scored = [(s, j) for s, j in scored if s >= NEAR]
        if not scored:
            return None, "none", []
        top = max(s for s, _ in scored)
        best = [j for s, j in scored if s == top]
        if len(best) == 1:
            return best[0], "number", []
        fw = words(os.path.dirname(pdf))
        by_folder = [(jaccard(fw, words(os.path.dirname(j))), j) for j in best]
        ftop = max(s for s, _ in by_folder)
        fbest = [j for s, j in by_folder if s == ftop]
        if len(fbest) == 1:
            return fbest[0], "folder", []
        return None, "tied", fbest


def pairs_path():
    return os.path.join(CACHE, "pairs.tsv")


def read_pairs():
    with open(pairs_path(), encoding="utf-8") as f:
        next(f)
        for line in f:
            pdf, jpeg, method, tied = line.rstrip("\n").split("\t")
            yield pdf, jpeg or None, method, json.loads(tied)


def write_pairs(rows):
    os.makedirs(CACHE, exist_ok=True)
    tmp = pairs_path() + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("pdf\tjpeg\tmethod\ttied\n")
        for pdf, jpeg, method, tied in rows:
            f.write(f"{pdf}\t{jpeg or ''}\t{method}\t{json.dumps(tied, ensure_ascii=False)}\n")
    os.replace(tmp, pairs_path())


def per_document_folders():
    """The survey's per-document folders (corpus_survey.py survey's folders.tsv)."""
    with open(os.path.join(CS.CACHE, "folders.tsv"), encoding="utf-8") as f:
        head = next(f).rstrip("\n").split("\t")
        return [r["folder"] for r in (dict(zip(head, l.rstrip("\n").split("\t"))) for l in f)
                if r["class"] == "per-document"]


def cmd_pair(a):
    pdfs = list_tree(CS.CORPUS, (".pdf",))
    jpegs = list_tree(JPEGS, JPEG_EXT)
    idx = Index(jpegs)
    rows = [(p, *idx.pair(p)) for p in sorted(pdfs)]
    write_pairs(rows)
    report(rows, len(jpegs))


def counts(rows, keep=lambda pdf: True):
    c = collections.Counter(m for p, _, m, _ in rows if keep(p))
    return c, sum(c.values())


METHODS = ("mirrored", "stem", "number", "folder", "image", "tied", "none")


def report(rows, n_jpegs, checked=None):
    docs = set(per_document_folders())
    lines = ["# W41.seg-corpus-pairs — corpus PDFs paired to their JPEG originals", "",
             "Generated by `ArchiveProcessor/scripts/segbench/corpus_pairs.py` (read only on both trees; the rule "
             "is in that file's header). Numbers only: no names, text or images. The pairs themselves are in the "
             "cache (`~/Library/Caches/ArchiveSuiteRehearsal/corpus-pairs/pairs.tsv`), outside git.", "",
             f"**{len(rows):,} PDFs, {n_jpegs:,} JPEGs.**", "",
             "| method | all PDFs | share | per-document folders | share |", "|---|---:|---:|---:|---:|"]
    call, nall = counts(rows)
    cdoc, ndoc = counts(rows, lambda p: os.path.dirname(p) in docs)
    for m in METHODS:
        lines.append(f"| {m} | {call[m]:,} | {100 * call[m] / max(1, nall):.1f}% | {cdoc[m]:,} "
                     f"| {100 * cdoc[m] / max(1, ndoc):.1f}% |")
    paired = lambda c, n: 100 * sum(c[m] for m in METHODS[:5]) / max(1, n)  # noqa: E731
    lines += ["", f"Paired: {paired(call, nall):.1f}% of all PDFs, {paired(cdoc, ndoc):.1f}% of those in the "
              f"{len(docs)} per-document folders the training windows come from (the July audit found 90.6% of "
              "all PDFs, OWNER_AUTHORIZATIONS.md, W24 grant)."]
    if checked:
        lines += ["", "## Checked by image", "",
                  f"A random {SAMPLE} pairs a method (all of them where fewer). The PDF page is rendered and "
                  f"compared with its JPEG by a {HASH}x{HASH} difference hash at the JPEG's four quarter turns; the "
                  f"pair matches when its JPEG is nearer the page than each of the {NEIGHBOURS} JPEGs nearest it in "
                  "its folder, the most alike wrong answers there are. A tie is settled when one candidate is "
                  f"nearer than the rest by {MARGIN} bits.", "",
                  "| method | checked | match | no match | could not render |", "|---|---:|---:|---:|---:|"]
        for m in METHODS[:4]:
            if m in checked:
                k = checked[m]
                lines.append(f"| {m} | {k['n']} | {k['match']} | {k['miss']} | {k['err']} |")
        if "ties" in checked:
            t = checked["ties"]
            lines += ["", "Mirrored pairs are right by construction, so their misses measure the check itself, not the pairing: the number rule's pairs pass the check as often as they do."]
            lines += ["", f"Ties: {t['n']:,} checked, {t['settled']:,} settled by image, {t['open']:,} still open "
                      f"(left unpaired), {t['err']:,} could not render."]
    os.makedirs(os.path.dirname(RESULTS), exist_ok=True)
    with open(RESULTS, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))


HASH = 16       # a 16x16 difference hash (256 bits); an 8x8 one could not tell a page from its neighbour
NEIGHBOURS = 4  # the JPEGs either side of the paired one in its folder, the hardest wrong answers there are
MARGIN = 8      # bits a tie's nearest candidate must beat the next by


def image_hash(path, is_pdf):
    """Difference hashes of the image at its four quarter turns (the PDFs were turned upright, the JPEG originals
    were not). A PDF's first page is rendered by sips into a temp file in the cache."""
    from PIL import Image
    src, tmp = path, None
    if is_pdf:
        tmp = tempfile.NamedTemporaryFile(suffix=".png", delete=False, dir=os.path.join(CACHE, "tmp")).name
        r = subprocess.run(["/usr/bin/sips", "-s", "format", "png", "-Z", "512", path, "--out", tmp],
                           capture_output=True)
        if r.returncode:
            os.unlink(tmp)
            raise RuntimeError("sips failed")
        src = tmp
    try:
        with Image.open(src) as im:
            im.draft("L", (512, 512))
            im = im.convert("L")
            out = []
            for k in range(4 if not is_pdf else 1):
                t = im.rotate(90 * k, expand=True).resize((HASH + 1, HASH), Image.Resampling.LANCZOS)
                px = t.tobytes()
                out.append(sum(1 << i for i in range(HASH * HASH)
                               if px[(i // HASH) * (HASH + 1) + i % HASH] > px[(i // HASH) * (HASH + 1) + i % HASH + 1]))
    finally:
        if tmp:
            os.unlink(tmp)
    return out


def distance(pdf_hash, jpeg_hashes):
    return min(bin(pdf_hash[0] ^ h).count("1") for h in jpeg_hashes)


def cmd_check(a):
    """Each sampled pair is a match when its JPEG is nearer the PDF page than every one of the NEIGHBOURS JPEGs
    nearest it in its folder; a tie is settled when one candidate beats the rest by MARGIN bits."""
    os.makedirs(os.path.join(CACHE, "tmp"), exist_ok=True)
    rows = list(read_pairs())
    rng = random.Random(SEED)
    folder = collections.defaultdict(list)
    for j in list_tree(JPEGS, JPEG_EXT):
        folder[os.path.dirname(j)].append(j)
    for v in folder.values():
        v.sort(key=lambda j: CS.order_key(os.path.basename(j)))
    checked = {}
    for m in METHODS[:4]:
        mine = [r for r in rows if r[2] == m]
        sample = rng.sample(mine, min(SAMPLE, len(mine)))

        def one(r):
            sib = folder[os.path.dirname(r[1])]
            i = sib.index(r[1])
            near = sorted((k for k in range(len(sib)) if k != i), key=lambda k: abs(k - i))[:NEIGHBOURS]
            try:
                h = image_hash(os.path.join(CS.CORPUS, r[0]), True)
                mine_d = distance(h, image_hash(os.path.join(JPEGS, r[1]), False))
                others = [distance(h, image_hash(os.path.join(JPEGS, sib[k]), False)) for k in near]
            except Exception:
                return None
            return all(mine_d < o for o in others)
        with cf.ThreadPoolExecutor(8) as ex:
            d = list(ex.map(one, sample))
        checked[m] = {"n": len(sample), "match": sum(x is True for x in d), "miss": sum(x is False for x in d),
                      "err": sum(x is None for x in d)}
        print(m, checked[m], flush=True)

    def settle(r):
        try:
            h = image_hash(os.path.join(CS.CORPUS, r[0]), True)
            d = sorted((distance(h, image_hash(os.path.join(JPEGS, j), False)), j) for j in r[3])
        except Exception:
            return r, "err"
        ok = len(d) == 1 or d[1][0] - d[0][0] >= MARGIN
        return ((r[0], d[0][1], "image", r[3]) if ok else r), ("settled" if ok else "open")
    ties = [r for r in rows if r[2] == "tied"]
    with cf.ThreadPoolExecutor(8) as ex:
        done = {x[0][0]: x for x in ex.map(settle, ties)}
    outcome = collections.Counter(o for _, o in done.values())
    checked["ties"] = {"n": len(ties), "settled": outcome["settled"], "open": outcome["open"], "err": outcome["err"]}
    rows = [done[r[0]][0] if r[0] in done else r for r in rows]
    rows = [(p, j, "none" if m == "tied" else m, t) for p, j, m, t in rows]
    write_pairs(rows)
    with open(os.path.join(CACHE, "checked.json"), "w") as f:
        json.dump(checked, f, indent=1)
    report(rows, len(list_tree(JPEGS, JPEG_EXT)), checked)


# --- windows --------------------------------------------------------------------------------------------------

def collection_of(folder):
    return "/".join(folder.split("/")[:2])


def pdf_text(path):
    r = subprocess.run([PDFTOTEXT, "-enc", "UTF-8", path, "-"], capture_output=True, timeout=120)
    return r.stdout.decode("utf-8", "replace").strip() if r.returncode == 0 else None


def folder_pages(folder, pair_of):
    """[(pdf rel, jpeg rel or None, label)] in capture order. Labels: Box/Folder for a label photo (Red/Purple),
    New where the identity tag set changes from the previous page photo or a label photo came between, else Cont:
    corpus_survey's rule, applied page by page."""
    names = sorted((e.name for e in os.scandir(os.path.join(CS.CORPUS, folder))
                    if e.is_file() and e.name.lower().endswith(".pdf") and not e.name.startswith(".")),
                   key=CS.order_key)
    out, prev = [], None
    for n in names:
        rel = os.path.join(folder, n)
        tags = set(CS.read_tags(os.path.join(CS.CORPUS, rel)))
        if tags & {"Red"}:
            out.append((rel, pair_of.get(rel), "Box")); prev = None; continue
        if tags & {"Purple"}:
            out.append((rel, pair_of.get(rel), "Folder")); prev = None; continue
        ident = frozenset(tags - CS.IGNORED)
        out.append((rel, pair_of.get(rel), "New" if prev is None or ident != prev else "Cont"))
        prev = ident
    return out


def cmd_windows(a):
    import method_window as W
    pair_of = {p: j for p, j, m, _ in read_pairs() if j}
    folders = [f for f in per_document_folders() if not EXCLUDE.search(f)]
    excluded = [f for f in per_document_folders() if EXCLUDE.search(f)]
    pages = {}
    for f in folders:
        pages[f] = folder_pages(f, pair_of)
    # Hold out whole collections, about HOLDOUT_SHARE of implied boundaries, chosen by a seeded shuffle.
    bounds = collections.Counter()
    for f, ps in pages.items():
        bounds[collection_of(f)] += sum(l == "New" for _, _, l in ps)
    cols = sorted(bounds)
    random.Random(SEED).shuffle(cols)
    held, total, acc = set(), sum(bounds.values()), 0
    for c in cols:
        if acc >= HOLDOUT_SHARE * total:
            break
        if bounds[c] <= 0.25 * total:  # no one collection is a quarter of the holdout's job
            held.add(c); acc += bounds[c]
    # Text: ABBYY's layer, extracted once per page into the cache.
    tdir = os.path.join(CACHE, "text")
    todo = [p for ps in pages.values() for p, _, _ in ps
            if not os.path.exists(os.path.join(tdir, hashlib.sha1(p.encode()).hexdigest() + ".txt"))]
    print(f"{len(folders)} folders ({len(excluded)} excluded), {sum(map(len, pages.values()))} pages, "
          f"{len(todo)} texts to extract", flush=True)

    def extract(p):
        t = pdf_text(os.path.join(CS.CORPUS, p))
        out = os.path.join(tdir, hashlib.sha1(p.encode()).hexdigest() + ".txt")
        os.makedirs(tdir, exist_ok=True)
        with open(out + ".tmp", "w", encoding="utf-8") as fh:
            fh.write(t if t is not None else "\x00failed")
        os.replace(out + ".tmp", out)
    with cf.ThreadPoolExecutor(8) as ex:
        for k, _ in enumerate(ex.map(extract, todo), 1):
            if k % 2000 == 0:
                print(f"text {k}/{len(todo)}", flush=True)
    # Windows: runs of consecutive pages that all have a JPEG (a page without one breaks the run), 7 at stride 3.
    rng = random.Random(SEED)
    out = []
    stats = collections.Counter()
    for f, ps in pages.items():
        split = "holdout" if collection_of(f) in held else "train"
        fid = hashlib.sha1(f.encode()).hexdigest()[:12]
        runs, cur = [], []
        for i, (p, j, l) in enumerate(ps):
            if j:
                cur.append(i)
            else:
                stats["pages without a JPEG"] += 1
                if cur:
                    runs.append(cur); cur = []
        if cur:
            runs.append(cur)
        for run in runs:
            for lo, hi in W.windows(len(run)):
                idx = run[lo:hi]
                if len(idx) < 2:
                    continue
                text = "none" if split == "train" and rng.random() < NO_TEXT_SHARE else "abbyy"
                out.append({"folder_id": fid, "split": split, "text": text,
                            "pages": [{"n": i + 1, "pdf": ps[i][0], "jpeg": ps[i][1], "label": ps[i][2]}
                                      for i in idx]})
                stats[f"windows {split}"] += 1
                stats[f"gaps {split}"] += len(idx) - 1
    with open(os.path.join(CACHE, "windows.jsonl.tmp"), "w", encoding="utf-8") as fh:
        for w in out:
            fh.write(json.dumps(w, ensure_ascii=False) + "\n")
    os.replace(os.path.join(CACHE, "windows.jsonl.tmp"), os.path.join(CACHE, "windows.jsonl"))
    labels = collections.Counter((("holdout" if collection_of(f) in held else "train"), l)
                                 for f, ps in pages.items() for _, j, l in ps if j)
    failed = sum(1 for n in os.listdir(tdir) if open(os.path.join(tdir, n), encoding="utf-8").read(1) == "\x00")
    summary = {"folders": len(folders), "excluded_folders": len(excluded), "held_out_collections": len(held),
               "collections": len(cols), "pages": sum(map(len, pages.values())), "labels": {
                   f"{s} {l}": v for (s, l), v in sorted(labels.items())}, "text_failed": failed, **stats,
               "no_text_share": NO_TEXT_SHARE}
    with open(os.path.join(CACHE, "windows-summary.json"), "w") as fh:
        json.dump(summary, fh, indent=1)
    with open(os.path.join(CACHE, "holdout.json"), "w") as fh:
        json.dump(sorted(held), fh, indent=1)
    print(json.dumps(summary, indent=1))
    append_windows(summary)


def append_windows(s):
    with open(RESULTS, encoding="utf-8") as f:
        text = f.read().split("\n## Training windows\n")[0].rstrip("\n")
    lab = s["labels"]
    rows = []
    for split in ("train", "holdout"):
        rows.append(f"| {split} | {s.get('windows ' + split, 0):,} | {s.get('gaps ' + split, 0):,} "
                    f"| {lab.get(split + ' New', 0):,} | {lab.get(split + ' Cont', 0):,} "
                    f"| {lab.get(split + ' Box', 0) + lab.get(split + ' Folder', 0):,} |")
    text += "\n".join(["", "", "## Training windows", "",
                       f"From the {s['folders']} per-document folders that remain once {s['excluded_folders']} "
                       "corpus copies of the development and test boxes are set aside (folder names matching "
                       "Stanton, RG 165, Deaver, Dean or Herrnstein; that also takes Harvard's Office of the Dean papers, kept out "
                       "because which corpus folder the Dean box came from is not recorded). Seven-page windows at stride 3 over runs of "
                       "consecutive paired pages; a page with no JPEG breaks the run. Labels by corpus_survey's tag "
                       f"rule. {s['held_out_collections']} of {s['collections']} collections are held out whole "
                       f"(about {100 * HOLDOUT_SHARE:.0f}% of implied boundaries). {100 * s['no_text_share']:.0f}% "
                       "of training windows go with no page text, because in the app the segmenter sees the app's "
                       "own OCR, never ABBYY's; the rest carry ABBYY's text layer. App-style OCR text for a share "
                       "of windows would need OCR of the pages, which this item does not do.", "",
                       "| split | windows | window gaps (overlapping) | page photos New | Cont | Box/Folder photos |",
                       "|---|---:|---:|---:|---:|---:|", *rows, "",
                       f"Pages without a JPEG: {s.get('pages without a JPEG', 0):,}. PDFs whose text layer could "
                       f"not be read: {s['text_failed']:,}. Labels are the tags' implication, 21% wrong on starts "
                       "and 8% on continuations (corpus-survey.md); W41.seg-label-clean cleans them."]) + "\n"
    with open(RESULTS, "w", encoding="utf-8") as f:
        f.write(text)


def window_prompt(nums, texts):
    """The prompt method_local.request (method_window_cues.build_request, route codex) builds for these pages and
    texts, without making its 1600 px thumbnails (the label-clean pack needs only the 1024 px images it sends)."""
    import method_window as W
    import method_window_cues as C
    files = "\n".join(f"- {W.fname(n)}  (page {n})" for n in nums)
    body = "\n".join(f"--- page {n} ---\n{W.page_text(_Texts(texts), k)}" for k, n in enumerate(nums))
    gaps = ", ".join(f"[{x}, {x + 1}]" for x in nums[:-1])
    return C.prompt_template("codex").format(k=len(nums), files=files, texts=body, gaps=gaps, max_text=W.MAX_TEXT,
                                             pages=", ".join(str(n) for n in nums))


class _Texts:
    def __init__(self, texts):
        self.texts = texts

    def text(self, i):
        return self.texts[i]


def page_text_of(pdf):
    with open(os.path.join(CACHE, "text", hashlib.sha1(pdf.encode()).hexdigest() + ".txt"), encoding="utf-8") as f:
        t = f.read()
    return None if t.startswith("\x00") else t


def cmd_pack(a):
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "farmshare"))
    import method_openrouter as R
    import fs_seg as S
    out = a.out
    wins = [json.loads(l) for l in open(os.path.join(CACHE, "windows.jsonl"), encoding="utf-8")]
    # Held-out windows go too: the teacher's labels make the held-out set a cleaner test of the student, and never
    # become training labels (`clean` keeps the split). The owner-checked noise sample is scored from both.
    folders = sorted({w["folder_id"] for w in wins})
    pages_of = collections.Counter()
    for w in wins:
        pages_of[w["folder_id"]] += len(w["pages"])
    part, acc, per = {}, 0, sum(pages_of.values()) / a.parts
    for f in folders:  # contiguous by cumulative pages, so parts come out about even
        part[f] = min(a.parts - 1, int(acc // per)); acc += pages_of[f]
    os.makedirs(os.path.join(out, "images"), exist_ok=True)
    recs, todo = [], {}
    for w in wins:
        nums = [p["n"] for p in w["pages"]]
        prompt = window_prompt(nums, [page_text_of(p["pdf"]) for p in w["pages"]])
        key = hashlib.sha256(json.dumps([w["folder_id"], nums, prompt]).encode()).hexdigest()
        # The teacher reads every window with ABBYY's text; prompt_notext is the same request with no page text, for
        # the student's no-text share (train_seg.py data). fs_seg.py sends only "prompt".
        recs.append({"box": w["folder_id"], "window": nums, "cache_key": key, "prompt": prompt,
                     "prompt_notext": window_prompt(nums, [None] * len(nums)) if w["text"] == "none" else None})
        if part[w["folder_id"]] != a.part:
            continue
        for p in w["pages"]:
            todo[os.path.join(out, "images", w["folder_id"], f"{p['n']}.jpg")] = os.path.join(JPEGS, p["jpeg"])
    todo = {d: src for d, src in todo.items() if not os.path.exists(d)}

    def image(item):
        S.atomic_write(__import__("pathlib").Path(item[0]), R.image_jpeg(item[1], R.side_of(S.KEY)))
    with cf.ThreadPoolExecutor(8) as ex:
        for k, _ in enumerate(ex.map(image, todo.items()), 1):
            if k % 2000 == 0:
                print(f"images {k}/{len(todo)}", flush=True)
    n_img = len(todo)
    S.atomic_write(__import__("pathlib").Path(out) / "windows.jsonl",
                   "".join(json.dumps(r) + "\n" for r in recs).encode())
    S.atomic_write(__import__("pathlib").Path(out) / "pack.json", json.dumps({
        "key": S.KEY, "model": R.entry(S.KEY)[0], "side": R.side_of(S.KEY), "max_tokens": R.MAX_TOKENS,
        "prompt_version": R.PROMPT_VERSION, "boxes": ["corpus"], "pages": sum(pages_of.values()),
        "windows": len(recs), "made": time.strftime("%Y-%m-%dT%H:%M:%S"), "part": [a.part, a.parts]},
        indent=1).encode())
    print(f"part {a.part}/{a.parts}: {n_img} images; {len(recs)} windows over {len(folders)} folders", flush=True)


KEEP_AGREE = 0.5   # a tag label is kept when the teacher's P(new) is on the same side of this
# The owner's reading (2026-10-16): a tag change almost always marks a real start, but he sometimes kept separate
# documents on nearby dates with similar content under one tag set. So under "start-trust" a tag start stands unless
# the teacher is sure it is a continuation, and a tag continuation becomes a start where the teacher is sure of one.
SURE = 0.85


def rule_label(tag, p, rule):
    """The gap's label under a rule ("new", "cont"), or None where the rule drops it."""
    if rule == "agree":
        return tag if (p >= KEEP_AGREE) == (tag == "new") else None
    if tag == "new":
        return None if p <= 1 - SURE else "new"
    return "new" if p >= SURE else ("cont" if p < KEEP_AGREE else None)


RULES = ("agree", "start-trust")


def gap_labels(run):
    """Per gap of every window the teacher answered: the tag label, the teacher's P(new) averaged over the windows
    that cover it (method_window.combine's rule), the split. Keyed (folder_id, n): the gap after page n."""
    import method_window as W
    wins = {(w["folder_id"], tuple(p["n"] for p in w["pages"])): w
            for w in map(json.loads, open(os.path.join(CACHE, "windows.jsonl"), encoding="utf-8"))}
    votes = collections.defaultdict(list)
    for line in open(os.path.join(run, "answers.jsonl"), encoding="utf-8"):
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if r.get("status") != "ok":
            continue
        try:
            j = W.parse_answer(r["result"], r["window"])
        except Exception:
            continue
        for x, bd in j["boundaries"].items():
            votes[(r["collection"], x)].append(bd["confidence"] if bd["decision"] == "new" else 1 - bd["confidence"])
    out = {}
    for (fid, nums), w in wins.items():
        for left, right in zip(w["pages"], w["pages"][1:]):
            k = (fid, left["n"])
            if k in out or k not in votes:
                continue
            tag = "new" if right["label"] in ("New", "Box", "Folder") or left["label"] in ("Box", "Folder") else "cont"
            p = sum(votes[k]) / len(votes[k])
            out[k] = {"folder_id": fid, "n": left["n"], "left": left["pdf"], "right": right["pdf"], "split": w["split"],
                      "tag": tag, "p_new": round(p, 4), "n_judged": len(votes[k]),
                      "keep": (p >= KEEP_AGREE) == (tag == "new"),
                      **{f"label_{r}": rule_label(tag, p, r) for r in RULES}}
    return out


def cmd_clean(a):
    g = gap_labels(a.run)
    path = os.path.join(CACHE, "labels.jsonl")
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        for v in g.values():
            f.write(json.dumps(v, ensure_ascii=False) + "\n")
    os.replace(path + ".tmp", path)
    c = collections.Counter((v["split"], v["tag"], v["keep"]) for v in g.values())
    by_rule = {r: dict(collections.Counter(f"{v['split']} {v['tag']} -> {v[f'label_{r}'] or 'dropped'}"
                                           for v in g.values())) for r in RULES}
    # The owner-checked noise sample (corpus_survey pack, W36.seg-corpus-noise): how many of its wrong tag labels
    # the teacher's agreement removes, and how many right ones it throws away.
    key = json.load(open(os.path.join(CS.CACHE, "pack", "key.json")))
    ans = dict(l.strip().split(",") for l in open(os.path.join(CS.CACHE, "owner-answers-2026-10-08.csv")) if "," in l)
    by_pdf = {(v["left"], v["right"]): v for v in g.values()}
    probe = collections.Counter()
    for k in key:
        v = by_pdf.get((os.path.join(k["folder"], k["left"]), os.path.join(k["folder"], k["right"])))
        a_ = ans.get(k["id"])
        if v is None or a_ not in ("new", "same"):
            probe["not in the run or unsure"] += 1
            continue
        truth = "new" if a_ == "new" else "cont"
        probe[f"tags: {'right' if truth == v['tag'] else 'wrong'}"] += 1
        for r in RULES:
            got = v[f"label_{r}"]
            probe[f"{r}: {'dropped' if got is None else 'right' if got == truth else 'wrong'}"] += 1
    summary = {"gaps": len(g), "by_split_tag_keep": {f"{s} {t} {'kept' if k else 'dropped'}": n
                                                      for (s, t, k), n in sorted(c.items())},
               "by_rule": {r: dict(sorted(v.items())) for r, v in by_rule.items()},
               "owner_sample": dict(sorted(probe.items())), "keep_rule": f"teacher P(new) on the tag's side of {KEEP_AGREE}",
               "start_trust_sure": SURE}
    with open(os.path.join(CACHE, "labels-summary.json"), "w") as f:
        json.dump(summary, f, indent=1)
    print(json.dumps(summary, indent=1))


CHECK_DIR = os.path.join(CACHE, "checkpack")
# The fresh owner check of the cleaned labels: every label start-trust keeps, in four strata by how it was kept
# (start-trust's kept set holds agree's, with the same labels). Agree keeps A and D; start-trust keeps all four.
CHECK_N = {"A": 25, "B": 5, "C": 25, "D": 25}


def check_stratum(g):
    """A labels.jsonl gap's stratum: A tag start the teacher agrees with, B tag start start-trust keeps though the
    teacher leans continuation, C tag continuation start-trust turns into a start, D agreed continuation."""
    lab = g["label_start-trust"]
    if lab is None:
        return None
    if g["tag"] == "new":
        return "A" if g["label_agree"] == "new" else "B"
    return "D" if lab == "cont" else "C"


def cmd_checkpack(a):
    """A blind pack of kept labels for the owner to judge, drawn fresh: no gap from the 2026-10-08 sample. Writes
    the pack (JPEG thumbnails, read from the JPEG tree by sips) and its key into the cache, outside git."""
    lab = [json.loads(l) for l in open(os.path.join(CACHE, "labels.jsonl"), encoding="utf-8")]
    jpeg = {p["pdf"]: p["jpeg"] for w in map(json.loads, open(os.path.join(CACHE, "windows.jsonl"), encoding="utf-8"))
            for p in w["pages"]}
    old = {(os.path.join(k["folder"], k["left"]), os.path.join(k["folder"], k["right"]))
           for k in json.load(open(os.path.join(CS.CACHE, "pack", "key.json")))}
    by = collections.defaultdict(list)
    for g in lab:
        s = check_stratum(g)
        if s and (g["left"], g["right"]) not in old and g["left"] in jpeg and g["right"] in jpeg:
            by[s].append(g)
    rng = random.Random(SEED + 1)
    cases = [(s, g) for s in sorted(CHECK_N)
             for g in rng.sample(sorted(by[s], key=lambda g: (g["left"], g["right"])), CHECK_N[s])]
    rng.shuffle(cases)
    thumbs = os.path.join(CHECK_DIR, "thumbs")
    os.makedirs(thumbs, exist_ok=True)
    key, rows = [], []
    for i, (s, g) in enumerate(cases, 1):
        cid = f"k{i:02d}"
        key.append({"id": cid, "stratum": s, "left": g["left"], "right": g["right"], "tag": g["tag"],
                    "p_new": g["p_new"], "label_agree": g["label_agree"], "label_start-trust": g["label_start-trust"]})
        imgs = []
        for side, pdf in (("l", g["left"]), ("r", g["right"])):
            dst = os.path.join(thumbs, f"{cid}{side}.jpg")
            if not os.path.exists(dst):
                subprocess.run(["/usr/bin/sips", "-s", "format", "jpeg", "-Z", "900", os.path.join(JPEGS, jpeg[pdf]),
                                "--out", dst], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            imgs.append(f"thumbs/{cid}{side}.jpg")
        rows.append((cid, os.path.dirname(g["right"]), os.path.basename(g["left"]), os.path.basename(g["right"]), imgs))
    pop = {s: len(v) for s, v in sorted(by.items())}
    with open(os.path.join(CHECK_DIR, "key.json"), "w") as f:
        json.dump({"population": pop, "cases": key}, f, indent=1)
    page_path = os.path.join(CHECK_DIR, "index.html")
    CS.write_pack_html(rows, page_path)
    # corpus_survey's page names its own item and stores answers under its own key; this pack is a different check.
    with open(page_path) as f:
        page = f.read()
    page = (page.replace("Corpus tag noise check (W36.seg-corpus-survey)", "Cleaned label check (W41.seg-label-clean)")
            .replace("80 neighbouring photo pairs", f"{len(rows)} neighbouring photo pairs")
            .replace("'corpus-survey-answers'", "'label-clean-answers'"))
    with open(page_path, "w") as f:
        f.write(page)
    print(f"{len(rows)} cases from strata {pop} -> {page_path} (key in key.json; not shown in the page)")


def check_noise(key, answers):
    """Per stratum [right, wrong, unsure] for each rule's label, and each rule's noise among the labels it keeps,
    weighted by stratum population: {rule: (noise, judged)}. Answers: {id: new|same|unsure}."""
    per = {r: collections.defaultdict(lambda: [0, 0, 0]) for r in RULES}
    for k in key["cases"]:
        ans = answers.get(k["id"])
        if ans not in ("new", "same", "unsure"):
            continue
        for r in RULES:
            lab = k[f"label_{r}"]
            if lab is None:
                continue
            c = per[r][k["stratum"]]
            if ans == "unsure":
                c[2] += 1
            else:
                c[0 if (ans == "new") == (lab == "new") else 1] += 1
    noise = {}
    for r in RULES:
        judged = {s: c for s, c in per[r].items() if c[0] + c[1]}
        tot = sum(key["population"][s] for s in judged)
        est = sum(key["population"][s] * c[1] / (c[0] + c[1]) for s, c in judged.items())
        noise[r] = (est / tot if tot else 0.0, sum(c[0] + c[1] for c in judged.values()))
    return {r: dict(sorted(v.items())) for r, v in per.items()}, noise


def cmd_checkscore(a):
    with open(os.path.join(CHECK_DIR, "key.json")) as f:
        key = json.load(f)
    with open(a.answers) as f:
        answers = {k.strip(): v.strip() for k, v in (l.split(",", 1) for l in f if "," in l)}
    per, noise = check_noise(key, answers)
    print(json.dumps({"population": key["population"], "per_stratum": per,
                      "noise": {r: {"weighted": round(n, 4), "judged": j} for r, (n, j) in noise.items()}}, indent=1))


def cmd_subpack(a):
    """W41.seg-finetune: the held-out windows of a pack (corpus_pairs pack), for another key (a student or a
    baseline), images linked, not copied. Runs where the pack is (FarmShare); needs no corpus."""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "farmshare"))
    import method_openrouter as R
    split = {(w["folder_id"], tuple(p["n"] for p in w["pages"])): w["split"]
             for w in map(json.loads, open(a.windows, encoding="utf-8"))}
    os.makedirs(a.out)
    rows = [l for l in open(os.path.join(a.pack, "windows.jsonl"), encoding="utf-8")
            if split[(json.loads(l)["box"], tuple(json.loads(l)["window"]))] == a.split]
    with open(os.path.join(a.out, "windows.jsonl"), "w", encoding="utf-8") as f:
        f.writelines(rows)
    meta = json.load(open(os.path.join(a.pack, "pack.json")))
    meta.update(key=a.key, model=R.entry(a.key)[0], windows=len(rows), split=a.split, made=time.strftime("%Y-%m-%dT%H:%M:%S"))
    json.dump(meta, open(os.path.join(a.out, "pack.json"), "w"), indent=1)
    os.symlink(os.path.abspath(os.path.join(a.pack, "images")), os.path.join(a.out, "images"))
    print(f"{len(rows)} {a.split} windows for {a.key} -> {a.out}")


def cmd_score(a):
    """A run's per-gap calls (method_window.combine's mean over the windows covering a gap) against the held-out
    gaps the teacher and the tags agree on (labels.jsonl, `keep`), and against every held-out tag label."""
    import method_window as W
    lab = {(g["folder_id"], g["n"]): g for g in map(json.loads, open(os.path.join(CACHE, "labels.jsonl")))}
    votes, failed, n = collections.defaultdict(list), 0, 0
    for line in open(os.path.join(a.run, "answers.jsonl"), encoding="utf-8"):
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        n += 1
        try:
            j = W.parse_answer(r["result"], r["window"]) if r.get("status") == "ok" else None
        except Exception:
            j = None
        if j is None:
            failed += 1
            continue
        for x, bd in j["boundaries"].items():
            votes[(r["collection"], x)].append(bd["confidence"] if bd["decision"] == "new" else 1 - bd["confidence"])
    out = {"windows": n, "failed": failed}
    for name, keep in (("agreed", lambda g: g["keep"]), ("all tags", lambda g: True)):
        c = collections.Counter()
        for k, v in votes.items():
            g = lab.get(k)
            if g is None or g["split"] != "holdout" or not keep(g):
                continue
            said = "new" if sum(v) / len(v) >= 0.5 else "cont"
            c["gaps"] += 1
            c["right"] += said == g["tag"]
            c["false splits"] += said == "new" and g["tag"] == "cont"
            c["false merges"] += said == "cont" and g["tag"] == "new"
        out[name] = {**c, "accuracy": round(c["right"] / max(1, c["gaps"]), 4)}
    print(json.dumps(out, indent=1))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for c in ("pair", "check", "windows"):
        sub.add_parser(c)
    p = sub.add_parser("clean"); p.add_argument("--run", required=True, help="runs/seg/<label>, brought back")
    p = sub.add_parser("subpack")
    for k in ("pack", "windows", "key", "out"):
        p.add_argument("--" + k, required=True)
    p.add_argument("--split", default="holdout")
    p = sub.add_parser("score"); p.add_argument("--run", required=True)
    sub.add_parser("checkpack")
    p = sub.add_parser("checkscore"); p.add_argument("answers")
    p = sub.add_parser("pack")
    p.add_argument("--out", required=True); p.add_argument("--part", type=int, default=0)
    p.add_argument("--parts", type=int, default=1)
    a = ap.parse_args()
    {"pair": cmd_pair, "check": cmd_check, "windows": cmd_windows, "pack": cmd_pack, "clean": cmd_clean, "subpack": cmd_subpack,
     "score": cmd_score, "checkpack": cmd_checkpack, "checkscore": cmd_checkscore}[a.cmd](a)


if __name__ == "__main__":
    main()
