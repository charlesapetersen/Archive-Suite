#!/usr/bin/env python3
"""W46.seg-truth-sheet: one blind owner sheet for the segmentation truth the measurement audit doubted.

The measurement audit (2026-10-30, execution-plans/processing-review/11-measurement-audit.md) found three test truths
that no owner has ruled where it matters, and the owner asked for one sheet, about 30 minutes, built from cached data
with no model calls:

  stanton   SEG-7. Stanton 101-105, a whole newsletter issue kept as one document under the full-magazine rule
            (case 38 of the 2026-10-05 truth check, at photo 102), re-asked under the article-within-issue rule
            (owner, 2026-10-29), each case shown with the issue's cover, as W46.seg-boxes-sir-article did. A
            masthead screen of the five original boxes' cached OCR (ISSUE_SCREEN) found no other issue run.
  crest     SEG-2. The CREST gaps the Codex agent's audit called ambiguous: 46 (approval jottings), 88 (a seal page),
            94 (the exemption marker), 111 (cue jottings) and the two briefing-copy starts 75 and 95.
  lincoln   SEG-3. Lincoln's ambiguous wrappers 77 and 231, the clippings 76 and 230 they follow, and the mailed
            envelope 107 kept with its letter.
  sc0122    SEG-1. 60 of the 162 SC0122 gaps where tag and teacher agreed (never seen by the owner), drawn
            stratified by the teacher's P(new) with a fixed seed. The draw and each stratum's size are in key.json,
            so `fold` can weight the agreed stratum (owner's call, 2026-10-30).

Blind: the sheet shows the photos either side of each gap and never the truth, a tag, the teacher or a model's answer.
The key (current truth, audit note, stratum) stays beside the sheet in the cache. No Claude reader looked at the
pages to build it: the cases come from the truth CSVs, the public manifests' audit notes and the SC0122 draft.

READ ONLY on every source: the locked Test Files boxes, the public boxes in Long term storage, the corpus PDFs (only
for orient_like_pdf, as seg_boxes.py does). Writes only thumbnails, sheet.html, key.json and rulings.json in the cache.

    python3 seg_truth_sheet.py sheet          # sheet.html + key.json + thumbs/ in the cache
    python3 seg_truth_sheet.py fold FILE      # the owner's exported answers -> rulings.json, and a summary

Cache (outside git, private pages): ~/Library/Caches/ArchiveSuiteRehearsal/seg-truth-sheet/
"""
import argparse
import collections
import html
import json
import os
import random
import sys
import tempfile
from pathlib import Path

import data
import seg_boxes as SB

CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/seg-truth-sheet")
PUBLIC = Path("/Users/cp1/Claude/Long term storage/FarmShare-20261018/public-segmentation")
MANIFESTS = Path(__file__).resolve().parent.parent.parent / "segbench-results" / "public-segmentation"
RESULTS = Path(__file__).resolve().parent.parent.parent / "segbench-results" / "seg-truth-sheet.md"
SEED = 20261030

# SEG-7: the newsletter issue under case 38 (Stanton 102), its cover at 101; every gap inside the run is asked.
STANTON_RUN = (101, 105)
# The masthead screen run over the five boxes' cached OCR: an issue number, "Vol. N, No." or "Published by/monthly".
# Its only multi-page hit with an issue masthead was STANTON_RUN; the other hits were the word "magazine" or
# "newsletter" inside a letter or a one- or two-page clipping, already ruled at the 2026-10-05 truth check.
ISSUE_SCREEN = r"\bIssue No\.|\bVol(ume)?\.? ?[IVX\d]+,? ?No\.|Published (by|monthly|quarterly|weekly)"
# SEG-2 / SEG-3: right-hand photo of each gap (the audit's ambiguous and borderline decisions).
CREST_GAPS = (46, 75, 88, 94, 95, 111)
LINCOLN_GAPS = (76, 77, 107, 230, 231)
# SEG-1: strata of the agreed gaps by the teacher's mean P(new), and how many of each are drawn (60 in all). The
# less certain strata are drawn more heavily, since a teacher error is likelier there; key.json records N and n.
STRATA = (("cont, P(new) < 0.02", 0.0, 0.02, 12), ("cont, 0.02 <= P(new) < 0.5", 0.02, 0.5, 24),
          ("new, 0.5 <= P(new) < 0.99", 0.5, 0.99, 12), ("new, P(new) >= 0.99", 0.99, 1.01, 12))

