#!/usr/bin/env python3
"""W46.ent-prompt-app: the app's tagging prompt with the entity rules W46.ent-score-paid found, scored as its fourth arm.

    python3 ent_prompt_app.py run [--limit N] [--rerun]   # the new prompt on the 138 (paid, capped)
    python3 ent_prompt_app.py report                      # segbench-results/ent-prompt-app.md and .json
    python3 ent_prompt_app.py stamp                       # record prompt hash and settings on old replies

What changed (TagGenerator.generateTags, mirrored verbatim in date_tagging.PROMPT): three rules. recipient_name takes
everyone it is addressed to, a person or a body, names joined by "; " (the scorer's ent_score.split_names splits
there, and TagGenerator.names joins a JSON array the same way); author_location is the letterhead's or dateline's city
as "City, State" with the state written out; author_name is always a person, null rather than the letterhead's
organisation (W46.ent-score-paid's organisation fallback made 15 of its 27 wrong senders). The rest of the prompt, the
year, month, day and date_uncertain rules included, is unchanged.

A first wording (V1_RULES, label "tagging-v1", kept in the report) asked for "every person it is addressed to" and
"City, State" with no more: it nulled 14 recipients that are bodies ("All Employees", a committee, a board), which the
truth names, and wrote the state abbreviated after the prompt's own "New York, NY" example where the truth spells it.

Arms. "tagging-new" is the new prompt exactly as ent_score_paid's "tagging" arm sent the old one: Gemini 3.7 Flash
through the Stanford gateway, text only, temperature 0, the first 3,000 characters of the same Vision text, and the
same nearby-documents context block. So the old "tagging" replies (ent_score_paid's cache, not re-called) and the new
ones differ in the three rules alone. --rerun repeats the new prompt on the first RERUN documents with one extra
newline (the gateway caches a byte-identical request), for a rerun floor on both the entities and the dates.

Entities: ent_truth.score_rows and ent_score_paid's paired bootstrap, unchanged, against the old tagging prompt and
the dedicated prompt (entity3k: the same 3,000 characters). Dates: the same call's year, month, day and
date_uncertain, parsed as TagGenerator parses them (date_tagging.app_parse); (1) how many of the 138 change between
the old and new prompt, beside how many change between the new prompt and its rerun; (2) on the 82 from the
date-tagging sample, each against the owner's own Finder date tags (date_tagging's truth). The date-tagging sample's
other documents are not rerun: date_tagging reads the ABBYY text layer, which no new arm takes as input (owner,
2026-10-30), and Vision text exists for the 138 only.

Spend goes to this item's own ledger (CACHE) under CAP; replies stay in the bench cache, the report has aggregates.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import date_tagging as DT  # noqa: E402
import ent_score_paid as P  # noqa: E402
import ent_truth as ET  # noqa: E402

CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/ent-prompt-app")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "ent-prompt-app.md")
CAP = 1.50                # this item's total, under the owner's $7 a piece of work
RERUN = 40
NEW = "tagging-new"
V1 = "tagging-v1"
V1_RULES = {
    "recipient_name": '- "recipient_name": every person it is addressed to (the inside address, a "To:" line, the '
                      'salutation), names separated by "; " (e.g. "Jane Doe; John Smith"), or null. Copies ("cc") are '
                      'not recipients',
    "author_location": '- "author_location": where it was written or sent from (the letterhead\'s or the dateline\'s '
                       'city), as "City, State" or "City, Country", or null',
}


def prompt_new(d):
    return DT.build_prompt(P.vision_text(d), P.context_of(d["prompt"]))


def prompt_v1(d):
    return P.with_rules(prompt_new(d), V1_RULES)


# The prompt each label's replies answered, for their hash (ent_score_paid.cached). The first wording's replies were
# made under the label tagging-new and moved to tagging-v1 when the second wording was run, so their meta still says
# "tagging-new"; their prompt is the new one with V1_RULES' two lines (the gateway's prompt tokens sit a constant 29
# under the new prompt's on all 138, and a rerun's a constant 1 over its arm's: the extra newline).
LABEL_PROMPT = {NEW: prompt_new, NEW + "-rerun": lambda d: prompt_new(d) + "\n",
                V1: prompt_v1, V1 + "-rerun": lambda d: prompt_v1(d) + "\n"}


def cmd_run(a):
    rs = P.rows()[: a.limit or None]
    label, tail = NEW, ""
    if a.rerun:
        rs, label, tail = P.rows()[:RERUN], NEW + "-rerun", "\n"
    with ThreadPoolExecutor(P.WORKERS) as ex:
        list(ex.map(lambda rd: P.call(label, rd[1]["id"], prompt_new(rd[1]) + tail, CACHE, CAP), rs))
    n = sum(os.path.exists(P.reply_path(label, d["id"], CACHE)) for _r, d in rs)
    print(f"{label}: {n}/{len(rs)} answered; ${P.spent(CACHE):.4f} spent of ${CAP}")


def cmd_stamp(a):
    labels = {label: LABEL_PROMPT.get(label) for label in P.replies_labels(CACHE)}
    print(json.dumps(P.stamp(labels, CACHE), indent=1))


# --- dates ------------------------------------------------------------------------------------------

def dates(label, cache):
    """{doc_id: (year, month, day, uncertain)} as the app keeps them, for the answered documents."""
    out = {}
    for _r, d in P.rows():
        p = P.reply_path(label, d["id"], cache)
        if not os.path.exists(p):
            continue
        raw = json.load(open(p)).get("raw") or ""
        y, m, du, _ok = DT.app_parse({"candidates": [{"content": {"parts": [{"text": raw}]}}]})
        js = P.parse(raw) or {}
        day = js.get("day")
        day = str(day).strip() if isinstance(day, (str, int)) and str(day).strip() else None
        digits = "".join(c for c in (day or "") if c.isdigit())
        out[d["id"]] = (y, m, int(digits) if digits else day, du)
    return out


def changed(a, b):
    ids = sorted(set(a) & set(b))
    per = {k: sum(a[i][j] != b[i][j] for i in ids) for j, k in enumerate(("year", "month", "day", "uncertain"))}
    return {"n": len(ids), "any": sum(a[i] != b[i] for i in ids), **per}


def against_owner(ds, truth):
    """Year right (a decade truth: the year in that decade), month right where the owner tagged one, a month given
    where the owner tagged none, and date_uncertain agreeing with the owner's Date Uncertain tag."""
    ids = sorted(set(ds) & set(truth))
    r = {"n": len(ids), "year_right": 0, "month_truth": 0, "month_right": 0, "month_untagged": 0,
         "month_given_untagged": 0, "du_agree": 0}
    for i in ids:
        y, m, _day, du = ds[i]
        t = truth[i]
        yi = int(y) if y and str(y).isdigit() else None
        if "year" in t:
            r["year_right"] += yi == t["year"]
        else:
            r["year_right"] += yi is not None and yi // 10 * 10 == t["decade"]
        if t.get("month"):
            r["month_truth"] += 1
            r["month_right"] += m == t["month"]
        else:
            r["month_untagged"] += 1
            r["month_given_untagged"] += m is not None
        r["du_agree"] += du == bool(t.get("du"))
    return r


