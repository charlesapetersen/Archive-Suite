#!/usr/bin/env python3
"""W36.seg-corpus-survey: can the owner's tagged corpus train a segmentation model?

Each PDF in the corpus is ONE photo, numbered in capture order, so a document is only implied by its
Finder tags: where a folder was tagged per document, a change of tag set between neighbouring photos
implies a document start; where it was tagged per collection, nothing is implied.

READ ONLY on the corpus. The only calls that touch a corpus file are `os.scandir` (listing) and
`getxattr(2)` on `com.apple.metadata:_kMDItemUserTags` (reading the tags), plus, for the review pack only,
`sips` reading the sampled PDFs and writing a JPEG copy into the cache. Nothing in the corpus is written,
renamed, moved or opened for writing.

    python3 corpus_survey.py survey      # tags of every PDF -> per-folder TSV in the cache + the results md
    python3 corpus_survey.py pack        # 40 implied boundaries + 40 continuations -> review pack (cache)
    python3 corpus_survey.py score FILE  # the owner's exported answers -> measured noise rate

Cache (outside git): ~/Library/Caches/ArchiveSuiteRehearsal/corpus-survey/
Committed result (numbers only): ArchiveProcessor/segbench-results/corpus-survey.md

THE CLASSIFICATION RULE — written before any totals were looked at, and not changed after:
  * Tags ignored entirely: `Unread`, and the Finder colour labels (Red, Orange, Yellow, Green, Blue, Purple,
    Gray/Grey). A photo carrying Red or Purple is a LABEL photo (box or folder card); the rest are PAGE photos.
  * A page photo's identity is its remaining tag set (year, month, subject, priority, …).
  * Pairs: consecutive page photos in file-number order with no label photo between them. A pair is a
    CHANGE if the two identity sets differ, else SAME.
  * Per folder (a directory that directly holds PDFs):
      tagged  = share of page photos with a non-empty identity set
      change  = share of pairs that are CHANGE
      year    = share of page photos carrying a 4-digit year tag (1500-2099)
  * Class, first match wins:
      small           fewer than 5 page photos (too few pairs to say anything)
      untagged        tagged < 0.5
      per-collection  change < 0.03            (under one tag change per ~33 pages)
      per-document    change >= 0.10 and year >= 0.5
      mixed           anything else
  * Usable training pairs come from per-document folders only: each CHANGE pair is an implied boundary, each
    SAME pair an implied continuation. Implied documents = runs of identical identity among page photos, with
    a label photo also ending a run.
For reference, a single-page-document folder has change near 1; the ground-truth boxes average 1.75 pages a
document (change ~0.57). The rule is checked, not tuned, against the corpus copies of Deaver, Dean and
Herrnstein, which an interactive look on 2026-10-06 found collection-tagged.
"""
import argparse
import ctypes
import ctypes.util
import html
import json
import os
import plistlib
import random
import re
import subprocess
import sys
from collections import defaultdict

CORPUS = os.path.expanduser("~/Desktop/Google Drive/Archival Photos")
CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/corpus-survey")
RESULTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "segbench-results",
                       "corpus-survey.md")
XATTR = b"com.apple.metadata:_kMDItemUserTags"
COLOURS = {"Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray", "Grey"}
LABEL_COLOURS = {"Red", "Purple"}
IGNORED = {"Unread"} | COLOURS
YEAR = re.compile(r"^(1[5-9]\d\d|20\d\d)$")
NUM = re.compile(r"^(\d+)")
SEED = 36
DEV_NAMES = ("Deaver", "Dean", "Herrnstein")

_libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
_libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                           ctypes.c_uint32, ctypes.c_int]
_libc.getxattr.restype = ctypes.c_ssize_t


def read_tags(path):
    """Finder tag names on `path`, read with getxattr(2) (no open for writing). [] if none."""
    p = os.fsencode(path)
    size = _libc.getxattr(p, XATTR, None, 0, 0, 0)
    if size <= 0:
        return []
    buf = ctypes.create_string_buffer(size)
    got = _libc.getxattr(p, XATTR, buf, size, 0, 0)
    if got <= 0:
        return []
    try:
        entries = plistlib.loads(buf.raw[:got])
    except Exception:
        return []
    return [str(e).split("\n", 1)[0] for e in entries if isinstance(e, str)]


def order_key(name):
    m = NUM.match(name)
    return (0, int(m.group(1)), name) if m else (1, 0, name)


