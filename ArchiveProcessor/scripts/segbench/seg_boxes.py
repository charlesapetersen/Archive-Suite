#!/usr/bin/env python3
"""W46.fix-seg-boxes: draft truth for the three new locked segmentation boxes, and the owner's ruling sheets.

The owner named the boxes on 2026-10-21 (execution-plans/processing-review/STATE.md, "Locked boxes named"), and
replaced Rawls with a box of handwritten letters on 2026-10-29 (W46.seg-boxes-hand: Rawls' segmentation principles
were unclear; it stays for handwriting OCR and W46.date-traceable, and its retired sheet is in the cache as
rawls-retired-20261029/):

  sasha     Young, Sasha letters, photos 00001-00180 (180 photos): her handwritten letters to Michael Young, one
            letter a document, all on one set of collection tags, so no document tags; only Red (box) and Purple
            (folder) label tags. The owner rules every gap. The corpus holds the JPEGs themselves (no per-photo
            PDF), so the thumbnails are turned by EXIF alone.
  sir       Stanford Illustrated Review (147 photos), pages of alumni-magazine issues photographed one by one. Ruled on
            the article-within-issue rule (owner, 2026-10-29; W46.seg-boxes-sir-article): an article inside an issue
            is its own document and takes the issue's date and journal title from its cover or contents page; the
            full-magazine rule of 2026-10-05 is only the fallback where splitting an issue by article is too
            difficult. The tags and the W41.seg-label-clean teacher were both made under the old rule, so neither
            drafts it: the draft is a page-by-page reading kept in the cache (reading.json), and the owner rules
            every gap except a byte-identical repeat photo, each case shown with its issue's cover or contents
            photo. The sheet built on the old rule is kept as sir-fullmag-retired-20261029/.
  sc0122    SC0122 News Service (200 photos), reading-room clippings mixed with other papers; as sir.

Every sheet is blind: it shows the two photos either side of a gap and never the tag, the teacher or any model,
so the owner's ruling leans on nothing a later bench run is scored against (the same reason the W46 OCR sheets
never reveal the current reading). The key, with the draft and the teacher's P(new), stays beside the sheet.

READ ONLY on the corpus and the JPEG tree: getxattr(2) for tags (corpus_survey.read_tags), Pillow reading a
JPEG and writing an upright thumbnail into the cache. No model calls: the teacher's answers were made by the
W41.seg-label-clean run and are read from the corpus-pairs cache. Only `lock` writes under `Test Files/`: it copies
each JPEG original byte for byte, renumbered 1..N, beside the folded truth CSV and a lock.json (source photo, sha-256,
the sheet's turn where known, the gaps the owner left unsure, the trained-on note), then makes the folder read-only.

    python3 seg_boxes.py draft [BOX ...]  # draft.json + draft.csv per box, counts in segbench-results/seg-boxes.md
    python3 seg_boxes.py sheet [BOX ...]  # sheet.html + key.json + thumbnails per box, in the cache
    python3 seg_boxes.py fold BOX FILE    # the owner's exported answers -> truth.csv beside the draft (cache)
    python3 seg_boxes.py lock [BOX ...]   # W46.fix-seg-boxes-lock: freeze a box into Test Files (once; refuses to redo)
    python3 seg_boxes.py verify [BOX ...] # re-hash a frozen box against its lock.json

sir's reading.json is {"pages": [{"n", "issue": "YYYY-MM" or null, "kind", "starts"}], "fallback": {"YYYY-MM":
reason}}: `kind` is a FRONT_KINDS page or another page kind, `starts` whether the photo begins an article (or front
matter) against the photo before it, and `fallback` the issues whose run stays one document.

Cache (outside git, private pages): ~/Library/Caches/ArchiveSuiteRehearsal/seg-boxes/<box>/
"""
import argparse
import collections
import csv
import hashlib
import html
import json
import os
import re
import subprocess
import sys

import corpus_survey as CS

CORPUS = os.path.expanduser("~/Desktop/Google Drive/Archival Photos")
JPEGS = os.path.expanduser("~/Desktop/Google Drive/Archival Photos JPEGS")
PAIRS_CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/corpus-pairs")
CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/seg-boxes")
RESULTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "segbench-results", "seg-boxes.md")
THUMB_PX = 1100
ORIENT_MIN = 0.65   # ocr_truth.orient_like_pdf: true pairs measured 0.69-0.98, mismatches 0.16-0.48
LEAD = re.compile(r"^\s*(\d{3,})")

# Owner, 2026-10-29 (W46.seg-boxes-overlap-ok, answer b): both tagged boxes were wholly in W41.seg-label-clean's train
# split, so the students' scores on them are trained-on, never held-out; corpus_pairs.EXCLUDE keeps them out of any retrain.
TRAINED_ON = "W41.seg-finetune 2B and 4B students (W41.seg-label-clean train split): report their scores as trained-on"
# A label card the owner ruled that is a BOX card (the sheet's 'label' folds to Folder): {box: (photo, ...)}. None so far:
# SC0122 photo 139 is a second card after its box card at photo 1, Sasha photo 164 is a folder card (YONG 2/2, owner).
BOX_CARDS = {}

