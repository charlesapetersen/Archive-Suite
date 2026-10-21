#!/usr/bin/env python3
"""W46.fix-date-truth: the dating classes A to D on the 131 unprinted-year documents, the owner's sheet for the 33
strict and 21 none cases, and the dating scorer changes applied to every cached answer.

Classes (B-dating.md §Test design 1; enclosure_split.py's neighbours, tag-rule segments in folder order, "printed"
= the owner's year string in that document's first 3,000 characters of ABBYY text):
  A   strict    the previous segment is a document printing this document's owner year
  A'  chained   the previous document has the same owner year unprinted, and a printed one lies within three
                positions back through an unbroken run of same-year documents
  B   near      a printed same-year document within three positions either side, not A or A'
  C   far       the nearest printed same-year document is four or more positions away in the folder
  D   none      no printed same-year document in the folder

    python3 date_truth.py classes      # the counts (no files written)
    python3 date_truth.py sheet        # the owner's sheet, under the date-tagging cache's cases/ (private)
    python3 date_truth.py score        # segbench-results/date-truth.md and .json, from cached answers only

Read-only on the corpus: it reads tags and the text cache, and asks `sips` to render first pages into the sheet
folder. No model call, $0. W46.fix-date-truth-score reads the owner's exported answers and writes the truth sets.
Run from scripts/segbench.
"""
import argparse
import collections
import html
import json
import os
import subprocess
import sys
import urllib.parse

sys.path.insert(0, os.getcwd())
import corpus_survey as CS
import date_scorers as S
import date_tagging as DT
import enclosure_split as ES

CASES = os.path.join(DT.CACHE, "cases")
RESULTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "segbench-results", "date-truth.md")
RESULTS_JSON = RESULTS[:-3] + ".json"
CLASS_ORDER = ("in text", "A", "A'", "B", "C", "D")
SECONDS_PER_CASE = 60          # B test 1's "about an hour" for 54 cases
ALPHA = 0.1


def structural_class(r, info, found):
    """One of CLASS_ORDER for a year-tagged row of enclosure_split.build_rows."""
    if r["year_in_text"]:
        return "in text"
    if r["prev_dated_same_year"]:
        return "A"
    k, y, segs = info["k"], r["truth"]["year"], info["segs"]
    for j in range(k - 1, max(k - 4, -1), -1):
        t = info["truths"][j][1] if segs[j]["kind"] == "doc" and info["truths"][j] else None
        if not t or t.get("year") != y:
            break
        if ES.own_year_in_text(j, info):
            return "A'"
    if r["any3_dated_same_year"]:
        return "B"
    return "C" if ES.nearest_same_year(r, found) is not None else "D"


def classified():
    sample, found = ES.load()
    rows = ES.build_rows(sample, found, labels=())
    cls = {r["id"]: structural_class(r, found[r["id"]], found) for r in rows}
    return sample, found, rows, cls


def labels():
    """Every model whose cached answers cover the sample: Gemini (None) and each answers-<label> folder."""
    out = [None]
    for name in sorted(os.listdir(DT.CACHE)):
        if name.startswith("answers-") and os.path.isdir(os.path.join(DT.CACHE, name)):
            out.append(name[len("answers-"):])
    return out


def cmd_classes(a):
    sample, found, rows, cls = classified()
    c = collections.Counter(cls.values())
    chained = c["A'"]
    print(f"year-tagged located {len(rows)}; " + ", ".join(f"{k} {c[k]}" for k in CLASS_ORDER))
    print(f"not in text {sum(c[k] for k in CLASS_ORDER[1:])}; within three (A+A'+B) {c['A'] + chained + c['B']}")


# ---- the owner's sheet ---------------------------------------------------------------------------------------------

def year_line(text, year):
    """The line of a document's text that prints the year, trimmed, for the sheet."""
    for line in text[:3000].splitlines():
        if str(year) in line:
            return line.strip()[:160]
    return ""


def tags_of(truth):
    if not truth or not truth[1]:
        return "(no date tags)"
    t = truth[1]
    if "decade" in t:
        s = f"{t['decade']}s"
    else:
        s = str(t["year"]) + (f", month {t['month']:02d}" if t.get("month") else "")
    return s + (", Date Uncertain" if t.get("du") else "")


