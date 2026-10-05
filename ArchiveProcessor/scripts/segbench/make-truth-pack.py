#!/usr/bin/env python3
"""Build the owner's ground-truth review pack for W36.seg-truth.

Reads the five ground-truth folders (page photos plus a `File Number,Status` CSV each) and the OCR
snippets the spring Gemini runs saved under `test_results/`, picks the pages the owner should look at,
and writes an HTML pack OUTSIDE git:

    ~/Library/Caches/ArchiveSuiteRehearsal/seg-truth/index.html   the cases, with thumbnails
    ~/Library/Caches/ArchiveSuiteRehearsal/seg-truth/rules.html   the draft document rules
    ~/Library/Caches/ArchiveSuiteRehearsal/seg-truth/thumbs/      `sips -Z 800` copies of the photos

Read-only on the data folder: it lists directories, reads CSV/JSON, and asks `sips` to write resized
copies into the pack folder. It never writes into `Test Files/`, does no OCR and makes no network call.
Stdlib only, plus macOS `sips`.

    python3 make-truth-pack.py                  # build the pack (thumbnails are reused if present)
    python3 make-truth-pack.py --markdown       # print the case list as text (no images, no names)
    python3 make-truth-pack.py --data DIR --out DIR --no-thumbs

The case rules are in `find_cases()`; the rule text is in `RULES`. The committed copy of both is
`execution-plans/segmentation/02-truth-check.md`, written from `--markdown`.
"""
import argparse
import csv
import html
import json
import os
import re
import subprocess
import sys

DEFAULT_DATA = os.path.expanduser(
    "~/Claude/Archive Suite/ArchiveProcessor/Test Files/Ground Truth Segmentation")
DEFAULT_OUT = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/seg-truth")

# Folder name -> the key the spring runs used for their result files.
RESULT_KEYS = {"RG 165 — War Department": "RG165"}
COLLECTION_ORDER = ["Dean", "Deaver", "Herrnstein", "RG 165 — War Department", "Stanton"]
RUNS = ["", "improved_v1", "improved_v2"]   # baseline, then the two later runs

LABEL_WORDS = {"Box": "Box label", "Folder": "Folder label", "New": "Start of a new document",
               "Cont": "Continues the document before"}


# ---------------------------------------------------------------- loading

def short_name(folder):
    return folder.split(" — ")[0]


def load_collection(data, folder):
    path = os.path.join(data, folder)
    names = os.listdir(path)
    csvs = [n for n in names if n.lower().endswith(".csv")]
    if len(csvs) != 1:
        sys.exit(f"{folder}: expected one CSV, found {csvs}")
    labels = {}
    with open(os.path.join(path, csvs[0]), newline="", encoding="utf-8-sig") as fh:
        for row in csv.DictReader(fh):
            num = (row.get("File Number") or "").strip()
            status = (row.get("Status") or "").strip()
            if not num:
                continue            # trailing blank rows
            labels[int(num)] = status
    images = {}
    for n in names:
        m = re.match(r"^(\d{5})\b", n)
        if m and n.lower().endswith((".jpg", ".jpeg")):
            images[int(m.group(1))] = os.path.join(path, n)
    key = RESULT_KEYS.get(folder, short_name(folder))
    snippets = {}
    for run in RUNS:
        f = os.path.join(data, "test_results", run, f"{key}_results.json")
        if not os.path.exists(f):
            continue
        with open(f, encoding="utf-8") as fh:
            for r in json.load(fh):
                s = (r.get("ocr_snippet") or "").strip()
                if s:
                    snippets.setdefault(r["file_num"], [])
                    if s not in snippets[r["file_num"]]:
                        snippets[r["file_num"]].append(s)
    return {"folder": folder, "name": short_name(folder), "labels": labels,
            "images": images, "snippets": snippets}


def text_lines(snippet, limit):
    """Non-empty lines, skipping the bracketed notes some runs added ("[folder_label]")."""
    out = []
    for line in snippet.splitlines():
        line = line.strip()
        if not line or line.startswith("["):
            continue
        out.append(line)
        if len(out) == limit:
            break
    return out


# ---------------------------------------------------------------- case rules