BOXES = {
    "sasha": {"name": "Young, Sasha letters 00001-00180", "folder": "Cambridge/Young, Sasha",
              "jpegs": "Churchill Archives/Young, Sasha", "first": 1, "last": 180, "draft": "label tags only",
              "locked": ("Sasha", "Young, Sasha")},
    "sir": {"name": "Stanford Illustrated Review", "folder": "Stanford University Archives/Stanford Illustrated Review",
            "draft": "article reading", "prefix": "ar", "locked": ("IllustratedReview", "Stanford Illustrated Review"),
            "trained_on": TRAINED_ON},
    "sc0122": {"name": "SC0122 News Service", "folder": "Stanford University Archives/SC0122 — News Service",
               "draft": "tags + teacher", "locked": ("SC0122", "SC0122 — News Service"), "trained_on": TRAINED_ON},
}
ANSWERS = ("new", "same", "label", "fallback", "unsure")
FRONT_KINDS = ("cover", "masthead_contents")   # the pages an article takes its issue date and journal title from


def photo_number(name):
    m = LEAD.match(name)
    return int(m.group(1)) if m else None


def label_of(tags):
    """A photo's label from its Finder tags alone: Red is a box card, Purple a folder card (corpus_survey)."""
    if "Red" in tags:
        return "Box"
    if "Purple" in tags:
        return "Folder"
    return None


def gap_needs_ruling(tag, p_new):
    """A tagged box's gap goes to the owner when the teacher is on the other side of 0.5 from the tag, or never
    judged it. tag: 'new' | 'cont'; p_new: the teacher's mean P(new) or None."""
    if p_new is None:
        return True
    return (p_new >= 0.5) != (tag == "new")


def untagged_gap_needs_ruling(left_label, right_label):
    """Untagged box: every gap between two page photos is ruled; a gap beside a tagged label photo is a start by
    definition (a label photo is never part of a document) and is not asked."""
    return left_label is None and right_label is None


def article_gap_needs_ruling(left_sha, right_sha):
    """Article-rule box: every gap is ruled except a byte-identical repeat photo, which continues its document by
    the 2026-10-05 rules (a repeat photo is part of its document)."""
    return left_sha != right_sha


def issue_fronts(reading):
    """{n: the issue's cover or contents photo for photo n, or None}: the latest front photo at or before n of the
    same issue. A photo whose issue is unknown, or whose issue has no front photographed before it, gets None."""
    fronts, last = {}, {}
    for p in sorted(reading, key=lambda p: p["n"]):
        if p["issue"] and p["kind"] in FRONT_KINDS:
            last[p["issue"]] = p["n"]
        fronts[p["n"]] = last.get(p["issue"]) if p["issue"] else None
    return fronts


def article_draft(reading, fallback):
    """{n: New | Cont} on the article rule. Inside a fallback issue only a change of issue starts a document (the
    issue's run is one document); elsewhere a photo starts one where the reading says so."""
    by = {p["n"]: p for p in reading}
    out, prev = {}, None
    for n in sorted(by):
        p = by[n]
        if prev is None:
            out[n] = "New"
        elif p["issue"] in fallback and p["issue"] == by[prev]["issue"]:
            out[n] = "Cont"
        else:
            out[n] = "New" if p["starts"] else "Cont"
        prev = n
    return out


def rd_fallback(key):
    with open(os.path.join(CACHE, key, "reading.json"), encoding="utf-8") as f:
        return json.load(f).get("fallback", {})


def file_sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def read_jsonl(path):
    with open(path, encoding="utf-8") as f:
        return [json.loads(l) for l in f]


def tagged_pages(folder):
    """[{n, pdf, jpeg, label}] in capture order for a per-document folder, from the corpus-pairs windows cache,
    and {right pdf: gap} from its cleaned labels. Renumbered 1..N, as the locked boxes' CSVs are."""
    seen = {}
    for w in read_jsonl(os.path.join(PAIRS_CACHE, "windows.jsonl")):
        for p in w["pages"]:
            if os.path.dirname(p["pdf"]) == folder:
                seen[p["pdf"]] = {"pdf": p["pdf"], "jpeg": p["jpeg"], "label": p["label"], "split": w["split"]}
    pages = sorted(seen.values(), key=lambda p: (photo_number(os.path.basename(p["pdf"])) or 0, p["pdf"]))
    gaps = {g["right"]: g for g in read_jsonl(os.path.join(PAIRS_CACHE, "labels.jsonl"))
            if os.path.dirname(g["right"]) == folder}
    return pages, gaps


