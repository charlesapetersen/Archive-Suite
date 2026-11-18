#!/usr/bin/env python3
"""W46.seg-truth-audit (part 1): an owner sheet for the test-box segmentation truth where the models agreed.

The Stanton and RG165 boundary truth has been re-judged only where a model disagreed with it: the 92 gaps the app's
Gemini route flags, which the owner answered in the W46.seg-check-time session (the 12 where his answer differed were
reviewed, 8 changed: W46.seg-truth-owner-fixes), and Stanton's magazine run (W46.seg-truth-sheet). A gap every model
calls the same way has never been looked at again (owner review of the pipeline doc, 2026-11-17).

  python3 seg_truth_audit.py draw [--preview]   # the agreed pool and a seeded stratified draw of about 50 gaps
  python3 seg_truth_audit.py sheet              # the sheet in the bench cache, pages copied and turned upright
  python3 seg_truth_audit.py fold ANSWERS.json  # rulings beside the truth, and the weighted error estimate

Run each under the heavy lock with the shared torch-env Python (the routes' answers are rebuilt from the cache; no
model call, upload or key: `rescore.no_network()`). Owner images stay on this Mac: the pack and the sheet are in
~/Library/Caches/ArchiveSuiteRehearsal/seg-truth-audit/, never in git. The committed record
(segbench-results/seg-truth-audit.json) holds numbers only.

Pool: every document gap of the two boxes (both pages document pages, not a gap the owner left unknown) where all
eleven ranked settings routes make the same no-checking call, less the gaps the owner already answered. Strata: the
gaps where the consensus differs from the truth (all asked: if any, they are the likeliest truth errors), then box by
truth label, drawn with more weight on the scarcer "new" side. `fold` weights each stratum by N/n, so its error rate
is an estimate for the whole agreed pool.
"""
from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import random
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import data  # noqa: E402

TAG = "W46.seg-truth-audit"
SEED = 20261118
DRAW = 50
CONTEXT = 3                         # pages either side, as on the 13 Nov review
REH = Path.home() / "Library/Caches/ArchiveSuiteRehearsal"
OUT = REH / "seg-truth-audit"
PACK = OUT / "pack.json"            # keys, strata and page paths; the asked gap's truth is in KEY only
KEY = OUT / "key.json"
SHEET = OUT / "index.html"
PAGES = OUT / "img"
RULINGS = OUT / "rulings.json"
RESULTS = HERE.parents[1] / "segbench-results"
RECORD = RESULTS / "seg-truth-audit.json"
CHECK_TIME = REH / "seg-check-time/pack.json"   # the 92 gaps the owner answered on 2026-11-13
RULED = RESULTS / "seg-truth-rulings.json"       # W46.seg-truth-sheet's rulings (Stanton's magazine run)
# Vision's best turn was not upright but not a clear win; each was looked at (2026-11-18) and is upright as taken: photographs,
# a handwritten note, and folder shots whose label is upright (RG165 2, 31 and 50 hold a typed sheet lying sideways inside
# the folder; the sheet's turn button serves it). check_time's own four are upright too.
EYE_UPRIGHT = {"RG165-002", "RG165-031", "RG165-050", "RG165-056", "RG165-057", "RG165-094", "Stanton-014",
               "Stanton-020", "Stanton-021", "Stanton-091", "Stanton-197", "Stanton-198"}
# n drawn per (box, truth label) from the agreed pool; "new" is drawn more heavily since a missed boundary hides an
# owner capture slip (a label card left out) that every model would agree on.
QUOTA = {("Stanton", "new"): 15, ("Stanton", "continue"): 15, ("RG165", "new"): 10, ("RG165", "continue"): 10}


def answered() -> set[str]:
    """"<box> <left>|<right>" of every gap the owner has already ruled on these two boxes."""
    out = {it["key"] for it in json.loads(CHECK_TIME.read_text())["items"]}
    for r in json.loads(RULED.read_text())["rulings"]:
        if r["section"] == "stanton":
            out.add(f"Stanton {r['left']}|{r['right']}")
    return out