RULES_ISSUE = """These photos are one issue of a political newsletter, kept until now as a single document under the
full-magazine rule. Judge by the article-within-issue rule (owner, 2026-10-29): <b>an article inside an issue is its
own document</b> and takes the issue's date and title from its cover, shown first in each case. An advertisement
photographed between an article's pages goes with that article (owner, 2026-10-30). Where splitting the issue by
article is too difficult, answer <b>fallback</b>: the right photo stays with the whole issue's document."""
RULES_PUBLIC = """Public boxes: CIA CREST reading-room files and Library of Congress Lincoln Papers, in their supplied
order. Judge by the document rules of 2026-10-05 (an enclosure with its own date, author or heading is its own; an
envelope, a blank back or a repeat photo is part of its document; separately preserved copies each start anew;
photographs are never reordered). If the right photo belongs to a document that is <b>not</b> the left one but an
earlier one (a wrapper or envelope separated from its letter by an enclosure, say), answer <b>earlier</b>."""
RULES_SC0122 = """News Service reading-room clippings mixed with other papers. Judge by the document rules of 2026-10-05
(each clipping article is its own document; an enclosure with its own date, author or heading is its own; an
envelope, a blank back or a repeat photo is part of its document)."""

SECTIONS = (("stanton", "Stanton: one newsletter issue", RULES_ISSUE, ("new", "same", "fallback", "unsure")),
            ("crest", "CIA CREST", RULES_PUBLIC, ("new", "same", "earlier", "unsure")),
            ("lincoln", "Lincoln Papers", RULES_PUBLIC, ("new", "same", "earlier", "unsure")),
            ("sc0122", "SC0122 News Service", RULES_SC0122, ("new", "same", "label", "unsure")))
CHOICE_TEXT = {"new": "right starts a NEW document", "same": "right CONTINUES the left",
               "fallback": "too hard to split by article: FALLBACK, keep with the whole issue",
               "earlier": "right belongs to an EARLIER document, not the left one",
               "label": "right is a box or folder LABEL card", "unsure": "can't tell"}
PREFIX = {"stanton": "st", "crest": "cr", "lincoln": "li", "sc0122": "sc"}


def stratum_of(p_new):
    for name, lo, hi, _ in STRATA:
        if lo <= p_new < hi:
            return name
    raise ValueError(p_new)


def draw_controls(rows, seed=SEED):
    """The SC0122 control draw: [(row, stratum)] in box order, and {stratum: [N, n]}. rows: seg_boxes draft rows of
    the box; the agreed gaps are those not asked (rows[0] has no gap)."""
    agreed = [r for r in rows[1:] if not r["ask"]]
    by = collections.defaultdict(list)
    for r in agreed:
        by[stratum_of(r["p_new"])].append(r)
    rng, picked, sizes = random.Random(seed), [], {}
    for name, _, _, k in STRATA:
        pool = sorted(by[name], key=lambda r: r["n"])
        take = rng.sample(pool, min(k, len(pool)))
        picked += [(r, name) for r in take]
        sizes[name] = [len(pool), len(take)]
    return sorted(picked, key=lambda x: x[0]["n"]), sizes


def thumb(src, dst, pdf=None, turn=None):
    """An upright thumbnail of src at dst (once): EXIF applied, then `turn` degrees, or the turn that matches the
    corpus PDF when one is given (seg_boxes.thumb_of). Returns [turn, correlation or None]."""
    from PIL import Image, ImageOps
    import ocr_truth
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with Image.open(src) as im:
        up = ImageOps.exif_transpose(im).convert("RGB")
        corr = None
        if turn is None and pdf:
            with tempfile.TemporaryDirectory() as tmp:
                turn, corr = ocr_truth.orient_like_pdf(up, Path(pdf), Path(tmp))
        up = up.rotate(turn or 0, expand=True)
        up.thumbnail((SB.THUMB_PX, SB.THUMB_PX))
        up.save(dst, "JPEG", quality=88)
    return [turn or 0, None if corr is None else round(corr, 3)]


def public_pages(box):
    with open(MANIFESTS / f"{box}.json", encoding="utf-8") as f:
        m = json.load(f)
    return {p["n"]: p for p in m["pages"]}


