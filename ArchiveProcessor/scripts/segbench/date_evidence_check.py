#!/usr/bin/env python3
"""W46.date-evidence-check: the evidence checker's false refusals, re-scored on cached replies.

date_scorers.evidence_check used to want the year's four digits in the quote, so a right year quoted as "9/24/58",
"27 Oct 82", "1983-84" or "196L" was refused. It now reads two-digit years inside a date form and OCR letters for a
digit (date_scorers.year_in_quote), finds a quote across line-end hyphens and "..." elisions, and still refuses a
quote with no date in it, a different year as written ("1938" for 1988), or text that is not in the cited document.

The replies re-scored are the 27B's 300 trace-neigh replies on Apple Vision text (W46.date-traceable-vision, run on
Sherlock), with the context rebuilt from the prompts that were sent (the pack), so the check sees exactly the text
the model saw. The corpus-text arms' replies (date-tagging/traceable, the "49 of 101" in date-traceable.md) and the
Gemini arm's moved to the owner's backup on 30 Oct; the restated route reads Vision text, so these are the replies
it will meet. No model is called; read-only on the corpus (truth from date_truth through date_traceable).

  python3 date_evidence_check.py     (from ArchiveProcessor/scripts/segbench)
"""
import collections
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import date_scorers as S
import date_traceable as T

SHERLOCK = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/sherlock-results")
ANSWERS = os.path.join(SHERLOCK, "runs/text/date-traceable-vision-qwen3.6-27b-nothink/answers.jsonl")
PACK = os.path.join(SHERLOCK, "text-packs/fs-tracepack-vision/requests.jsonl")
RESULTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "segbench-results",
                       "date-evidence-check.md")


def old_check(year, evidence, context):
    """The checker before this item (date_traceable's figures): four digits in the quote, the quote found by
    spacing and case only."""
    if not evidence:
        return "none"
    if year is None:
        return "unsupported"
    nb = evidence.get("neighbour", "self")
    quote = evidence.get("quote") or ""
    if nb not in context or not quote.strip() or S._norm(quote) not in S._norm(context[nb]):
        return "unsupported"
    return "valid" if str(year) in S._norm(quote) else "unsupported"


def context_of_prompt(prompt):
    """{id: text} of a trace-neigh prompt (date_traceable.trace_prompt), as date_traceable.context_of builds it:
    the document, each neighbour's text, and each neighbour's rule line from the prompt's list."""
    _, rest = prompt.split('(id "self"):\n---\n', 1)
    own, rest = rest.split("\n---\n\nNearby documents", 1)
    ctx = {"self": own}
    near, _, extra = rest.split("each headed by its id:\n", 1)[1].partition("\nDates a rule found printed")
    for m in re.finditer(r"\[([PN]\d)\]\n(.*?)\n---\n", near, re.S):
        ctx[m.group(1)] = m.group(2)
    for m in re.finditer(r'^\[([PN]\d)\] \d{4} \("(.*)"\)$', extra, re.M):
        ctx[m.group(1)] += "\n" + m.group(2)
    return ctx


def rows():
    answers = {r["id"]: r for r in map(json.loads, open(ANSWERS, encoding="utf-8")) if "raw" in r}
    prompts = {r["id"]: r["prompt"] for r in map(json.loads, open(PACK, encoding="utf-8"))}
    truth = {d["id"]: d for d in T.owner_docs()}
    out = []
    for k in sorted(i for i in answers if i.startswith("trace-neigh|")):
        d = truth[k.split("|", 1)[1]]
        t = T.parse_trace(answers[k]["raw"])
        if t["y"] is None:
            continue
        ctx = context_of_prompt(prompts[k])
        new, reason = S.evidence_check(t["y"], t["evidence"], ctx)
        out.append({"id": d["id"], "cls": d["cls"], "y": t["y"], "evidence": t["evidence"],
                    "right": S.interval_distance(t["y"], *S.truth_interval(d["truth"])) == 0,
                    "old": old_check(t["y"], t["evidence"], ctx), "new": new, "reason": reason})
    return out


def tally(rs, key):
    c = collections.Counter(r[key] for r in rs)
    return {"valid": c["valid"], "unsupported": c["unsupported"], "none": c["none"],
            "right_unsupported": sum(1 for r in rs if r[key] == "unsupported" and r["right"]),
            "wrong_valid": sum(1 for r in rs if r[key] == "valid" and not r["right"])}


def quote(r):
    ev = r["evidence"] or {}
    q = (ev.get("quote") or "").replace("|", "\\|").replace("\n", " ")
    return f"{ev.get('neighbour', 'self')}: \"{q[:60]}{'…' if len(q) > 60 else ''}\""


