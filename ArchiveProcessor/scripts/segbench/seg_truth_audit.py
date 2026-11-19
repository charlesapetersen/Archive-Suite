#!/usr/bin/env python3
"""W46.seg-truth-audit (part 1): an owner sheet for the test-box segmentation truth where the models agreed.

The Stanton and RG165 boundary truth has been re-judged only where a model disagreed with it: the 92 gaps the app's
Gemini route flags, which the owner answered in the W46.seg-check-time session (the 12 where his answer differed were
reviewed, 8 changed: W46.seg-truth-owner-fixes), and Stanton's magazine run (W46.seg-truth-sheet). A gap every model
calls the same way has never been looked at again (owner review of the pipeline doc, 2026-11-17).

  python3 seg_truth_audit.py draw [--preview]   # the agreed pool and a seeded stratified draw of about 50 gaps
  python3 seg_truth_audit.py sheet              # the sheet in the bench cache, pages copied and turned upright
  python3 seg_truth_audit.py fold ANSWERS.json  # rulings beside the truth, and the weighted error estimate
  python3 seg_truth_audit.py apply              # the ruled changes into the truth CSVs (copied first), the record

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
# n drawn per (box, truth label) from the agreed pool: equal quotas per label, so each box's scarcer label is drawn more
# heavily than its share; fold's N/n weights undo that for the pool-wide estimate.
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
    RECORD.with_suffix(".md").write_text(render_record(record))
    print(f"{len(picked)} gaps drawn; {RECORD} and {KEY}")


def render_record(r) -> str:
    import seg_card
    c = r["counts"]
    L = ["# W46.seg-truth-audit — an owner sheet for the test-box segmentation truth where every model agreed", "",
         "Generated by `seg_truth_audit.py draw` (numbers only: no names, text or images). Owner review of the pipeline "
         "doc, 2026-11-17: the Stanton and RG165 boundary truth was re-judged only where a model disagreed with it (the "
         "92 gaps the app's Gemini route flags, answered by the owner on 2026-11-13, 12 reviewed and 8 changed: "
         "W46.seg-truth-owner-fixes; and Stanton's magazine run, W46.seg-truth-sheet). Cached answers only, $0, no "
         "model call or upload.", "",
         f"Of the two boxes' {c['document_gaps']} document gaps (both pages document pages, the two unknown RG165 gaps "
         f"left out), all {len(c['routes'])} ranked settings routes make the same no-checking call on {c['agreed']}. "
         f"The owner had already answered {c['answered_before']} of those, which leaves a pool of {r['pool']} never "
         "looked at again. On none of them does the consensus differ from the truth, so every drawn gap is one where "
         "the truth and all eleven routes agree.", "",
         "| stratum | N (pool) | n (drawn) | weight N/n |", "|---|---:|---:|---:|"]
    for row in r["strata"]:
        L.append(f"| {row['stratum']} | {row['N']} | {row['n']} | {row['weight']} |")
    L += ["", f"**{r['drawn']} gaps** (seed {r['seed']}). Each box's two labels get equal quotas, so the scarcer label "
          "of each box is drawn more heavily than its share, and RG165 more heavily than its size. The sheet shows three pages either side, hides the truth and the routes at the asked gap, and "
          "lists the unasked gaps in view with the truth as it stands (correctable in a note). Pages turned upright "
          "where Apple Vision was clear (none needed it); the twelve close calls were looked at and are upright as "
          "taken. `fold` weights each answer by its stratum's N/n, so the error rate it prints estimates the whole "
          "pool, and writes the rulings beside the truth in the bench cache; W46.seg-truth-audit-fold applies any "
          "change to the truth and rescores.", ""]
    f = r.get("fold")
    if f:
        lo, hi = f["interval95"]
        sup = f.get("superseded", [])
        L += [f"## The owner's answers ({FOLD_TAG}, {f['date']})", "",
              f"The owner answered all {f['ruled']} gaps ({f['unsure']} can't tell, no notes or turns). "]
        if sup:
            L[-1] += (f"His sheet called {len(sup)} gaps continuations where the truth and all eleven routes call a new "
                      f"document ({', '.join(s['key'] for s in sup)}). Shown each gap alone with pages either side, "
                      "he ruled all of them new documents (2026-11-18), so the later ruling stands and the sheet "
                      "answers are superseded. All of them are one-page documents, where the sheet's layout put the "
                      "next gap's '│ new' mark just right of the asked page; of his 15 Stanton-new answers, 3 of 6 "
                      "one-page cases were answered continues against 0 of 9 others. The sheet now boxes the asked "
                      "pair and names every other mark by its pair.")
        L[-1] += (f" **{f['differs']} of {f['ruled']} differ from the truth**. Weighted by N/n, the truth is wrong on "
                  f"an estimated **{100 * f['weighted_truth_error']:.1f}%** of the agreed pool (95% interval about "
                  f"{100 * lo:.1f}-{100 * hi:.1f}%, n {f['ruled']}).")
        if not f["differs"]:
            ex = exact_upper(f, r["strata"])
            L[-1] += (f" That interval is a normal approximation; the exact one-sided 95% upper bound is about "
                      f"{100 * ex['proportional']:.1f}% if errors spread over the strata in proportion to their size, "
                      f"and {ex['concentrated_max']} of {ex['pool']} gaps ({100 * ex['concentrated_max'] / ex['pool']:.1f}%; "
                      f"{ex['concentrated_max'] + 1} would be excluded, "
                      f"{100 * (ex['concentrated_max'] + 1) / ex['pool']:.1f}%) if they all sat in {ex['concentrated_stratum']}.")
        rc = f.get("recheck", [])
        if rc:
            same = sum(x["answer"] == x["earlier"] for x in rc)
            L[-1] += (f" The {len(rc)} gaps he had answered continues where the old layout could have pushed a one-page "
                      f"document that way were re-asked on the fixed layout (2026-11-18): {same} of {len(rc)} answered "
                      f"as before ({', '.join(x['key'] for x in rc)}), so none changes.")
        L += ["", "| stratum | asked | differ |", "|---|---:|---:|"]
        for s, v in sorted(f["strata"].items()):
            L.append(f"| {s} | {v['asked']} | {v['differs']} |")
        L += ["", ("Changed in the truth (`seg_truth_audit.py apply`, the CSVs copied first to the bench cache): " +
                   "; ".join(f"{c['key']} {c['truth_before']} -> {c['truth_after']}" for c in f["changed"]) +
                   ". Every test-box result is rescored from cached answers in the same item.") if f["changed"] else
              "Nothing in the truth changes, so no test-box result is rescored.", ""]
    L += seg_card.card(
        truth=("The owner's untimed answers, three pages either side, are the truth for the asked gaps, with his "
               "later rulings where he reruled a gap shown alone; they replace his capture labels where they differ."
               if f else
               "None scored here. The sheet asks the owner about gaps whose truth came from his own capture labels and "
               "that no later check reached."),
        selection="The population is chosen by route agreement (that is the audit's definition: agreed gaps were never "
                  "re-judged); within it the draw is seeded and stratified by box and truth label, not by any route's "
                  "confidence or answer. No ABBYY text.",
        comparison=("Every ranked route made the truth's call at each asked gap, so a changed gap would count against "
                    "all of them at that gap: the routes' figures would move together, though not by the same amount (a "
                    "page counts exact only when its whole document is, so the other gaps of the document matter)."
                    if f else "Not applicable until the answers are folded."),
        noise=((f"{f['differs']} of {f['ruled']} answers differ: the pool estimate rests on "
                f"{f['differs']} gap{'s' if f['differs'] != 1 else ''} and its interval is wide." if f["differs"] else
                f"None of {f['ruled']} answers differs: the estimate is zero and its upper bound is what the audit "
                "measures.") +
               " The interval is a normal one on the weighted rate, each stratum's variance from its Wilson interval, "
               "with a finite-pool correction" + ("; at zero differences the exact hypergeometric bound above is the one "
               "to quote." if not f["differs"] else ".") + " The sheet's answers on one-page documents proved unreliable (3 of 6 "
               "reversed); every other answer agrees with the truth, so the layout could not have made a false "
               "difference among them" + (f", and the {len(f['recheck'])} continues it could have caused were "
               "re-asked on the fixed layout and all stood." if f.get("recheck") else
               ", though an agreement it caused would not show.") if f else
               f"{r['drawn']} answers against a pool of {r['pool']}: an error rate near zero will carry a wide interval "
               "(no error in 50 bounds the rate at about 6% with 95% confidence before weighting); report it with its n."),
        scope=(((("Only the asked gaps change. If the estimate holds, about "
                 f"{round(f['weighted_truth_error'] * r['pool']) - f['differs']} more of the {r['pool'] - r['drawn']} "
                 "unasked agreed gaps are wrong; like these they would move every route alike. ") if f["differs"] else
                "Nothing changes. ") if f else "") +
               f"Does not re-rule the agreed gaps the owner already answered ({c['answered_before']}), the "
               f"{c['document_gaps'] - c['agreed']} gaps where the routes split (those the app's Gemini route did not "
               "flag were never asked), the unknown RG165 gaps, or any other box."))
    return "\n".join(L) + "\n"


def cmd_report(_a):
    r = json.loads(RECORD.read_text())
    RECORD.with_suffix(".md").write_text(render_record(r))
    print(RECORD.with_suffix(".md"))


# --- sheet --------------------------------------------------------------------------------------------------------

def cmd_sheet(_a):
    key = json.loads(KEY.read_text())["items"]
    items, turned, close = build_sheet(key, OUT, unchecked_ok=False)
    SHEET.write_text(render_sheet(items, turned, close))
    print(f"{len(items)} gaps, {sum(len(it['strip']) for it in items)} page slots, {len(turned)} turned upright, "
          f"{len(close)} close calls left as taken {close}; {SHEET}")


def build_sheet(key: list[dict], out: Path, unchecked_ok: bool, tag: str = TAG):
    """The sheet's items for asked gaps [{key, box, i}], pages copied to out/img and turned upright where Apple Vision is
    clear; writes out/pack.json. A close call not in EYE_UPRIGHT stops the build unless `unchecked_ok` (a session that
    may not look at the pages leaves it as taken and says so on the sheet). Returns (items, turned, close)."""
    import check_time as CT
    cols = {n: data.load(n, with_exif=False) for n in data.TEST}
    from score import PHOTO, segment_ids
    pages_dir = out / "img"
    pages_dir.mkdir(parents=True, exist_ok=True)
    items = []
    for k, g in enumerate(key):
        col = cols[g["box"]]
        t, ids, i = col.labels, segment_ids(col.labels), g["i"]
        lo, hi = max(0, i - CONTEXT + 1), min(len(col.pages) - 1, i + CONTEXT)
        strip = []
        for j in range(lo, hi + 1):
            p = col.pages[j]
            dest = pages_dir / f"{g['box']}-{p.n:03d}{p.path.suffix.lower()}"
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
    saved, CT.OUT = CT.OUT, out      # orient() writes its list and scores beside the pack
    try:
        turns = CT.orient(paths)
    finally:
        CT.OUT = saved
    scores = json.loads((out / "orient-scores.json").read_text())
    close = sorted(Path(p).stem for p, sc in scores.items() if max(range(4), key=lambda k: sc[k]) and not turns[p])
    unchecked = [c for c in close if c not in EYE_UPRIGHT]
    if unchecked and not unchecked_ok:
        raise SystemExit(f"close orientation calls not checked by eye: {unchecked}; look, then add to EYE_UPRIGHT")
    for it in items:
        for p in it["strip"]:
            p["rotation"] = turns[p["path"]]
            p["src"] = "img/" + Path(p["path"]).name
    turned = sorted(Path(p).stem for p, d in turns.items() if d)
    (out / "pack.json").write_text(json.dumps({"tag": tag, "date": dt.date.today().isoformat(), "turned": turned,
                                               "close_calls": close, "unchecked_close_calls": unchecked,
                                               "items": items}, indent=1) + "\n")
    return items, turned, close


SEP_TEXT = {"new": "│ new", "same": "· same", "card": "· card", "ask": "?"}
# Owner, 2026-11-18: on this sheet he called three one-page documents continuations (Stanton 80|81, 100|101, 138|139)
# and reversed all three when shown the gap alone. The asked page stood between the red ? and a bare "│ new" that
# belonged to the next gap, and the question asked whether it "starts" a document. So the asked pair is now one boxed
# group, every unasked mark names its own pair, the question asks whether the right page belongs with the left one,
# and a page the next gap already separates is said to be a one-page document if it does not continue.


AUDIT_TITLE = "Segmentation truth audit: gaps every model agreed on"
AUDIT_INTRO = """{n} gaps from the Stanton and RG165 test boxes where all eleven segmentation routes made the
same call. Until now the truth was re-checked only where a model disagreed."""


def render_sheet(items, turned, close, title=AUDIT_TITLE, intro=AUDIT_INTRO, store="seg-truth-audit-answers",
                 unchecked=()) -> str:
    """The owner sheet. `intro` is the opening sentences ({n} is the gap count); `store` names the browser's saved
    answers and the downloaded file; `unchecked` lists close orientation calls nobody looked at."""
    cards = []
    for it in items:
        cells, strip = [], it["strip"]
        L, R = it["left"], it["right"]
        for k, p in enumerate(strip):
            cap = f"p. {p['n']}" + (" (label card)" if p["label_photo"] else "")
            fig = (f'<figure class="page"><img src="{p["src"]}" data-r="{p["rotation"]}" '
                   f'style="transform:rotate({p["rotation"]}deg)" loading="lazy"><figcaption>{cap} '
                   f'<button type="button" class="turn">turn</button></figcaption></figure>')
            if p["n"] == L:
                cells.append(f'<div class="asked"><div class="askedlabel">asked: p. {L} | p. {R}</div><div class="pair">')
            cells.append(fig)
            if p["n"] == R:
                cells.append('</div></div>')
            if p["sep"] == "ask":
                cells.append(f'<div class="sep ask">?</div>')
            elif p["sep"]:
                nxt = strip[k + 1]["n"]
                cells.append(f'<div class="sep {p["sep"]}" title="the gap p. {p["n"]}|{nxt}, not asked">'
                             f'{p["n"]}|{nxt} {SEP_TEXT[p["sep"]]}</div>')
        after = next((a["sep"] for a in strip if a["n"] == R), None)
        alone = (f'<p class="alone">p. {R + 1} is already marked as starting another document, so if p. {R} does not '
                 f'belong with p. {L} it is a document of one page.</p>') if after in ("new", "card") else ""
        listed = [f"p. {a['n']}|{b['n']}: {a['sep']}" for a, b in zip(it["strip"], it["strip"][1:])
                  if a["sep"] not in ("ask", None)]
        name = html.escape(it["id"])
        cards.append(f'''<section class="card" id="{name}">
  <h2>{html.escape(it["box"])} {L}|{R} <span class="sub">Does p. {R} belong to the same document as p. {L}?
  (the boxed pair)</span></h2>
  <div class="strip">{"".join(cells)}</div>
  {alone}  <p class="unasked">Not asked, going in as listed (the truth as it stands): {html.escape("; ".join(listed)) or "none"}.</p>
  <fieldset>
    <label><input type="radio" name="{name}" value="continue"> same document as p. {L}</label>
    <label><input type="radio" name="{name}" value="new"> p. {R} starts a new document</label>
    <label><input type="radio" name="{name}" value="unsure"> can't tell</label>
    <input class="note" type="text" data-id="{name}" placeholder="note (optional): anything wrong here, a listed gap included">
  </fieldset>
</section>''')
    data_js = json.dumps({it["id"]: it["key"] for it in items})
    close_note = (f"Apple Vision could not tell for {', '.join(unchecked)}, and no one has looked: they are shown as "
                  "taken. " if unchecked else "")
    return f'''<!doctype html><html><head><meta charset="utf-8"><title>{html.escape(title)}</title>
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
.asked {{ flex:0 0 auto; border:3px solid var(--gap); border-radius:8px; padding:4px 6px; }}
.askedlabel {{ font-size:12px; font-weight:700; color:var(--gap); text-align:center; }}
.pair {{ display:flex; align-items:center; gap:4px; }}
.alone {{ font-size:13px; margin:4px 0; }}
figcaption {{ font-size:12px; color:var(--muted); }} .turn {{ font-size:11px; }}
.sep {{ flex:0 0 auto; font-size:11px; color:var(--muted); writing-mode:vertical-rl; padding:0 2px; }}
.sep {{ opacity:.75; }} .sep.new {{ color:var(--new); font-weight:600; }}
.sep.ask {{ color:var(--gap); font-weight:700; font-size:16px; opacity:1; }}
.unasked {{ font-size:13px; color:var(--muted); margin:4px 0; }}
fieldset {{ border:0; padding:0; margin:8px 0 0; display:flex; flex-wrap:wrap; gap:6px 18px; }}
.note, #snote {{ flex:1 1 260px; padding:4px 6px; border:1px solid var(--line); border-radius:6px; background:var(--bg); color:var(--fg); }}
#done {{ position:fixed; bottom:0; left:0; right:0; background:var(--bg); border-top:1px solid var(--line); padding:10px 16px;
  display:flex; gap:12px; align-items:center; }}
</style></head><body>
<h1>{html.escape(title)}</h1>
<p class="intro">{intro.format(n=len(items))} For each gap, the two pages in the red box
are asked: does the right one belong to the same document as the left one? A page can be a document of one page. The
pages either side are context; each mark between them names its own pair (<b>81|82 │ new</b>, <b>· same</b>,
<b>· card</b> for a label photo), is the truth as it stands, not asked, and goes in as listed: if one is wrong, say so in
the note. The sheet does not show what the truth or the models say at the asked gap.
Pages were turned upright where Apple Vision was clear ({len(turned)} turned{": " + ", ".join(turned) if turned else ""});
{close_note}use "turn" on any still sideways. Answers save in this browser as you go; "Save answers" downloads them.</p>
{"".join(cards)}
<div id="done"><span id="count"></span><input id="snote" type="text" placeholder="note on the whole sheet (optional)">
<button type="button" id="save">Save answers</button></div>
<script>
const KEY='{store}', IDS={data_js};
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
  u.href=URL.createObjectURL(b); u.download='{store}.json'; u.click(); }});
cnt();
</script></body></html>
'''


# --- fold ---------------------------------------------------------------------------------------------------------

# The owner's later rulings, which replace his sheet answers. 2026-11-18 ~09:35, interactive session: shown each of
# the three gaps his sheet called continuations with pages either side (confirm-continuations.html in the bench
# cache), he ruled all three new documents. All three are one-page documents, where the sheet's layout misled
# (fixed in render_sheet the same day).
LATER = {"Stanton 80|81": "new", "Stanton 100|101": "new", "Stanton 138|139": "new"}
LATER_WHY = "owner, 2026-11-18 ~09:35: reruled shown the gap alone; the sheet answer is superseded"

def fold(answers: dict, key: list[dict], ids: dict[str, str]) -> dict:
    """Each answer beside the truth, per-stratum agreement, and the pool's weighted truth-error estimate."""
    by_key = {g["key"]: g for g in key}
    rows, notes = [], answers.get("_notes") or {}
    for aid, k in ids.items():
        g = by_key[k]
        ans = sheet = answers.get(aid)
        ans = LATER.get(k, ans)
        rows.append({"id": aid, "key": k, "stratum": g["stratum"], "weight": g["weight"], "truth": g["truth"],
                     "consensus": g["consensus"], "answer": ans, "note": notes.get(aid, ""),
                     "differs": ans in ("new", "continue") and ans != g["truth"],
                     **({"sheet_answer": sheet, "later": LATER_WHY} if k in LATER else {})})
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
            "weighted_truth_error": rate, "sheet_note": notes.get("_sheet", ""),
            "superseded": sorted(r["key"] for r in rows if "later" in r and r["sheet_answer"] != r["answer"])}


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