def thumb(page, name):
    """A sips rendering of a page PDF's first page in the sheet folder; reused when present."""
    out = os.path.join(CASES, "thumbs", name + ".jpg")
    if not os.path.exists(out):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        subprocess.run(["sips", "-s", "format", "jpeg", "-Z", "1100", os.path.join(CS.CORPUS, page), "--out", out],
                       capture_output=True, check=False)
    return "thumbs/" + name + ".jpg" if os.path.exists(out) else None


def doc_card(info, j, role, case_id):
    seg = info["segs"][j]
    pages = seg["pages"]
    return {"role": role, "position": j, "tags": tags_of(info["truths"][j]), "pages": len(pages),
            "links": ["file://" + urllib.parse.quote(os.path.join(CS.CORPUS, p)) for p in pages],
            "names": [os.path.basename(p) for p in pages],
            "img": thumb(pages[0], f"{case_id}-{role}"),
            "img2": thumb(pages[1], f"{case_id}-{role}-2") if role == "this" and len(pages) > 1 else None}


def cmd_sheet(a):
    sample, found, rows, cls = classified()
    by_id = {d["id"]: d for d in sample}
    cases = []
    for r in rows:
        c = cls[r["id"]]
        if c not in ("A", "D"):
            continue
        info = found[r["id"]]
        k, y = info["k"], r["truth"]["year"]
        cid = f"{c.lower()}{sum(1 for x in cases if x['class'] == c) + 1:02d}"
        card = {"id": cid, "doc": r["id"], "class": c, "collection": by_id[r["id"]]["collection"],
                "folder": info["folder"], "year": y, "this": doc_card(info, k, "this", cid)}
        if k > 0 and info["segs"][k - 1]["kind"] == "doc":
            card["prev"] = doc_card(info, k - 1, "prev", cid)
            card["prev"]["line"] = year_line(info["texts"][k - 1], y) if c == "A" else ""
        elif k > 0:
            card["prev_label"] = info["segs"][k - 1]["kind"]
        if k + 1 < len(info["segs"]) and info["segs"][k + 1]["kind"] == "doc":
            card["next"] = {"tags": tags_of(info["truths"][k + 1]), "position": k + 1}
        cases.append(card)
    cases.sort(key=lambda x: (x["class"], x["id"]))
    minutes = len(cases) * SECONDS_PER_CASE / 60
    os.makedirs(CASES, exist_ok=True)
    with open(os.path.join(CASES, "index.html"), "w", encoding="utf-8") as fh:
        fh.write(SHEET_HTML.replace("__DATA__", json.dumps(cases, ensure_ascii=False))
                 .replace("__N__", str(len(cases))).replace("__MINUTES__", f"{minutes:.0f}")
                 .replace("__NA__", str(sum(x["class"] == "A" for x in cases)))
                 .replace("__ND__", str(sum(x["class"] == "D" for x in cases))))
    with open(os.path.join(CASES, "cases.json"), "w", encoding="utf-8") as fh:
        json.dump(cases, fh, ensure_ascii=False, indent=1)
    missing = sum(1 for x in cases for d in (x["this"], x.get("prev")) if d and not d["img"])
    print(f"{len(cases)} cases (A {sum(x['class'] == 'A' for x in cases)}, D {sum(x['class'] == 'D' for x in cases)}), "
          f"about {minutes:.0f} minutes; images not rendered: {missing}; {os.path.join(CASES, 'index.html')}")