def draft_tagged(key):
    box = BOXES[key]
    pages, gaps = tagged_pages(box["folder"])
    if not pages:
        raise SystemExit(f"{key}: no pages for {box['folder']!r} in the corpus-pairs cache")
    rows = []
    for i, p in enumerate(pages, 1):
        g = gaps.get(p["pdf"]) if i > 1 else None
        if i > 1 and g is None:
            raise SystemExit(f"{key}: no cleaned gap into {p['pdf']}")
        rows.append({"n": i, "pdf": p["pdf"], "jpeg": p["jpeg"], "draft": p["label"], "split": p["split"],
                     "tag_gap": g["tag"] if g else None, "p_new": g["p_new"] if g else None,
                     "ask": bool(g) and gap_needs_ruling(g["tag"], g["p_new"])})
    return rows


def draft_article(key):
    """The article-rule draft for a tagged per-document folder: the photos as draft_tagged finds them (keeping the
    tag and teacher for the key), relabelled from the reading in the cache, and every non-repeat gap asked."""
    rows = draft_tagged(key)
    with open(os.path.join(CACHE, key, "reading.json"), encoding="utf-8") as f:
        rd = json.load(f)
    reading, fallback = rd["pages"], rd.get("fallback", {})
    if sorted(p["n"] for p in reading) != [r["n"] for r in rows]:
        raise SystemExit(f"{key}: reading.json does not cover photos 1..{len(rows)}")
    draft, fronts = article_draft(reading, fallback), issue_fronts(reading)
    by = {p["n"]: p for p in reading}
    shas = [file_sha(os.path.join(JPEGS, r["jpeg"])) for r in rows]
    for i, r in enumerate(rows):
        p = by[r["n"]]
        r["repeat"] = bool(i) and not article_gap_needs_ruling(shas[i - 1], shas[i])
        r.update({"tag_draft": r["draft"], "draft": "Cont" if r["repeat"] else draft[r["n"]], "issue": p["issue"],
                  "kind": p["kind"], "front": fronts[r["n"]], "fallback": p["issue"] in fallback,
                  "ask": bool(i) and not r["repeat"]})
    return rows


def jpeg_of_pdfs():
    with open(os.path.join(PAIRS_CACHE, "pairs.tsv"), encoding="utf-8") as f:
        return {r["pdf"]: r["jpeg"] for r in csv.DictReader(f, delimiter="\t")}


def draft_untagged(key):
    """A box with no document tags, whose corpus folder holds the photos as JPEGs (no per-photo PDF, so `pdf` is
    None). Its tags are read from the corpus JPEG; the JPEG originals tree supplies the image."""
    box = BOXES[key]
    names = {photo_number(n): n for n in os.listdir(os.path.join(CORPUS, box["folder"])) if n.endswith(".jpeg")}
    originals = {photo_number(n): n for n in os.listdir(os.path.join(JPEGS, box["jpegs"])) if n.endswith(".jpeg")}
    rows = []
    for i, num in enumerate(range(box["first"], box["last"] + 1), 1):
        if num not in names or num not in originals:
            raise SystemExit(f"{key}: no photo {num:05d} in the corpus or the JPEG originals")
        rows.append({"n": i, "pdf": None, "jpeg": os.path.join(box["jpegs"], originals[num]),
                     "label": label_of(CS.read_tags(os.path.join(CORPUS, box["folder"], names[num])))})
    for i, r in enumerate(rows):
        # The draft: label photos from the tags, the first page after one a start, every other page undecided
        # (the owner rules it). "Cont" is only a placeholder so the CSV parses; `ask` marks what is undecided.
        prev = rows[i - 1]["label"] if i else "Box"
        r["draft"] = r["label"] or ("New" if prev else "Cont")
        r["ask"] = bool(i) and untagged_gap_needs_ruling(prev, r["label"])
        r["split"] = None
        r["tag_gap"] = None
        r["p_new"] = None
    return rows