def walk(root):
    """Yield (relative folder, [pdf names in capture order]) for every folder that directly holds PDFs."""
    stack = [root]
    while stack:
        d = stack.pop()
        try:
            entries = list(os.scandir(d))
        except OSError:
            continue
        pdfs = []
        for e in entries:
            if e.name.startswith("."):
                continue
            if e.is_dir(follow_symlinks=False):
                stack.append(e.path)
            elif e.is_file(follow_symlinks=False) and e.name.lower().endswith(".pdf"):
                pdfs.append(e.name)
        if pdfs:
            yield os.path.relpath(d, root), sorted(pdfs, key=order_key)


def analyse(photos):
    """photos: [(name, [tags])] in order -> dict of per-folder measures, pairs and class."""
    pages, labels, pairs = 0, 0, []
    tagged = years = 0
    prev = None          # (name, identity) of the previous page photo, None after a label photo
    runs = 0
    for name, tags in photos:
        if LABEL_COLOURS & set(tags):
            labels += 1
            prev = None
            continue
        ident = frozenset(t for t in tags if t not in IGNORED)
        pages += 1
        tagged += bool(ident)
        years += any(YEAR.match(t) for t in ident)
        if prev is None or prev[1] != ident:
            runs += 1
        if prev is not None:
            pairs.append((prev[0], name, prev[1] != ident))
        prev = (name, ident)
    n_pairs = len(pairs)
    changes = sum(1 for p in pairs if p[2])
    m = {
        "photos": len(photos), "pages": pages, "labels": labels, "pairs": n_pairs, "changes": changes,
        "tagged": tagged / pages if pages else 0.0,
        "change": changes / n_pairs if n_pairs else 0.0,
        "year": years / pages if pages else 0.0,
        "docs": runs,
    }
    m["class"] = classify(m)
    return m, pairs


def classify(m):
    if m["pages"] < 5:
        return "small"
    if m["tagged"] < 0.5:
        return "untagged"
    if m["change"] < 0.03:
        return "per-collection"
    if m["change"] >= 0.10 and m["year"] >= 0.5:
        return "per-document"
    return "mixed"


def collection_of(folder):
    parts = folder.split(os.sep)
    return os.sep.join(parts[:2]) if len(parts) > 1 else parts[0]


def cmd_survey(args):
    os.makedirs(CACHE, exist_ok=True)
    folders = []
    all_pairs = {}
    n_files = 0
    for folder, names in walk(args.corpus):
        photos = [(n, read_tags(os.path.join(args.corpus, folder, n))) for n in names]
        n_files += len(photos)
        m, pairs = analyse(photos)
        m["folder"] = folder
        folders.append(m)
        if m["class"] == "per-document":
            all_pairs[folder] = pairs
    folders.sort(key=lambda m: m["folder"])
    cols = ["folder", "class", "photos", "pages", "labels", "pairs", "changes", "change", "tagged", "year",
            "docs"]
    with open(os.path.join(CACHE, "folders.tsv"), "w") as f:
        f.write("\t".join(cols) + "\n")
        for m in folders:
            f.write("\t".join(f"{m[c]:.3f}" if isinstance(m[c], float) else str(m[c]) for c in cols) + "\n")
    with open(os.path.join(CACHE, "pairs.json"), "w") as f:
        json.dump({k: [[a, b, c] for a, b, c in v] for k, v in all_pairs.items()}, f)
    write_results(folders, n_files, args.results)
    print(f"{n_files} PDFs in {len(folders)} folders; results -> {args.results}")


def pct(x):
    return f"{100 * x:.1f}%"


