#!/usr/bin/env python3
"""W46.ent-place-rule-paid: the sending-place rule the owner's entity answers set, in the app's tagging prompt and the
dedicated entity prompt, measured.

    python3 ent_place_rule.py run [--arm tagging|entity] [--rerun]   # paid, capped
    python3 ent_place_rule.py report                                # segbench-results/ent-place-rule.md and .json

The rule (W46.ent-truth-owner-fold, ent_truth.place_rule): the sending place is a place the document writes, in a
dateline, a letterhead or an address, never one inferred from the collection, the content or an institution's name.
Each prompt keeps its place line and adds that rule to it (TAGGING_PLACE, ENTITY_PLACE; ent_score_paid.with_rules
swaps the one line, so the rest of each prompt is byte for byte the one its baseline replies answered).

Arms, all Gemini 3.7 Flash through the Stanford gateway, text only, temperature 0, the same Vision text as
W46.ent-score-paid:
- tagging-place: the app's tagging prompt as it stands after W46.ent-prompt-app (date_tagging.build_prompt, first
  3,000 characters, the nearby-documents context), with TAGGING_PLACE. Its baseline is ent_prompt_app's tagging-new.
- entity3k-place: ent_score_paid.ENTITY_PROMPT on the same 3,000 characters, with ENTITY_PLACE. Its baseline is
  ent_score_paid's entity3k.
--rerun repeats an arm on the first RERUN documents with one extra newline (the gateway caches a byte-identical
request), for the rerun floor.

Scored against the truth as it now stands (ent_truth.load_truth(): the owner's answers and the place rule), with
ent_truth_owner.scores and ent_score_paid's paired bootstrap; the dates the tagging call returns are checked as
W46.ent-prompt-app checked them (ent_prompt_app.dates, changed, against_owner).
"""
from __future__ import annotations

import argparse
import collections
import json
import math
import os
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ent_prompt_app as EPA  # noqa: E402
import ent_score_paid as P  # noqa: E402
import ent_truth as ET  # noqa: E402

CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/ent-place-rule")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "ent-place-rule.md")
CAP = 1.50                # this item's total, under the owner's $7 a piece of work
RERUN = 40
RULE = ("Only a place the document writes (a dateline, a letterhead or an address): {none} when it writes none, "
        "never a place inferred from an institution's name, the collection or {others}")
TAGGING_PLACE = ('- "author_location": where it was written or sent from (the letterhead\'s or the dateline\'s city), '
                 'as "City, State" with the state written out (e.g. "Chicago, Illinois") or "City, Country", or null. '
                 + RULE.format(none="null", others="the nearby documents"))
ENTITY_PLACE = ('- "sending_place": where it was sent from (the letterhead\'s or the dateline\'s city), as '
                '"City, State" or "City, Country". '
                + RULE.format(none="an empty list", others="other documents") + ".")
TAG, ENT = "tagging-place", "entity3k-place"


def prompt_tagging(d):
    """The tagging prompt as this item measured and shipped it in 4374254d; W46.tagging-prompt-revert took the rule back
    out of the app (owner call 10), so it is pinned here (test_ent_place_rule)."""
    return P.with_rules(EPA.prompt_new(d), {"author_location": TAGGING_PLACE})


def prompt_entity(d):
    return P.with_rules(P.prompt_for("entity3k", d), {"sending_place": ENTITY_PLACE})


LABEL_PROMPT = {TAG: prompt_tagging, TAG + "-rerun": lambda d: prompt_tagging(d) + "\n",
                ENT: prompt_entity, ENT + "-rerun": lambda d: prompt_entity(d) + "\n"}


def cmd_run(a):
    label = {"tagging": TAG, "entity": ENT}[a.arm]
    rs = P.rows()
    if a.rerun:
        rs, label = rs[:RERUN], label + "-rerun"
    with ThreadPoolExecutor(P.WORKERS) as ex:
        list(ex.map(lambda rd: P.call(label, rd[1]["id"], LABEL_PROMPT[label](rd[1]), CACHE, CAP), rs))
    n = sum(os.path.exists(P.reply_path(label, d["id"], CACHE)) for _r, d in rs)
    print(f"{label}: {n}/{len(rs)} answered; ${P.spent(CACHE):.4f} spent of ${CAP}")


