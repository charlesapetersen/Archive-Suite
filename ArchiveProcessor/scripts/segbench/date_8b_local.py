#!/usr/bin/env python3
"""W46.date-8b-local-baseline: the Mac 8B's cached image quotes on the actual no-key laptop route (08-dating.md call 7.5).

Option (a), the route the owner chose for the laptop without a key: Apple Vision text, the rules, the 2B chooser where
the rule is ambiguous, and propagation at t=3 from the nearest earlier document whose text prints a date, every
propagated year with Date Uncertain; no residue stage, so a document propagation does not reach gets no year.
Option (c) adds the Qwen3-VL 8B image pass (MLX, 1,400 px) as step 2 on a document whose own text gives no year
candidate, ahead of propagation, its year explicit (no Date Uncertain), as date_route_pipeline.route orders step 2.
Two readings of the 8B reply, both cached by W46.date-route-pipeline-8b: "strict" takes its own document year only
when that year is written in a date it quoted (date_undated.own_date); "quote source" takes that, else the one year
its quoted dates name when they name exactly one (date_route_pipeline.quote_year).

Inputs are date_route_pipeline's: the owner's 300 and the undated 90, their Vision text read from confirmed JPEG
originals on macOS 27.2, the neighbours' text the same way. No ABBYY text is an input. The two options differ only on
documents whose own Vision text has no rule candidate; the 2B chooser acts only where a candidate exists, so it is the
same in both and cancels from every paired figure. Its cached replies were made on prompts built from the corpus (ABBYY)
text, which do not match these inputs, so they are not reused, and no 2B run is needed for the comparison: on documents
with a candidate both options are reported as the rule pick, labelled as such.

Truth: the owner's date tags on the 300. False years on the undated 90: the owner's ruling where he ruled (20), else
the Gemini 3.7 image pass's reading of the page (model-scored, reported apart), date_route_pipeline.undated_summary.

    python3 date_8b_local.py        # segbench-results/date-8b-local.md and .json; $0, reads caches only, no model run
Run from scripts/segbench.
"""
from __future__ import annotations

import collections
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import date_route_pipeline as R
import date_traceable as T
import date_undated as DU

RESULTS = HERE.parent.parent / "segbench-results" / "date-8b-local.md"
RESULTS_JSON = RESULTS.with_suffix(".json")
THRESHOLD = 3
ARMS = ("a", "c_strict", "c_quote")
ARM_NAMES = {"a": "(a) Vision, rules, propagation t=3", "c_strict": "(c) + 8B own date (strict)",
             "c_quote": "(c) + 8B quote source"}


def route_a(doc, cands):
    """(year, du, cls) under option (a), the chooser left at the rule pick (see the module note)."""
    if cands:
        y = T.rule_pick(cands)[0]
        return y, y is None, "text" if y is not None else "none"
    py, dist, _ = T.propagate(doc)
    if py is not None and dist <= THRESHOLD:
        return py, True, "estimate"
    return None, True, "none"


def rows(ts, gem_image):
    out, missing8 = [], []
    for d in ts:
        if not R.readable(d):
            continue
        doc = R.doc_of(d)
        cands = T.candidates(doc["text"])
        a = route_a(doc, cands)
        rec = None if cands else R.mac8_image(d)
        if not cands and rec is None:
            missing8.append(d["id"])
        strict = DU.own_date(rec)[1] if rec is not None else None
        quote = R.quote_year(rec) if rec is not None else None
        truth = d.get("truth") or {}
        r = {"id": d["id"], "set": d["set"], "has_candidate": bool(cands), "truth_y": truth.get("year"),
             "truth_du": truth.get("du"), "eight_b_reply": rec is not None, "strict_y": strict, "quote_y": quote,
             "propagated": a[2] == "estimate"}
        for arm, y8 in (("a", None), ("c_strict", strict), ("c_quote", quote)):
            y, du, cls = (y8, False, "image") if y8 is not None else a
            r[arm] = {"year": y, "du": du, "cls": cls}
        if d["set"] == "undated":
            g = gem_image.get(d["id"])
            r["page_own"] = DU.own_date(g)[1] if g is not None else None
        out.append(r)
    return out, missing8


def flat(rs, arm):
    return [{**r, **r[arm]} for r in rs]


