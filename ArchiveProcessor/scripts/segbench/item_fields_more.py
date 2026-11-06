#!/usr/bin/env python3
"""W47.item-fields-more-checks: a second item-field sheet, drawn at random from the image prompt's readings, so the
owner-checked n reaches the fill rule's floor (filed by W47.item-fields-retruth-score, 2026-11-05).

    python3 item_fields_more.py sheet     # CACHE/sheet2: index.html and key.json (private); the draw summary

Offline and $0: every reading is already in the bench cache. It reads the corpus's Finder tags with getxattr(2)
(corpus_survey.read_tags), nothing else there, and writes nothing in it.

Why. The first sheet left 15-21 owner-checked documents with a true value on each item field, kind 38, against the
40 the fill rule needs (item_fields_score.FLOOR), so every Gemini route's verdict was "too close (n)". Its checked
pairs also lean to the hard cases: kind crossings and disputes were chosen for being hard.

The draw. The image prompt is drafter A's reading (Gemini 3.7 Flash, the item prompt on the page images). A pair is
eligible when the score item would score it on owner-checked pairs: the document is not one with a page read
sideways, the field is in scope for the folded truth's kind and not unknown, and the owner has not settled it on the
first sheet or in a note. One seeded shuffle of the documents (SEED) orders every field's draw, and each field takes
the first eligible documents in that order: for each field, a uniform random sample of its eligible pairs, with no
route but the drawn one consulted and no document preferred, while the fields share documents, which keeps the
pages to look over down. Each field takes ceil(need / FILL_SHARE) of its pairs where the image prompt gave a value
(need = FLOOR less the owner-checked n with a true value), so that with some readings wrong and some answers "can't
tell" the floor is still reached, and EMPTY_PER_FIELD where it gave none, for recall. Kind is always given, so it has
no empty draw. The filled draw measures the image prompt's precision directly; the empty draw, how often it misses.

The sheet. One reading per question (the image prompt's value, or "(empty)"), confirmed or corrected, in
item_fields_retruth's sheet with its notes box per document, the fields it does not ask, and pages upright (root
CLAUDE.md, owner 2026-11-05). The not-asked line lists every truth the document has: the folded item fields (marked
where the owner checked one on the first sheet), W46.fix-ent-truth's sender, recipient and sending place, and the
owner's date tags on the first page. Ids are "<doc>:more-<field>", distinct from the first sheet's, so the score
item can fold both keys together. The texts, readings and the sheet stay in the bench cache (the owner's material;
the repo is public); the committed summary has counts only.
"""
from __future__ import annotations

import collections
import json
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ent_truth as ET  # noqa: E402
import item_fields as IF  # noqa: E402
import item_fields_retruth as IR  # noqa: E402
import item_fields_score as IS  # noqa: E402

OUT = os.path.join(IR.CACHE, "sheet2")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "item-fields-more-sheet.md")
SEED = 4750
FILL_SHARE = 0.8        # the share of a filled draw expected to end with a true value the owner settled
EMPTY_PER_FIELD = 10
ROUTE = "draft-gemini"
PART = "draw"
STORE = "w47-item-fields-more"
DATE_NAME = "date (your Finder tags on the first page)"

INTRO = """A second check, drawn at random so the readings can be measured. Each question offers one reading of a
field: <b>1</b> right · <b>0</b> wrong (type what the pages show; empty = the field is empty) · <b>9</b> can't tell
· <b>n/p</b> next/previous · <b>z</b> zoom. A reading offered as <i>(empty)</i>: <b>1</b> means the pages show no
such thing, <b>0</b> that they do: type it. Give what the pages show; when a value needs inference (a full name from
initials, a paper from its initials), say so in the notes. The grey line lists every other truth the document has,
with what goes into it: the item fields (marked where you checked one on the first sheet), the sender, recipient and
sending place from the entity truth, and the date from your Finder tags. Those go in as listed; the notes box under
each document is for one that is wrong or missing, or anything else. Pages photographed sideways or upside down are
shown turned upright where a check found them; "turn page" turns any other, with its boxes. Pink boxes mark where a
reading was found in the text (from Apple Vision's line positions; they can be off, and a reading with no box was not
found)."""


def owner_n(frows, skip):
    """{field: owner-checked documents with a true value}, as item_fields_score.build counts them."""
    return {f: sum(1 for t in frows if t["owner"].get(f) and t["id"] not in skip and IF.filled(f, t["label"][f])
                   and (IF.SCOPE[f] is None or t["label"]["kind"] in IF.SCOPE[f])) for f in IS.FIELDS}