def build_cases():
    """[(section, case)] in sheet order; a case is {left, right, next, front, src: {n: (image, pdf, turn)}, key}."""
    cases = []
    st = data.load("Stanton", with_exif=False)
    lo, hi = STANTON_RUN
    for right in range(lo + 1, hi + 1):
        src = {n: (st.pages[n - 1].path, None, None) for n in (lo, right - 1, right, right + 1)
               if 1 <= n <= len(st.pages)}
        cases.append(("stanton", {"box": "Stanton", "left": right - 1, "right": right, "front": lo, "src": src,
                                  "key": {"current": st.pages[right - 1].label, "rule_then": "full magazine"}}))
    for box, gaps in (("crest", CREST_GAPS), ("lincoln", LINCOLN_GAPS)):
        pages = public_pages(box)
        root = PUBLIC / "boxes"
        for right in gaps:
            src = {n: (root / pages[n]["image"].split("boxes/", 1)[1], None, 0)
                   for n in (right - 1, right, right + 1) if n in pages}
            cases.append((box, {"box": box.upper() if box == "crest" else "Lincoln", "left": right - 1,
                                "right": right, "front": None, "src": src,
                                "key": {"current": pages[right]["label"], "audit": pages[right]["audit"]}}))
    with open(os.path.join(SB.CACHE, "sc0122", "draft.json"), encoding="utf-8") as f:
        rows = json.load(f)["pages"]
    locked = os.path.join(str(data.DATA_DIR), data.LOCKED["SC0122"])
    with open(os.path.join(locked, "lock.json"), encoding="utf-8") as f:
        lock = {p["n"]: p for p in json.load(f)["pages"]}
    picked, sizes = draw_controls(rows)
    for r, name in picked:
        n = r["n"]
        src = {m: (os.path.join(locked, lock[m]["file"]), os.path.join(SB.CORPUS, rows[m - 1]["pdf"]),
                   lock[m]["turn"]) for m in (n - 1, n, n + 1) if m in lock}
        cases.append(("sc0122", {"box": "SC0122", "left": n - 1, "right": n, "front": None, "src": src,
                                 "key": {"current": lock[n]["label"], "agreed_draft": r["draft"], "tag_gap": r["tag_gap"],
                                         "p_new": r["p_new"], "stratum": name}}))
    return cases, sizes


def case_html(cid, c, img, choices):
    e = html.escape
    def fig(n, cls, cap):
        return f'<figure class="{cls}"><img loading="lazy" src="{e(img[n])}"><figcaption>{cap}</figcaption></figure>'
    front = fig(c["front"], "front", f"photo {c['front']}: this issue's cover (date and title)") \
        if c["front"] and c["front"] not in (c["left"], c["right"]) else ""
    nxt = c["right"] + 1
    ctx = fig(nxt, "ctx", f"photo {nxt} (context)") if nxt in img else ""
    radios = "\n".join(f'<label><input type="radio" name="{cid}" value="{v}"> {CHOICE_TEXT[v]}</label>' for v in choices)
    return (f'<div class="case" id="{cid}"><b>{cid}</b> · {e(c["box"])} photos {c["left"]} | {c["right"]}\n'
            f'<div class="row">{front}{fig(c["left"], "", f"photo {c["left"]} (left)")}'
            f'{fig(c["right"], "", f"photo {c["right"]} (right)")}{ctx}</div>\n{radios}</div>')


def sheet_html(cases, img_of):
    n = len(cases)
    head = f"""<!doctype html><meta charset="utf-8"><title>Segmentation truth sheet — {n} gaps</title>
<style>body{{font:15px -apple-system,sans-serif;margin:24px;max-width:1700px}}
.case{{border-top:2px solid #ccc;padding:12px 0}}.row{{display:flex;gap:12px;align-items:flex-start}}
.row figure{{margin:0;flex:1}}.row figure.ctx{{flex:.45;opacity:.75}}.row figure.front{{flex:.6}}
.row img{{width:100%;border:1px solid #999}}.row figure.front img{{border:2px solid #36c}}
figcaption{{font-size:12px;color:#555}}label{{margin-right:18px}}#out{{width:100%;height:160px}}
h2{{margin-top:40px}}.rules{{background:#f4f4f4;padding:10px}}</style>
<h1>Segmentation truth sheet — {n} gaps (W46.seg-truth-sheet)</h1>
<p>Each case is one gap between two neighbouring photos, in box order, from four boxes. The pages are shown on their
own: no truth, tag, label or model answer is shown, so the ruling stands on the pages. The small page on the right is
the photo after, for context only. For each gap: does the RIGHT photo start a new document or continue the left one?
Answers are saved in this browser as you go. When done, press <b>Export</b> and paste the text into a reply.</p>
"""
    parts, ids, section = [head], [], None
    for k, (sec, c) in enumerate(cases):
        if sec != section:
            section = sec
            _, title, rules, choices = next(s for s in SECTIONS if s[0] == sec)
            parts.append(f'<h2>{html.escape(title)}</h2><p class="rules">{rules}</p>')
        cid = c["id"]
        ids.append(cid)
        parts.append(case_html(cid, c, img_of[cid], choices))
    parts.append(f"""<p><button onclick="exp()">Export</button> <span id="cnt"></span></p><textarea id="out"></textarea>
<script>
const K='seg-truth-sheet-answers';const s=JSON.parse(localStorage.getItem(K)||'{{}}');
document.querySelectorAll('input[type=radio]').forEach(r=>{{if(s[r.name]===r.value)r.checked=true;
r.addEventListener('change',()=>{{s[r.name]=r.value;localStorage.setItem(K,JSON.stringify(s));cnt();}});}});
function cnt(){{document.getElementById('cnt').textContent=Object.keys(s).length+' of {n} answered';}}
function exp(){{document.getElementById('out').value='seg-truth-sheet\\n'+Object.keys(s).sort().map(k=>k+','+s[k]).join('\\n');}}
cnt();
</script>""")
    return "\n".join(parts)