def counts(rs, arm):
    """Exact, wrong unflagged, wrong flagged and no year, owner documents with a year."""
    g = [r[arm] | {"t": r["truth_y"]} for r in rs]
    return {"n": len(g), "exact": R.frac(sum(x["year"] == x["t"] for x in g), len(g)),
            "wrong_explicit": sum(x["year"] is not None and x["year"] != x["t"] and not x["du"] for x in g),
            "wrong_flagged": sum(x["year"] is not None and x["year"] != x["t"] and x["du"] for x in g),
            "no_year": sum(x["year"] is None for x in g)}


def paired(rs, arm):
    # R.paired names its first arm a_* and its second b_*; here the first is the 8B arm (c) and the second option (a),
    # so the keys are renamed for what they hold (P16-9: `a_*` read as option (a), the opposite of what it held).
    q = R.paired([{"truth_y": r["truth_y"], "x": r[arm]["year"], "a": r["a"]["year"]} for r in rs], "x", "a")
    p = {"n": q["n"], "arm_exact": q["a_exact"], "option_a_exact": q["b_exact"], "gains": q["a_only"],
         "losses": q["b_only"], "sign_p": q["sign_p"]}
    changed = [r for r in rs if r[arm]["year"] != r["a"]["year"]]
    p["changed"] = len(changed)
    p["wrong_to_wrong"] = sum(r[arm]["year"] != r["truth_y"] and r["a"]["year"] != r["truth_y"] for r in changed)
    p["none_to_wrong"] = sum(r["a"]["year"] is None and r[arm]["year"] != r["truth_y"] for r in changed)
    p["flagged_right_to_explicit_right"] = sum(r["a"]["year"] == r["truth_y"] == r[arm]["year"] and r["a"]["du"]
                                               and not r[arm]["du"] for r in rs)
    return p


def score():
    ts = R.targets()
    gem_image = {d["id"]: R.load(R.image_dest(d)) for d in ts}
    rs, missing8 = rows(ts, gem_image)
    owner = [r for r in rs if r["set"] == "owner" and r["truth_y"] is not None]
    nc = [r for r in owner if not r["has_candidate"]]
    strata = {
        "8B quotes a year, propagation reaches": lambda r: r["quote_y"] is not None and r["propagated"],
        "8B quotes a year, propagation does not reach": lambda r: r["quote_y"] is not None and not r["propagated"],
        "8B quotes no year, propagation reaches": lambda r: r["quote_y"] is None and r["propagated"],
        "8B quotes no year, propagation does not reach": lambda r: r["quote_y"] is None and not r["propagated"],
    }
    out = {"sets": dict(collections.Counter(r["set"] for r in rs)), "threshold": THRESHOLD,
           "owner_scored": len(owner), "owner_no_candidate": len(nc),
           "owner_with_candidate": len(owner) - len(nc), "missing_8b": missing8,
           "eight_b_replies_no_candidate": sum(r["eight_b_reply"] for r in rs if not r["has_candidate"]),
           "no_candidate_all": sum(not r["has_candidate"] for r in rs),
           "arms": {}, "strata": {}}
    for arm in ARMS:
        A = {"no_candidate": counts(nc, arm), "all_owner": counts(owner, arm),
             "du_vs_owner": {
                 "certain_flagged": R.frac(sum(r[arm]["du"] for r in owner if r["truth_du"] is False
                                               and r[arm]["year"] is not None),
                                           sum(1 for r in owner if r["truth_du"] is False and r[arm]["year"] is not None)),
                 "uncertain_unflagged": R.frac(sum(not r[arm]["du"] for r in owner if r["truth_du"] is True
                                                   and r[arm]["year"] is not None),
                                               sum(1 for r in owner if r["truth_du"] is True
                                                   and r[arm]["year"] is not None))},
             "undated": R.undated_summary(flat([r for r in rs if r["set"] == "undated"], arm))}
        if arm != "a":
            A["paired_no_candidate"] = paired(nc, arm)
            A["image_years"] = {"n": sum(r[arm]["cls"] == "image" for r in nc),
                                "right": sum(r[arm]["cls"] == "image" and r[arm]["year"] == r["truth_y"] for r in nc)}
        out["arms"][arm] = A
    for name, f in strata.items():
        g = [r for r in nc if f(r)]
        out["strata"][name] = {"n": len(g), **{arm: sum(r[arm]["year"] == r["truth_y"] for r in g) for arm in ARMS}}
    out["changed_documents"] = [
        {"id": r["id"], "truth": r["truth_y"], "a": r["a"]["year"], "a_du": r["a"]["du"], "strict": r["strict_y"],
         "quote": r["quote_y"]}
        for r in nc if r["quote_y"] is not None and r["quote_y"] != r["a"]["year"]]
    q = out["arms"]["c_quote"]["paired_no_candidate"]
    s = out["arms"]["c_strict"]["paired_no_candidate"]
    out["condition_met"] = q["gains"] > q["losses"] and q["sign_p"] < 0.05 or (
        s["gains"] > s["losses"] and s["sign_p"] < 0.05)
    return out