def gaps():
    """[{key, box, i, truth, consensus}] for every document gap where all ranked routes agree, and the counts."""
    import rescore
    rescore.no_network()
    import seg_pair_ties as P
    from score import PHOTO, doc_unsure, segment_ids
    labels, cols = P.route_labels()
    done = answered()
    pool, counts = [], {"document_gaps": 0, "agreed": 0, "answered_before": 0}
    for n in data.TEST:
        col = cols[n]
        t = col.labels
        tid, unsure = segment_ids(t), doc_unsure(t)
        pid = {r: segment_ids(by[n]) for r, by in labels.items()}
        for i in range(len(t) - 1):
            if t[i] in PHOTO or t[i + 1] in PHOTO or i + 1 in unsure:
                continue
            counts["document_gaps"] += 1
            calls = {("new" if p[i] != p[i + 1] else "continue") for p in pid.values()}
            if len(calls) != 1:
                continue
            counts["agreed"] += 1
            key = f"{n} {col.pages[i].n}|{col.pages[i + 1].n}"
            if key in done:
                counts["answered_before"] += 1
                continue
            truth = "new" if tid[i] != tid[i + 1] else "continue"
            pool.append({"key": key, "box": n, "i": i, "truth": truth, "consensus": calls.pop()})
    counts["routes"] = sorted(labels)
    return pool, counts, cols


def stratum(g) -> str:
    return "consensus against truth" if g["consensus"] != g["truth"] else f"{g['box']} {g['truth']}"


def draw(pool):
    rng = random.Random(SEED)
    strata: dict[str, list] = {}
    for g in pool:
        strata.setdefault(stratum(g), []).append(g)
    out, table = [], []
    for name in sorted(strata):
        members = strata[name]
        if name == "consensus against truth":
            n = len(members)
        else:
            box, lab = name.split(" ")
            n = min(QUOTA[(box, lab)], len(members))
        picked = sorted(rng.sample(members, n), key=lambda g: (g["box"], g["i"]))
        for g in picked:
            g["stratum"], g["weight"] = name, len(members) / n
        out += picked
        table.append({"stratum": name, "N": len(members), "n": n, "weight": round(len(members) / n, 3)})
    return out, table


def cmd_draw(a):
    pool, counts, _ = gaps()
    picked, table = draw(pool)
    print(json.dumps(counts | {"pool": len(pool)}, indent=1))
    for row in table:
        print(f"  {row['stratum']:28} N {row['N']:4}  n {row['n']:3}  weight {row['weight']}")
    if a.preview:
        return
    record = {"tag": TAG, "date": dt.date.today().isoformat(), "seed": SEED, "counts": counts, "pool": len(pool),
              "strata": table, "drawn": len(picked), "keys": [g["key"] for g in picked]}
    RECORD.write_text(json.dumps(record, indent=1) + "\n")
    OUT.mkdir(parents=True, exist_ok=True)
    KEY.write_text(json.dumps({"tag": TAG, "items": [{k: g[k] for k in ("key", "box", "i", "truth", "consensus",
                                                                       "stratum", "weight")} for g in picked]},
                              indent=1) + "\n")
    print(f"{len(picked)} gaps drawn; {RECORD} and {KEY}")


# --- sheet --------------------------------------------------------------------------------------------------------