def wilson(k, n, z=1.96):
    if not n:
        return [None, None]
    p, d = k / n, 1 + z * z / n
    c, h = (p + z * z / (2 * n)) / d, z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return [round(max(0.0, c - h), 3), round(min(1.0, c + h), 3)]


def cmd_report(_a):
    import ent_truth_owner as EO
    import gateway_gemini as G
    truth = {r["id"]: r for r in ET.load_truth()}
    P.check_replies("entity3k", P.CACHE, lambda d: P.label_prompt("entity3k", d))
    P.check_replies(EPA.NEW, EPA.CACHE, EPA.LABEL_PROMPT[EPA.NEW])
    P.check_replies(EPA.NEW + "-rerun", EPA.CACHE, EPA.LABEL_PROMPT[EPA.NEW + "-rerun"])
    for label, fn in LABEL_PROMPT.items():
        P.check_replies(label, CACHE, fn)
    src = {"tagging-new": (EPA.NEW, EPA.CACHE), "tagging-new-rerun": (EPA.NEW + "-rerun", EPA.CACHE),
           "entity3k": ("entity3k", P.CACHE)} | {k: (k, CACHE) for k in LABEL_PROMPT}
    A = {k: P.preds(lab, c) for k, (lab, c) in src.items()}
    pr = {k: v[0] for k, v in A.items()}
    s = {"docs": len(truth), "answered": {k: len(v[0]) for k, v in A.items()},
         "unparsed": {k: v[1] for k, v in A.items()}, "scores": {}, "paired": {}}
    for k, p in pr.items():
        s["scores"][k] = EO.scores(p, truth)
    for name, a_, b_ in (("tagging: the rule added", "tagging-new", TAG),
                         ("entity: the rule added", "entity3k", ENT),
                         ("tagging with the rule against entity with it", ENT, TAG),
                         ("rerun floor: tagging-new again", "tagging-new", "tagging-new-rerun"),
                         ("rerun floor: tagging-place again", TAG, TAG + "-rerun"),
                         ("rerun floor: entity3k-place again", ENT, ENT + "-rerun")):
        ids = sorted(set(pr[a_]) & set(pr[b_]) & set(truth))
        s["paired"][name] = {"a": a_, "b": b_, **{f: P.paired(pr[a_], pr[b_], ids, truth, f) for f in ET.FIELDS},
                             "city": EO.paired_city(pr[a_], pr[b_], truth)["city"]}
    # measurement review pass 11, P11-3: the same comparisons without the documents whose place the rule emptied,
    # where the prompt's rule and the truth's rule agree by construction
    kept = {i: r for i, r in truth.items() if not r.get("place_rule_dropped")}
    s["paired_rule_kept"] = {}
    for name, a_, b_ in (("tagging: the rule added", "tagging-new", TAG), ("entity: the rule added", "entity3k", ENT)):
        pc = EO.paired_city(pr[a_], pr[b_], kept)
        s["paired_rule_kept"][name] = {"a": a_, "b": b_, "full": pc["full"], "city": pc["city"]}
    s["rule_dropped"] = len(truth) - len(kept)
    # W46.place-rule-fold: the owner's check of the rule's two classes (W46.place-rule-sheet), and the arms restated on
    # the documents whose place the owner checked (either sheet) and on the rest
    corr = json.load(open(ET.OWNER_CORRECTIONS, encoding="utf-8"))
    oc = {}
    for cls in ("kept", "emptied"):
        xs = [x for x in corr["place_asked"] if x["class"] == cls]
        wrong = sum(x["written"] != (cls == "kept") for x in xs)
        oc[cls] = {"n": len(xs), "written": sum(x["written"] for x in xs), "wrong": wrong,
                   "wilson": wilson(wrong, len(xs)), "by_note": sum(x["by"] == "note" for x in xs),
                   "kinds": dict(collections.Counter(x["kind"] for x in xs)),
                   "written_kinds": dict(collections.Counter(x["kind"] for x in xs if x["written"]))}
    s["owner_check"] = oc
    checked = {i for i, r in truth.items() if "sending_place" in r.get("owner_checked", [])}
    s["subsets"] = {}
    for name, ids in (("owner-checked place", checked), ("the rest", set(truth) - checked),
                      ("the rest, rule did not empty", set(kept) - checked)):
        sub = {i: truth[i] for i in ids}
        s["subsets"][name] = {
            "n": len(sub),
            "scores": {k: EO.scores({i: p for i, p in pr[k].items() if i in sub}, sub)
                       for k in ("tagging-new", TAG, "entity3k", ENT)},
            "paired": {nm: {"a": a_, "b": b_, **EO.paired_city(pr[a_], pr[b_], sub)}
                       for nm, a_, b_ in (("tagging: the rule added", "tagging-new", TAG),
                                          ("entity: the rule added", "entity3k", ENT))}}
    # what the rule changed: places dropped and kept where the truth has one, or none
    s["place_moves"] = {}
    for name, a_, b_ in (("tagging", "tagging-new", TAG), ("entity", "entity3k", ENT)):
        c = {"emptied, truth has none": 0, "emptied, truth has one": 0, "filled, truth has none": 0, "other change": 0}
        for i in sorted(set(pr[a_]) & set(pr[b_]) & set(truth)):
            had = bool(ET.ent_names(pr[a_][i].get("sending_place")))
            has = bool(ET.ent_names(pr[b_][i].get("sending_place")))
            t = bool(truth[i]["sending_place"])
            if had and not has:
                c["emptied, truth has " + ("one" if t else "none")] += 1
            elif has and not had:
                c["filled, truth has none" if not t else "other change"] += 1
            elif ET.ent_names(pr[a_][i].get("sending_place")) != ET.ent_names(pr[b_][i].get("sending_place")):
                c["other change"] += 1
        s["place_moves"][name] = c
    # dates, as W46.ent-prompt-app checked them
    D = {"tagging-new": EPA.dates(EPA.NEW, EPA.CACHE), TAG: EPA.dates(TAG, CACHE),
         TAG + "-rerun": EPA.dates(TAG + "-rerun", CACHE), "tagging-new-rerun": EPA.dates(EPA.NEW + "-rerun", EPA.CACHE)}
    import date_tagging as DT
    sample = {json.loads(x)["id"]: json.loads(x)["truth"] for x in open(os.path.join(DT.CACHE, "sample.jsonl"))}
    owner = {i: t for i, t in sample.items() if i in truth}
    s["dates_changed"] = {"tagging-new vs tagging-place": EPA.changed(D["tagging-new"], D[TAG]),
                          "tagging-new vs its rerun": EPA.changed(D["tagging-new"], D["tagging-new-rerun"]),
                          "tagging-place vs its rerun": EPA.changed(D[TAG], D[TAG + "-rerun"])}
    s["dates_owner"] = {k: EPA.against_owner(D[k], owner) for k in ("tagging-new", TAG)}
    led = P.ledger(CACHE)
    s["calls"] = {"n": len(led), "ok": sum(r["http"] == 200 for r in led), "spent": round(P.spent(CACHE), 4),
                  "note": G.billed_note(led)}
    s["rules"] = {"tagging": TAGGING_PLACE, "entity": ENTITY_PLACE}
    json.dump(s, open(RESULTS[:-3] + ".json", "w"), indent=1)
    open(RESULTS, "w").write(report(s))
    print(RESULTS)