# --- apply (W46.seg-truth-audit-fold) -----------------------------------------------------------------------------

FOLD_TAG = "W46.seg-truth-audit-fold"
FOLD_DATE = "2026-11-18"
BACKUP = OUT / "truth-before-audit-fold"
LABEL = {"new": "New", "continue": "Cont"}
# The owner's answers file (2026-11-18 08:40, 50 of 50, no notes or turns) with his later rulings (LATER), checked
# so a misread file cannot fold silently. His sheet called three Stanton gaps continuations (80|81, 100|101,
# 138|139); he reversed all three, so nothing in the truth changes. A first apply wrote those three as Cont and was
# undone by hand from truth-before-audit-fold/ (the folded copy kept as stanton-after-fold-reverted-20261118.csv).
EXPECTED: dict[str, dict[int, str]] = {}
# The owner's re-check (2026-11-18 10:03, recheck-20261118.html): the nine gaps answered continue whose earlier sheet
# could have pushed a one-page document that way, re-asked on the fixed layout. A re-check answer replaces the earlier
# one; apply refuses one that differs, since that would be a reversal for LATER, not a confirmation.
RECHECK = OUT / "seg-truth-audit-recheck-answers.json"


def flips(rows: list[dict]) -> dict[str, dict[int, str]]:
    """box -> {right page: the owner's label} for every ruled answer that differs from the truth."""
    if any(r["answer"] not in ("new", "continue") for r in rows):
        raise SystemExit("an answer is blank or can't tell: no fold rule here, add it to the box's lock.json unsure by hand")
    out: dict[str, dict[int, str]] = {}
    for r in rows:
        if r["differs"]:
            box, gap = r["key"].split()
            out.setdefault(box, {})[int(gap.split("|")[1])] = LABEL[r["answer"]]
    return out