def cmd_sheet(_a):
    import check_time as CT
    key = json.loads(KEY.read_text())["items"]
    cols = {n: data.load(n, with_exif=False) for n in data.TEST}
    from score import PHOTO, segment_ids
    PAGES.mkdir(parents=True, exist_ok=True)
    items = []
    for k, g in enumerate(key):
        col = cols[g["box"]]
        t, ids, i = col.labels, segment_ids(col.labels), g["i"]
        lo, hi = max(0, i - CONTEXT + 1), min(len(col.pages) - 1, i + CONTEXT)
        strip = []
        for j in range(lo, hi + 1):
            p = col.pages[j]
            dest = PAGES / f"{g['box']}-{p.n:03d}{p.path.suffix.lower()}"
            if not dest.exists():
                shutil.copyfile(p.path, dest)   # read the box's image, write only the bench cache
            sep = None
            if j < hi:   # the gap after page j: the asked one is hidden, the rest are the truth as it stands (unasked)
                if j == i:
                    sep = "ask"
                elif t[j] in PHOTO or t[j + 1] in PHOTO:
                    sep = "card"
                else:
                    sep = "new" if ids[j] != ids[j + 1] else "same"
            strip.append({"n": p.n, "path": str(dest), "label_photo": t[j] in PHOTO, "sep": sep})
        items.append({"id": f"a{k + 1:02d}", "key": g["key"], "box": g["box"], "left": col.pages[i].n,
                      "right": col.pages[i + 1].n, "strip": strip})
    paths = sorted({p["path"] for it in items for p in it["strip"]})
    saved, CT.OUT = CT.OUT, OUT      # orient() writes its list and scores beside the pack
    try:
        turns = CT.orient(paths)
    finally:
        CT.OUT = saved
    scores = json.loads((OUT / "orient-scores.json").read_text())
    close = sorted(Path(p).stem for p, sc in scores.items() if max(range(4), key=lambda k: sc[k]) and not turns[p])
    unchecked = [c for c in close if c not in EYE_UPRIGHT]
    if unchecked:
        raise SystemExit(f"close orientation calls not checked by eye: {unchecked}; look, then add to EYE_UPRIGHT")
    for it in items:
        for p in it["strip"]:
            p["rotation"] = turns[p["path"]]
            p["src"] = "img/" + Path(p["path"]).name
    turned = sorted(Path(p).stem for p, d in turns.items() if d)
    PACK.write_text(json.dumps({"tag": TAG, "date": dt.date.today().isoformat(), "turned": turned,
                                "close_calls": close, "items": items}, indent=1) + "\n")
    SHEET.write_text(render_sheet(items, turned, close))
    print(f"{len(items)} gaps, {len(paths)} pages, {len(turned)} turned upright, {len(close)} close calls left as taken "
          f"{close}; {SHEET}")


SEP_TEXT = {"new": "│ new", "same": "· same", "card": "· card", "ask": "?"}