def report(s):
    iv = lambda v: f"{v['diff']:+.2f} [{v['lo']:+.2f}, {v['hi']:+.2f}]"  # noqa: E731
    f2 = lambda x: "–" if x is None else f"{x:.2f}"  # noqa: E731
    L = ["# The sending-place rule in the tagging and entity prompts (W46.ent-place-rule-paid)", "",
         "Generated by `scripts/segbench/ent_place_rule.py report`; method in its header. The 138 correspondence "
         "documents, Vision text, Gemini 3.7 Flash through the gateway, scored against the entity truth as it now "
         "stands (`ent_truth.load_truth()`: the owner's answers and the sending-place rule, `ent-truth-owner.md`).", "",
         "The place line each prompt was given:", "",
         f"- tagging: `{s['rules']['tagging']}`", f"- entity: `{s['rules']['entity']}`", "",
         "Answered / unparsed: " + ", ".join(f"{k} {s['answered'][k]}/{s['unparsed'][k]}" for k in s["answered"])
         + ".", "", "## Scores", "",
         "ed2 on the full string, P / R / F1, and the place by its city (F1). \"Filled, no place\" is the documents "
         "where the route names a place and the truth has none; \"wrong\" the documents with a wrong name filled, "
         "which counts those as well, so it is split into the invented places (the \"filled, no place\" column) and "
         "the places wrong where the truth has one.", "",
         "| arm | n | sender F1 | recipient F1 | place P / R / F1 | place by city | filled, no place | place wrong "
         "(all) | wrong where a place is written |",
         "|---|---|---|---|---|---|---|---|---|"]
    for k, v in s["scores"].items():
        sp = v["sending_place"]
        L.append(f"| {k} | {v['n']} | {f2(v['sender']['f1'])} | {f2(v['recipient']['f1'])} | {f2(sp['precision'])} / "
                 f"{f2(sp['recall'])} / {f2(sp['f1'])} | {f2(v['city']['f1'])} | {sp['filled_when_empty']} | "
                 f"{sp['wrong_when_filled_docs']} | {sp['wrong_when_filled_docs'] - sp['filled_when_empty']} |")
    L += ["", "## Paired differences in ed2 F1, b minus a (95% bootstrap interval)", "",
          "| comparison | a → b | n | sender | recipient | sending place | place by city |", "|---|---|---|---|---|---|---|"]
    for k, v in s["paired"].items():
        L.append(f"| {k} | {v['a']} → {v['b']} | {v['sender']['n']} | " + " | ".join(iv(v[f]) for f in ET.FIELDS)
                 + f" | {iv(v['city'])} |")
    L += ["", f"The rule's arms again without the {s['rule_dropped']} documents whose place the truth's rule emptied "
          "(measurement review pass 11, P11-3): on those the prompt's rule and the truth's rule agree by "
          "construction.", "", "| comparison | a → b | n | sending place | place by city |", "|---|---|---|---|---|"]
    for k, v in s["paired_rule_kept"].items():
        L.append(f"| {k} | {v['a']} → {v['b']} | {v['full']['n']} | {iv(v['full'])} | {iv(v['city'])} |")
    oc = s["owner_check"]
    pct = lambda w: f"{w[0] * 100:.0f}% to {w[1] * 100:.0f}%"  # noqa: E731
    L += ["", "## The owner's check of the rule's classes (W46.place-rule-sheet, W46.place-rule-fold)", "",
          "The owner was asked, on 20 documents, whether the place shown is where the document says it was sent from "
          "(answered 2026-11-06, notes read first). The rule is wrong on a kept place he says the document does not "
          "write, and on an emptied place he says it does.", "",
          "| class | asked | he says written | he says not written | the rule wrong | 95% Wilson | of them by a note |",
          "|---|---|---|---|---|---|---|"]
    for cls, lab in (("kept", "kept, in a heading or address"), ("emptied", "emptied by the rule")):
        v = oc[cls]
        L.append(f"| {lab} | {v['n']} | {v['written']} | {v['n'] - v['written']} | {v['wrong']} of {v['n']} | "
                 f"{pct(v['wilson'])} | {v['by_note']} |")
    L += ["", "Emptied places asked, by what `place_kind` found: " + ", ".join(
          f"{k} {v} ({oc['emptied']['written_kinds'].get(k, 0)} of them written)"
          for k, v in sorted(oc["emptied"]["kinds"].items())) + ".", "",
          "The arms on the documents whose sending place the owner checked (on either sheet), on the rest, and on "
          "the rest without the documents the rule emptied:", "",
          "| documents | n | arm | place F1 (ed2) | place by city | filled, no place |", "|---|---|---|---|---|---|"]
    for nm, v in s["subsets"].items():
        for k, sc in v["scores"].items():
            L.append(f"| {nm} | {v['n']} | {k} | {f2(sc['sending_place']['f1'])} | {f2(sc['city']['f1'])} | "
                     f"{sc['sending_place']['filled_when_empty']} |")
    L += ["", "| documents | comparison | n | sending place | place by city |", "|---|---|---|---|---|"]
    for nm, v in s["subsets"].items():
        for k, p in v["paired"].items():
            L.append(f"| {nm} | {k} | {p['full']['n']} | {iv(p['full'])} | {iv(p['city'])} |")
    L += ["", "What the rule changed in the place, document by document:", "",
          "| prompt | " + " | ".join(next(iter(s["place_moves"].values()))) + " |",
          "|---|" + "---|" * len(next(iter(s["place_moves"].values())))]
    for k, v in s["place_moves"].items():
        L.append(f"| {k} | " + " | ".join(str(x) for x in v.values()) + " |")
    L += ["", "## The dates the tagging call returns", "",
          "Documents whose year, month, day or date_uncertain differ, as the app parses them:", "",
          "| pair | n | any | year | month | day | date uncertain |", "|---|---|---|---|---|---|---|"]
    for k, v in s["dates_changed"].items():
        L.append(f"| {k} | {v['n']} | {v['any']} | {v['year']} | {v['month']} | {v['day']} | {v['uncertain']} |")
    L += ["", "Against the owner's Finder date tags, on the 82 from the date-tagging sample:", "",
          "| prompt | n | year right | month right (of tagged) | month given where none tagged | date uncertain agrees |",
          "|---|---|---|---|---|---|"]
    for k, v in s["dates_owner"].items():
        L.append(f"| {k} | {v['n']} | {v['year_right']} | {v['month_right']}/{v['month_truth']} | "
                 f"{v['month_given_untagged']}/{v['month_untagged']} | {v['du_agree']} |")
    L += ["", f"Spend: ${s['calls']['spent']:.2f} estimated over {s['calls']['n']} gateway calls ({s['calls']['ok']} "
          f"answered). {s['calls']['note']}", ""]
    L += READING
    return "\n".join(L) + "\n"


