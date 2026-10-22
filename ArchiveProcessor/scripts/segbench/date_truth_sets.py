#!/usr/bin/env python3
"""W46.fix-date-truth-score: the relation and image-extraction truth sets from the owner's answers to the dating
cases sheet (W46.fix-date-truth, gate W46.date-cases-owner-ok, answered 2026-10-21, 54 cases).

    python3 date_truth_sets.py         # the truth sets (private) and segbench-results/date-truth-sets.md

Inputs, all in the date-tagging bench cache: cases/cases.json (the sheet), cases/answers.json (the owner's export;
a private copy is kept under ~/Claude/Long term storage/Archive Suite owner answers/), sample.jsonl (the owner's
tags). Output: cases/truth-sets.json (private: it carries the owner's notes verbatim, one `note` per record, never
dropped) and a committed summary without the notes. No model call, $0, read-only on the corpus.

What each record says
  basis        where the owner's year came from: own page / cover (the previous document, sent with it) /
               previous, not the cover / inferred from neighbours (the year guessed from surrounding material, the
               notes on a23, a28, a29, a31, a33) / unsure
  sent_with    the relation truth: True for "cover", False for "previous, not the cover", None where the owner
               answered something else (an own-page date says nothing about the previous document)
  relation     a refinement read from the notes: reply (a27), bound issue (a05, d10: pages of one bound magazine
               issue, the cover or contents page first), inferred (above)
  page_date    the image-extraction truth: whether a date is on the document's own pages, its kind
               (handwritten / stamped / printed or typed), where, the string as the owner read it, the year in that
               string, and whether it was legible. a19's owner year came from the previous document, but the note
               puts an illegible printed date on page 2, so the record carries both.
  conflicts    any place the note contradicts the answer or the tag: a page year that differs from the owner's tag
               (the tag is not changed here; the corpus is read-only), a kind given only in the note (a07), a page
               date whose year a later hand supplied (a32).
"""
import collections
import json
import os
import re
import sys

sys.path.insert(0, os.getcwd())
import date_tagging as DT

CASES = os.path.join(DT.CACHE, "cases")
OUT_PRIVATE = os.path.join(CASES, "truth-sets.json")
RESULTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "segbench-results", "date-truth-sets.md")

BASIS = {"image": "own page", "cover": "cover", "prev_other": "previous, not the cover", "nearby": "another document",
         "label": "box or folder label", "knowledge": "outside knowledge", "unsure": "unsure"}
# Read from the notes, case by case, 2026-10-21 (every one of the 38 notes was read; these are the ones that change
# a field). Kept explicit rather than guessed by keyword, since a misread here becomes truth.
INFERRED = {"a23", "a28", "a29", "a31", "a33"}           # "likely date is inferred from previous document"
RELATION = {"a27": "reply", "a05": "bound issue", "d10": "bound issue"}
NOTE_KIND = {"a07": "handwritten"}                      # "Handwritten on top", kind left blank on the sheet
PAGE_DATE_OTHER_BASIS = {"a19"}                         # date printed on page 2, illegible; year from the previous
ILLEGIBLE = {"a19", "a30"}                              # "can't quite make out", "hard to make out precisely"
LATER_HAND = {"a32"}                                    # "Friday 29", the year guessed in pencil by a later reader
NOTE_DATE = {"a17": "Sept 10-26", "d06": "March 7, 1967", "d16": "March 11, 1967", "a32": "Friday 29"}  # no colon
LOCATIONS = (("upper right", "upper right"), ("top left", "upper left"), ("upper left", "upper left"),
             ("bottom right", "lower right"), ("bottom left", "lower left"), ("lower left", "lower left"),
             ("below the byline", "below the byline"), ("first line", "first line"), ("second printed line", "second line"),
             ("last line", "last line"), ("page 2", "page 2"), ("on top", "top"), ("at top", "top"))


def location(note):
    n = (note or "").lower()
    found = list(dict.fromkeys(v for k, v in LOCATIONS if k in n))
    if len(found) > 1 and "top" in found:
        found.remove("top")
    return ", ".join(found) or None


def date_string(note):
    """The date as the owner read it: the text after the last colon, else a 'Stamped …' phrase."""
    if not note:
        return None
    m = re.search(r":\s*(.+?)\s*$", note.strip())
    if m:
        return m.group(1).strip(" .\"")
    m = re.search(r"(?:Stamped|Reads:?)\s+(.+?)\s*$", note.strip())
    return m.group(1).strip(" .\"") if m else None