def render_sheet(items, turned, close) -> str:
    cards = []
    for it in items:
        cells = []
        for p in it["strip"]:
            cls = "gapL" if p["n"] == it["left"] else "gapR" if p["n"] == it["right"] else ""
            cap = f"p. {p['n']}" + (" (label card)" if p["label_photo"] else "")
            cells.append(f'<figure class="page {cls}"><img src="{p["src"]}" data-r="{p["rotation"]}" '
                         f'style="transform:rotate({p["rotation"]}deg)" loading="lazy"><figcaption>{cap} '
                         f'<button type="button" class="turn">turn</button></figcaption></figure>')
            if p["sep"]:
                cells.append(f'<div class="sep {p["sep"]}">{SEP_TEXT[p["sep"]]}</div>')
        listed = [f"p. {a['n']}|{b['n']}: {a['sep']}" for a, b in zip(it["strip"], it["strip"][1:])
                  if a["sep"] not in ("ask", None)]
        name = html.escape(it["id"])
        cards.append(f'''<section class="card" id="{name}">
  <h2>{html.escape(it["box"])} {it["left"]}|{it["right"]} <span class="sub">is p. {it["right"]} the start of a new document,
  or does it continue the document p. {it["left"]} is in? (outlined)</span></h2>
  <div class="strip">{"".join(cells)}</div>
  <p class="unasked">Not asked, going in as listed (the truth as it stands): {html.escape("; ".join(listed)) or "none"}.</p>
  <fieldset>
    <label><input type="radio" name="{name}" value="new"> new document</label>
    <label><input type="radio" name="{name}" value="continue"> continues</label>
    <label><input type="radio" name="{name}" value="unsure"> can't tell</label>
    <input class="note" type="text" data-id="{name}" placeholder="note (optional): anything wrong here, a listed gap included">
  </fieldset>
</section>''')
    data_js = json.dumps({it["id"]: it["key"] for it in items})
    return f'''<!doctype html><html><head><meta charset="utf-8"><title>Segmentation truth audit: agreed gaps</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root {{ --bg:#fff; --fg:#1d1d1f; --muted:#666; --line:#d0d0d5; --gap:#d1453b; --new:#2f6fdb; --card:#f6f6f8; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#1c1c1e; --fg:#f2f2f7; --muted:#a1a1a6; --line:#3a3a3c;
  --gap:#ff6b5e; --new:#6ea2ff; --card:#2c2c2e; }} }}
body {{ background:var(--bg); color:var(--fg); font:15px/1.45 -apple-system, system-ui, sans-serif; margin:0 16px 90px; }}
h1 {{ font-size:22px; margin:20px 0 4px; }} .intro {{ color:var(--muted); max-width:920px; }}
.card {{ background:var(--card); border:1px solid var(--line); border-radius:10px; padding:12px 14px; margin:18px 0; }}
h2 {{ font-size:17px; margin:0 0 8px; }} .sub {{ font-weight:400; color:var(--muted); font-size:14px; }}
.strip {{ display:flex; align-items:center; gap:4px; overflow-x:auto; padding-bottom:6px; }}
.page {{ margin:0; flex:0 0 auto; text-align:center; }}
.page img {{ height:320px; width:auto; display:block; border:2px solid transparent; border-radius:4px; }}
.gapL img, .gapR img {{ border-color:var(--gap); }}
figcaption {{ font-size:12px; color:var(--muted); }} .turn {{ font-size:11px; }}
.sep {{ flex:0 0 auto; font-size:11px; color:var(--muted); writing-mode:vertical-rl; padding:0 2px; }}
.sep.new {{ color:var(--new); font-weight:600; }} .sep.ask {{ color:var(--gap); font-weight:700; font-size:16px; }}
.unasked {{ font-size:13px; color:var(--muted); margin:4px 0; }}
fieldset {{ border:0; padding:0; margin:8px 0 0; display:flex; flex-wrap:wrap; gap:6px 18px; }}
.note, #snote {{ flex:1 1 260px; padding:4px 6px; border:1px solid var(--line); border-radius:6px; background:var(--bg); color:var(--fg); }}
#done {{ position:fixed; bottom:0; left:0; right:0; background:var(--bg); border-top:1px solid var(--line); padding:10px 16px;
  display:flex; gap:12px; align-items:center; }}
</style></head><body>
<h1>Segmentation truth audit: gaps every model agreed on</h1>
<p class="intro">{len(items)} gaps from the Stanton and RG165 test boxes where all eleven segmentation routes made the
same call. Until now the truth was re-checked only where a model disagreed. For each gap, outlined in red with a
<b>?</b>, say whether the right-hand page starts a new document. The pages either side are context; the marks between
them (<b>│ new</b>, <b>· same</b>, <b>· card</b> for a label photo) are the truth as it stands, not asked, and go in as
listed: if one is wrong, say so in the note. The sheet does not show what the truth or the models say at the asked gap.
Pages were turned upright where Apple Vision was clear ({len(turned)} turned{": " + ", ".join(turned) if turned else ""});
use "turn" on any still sideways. Answers save in this browser as you go; "Save answers" downloads them.</p>
{"".join(cards)}
<div id="done"><span id="count"></span><input id="snote" type="text" placeholder="note on the whole sheet (optional)">
<button type="button" id="save">Save answers</button></div>
<script>
const KEY='seg-truth-audit-answers', IDS={data_js};
let A=JSON.parse(localStorage.getItem(KEY)||'{{}}'); A._notes=A._notes||{{}}; A._turns=A._turns||{{}};
const save=()=>localStorage.setItem(KEY,JSON.stringify(A));
const cnt=()=>{{document.getElementById('count').textContent=Object.keys(IDS).filter(k=>A[k]).length+' of '+Object.keys(IDS).length+' answered';}};
document.querySelectorAll('input[type=radio]').forEach(r=>{{ if(A[r.name]===r.value) r.checked=true;
  r.addEventListener('change',()=>{{A[r.name]=r.value;save();cnt();}}); }});
document.querySelectorAll('input.note').forEach(n=>{{ n.value=A._notes[n.dataset.id]||'';
  n.addEventListener('input',()=>{{A._notes[n.dataset.id]=n.value;save();}}); }});
const sn=document.getElementById('snote'); sn.value=A._notes._sheet||''; sn.addEventListener('input',()=>{{A._notes._sheet=sn.value;save();}});
document.querySelectorAll('.turn').forEach(b=>b.addEventListener('click',()=>{{
  const img=b.closest('figure').querySelector('img'); const src=img.getAttribute('src');
  const r=((+(A._turns[src]??img.dataset.r))+90)%360; A._turns[src]=r; img.style.transform='rotate('+r+'deg)'; save(); }}));
document.querySelectorAll('img').forEach(img=>{{ const r=A._turns[img.getAttribute('src')]; if(r!=null) img.style.transform='rotate('+r+'deg)'; }});
document.getElementById('save').addEventListener('click',()=>{{ const out=Object.assign({{_keys:IDS}},A);
  const b=new Blob([JSON.stringify(out,null,1)],{{type:'application/json'}}); const u=document.createElement('a');
  u.href=URL.createObjectURL(b); u.download='seg-truth-audit-answers.json'; u.click(); }});
cnt();
</script></body></html>
'''