def stratified_interval(folded: dict, strata: list[dict], z: float = 1.96) -> tuple[float, float]:
    """A normal interval for the N/n-weighted error, each stratum's variance from its Wilson-adjusted rate."""
    from seg_truth_rescore import wilson
    total = sum(s["N"] for s in strata)
    rate = var = 0.0
    for s in strata:
        v = folded["strata"][s["stratum"]]
        lo, hi = wilson(v["differs"], v["ruled"], z)
        p, n, W = v["differs"] / v["ruled"], v["ruled"], s["N"] / total
        rate += W * p
        half = (hi - lo) / 2
        var += (W * half / z) ** 2 * (1 - n / s["N"])
    sd = var ** 0.5
    return max(0.0, rate - z * sd), min(1.0, rate + z * sd)


def exact_upper(folded: dict, strata: list[dict], alpha: float = 0.05) -> dict:
    """Exact one-sided upper bounds on the pool's truth errors when no answer differs, each stratum drawn without
    replacement (hypergeometric): errors spread in proportion to the strata (continuous in the count), and all of them
    in the one stratum that hides the most (W46.p16-score-hygiene; the normal interval above is an approximation)."""
    from math import exp, lgamma

    def none_drawn(N: int, K: float, n: int) -> float:
        ch = lambda a, b: lgamma(a + 1) - lgamma(b + 1) - lgamma(a - b + 1)
        return 0.0 if N - K < n else exp(ch(N - K, n) - ch(N, n))

    sizes = [(s["stratum"], s["N"], folded["strata"][s["stratum"]]["ruled"]) for s in strata]
    total = sum(N for _, N, _ in sizes)
    lo, hi = 0.0, float(total)
    for _ in range(60):
        m = (lo + hi) / 2
        p = 1.0
        for _, N, n in sizes:
            p *= none_drawn(N, m * N / total, n)
        lo, hi = (m, hi) if p >= alpha else (lo, m)
    worst = max(((name, max(k for k in range(N + 1) if none_drawn(N, k, n) >= alpha)) for name, N, n in sizes),
                key=lambda x: x[1])
    return {"proportional": round(lo / total, 4), "concentrated_stratum": worst[0], "concentrated_max": worst[1],
            "pool": total}