READING = """## Reading

- **The owner's check (W46.place-rule-fold, 2026-11-06): the kept class holds, the emptied class does not.** Of the
  12 places the rule keeps in a heading or address, he confirmed all 12 as where the document says it was sent from
  (0 wrong, 0% to 24%); none was a recipient's inside address. Of the 8 places the rule emptied, he says 4 are
  written (the rule wrong on 4 of 8, 22% to 78%): all 4 were places the truth's drafters classed as inferred, so that
  class is not a reliable sign that the document does not write the place, and the 18 emptied places nobody checked
  are uncertain truth (on this draw, about half would be written). His 20 answers are set outright, so the rule no
  longer touches those documents; the figures below are against that truth.
- **The tagging prompt: no measured gain in the place now, and fewer invented places.** Documents where it names a
  place and the truth has none still fall, from 14 to 1 of 138; the places wrong where the truth has one do not fall
  (14 to 15). The invented places split 6 to 0 on the 32 owner-checked documents, 1 to 0 on the 88 the rule did not
  empty, and 7 to 1 on the 18 unchecked documents whose place the rule emptied, a class the owner found wrong on 4 of
  the 8 he was asked; the firm part is 7 to 0 (measurement review pass 12, P12-8). On the full string F1 0.72 to 0.72, +0.01 (interval -0.08 to +0.09); by the city 0.86 to 0.88, +0.03
  (-0.04 to +0.08), at the rerun floor (+0.03 on 40): a tie, where before the fold it was +0.08 (+0.02 to +0.14).
  The gain went with the four places the owner restored: the old prompt named all four right and the rule line
  emptied all four, while on the four he says are not written it emptied the two the old prompt had filled. On the
  32 documents whose place the owner checked (either sheet) the line ties (by city +0.01, -0.17 to +0.18); on the
  other 106 +0.03 (-0.04 to +0.09); on those 106 without the 18 the truth's rule empties, -0.02 (-0.07 to +0.02).
  So the line, shipped in 4374254d, trades invented places for written places a drafter called inferred, and on this
  truth that is a tie; Phase 4 decides it with the entity feature. Of the 23 documents whose place changed, 13 were
  emptied where the truth has none, 5 emptied where it has one (4 of them the owner's restored places), and 5
  respelled. The sender and recipient do not move (-0.01 and 0.00, inside the floor).
- **Dates hold.** The year, month, day and date_uncertain the same call returns differ on 3 of the 138 documents,
  all three an estimated year (date_uncertain true both times), where the new prompt's own rerun differs on 2 of 40
  and the old prompt's on 1 of 40. Against the owner's Finder date tags on the 82: year right 74 before and 76 after;
  months and Date Uncertain identical.
- **The dedicated entity prompt: no gain, left unchanged.** It already filled a place where none is written on only
  2 documents, because its rule asks for the quote of each name; with the rule, 1. Its place F1 moves -0.04 (interval
  -0.10 to +0.02) and by city -0.01, a tie leaning worse: of its 3 emptied places 2 are places the truth keeps
  ("New York, New York" read from a letterhead's "YORK", and "At Sea"). It named none of the four places the owner
  restored, with the rule or without it. So ENTITY_PROMPT keeps its line, and the
  rule's wording stays here (ENTITY_PLACE) for the entity feature's own prompt to start from.
- **Tagging against the dedicated prompt, both with the rule:** place by city a tie (0.88 each, +0.00); full string
  -0.07 (interval -0.17 to +0.02), the tagging call's respellings against the dedicated prompt's normalised names.

What it means for the app: TagGenerator.generateTags' author_location now asks for a written place only, null when
the document writes none, never one inferred from an institution's name, the collection or the nearby documents
(mirrored in date_tagging.PROMPT and prompts.md). The sidecar field's shape is unchanged. On the owner-checked truth
the line is a tie in the place, with fewer invented places and more written ones missed; this item changes no prompt.
Phase 4 decides the place rule with the entity feature; this is the evidence it reads. The owner's caveat that a letterhead is not always where
a letter was sent from has no text rule and is not tested here.

## Measurement card

- **Truth:** W46.fix-ent-truth's 138 correspondence documents (model truth: GPT 5.6 Luna and Claude Sonnet 5 drafts,
  Sonnet rulings) with the owner's answers on 41 documents (the item-field sheet's 21, W46.ent-truth-owner-fold, and
  W46.place-rule-sheet's 20 sending places, W46.place-rule-fold) and the sending-place rule
  (`ent_truth.load_truth()`). The owner has checked the sending place on 32 documents. The rule empties the place on
  18 documents he did not check, by the class and quote the truth's drafters gave; his check found that class wrong
  on 4 of 8, so those 18 are the weakest rows. The kept heading-or-address class rests on 15 owner rulings, 1
  against it. Dates on the 82 against the owner's own Finder tags. No Gemini drafted or ruled.
- **Selection:** as W46.ent-score-paid (82 of the date-tagging sample's correspondence documents plus 56 chosen by
  ABBYY text cues, not by any route tested here). The rule's wording was written once, from the owner's definition,
  and not tuned on these replies; but the definition came from the owner's answers on 12 of these documents, and the
  prompt's rule and the truth's rule say the same thing, so the gain measures how well the model follows the
  definition, not a held-out accuracy. The 20 places of W46.place-rule-sheet were a seeded draw (seed 4651) from the
  pools `place_kind` defines, chosen by no route's reading.
- **Comparison:** each arm against its own baseline differs in the one place line: the same Vision text, first
  3,000 characters, context block, model, temperature 0, token cap and gateway (tagging-new and entity3k's cached
  replies, prompt-checked).
- **Noise:** n 138 (82 for the owner's dates, 40 per rerun floor, 12 and 8 for the owner's class check with Wilson
  intervals); paired document bootstrap, 2,000 draws, 95% intervals. Rerun floors on 40: full-string place -0.05, -0.02 and -0.03; by city 0.00, +0.03 and +0.03; dates 1-2
  of 40 documents, all estimated years.
- **Scope:** one model (Gemini 3.7 Flash), text only, correspondence documents only. It does not settle another
  model's reading of the rule (the app's other routes), non-correspondence documents (the tagging prompt runs on all,
  so its dates there are untested), whether "an address" pulls in a recipient's inside address (none of the 12 kept
  places the owner checked was one, which bounds it only loosely; the places wrong where one is written did not
  fall), or whether a letterhead place is where a letter was sent from (two of the owner's notes say a letterhead in
  view belonged to the sheet behind).
""".splitlines()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--arm", choices=("tagging", "entity"), required=True)
    r.add_argument("--rerun", action="store_true")
    sub.add_parser("report")
    a = ap.parse_args()
    os.makedirs(CACHE, exist_ok=True)
    {"run": cmd_run, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    main()
