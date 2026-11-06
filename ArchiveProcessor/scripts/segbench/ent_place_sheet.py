#!/usr/bin/env python3
"""W46.place-rule-sheet: a short owner sheet on the sending places the place rule keeps and empties (measurement
review 2026-11-05 pass 11, P11-3; execution-plans/processing-review/measure-reviews/2026-11-05-3.md).

    python3 ent_place_sheet.py sheet     # ent-truth/place-sheet: index.html and key.json (private); the draw summary

Offline and $0: the truth, the pages, the Vision lines and the orientation scores are already in the bench cache. It
reads the corpus's Finder tags with getxattr(2) (the date on the not-asked line, as item_fields_more does), nothing
else there, and writes nothing in it.

Why. The sending place, as the owner's answers define it, is a place written in the document (ent_truth.place_rule).
`place_kind`, a text heuristic, applied that to the 138: it emptied 26 places he did not answer (24 inferred, 2
institution names), and the tagging prompt's place gain rests on those rows (a tie on the other 112). The emptied
class has support (he emptied 8 of the 8 inferred places he was asked); the kept "heading or address" class, most of
the places the truth keeps, does not (he emptied 1 of the 3 asked), and a recipient's inside address would land in it.

The draw. Two pools, neither touching a place the owner settled or left open (place_rule leaves those as he set
them): KEPT, the documents whose truth, with his answers and the rule, keeps a place `place_kind` puts in a heading or
address; EMPTIED, the documents the rule emptied a place on. One seeded shuffle (SEED) of each pool; KEPT_N and
EMPTIED_N documents taken from the front, a document in both pools counted once, in EMPTIED. No route's reading and no
ABBYY text chose them (`place_kind` reads the truth's quote in the OCR text, and that is the class being measured).

The sheet. One question per document, the same for both classes so the sheet does not say which the rule did: the
place (the kept place, or the one the rule emptied), to confirm as where the document says it was sent from, or
correct (empty = the document does not say). In item_fields_retruth's sheet with a notes box per document, every
other truth the document has on the not-asked line (sender and recipient from the entity truth, the item fields, the
owner's date tags), pages upright, and the place boxed where Vision's lines hold its quote or name. Ids are
"<doc>:place", so the fold (W46.place-rule-fold) reads the key's class beside each answer. The sheet, its key and the
names stay in the bench cache (the owner's material; the repo is public); the committed summary has counts only.
"""
from __future__ import annotations

import collections
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ent_truth as ET  # noqa: E402
import item_fields_more as IM  # noqa: E402
import item_fields_retruth as IR  # noqa: E402
import item_fields_score as IS  # noqa: E402

OUT = os.path.join(ET.CACHE, "place-sheet")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "ent-place-sheet.md")
SEED = 4651
KEPT_N, EMPTIED_N = 12, 8
KEPT_KIND = "heading or address"
PART, FIELD = "place", "sending_place"
STORE = "w46-place-rule-sheet"

INTRO = """Where was each letter sent from, as the document itself writes it (a dateline, a letterhead or an
address)? Each question offers one place, then "wrong" and "can't tell"; click one or press its key: <b>1</b> right,
the document gives this as where it was sent from · <b>0</b> wrong (type the place the document gives; empty = it does
not say where it was sent from) · <b>9</b> can't tell (after typing a correction, Enter moves on) · <b>n/p</b>
next/previous · <b>z</b> zoom. A place only inferred (from the collection, the content, an institution's name) is not
written, so it is <b>0</b> with the box left empty; a recipient's address is not where it was sent from. A letterhead
that is not where the letter was sent from: say so in the notes. The grey line lists every other truth the document
has, with what goes into it: the sender and recipient from the entity truth, the item fields, and the date from your
Finder tags. Those go in as listed; the notes box under each document is for one that is wrong or missing, or anything
else. Pages photographed sideways or upside down are shown turned upright where a check found them; "turn page" turns
any other, with its boxes. Pink boxes mark where the place was found in the text (from Apple Vision's line positions;
they can be off, and a place with no box was not found)."""