def year_of(s):
    """The year in a date string: four digits, else a two-digit year after - / . or ' (read as 19xx)."""
    if not s:
        return None
    m = re.findall(r"\b(1[6-9]\d\d|20\d\d)\b", s)
    if m:
        return int(m[-1])
    m = re.search(r"(?:[-/.']|\s')(\d\d)\b\s*$", s)
    return 1900 + int(m.group(1)) if m else None


def truth_record(case, answer, tag):
    """One case: the sheet's card, the owner's answer and the document's owner tag -> its truth record."""
    cid, src, note = case["id"], answer.get("source"), answer.get("note") or ""
    rec = {"id": cid, "doc": case["doc"], "structural_class": case["class"], "folder": case["folder"],
           "position": case["this"]["position"], "owner_year": tag.get("year"), "owner_month": tag.get("month"),
           "date_uncertain": bool(tag.get("du")), "answer": src, "note": note, "conflicts": []}
    basis = BASIS.get(src, src)
    if cid in INFERRED:
        basis = "inferred from neighbours"
    rec["basis"] = basis
    rec["sent_with"] = True if src == "cover" else False if src == "prev_other" else None
    rec["relation"] = RELATION.get(cid, "inferred" if cid in INFERRED else
                                   "cover" if src == "cover" else "other" if src == "prev_other" else None)
    rec["previous"] = case.get("prev", {}).get("position") if case.get("prev") else None
    if src == "image" or cid in PAGE_DATE_OTHER_BASIS:
        kind = answer.get("kind") or NOTE_KIND.get(cid)
        if not answer.get("kind") and cid in NOTE_KIND:
            rec["conflicts"].append(f"kind '{kind}' from the note; left blank on the sheet")
        legible = cid not in ILLEGIBLE
        s = (NOTE_DATE.get(cid) or date_string(note)) if legible else None
        y = year_of(s) if s and cid not in LATER_HAND else None
        rec["page_date"] = {"kind": kind, "location": location(note), "as_read": s, "year": y, "legible": legible,
                            "later_hand_year": cid in LATER_HAND}
        if cid in PAGE_DATE_OTHER_BASIS:
            rec["conflicts"].append("the answer names the previous document, the note an illegible date on page 2")
        if cid in LATER_HAND:
            rec["conflicts"].append("the page's own date has no year; a later reader pencilled one in")
        if y is not None and tag.get("year") is not None and y != tag["year"]:
            rec["conflicts"].append(f"page reads {y}, owner tag {tag['year']}" + (" (Date Uncertain)" if tag.get("du") else ""))
    else:
        rec["page_date"] = None
    if cid == "d06":
        rec["conflicts"].append("date blurry in the processed PDF, clear in the JPEG original")
    return rec


def build(cases, answers, tags):
    recs = [truth_record(c, answers.get(c["id"], {}), tags[c["doc"]]) for c in cases]
    missing = [c["id"] for c in cases if not answers.get(c["id"], {}).get("source")]
    noted = sum(1 for r in recs if r["note"])
    return {"records": recs, "unanswered": missing, "notes_carried": noted,
            "relation": [r["id"] for r in recs if r["sent_with"] is not None],
            "image": [r["id"] for r in recs if r["page_date"]]}