def pc(f):
    return f"{f['pct']:.1f}% ({f['k']}/{f['n']}; {f['ci'][0]:.0f}-{f['ci'][1]:.0f})" if f and f["n"] else "–"


def write_md(o):
    A = o["arms"]
    L = ["# The Mac 8B's image quotes on the actual no-key laptop route (W46.date-8b-local-baseline)", "",
         "Measurement review pass 15, P15-3: 08-dating.md call 7.5 adds the Qwen3-VL 8B image pass at 16 GB, option (c), "
         "to option (a) once its quotes improve the year. W46.date-route-pipeline-8b paired the 8B only with the Gemini "
         "and 27B trace replies; this pairs the same cached 8B replies with option (a) itself: Vision text, rules, the "
         "2B chooser and propagation at t=3. $0: cached replies only, no model run, no upload, no ABBYY input. Script: "
         "`ArchiveProcessor/scripts/segbench/date_8b_local.py`.", "",
         "## Verdict", ""]
    q, s = A["c_quote"]["paired_no_candidate"], A["c_strict"]["paired_no_candidate"]
    verdict = ("met" if o["condition_met"] else "not met")
    L += [f"The owner's condition (the 8B's quotes improve the year on the route) is **{verdict}**. On the "
          f"{o['owner_no_candidate']} owner documents whose own Vision text gives no year candidate, the only documents "
          f"where (a) and (c) can differ, the quote-source reading gains {q['gains']} and loses {q['losses']} "
          f"(exact sign test p {q['sign_p']}); the strict reading gains {s['gains']} and loses {s['losses']} "
          f"(p {s['sign_p']}). " + (
              "No image route is added: the 16 GB route stays (a) and `qwen3-vl-8b-image-mac` stays unoffered."
              if not o["condition_met"] else "The gain clears the sign test; call 7.5 (c) may be added."), "",
          "## Results", "",
          f"Documents readable from JPEG originals: {o['sets'].get('owner', 0)} owner, {o['sets'].get('undated', 0)} undated; {o['owner_scored']} owner documents with a year tag, "
          f"{o['owner_no_candidate']} of them with no rule candidate in their own Vision text and "
          f"{o['owner_with_candidate']} with one. The 8B reply is cached for {o['eight_b_replies_no_candidate']} of "
          f"the {o['no_candidate_all']} no-candidate documents across both sets"
          + (f"; missing for {len(o['missing_8b'])}: {', '.join(o['missing_8b'])}" if o["missing_8b"] else "; none missing")
          + ".", "",
          "| arm | no-candidate exact | wrong, explicit | wrong, Date Uncertain | no year | all owner exact |",
          "|---|---|---|---|---|---|"]
    for arm in ARMS:
        n, a = A[arm]["no_candidate"], A[arm]["all_owner"]
        L.append(f"| {ARM_NAMES[arm]} | {pc(n['exact'])} | {n['wrong_explicit']} | {n['wrong_flagged']} | "
                 f"{n['no_year']} | {pc(a['exact'])} |")
    L += ["", "All-owner figures leave the rule pick standing where a candidate exists (the 2B chooser not run, see "
          "Measurement card); they are identical in the three arms there, so they serve only as context.", "",
          "Paired against (a) on the no-candidate owner documents:", "",
          "| arm | image years (right) | gains | losses | sign p | changed | wrong to another wrong | none to wrong | "
          "flagged right made explicit |", "|---|---|---|---|---|---|---|---|---|"]
    for arm in ARMS[1:]:
        p, im = A[arm]["paired_no_candidate"], A[arm]["image_years"]
        L.append(f"| {ARM_NAMES[arm]} | {im['n']} ({im['right']}) | {p['gains']} | {p['losses']} | {p['sign_p']} | "
                 f"{p['changed']} | {p['wrong_to_wrong']} | {p['none_to_wrong']} | "
                 f"{p['flagged_right_to_explicit_right']} |")
    L += ["", "Strata, named for this comparison (whether the 8B quotes a year; whether propagation reaches within "
          "t=3), exact years per arm:", "", "| stratum | n | (a) | strict | quote source |", "|---|---|---|---|---|"]
    for name, g in o["strata"].items():
        L.append(f"| {name} | {g['n']} | {g['a']} | {g['c_strict']} | {g['c_quote']} |")
    L += ["", "Documents where the quote-source year differs from (a)'s:", "",
          "| document | owner year | (a) | (a) flagged | 8B strict | 8B quote source |", "|---|---|---|---|---|---|"]
    for c in o["changed_documents"]:
        L.append(f"| {c['id']} | {c['truth']} | {c['a']} | {'yes' if c['a_du'] else 'no'} | {c['strict']} | {c['quote']} |")
    L += ["", "False years on the undated 90 (a year written without Date Uncertain where the document has no own date "
          "of that year):", "", "| arm | explicit years | false, owner-ruled | false, model-scored | false-year rate |",
          "|---|---|---|---|---|"]
    for arm in ARMS:
        u = A[arm]["undated"]
        L.append(f"| {ARM_NAMES[arm]} | {u['explicit']} | {u['owner_ruled']['false']} of "
                 f"{u['owner_ruled']['explicit_ruled']} | {u['model_scored']['false']} of "
                 f"{u['model_scored']['explicit_unruled']} | {pc(u['false_year'])} |")
    L += ["", "Date Uncertain against the owner's flag, all owner documents with a year written:", "",
          "| arm | certain years flagged | uncertain years unflagged |", "|---|---|---|"]
    for arm in ARMS:
        d = A[arm]["du_vs_owner"]
        L.append(f"| {ARM_NAMES[arm]} | {pc(d['certain_flagged'])} | {pc(d['uncertain_unflagged'])} |")
    L += ["", "## Measurement card", "",
          "- **Truth:** the owner's date tags on his 300 (year exact; his Date Uncertain flag for the flag table). "
          "Neither arm drafted it. Undated 90: the owner's rulings on 20 (W46.date-undated-fold), the rest scored "
          "against Gemini 3.7's reading of the page image, a model that is not one of the compared arms; that half is "
          "model-scored and reported apart.",
          "- **Selection:** date_route_pipeline's sets (date_tagging's owner sample, W46.date-undated's 90), kept where "
          "the first page has Vision text of a confirmed JPEG original. The comparison set is chosen by the rule on the "
          "document's own Vision text, the step both arms share, not by either tested reader and not by ABBYY text. "
          "The strata above are defined here from the arms' own inputs; date_truth's ABBYY-defined classes are not used.",
          "- **Comparison:** same documents, same Vision text and neighbours, same propagation, the 8B replies as cached "
          "(1,400 px, the first two pages, date_image.PROMPT). The 2B chooser acts only where a candidate exists, so it "
          "is identical in (a) and (c) and cancels from every paired figure. Its cached replies answer prompts built "
          "from ABBYY text, not these inputs, so none was reused, and none was needed: the smallest 2B run the "
          "comparison requires is zero documents. The quote-source reading was chosen after its replies were read in "
          "W46.date-route-pipeline-8b (in-sample); the strict one was fixed beforehand.",
          f"- **Noise:** n = {o['owner_no_candidate']} paired owner documents; exact two-sided sign test on the "
          "discordant pairs, Wilson 95% intervals on rates. The 8B's rerun floor is not measured (one reply per "
          "document, greedy decoding), so a gap of one or two documents cannot be told from rerun noise; the verdict "
          "needs no floor here, since (c) does not lead (a) even in the raw counts.",
          "- **Scope:** the 16 GB no-key route on these sets. It does not measure a residue stage, the 8B on documents "
          "with a candidate (item 8.2's question), inheritance (step 3), the 2B chooser's accuracy on Vision-text "
          "prompts, or other memory tiers.", ""]
    RESULTS.write_text("\n".join(L))


def main():
    o = score()
    RESULTS_JSON.write_text(json.dumps(o, indent=1) + "\n")
    write_md(o)
    print(json.dumps({k: o[k] for k in ("owner_scored", "owner_no_candidate", "missing_8b", "condition_met")}))
    for arm in ARMS:
        print(arm, json.dumps(o["arms"][arm].get("paired_no_candidate")), json.dumps(o["arms"][arm]["no_candidate"]))
    print("->", RESULTS)


if __name__ == "__main__":
    main()