def pools(rows, owner_rows, texts):
    """{"kept": {doc: entity}, "emptied": {doc: entity}}. rows: the truth with the owner's answers and the rule;
    owner_rows: with his answers only, which still hold the places the rule emptied."""
    before = {r["id"]: r for r in owner_rows}
    kept, emptied = {}, {}
    for r in rows:
        if FIELD in r.get("owner_checked", []) + r.get("unscored", []):
            continue
        if r.get("place_rule_dropped"):
            gone = [e for e in before[r["id"]][FIELD] if e not in r[FIELD]]
            if gone:
                emptied[r["id"]] = gone[0]
            continue
        ha = [e for e in r[FIELD] if ET.place_kind(e, texts[r["id"]]) == KEPT_KIND]
        if ha:
            kept[r["id"]] = ha[0]
    return {"kept": kept, "emptied": emptied}


def draw(p, seed=SEED, kept_n=KEPT_N, emptied_n=EMPTIED_N):
    """[(doc, class)]: a seeded shuffle of each pool, the first n of each; a document in both is drawn as emptied."""
    rng = random.Random(seed)
    out = []
    for cls, n in (("emptied", emptied_n), ("kept", kept_n)):
        ids = sorted(d for d in p[cls] if not (cls == "kept" and d in p["emptied"]))
        rng.shuffle(ids)
        out += [(d, cls) for d in ids[:n]]
    return out


def questions(picks, p, rows, docs, texts):
    """(items, keyed) in item_fields_retruth.write_sheet's shape."""
    by_doc = {d["id"]: d for d in docs}
    truth = {r["id"]: r for r in rows}
    items, keyed = collections.defaultdict(list), {}
    for doc, cls in sorted(picks):
        e = p[cls][doc]
        # The quote's line, else the name's (a garbled quote the Vision lines spell right): the same for both classes.
        boxes = IR.locate(by_doc[doc], e["name"], e.get("quote")) or IR.locate(by_doc[doc], e["name"], None)
        n = f"{doc}:place"
        items[doc].append({"id": n, "part": PART, "field": FIELD, "options": [{"text": e["name"], "boxes": boxes}]})
        keyed[n] = {"doc": doc, "part": PART, "field": FIELD, "options": ["place"], "class": cls,
                    "place": e["name"], "place_class": e.get("class"), "kind": ET.place_kind(e, texts[doc]),
                    "boxed": bool(boxes), "where": "" if boxes else where(e, texts[doc]),
                    "truth": "; ".join(x["name"] for x in truth[doc][FIELD])}
    return items, keyed


def where(e, text):
    """The fallback for a place with no box (root CLAUDE.md, 2026-10-21): how far through the document's OCR text its
    quote stands, or that neither its quote nor its name was found on Vision's lines."""
    q = e.get("quote")
    i = text.find(q) if q else -1
    if i < 0:
        return "no box: not found in the text as written"
    pct = 100 * i / max(1, len(text))
    return (f"no box: Vision's lines do not hold it; the OCR text has it as “{q}”, "
            + ("near the start of the document's text" if pct < 10 else
               f"about {round(pct, -1):.0f}% of the way through it"))


def not_asked(t, ent, tag, hint=""):
    """Every truth the document has but its sending place: item_fields_more's line less the place asked, and the
    place's fallback when it has no box."""
    return ([["where the place stands", hint]] if hint else []) + \
        [x for x in IM.not_asked(t, set(), ent, tag) if x[0] != FIELD]