def write_md(t, path):
    R = t["records"]
    by = collections.Counter((r["structural_class"], r["basis"]) for r in R)
    kinds = collections.Counter(r["page_date"]["kind"] or "not said" for r in R if r["page_date"])
    legible = [r for r in R if r["page_date"] and r["page_date"]["legible"]]
    with_year = [r for r in legible if r["page_date"]["year"]]
    agree = [r for r in with_year if r["page_date"]["year"] == r["owner_year"]]
    rel = [r for r in R if r["sent_with"] is not None]
    nA = sum(1 for r in R if r["structural_class"] == "A")
    L = ["# Dating: the relation and image-extraction truth sets (W46.fix-date-truth-score)", "",
         "Written by `scripts/segbench/date_truth_sets.py` from the owner's answers to the dating cases sheet "
         f"(W46.fix-date-truth; answered 2026-10-21, {len(R)} cases, {len(t['unanswered'])} unanswered). The records "
         f"themselves, with the owner's {t['notes_carried']} notes verbatim, stay private in the bench cache "
         "(`date-tagging/cases/truth-sets.json`); this page has no note text. No model call, $0.", "",
         "## Where the owner's year came from", "",
         "| structural class | basis | documents |", "|---|---|---|"]
    for (c, b), n in sorted(by.items(), key=lambda x: (x[0][0], -x[1])):
        L.append(f"| {c} | {b} | {n} |")
    covers = sum(1 for r in R if r["structural_class"] == "A" and r["basis"] == "cover")
    own = sum(1 for r in R if r["structural_class"] == "A" and r["basis"] == "own page")
    L += ["", f"The strict class was built on the guess that a previous document printing the same year was the cover "
          f"the document came with. The owner's answers mostly refute it: of the {nA} strict documents, {covers} were "
          f"sent with the previous document and {own} carry their own date on their pages, which the OCR text missed "
          "or misread. The others take the year from the previous document without it being the cover (a reply, a "
          "run of papers, the year guessed from the neighbours and tagged `Date Uncertain`) or the owner cannot say. "
          "So most of what the enclosure marker would propagate is better found on the page itself, and the "
          "image pass (W46.date-image) matters more than the relation classifier (W46.date-enclosure).", "",
          "## The relation truth set", "",
          f"{len(rel)} documents with an answer about the previous document: sent with it (the cover) "
          f"{sum(r['sent_with'] for r in rel)}, not sent with it {sum(not r['sent_with'] for r in rel)}. Refinements "
          "from the notes: " + ", ".join(f"{k} {v}" for k, v in collections.Counter(
              r["relation"] for r in rel).most_common()) + ". Two cases (a05, d10) are pages of one bound "
          "magazine issue, where the issue's cover or contents page is the dated member of a sequence rather than "
          "an enclosing letter; a scorer should treat a bound issue as its own relation, not as a cover. The "
          "image-sourced and unsure answers say nothing about the previous document and are left out (`sent_with` "
          "null).", "",
          "## The image-extraction truth set", "",
          f"{sum(1 for r in R if r['page_date'])} documents with a date on their own pages that is not in the OCR "
          f"text sent: " + ", ".join(f"{k} {v}" for k, v in kinds.most_common()) + f". {len(legible)} legible; "
          f"the owner read a year from the note on {len(with_year)}, and it matches the owner's tag on {len(agree)}.", "",
          "| case | class | kind | where | legible | page year = tag |", "|---|---|---|---|---|---|"]
    for r in R:
        p = r["page_date"]
        if not p:
            continue
        eq = "–" if not p["year"] else "yes" if p["year"] == r["owner_year"] else f"no ({p['year']} vs {r['owner_year']})"
        L.append(f"| {r['id']} | {r['structural_class']} | {p['kind'] or 'not said'} | {p['location'] or '–'} | "
                 f"{'yes' if p['legible'] else 'no'} | {eq} |")
    conf = [r for r in R if r["conflicts"]]
    L += ["", "## Where a note contradicts the answer or the tag", "",
          "Carried into the records as `conflicts`; nothing is dropped and no tag is changed (the corpus is "
          "read-only). A scorer of page-date extraction scores against the page's date; a scorer of the owner's "
          "year scores against the tag and reports these separately.", ""]
    for r in conf:
        L.append(f"- {r['id']}: " + "; ".join(r["conflicts"]) + ".")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L) + "\n")


def main():
    cases = json.load(open(os.path.join(CASES, "cases.json")))
    answers = json.load(open(os.path.join(CASES, "answers.json")))
    tags = {}
    with open(os.path.join(DT.CACHE, "sample.jsonl")) as fh:
        for line in fh:
            d = json.loads(line)
            tags[d["id"]] = d["truth"]
    t = build(cases, answers, tags)
    with open(OUT_PRIVATE, "w", encoding="utf-8") as fh:
        json.dump(t, fh, ensure_ascii=False, indent=1)
    write_md(t, RESULTS)
    print(f"{len(t['records'])} records, {t['notes_carried']} notes carried, relation {len(t['relation'])}, "
          f"image {len(t['image'])}, unanswered {len(t['unanswered'])}; {OUT_PRIVATE}; {RESULTS}")


if __name__ == "__main__":
    main()