def write_results(folders, n_files, out):
    classes = ["per-document", "mixed", "per-collection", "untagged", "small"]
    by_class = defaultdict(lambda: [0, 0, 0, 0, 0])   # folders, photos, pairs, changes, docs
    by_col = defaultdict(lambda: defaultdict(lambda: [0, 0, 0, 0, 0]))
    for m in folders:
        for agg in (by_class[m["class"]], by_col[collection_of(m["folder"])][m["class"]]):
            agg[0] += 1; agg[1] += m["photos"]; agg[2] += m["pairs"]; agg[3] += m["changes"]; agg[4] += m["docs"]
    L = []
    L.append("# W36.seg-corpus-survey — can the tagged corpus train a segmentation model?\n")
    L.append("Generated by `ArchiveProcessor/scripts/segbench/corpus_survey.py survey` (read-only on the corpus; "
             "the classification rule is in that file's header, fixed before the totals were seen). Numbers "
             "only: no page text or images. Per-folder detail is in the cache "
             "(`~/Library/Caches/ArchiveSuiteRehearsal/corpus-survey/folders.tsv`), outside git.\n")
    L.append(f"**{n_files:,} PDFs in {len(folders):,} folders.**\n")
    L.append("## Totals by class\n")
    L.append("| class | folders | photos | page pairs | implied boundaries | implied continuations | implied documents |")
    L.append("|---|---:|---:|---:|---:|---:|---:|")
    for c in classes:
        a = by_class[c]
        L.append(f"| {c} | {a[0]:,} | {a[1]:,} | {a[2]:,} | {a[3]:,} | {a[2] - a[3]:,} | {a[4]:,} |")
    pd = by_class["per-document"]
    L.append(f"\nUsable for training (per-document folders only): **{pd[3]:,} implied boundaries and "
             f"{pd[2] - pd[3]:,} implied continuations** across {pd[0]:,} folders and {pd[1]:,} photos, "
             f"before noise. For scale, the ground-truth development set has 551 pages and 315 documents.\n")
    L.append("## By collection (first two path levels)\n")
    L.append("Per-document columns are the usable ones; the other classes are counted in folders and photos.\n")
    L.append("| collection | per-doc folders | per-doc photos | implied boundaries | implied continuations | "
             "mixed (folders/photos) | per-collection (folders/photos) | untagged (folders/photos) | small (folders) |")
    L.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    order = sorted(by_col, key=lambda k: (-by_col[k]["per-document"][3], k))
    for k in order:
        a = by_col[k]
        p = a["per-document"]
        L.append(f"| {k} | {p[0]} | {p[1]:,} | {p[3]:,} | {p[2] - p[3]:,} | {a['mixed'][0]}/{a['mixed'][1]:,} | "
                 f"{a['per-collection'][0]}/{a['per-collection'][1]:,} | {a['untagged'][0]}/{a['untagged'][1]:,} | "
                 f"{a['small'][0]} |")
    L.append("\n## Rule check against the known collection-tagged boxes\n")
    L.append("Corpus copies of the development collections, which the 2026-10-06 look found tagged per collection "
             "(tags recovered 0% of Deaver's and Dean's document starts, 16% of Herrnstein's). Not used to set "
             "the rule.\n")
    L.append("| folder | class | pages | change | tagged | year | implied documents |")
    L.append("|---|---|---:|---:|---:|---:|---:|")
    for m in folders:
        if any(n in os.path.basename(m["folder"]) for n in DEV_NAMES):
            L.append(f"| {m['folder']} | {m['class']} | {m['pages']:,} | {pct(m['change'])} | {pct(m['tagged'])} | "
                     f"{pct(m['year'])} | {m['docs']:,} |")
    L.append("\n## Distribution of the change share (folders with 5+ tagged page photos)\n")
    bins = [(0, .03), (.03, .10), (.10, .25), (.25, .50), (.50, .75), (.75, 1.01)]
    L.append("| change share | folders | photos |")
    L.append("|---|---:|---:|")
    for lo, hi in bins:
        sel = [m for m in folders if m["class"] not in ("small", "untagged") and lo <= m["change"] < hi]
        L.append(f"| {pct(lo)}–{pct(min(hi, 1))} | {len(sel)} | {sum(m['photos'] for m in sel):,} |")
    L.append("\n## Noise sample\n")
    L.append("Pending the owner: 40 implied boundaries and 40 implied continuations drawn at random (seed 36) from "
             "per-document folders, shown blind and shuffled in `~/Library/Caches/ArchiveSuiteRehearsal/"
             "corpus-survey/pack/index.html`. The measured noise rate is added here by "
             "`corpus_survey.py score` once the owner's answers are in.\n")
    with open(out, "w") as f:
        f.write("\n".join(L) + "\n")


