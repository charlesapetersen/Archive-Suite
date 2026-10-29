#!/usr/bin/env python3
"""W46.fix-seg-boxes: draft truth for the three new locked segmentation boxes, and the owner's ruling sheets.

The owner named the boxes on 2026-10-21 (execution-plans/processing-review/STATE.md, "Locked boxes named"):

  rawls     Rawls papers, images 00057-00252 (196 photos), handwritten; no document tags, only Red (box) and
            Purple (folder) label tags, which may be incomplete. The owner rules every gap.
  sir       Stanford Illustrated Review (147 photos), a bound periodical photographed page by page; tagged per
            document. The tags give the draft; the owner rules the gaps where the W41.seg-label-clean teacher
            (Qwen3.5 27B, P(new) averaged over the windows covering the gap) is on the other side of 0.5.
  sc0122    SC0122 News Service (200 photos), reading-room clippings mixed with other papers; as sir.

Every sheet is blind: it shows the two photos either side of a gap and never the tag, the teacher or any model,
so the owner's ruling leans on nothing a later bench run is scored against (the same reason the W46 OCR sheets
never reveal the current reading). The key, with the draft and the teacher's P(new), stays beside the sheet.

READ ONLY on the corpus and the JPEG tree: getxattr(2) for tags (corpus_survey.read_tags), `sips` reading a
JPEG and writing a thumbnail into the cache. No model calls: the teacher's answers were made by the
W41.seg-label-clean run and are read from the corpus-pairs cache. Nothing is written under `Test Files/`; the
lock item (W46.fix-seg-boxes-lock) folds the owner's rulings in and freezes the boxes there.

    python3 seg_boxes.py draft            # draft.json + draft.csv per box, counts in segbench-results/seg-boxes.md
    python3 seg_boxes.py sheet            # sheet.html + key.json + thumbnails per box, in the cache
    python3 seg_boxes.py fold BOX FILE    # the owner's exported answers -> truth.csv beside the draft (cache)

Cache (outside git, private pages): ~/Library/Caches/ArchiveSuiteRehearsal/seg-boxes/<box>/
"""
import argparse
import collections
import csv
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
LEAD = re.compile(r"^\s*(\d{3,})")

BOXES = {
    "rawls": {"name": "Rawls papers 00057-00252", "folder": "05 Final Tagging/5 Priority 5/Rawls papers",
              "first": 57, "last": 252, "draft": "label tags only"},
    "sir": {"name": "Stanford Illustrated Review", "folder": "Stanford University Archives/Stanford Illustrated Review",
            "draft": "tags + teacher"},
    "sc0122": {"name": "SC0122 News Service", "folder": "Stanford University Archives/SC0122 — News Service",
               "draft": "tags + teacher"},
}
ANSWERS = ("new", "same", "label", "unsure")


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


def rawls_gap_needs_ruling(left_label, right_label):
    """Untagged box: every gap between two page photos is ruled; a gap beside a tagged label photo is a start by
    definition (a label photo is never part of a document) and is not asked."""
    return left_label is None and right_label is None


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


def jpeg_of_pdfs():
    with open(os.path.join(PAIRS_CACHE, "pairs.tsv"), encoding="utf-8") as f:
        return {r["pdf"]: r["jpeg"] for r in csv.DictReader(f, delimiter="\t")}


def draft_rawls():
    box = BOXES["rawls"]
    jpeg = jpeg_of_pdfs()
    names = {photo_number(n): n for n in os.listdir(os.path.join(CORPUS, box["folder"])) if n.endswith(".pdf")}
    rows = []
    for i, num in enumerate(range(box["first"], box["last"] + 1), 1):
        if num not in names:
            raise SystemExit(f"rawls: no photo {num:05d}")
        pdf = os.path.join(box["folder"], names[num])
        if not jpeg.get(pdf):
            raise SystemExit(f"rawls: no JPEG paired with {pdf}")
        rows.append({"n": i, "pdf": pdf, "jpeg": jpeg[pdf],
                     "label": label_of(CS.read_tags(os.path.join(CORPUS, pdf)))})
    for i, r in enumerate(rows):
        # The draft: label photos from the tags, the first page after one a start, every other page undecided
        # (the owner rules it). "Cont" is only a placeholder so the CSV parses; `ask` marks what is undecided.
        prev = rows[i - 1]["label"] if i else "Box"
        r["draft"] = r["label"] or ("New" if prev else "Cont")
        r["ask"] = bool(i) and rawls_gap_needs_ruling(prev, r["label"])
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
    by = collections.Counter((r["tag_gap"], "teacher new" if (r["p_new"] or 0) >= 0.5 else "teacher cont")
                             for r in asked if r["tag_gap"])
    return {"pages": len(rows), "gaps": len(rows) - 1, "labels": dict(sorted(labels.items())),
            "asked": len(asked), "asked_by": {f"{a} / {b}": n for (a, b), n in sorted(by.items())},
            "unjudged": sum(1 for r in rows[1:] if r["tag_gap"] and r["p_new"] is None),
            "train_split": sum(1 for r in rows if r["split"] == "train")}