def eligible(frows, pred, skip):
    """{field: {"filled": [doc], "empty": [doc]}}: the pairs item_fields_score.pairs would score on owner-checked
    pairs once answered, that the owner has not settled, split by whether the route gave a value."""
    out = {f: {"filled": [], "empty": []} for f in IS.FIELDS}
    for t in frows:
        p = pred.get(t["id"])
        if p is None or t["id"] in skip:
            continue
        for f in IS.FIELDS:
            ks = IF.SCOPE[f]
            if f in t["unknown"] or (ks is not None and t["label"]["kind"] not in ks) or t["owner"].get(f):
                continue
            out[f]["filled" if IF.filled(f, p.get(f)) else "empty"].append(t["id"])
    return out


def draw(pools, have, rng, floor=IS.FLOOR, share=FILL_SHARE, empty=EMPTY_PER_FIELD):
    """[(doc, field, "filled"|"empty")]: one seeded shuffle of the documents; each field takes the first of its
    eligible documents in that order, ceil(need / share) filled and `empty` empty (none for kind)."""
    order = sorted({d for v in pools.values() for ds in v.values() for d in ds})
    rng.shuffle(order)
    rank = {d: i for i, d in enumerate(order)}
    picks = []
    for f in IS.FIELDS:
        need = max(0, floor - have.get(f, 0))
        want = {"filled": math.ceil(need / share) if need else 0, "empty": 0 if f == "kind" else empty}
        for which, k in want.items():
            for d in sorted(pools[f][which], key=rank.get)[:k]:
                picks.append((d, f, which))
    return picks


def entity_truth():
    p = os.path.join(ET.CACHE, "truth.jsonl")
    if not os.path.exists(p):
        return {}
    with open(p, encoding="utf-8") as fh:
        return {e["id"]: e for e in (json.loads(x) for x in fh)}


def not_asked(t, asked, ent, tag):
    """[[name, value]]: every truth the document has outside the questions asked on it."""
    out = []
    for f in IS.FIELDS:
        v = t["label"].get(f)
        ks = IF.SCOPE[f]
        if f in asked or f in t["unknown"] or not IF.filled(f, v) or (ks is not None and t["label"]["kind"] not in ks):
            continue
        out.append([f, IR.shown(f, v) + (" (you checked it on the first sheet)" if t["owner"].get(f) else "")])
    if ent and ent.get("is_correspondence"):
        for f in ET.FIELDS:
            out.append([f, "; ".join(n["name"] for n in ET.ent_names(ent.get(f))) or "none given"])
    if tag:
        out.append([DATE_NAME, f"{tag[0]}" + (f"-{tag[1]:02d}" if tag[1] else "")])
    return out


def questions(picks, rows, frows, docs):
    """(items, keyed) in item_fields_retruth.write_sheet's shape, one question per pick."""
    by_doc = {d["id"]: d for d in docs}
    rd = {r["id"]: r for r in rows}
    fr = {t["id"]: t for t in frows}
    items, keyed = collections.defaultdict(list), {}
    for doc, f, which in sorted(picks, key=lambda x: (x[0], IS.FIELDS.index(x[1]))):
        r = rd[doc]
        g = r["readers"]["gemini"] or {}
        text = IR.shown(f, g.get(f))
        quote = (r.get("reader_quotes") or {}).get("gemini", {}).get(f)
        boxes = IR.locate(by_doc[doc], text, quote) if f != "kind" and text else []
        n = f"{doc}:more-{f}"
        items[doc].append({"id": n, "part": PART, "field": f, "options": [{"text": text, "boxes": boxes}]})
        keyed[n] = {"doc": doc, "part": PART, "field": f, "options": ["gemini"], "draw": which, "gemini": text,
                    "truth": IR.shown(f, fr[doc]["label"].get(f))}
    return items, keyed


def close_calls(items, docs, turns):
    """Pages on the sheet whose orientation scores give no clear turn and too little text to be sure: to check by
    eye (the sheet-orient-eye.tsv file)."""
    sc = {}
    if os.path.exists(IR.ORIENT):
        with open(IR.ORIENT, encoding="utf-8") as fh:
            for line in fh:
                f = line.rstrip("\n").split("\t")
                if len(f) == 5:
                    sc[os.path.splitext(os.path.basename(f[0]))[0]] = [float(x) for x in f[1:]]
    eye = set()
    if os.path.exists(IR.ORIENT_EYE):
        with open(IR.ORIENT_EYE, encoding="utf-8") as fh:
            eye = {x.split()[0] for x in fh if x.split()}
    by_doc = {d["id"]: d for d in docs}
    out = []
    for doc in items:
        for p in IR.capped(by_doc[doc]["pages"]):
            k = IR.key(p)
            s = sc.get(k)
            if k in turns or k in eye:
                continue
            if s is None or max(s) < IR.TURN_MIN or max(range(4), key=lambda i: s[i]):   # little text, or a turn
                # that scored best without the clear win display_turns asks for
                out.append(k)
    return out