def cmd_sheet(_a):
    rows = ET.load_truth()
    owner_rows = ET.load_truth(rule=False)
    texts = {d["id"]: d["text"] for d in ET.load_docs()}
    p = pools(rows, owner_rows, texts)
    picks = draw(p)
    docs = IR.load_docs()
    items, keyed = questions(picks, p, rows, docs, texts)
    irows, _d, ikey, answers, fixes = IS.load()
    frows, _chk = IS.fold(irows, ikey, answers, fixes)
    fr = {t["id"]: t for t in frows}
    ent = {r["id"]: r for r in rows}
    tags = IS.owner_tags([d for d in docs if d["id"] in items])
    turns = IR.display_turns()
    ok = IR.write_sheet(items, keyed, docs, irows, turns=turns, out=OUT, intro=INTRO, store=STORE, appendable=(),
                        seed=SEED, agreed=lambda d, _asked: not_asked(fr[d], ent.get(d), tags.get(d), keyed[f"{d}:place"]["where"]))
    by_doc = {d["id"]: d for d in docs}
    o = {"pools": {c: len(v) for c, v in p.items()},
         "pool_kinds": {c: dict(collections.Counter(ET.place_kind(e, texts[d]) for d, e in v.items()))
                        for c, v in p.items()},
         "drawn": dict(collections.Counter(c for _d, c in picks)),
         "drawn_kinds": dict(collections.Counter(k["kind"] for k in keyed.values())),
         "boxed": {c: sum(1 for k in keyed.values() if k["class"] == c and k["boxed"]) for c in ("kept", "emptied")},
         "questions": len(keyed), "documents": len(items),
         "turned_pages": sum(1 for d in items for pg in IR.capped(by_doc[d]["pages"]) if turns.get(IR.key(pg))),
         "close_calls": IM.close_calls(items, docs, turns), "minutes": round(IR.minutes(items)),
         "date_listed": sum(1 for d in items if d in tags), "written": ok}
    os.makedirs(OUT, exist_ok=True)
    json.dump(o, open(os.path.join(OUT, "draw.json"), "w"), indent=1, sort_keys=True)
    open(RESULTS, "w").write(report(o))
    print(report(o))
    print(os.path.join(OUT, "index.html"), "written" if ok else "left as it was (answered)")


def report(o):
    dk = o["drawn_kinds"]
    L = ["# Sending places: the owner sheet on what the place rule keeps and empties (W46.place-rule-sheet)",
         "",
         "Built by `ArchiveProcessor/scripts/segbench/ent_place_sheet.py sheet`, offline and $0. The sheet and its key "
         "stay in the bench cache (`ent-truth/place-sheet/`); this page has counts only. Measurement review "
         "2026-11-05 pass 11, P11-3; W46.place-rule-fold folds the answers once the gate W46.place-rule-fold-owner-ok "
         "is ticked.",
         "",
         f"{o['questions']} questions on {o['documents']} documents, about {o['minutes']} minutes by the sheets' "
         f"usual allowance (20 s a document, 12 s a question; one place a document, so likely less). "
         f"{o['turned_pages']} pages are shown turned upright; the owner's date tags are listed on "
         f"{o['date_listed']}.",
         "",
         "| class | documents in the pool | drawn | drawn with a box on the page |",
         "|---|---|---|---|",
         f"| kept, in a heading or address | {o['pools']['kept']} | {o['drawn'].get('kept', 0)} | "
         f"{o['boxed']['kept']} |",
         f"| emptied by the rule | {o['pools']['emptied']} | {o['drawn'].get('emptied', 0)} | "
         f"{o['boxed']['emptied']} |",
         "",
         "The emptied pool by what `place_kind` found: " + ", ".join(f"{k} {v}" for k, v in
                                                                   sorted(o["pool_kinds"]["emptied"].items()))
         + "; drawn: " + ", ".join(f"{k} {v}" for k, v in sorted(dk.items())) + ".",
         "",
         "## Measurement card",
         "",
         "- **Truth**: the owner's answers, when he gives them; the key carries the truth as it stands (his first "
         "answers and the rule) beside each question, for the fold only.",
         f"- **Selection**: a seeded shuffle of each pool (seed {SEED}), the first {KEPT_N} kept and {EMPTIED_N} "
         "emptied; the places the owner settled or left open are in neither pool. No route's reading and no ABBYY text "
         "chose them; the class is `place_kind`'s, the heuristic being measured.",
         "- **Comparison**: none yet; the fold restates the tagging and entity arms of `ent-place-rule.md` on the "
         "owner-checked rows and on the rest.",
         f"- **Noise**: {KEPT_N} and {EMPTIED_N} documents give each class's error with a wide Wilson interval (one "
         f"wrong in {KEPT_N} is 1% to 35%); enough to tell a class that is mostly right from one that is not, not to "
         "rank routes.",
         "- **Scope**: one place a document (the first kept heading-or-address place, or the first emptied one); the "
         "other places of a document and the dateline and image classes are not drawn. The 138 correspondence "
         "documents of W46.fix-ent-truth only."]
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