def write(rs):
    old, new = tally(rs, "old"), tally(rs, "new")
    flipped = [r for r in rs if r["old"] != r["new"]]
    how = collections.Counter(re.search(r"\((.*)\)$", r["reason"]).group(1) if r["reason"].endswith(")")
                              else "quote found by hyphen or elision" for r in flipped)
    left = [r for r in rs if r["new"] == "unsupported"]
    out = {"replies": len(rs), "old": old, "new": new, "flipped": len(flipped), "flipped_how": dict(how),
           "flipped_wrong_year": sum(1 for r in flipped if not r["right"]),
           "left_reasons": dict(collections.Counter(r["reason"] for r in left)),
           "left_right_year": sum(1 for r in left if r["right"])}
    with open(RESULTS[:-3] + ".json", "w", encoding="utf-8") as fh:
        json.dump({**out, "rows": [{k: r[k] for k in ("id", "y", "right", "old", "new", "reason")} for r in rs]}, fh,
                  indent=1, ensure_ascii=False)     # verdicts only: the quotes stay in the cache
    L = ["# The evidence checker's false refusals (W46.date-evidence-check)", "",
         "`date_scorers.evidence_check` re-scored on the 27B's cached trace-neigh replies on Apple Vision text "
         f"({len(rs)} replies with a year, the owner's 300), the context rebuilt from the prompts sent. Script: "
         "`scripts/segbench/date_evidence_check.py`. No model was called.", "",
         "## Findings", "",
         f"- **The widened checker accepts {len(flipped)} more citations; the right-year refusals fall from "
         f"{old['right_unsupported']} to {new['right_unsupported']}.** Valid / unsupported: {old['valid']} / "
         f"{old['unsupported']} before, {new['valid']} / {new['unsupported']} after. Of the {len(flipped)}: "
         + ", ".join(f"{n} {k}" for k, n in how.most_common()) + ". Every one is listed below and was read: each "
         "quote is in the cited text and does carry the year given.",
         f"- **{out['flipped_wrong_year']} of the newly valid citations give a wrong year.** The check is for "
         "traceability, not truth: \"3/25/68\" in a neighbour does carry 1968, whether or not the document is from "
         "1968. Before, the valid set held "
         f"{old['wrong_valid']} wrong years; after, {new['wrong_valid']}.",
         f"- **{new['unsupported']} are still refused, {out['left_right_year']} of them with the right year, and "
         "those refusals are meant.** Most quote text with no date in it (\"Some people would bar President "
         "Truman, others Senator Taft.\"), or a different year as written (\"APRIL 25, 1938\" for 1988, \"BUSINESS "
         "WEEK November 5, 1966\" for 1968). A digit read as another digit is not accepted: the weekday does not "
         "separate the two, since April 25 was a Monday in 1938 and in 1988. A few are damage the checker does not "
         "read (\"FALL 19/70\", \"9 0et 75\", \"June 20, 19 23\"), each one case.",
         "- **What this changes for the route.** W46.date-route's estimate step writes a year only when this check "
         "passes, and the owner's call 9 kept failed estimates hidden until it was fixed. A valid reason that is "
         "not four digits names how the year was read (\"(two digits)\", \"(ocr damage)\"), so the route can show "
         "the evidence class beside the quote.", "",
         "## Measurement card", "",
         "- **Truth:** the owner's date tags (date_truth, the 300), used only to say whether a year is right; the "
         "verdict itself needs no truth. The newly accepted quotes were read by this session against the rule.",
         "- **Selection:** every trace-neigh reply with a year on the owner's 300; none chosen by a tested route or "
         "by ABBYY text.",
         "- **Comparison:** the same replies, the same contexts, the checker before and after.",
         "- **Noise:** none from sampling; it is a deterministic re-score of fixed replies. The change in counts is "
         "exact.",
         "- **Scope:** one model (Qwen3.6 27B), one prompt (trace-neigh), Vision text. The corpus-text replies "
         "behind date-traceable.md's \"49 of 101\" and the Gemini arm's replies (45 of 131 failing) are in the "
         "owner's backup since 30 Oct and were not re-scored; W46.date-route-pipeline makes fresh Gemini and 27B "
         "replies and scores them with this checker. Whether a two-digit year's century is right is the year's "
         "question, not the quote's.", "",
         f"## The {len(flipped)} citations now accepted", "",
         "| year | right | how | cited quote |", "|---|---|---|---|"]
    for r in sorted(flipped, key=lambda r: r["reason"]):
        L.append(f"| {r['y']} | {'yes' if r['right'] else 'no'} | {r['reason'].rsplit('(', 1)[-1].rstrip(')') if r['reason'].endswith(')') else 'hyphen or elision'} | {quote(r)} |")
    L += ["", f"## Still refused ({len(left)})", "", "| reason | n | of them right |", "|---|---|---|"]
    for reason, n in collections.Counter(r["reason"] for r in left).most_common():
        L.append(f"| {reason} | {n} | {sum(1 for r in left if r['reason'] == reason and r['right'])} |")
    L += ["", "Right years still refused:", ""]
    L += [f"- {r['y']}, {quote(r)}" for r in left if r["right"]]
    with open(RESULTS, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L) + "\n")
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    write(rows())