SHEET_HTML = r"""<!doctype html><meta charset="utf-8"><title>W46 dating cases</title>
<style>
body{font:14px -apple-system,sans-serif;margin:0}
header{position:sticky;top:0;background:#fff;border-bottom:1px solid #ccc;padding:6px 12px;z-index:2}
.case{border-bottom:3px solid #999;padding:10px}.case.cur{background:#f3f7ff}.case.done h3{color:#060}
.imgs{display:flex;gap:10px;align-items:flex-start}.imgs figure{margin:0;flex:1 1 0}.imgs img{width:100%;border:1px solid #ccc;cursor:zoom-in}
.imgs img.zoom{position:fixed;inset:2vh 2vw;width:auto;height:96vh;z-index:5;cursor:zoom-out;background:#fff}
figcaption{font-size:12px;color:#555}.line{font-family:Georgia,serif;background:#ffd;padding:2px 4px}
.opts{margin:8px 0}.opt{display:block;margin:2px 0;cursor:pointer}.opt.sel{font-weight:bold;color:#060}
.sub{margin-left:24px}.k{color:#888;font-size:12px}textarea{width:60%;height:2.4em}
</style>
<header><b>Dating cases</b> — __N__ documents (__NA__ strict, __ND__ none), about __MINUTES__ minutes.
Each document's year tag is not printed in its OCR text. Say where the year came from.
<b>Strict</b>: the previous document prints the same year — was it the cover this one was sent with?
<b>None</b>: no document in the folder prints that year.
Keys: <b>1-7</b> answer · <b>h/s/t</b> handwritten/stamped/typed (for 4) · <b>c</b> comment · <b>n/p</b> next/previous.
Click an image to enlarge; the file names open the PDFs. Answers stay in this browser;
<button onclick="exportAnswers()">Export answers</button><span id="prog"></span></header><div id="root"></div>
<script>
const DATA=__DATA__;const KEY='w46-date-cases';
const OPTS=[['cover','The previous document: this was sent with it (it is the cover)'],
 ['prev_other','The previous document, but it is not the cover (same file, a reply, a run of papers)'],
 ['nearby','Another document in the folder, not the previous one'],
 ['image','A date on this document\'s own pages that the OCR text missed or misread'],
 ['label','The box or folder label'],['knowledge','What I know about the material, from outside the folder'],
 ['unsure','Can\'t say']];
const KINDS=[['h','handwritten'],['s','stamped'],['t','printed or typed']];
let A=JSON.parse(localStorage.getItem(KEY)||'{}');const els=[];
function esc(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function save(){localStorage.setItem(KEY,JSON.stringify(A));prog()}
function prog(){document.getElementById('prog').textContent=` ${DATA.filter(c=>(A[c.id]||{}).source).length} / ${DATA.length} answered`}
function set(c,f,v){(A[c.id]=A[c.id]||{doc:c.doc,class:c.class})[f]=v;save();paint(c)}
function links(d){return d.names.map((n,i)=>`<a href="${d.links[i]}">${esc(n)}</a>`).join(', ')}
function fig(src,cap){return src?`<figure><img src="${src}" onclick="this.classList.toggle('zoom')"><figcaption>${cap}</figcaption></figure>`:`<figure><i>(no image)</i><figcaption>${cap}</figcaption></figure>`}
function paint(c){const a=A[c.id]||{},el=c.el;el.classList.toggle('done',!!a.source);
 el.querySelectorAll('.opt').forEach(o=>o.classList.toggle('sel',o.dataset.v===a.source||o.dataset.k===a.kind));
 el.querySelector('.sub').style.display=a.source==='image'?'block':'none';el.querySelector('textarea').value=a.note||''}
const root=document.getElementById('root');
DATA.forEach((c,i)=>{const d=document.createElement('div');d.className='case';
 let h=`<h3>${i+1}. ${c.class==='A'?'Strict':'None'} · ${esc(c.collection)} · owner tags: ${esc(c.this.tags)}</h3>`;
 h+=`<div>This document (${c.this.pages} p.): ${links(c.this)}</div>`;
 if(c.prev)h+=`<div>Previous document, tags ${esc(c.prev.tags)}: ${links(c.prev)}${c.prev.line?` — prints: <span class="line">${esc(c.prev.line)}</span>`:''}</div>`;
 else if(c.prev_label)h+=`<div>Previous: a ${esc(c.prev_label)} photograph</div>`;else h+=`<div>First document in the folder</div>`;
 if(c.next)h+=`<div class="k">Next document's tags: ${esc(c.next.tags)}</div>`;
 h+=`<div class="imgs">${fig(c.this.img,'this document, page 1')}${c.this.img2?fig(c.this.img2,'page 2'):''}${c.prev?fig(c.prev.img,'previous document, page 1'):''}</div>`;
 h+='<div class="opts"><b>Where did the year come from?</b>'+OPTS.map((o,j)=>`<span class="opt" data-v="${o[0]}"><span class="k">${j+1}</span> ${o[1]}</span>`).join('')+
  '<div class="sub">'+KINDS.map(k=>`<span class="opt" data-k="${k[1]}"><span class="k">${k[0]}</span> ${k[1]}</span>`).join('')+'</div></div>'+
  '<textarea placeholder="comment (optional)"></textarea>';
 d.innerHTML=h;root.appendChild(d);c.el=d;els.push(c);
 d.querySelectorAll('.opt[data-v]').forEach(o=>o.addEventListener('click',()=>{go(i);set(c,'source',o.dataset.v)}));
 d.querySelectorAll('.opt[data-k]').forEach(o=>o.addEventListener('click',()=>set(c,'kind',o.dataset.k)));
 d.querySelector('textarea').addEventListener('change',e=>set(c,'note',e.target.value));
 d.addEventListener('click',()=>{if(cur!==i)go(i,false)});paint(c)});
let cur=0;function go(i,scroll=true){if(i<0||i>=els.length)return;els[cur].el.classList.remove('cur');cur=i;
 els[cur].el.classList.add('cur');if(scroll)els[cur].el.scrollIntoView({block:'start'})}
document.addEventListener('keydown',e=>{if(e.target.tagName==='TEXTAREA')return;const c=els[cur];if(!c)return;
 if(e.key==='n')go(cur+1);else if(e.key==='p')go(cur-1);
 else if(e.key>='1'&&e.key<='7'){const v=OPTS[+e.key-1][0];set(c,'source',v);if(v!=='image')go(cur+1)}
 else if(['h','s','t'].includes(e.key)&&(A[c.id]||{}).source==='image'){set(c,'kind',KINDS.find(k=>k[0]===e.key)[1]);go(cur+1)}
 else if(e.key==='c'){e.preventDefault();c.el.querySelector('textarea').focus()}});
function exportAnswers(){const b=new Blob([JSON.stringify(A,null,1)],{type:'application/json'});
 const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='date-cases-answers.json';a.click()}
prog();go(0,false);
</script>"""


