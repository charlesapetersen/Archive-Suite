#!/usr/bin/env python3
"""W47.wh-date-evidence-shown — what showing a failed-check estimate would add (owner call 9).

Reads W46.date-route-pipeline's scored rows (CACHE/rows-<model>.jsonl, written by `date_route_pipeline.py score` with
the widened checker of W46.date-evidence-check) and its cached trace replies. For each route it counts the replies the
check refuses, which of them would newly put a year in front of the user (the route wrote none), and how many of those
are right; and it sorts the refused right years by what the quote holds, from its digits alone (no session reads a
quote). $0, no model called, read-only; writes nothing but the report.

    python3 date_failed_estimates.py          # -> ../../segbench-results/date-failed-estimates.json + a summary
"""
import collections
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import date_route_pipeline as RP  # noqa: E402

OUT = HERE.parent.parent / "segbench-results" / "date-failed-estimates.json"
MODELS = (RP.GEMINI, RP.QWEN)


def quote_of(raw):
    s = re.sub(r"^```(json)?|```$", "", (raw or "").strip(), flags=re.M).strip()
    try:
        ev = json.loads(s).get("evidence") or {}
    except (ValueError, AttributeError):
        return ""
    return " ".join(str(v) for v in ev.values())


def raw_replies(model):
    if model == RP.GEMINI:
        return lambda r: json.loads(RP.trace_dest(r).read_text())["text"]
    qa = {}
    for line in open(RP.QWEN_ANSWERS, encoding="utf-8"):
        a = json.loads(line)
        if a["id"].startswith("trace-neigh|"):
            qa[a["id"].split("|", 1)[1]] = a["raw"]
    return lambda r: qa.get(r["id"], "")


def digits_form(year, quote):
    """What the quote's digits hold against the year, coarsely; the checker's own reason says why it refused."""
    y, nums = str(year), re.findall(r"\d+", quote)
    if not nums:
        return "no digits"
    if any(len(n) == 4 and n != y for n in nums):
        return "another four-digit year"
    if any(n.endswith(y[2:]) for n in nums):
        return "the year's two digits, not in a date form the checker reads"
    if any(len(n) >= 3 and n[:3] == y[:3] for n in nums):
        return "three of the year's digits"
    return "digits, not the year"


def in_decade(r):
    d = r.get("decade")
    return d is not None and r["trace_y"] is not None and d <= r["trace_y"] <= d + 9


def score(model):
    rows = [json.loads(l) for l in open(RP.CACHE / f"rows-{model}.jsonl", encoding="utf-8")]
    raw = raw_replies(model)
    out = {}
    for st in ("owner", "undated"):
        R = [r for r in rows if r["set"] == st]
        failed = [r for r in R if r["verdict"] != "valid" and r.get("trace_y")]
        new = [r for r in failed if r["cls"] == "none"]
        dated = [r for r in new if r["truth_y"] is not None]
        o = {"documents": len(R), "no_year_written": sum(1 for r in R if r["cls"] == "none"),
             "failed_with_year": len(failed),
             "failed_where_another_step_wrote": sum(1 for r in failed if r["cls"] != "none"),
             "newly_shown": len(new),
             "newly_shown_reasons": dict(collections.Counter(r["reason"] for r in new))}
        if st == "owner":
            o["newly_shown_year_truth"] = {"right": sum(1 for r in dated if r["trace_y"] == r["truth_y"]),
                                           "wrong": sum(1 for r in dated if r["trace_y"] != r["truth_y"]),
                                           "wrong_by_years": sorted(abs(r["trace_y"] - r["truth_y"]) for r in dated
                                                                    if r["trace_y"] != r["truth_y"])}
            dec = [r for r in new if r["truth_y"] is None]
            o["newly_shown_decade_truth"] = {"n": len(dec), "in_decade": sum(1 for r in dec if in_decade(r))}
            rr = [r for r in failed if r["truth_y"] is not None and r["trace_y"] == r["truth_y"]]
            o["right_years_refused"] = len(rr)
            o["right_refused_by_reason"] = dict(collections.Counter(r["reason"] for r in rr))
            o["right_refused_no_year_in_quote_by_digits"] = dict(collections.Counter(
                digits_form(r["trace_y"], quote_of(raw(r))) for r in rr
                if r["reason"] == "quote does not carry the year given"))
        else:
            o["newly_shown_false_years"] = len(new)          # every document of the undated set is undated
        out[st] = o
    return out


def main():
    res = {m: score(m) for m in MODELS}
    OUT.write_text(json.dumps(res, indent=1) + "\n")
    print(json.dumps(res, indent=1))
    print(f"-> {OUT}")


if __name__ == "__main__":
    main()