def write_draft(key, rows):
    d = os.path.join(CACHE, key)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "draft.json"), "w", encoding="utf-8") as f:
        json.dump({"box": BOXES[key], "pages": rows}, f, indent=0, ensure_ascii=False)
    with open(os.path.join(d, "draft.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["File Number", "Status"])
        w.writerows((r["n"], r["draft"]) for r in rows)


def summary(key, rows):
    labels = collections.Counter(r["draft"] for r in rows)
    asked = [r for r in rows if r["ask"]]
    out = {"pages": len(rows), "gaps": len(rows) - 1, "labels": dict(sorted(labels.items())), "asked": len(asked),
           "train_split": sum(1 for r in rows if r["split"] == "train")}
    if BOXES[key]["draft"] == "article reading":
        issues = sorted({r["issue"] for r in rows if r["issue"]})
        fronted = {r["issue"] for r in rows if r["issue"] and r["front"]}
        out.update({
            "issues": len(issues), "issues_with_front": len(fronted),
            "photos_issue_unknown": sum(1 for r in rows if not r["issue"]),
            "photos_without_front": sum(1 for r in rows if not r["front"]),
            "issues_inferred": sum(1 for k in issues if k.endswith("?")),
            "fallback_issues": sorted({r["issue"] for r in rows if r["fallback"]}), "fallback_reasons": rd_fallback(key),
            "fallback_photos": sum(1 for r in rows if r["fallback"]), "repeats": sum(1 for r in rows if r["repeat"]),
            "tag_new_now_cont": sum(1 for r in rows[1:] if r["tag_draft"] == "New" and r["draft"] == "Cont"),
            "tag_cont_now_new": sum(1 for r in rows[1:] if r["tag_draft"] == "Cont" and r["draft"] == "New")})
        return out
    by = collections.Counter((r["tag_gap"], "teacher new" if (r["p_new"] or 0) >= 0.5 else "teacher cont")
                             for r in asked if r["tag_gap"])
    out.update({"asked_by": {f"{a} / {b}": n for (a, b), n in sorted(by.items())},
                "unjudged": sum(1 for r in rows[1:] if r["tag_gap"] and r["p_new"] is None)})
    return out


def cmd_draft(a):
    """Drafts the named boxes (all by default); the others keep their summary from the last run."""
    path = os.path.join(CACHE, "summary.json")
    out = {}
    if os.path.exists(path):
        with open(path) as f:
            out = {k: v for k, v in json.load(f).items() if k in BOXES}
    for key in a.boxes or BOXES:
        rows = {"label tags only": draft_untagged, "article reading": draft_article}.get(
            BOXES[key]["draft"], draft_tagged)(key)
        write_draft(key, rows)
        out[key] = summary(key, rows)
        print(key, json.dumps(out[key]))
    out = {k: out[k] for k in BOXES if k in out}
    with open(path, "w") as f:
        json.dump(out, f, indent=1)
    write_results(out)


def write_results(out):
    lines = ["# W46.fix-seg-boxes — draft truth for three new locked segmentation boxes", "",
             "Written by `seg_boxes.py draft` (numbers only: no names, text or images). The boxes were named by the",
             "owner on 2026-10-21 (`execution-plans/processing-review/STATE.md`); on 2026-10-29 the owner replaced",
             "Rawls papers 00057-00252 with the Young, Sasha letters (W46.seg-boxes-hand), since Rawls' segmentation",
             "principles were unclear, and had the Illustrated Review re-ruled on the article-within-issue rule",
             "(W46.seg-boxes-sir-article). Drafts, keys and the blind ruling",
             "sheets are in `~/Library/Caches/ArchiveSuiteRehearsal/seg-boxes/<box>/`, outside git. No bench or paid model calls:",
             "the teacher's P(new) is the W41.seg-label-clean run's (`label-clean.md`); the Illustrated Review's",
             "draft is a page-by-page reading made in the coding session (below).", "",
             "| box | draft from | photos | gaps | New | Cont | Box | Folder | gaps for the owner | photos in label-clean's train split |",
             "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for key, s in out.items():
        lab = s["labels"]
        if BOXES[key]["draft"] == "label tags only":
            new, cont = lab.get("New", 0), "—"
        else:
            new, cont = lab.get("New", 0), lab.get("Cont", 0)
        lines.append(f"| {BOXES[key]['name']} | {BOXES[key]['draft']} | {s['pages']} | {s['gaps']} | {new} | {cont} "
                     f"| {lab.get('Box', 0)} | {lab.get('Folder', 0)} | {s['asked']} | {s['train_split']} |")
    lines += ["", "The letters carry no document tags, so their New column counts only the first page after a label",
              "photo; every gap between two page photos goes to the owner. The box is in no label-clean split (its",
              "folder is not in the corpus-pairs windows), so every model scored on it is held out."]
    if "sir" in out:
        s = out["sir"]
        fb = ", ".join(s["fallback_issues"]) or "none"
        lines += ["", "## Stanford Illustrated Review on the article-within-issue rule", "",
                  "Owner, 2026-10-29: an article inside an issue is its own document and inherits the issue's date and",
                  "journal title from its cover or contents page; the full-magazine rule of 2026-10-05 is only the",
                  "fallback where splitting an issue by article is too difficult. The box's tags and the label-clean",
                  "teacher were both made before that rule, so neither drafts it. The draft is a reading of every page",
                  "(issue, page kind, whether an article or front matter begins), made by four Claude readers in the",
                  "coding session over the upright thumbnails and merged by hand; it is not a bench arm and decides",
                  "nothing the owner rules, since every gap except a repeat goes to the owner blind. It is kept in the cache",
                  "as `seg-boxes/sir/reading.json`.", "",
                  f"- {s['issues']} issues across the {s['pages']} photos ({s['issues_inferred']} dated only by inference",
                  f"  from their contents, {s['photos_issue_unknown']} photos of no readable issue);",
                  f"  {s['issues_with_front']} issues have a cover or contents photo in the box, and",
                  f"  {s['photos_without_front']} photos have none before them (the sheet says so for those cases).",
                  f"- {s['repeats']} gaps are a byte-identical repeat photo (the same JPEG twice, and their corpus PDFs",
                  "  match it equally) and are drafted Cont without asking; the other "
                  f"{s['asked']} gaps go to the owner.",
                  f"- Against the old tags: {s['tag_cont_now_new']} photos tagged as continuing are drafted as starts,",
                  f"  {s['tag_new_now_cont']} tagged as starts are drafted as continuing.",
                  f"- Fallback needed in the draft: {fb} ({s['fallback_photos']} photos)."]
        lines += [f"  - {k}: {v}." for k, v in s["fallback_reasons"].items()]
        lines += ["- The sheet offers a fallback answer on every case, and `fold` lists the issues where it was used.",
                  "",
                  "Stale against the new rule, left for `W46.seg-magazine-rule-redo`: the method prompts (`method_gemini.py`",
                  "and `method_whole.py` rule 10), `make-truth-pack.py`, this script's sheet text for the other boxes",
                  "(SC0122 already answered on it; the Young, Sasha sheet is out to the owner with it, and holds no",
                  "magazines), the truth sets with magazine cases (Stanton case 38), and every score built on them."]
    lines += ["", "In the SC0122 box a gap goes to the owner when the teacher's P(new) is on the other side of 0.5 from",
              "the tag (the agree rule's dropped gaps):", ""]
    for key in ("sc0122",):
        if key not in out:
            continue
        lines.append(f"- {BOXES[key]['name']}: " + ", ".join(f"tag {k}: {v}" for k, v in out[key]["asked_by"].items())
                     + f"; gaps the teacher never judged: {out[key]['unjudged']}.")
    lines += ["", "**Both tagged boxes are in label-clean's train split**, so the Mac students trained on its windows",
              "(the W41.seg-finetune 2B and 4B, on the Mac since W41.seg-mac-model) have seen these boxes with the tag or teacher labels; a student's",
              "score on them is not a held-out figure. The owner kept both (`W46.seg-boxes-overlap-ok`, 2026-10-29): a",
              "student's score on them is reported as trained-on, and both go into corpus_pairs EXCLUDE for any retrain.", ""]
    with open(RESULTS, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def thumb_of(key, row, orient):
    """The photo's thumbnail, upright: EXIF orientation applied, then turned to match its corpus PDF, since only the
    PDFs were turned upright (ocr_truth.orient_like_pdf). `orient` collects {n: [turn, correlation]} per box; a
    correlation under ORIENT_MIN means the pairing itself is doubtful, and cmd_sheet reports it. A photo with no
    corpus PDF (an untagged JPEG box) is turned by EXIF alone, recorded as [0, None]."""
    import tempfile
    from pathlib import Path
    from PIL import Image, ImageOps
    import ocr_truth
    d = os.path.join(CACHE, key, "thumbs")
    os.makedirs(d, exist_ok=True)
    dst = os.path.join(d, f"{row['n']:04d}.jpg")
    if not os.path.exists(dst) or str(row["n"]) not in orient:
        with tempfile.TemporaryDirectory() as tmp, Image.open(os.path.join(JPEGS, row["jpeg"])) as im:
            up = ImageOps.exif_transpose(im).convert("RGB")
            deg, corr = (ocr_truth.orient_like_pdf(up, Path(CORPUS) / row["pdf"], Path(tmp)) if row["pdf"]
                         else (0, None))
            up = up.rotate(deg, expand=True)
            up.thumbnail((THUMB_PX, THUMB_PX))
            up.save(dst, "JPEG", quality=88)
        orient[str(row["n"])] = [deg, None if corr is None else round(corr, 3)]
    return f"thumbs/{row['n']:04d}.jpg"


RULES_2026_10_05 = """Judge by the document rules approved on 2026-10-05 (a full magazine is one document; each clipping article is its
own; an enclosure with its own date, author or heading is its own; an envelope, a blank back or a repeat photo is
part of its document). The small page on the right is the photo after, for context only.
For each gap: does the RIGHT photo start a new document, continue the left one, or is it a box or folder label card?"""

RULES_ARTICLE = """These are pages of single issues of an alumni magazine. Judge by the article-within-issue rule (owner,
2026-10-29): <b>an article inside an issue is its own document</b>, and takes the issue's date and journal title from
its cover or contents page, which is shown first in each case when this box holds one for that issue. The other
2026-10-05 rules stand (an enclosure with its own date, author or heading is its own; an ad page, a blank back or a
repeat photo is part of its document; photographs are never reordered). The full-magazine rule is now only the
fallback: where splitting this issue by article is too difficult (articles interleaved across photos, say), answer
<b>fallback</b>, and the right photo stays with the left one as part of the whole issue's document.
A gap where the right photo is a byte-identical repeat of the left is not asked. The small page on the right is the
photo after, for context only. For each gap: does the RIGHT photo start a new document or continue the left one?"""


def sheet_html(key, cases, total_gaps):
    """cases: [(cid, left n, right n, left img, right img, next img or None, front n or None, front img or None)]
    in box order. A box on the article rule shows each case's issue cover or contents photo first."""
    e = html.escape
    name = BOXES[key]["name"]
    article = BOXES[key]["draft"] == "article reading"
    rules = RULES_ARTICLE if article else RULES_2026_10_05
    store = f"seg-boxes-{key}-article-answers" if article else f"seg-boxes-{key}-answers"
    head = f"""<!doctype html><meta charset="utf-8"><title>{e(name)} — gap rulings</title>
<style>body{{font:15px -apple-system,sans-serif;margin:24px;max-width:1700px}}
.case{{border-top:2px solid #ccc;padding:12px 0}}.row{{display:flex;gap:12px;align-items:flex-start}}
.row figure{{margin:0;flex:1}}.row figure.ctx{{flex:.45;opacity:.75}}.row figure.front{{flex:.6}}
.row img{{width:100%;border:1px solid #999}}.row figure.front img{{border:2px solid #36c}}.nofront{{flex:.6;font-size:12px;color:#555}}
figcaption{{font-size:12px;color:#555}}label{{margin-right:18px}}#out{{width:100%;height:160px}}</style>
<h1>{e(name)} — {len(cases)} gaps to rule ({"W46.seg-boxes-sir-article" if article else "W46.fix-seg-boxes"})</h1>
<p>Each case is one gap between two neighbouring photos of this box, in box order ({len(cases)} of its {total_gaps}
gaps). The pages are shown on their own: no tag, label or model answer is shown, so the ruling stands on the pages.
{rules}
Answers are saved in this browser as you go. When done, press <b>Export</b> and paste the text into a reply.</p>
"""
    parts = [head]
    for cid, ln, rn, li, ri, ni, fn, fi in cases:
        ctx = f'<figure class="ctx"><img loading="lazy" src="{ni}"><figcaption>photo {rn + 1} (context)</figcaption></figure>' if ni else ""
        front = ""
        if article and fi and fn not in (ln, rn):
            front = (f'<figure class="front"><img loading="lazy" src="{fi}"><figcaption>photo {fn}: this issue\'s cover '
                     f'or contents page (date and journal title)</figcaption></figure>')
        elif article and not fn:
            front = '<div class="nofront">No cover or contents page of this issue is in the box before these photos.</div>'
        choices = [("new", "right starts a NEW document"), ("same", "right CONTINUES the left")]
        choices += ([("fallback", "too hard to split by article here: FALLBACK, keep with the whole issue")] if article
                    else [("label", "right is a box or folder LABEL card")])
        choices.append(("unsure", "can't tell"))
        radios = "\n".join(f'<label><input type="radio" name="{cid}" value="{v}"> {t}</label>' for v, t in choices)
        parts.append(f"""<div class="case" id="{cid}"><b>{cid}</b> · photos {ln} | {rn}
<div class="row">{front}<figure><img loading="lazy" src="{li}"><figcaption>photo {ln} (left)</figcaption></figure>
<figure><img loading="lazy" src="{ri}"><figcaption>photo {rn} (right)</figcaption></figure>{ctx}</div>
{radios}</div>""")
    parts.append(f"""<p><button onclick="exp()">Export</button> <span id="cnt"></span></p><textarea id="out"></textarea>
<script>
const K='{store}';const s=JSON.parse(localStorage.getItem(K)||'{{}}');
document.querySelectorAll('input[type=radio]').forEach(r=>{{if(s[r.name]===r.value)r.checked=true;
r.addEventListener('change',()=>{{s[r.name]=r.value;localStorage.setItem(K,JSON.stringify(s));cnt();}});}});
function cnt(){{document.getElementById('cnt').textContent=Object.keys(s).length+' of {len(cases)} answered';}}
function exp(){{document.getElementById('out').value='{key}\\n'+Object.keys(s).sort().map(k=>k+','+s[k]).join('\\n');}}
cnt();
</script>""")
    return "\n".join(parts)


def cmd_sheet(a):
    for key in a.boxes or BOXES:
        with open(os.path.join(CACHE, key, "draft.json"), encoding="utf-8") as f:
            rows = json.load(f)["pages"]
        orient_path = os.path.join(CACHE, key, "orient.json")
        orient = {}
        if os.path.exists(orient_path):
            with open(orient_path) as f:
                orient = json.load(f)
        thumb = lambda key, row: thumb_of(key, row, orient)
        cases, keyrows = [], []
        for i, r in enumerate(rows):
            if not r["ask"]:
                continue
            left = rows[i - 1]
            nxt = rows[i + 1] if i + 1 < len(rows) else None
            cid = f"{BOXES[key].get('prefix', key[:2])}{len(cases) + 1:03d}"
            fn = r.get("front")
            front_row = rows[fn - 1] if fn else None
            cases.append((cid, left["n"], r["n"], thumb(key, left), thumb(key, r), thumb(key, nxt) if nxt else None,
                          fn, thumb(key, front_row) if front_row else None))
            keyrows.append({"id": cid, "left": left["n"], "right": r["n"], "draft": r["draft"],
                            "tag_gap": r["tag_gap"], "p_new": r["p_new"], "front": fn,
                            "issue": r.get("issue"), "fallback": r.get("fallback", False)})
        with open(os.path.join(CACHE, key, "key.json"), "w") as f:
            json.dump(keyrows, f, indent=0)
        with open(os.path.join(CACHE, key, "sheet.html"), "w", encoding="utf-8") as f:
            f.write(sheet_html(key, cases, len(rows) - 1))
        with open(orient_path, "w") as f:
            json.dump(orient, f, indent=0)
        turned = sum(1 for deg, _ in orient.values() if deg)
        doubtful = sorted((int(n) for n, (_, c) in orient.items() if c is not None and c < ORIENT_MIN))
        print(f"{key}: {len(cases)} gaps -> {os.path.join(CACHE, key, 'sheet.html')}; {turned} of {len(orient)} "
              f"photos turned upright; pairing doubtful (correlation < {ORIENT_MIN}): {doubtful or 'none'}")


def fold(rows, keyrows, answers):
    """The draft with the owner's rulings applied: [(n, label)], plus the ids left unanswered or unsure.
    'new' -> New, 'same' -> Cont, 'fallback' -> Cont (the full-magazine fallback: the photo stays with its issue's
    document; cmd_fold lists where it was used), 'label' -> Folder (a box card is marked Box by hand: the sheet does
    not tell them apart, and only the label photo itself changes). A page after a label card is a start."""
    labels = {r["n"]: r["draft"] for r in rows}
    open_ids = []
    for k in keyrows:
        ans = answers.get(k["id"])
        if ans not in ("new", "same", "label", "fallback"):
            open_ids.append(k["id"])
            continue
        labels[k["right"]] = {"new": "New", "same": "Cont", "fallback": "Cont", "label": "Folder"}[ans]
    ns = sorted(labels)
    for prev, n in zip(ns, ns[1:]):
        if labels[prev] in ("Box", "Folder") and labels[n] == "Cont":
            labels[n] = "New"
    return [(n, labels[n]) for n in ns], open_ids


def cmd_fold(a):
    d = os.path.join(CACHE, a.box)
    with open(os.path.join(d, "draft.json"), encoding="utf-8") as f:
        rows = json.load(f)["pages"]
    with open(os.path.join(d, "key.json")) as f:
        keyrows = json.load(f)
    answers = read_answers(a.answers)
    labs, open_ids = fold(rows, keyrows, answers)
    with open(os.path.join(d, "truth.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["File Number", "Status"])
        w.writerows(labs)
    used = sorted({k.get("issue") or "issue unknown" for k in keyrows if answers.get(k["id"]) == "fallback"})
    print(f"{a.box}: {len(keyrows) - len(open_ids)} of {len(keyrows)} rulings applied; open: {open_ids}"
          + (f"; full-magazine fallback answered in: {used}" if used else ""))


def latest_answers(d):
    names = sorted(n for n in os.listdir(d) if re.fullmatch(r"answers-\d{8}\.txt", n))
    if not names:
        raise SystemExit(f"{d}: no answers-YYYYMMDD.txt (fold the owner's export first)")
    return os.path.join(d, names[-1])


def read_answers(path):
    with open(path) as f:
        return {k.strip(): v.strip() for k, v in (l.split(",", 1) for l in f if "," in l)}


def lock_box(key, data_dir, today):
    """Freezes one box into data_dir/<folder>/ as data.py loads it; returns the lock record. Refuses an existing folder:
    a frozen box is never rewritten (a re-rule is a new item, made by hand)."""
    import shutil
    d = os.path.join(CACHE, key)
    coll, folder = BOXES[key]["locked"]
    dst = os.path.join(data_dir, folder)
    if os.path.exists(dst):
        raise SystemExit(f"{key}: {dst} already exists; a locked box is not rewritten")
    with open(os.path.join(d, "draft.json"), encoding="utf-8") as f:
        rows = json.load(f)["pages"]
    with open(os.path.join(d, "key.json")) as f:
        keyrows = json.load(f)
    ans_path = latest_answers(d)
    answers = read_answers(ans_path)
    labs, open_ids = fold(rows, keyrows, answers)
    with open(os.path.join(d, "truth.csv"), newline="", encoding="utf-8") as f:
        cached = [(int(n), lab) for n, lab in list(csv.reader(f))[1:]]
    if cached != labs:
        raise SystemExit(f"{key}: truth.csv in the cache differs from a fresh fold of {ans_path}; re-run fold first")
    labs = [(n, "Box" if n in BOX_CARDS.get(key, ()) else lab) for n, lab in labs]
    orient_path = os.path.join(d, "orient.json")
    orient = json.load(open(orient_path)) if os.path.exists(orient_path) else {}
    by_id = {k["id"]: k for k in keyrows}
    tmp = dst + ".partial"
    if os.path.exists(tmp):
        raise SystemExit(f"{key}: {tmp} is left from an interrupted lock; look at it and move it aside by hand")
    os.makedirs(tmp)
    pages = []
    for r, (n, lab) in zip(rows, labs):
        assert r["n"] == n
        src = os.path.join(JPEGS, r["jpeg"])
        name = f"{n:05d} \u2014\u00a0{coll}{os.path.splitext(src)[1].lower()}"
        shutil.copyfile(src, os.path.join(tmp, name))
        sha = file_sha(os.path.join(tmp, name))
        if sha != file_sha(src):
            raise SystemExit(f"{key}: copy of {src} does not match it")
        turn = orient.get(str(n))
        pages.append({"n": n, "file": name, "source": r["jpeg"], "sha256": sha, "label": lab,
                      "turn": turn[0] if turn else None})
    csv_name = f"{coll} Ground Truth.csv"
    with open(os.path.join(tmp, csv_name), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["File Number", "Status"])
        w.writerows(labs)
    rec = {"item": "W46.fix-seg-boxes-lock", "locked": today, "collection": coll, "box": BOXES[key]["name"],
           "corpus_folder": BOXES[key]["folder"], "rulings": os.path.basename(ans_path), "rulings_sha256": file_sha(ans_path),
           "truth_csv": csv_name, "truth_sha256": file_sha(os.path.join(tmp, csv_name)),
           "rule": "article-within-issue (owner, 2026-10-29); an advertisement between an article's pages goes with it "
                   "(owner, 2026-10-30)" if BOXES[key]["draft"] == "article reading" else "document rules of 2026-10-05",
           "unsure": [{"id": i, "left": by_id[i]["left"], "right": by_id[i]["right"], "answer": answers.get(i, "")}
                      for i in open_ids],
           "fallback": [{"id": i, "right": by_id[i]["right"], "issue": by_id[i].get("issue")}
                        for i in sorted(answers) if answers[i] == "fallback" and i in by_id],
           "label_rulings": [by_id[i]["right"] for i in sorted(answers) if answers[i] == "label" and i in by_id],
           "box_cards_by_hand": list(BOX_CARDS.get(key, ())),
           "trained_on": BOXES[key].get("trained_on"),
           "turn_note": "the JPEG originals are copied unturned; `turn` is the extra rotation (degrees, PIL) the sheet "
                        "applied after EXIF to match the upright corpus PDF, where it was measured",
           "pages": pages}
    with open(os.path.join(tmp, "lock.json"), "w", encoding="utf-8") as f:
        json.dump(rec, f, indent=1, ensure_ascii=False)
    for name in os.listdir(tmp):
        os.chmod(os.path.join(tmp, name), 0o444)
    os.rename(tmp, dst)
    os.chmod(dst, 0o500)
    return rec


def verify_box(data_dir, folder):
    """Problems with a frozen box against its lock.json (an empty list when it is intact)."""
    dst = os.path.join(data_dir, folder)
    with open(os.path.join(dst, "lock.json"), encoding="utf-8") as f:
        rec = json.load(f)
    bad = []
    want = {p["file"]: p["sha256"] for p in rec["pages"]} | {rec["truth_csv"]: rec["truth_sha256"]}
    have = set(os.listdir(dst)) - {"lock.json"}
    bad += [f"extra file {n}" for n in sorted(have - set(want))]
    bad += [f"missing {n}" for n in sorted(set(want) - have)]
    bad += [f"changed {n}" for n in sorted(set(want) & have) if file_sha(os.path.join(dst, n)) != want[n]]
    bad += [f"writable {n}" for n in sorted(have | {"lock.json"}) if os.stat(os.path.join(dst, n)).st_mode & 0o222]
    return bad


def cmd_lock(a):
    import datetime
    import data
    for key in a.boxes or BOXES:
        rec = lock_box(key, str(data.DATA_DIR), datetime.date.today().isoformat())
        print(f"{key}: locked {len(rec['pages'])} photos as {rec['collection']}; unsure gaps "
              f"{[u['right'] for u in rec['unsure']]}; label cards {rec['label_rulings']}")


def cmd_verify(a):
    import data
    failed = False
    for key in a.boxes or BOXES:
        bad = verify_box(str(data.DATA_DIR), BOXES[key]["locked"][1])
        failed |= bool(bad)
        print(f"{key}: " + ("intact" if not bad else "; ".join(bad)))
    return 1 if failed else 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name, fn in (("draft", cmd_draft), ("sheet", cmd_sheet), ("lock", cmd_lock), ("verify", cmd_verify)):
        c = sub.add_parser(name)
        c.add_argument("boxes", nargs="*", metavar="BOX", help=f"default: every box ({', '.join(BOXES)})")
        c.set_defaults(fn=fn)
    f = sub.add_parser("fold")
    f.add_argument("box", choices=sorted(BOXES))
    f.add_argument("answers")
    f.set_defaults(fn=cmd_fold)
    a = p.parse_args()
    unknown = [b for b in getattr(a, "boxes", []) if b not in BOXES]
    if unknown:
        p.error(f"unknown box {', '.join(unknown)} (choose from {', '.join(BOXES)})")
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