# --- fold ---------------------------------------------------------------------------------------------------------

def fold(answers: dict, key: list[dict], ids: dict[str, str]) -> dict:
    """Each answer beside the truth, per-stratum agreement, and the pool's weighted truth-error estimate."""
    by_key = {g["key"]: g for g in key}
    rows, notes = [], answers.get("_notes") or {}
    for aid, k in ids.items():
        g = by_key[k]
        ans = answers.get(aid)
        rows.append({"id": aid, "key": k, "stratum": g["stratum"], "weight": g["weight"], "truth": g["truth"],
                     "consensus": g["consensus"], "answer": ans, "note": notes.get(aid, ""),
                     "differs": ans in ("new", "continue") and ans != g["truth"]})
    ruled = [r for r in rows if r["answer"] in ("new", "continue")]
    strata = {}
    for r in rows:
        s = strata.setdefault(r["stratum"], {"asked": 0, "ruled": 0, "differs": 0, "unsure": 0, "blank": 0})
        s["asked"] += 1
        s["ruled"] += r["answer"] in ("new", "continue")
        s["differs"] += r["differs"]
        s["unsure"] += r["answer"] == "unsure"
        s["blank"] += r["answer"] is None
    w_all = sum(r["weight"] for r in ruled)
    rate = sum(r["weight"] for r in ruled if r["differs"]) / w_all if w_all else None
    return {"rows": rows, "strata": strata, "ruled": len(ruled), "differs": sum(r["differs"] for r in ruled),
            "weighted_truth_error": rate, "sheet_note": notes.get("_sheet", "")}


def cmd_fold(a):
    answers = json.loads(Path(a.answers).read_text())
    key = json.loads(KEY.read_text())["items"]
    ids = answers.get("_keys") or {f"a{k + 1:02d}": g["key"] for k, g in enumerate(key)}
    out = fold(answers, key, ids)
    RULINGS.write_text(json.dumps(out, indent=1) + "\n")
    for s, v in sorted(out["strata"].items()):
        print(f"  {s:28} asked {v['asked']:3}  ruled {v['ruled']:3}  differs {v['differs']:3}  can't tell {v['unsure']}")
    rate = out["weighted_truth_error"]
    print(f"{out['ruled']} ruled, {out['differs']} differ from the truth; weighted truth error on the agreed pool "
          f"{'n/a' if rate is None else f'{100 * rate:.1f}%'}; {RULINGS}")
    for r in out["rows"]:
        if r["differs"] or r["note"]:
            print(f"  {r['key']}: truth {r['truth']}, answer {r['answer']}  {r['note']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("draw")
    d.add_argument("--preview", action="store_true", help="print the pool and strata, write nothing")
    sub.add_parser("sheet")
    f = sub.add_parser("fold")
    f.add_argument("answers")
    a = ap.parse_args()
    {"draw": cmd_draw, "sheet": cmd_sheet, "fold": cmd_fold}[a.cmd](a)


if __name__ == "__main__":
    main()