def cmd_draft(a):
    out = {}
    for key in BOXES:
        rows = draft_rawls() if key == "rawls" else draft_tagged(key)
        write_draft(key, rows)
        out[key] = summary(key, rows)
        print(key, json.dumps(out[key]))
    with open(os.path.join(CACHE, "summary.json"), "w") as f:
        json.dump(out, f, indent=1)
    write_results(out)


def write_results(out):
    lines = ["# W46.fix-seg-boxes — draft truth for three new locked segmentation boxes", "",
             "Written by `seg_boxes.py draft` (numbers only: no names, text or images). The boxes were named by the",
             "owner on 2026-10-21 (`execution-plans/processing-review/STATE.md`). Drafts, keys and the blind ruling",
             "sheets are in `~/Library/Caches/ArchiveSuiteRehearsal/seg-boxes/<box>/`, outside git. No model calls:",
             "the teacher's P(new) is the W41.seg-label-clean run's (`label-clean.md`).", "",
             "| box | draft from | photos | gaps | New | Cont | Box | Folder | gaps for the owner | photos in label-clean's train split |",
             "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for key, s in out.items():
        lab = s["labels"]
        if key == "rawls":
            new, cont = lab.get("New", 0), "—"
        else:
            new, cont = lab.get("New", 0), lab.get("Cont", 0)
        lines.append(f"| {BOXES[key]['name']} | {BOXES[key]['draft']} | {s['pages']} | {s['gaps']} | {new} | {cont} "
                     f"| {lab.get('Box', 0)} | {lab.get('Folder', 0)} | {s['asked']} | {s['train_split']} |")
    lines += ["", "Rawls carries no document tags, so its New column counts only the first page after a label photo;",
              "every gap between two page photos goes to the owner. In the two tagged boxes a gap goes to the owner",
              "when the teacher's P(new) is on the other side of 0.5 from the tag (the agree rule's dropped gaps):", ""]
    for key in ("sir", "sc0122"):
        lines.append(f"- {BOXES[key]['name']}: " + ", ".join(f"tag {k}: {v}" for k, v in out[key]["asked_by"].items())
                     + f"; gaps the teacher never judged: {out[key]['unjudged']}.")
    lines += ["", "**Both tagged boxes are in label-clean's train split**, so the Mac students trained on its windows",
              "(the W41.seg-finetune 2B and 4B, on the Mac since W41.seg-mac-model) have seen these boxes with the tag or teacher labels; a student's",
              "score on them is not a held-out figure. The owner's call on it is `W46.seg-boxes-overlap-ok`.", ""]
    with open(RESULTS, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def thumb(key, row):
    d = os.path.join(CACHE, key, "thumbs")
    os.makedirs(d, exist_ok=True)
    dst = os.path.join(d, f"{row['n']:04d}.jpg")
    if not os.path.exists(dst):
        subprocess.run(["/usr/bin/sips", "-s", "format", "jpeg", "-Z", str(THUMB_PX), os.path.join(JPEGS, row["jpeg"]),
                        "--out", dst], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return f"thumbs/{row['n']:04d}.jpg"


def sheet_html(key, cases, total_gaps):
    """cases: [(cid, left n, right n, left img, right img, next img or None)] in box order."""
    e = html.escape
    name = BOXES[key]["name"]
    head = f"""<!doctype html><meta charset="utf-8"><title>{e(name)} — gap rulings</title>
<style>body{{font:15px -apple-system,sans-serif;margin:24px;max-width:1700px}}
.case{{border-top:2px solid #ccc;padding:12px 0}}.row{{display:flex;gap:12px;align-items:flex-start}}
.row figure{{margin:0;flex:1}}.row figure.ctx{{flex:.45;opacity:.75}}.row img{{width:100%;border:1px solid #999}}
figcaption{{font-size:12px;color:#555}}label{{margin-right:18px}}#out{{width:100%;height:160px}}</style>
<h1>{e(name)} — {len(cases)} gaps to rule (W46.fix-seg-boxes)</h1>
<p>Each case is one gap between two neighbouring photos of this box, in box order ({len(cases)} of its {total_gaps}
gaps). The pages are shown on their own: no tag, label or model answer is shown, so the ruling stands on the pages.
Judge by the document rules approved on 2026-10-05 (a full magazine is one document; each clipping article is its
own; an enclosure with its own date, author or heading is its own; an envelope, a blank back or a repeat photo is
part of its document). The small page on the right is the photo after, for context only.
For each gap: does the RIGHT photo start a new document, continue the left one, or is it a box or folder label card?
Answers are saved in this browser as you go. When done, press <b>Export</b> and paste the text into a reply.</p>
"""
    parts = [head]
    for cid, ln, rn, li, ri, ni in cases:
        ctx = f'<figure class="ctx"><img loading="lazy" src="{ni}"><figcaption>photo {rn + 1} (context)</figcaption></figure>' if ni else ""
        parts.append(f"""<div class="case" id="{cid}"><b>{cid}</b> · photos {ln} | {rn}
<div class="row"><figure><img loading="lazy" src="{li}"><figcaption>photo {ln} (left)</figcaption></figure>
<figure><img loading="lazy" src="{ri}"><figcaption>photo {rn} (right)</figcaption></figure>{ctx}</div>
<label><input type="radio" name="{cid}" value="new"> right starts a NEW document</label>
<label><input type="radio" name="{cid}" value="same"> right CONTINUES the left</label>
<label><input type="radio" name="{cid}" value="label"> right is a box or folder LABEL card</label>
<label><input type="radio" name="{cid}" value="unsure"> can't tell</label></div>""")
    parts.append(f"""<p><button onclick="exp()">Export</button> <span id="cnt"></span></p><textarea id="out"></textarea>
<script>
const K='seg-boxes-{key}-answers';const s=JSON.parse(localStorage.getItem(K)||'{{}}');
document.querySelectorAll('input[type=radio]').forEach(r=>{{if(s[r.name]===r.value)r.checked=true;
r.addEventListener('change',()=>{{s[r.name]=r.value;localStorage.setItem(K,JSON.stringify(s));cnt();}});}});
function cnt(){{document.getElementById('cnt').textContent=Object.keys(s).length+' of {len(cases)} answered';}}
function exp(){{document.getElementById('out').value='{key}\\n'+Object.keys(s).sort().map(k=>k+','+s[k]).join('\\n');}}
cnt();
</script>""")
    return "\n".join(parts)


def cmd_sheet(a):
    for key in BOXES:
        with open(os.path.join(CACHE, key, "draft.json"), encoding="utf-8") as f:
            rows = json.load(f)["pages"]
        cases, keyrows = [], []
        for i, r in enumerate(rows):
            if not r["ask"]:
                continue
            left = rows[i - 1]
            nxt = rows[i + 1] if i + 1 < len(rows) else None
            cid = f"{key[:2]}{len(cases) + 1:03d}"
            cases.append((cid, left["n"], r["n"], thumb(key, left), thumb(key, r), thumb(key, nxt) if nxt else None))
            keyrows.append({"id": cid, "left": left["n"], "right": r["n"], "draft": r["draft"],
                            "tag_gap": r["tag_gap"], "p_new": r["p_new"]})
        with open(os.path.join(CACHE, key, "key.json"), "w") as f:
            json.dump(keyrows, f, indent=0)
        with open(os.path.join(CACHE, key, "sheet.html"), "w", encoding="utf-8") as f:
            f.write(sheet_html(key, cases, len(rows) - 1))
        print(f"{key}: {len(cases)} gaps -> {os.path.join(CACHE, key, 'sheet.html')}")


def fold(rows, keyrows, answers):
    """The draft with the owner's rulings applied: [(n, label)], plus the ids left unanswered or unsure.
    'new' -> New, 'same' -> Cont, 'label' -> Folder (a box card is marked Box by hand: the sheet does not tell them
    apart, and only the label photo itself changes). A page after a label card is a start."""
    labels = {r["n"]: r["draft"] for r in rows}
    open_ids = []
    for k in keyrows:
        ans = answers.get(k["id"])
        if ans not in ("new", "same", "label"):
            open_ids.append(k["id"])
            continue
        labels[k["right"]] = {"new": "New", "same": "Cont", "label": "Folder"}[ans]
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
    with open(a.answers) as f:
        answers = {k.strip(): v.strip() for k, v in (l.split(",", 1) for l in f if "," in l)}
    labs, open_ids = fold(rows, keyrows, answers)
    with open(os.path.join(d, "truth.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["File Number", "Status"])
        w.writerows(labs)
    print(f"{a.box}: {len(keyrows) - len(open_ids)} of {len(keyrows)} rulings applied; open: {open_ids}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("draft").set_defaults(fn=cmd_draft)
    sub.add_parser("sheet").set_defaults(fn=cmd_sheet)
    f = sub.add_parser("fold")
    f.add_argument("box", choices=sorted(BOXES))
    f.add_argument("answers")
    f.set_defaults(fn=cmd_fold)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