# A page number of 2 or more near the top of the page. FIRST_ONLY patterns are too loose below line 1.
PAGE_NUM = [re.compile(p, re.I) for p in (
    r"^-\s*(\d{1,3})\s*-",                 # -2-
    r"(?:^|\s)-\s*(\d{1,3})\s*-(?:\s|$)",  # Mr. X   - 2 -   date
    r"\bpage\s+[A-Z]?(\d{1,3})\b",         # Page 2, Page A8
    r"^(\d{1,3})\.?$",                     # a lone number on its own line
    r"\bpg\.?\s*(\d{1,3})\b",              # Pg 2
    r"^\(\s*(\d{1,3})\s*\)$",              # (2)
)]
FIRST_ONLY = [re.compile(p, re.I) for p in (
    r"^(\d{1,3})\.\s",                     # "2." at the very top
    r"^(\d{1,2})[A-Z]$",                   # 6A, 10A (newspaper section pages)
)]
NEWSPAPER = re.compile(r"EXAMINER|SACRAMENTO BEE|CHRONICLE|\bSection\b|[☆✰★]|\*\s*\*|^\d{1,2}A$|Page A\d",
                       re.I)
OPENING = re.compile(r"^(dear\b|my dear\b|gentlemen\b|memorandum\b|memo\b|office memorandum|to\s*:)", re.I)


def page_number_cue(snippets):
    """The first page-number cue (>= 2) in the top three lines of any saved reading, else None."""
    for s in snippets:
        for i, line in enumerate(text_lines(s, 3)):
            for p in PAGE_NUM + (FIRST_ONLY if i == 0 else []):
                m = p.search(line)
                if m and int(m.group(1)) >= 2:
                    return m.group(0).strip(), line
    return None


def opening_cue(snippets):
    """A greeting or memo heading in the top eight lines of any saved reading, else None."""
    if not snippets or page_number_cue(snippets):
        return None
    for s in snippets:
        for line in text_lines(s, 8):
            m = OPENING.search(line)
            if m and line[0].isupper():
                word = m.group(1).strip().rstrip(":")
                return ("a greeting (“Dear …”)" if word.lower() in ("dear", "my dear", "gentlemen")
                        else f"a “{word.upper()}” heading")
    return None


# Hand-named cases from the plan (00-plan.md "The data") and the item brief.
NAMED = [
    ("b", "Dean", [13],
     "Page 13 starts with “-2-” and repeats the addressee and date of the letter on page 12. It is marked as "
     "the start of a new document. Is it page 2 of the letter on page 12?",
     ["Keep as is (13 starts a new document)", "Change 13 to Cont (page 2 of the letter on page 12)"],
     "page 13 starts “-2-”, same addressee and date as page 12"),
    ("b", "Dean", [15],
     "Page 15 has “- 2 -” in its heading and repeats the addressee and date of the letter on page 14. It is "
     "marked as the start of a new document. Is it page 2 of the letter on page 14?",
     ["Keep as is (15 starts a new document)", "Change 15 to Cont (page 2 of the letter on page 14)"],
     "page 15 heading has “- 2 -”, same addressee and date as page 14"),
    ("b", "Dean", [111, 112],
     "Pages 111 and 112 both look like page 2 of the same letter (same addressee, same date, a few weeks after "
     "the letter on page 110). Its page 1 does not seem to be here. 111 is marked New and 112 Cont, which makes "
     "them one two-page document. Which is right?",
     ["Keep as is (one document: the same page photographed twice, rule 5)",
      "Change 112 to New (two copies kept by the archive, each its own document, rule 4)",
      "Change 111 to Cont (both belong to the letter on page 110)"],
     "two copies of a page 2 with the same addressee and date; page 1 apparently absent"),
    ("d", "RG 165", [41, 42],
     "Pages 41 and 42 are both marked as folder labels, one after the other, so the folder at 41 holds nothing. "
     "Page 42 also seems to carry a “classification cancelled” stamp. Are both really folder labels?",
     ["Keep as is (two folder labels; 41 is an empty folder or a second photo of a label)",
      "Change 42 to New (42 is the first page of a document)",
      "Change 41 so it is left out (a repeat photo of a folder label)"],
     "two folder labels in a row; 42 carries a stamp"),
    ("d", "RG 165", [91, 92, 93],
     "Pages 91, 92 and 93 are all marked as box labels. One spring reading of 91 repeated the text of page 90, "
     "a document page; another read it as a box label. Is 91 a box label, and do three box photos in a row "
     "belong here?",
     ["Keep as is (91, 92 and 93 are all box labels)",
      "Change 91 to Cont (it is another page of the document before)",
      "Change some of 91–93 so they are left out (repeat photos of the same box label)"],
     "three box labels in a row; one reading of 91 matched page 90"),
    ("d", "RG 165", list(range(107, 114)),
     "The box ends with seven pages in a row, 107 to 113, all marked as box labels, with no documents after "
     "them. Are these all photos of box labels, and should they stay in the test?",
     ["Keep as is (seven box labels)",
      "Change: leave the repeats out of the test and keep one box label",
      "Change: some of these are document pages (say which in the note)"],
     "seven box labels in a row at the end of the box, no documents after"),
    ("d", "Herrnstein", [64, 65],
     "Page 64 is a folder label and page 65, right after it, is a box label. So folder 64 comes before its box "
     "and holds nothing. Was 64 photographed out of order, or is it an empty folder at the end of the "
     "previous box?",
     ["Keep as is (64 is an empty folder at the end of the previous box)",
      "Change the order: 64 belongs after 65, in the new box",
      "Change 64 so it is left out (a stray photo)"],
     "folder label immediately before a box label"),
]