def cmd_sheet(a):
    cases, sizes = build_cases()
    counts, img_of, keyrows, orient = collections.Counter(), {}, [], {}
    orient_path = os.path.join(CACHE, "orient.json")
    if os.path.exists(orient_path):
        with open(orient_path) as f:
            orient = json.load(f)
    for sec, c in cases:
        counts[sec] += 1
        c["id"] = f"{PREFIX[sec]}{counts[sec]:02d}"
        img_of[c["id"]] = {}
        for n, (src, pdf, turn) in c["src"].items():
            rel = f"thumbs/{sec}/{n:04d}.jpg"
            dst = os.path.join(CACHE, rel)
            if not os.path.exists(dst) or f"{sec}/{n}" not in orient:
                orient[f"{sec}/{n}"] = thumb(str(src), dst, pdf, turn)
            img_of[c["id"]][n] = rel
        keyrows.append({"id": c["id"], "section": sec, "box": c["box"], "left": c["left"], "right": c["right"],
                        "front": c["front"], **c["key"]})
    os.makedirs(CACHE, exist_ok=True)
    with open(os.path.join(CACHE, "key.json"), "w", encoding="utf-8") as f:
        json.dump({"item": "W46.seg-truth-sheet", "seed": SEED, "strata": sizes, "stanton_run": STANTON_RUN,
                   "issue_screen": ISSUE_SCREEN, "cases": keyrows}, f, indent=1, ensure_ascii=False)
    with open(os.path.join(CACHE, "sheet.html"), "w", encoding="utf-8") as f:
        f.write(sheet_html(cases, img_of))
    with open(orient_path, "w") as f:
        json.dump(orient, f, indent=0)
    doubtful = sorted(k for k, (_, c) in orient.items() if c is not None and c < SB.ORIENT_MIN)
    print(f"{len(cases)} gaps ({dict(counts)}) -> {os.path.join(CACHE, 'sheet.html')}; SC0122 strata {sizes}; "
          f"pairing doubtful: {doubtful or 'none'}")


def fold(keyrows, strata, answers):
    """Per-section counts of the owner's answers against the current truth, and SC0122's weighted error rate on the
    agreed stratum: each control's disagreement weighted by its stratum's N/n. An unsure or unanswered case is left
    out of the rate (and listed). 'earlier' (a wrapper that belongs to a document before the left one) counts as
    differing; W46.seg-truth-rescore decides how a contiguous score treats it. Returns a JSON-able summary."""
    want = {"New": "new", "Cont": "same", "Box": "label", "Folder": "label"}
    out, open_ids = {}, []
    for k in keyrows:
        ans = answers.get(k["id"])
        sec = out.setdefault(k["section"], collections.Counter())
        if ans not in CHOICE_TEXT or ans == "unsure":
            open_ids.append(k["id"])
            sec["open"] += 1
            continue
        sec["answered"] += 1
        same = want.get(k["current"]) == ("same" if ans == "fallback" else ans)   # fallback keeps the photo: Cont
        sec["agrees with current truth" if same else "differs"] += 1
    sc = [k for k in keyrows if k["section"] == "sc0122" and answers.get(k["id"]) in ("new", "same", "label")]
    num = den = 0.0
    for k in sc:
        big_n, n = strata[k["stratum"]]
        w = big_n / n
        den += w
        num += w * (want.get(k["current"]) != answers[k["id"]])
    return {"sections": {s: dict(c) for s, c in out.items()}, "open": open_ids,
            "sc0122_agreed_weighted_error": round(num / den, 4) if den else None,
            "sc0122_agreed_weighted_errors_of_162": round(162 * num / den, 1) if den else None}


def cmd_fold(a):
    with open(os.path.join(CACHE, "key.json"), encoding="utf-8") as f:
        key = json.load(f)
    answers = SB.read_answers(a.answers)
    summary = fold(key["cases"], key["strata"], answers)
    rulings = [{**k, "answer": answers.get(k["id"])} for k in key["cases"]]
    with open(os.path.join(CACHE, "rulings.json"), "w", encoding="utf-8") as f:
        json.dump({"answers_file": os.path.basename(a.answers), "summary": summary, "rulings": rulings}, f, indent=1,
                  ensure_ascii=False)
    print(json.dumps(summary, indent=1))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("sheet").set_defaults(fn=cmd_sheet)
    f = sub.add_parser("fold")
    f.add_argument("answers")
    f.set_defaults(fn=cmd_fold)
    a = p.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
