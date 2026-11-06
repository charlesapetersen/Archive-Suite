#!/usr/bin/env python3
"""W46.ent-truth-owner-fold: the owner's entity answers folded into W46.fix-ent-truth, and the sending-place rule.

    python3 ent_truth_owner.py fold      # ent-truth/owner-corrections.json (private), from the item-field sheet
    python3 ent_truth_owner.py report    # segbench-results/ent-truth-owner.md and .json: the restated scores

Where the answers come from. W47.item-fields-retruth's sheet (answered 2026-11-05) carried 20 entity controls: fields
where Claude Sonnet 5, adjudicating W46.fix-ent-truth, ruled for its own reader's draft. The sheet showed the two
readers' values (GPT 5.6 Luna's and Sonnet's) as options; the owner answered 17 and left notes on most documents. The
notes are read first and can override an answer, as for any owner sheet (root CLAUDE.md, 2026-11-05).

The fold, per asked field (`fold`): Sonnet's value picked, the truth is upheld; Luna's picked and empty, the field
is emptied (the owner: none given); Luna's picked and naming the same thing (the same city, or the same names at the
scorer's ed2), the truth stands with Luna's spelling added as an alternate, since the owner was choosing a form and
not a reading; Luna's picked and different, Luna's value is the truth. NOTE_RULINGS holds the notes that settle or
unsettle a field whatever the answer, each with its reason; an unsettled field is listed in the row's "unscored" and
left out of scoring, as W47.item-fields-retruth-score dropped the fields its notes left open. NOTE_CONFIRMS are notes
on other documents of the set that name the sender or recipient the truth already has (checked against the truth by
the session that wrote them, read off the notes, not the pages); they mark the field owner-checked and change nothing.

The rule (`ent_truth.place_rule`): of the 11 sending places the owner answered, he emptied 9, every one of them a
place not written in the document (inferred, or Stanford taken from "STANFORD UNIVERSITY"), and upheld the 2 that are
written (one a letterhead address); his note on a 12th says the place is not given in the text. So a sending place
is a place written in the document, in a dateline, a letterhead or an address, and the rule empties the truth's
inferred and institution-name places on the rest of the set. A letterhead place is not dropped: the owner upheld one,
and his note that a letterhead is not always where a letter was sent from is a caveat the text alone cannot act on
(the text cannot tell a printed letterhead from a typed address; `place_kind` counts where each place stands).

The report restates, against the truth as built, with the owner's answers, and with the rule as well, the sending
place (and the sender and recipient, which the fold also touches) of W46.ent-score (the app's cached tagging replies
on the 82 and the local extractors on the 138), W46.ent-score-paid (Gemini 3.7 Flash, tagging prompt and the
dedicated entity prompt, on the 138) and W46.ent-prompt-app (the tagging prompt's new rules). Cached replies only:
no model is called, nothing is spent. W46.ent-robust is not scored against this truth (its reference is each
extractor's own reply on the owner's 96 truth texts), so nothing of it moves.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ent_truth as ET  # noqa: E402

SHEET = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/item-fields-retruth/sheet")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "ent-truth-owner.md")

# (document, field): (action, reason). "set-signed" sets the name the note says the document is signed with.
NOTE_RULINGS = {
    ("7b697139c0117a16", "sending_place"): ("none", "unanswered; the note: where it was sent from is not given in "
                                                    "the text"),
    ("8abffb5b5485a158", "sender"): ("unscored", "unanswered; the note doubts where the sender's name comes from"),
    ("8f82ff7807211fb9", "sender"): ("unscored", "unanswered; the note: the sender is the name signed at the bottom, "
                                                 "not the letterhead's company, and neither option gave it"),
    ("b0e15214c84a6523", "sender"): ("set-signed", "unanswered; the note: signed with a first name only, the full "
                                                   "name not given and not to be inferred"),
    ("d9fef5f00c1f6bfa", "recipient"): ("confirm", "unanswered; the note confirms the truth's name"),
    ("d4513058634e3f33", "recipient"): ("unscored", "the answer took one reader's single name, the note names a "
                                                    "different addressee; unsettled"),
}
NOTE_CONFIRMS = {("7027e78edadc8045", "recipient"), ("ff1879de353d9f77", "sender"), ("ff1879de353d9f77", "recipient"),
                 ("3846b1232f5cff80", "sender"), ("3846b1232f5cff80", "recipient"), ("2a7dd985f800b3d2", "sender")}


def names(v):
    return [e["name"] for e in ET.ent_names(v)]


def same_thing(f, a, b):
    """Do two entity lists name the same things: by city for a sending place, else every name at ed2 both ways."""
    if f == "sending_place":
        a, b = [x.split(",")[0] for x in a], [x.split(",")[0] for x in b]
    return bool(a) and len(a) == len(b) and all(any(ET.match(x, y, "ed2") for y in b) for x in a) \
        and all(any(ET.match(y, x, "ed2") for x in a) for y in b)


def fold():
    key = json.load(open(os.path.join(SHEET, "key.json"), encoding="utf-8"))["items"]
    answers = json.load(open(os.path.join(SHEET, "answers.json"), encoding="utf-8"))
    truth = {r["id"]: r for r in ET.load_truth(owner=False, rule=False, correspondence=False)}
    text = {d["id"]: d["text"] for d in ET.load_docs()}
    docs = collections.defaultdict(dict)
    asked = []
    for n, k in sorted(key.items()):
        if k["part"] != "entity":
            continue
        d, f = k["doc"], k["field"]
        r, a = truth[d], answers.get(n)
        note = answers.get(f"_notes/{d}") or ""
        pick = k["options"][int(a) - 1] if a and a.isdigit() else None
        asked.append({"doc": d, "field": f, "answer": pick, "truth_class": [e["class"] for e in r[f]],
                      "place_kind": [ET.place_kind(e, text[d]) for e in r[f]] if f == "sending_place" else None})
        if (d, f) in NOTE_RULINGS:
            act, why = NOTE_RULINGS[(d, f)]
            if act == "none":
                docs[d][f] = {"action": "set", "value": [], "how": "note", "reason": why}
            elif act == "unscored":
                docs[d][f] = {"action": "unscored", "how": "note", "reason": why}
            elif act == "confirm":
                docs[d][f] = {"action": "confirm", "how": "note", "reason": why}
            elif act == "set-signed":
                m = re.search(r"\bsigned\s+([A-Z][a-z]+)", note)
                if not m:
                    raise SystemExit(f"{d} {f}: the note no longer names the signature")
                nm = m.group(1)
                q = nm if re.search(rf"\b{nm}\b", text[d]) else None
                docs[d][f] = {"action": "set", "value": [{"name": nm, "quote": q, "class": "named"}], "how": "note",
                              "reason": why}
            asked[-1]["ruling"] = {"none": "none given", "confirm": "upheld", "unscored": "unscored",
                                   "set-signed": "another name"}[act]
            asked[-1]["by"] = "note"
            continue
        if pick is None:
            asked[-1]["ruling"] = "open"
            continue
        if pick == "claude":
            docs[d][f] = {"action": "confirm", "how": "sheet answer", "pick": pick}
            asked[-1]["ruling"] = "upheld"
            continue
        lv = r["readers"]["luna"].get(f) or []
        if not names(lv):
            docs[d][f] = {"action": "set", "value": [], "how": "sheet answer", "pick": pick}
            asked[-1]["ruling"] = "none given"
        elif same_thing(f, names(lv), names(r[f])):
            docs[d][f] = {"action": "confirm", "how": "sheet answer", "pick": pick, "alternates": names(lv)}
            asked[-1]["ruling"] = "upheld, another spelling"
        else:
            docs[d][f] = {"action": "set", "value": [{"name": e["name"], "quote": e.get("quote"),
                                                      "class": e.get("class", "named")} for e in lv],
                          "how": "sheet answer", "pick": pick}
            asked[-1]["ruling"] = "another name"
    for d, f in sorted(NOTE_CONFIRMS):
        if f in docs[d]:
            continue
        if not truth[d][f]:
            raise SystemExit(f"{d} {f}: a note confirms a field the truth has empty")
        docs[d][f] = {"action": "confirm", "how": "note", "reason": "a note on the document names the same"}
    return {"_about": "W46.ent-truth-owner-fold: the owner's answers and notes on W47.item-fields-retruth's sheet, "
                      "applied by ent_truth.load_truth. Private (the owner's material).",
            "docs": dict(docs), "asked": asked}


def cmd_fold(_a):
    c = fold()
    tmp = ET.OWNER_CORRECTIONS + ".tmp"
    json.dump(c, open(tmp, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    os.replace(tmp, ET.OWNER_CORRECTIONS)
    print(ET.OWNER_CORRECTIONS, collections.Counter(x["ruling"] for x in c["asked"]))


# --- the restatement -----------------------------------------------------------------------------------------------

TRUTHS = ("built", "owner", "owner+rule")
RULINGS = ("upheld", "upheld, another spelling", "none given", "another name", "unscored", "open")


def truths():
    return {"built": ET.load_truth(owner=False, rule=False), "owner": ET.load_truth(rule=False),
            "owner+rule": ET.load_truth()}


def arms():
    """{arm: (source report, {doc_id: pred})}: every cached reply set the W46 entity reports scored on this truth."""
    import ent_prompt_app as EPA
    import ent_score as ES
    import ent_score_paid as P
    out = {}
    for m, got in ES.reply_preds().items():
        out[f"{m} tagging reply, ABBYY (82)"] = ("ent-score", {i: p for i, p in got.items() if p is not None})
    for name in ES.LOCAL:
        p = ES.load_preds(name)
        if p is None:
            raise SystemExit(f"missing ent-score run {name}")
        out[f"{name} (138)"] = ("ent-score", {i: x["pred"] for i, x in p.items()})
    for arm in ("tagging", "entity3k", "entity8k", "entity8k-rerun"):
        P.check_replies(arm, P.CACHE, lambda d, L=arm: P.label_prompt(L, d))
        out[f"gemini-3.7 {arm}, Vision"] = ("ent-score-paid", P.preds(arm)[0])
    for label in (EPA.V1, EPA.NEW, EPA.NEW + "-rerun"):
        P.check_replies(label, EPA.CACHE, EPA.LABEL_PROMPT[label])
        out[f"gemini-3.7 {label}, Vision"] = ("ent-prompt-app", P.preds(label, EPA.CACHE)[0])
    return out


def scores(pred, truth):
    """Per field: ed2 precision, recall, F1, wrong-when-filled documents, filled-when-empty; and the place by city."""
    import ent_score_paid as P
    ids = [i for i in pred if i in truth]
    s = ET.score_rows([{"truth": truth[i], "pred": pred[i] or {}, "text": ""} for i in ids], levels=("ed2",))
    out = {f: {k: s[f]["ed2"][k] for k in ("precision", "recall", "f1", "tp", "fp", "fn", "wrong_when_filled_docs")}
           | {"filled_when_empty": s[f]["filled_when_empty"], "truth_nonempty": s[f]["truth_nonempty"],
              "docs": s[f]["docs"]} for f in ET.FIELDS}
    pc, tc = P.by_city({i: pred[i] for i in ids}, {i: truth[i] for i in ids})
    c = [P.doc_counts(tc[i], pc[i], "sending_place") for i in ids if "sending_place" not in truth[i].get("unscored", [])]
    tot = tuple(map(sum, zip(*c))) if c else (0, 0, 0)
    out["city"] = {"tp": tot[0], "fp": tot[1], "fn": tot[2], "f1": P.f1(tot),
                   "precision": tot[0] / (tot[0] + tot[1]) if tot[0] + tot[1] else None}
    out["n"] = len(ids)
    return out


def paired_city(pa, pb, truth):
    import ent_score_paid as P
    ids = sorted(set(pa) & set(pb) & set(truth))
    a, ta = P.by_city({i: pa[i] for i in ids}, {i: truth[i] for i in ids})
    b, _ = P.by_city({i: pb[i] for i in ids}, {i: truth[i] for i in ids})
    full = P.paired(pa, pb, ids, truth, "sending_place")
    return {"full": full, "city": P.paired(a, b, ids, ta, "sending_place")}


def cmd_report(_a):
    T = truths()
    by = {k: {r["id"]: r for r in v} for k, v in T.items()}
    text = {d["id"]: d["text"] for d in ET.load_docs()}
    corr = json.load(open(ET.OWNER_CORRECTIONS, encoding="utf-8"))
    s = {"documents": len(T["built"]), "asked": collections.Counter(), "rulings": {}, "place_kinds": {},
         "asked_place_kinds": {}, "truth_places": {}, "scores": {}, "paired": {}}
    rul = collections.defaultdict(collections.Counter)
    for x in corr["asked"]:
        rul[x["field"]][x["ruling"]] += 1
        if x["field"] == "sending_place":
            for k in x["place_kind"] or ["(empty)"]:
                s["asked_place_kinds"].setdefault(k, collections.Counter())[x["ruling"]] += 1
    s["rulings"] = {f: dict(c) for f, c in rul.items()}
    s["asked_place_kinds"] = {k: dict(v) for k, v in s["asked_place_kinds"].items()}
    s["corrections"] = {"documents": len(corr["docs"]),
                        "fields": dict(collections.Counter(f"{x['action']} ({x['how']})" for d in corr["docs"].values()
                                                           for x in d.values()))}
    kinds = collections.Counter(ET.place_kind(e, text[r["id"]]) for r in T["built"] for e in r["sending_place"])
    s["place_kinds"] = {k: kinds.get(k, 0) for k in ET.PLACE_KINDS}
    kept = collections.Counter(ET.place_kind(e, text[r["id"]]) for r in T["owner+rule"] for e in r["sending_place"])
    s["kept_place_kinds"] = {k: kept.get(k, 0) for k in ET.PLACE_KINDS}
    for k, rows in T.items():
        s["truth_places"][k] = {"documents with a place": sum(bool(r["sending_place"]) for r in rows),
                                "named places": sum(e["class"] == "named" for r in rows for e in r["sending_place"]),
                                "inferred places": sum(e["class"] != "named" for r in rows for e in r["sending_place"]),
                                "unscored fields": sum(len(r.get("unscored", [])) for r in rows)}
    s["rule_dropped_documents"] = sum(bool(r.get("place_rule_dropped")) for r in T["owner+rule"])
    A = arms()
    s["sources"] = {a: src for a, (src, _p) in A.items()}
    for a, (_src, pr) in A.items():
        s["scores"][a] = {k: scores(pr, by[k]) for k in TRUTHS}
    P_ = {a: p for a, (_s, p) in A.items()}
    for name, a_, b_ in (("entity3k vs tagging", "gemini-3.7 tagging, Vision", "gemini-3.7 entity3k, Vision"),
                         ("tagging-new vs tagging", "gemini-3.7 tagging, Vision", "gemini-3.7 tagging-new, Vision"),
                         ("rerun floor: entity8k again", "gemini-3.7 entity8k, Vision",
                          "gemini-3.7 entity8k-rerun, Vision"),
                         ("rerun floor: tagging-new again", "gemini-3.7 tagging-new, Vision",
                          "gemini-3.7 tagging-new-rerun, Vision")):
        s["paired"][name] = {k: paired_city(P_[a_], P_[b_], by[k]) for k in ("built", "owner+rule")}
    s["asked"] = dict(collections.Counter(x["field"] for x in corr["asked"]))
    json.dump(s, open(RESULTS[:-3] + ".json", "w"), indent=1)
    open(RESULTS, "w").write(report(s))
    print(RESULTS)


def f3(x):
    return "–" if x is None else f"{x:.2f}"


def report(s):
    R = s["rulings"]
    L = ["# The entity truth with the owner's answers, and the sending-place rule (W46.ent-truth-owner-fold)", "",
         "Generated by `scripts/segbench/ent_truth_owner.py report`; method in its header. Counts only: the truth and "
         "the corrections stay in the bench cache (`ent-truth/truth.jsonl`, `ent-truth/owner-corrections.json`). "
         "`ent_truth.load_truth()` gives the truth as it now stands (the owner's answers and the rule); "
         "`load_truth(owner=False, rule=False)` gives it as W46.fix-ent-truth built it. Offline: cached replies "
         "only, no model called, $0.", "",
         "## The owner's answers", "",
         f"W47.item-fields-retruth's sheet asked {sum(s['asked'].values())} entity fields where Claude Sonnet 5 had "
         "ruled for its own reader's draft. What each came to, notes read first:", "",
         "| field | " + " | ".join(RULINGS) + " |",
         "|---|---|---|---|---|---|---|"]
    for f in ET.FIELDS:
        c = R.get(f, {})
        L.append(f"| {f} | " + " | ".join(str(c.get(k, 0)) for k in RULINGS) + " |")
    L += ["", "\"Upheld\" counts a note that confirms the name; \"another name\" counts the one note that gives the "
          "name the document is signed with, which neither option had, as well as an answer taking reader A's different name. An unscored field is one whose note leaves it "
          "unsettled (an answer and a note that disagree, or a note doubting the name); it is left out of every "
          "score below. Of the 11 sending places answered, W47.item-fields-score.md counts 0 upheld; 2 of its 11 "
          "\"Luna's\" are the same city in Luna's spelling (\"Philadelphia, PA\", \"St. Paul\"), so the place stood "
          f"on 2 and was emptied on 9; a note empties one more.", "",
          f"The corrections file covers {s['corrections']['documents']} documents: " +
          ", ".join(f"{k} {v}" for k, v in sorted(s['corrections']['fields'].items())) + " (six of the confirmations "
          "are notes on other documents of the set that name the sender or recipient the truth already has).", "",
          "## Where the truth's sending places stand", "",
          "Each of the truth's sending places as W46.fix-ent-truth built it, by its class, its quote and the quote's "
          "line in the OCR text (`ent_truth.place_kind`). The text cannot tell a printed letterhead from a typed "
          "address, so they share a row.", "",
          "| where the place stands | places | of them asked: upheld / emptied |", "|---|---|---|"]
    ak = s["asked_place_kinds"]
    for k, v in s["place_kinds"].items():
        a = ak.get(k, {})
        up = a.get("upheld", 0) + a.get("upheld, another spelling", 0)
        em = a.get("none given", 0)
        L.append(f"| {k} | {v} | {up} / {em} |" if a else f"| {k} | {v} | – |")
    tot = sum(s["place_kinds"].values())
    hd = s["place_kinds"]["heading or address"] + s["place_kinds"]["line above a date"]
    ak_inf = ak.get("inferred", {}).get("none given", 0)
    ak_inst = ak.get("institution name", {}).get("none given", 0)
    ak_hd = sum(ak.get("heading or address", {}).values())
    ak_hd_up = sum(v for k, v in ak.get("heading or address", {}).items() if k.startswith("upheld"))
    hd_kept = s["kept_place_kinds"]["heading or address"]
    owner_rule_named = sum(s["kept_place_kinds"].values())
    L += ["", f"So of the {tot} places, {s['place_kinds']['dateline']} sit on a line with a date; {hd} sit in a "
          "heading or address block (a letterhead or a typed address; that many is the most a letterhead place "
          f"can stand for the sending place in this truth); {s['place_kinds']['read in an image']} were read in an "
          f"image only; and {s['place_kinds']['inferred'] + s['place_kinds']['institution name']} are not written "
          "as a place at all (inferred from the collection or content, or a town taken from an institution's name).",
          "", "## The rule", "",
          f"The owner emptied all {ak_inf} inferred places he was asked and the {ak_inst} taken from an "
          f"institution's name; of the {ak_hd} heading-or-address places asked, he upheld {ak_hd_up} (one in a "
          f"letterhead address) and emptied {ak_hd - ak_hd_up}, his note saying the place is not given in the text. So "
          "the emptied class (inferred places) is supported by his answers, and the kept heading-or-address class, "
          f"which holds {hd_kept} of the {owner_rule_named} places the truth now keeps, rests on {ak_hd} rulings, 1 "
          "of them against it (W46.place-rule-sheet checks it). The "
          "sending place is a place the document writes, in a dateline, a letterhead or an address, and never one "
          "inferred from the collection, the content or an institution's name (`ent_truth.place_rule`). A letterhead "
          "place stays: the owner upheld one, and his note that a letterhead is not always where a letter was sent "
          "from is a caveat with no rule the text can apply. The definition the truth was drafted with "
          "(`ent_truth.PROMPT`: \"the dateline's place, or the letterhead address\") already asked for a written "
          "place; what changes is that its inferred classes no longer count, so a route that fills one is wrong "
          "when filled, where before it was set aside.", "",
          "| truth | documents with a place | named places | inferred places | unscored fields |", "|---|---|---|---|---|"]
    for k, v in s["truth_places"].items():
        L.append(f"| {k} | {v['documents with a place']} | {v['named places']} | {v['inferred places']} | "
                 f"{v['unscored fields']} |")
    L += ["", f"The rule empties or trims the place on {s['rule_dropped_documents']} documents the owner did not "
          "answer.", "", "## The W46 entity scores restated", "",
          "Sending place, ed2 on the full string (P / R / F1) and by its city (F1, as the reports' place figures), "
          "against the truth as built, with the owner's answers, and with the rule as well. \"Filled, no place\" is "
          "the documents where the route names a place and the truth has none.", "",
          "| route (report) | n | built: P / R / F1 · city | owner: F1 · city | owner+rule: P / R / F1 · city | "
          "filled, no place: built → owner+rule |", "|---|---|---|---|---|---|"]
    for a, sc in s["scores"].items():
        b, o, r = sc["built"], sc["owner"], sc["owner+rule"]
        L.append(f"| {a} ({s['sources'][a]}) | {b['n']} | {f3(b['sending_place']['precision'])} / "
                 f"{f3(b['sending_place']['recall'])} / {f3(b['sending_place']['f1'])} · {f3(b['city']['f1'])} | "
                 f"{f3(o['sending_place']['f1'])} · {f3(o['city']['f1'])} | {f3(r['sending_place']['precision'])} / "
                 f"{f3(r['sending_place']['recall'])} / {f3(r['sending_place']['f1'])} · {f3(r['city']['f1'])} | "
                 f"{b['sending_place']['filled_when_empty']} → {r['sending_place']['filled_when_empty']} |")
    L += ["", "Sender and recipient, ed2 F1, built → with the owner's answers (the rule touches only the place):", "",
          "| route | sender | recipient |", "|---|---|---|"]
    for a, sc in s["scores"].items():
        b, o = sc["built"], sc["owner+rule"]
        L.append(f"| {a} | {f3(b['sender']['f1'])} → {f3(o['sender']['f1'])} | "
                 f"{f3(b['recipient']['f1'])} → {f3(o['recipient']['f1'])} |")
    L += ["", "Paired differences in sending-place F1 (b minus a, document bootstrap 95%, ent_score_paid.paired), "
          "built and now:", "", "| comparison | n | full string, built | full string, now | city, built | city, now |",
          "|---|---|---|---|---|---|"]
    fmt = lambda p: f"{p['diff']:+.2f} [{p['lo']:+.2f}, {p['hi']:+.2f}]"  # noqa: E731
    for k, v in s["paired"].items():
        L.append(f"| {k} | {v['owner+rule']['full']['n']} | {fmt(v['built']['full'])} | "
                 f"{fmt(v['owner+rule']['full'])} | {fmt(v['built']['city'])} | {fmt(v['owner+rule']['city'])} |")
    L += ["", "W46.ent-robust is not restated: it scores each route's reply against the same extractor's reply on the "
          "owner's 96 truth texts, not against this truth.", "",
          "## Measurement card", "",
          "- **Truth.** W46.fix-ent-truth (GPT 5.6 Luna and Claude Sonnet 5 drafts, Sonnet adjudicating), with the "
          "owner's answers on the 23 fields his sheet asked (all of them fields Sonnet ruled for its own reader) and "
          "six confirming notes. The rest of the set has no owner check; the 20 documents asked (23 fields) were "
          "chosen as Sonnet's self-rulings, so they say how far to trust those, not the agreed rows. "
          + ET.SELF_RULINGS + " No scored route drafted the truth.",
          "- **Selection.** The 138 correspondence documents and the reports' own subsets (the 82 with cached "
          "tagging replies); nothing chosen by a scored route. The set itself was chosen by ABBYY text: its 56 "
          "additions came from the agreed, year-tagged pool with ABBYY text, as the date-tagging sample's letters "
          "did (`ent-truth.md`), so undated documents and documents without ABBYY text are not in it. The sheet's entity controls were drawn by the "
          "adjudicator's side, not by a route.",
          "- **Comparison.** Each route's cached replies exactly as its report scored them; only the truth changes. "
          "ent-score's tagging replies read ABBYY text (scored before the owner's 2026-10-30 rule; no new ABBYY arm "
          "is run here); the Gemini 3.7 arms read Apple Vision text.",
          "- **Noise.** Paired bootstrap intervals above, beside each prompt's rerun floor. A difference inside its "
          "interval, or inside the rerun floor, is a tie.",
          "- **Scope.** The rule rests on 12 owner rulings on places and on `place_kind`, a text heuristic that "
          "cannot tell a letterhead from a typed address or check a place against the image; its dateline count is "
          "low because the OCR often puts the date on its own line. Whether a letterhead place should count when "
          "nothing else names the place is the owner's caveat and is not tested; the kept heading-or-address class "
          "is checked by the owner on 3 places (W46.place-rule-sheet and W46.place-rule-fold check it on more). "
          "The app's tagging prompt carries the rule since 4374254d (W46.ent-place-rule-paid, `ent-place-rule.md`); "
          "the dedicated entity prompt with the rule tied and was left unchanged.", ""]
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("fold").set_defaults(fn=cmd_fold)
    sub.add_parser("report").set_defaults(fn=cmd_report)
    a = ap.parse_args()
    os.chdir(HERE)
    a.fn(a)


if __name__ == "__main__":
    main()