def find_cases(colls):
    by_name = {c["name"]: c for c in colls}
    named_pages = {(name, n) for _, name, pages, *_ in NAMED for n in pages}
    cases = []
    for kind, name, pages, question, options, summary in NAMED:
        c = by_name[name]
        cases.append({"kind": kind, "coll": c, "pages": pages, "question": question,
                      "options": options, "summary": summary,
                      "current": ", ".join(f"{n}: {c['labels'].get(n, '?')}" for n in pages)})
    for c in colls:
        for n in sorted(c["labels"]):
            if (c["name"], n) in named_pages:
                continue
            status, snips = c["labels"][n], c["snippets"].get(n, [])
            if status == "New":
                cue = page_number_cue(snips)
                if not cue:
                    continue
                num, line = cue
                if NEWSPAPER.search(line) or NEWSPAPER.search(" ".join(text_lines(snips[0], 3))):
                    q = (f"This looks like a newspaper clipping, and the top shows the newspaper’s own page "
                         f"number (“{num}”). It is marked as the start of a new document. Is it a new clipping, "
                         f"or another piece of the clipping before it?")
                    opts = ["Keep as is (a new clipping)", "Change to Cont (part of the clipping before)"]
                    summ = f"newspaper page number “{num}” at the top"
                else:
                    q = (f"This page starts with a page number (“{num}”), but it is marked as the start of a "
                         f"new document. Is it really the first page of a document, or a later page of the "
                         f"document before it?")
                    opts = ["Keep as is (starts a new document)", "Change to Cont (part of the document before)"]
                    summ = f"page number “{num}” at the top"
                cases.append({"kind": "a", "coll": c, "pages": [n], "question": q, "options": opts,
                              "summary": summ, "current": f"{n}: New"})
            elif status == "Cont":
                cue = opening_cue(snips)
                if not cue:
                    continue
                q = (f"This page is marked as continuing the document before it, but it begins like a new "
                     f"letter or memo ({cue}). Is it a new document, or part of the one before (for example "
                     f"something enclosed with it, or a reply written on the same sheets)?")
                opts = ["Keep as is (part of the document before)", "Change to New (a new document)"]
                cases.append({"kind": "c", "coll": c, "pages": [n], "question": q, "options": opts,
                              "summary": f"begins with {cue}", "current": f"{n}: Cont"})
    order = {"b": 0, "a": 1, "c": 2, "d": 3}
    cases.sort(key=lambda k: (order[k["kind"]], COLLECTION_ORDER.index(k["coll"]["folder"]), k["pages"][0]))
    for i, k in enumerate(cases, 1):
        k["id"] = i
    return cases


KIND_TITLES = {
    "b": "Labels that look wrong",
    "a": "Pages marked “new document” that start with a page number of 2 or more",
    "c": "Pages marked “continues” that start like a new letter or memo",
    "d": "Runs of box and folder labels",
}


# ---------------------------------------------------------------- rules