def paired_rate(a, b, ids, fn):
    """b minus a in the share of ids where fn holds, with a document bootstrap's 95% interval."""
    xa = [fn(a[i], i) for i in ids]
    xb = [fn(b[i], i) for i in ids]
    d = (sum(xb) - sum(xa)) / len(ids)
    rng = random.Random(P.SEED)
    ds = sorted((sum(xb[j] - xa[j] for j in k) / len(ids)) for k in
                ([rng.randrange(len(ids)) for _ in ids] for _ in range(P.BOOT)))
    return {"n": len(ids), "diff": d, "lo": ds[int(0.025 * P.BOOT)], "hi": ds[int(0.975 * P.BOOT) - 1]}


# --- report -----------------------------------------------------------------------------------------

def cmd_report(a):
    import ent_score as ES
    import gateway_gemini as G
    rs = P.rows()
    truth = {r["id"]: r for r, _d in rs}
    texts = {d["id"]: P.vision_text(d) for _r, d in rs}
    for label in ("tagging", "entity3k"):
        P.check_replies(label, P.CACHE, lambda d, L=label: P.label_prompt(L, d))
    for label in (V1, NEW, NEW + "-rerun"):
        P.check_replies(label, CACHE, LABEL_PROMPT[label])
    A = {"tagging": P.preds("tagging"), "entity3k": P.preds("entity3k"), V1: P.preds(V1, CACHE),
         NEW: P.preds(NEW, CACHE), NEW + "-rerun": P.preds(NEW + "-rerun", CACHE)}
    arms = ("tagging", V1, NEW, "entity3k")
    pr = {k: v[0] for k, v in A.items()}
    s = {"docs": len(rs), "answered": {k: len(v[0]) for k, v in A.items()}, "unparsed": {k: v[1] for k, v in A.items()},
         "scores": {}, "paired": {}, "place_city": {}, "paired_city": {}}
    for arm in arms:
        s["scores"][arm] = ET.score_rows([{"truth": truth[i], "pred": p, "text": texts[i][:3000]}
                                          for i, p in pr[arm].items()])
    for a_, b_, what in (("tagging", NEW, "the three rules"), (V1, NEW, "the second wording"),
                         ("entity3k", NEW, "new tagging against dedicated"),
                         (NEW, NEW + "-rerun", "the same calls repeated")):
        ids = sorted(set(pr[a_]) & set(pr[b_]))
        s["paired"][f"{b_} vs {a_}"] = {"what": what, **{f: P.paired(pr[a_], pr[b_], ids, truth, f)
                                                          for f in ET.FIELDS}}
        pa, ta = P.by_city(pr[a_], truth)
        pb, _ = P.by_city(pr[b_], truth)
        s["paired_city"][f"{b_} vs {a_}"] = P.paired(pa, pb, ids, ta, "sending_place")
    for arm in arms:
        pc, tc = P.by_city(pr[arm], truth)
        c = [P.doc_counts(tc[i], pc[i], "sending_place") for i in pc]
        s["place_city"][arm] = P.f1(tuple(map(sum, zip(*c)))) or 0
    s["multi_recipient"] = {arm: sum(len(ET.ent_names(p.get("recipient"))) > 1 for p in pr[arm].values())
                            for arm in arms}
    s["recipients_named"] = {arm: sum(len(ET.ent_names(p.get("recipient"))) for p in pr[arm].values())
                             for arm in arms}
    # dates
    D = {"tagging": dates("tagging", P.CACHE), V1: dates(V1, CACHE), NEW: dates(NEW, CACHE),
         NEW + "-rerun": dates(NEW + "-rerun", CACHE)}
    sample = {json.loads(x)["id"]: json.loads(x)["truth"] for x in open(os.path.join(DT.CACHE, "sample.jsonl"))}
    owner = {i: t for i, t in sample.items() if i in truth}
    s["dates_changed"] = {"old vs new prompt": changed(D["tagging"], D[NEW]),
                          "old vs the first wording": changed(D["tagging"], D[V1]),
                          "old vs new, the rerun's 40": changed({i: D["tagging"][i] for i in D[NEW + "-rerun"]},
                                                                D[NEW]),
                          "new vs its rerun": changed(D[NEW], D[NEW + "-rerun"])}
    s["dates_owner"] = {arm: against_owner(D[arm], owner) for arm in ("tagging", V1, NEW)}
    ids = sorted(set(D["tagging"]) & set(D[NEW]) & set(owner))
    yr = lambda x, i: (int(x[0]) == owner[i]["year"]) if "year" in owner[i] and x[0] and str(x[0]).isdigit() else (  # noqa: E731
        bool(x[0] and str(x[0]).isdigit() and int(x[0]) // 10 * 10 == owner[i].get("decade")))
    mo = lambda x, i: x[1] == owner[i].get("month") if owner[i].get("month") else x[1] is None  # noqa: E731
    du = lambda x, i: x[3] == bool(owner[i].get("du"))  # noqa: E731
    s["dates_paired"] = {k: paired_rate(D["tagging"], D[NEW], ids, fn)
                         for k, fn in (("year right", yr), ("month right or rightly absent", mo),
                                       ("date uncertain agrees", du))}
    led = P.ledger(CACHE)
    s["calls"] = {"n": len(led), "ok": sum(r["http"] == 200 for r in led), "spent": round(P.spent(CACHE), 4),
                  "note": G.billed_note(led)}
    json.dump(s, open(RESULTS[:-3] + ".json", "w"), indent=1)
    open(RESULTS, "w").write(report(s, ES))
    print(RESULTS)


def report(s, ES):
    iv = lambda v: f"{v['diff']:+.3f} [{v['lo']:+.3f}, {v['hi']:+.3f}]"  # noqa: E731
    L = ["# The app's tagging prompt with the entity rules (W46.ent-prompt-app)", "",
         "Scored against W46.fix-ent-truth as built. W46.ent-truth-owner-fold (2026-11-05) restates these "
         "figures against the truth with the owner's answers and the sending-place rule (`ent-truth-owner.md`):"
         " the sending place moves most, since a place a route infers is now wrong when filled.", "",
         "Generated by `scripts/segbench/ent_prompt_app.py report`; method in its header. The same 138 correspondence "
         "documents, Vision text, model (Gemini 3.7 Flash, gateway) and scorer as W46.ent-score-paid "
         "(`ent-score-paid.md`); `tagging` is the prompt before this item, `tagging-new` after it.", "",
         "Answered / unparsed: " + ", ".join(f"{k} {s['answered'][k]}/{s['unparsed'][k]}" for k in s["answered"])
         + ".", "", "## Entities on all 138", ""]
    L += ES.score_table(s["scores"])
    L += ["", "Recipients named (documents with more than one): " + ", ".join(
        f"{k} {s['recipients_named'][k]} ({s['multi_recipient'][k]})" for k in s["recipients_named"]) + ".", "",
          "## Paired differences in ed2 F1 (95% bootstrap interval)", "",
          "| comparison | what changes | n | sender | recipient | sending place | place by city |",
          "|---|---|---|---|---|---|---|"]
    for k, v in s["paired"].items():
        L.append(f"| {k} | {v['what']} | {v['sender']['n']} | " + " | ".join(iv(v[f]) for f in ET.FIELDS)
                 + f" | {iv(s['paired_city'][k])} |")
    L += ["", "Place by city, ed2 F1: " + ", ".join(f"{k} {v:.3f}" for k, v in s["place_city"].items()) + ".", "",
          "## The dates the same call returns", "",
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
    L += ["", "| new minus old, share of the 82 | difference [95%] |", "|---|---|"]
    for k, v in s["dates_paired"].items():
        L.append(f"| {k} | {iv(v)} |")
    L += ["", f"Spend: ${s['calls']['spent']:.2f} estimated over {s['calls']['n']} gateway calls ({s['calls']['ok']} "
          f"answered). {s['calls']['note']}", ""]
    L += READING
    return "\n".join(L) + "\n"


READING = """## Reading

- **Recipients: most of the dedicated prompt's gain, in the app's own call.** ed2 F1 0.72 before, 0.82 after (+0.10,
  interval -0.02 to +0.26, so not yet a measured gain on 138), against the dedicated prompt's 0.87 (-0.05, a tie).
  Nulls where the truth names someone fall from 14 to 4 of 132, and the new prompt names 160 recipients to the old
  124 and the dedicated prompt's 168. The rerun did not move recipients at all. The first wording asked for "every
  person" and nulled the bodies a letter is addressed to ("All Employees", a committee, a board), which the truth
  names; "a person or a body" brought them back.
- **Sending place: the full string now matches the truth's form.** 0.62 before, 0.77 after (+0.15, interval +0.01 to
  +0.29); by the city alone every arm stays 0.90-0.92, a tie. Asking for "City, State" was not enough: the first
  wording followed the prompt's own "New York, NY" example and scored 0.59. Writing the state out (with an example)
  is what moved it. The rerun floor on the full string is -0.08 on 40, so the gain is about twice the floor.
- **Senders: fewer wrong, more left empty; F1 a tie.** 0.71 before, 0.73 after (+0.03, interval -0.02 to +0.07).
  Documents with a wrong sender fall from 16 to 6; documents left empty where the truth has a sender rise from 31 to
  41 of 129. That is the trade the rule asks for: a wrong
  name in the sidecar is worse than none. Against the dedicated prompt the new sender is better (+0.06, interval
  +0.02 to +0.10).
- **Dates do not move.** The year, month, day and date_uncertain the same call returns differ on 2 of the 138
  documents (one year, one day), where the new prompt's own rerun differs on 1 of 40. Against the owner's Finder date
  tags on the 82: year right 75 before and 74 after (-0.01, interval -0.04 to 0.00), months and Date Uncertain
  identical.

What it means for the app: the change ships in TagGenerator.generateTags. The sidecar's field shapes are unchanged
(recipient_name stays one string, several names joined by "; "; a JSON array is joined the same way). The shipped
rules are provisional: the processing review's Phase 4 decides the sender and place rules with the entity feature.
The sender rule (always a person, never the letterhead's organisation) is stricter than the truth it is scored
against, which takes an organisation where no person is named (`ent_truth.py`), and than the entity feature's design
(G-entities: a person or an organisation), so some of the new empty senders are senders the truth counts right; the
sender F1 is a tie.

## Measurement card

- **Truth:** W46.fix-ent-truth's 138 correspondence documents (model truth: GPT 5.6 Luna and Claude Sonnet 5 drafts,
  Sonnet rulings; the owner has not checked it). Dates on the 82 against the owner's own Finder tags. No Gemini
  drafted or ruled.
- **Selection:** as W46.ent-score-paid (82 of the date-tagging sample's correspondence documents plus 56 chosen by
  ABBYY text cues, not by any route tested here). The three rules were written after reading W46.ent-score-paid's
  misses on these same 138, and the second wording after reading the first wording's misses on them, so no new-prompt
  figure is held out: every gain against the old prompt, not only the second wording's over the first, is in-sample
  and partly fitted to this set.
- **Comparison:** the same Vision text, first 3,000 characters, context block, model, temperature 0 and gateway in
  every arm; old and new tagging prompts differ in three rules only.
- **Noise:** n 138 (82 for the owner's dates, 40 for the rerun floor); paired document bootstrap, 2,000 draws, 95%
  intervals. Rerun floor: sender 0.00, recipient 0.00, full-string place -0.08, city -0.03 (-0.100 to 0.000,
  one-signed: a drift between identical calls, not a floor around zero); dates 1 of 40 documents.
- **Scope:** one model (Gemini 3.7 Flash), text only, correspondence documents only. It does not settle another
  model's reading of the new rules (the app's other routes), the date-tagging sample's other documents (their text
  is ABBYY's, which no new arm reads), or non-correspondence documents, where author_name is now null rather than an
  issuing organisation.
""".splitlines()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--limit", type=int)
    r.add_argument("--rerun", action="store_true")
    sub.add_parser("report")
    sub.add_parser("stamp")
    a = ap.parse_args()
    os.makedirs(CACHE, exist_ok=True)
    {"run": cmd_run, "report": cmd_report, "stamp": cmd_stamp}[a.cmd](a)


if __name__ == "__main__":
    main()