def cmd_sheet(_a):
    rows, docs, key, answers, fixes = IS.load()
    frows, _chk = IS.fold(rows, key, answers, fixes)
    skip = {x["doc"] for x in json.load(open(IS.RETRUTH_JSON, encoding="utf-8"))["counts"]["sideways"]}
    pred = IS.predictions(rows, docs)[ROUTE]
    have = owner_n(frows, skip)
    pools = eligible(frows, pred, skip)
    picks = draw(pools, have, random.Random(SEED))
    items, keyed = questions(picks, rows, frows, docs)
    ent, tags = entity_truth(), IS.owner_tags(docs)
    fr = {t["id"]: t for t in frows}
    turns = IR.display_turns()
    ok = IR.write_sheet(items, keyed, docs, rows, turns=turns, out=OUT, intro=INTRO, store=STORE, appendable=(),
                        seed=SEED, agreed=lambda d, asked: not_asked(fr[d], asked, ent.get(d), tags.get(d)))
    by_part = collections.Counter(fr[d]["part"] for d in items)
    o = {"have": have, "pools": {f: {w: len(v) for w, v in p.items()} for f, p in pools.items()},
         "drawn": {f: dict(collections.Counter(w for _d, g, w in picks if g == f)) for f in IS.FIELDS},
         "questions": len(keyed), "documents": len(items), "by_part": dict(by_part),
         "turned_pages": sum(1 for d in items for p in IR.capped({x["id"]: x for x in docs}[d]["pages"])
                             if turns.get(IR.key(p))),
         "close_calls": close_calls(items, docs, turns), "minutes": round(IR.minutes(items)),
         "entity_listed": sum(1 for d in items if (ent.get(d) or {}).get("is_correspondence")),
         "date_listed": sum(1 for d in items if d in tags), "written": ok}
    json.dump(o, open(os.path.join(OUT, "draw.json"), "w"), indent=1, sort_keys=True)
    open(RESULTS, "w").write(report(o))
    print(report(o))
    print(os.path.join(OUT, "index.html"), "written" if ok else "left as it was (answered)")


def report(o):
    L = ["# Item fields: the second owner sheet, a random draw from the image prompt (W47.item-fields-more-checks)",
         "",
         "Built by `ArchiveProcessor/scripts/segbench/item_fields_more.py sheet`, offline and $0. The sheet and its "
         "key stay in the bench cache (`item-fields-retruth/sheet2/`); this page has counts only.",
         "",
         f"{o['questions']} questions on {o['documents']} documents (base {o['by_part'].get('base', 0)}, clippings "
         f"{o['by_part'].get('clippings', 0)}, handwritten {o['by_part'].get('handwritten', 0)}), about "
         f"{o['minutes']} minutes. {o['turned_pages']} pages are shown turned upright. The not-asked line carries the "
         f"entity truth on {o['entity_listed']} documents and the owner's date tags on {o['date_listed']}.",
         "",
         "| field | owner-checked with a true value now | eligible, the image prompt filled | eligible, empty | "
         "drawn filled | drawn empty |",
         "|---|---|---|---|---|---|"]
    for f in IS.FIELDS:
        L.append(f"| {f} | {o['have'][f]} | {o['pools'][f]['filled']} | {o['pools'][f]['empty']} | "
                 f"{o['drawn'][f].get('filled', 0)} | {o['drawn'][f].get('empty', 0)} |")
    L += ["",
          f"A field draws ceil((40 - n) / {FILL_SHARE}) of its filled pairs, so that some wrong readings and \"can't "
          f"tell\" answers still leave 40, and {EMPTY_PER_FIELD} empty pairs for recall (kind is always filled).",
          "",
          "## Measurement card",
          "",
          "- **Truth**: the owner's answers, when he gives them; until then the questions carry the folded truth "
          "(W47.item-fields-retruth-score) in the key, for the score item only.",
          "- **Selection**: one seeded shuffle of the documents (seed "
          f"{SEED}); each field takes the first eligible documents in it, a uniform draw from that field's pairs "
          "the owner has not settled, split by whether the image prompt (Gemini 3.7, drafter A) gave a value. No "
          "other route and no ABBYY text chose them. Documents with a page read sideways are out, as in the score.",
          "- **Comparison**: none yet; the score item folds both sheets and scores every route on the same pairs.",
          "- **Noise**: the filled draw alone is about 25-32 a field, so its precision is reported with its Wilson "
          "interval; the floor of 40 is met with the first sheet's checked pairs.",
          "- **Scope**: the draw is over the image prompt's readings, so it measures that route's precision "
          "directly; the other routes gain owner-checked pairs but not a draw over their own values. The first "
          "sheet's pairs lean to the hard cases; the score item should report the random draw apart as well."]
    return "\n".join(L) + "\n"


def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("sheet").set_defaults(fn=cmd_sheet)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
