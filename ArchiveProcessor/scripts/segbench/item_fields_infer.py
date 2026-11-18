#!/usr/bin/env python3
"""W47.item-fields-inference: the owner's inference level for item fields, measured before it is a setting.

    python3 item_fields_infer.py run [--limit N]   # the inference prompt on the 299 documents (gateway, CAP)
    python3 item_fields_infer.py score             # the report, segbench-results/item-fields-inference.md

Why. The owner's sheet notes ask for inference as a level the user sets (15 notes; item-fields-score.md "The fold"): a
name from initials or an office ("M.Y.", i.e. Michael Young; "President Lyman", i.e. Richard Lyman), a paper from its
initials ("P.A.T.", the Palo Alto Times), a recipient's city from an address ("5 University Hall", Cambridge, MA). He
also wants every inferred value marked, and one note draws the line: a letter signed "Dave" is David Riesman, "but
this is not given and should not be inferred". The shipped item-field prompt (item_fields_retruth.PROMPT, byte for
byte the app's ItemFieldExtractor) says "Do not guess from general knowledge" and is the only one measured, so a level
that loosens it is a new prompt, measured here before it becomes a setting.

The prompt. INFER_PROMPT is PROMPT with that one line replaced by an inference rule (complete a field the document
gives in part, from the document and what is widely known, when one completion is clear; never add a field the
document does not point to at all) and one more key, "inferred": for each completed field, the words it was completed
from. Its examples are made up, not taken from the set. A value listed there is the marked one the app would show as inferred. No collection name, folder or
neighbouring document is sent, as for the shipped call, so the reader cannot know that "Dave" in the Riesman papers is
Riesman; that is the line the owner drew.

The run. Gemini 3.7 Flash through the Stanford gateway with the shipped call's settings (temperature 0, low
reasoning, 8,192 tokens), on the same 299 documents, page images and Vision text as the shipped prompt's scored
reading (W47.item-fields-retruth's drafter A, read from its cache, never copied), so the comparison is paired. Its own
replies and ledger are in CACHE; CAP bounds the item (real money on a Stanford PTA, under the $7 rule).

The score (offline, $0). Against item_fields_score's folded owner truth, by its stratified precision and fill rule
(FLOOR, LOWER, POINT), three routes: the shipped prompt ("none", the cached drafter A), the inference prompt with
its marked values left out ("as written": what the level does to the values it still reads from the page), and the
inference prompt whole ("inferred": what a user at that level would get). Paired, the values the inference prompt
changes from the shipped one. The marked values themselves are scored apart: against the owner-checked truth where
the owner settled the field, and against the owner's inference notes (NOTE_TRUTH, read by hand from his notes; the
fold dropped those fields as "a name only inference gives", so no other truth has them). The documents read sideways
are left out as in item_fields_score.

Both OCR sets: the item fields have no truth on the public set (no route was ever scored on it there), so the
owner's set is the whole measurement, as it was for W47.item-fields-build.

Readings, notes and values stay in the bench cache (the owner's material; the repo is public); the report has counts.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ent_truth as ET  # noqa: E402
import item_fields as IF  # noqa: E402
import item_fields_retruth as IR  # noqa: E402
import item_fields_score as S  # noqa: E402

CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/item-fields-infer")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "item-fields-inference.md")
CAP = 2.00
STAGE = "infer"
MODEL = IR.MODELS["gemini"]
SHIPPED_LINE = "- Do not guess from general knowledge. Use only this document.\n"
INFER_LINE = (
    "- Inference. When the document gives a field only in part, complete it where the document, with what is widely "
    "known, makes one completion clear: a person's full name from initials, a first name, a surname or an office "
    "(\"J.K.\", \"Dean Smith\"), a publication's full name from its initials or a short form, a recipient's "
    "\"City, State\" from an address or an institution written without them. When more than one completion fits, give "
    "the field as written. Never add a field the document does not point to at all (no title, author, publication, "
    "date or place the pages do not give in some form).\n"
    "- inferred: for each field you completed beyond what the document writes, the words you completed it from, "
    "copied as written; {} when you completed nothing.\n")
SHIPPED_KEYS = '"recipient_place": "..."}}'
INFER_KEYS = '"recipient_place": "..."},\n "inferred": {"byline": "...", "publication": "...", ...}}'
INFER_PROMPT = IR.PROMPT.replace(SHIPPED_LINE, INFER_LINE).replace(SHIPPED_KEYS, INFER_KEYS)
# The owner's inference notes, read by hand into values (item-fields-score's note-fixes dropped these fields, or kept
# a value the note doubts). In the cache, never here: CACHE/note-truth.json, {doc: {field: value}}.
NOTE_TRUTH = os.path.join(CACHE, "note-truth.json")
INFERABLE = ("byline", "publication", "publication_date", "recipient_place")


def prompt_for(d):
    return INFER_PROMPT.replace("{text}", IR.doc_text(d)[:IR.TEXT_CAP])


def parse(raw):
    """(reading with the label definitions applied, {field: the words it was completed from})."""
    r = IR.parse(raw)
    if r is None:
        return None, {}
    js = ET.parse_json(raw) or {}
    inf = js.get("inferred") if isinstance(js.get("inferred"), dict) else {}
    marks = {f: IF.clean(v if not isinstance(v, list) else " ".join(map(str, v))) for f, v in inf.items()
             if f in IF.FIELDS and v not in (None, "", [])}
    r = IR.defined(r)
    return r, {f: w for f, w in marks.items() if IF.filled(f, r.get(f))}


def reading(doc_id):
    p = IR.reply_path(STAGE, doc_id, CACHE)
    return parse(json.load(open(p, encoding="utf-8")).get("raw")) if os.path.exists(p) else (None, {})


def cmd_run(a):
    assert INFER_PROMPT.count("inferred") >= 2 and SHIPPED_LINE not in INFER_PROMPT, "the prompt edit did not apply"
    os.makedirs(CACHE, exist_ok=True)
    docs = [d for d in IR.load_docs() if IR.ready(d)][: a.limit or None]
    res = IR.run_all(docs, lambda d: (d["id"], IR.call(STAGE, d["id"], MODEL, IR.images(d), prompt_for(d), "low",
                                                       root=CACHE, cap=CAP)))
    bad = [i for i, r in res if parse(r.get("raw"))[0] is None]
    print(f"{len(res) - len(bad)}/{len(res)} parsed; ${IR.spent(CACHE):.4f} of ${CAP} spent; unparsed: {bad}")


# --- the score ------------------------------------------------------------------------------------------------------

def plain(r):
    return {f: S.norm(f, r.get(f)) for f in IF.FIELDS} if r else None


def routes(rows):
    ids = [r["id"] for r in rows]
    shipped = {r["id"]: plain(r["readers"]["gemini"]) if r["readers"]["gemini"] else None for r in rows}
    full, written, marks = {}, {}, {}
    for i in ids:
        r, m = reading(i)
        full[i] = plain(r)
        marks[i] = m if r else {}
        written[i] = {f: (S.norm(f, [] if f in IF.LISTS else None) if f in m else v) for f, v in full[i].items()} \
            if r else None
    return {"none": shipped, "as written": written, "inferred": full}, marks


def in_scope(t, f):
    ks = IF.SCOPE[f]
    return ks is None or t["label"]["kind"] in ks


def route_table(P, frows, skip):
    out = {}
    for rk, pred in P.items():
        for f in IF.FIELDS:
            so = IF.score(S.pairs("draft-gemini", True, pred, frows, f, "owner", skip), f)
            st = S.stratified(pred, P["none"], frows, f, skip)
            out[f"{rk}|{f}"] = {"owner": [so["ed2"], so["pred_filled"]], "truth_filled": so["truth_filled"],
                                "strat": st, "verdict": S.verdict(so, 0.0, None, st) if st else "never filled"}
    return out


def changes(P, frows, skip):
    """Per field, on the in-scope documents both prompts answered: how many the inference prompt changed, and of the
    changed ones the owner settled, right before and after."""
    out = {}
    for f in IF.FIELDS:
        c = collections.Counter()
        for t in frows:
            a, b = P["none"].get(t["id"]), P["inferred"].get(t["id"])
            if not a or not b or t["id"] in skip or f in t["unknown"] or not in_scope(t, f):
                continue
            c["docs"] += 1
            if IF.agree(f, a.get(f), b.get(f)):
                continue
            c["changed"] += 1
            c["gained" if not IF.filled(f, a.get(f)) else "emptied" if not IF.filled(f, b.get(f)) else "other"] += 1
            if t["owner"].get(f):
                tv = t["label"][f]
                ok = lambda v: IF.filled(f, v) and IF.field_match(f, v, tv, "ed2") or (  # noqa: E731
                    not IF.filled(f, v) and not IF.filled(f, tv))
                c["owner"] += 1
                c["right before"] += ok(a.get(f))
                c["right after"] += ok(b.get(f))
        out[f] = dict(c)
    return out


def marked(P, marks, frows, skip, notes):
    """The marked (inferred) values: per field how many, and their score where a truth exists for them."""
    by = {t["id"]: t for t in frows}
    out = {f: collections.Counter() for f in IF.FIELDS}
    for i, m in marks.items():
        t = by.get(i)
        if t is None or i in skip:
            continue
        for f in m:
            c, v = out[f], P["inferred"][i].get(f)
            c["marked"] += 1
            if i in notes and f in notes[i]:
                c["note"] += 1
                c["note right"] += IF.field_match(f, v, S.norm(f, notes[i][f]), "ed2")
            elif t["owner"].get(f) and f not in t["unknown"] and in_scope(t, f):
                c["owner"] += 1
                c["owner right"] += IF.filled(f, t["label"][f]) and IF.field_match(f, v, t["label"][f], "ed2")
    return {f: dict(c) for f, c in out.items() if c}


def note_cases(P, marks, notes):
    """For each note value: the shipped prompt's and the inference prompt's reading, and whether it is marked."""
    out = []
    for i, fs in sorted(notes.items()):
        for f, tv in fs.items():
            tv = S.norm(f, tv)
            a, b = ((P[k].get(i) or {}).get(f) for k in ("none", "inferred"))
            hit = lambda v: IF.filled(f, v) and IF.field_match(f, v, tv, "ed2")  # noqa: E731
            out.append({"field": f, "shipped right": bool(hit(a)), "inference right": bool(hit(b)),
                        "marked": f in marks.get(i, {}), "inference filled": IF.filled(f, b)})
    return out


def cell(st):
    if not st:
        return "-"
    return f"{st['precision']:.2f} [{st['lo']:.2f}, {st['hi']:.2f}] of {st['filled']}"


def cmd_score(_a):
    rows, docs, key, answers, fixes = S.load()
    frows, _chk = S.fold(rows, key, answers, fixes)
    side = json.load(open(S.RETRUTH_JSON, encoding="utf-8"))["counts"]["sideways"]
    skip = {x["doc"] for x in side}
    P, marks = routes(rows)
    answered = sum(1 for v in P["inferred"].values() if v)
    notes = json.load(open(NOTE_TRUTH, encoding="utf-8")) if os.path.exists(NOTE_TRUTH) else {}
    notes = {d: v for d, v in notes.items() if not d.startswith("_")}
    led = IR.ledger(CACHE)
    import gateway_gemini as G
    o = {"answered": answered, "docs": len(rows), "routes": route_table(P, frows, skip),
         "changes": changes(P, frows, skip), "marked": marked(P, marks, frows, skip, notes),
         "notes": note_cases(P, marks, notes), "skip": len(skip),
         "docs_marked": sum(1 for i, m in marks.items() if m and i not in skip),
         "spent": sum(G.charge(r) for r in led), "calls": len(led),
         "gateway": sum(r.get("gateway_cost") or 0 for r in led)}
    json.dump(o, open(RESULTS.replace(".md", ".json"), "w"), indent=1, default=str)
    open(RESULTS, "w", encoding="utf-8").write(report(o))
    print(open(RESULTS, encoding="utf-8").read())


def report(o):
    R = o["routes"]
    L = ["# Item fields: the inference level, measured (W47.item-fields-inference)", "",
         "Generated by `scripts/segbench/item_fields_infer.py`; method in its header. The inference prompt (the "
         "shipped item-field prompt with \"Do not guess from general knowledge\" replaced by an inference rule, and "
         "every completed field listed under \"inferred\") on the 299 documents of W47.item-fields-retruth, Gemini 3.7 "
         "Flash through the gateway with the shipped call's settings, scored against item-fields-score.md's folded "
         "owner truth. Counts only; readings and values stay in the bench cache.", "",
         f"Answered {o['answered']} of {o['docs']}; ${o['spent']:.2f} charged over {o['calls']} calls (the gateway's "
         f"own figure ${o['gateway']:.2f}).", "",
         "## Every field, three ways", "",
         "Stratified precision on the owner's values [interval] of the pairs filled, and the fill verdict by "
         "item-fields-score's rule (40 with a true value, lower bound 0.85, point 0.90). none: the shipped prompt; "
         "as written: the inference prompt with its marked values left out; inferred: the inference prompt whole.",
         "", "| field | none | as written | inferred |", "|---|---|---|---|"]
    for f in IF.FIELDS:
        L.append(f"| {f} | " + " | ".join(f"{cell(R[f'{k}|{f}']['strat'])}: {R[f'{k}|{f}']['verdict']}"
                                          for k in ("none", "as written", "inferred")) + " |")
    L += ["", "## What the inference prompt changed, paired", "",
          "On the in-scope documents both prompts answered (sideways documents out): values changed, of them a value "
          "gained, one emptied, or another value; and of the changed ones the owner settled, right before and after.",
          "", "| field | documents | changed | gained | emptied | other | owner-settled | right before | right after |",
          "|---|---|---|---|---|---|---|---|---|"]
    for f, c in o["changes"].items():
        L.append(f"| {f} | {c.get('docs', 0)} | {c.get('changed', 0)} | {c.get('gained', 0)} | {c.get('emptied', 0)} "
                 f"| {c.get('other', 0)} | {c.get('owner', 0)} | {c.get('right before', 0)} | "
                 f"{c.get('right after', 0)} |")
    L += ["", "## The marked values", "",
          f"{o['docs_marked']} documents carry at least one value marked inferred. Scored against the owner's inference "
          "notes where a note gives the value, else against his settled value where he settled the field.", "",
          "| field | marked | against a note: right | against a settled value: right |", "|---|---|---|---|"]
    for f, c in o["marked"].items():
        L.append(f"| {f} | {c.get('marked', 0)} | {c.get('note right', 0)}/{c.get('note', 0)} | "
                 f"{c.get('owner right', 0)}/{c.get('owner', 0)} |")
    n = o["notes"]
    L += ["", "## The owner's inference notes", "",
          f"{len(n)} values the notes give that need inference: the shipped prompt right on "
          f"{sum(x['shipped right'] for x in n)}, the inference prompt on {sum(x['inference right'] for x in n)} "
          f"({sum(x['inference right'] and x['marked'] for x in n)} of them marked inferred); the inference prompt "
          f"filled {sum(x['inference filled'] for x in n)}.", ""]
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--limit", type=int)
    sub.add_parser("score")
    a = ap.parse_args()
    {"run": cmd_run, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    main()