# ---- scoring cached answers ---------------------------------------------------------------------------------------

def answer_rows(sample, cls, label):
    out = []
    for d in sample:
        p = DT.answer_path(d["prompt"], label)
        if not os.path.exists(p):
            continue
        year, month, du, parsed = DT.app_parse(json.load(open(p)))
        y = int(year) if year and year.isdigit() and len(year) == 4 else None
        r = {"id": d["id"], "truth": d["truth"], "kind": d["class"], "y": y, "parsed": parsed, "du_pred": du,
             "cls": cls.get(d["id"]), "evidence": None}
        if y is not None:
            r["lo"] = r["hi"] = y
        out.append(r)
    return out


def score_label(rows):
    yr = [r for r in rows if "year" in r["truth"]]
    by = {c: [r for r in yr if r["cls"] == c] for c in CLASS_ORDER}
    unprinted = [r for r in yr if r["cls"] not in (None, "in text")]
    strata = {**by, "A+A'": by["A"] + by["A'"], "C+D": by["C"] + by["D"], "not in text": unprinted, "all year-tagged": yr}
    dec = [r for r in rows if r["kind"] == "decade"]
    est = [r for r in yr if r["truth"]["du"]]
    return {
        "documents": len(rows),
        "invalid": S.invalid_rate(rows),
        "by_class": {c: {"n": len(rs), "curve": S.tolerance_curve(rs, 5), "invalid": S.invalid_rate(rs)}
                     for c, rs in strata.items()},
        "decade": {"n": len(dec), "inside": S.tolerance_curve(dec, 0)[0] if dec else [0, 0],
                   "mean_distance": S.mean_distance(dec)},
        "estimated_year": {"n": len(est), "within_tolerance_1": S.tolerance_curve(est, 0, tolerance=1)[0] if est else [0, 0],
                           "mean_distance_tol1": S.mean_distance(est, tolerance=1)},
        "uncertain": {"all": S.du_error_rates(rows), "not in text": S.du_error_rates(unprinted),
                      "in text": S.du_error_rates(by["in text"])},
        "conformal": {c: S.conformal(strata[c], ALPHA) for c in ("in text", "A+A'", "B", "C+D", "not in text", "all year-tagged")},
        "evidence": {"with_evidence": sum(1 for r in rows if r["evidence"])},
    }