RULES = [
    ("An enclosure — a complete item sent with a letter (a report, a pamphlet, someone else’s letter)",
     "Its own document: mark its first page New.",
     "It has its own author, date and subject. Joined to the cover letter it would take the letter’s date and "
     "tags. It stays next to the letter in the box, so the link is not lost."),
    ("An attachment — something made to go with this letter or memo (“Attachment A”, a list, a table, a "
     "budget) with no date or heading of its own",
     "Part of the letter: mark its pages Cont.",
     "It has no date or author apart from the letter, and it makes no sense on its own."),
    ("A carbon copy of a letter (the sender’s file copy)",
     "Treat it as the letter: its first page is New, like any letter.",
     "In most files the carbon is the only copy the archive has, so it is the document."),
    ("Two copies of the same document kept together (an original and a carbon, or two carbons)",
     "Each copy is its own document: the second copy’s first page is New.",
     "They are separate pieces of paper the archive kept, and one may carry notes the other lacks."),
    ("The same page photographed twice by mistake",
     "Mark the repeat Cont, as part of the same document.",
     "It is one piece of paper; a second document would be false. Leaving the photo out would lose it from "
     "the record."),
    ("An envelope",
     "Part of the letter it held, when it sits next to that letter: mark it Cont. An envelope on its own is "
     "its own document.",
     "Its postmark and addresses date and place that letter."),
    ("A newspaper clipping",
     "Each article is its own document. A second piece of the same article (“continued on page 8”) is Cont. "
     "Several articles in one photo stay one document.",
     "Articles have their own dates and subjects. A photo cannot be split, so one photo is never more than "
     "one document."),
    ("A photograph (a print in the folder)",
     "Its own document. A photo of its back (caption, stamp) is Cont.",
     "A print is an item in its own right; the back belongs to the same print."),
    ("A blank page or the blank back of a sheet",
     "Cont, as part of the document it belongs to.",
     "It carries nothing of its own and should not start a document."),
]


# ---------------------------------------------------------------- output

def thumb_name(coll, n):
    return f"{coll['name'].replace(' ', '')}-{n:05d}.jpg"