def cmd_pack(args):
    with open(os.path.join(CACHE, "pairs.json")) as f:
        pairs = json.load(f)
    flat = [(folder, a, b, c) for folder, ps in sorted(pairs.items()) for a, b, c in ps]
    rng = random.Random(SEED)
    bnd = rng.sample([p for p in flat if p[3]], args.n)
    cont = rng.sample([p for p in flat if not p[3]], args.n)
    cases = bnd + cont
    rng.shuffle(cases)
    out = os.path.join(CACHE, "pack")
    thumbs = os.path.join(out, "thumbs")
    os.makedirs(thumbs, exist_ok=True)
    key, rows = [], []
    for i, (folder, a, b, change) in enumerate(cases, 1):
        cid = f"c{i:02d}"
        key.append({"id": cid, "folder": folder, "left": a, "right": b, "implied": "new" if change else "same"})
        imgs = []
        for side, name in (("l", a), ("r", b)):
            dst = os.path.join(thumbs, f"{cid}{side}.jpg")
            if not os.path.exists(dst):
                subprocess.run(["sips", "-s", "format", "jpeg", "-Z", "900",
                                os.path.join(args.corpus, folder, name), "--out", dst],
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            imgs.append(f"thumbs/{cid}{side}.jpg")
        rows.append((cid, folder, a, b, imgs))
    with open(os.path.join(out, "key.json"), "w") as f:
        json.dump(key, f, indent=1)
    write_pack_html(rows, os.path.join(out, "index.html"))
    print(f"{len(cases)} cases -> {out}/index.html (key in key.json; not shown in the page)")


def write_pack_html(rows, path):
    e = html.escape
    parts = ["""<!doctype html><meta charset="utf-8"><title>Corpus tag noise check</title>
<style>body{font:15px -apple-system,sans-serif;margin:24px;max-width:1500px}
.case{border-top:2px solid #ccc;padding:12px 0}.pair{display:flex;gap:12px}
.pair figure{margin:0;flex:1}.pair img{width:100%;border:1px solid #999}
figcaption{font-size:12px;color:#555}label{margin-right:18px}
#out{width:100%;height:160px}</style>
<h1>Corpus tag noise check (W36.seg-corpus-survey)</h1>
<p>80 neighbouring photo pairs from folders tagged per document, mixed and shown blind. For each pair, judge
from the pages themselves: does the RIGHT photo start a new document, or continue the left one? Answers are
saved in this browser as you go. When done, press <b>Export</b> and paste the text into a file (or a reply).</p>
"""]
    for cid, folder, a, b, imgs in rows:
        parts.append(f"""<div class="case" id="{cid}"><b>{cid}</b> · {e(folder)}
<div class="pair"><figure><img loading="lazy" src="{imgs[0]}"><figcaption>{e(a)}</figcaption></figure>
<figure><img loading="lazy" src="{imgs[1]}"><figcaption>{e(b)}</figcaption></figure></div>
<label><input type="radio" name="{cid}" value="new"> right starts a NEW document</label>
<label><input type="radio" name="{cid}" value="same"> right CONTINUES the left</label>
<label><input type="radio" name="{cid}" value="unsure"> can't tell</label></div>""")
    parts.append("""<p><button onclick="exp()">Export</button> <span id="cnt"></span></p><textarea id="out"></textarea>
<script>
const K='corpus-survey-answers';const s=JSON.parse(localStorage.getItem(K)||'{}');
document.querySelectorAll('input[type=radio]').forEach(r=>{if(s[r.name]===r.value)r.checked=true;
r.addEventListener('change',()=>{s[r.name]=r.value;localStorage.setItem(K,JSON.stringify(s));cnt();});});
function cnt(){document.getElementById('cnt').textContent=Object.keys(s).length+' of """ + str(len(rows)) + """ answered';}
function exp(){document.getElementById('out').value=Object.keys(s).sort().map(k=>k+','+s[k]).join('\\n');}
cnt();
</script>""")
    with open(path, "w") as f:
        f.write("\n".join(parts))


def score(key, answers):
    """key: [{id, implied}], answers: {id: new|same|unsure} -> per-implied-kind (right, wrong, unsure)."""
    res = {"new": [0, 0, 0], "same": [0, 0, 0]}
    for k in key:
        a = answers.get(k["id"])
        if a is None:
            continue
        r = res[k["implied"]]
        if a == "unsure":
            r[2] += 1
        elif a == k["implied"]:
            r[0] += 1
        else:
            r[1] += 1
    return res


def cmd_score(args):
    with open(os.path.join(CACHE, "pack", "key.json")) as f:
        key = json.load(f)
    answers = {}
    with open(args.answers) as f:
        for line in f:
            if "," in line:
                cid, a = line.strip().split(",", 1)
                answers[cid.strip()] = a.strip()
    res = score(key, answers)
    for kind, label in (("new", "implied boundaries"), ("same", "implied continuations")):
        right, wrong, unsure = res[kind]
        n = right + wrong
        print(f"{label}: {right} right, {wrong} wrong, {unsure} unsure; "
              f"noise {pct(wrong / n) if n else 'n/a'} of {n} judged")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus", default=CORPUS)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("survey"); s.add_argument("--results", default=RESULTS)
    p = sub.add_parser("pack"); p.add_argument("--n", type=int, default=40)
    c = sub.add_parser("score"); c.add_argument("answers")
    args = ap.parse_args()
    {"survey": cmd_survey, "pack": cmd_pack, "score": cmd_score}[args.cmd](args)


if __name__ == "__main__":
    main()