def cmd_apply(_a):
    from seg_truth_owner_fixes import fold_csv
    folded = json.loads(RULINGS.read_text())
    want = flips(folded["rows"])
    if want != EXPECTED:
        raise SystemExit(f"the answers do not match the owner's file as checked: {want}")
    re_ans = json.loads(RECHECK.read_text())
    by_key = {r["key"]: r for r in folded["rows"]}
    recheck = [{"key": k, "earlier": by_key[k]["answer"], "answer": re_ans.get(i)} for i, k in re_ans["_keys"].items()]
    if any(x["answer"] != x["earlier"] for x in recheck):
        raise SystemExit(f"a re-check answer differs from the folded one; add it to LATER first: {recheck}")
    before = {}
    for box in ("Stanton", "RG165"):
        folder = data.DATA_DIR / data.COLLECTIONS[box]
        (csv_path,) = [p for p in folder.iterdir() if p.suffix.lower() == ".csv"]
        raw = csv_path.read_bytes()
        bom = raw.startswith(b"\xef\xbb\xbf")
        text = raw.decode("utf-8-sig")
        keep = BACKUP / f"{box}-{csv_path.name}"
        after = fold_csv(text, want.get(box, {}))
        if after != text and not keep.exists():
            BACKUP.mkdir(parents=True, exist_ok=True)
            shutil.copy2(csv_path, keep)
        before[box] = dict(data.read_truth(keep if keep.exists() else csv_path))
        if after != text:
            csv_path.write_bytes((b"\xef\xbb\xbf" if bom else b"") + after.encode("utf-8"))
    for box in ("Stanton", "RG165"):
        got = {p.n: p.label for p in data.load(box, with_exif=False).pages}
        for n, lab in want.get(box, {}).items():
            assert got[n] == lab, (box, n, got[n])
        moved = {n for n in got if got[n] != before[box][n]}
        assert moved <= set(want.get(box, {})), (box, moved)
    record = json.loads(RECORD.read_text())
    lo, hi = stratified_interval(folded, record["strata"])
    record["fold"] = {
        "item": FOLD_TAG, "date": FOLD_DATE, "ruled": folded["ruled"], "differs": folded["differs"],
        "unsure": sum(v["unsure"] for v in folded["strata"].values()),
        "weighted_truth_error": round(folded["weighted_truth_error"], 4), "interval95": [round(lo, 4), round(hi, 4)],
        "strata": folded["strata"], "recheck": recheck,
        "superseded": [{"key": r["key"], "sheet_answer": r["sheet_answer"], "answer": r["answer"]}
                       for r in folded["rows"] if r["key"] in folded.get("superseded", [])],
        "changed": [{"key": r["key"], "truth_before": before[r["key"].split()[0]][int(r["key"].split("|")[1])],
                     "answer": r["answer"], "truth_after": LABEL[r["answer"]]} for r in folded["rows"] if r["differs"]]}
    RECORD.write_text(json.dumps(record, indent=1) + "\n")
    RECORD.with_suffix(".md").write_text(render_record(record))
    print(f"folded {want}; weighted error {100 * folded['weighted_truth_error']:.1f}% "
          f"({100 * lo:.1f}-{100 * hi:.1f}%); {RECORD}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("draw")
    d.add_argument("--preview", action="store_true", help="print the pool and strata, write nothing")
    sub.add_parser("sheet")
    sub.add_parser("report")
    f = sub.add_parser("fold")
    f.add_argument("answers")
    sub.add_parser("apply", help="the folded rulings into the Stanton and RG165 truth CSVs, and the record")
    a = ap.parse_args()
    {"draw": cmd_draw, "sheet": cmd_sheet, "fold": cmd_fold, "report": cmd_report, "apply": cmd_apply}[a.cmd](a)


if __name__ == "__main__":
    main()