def make_thumbs(cases, out):
    tdir = os.path.join(out, "thumbs")
    os.makedirs(tdir, exist_ok=True)
    wanted = set()
    for k in cases:
        for n in shown_pages(k):
            wanted.add((k["coll"]["name"], n))
    by_name = {k["coll"]["name"]: k["coll"] for k in cases}
    made = missing = 0
    for name, n in sorted(wanted):
        c = by_name[name]
        src = c["images"].get(n)
        if not src:
            missing += 1
            continue
        dst = os.path.join(tdir, thumb_name(c, n))
        if os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(src):
            continue
        subprocess.run(["sips", "-Z", "800", src, "--out", dst], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        made += 1
    return made, missing, len(wanted)


def shown_pages(k):
    labels = k["coll"]["labels"]
    first, last = k["pages"][0], k["pages"][-1]
    out = []
    if first - 1 in labels:
        out.append(first - 1)
    out += k["pages"]
    if last + 1 in labels:
        out.append(last + 1)
    return out


def esc(s):
    return html.escape(s, quote=True)


CSS = """
body{font:16px/1.45 -apple-system,Helvetica,Arial,sans-serif;max-width:1500px;margin:1.5em auto;padding:0 1em;
color:#222;background:#fafafa}
h1{font-size:1.6em} h2{margin-top:2em;border-bottom:2px solid #ccc;padding-bottom:.2em}
.case{background:#fff;border:1px solid #ddd;border-radius:8px;padding:1em 1.2em;margin:1.2em 0}
.case h3{margin:.1em 0 .5em}
.row{display:flex;gap:12px;overflow-x:auto;align-items:flex-start}
.page{flex:0 0 auto;width:320px;font-size:.85em}
.page img{width:320px;height:auto;border:1px solid #bbb;background:#eee;display:block}
.page.focus img{border:4px solid #c60}
.lab{font-weight:600;margin:.3em 0}
.page.focus .lab{color:#c60}
pre{white-space:pre-wrap;font:12px/1.35 Menlo,monospace;background:#f3f3f3;padding:.4em;margin:.3em 0;
max-height:14em;overflow:auto}
.q{font-size:1.05em;margin:.8em 0 .4em;font-weight:600}
label{display:block;margin:.2em 0}
textarea{width:100%;min-height:2.5em;font:inherit}
#answers{width:100%;min-height:12em;font:13px Menlo,monospace}
.note{color:#555;font-size:.9em}
.toc a{margin-right:1em}
"""

JS = """
const KEY='seg-truth-answers';
function load(){const a=JSON.parse(localStorage.getItem(KEY)||'{}');
 for(const [id,v] of Object.entries(a)){const r=document.querySelector(`input[name="c${id}"][value="${v.choice}"]`);
  if(r)r.checked=true;const t=document.getElementById('n'+id);if(t)t.value=v.note||'';}}
function save(){const a={};document.querySelectorAll('.case').forEach(c=>{const id=c.dataset.id;
 const r=c.querySelector('input[type=radio]:checked');const n=document.getElementById('n'+id).value;
 if(r||n)a[id]={choice:r?r.value:'',note:n};});localStorage.setItem(KEY,JSON.stringify(a));}
function collect(){save();const lines=[];document.querySelectorAll('.case').forEach(c=>{const id=c.dataset.id;
 const r=c.querySelector('input[type=radio]:checked');const n=document.getElementById('n'+id).value.trim();
 lines.push(`Case ${id} (${c.dataset.where}): ${r?r.parentElement.textContent.trim():'NOT ANSWERED'}`+(n?` | note: ${n}`:''));});
 const t=document.getElementById('answers');t.value=lines.join('\\n');t.select();}
function turn(i){const d=((+i.dataset.deg||0)+90)%360;i.dataset.deg=d;i.style.transform=`rotate(${d}deg)`;
 i.style.margin=(d%180)?'60px 0':'0';}
document.addEventListener('change',save);document.addEventListener('input',save);window.onload=load;
"""


def page_html(k, n, focus):
    c = k["coll"]
    snips = c["snippets"].get(n, [])
    label = c["labels"].get(n, "?")
    role = "this page" if focus else ("page before" if n < k["pages"][0] else "page after")
    src = f"thumbs/{esc(thumb_name(c, n))}"
    img = (f'<img loading="lazy" src="{src}" alt="page {n}" onclick="turn(this)" title="Click to turn">'
           f'<a class="note" href="{src}" target="_blank">open larger</a>' if n in c["images"]
           else "<p>(no photo found)</p>")
    if focus:
        texts = "".join(f"<pre>{esc(s[:300])}</pre>" for s in snips) or "<pre>(no saved text)</pre>"
    else:
        texts = f"<pre>{esc(snips[0][:120])}</pre>" if snips else "<pre>(no saved text)</pre>"
    return (f'<div class="page{" focus" if focus else ""}">{img}'
            f'<div class="lab">Page {n} — {role}<br>Marked: {esc(LABEL_WORDS.get(label, label))}</div>'
            f"{texts}</div>")


def write_html(cases, out):
    parts = [f"<!doctype html><meta charset='utf-8'><title>Ground truth check</title><style>{CSS}</style>"
             f"<script>{JS}</script>",
             "<h1>Ground truth check — segmentation test boxes</h1>",
             "<p>These are the pages in your five labelled boxes that look as if their label might be wrong, "
             "or that raise a question only you can settle. For each one you see the page (orange frame), "
             "the page before and the page after, how it is marked now, and the text the spring test runs "
             "saved for it. That text is a machine reading of the top of the page; it can be wrong, and "
             "sometimes it shows the previous page instead.</p>",
             "<p>Some photos are sideways, as they came off the camera. Click a picture to turn it a "
             "quarter turn, or use “open larger”.</p>",
             "<p>Pick one answer per case. Your answers are kept in this browser as you go. When you are done, "
             "press <b>Collect my answers</b> at the bottom and paste the text into the session. Nothing is "
             "changed in your files until you approve it.</p>",
             '<p>The draft rules for what counts as one document are on a separate page: '
             '<a href="rules.html">rules.html</a>. Some answers depend on them, so it may help to read them '
             "first.</p>"]
    counts = {kind: sum(1 for k in cases if k["kind"] == kind) for kind in KIND_TITLES}
    parts.append('<p class="toc">' + "".join(
        f'<a href="#k{kind}">{esc(KIND_TITLES[kind])} ({counts[kind]})</a>' for kind in "bacd") + "</p>")
    for kind in "bacd":
        parts.append(f'<h2 id="k{kind}">{esc(KIND_TITLES[kind])} — {counts[kind]} cases</h2>')
        for k in [k for k in cases if k["kind"] == kind]:
            c = k["coll"]
            pages = k["pages"]
            where = f"{c['name']} {pages[0]}" + (f"–{pages[-1]}" if len(pages) > 1 else "")
            nums = str(pages[0]) + (f"–{pages[-1]}" if len(pages) > 1 else "")
            parts.append(f'<div class="case" data-id="{k["id"]}" data-where="{esc(where)}">'
                         f'<h3>Case {k["id"]} — {esc(c["name"])}, page{"s" if len(pages) > 1 else ""} '
                         f'{nums}</h3>')
            parts.append('<div class="row">' + "".join(
                page_html(k, n, n in pages) for n in shown_pages(k)) + "</div>")
            parts.append(f'<div class="q">{esc(k["question"])}</div>')
            for j, opt in enumerate(k["options"]):
                parts.append(f'<label><input type="radio" name="c{k["id"]}" value="{j}"> {esc(opt)}</label>')
            parts.append(f'<label><input type="radio" name="c{k["id"]}" value="x"> Not sure — I need to look '
                         f"at the original</label>")
            parts.append(f'<textarea id="n{k["id"]}" placeholder="Note (optional)"></textarea></div>')
    parts.append('<h2>Your answers</h2><p><button onclick="collect()">Collect my answers</button></p>'
                 '<textarea id="answers" placeholder="Press the button, then copy this text."></textarea>')
    with open(os.path.join(out, "index.html"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(parts))

    r = [f"<!doctype html><meta charset='utf-8'><title>Draft document rules</title><style>{CSS}</style>",
         "<h1>Draft rules: what counts as one document</h1>",
         "<p>The test boxes and the app need one answer to “where does a document start?” for the awkward "
         "cases. Each rule below has a recommended default and the reason. Approve it, or say what you want "
         "instead.</p>",
         "<p class='note'>Box and folder labels keep their own marks (Box, Folder) and are never part of a "
         "document.</p>"]
    for i, (what, default, why) in enumerate(RULES, 1):
        r.append(f'<div class="case"><h3>{i}. {esc(what)}</h3><p><b>Recommended:</b> {esc(default)}</p>'
                 f"<p><b>Why:</b> {esc(why)}</p></div>")
    r.append('<p><a href="index.html">Back to the cases</a></p>')
    with open(os.path.join(out, "rules.html"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(r))


def markdown(cases):
    out = []
    for kind in "bacd":
        sub = [k for k in cases if k["kind"] == kind]
        out.append(f"### {KIND_TITLES[kind]} — {len(sub)}\n")
        out.append("| Case | Collection | File number(s) | Current label | What to check |")
        out.append("|---|---|---|---|---|")
        for k in sub:
            p = k["pages"]
            nums = str(p[0]) if len(p) == 1 else f"{p[0]}–{p[-1]}"
            cur = k["current"] if len(p) <= 3 else f"all {k['coll']['labels'][p[0]]}"
            out.append(f"| {k['id']} | {k['coll']['name']} | {nums} | {cur} | {k['summary']} |")
        out.append("")
    out.append("### Draft document rules\n")
    for i, (what, default, why) in enumerate(RULES, 1):
        out.append(f"{i}. **{what}.** Recommended: {default} Why: {why}")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--data", default=DEFAULT_DATA)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--no-thumbs", action="store_true")
    ap.add_argument("--markdown", action="store_true", help="print the case list as text and stop")
    a = ap.parse_args()
    data, out = os.path.abspath(a.data), os.path.abspath(a.out)
    if out == data or out.startswith(data + os.sep):
        sys.exit("refusing to write inside the ground-truth folder")
    colls = [load_collection(data, f) for f in COLLECTION_ORDER]
    cases = find_cases(colls)
    if a.markdown:
        print(markdown(cases))
        return
    os.makedirs(out, exist_ok=True)
    if not a.no_thumbs:
        made, missing, wanted = make_thumbs(cases, out)
        print(f"thumbnails: {wanted} needed, {made} made now, {missing} without a photo")
    write_html(cases, out)
    counts = {kind: sum(1 for k in cases if k["kind"] == kind) for kind in "bacd"}
    print(f"cases: {len(cases)} ({', '.join(f'{k}={v}' for k, v in counts.items())})")
    print(f"open: open '{os.path.join(out, 'index.html')}'")


if __name__ == "__main__":
    main()