def pc(x):
    return f"{100 * x[0] / x[1]:.1f}% ({x[0]}/{x[1]})" if x and x[1] else "–"


def name(label):
    return label or DT.MODEL


def cmd_score(a):
    sample, found, rows, cls = classified()
    counts = collections.Counter(cls.values())
    out = {"classes": {c: counts[c] for c in CLASS_ORDER}, "alpha": ALPHA, "models": {}}
    for lab in labels():
        rs = answer_rows(sample, cls, lab)
        if len(rs) < len(sample):
            continue
        out["models"][name(lab)] = score_label(rs)
    with open(RESULTS_JSON, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=1)
    write_md(out)
    print(f"{len(out['models'])} models scored; {RESULTS}")


def write_md(out):
    M = {m: s for m, s in out["models"].items() if s["invalid"][0] * 2 < s["invalid"][1]}
    dead = [m for m in out["models"] if m not in M]
    c = out["classes"]
    chained = c["A'"]
    L = ["# Dating: the classes A to D and the gap audit's scorers on every cached answer (W46.fix-date-truth)", "",
         "Written by `scripts/segbench/date_truth.py score` from the cached replies of the W41 date-tagging sample (300 "
         "documents, the app's prompt with three neighbours at 300 characters; `date-tagging.md`). No new call, $0. "
         "The scorers are `date_scorers.py` (gap audit §4 fix 9, B-dating.md §3-4).", "",
         "## The classes", "",
         f"Of the 250 year-tagged documents, {c['in text']} print their owner year in the text sent. The other "
         f"{sum(c[k] for k in CLASS_ORDER[1:])} are classed by where the nearest document printing the same owner year "
         "sits in folder order: "
         f"A strict (the previous document) {c['A']}, A' chained (back through unprinted same-year documents, within three) "
         f"{chained}, B near (within three either side, not A or A') {c['B']}, C far (four or more away) {c['C']}, "
         f"D none in the folder {c['D']}. A + A' + B = {c['A'] + chained + c['B']}, the audit's \"within three\".", "",
         "The owner's sheet (private, `date-tagging/cases/` in the bench cache) asks, for the A and D documents, where "
         "the year came from; W46.fix-date-truth-score turns the answers into the relation and image-extraction truth "
         "sets. The classes here are structural (tags and order); they are not yet truth.", "",
         "## Year accuracy by class", "",
         *([f"Left out of every table: {', '.join(dead)}, whose replies give no year on most documents (the thinking "
            "runs, which all ran to the 512-token cap; `date-tagging.md`). They are in `date-truth.json`.", ""] if dead else []),
         "Exact and within one year, every row in the denominator (a reply with no year is a miss). Invalid = "
         "replies the app gets no year from.", ""]
    cols = ["in text", "A", "A'", "B", "C", "D", "not in text"]
    L += ["| model | invalid | " + " | ".join(f"{k} exact" for k in cols) + " |",
          "|---|---|" + "---|" * len(cols)]
    for m, s in M.items():
        L.append(f"| {m} | {pc(s['invalid'])} | " + " | ".join(pc(s["by_class"][k]["curve"][0]) for k in cols) + " |")
    L += ["", "| model | " + " | ".join(f"{k} within 1" for k in cols) + " |", "|---|" + "---|" * len(cols)]
    for m, s in M.items():
        L.append(f"| {m} | " + " | ".join(pc(s["by_class"][k]["curve"][1]) for k in cols) + " |")
    L += ["", "## Tolerance curve on the unprinted years", "",
          "Share of the not-in-text documents within k years of the owner's year (B33's tolerance curve).", "",
          "| model | " + " | ".join(f"k={k}" for k in range(6)) + " |", "|---|" + "---|" * 6]
    for m, s in M.items():
        L.append(f"| {m} | " + " | ".join(pc(x) for x in s["by_class"]["not in text"]["curve"]) + " |")
    L += ["", "## Owner-inferred dates as intervals", "",
          "Decade tags scored as the decade's ten years (HDC distance from the interval); `year + Date Uncertain` "
          "tags scored as the year plus or minus one, since the owner's year is itself an estimate.", "",
          "| model | decade: inside | decade: mean distance (yrs, rows with a year) | estimated year: within ±1 | mean distance beyond ±1 |",
          "|---|---|---|---|---|"]
    for m, s in M.items():
        dm, dn = s["decade"]["mean_distance"]
        em, en = s["estimated_year"]["mean_distance_tol1"]
        L.append(f"| {m} | {pc(s['decade']['inside'])} | {dm:.2f} ({dn})" if dm is not None else f"| {m} | {pc(s['decade']['inside'])} | –")
        L[-1] += f" | {pc(s['estimated_year']['within_tolerance_1'])} | " + (f"{em:.2f} ({en})" if em is not None else "–") + " |"
    L += ["", "## `Date Uncertain` as two error rates", "",
          "Owner-certain (a year, with or without a month, no `Date Uncertain`) flagged uncertain by the reply, and "
          "owner-uncertain (`year + Date Uncertain`) flagged certain. A reply that never sets the flag scores 0% on the "
          "first and 100% on the second, which plain agreement hides at about 80%.", "",
          "| model | certain → flagged (all) | uncertain → not flagged (all) | certain → flagged (not in text) | uncertain → not flagged (not in text) |",
          "|---|---|---|---|---|"]
    for m, s in M.items():
        u = s["uncertain"]
        L.append(f"| {m} | {pc(u['all']['certain_flagged_uncertain'])} | {pc(u['all']['uncertain_flagged_certain'])} | "
                 f"{pc(u['not in text']['certain_flagged_uncertain'])} | {pc(u['not in text']['uncertain_flagged_certain'])} |")
    L += ["", f"## Split-conformal intervals at {int(100 * (1 - out['alpha']))}%", "",
          "The replies give a point year, so the interval is the year widened by the calibration half's quantile of "
          "|error| (FermiEval's rank ceil((1-α)(n+1))), tested on the other half and swapped (seed 46). A stratum needs "
          f"{S.MIN_CALIBRATION} documents in each half (B47), so A' and D cannot be scored alone and are pooled as A+A' and "
          "C+D. A reply with no year is uncovered and left out of the width. q is the widening in years for each half; "
          "Winkler is width plus 2/α times any miss. With 17 or 18 documents a half the 90% rank is the half's largest "
          "or second-largest error, so a single outlier sets q; the pooled strata are the stable figures.", "",
          "| model | stratum | n | q | coverage | width | Winkler |", "|---|---|---|---|---|---|---|"]
    for m, s in M.items():
        for st, r in s["conformal"].items():
            if r is None:
                L.append(f"| {m} | {st} | – | too few | – | – | – |")
                continue
            q = "/".join("∞" if x == float("inf") else str(x) for x in r["q"])
            L.append(f"| {m} | {st} | {r['n']} | {q} | {pc(r['coverage'])} | "
                     + (f"{r['width']:.1f}" if r["width"] is not None else "–") + " | "
                     + (f"{r['winkler']:.1f}" if r["winkler"] is not None else "–") + " |")
    ev = sum(s["evidence"]["with_evidence"] for s in M.values())
    L += ["", "## Evidence validity", "",
          f"No cached reply cites evidence ({ev} rows with any): the app's prompt does not ask for it. "
          "`date_scorers.evidence_check` is ready for W46.date-traceable's prompt, which asks for the cited neighbour "
          "and a quote: the neighbour must be in the context given, the quote a spacing-tolerant substring of its text, "
          "and the quote must carry the year; a located region must contain a date string with that year. A right year "
          "with failed evidence counts as unsupported.", ""]
    with open(RESULTS, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("classes").set_defaults(fn=cmd_classes)
    sub.add_parser("sheet").set_defaults(fn=cmd_sheet)
    sub.add_parser("score").set_defaults(fn=cmd_score)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
