#!/usr/bin/env python3
"""W46.date-stamp-fallback: a stamp or postmark date as the document's approximate date when nothing better exists.

The route (date_route_pipeline.route, mirrored in the app's DateRoute.decide) now gives a document whose text has no
year candidate and whose image pass finds no own date, but a written stamped date, the earliest such year with Date
Uncertain (class "stamp"), before the neighbour estimate; a covering document's year still wins in the app. An own date
the image pass quotes from a stamp takes the same class. Either way the stamp keeps the month and day it is quoted with
(W46.p16-stamp-own-date, owner 2026-11-18). This script measures, from W46.date-route-pipeline's cached replies ($0, no
model call):

  fires     how often the stamp step writes the year on the pipeline's two sets, per image reader;
  right     how often a stamp's year (stamp_evidence) is the document's year: on the owner's documents against his
            Finder year tag, on every document whose image reply quotes a stamped date, whatever step wrote its year
            (the step's own documents are too few to score); on the undated set, against the route's explicit year;
  before    on every document the step touches, the route before W46.date-stamp-fallback on the same replies
            (date_route_pipeline.STAMP_STEP off): its year, month, day, Date Uncertain and class, beside the route now;
  order     the stamp's rate beside the neighbour estimate's on the same owner set (date-route-pipeline.md), which
            decides whether the stamp comes before or after step 4.

    python3 date_stamp_fallback.py score     # segbench-results/date-stamp-fallback.md and .json

READ ONLY: reads the pipeline's bench cache, writes only the report.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import date_route_pipeline as P   # noqa: E402
import date_traceable as T        # noqa: E402
import date_undated as DU         # noqa: E402

RESULTS = HERE.parent.parent / "segbench-results" / "date-stamp-fallback.md"
RESULTS_JSON = RESULTS.with_suffix(".json")
READERS = ((P.GEMINI, "Gemini 3.7 Flash (gateway)"), (P.QWEN, "Qwen3.6 27B (Sherlock)"))
ESTIMATE = (35, 51)    # date-route-pipeline.md, "By evidence class", Gemini 3.7 Flash: the estimate's exact years


def before_item(doc, traw, sent):
    """The route before W46.date-stamp-fallback on the same inputs (no stamp class, no stamp step)."""
    P.STAMP_STEP = False
    try:
        return P.route(doc, traw, sent)
    finally:
        P.STAMP_STEP = True


def ymdd(r):
    return {"year": r["year"], "month": r["month"], "day": r["day"], "du": bool(r["du"]), "cls": r["cls"]}


def rows(model):
    out = []
    for d in P.targets():
        if not P.readable(d):
            continue
        traw, im = P.replies(model, d)
        if traw is None:
            continue
        doc = P.doc_of(d)
        cands = T.candidates(doc["text"])
        sent = im if (im is not None and not cands) else None
        r = P.route(doc, traw, sent)
        st = P.stamp_evidence(im) if im is not None else None
        own = DU.own_date(im)[1] if im is not None else None
        out.append({"id": d["id"], "set": d["set"], "truth_y": (d.get("truth") or {}).get("year"), "cls": r["cls"],
                    "year": r["year"], "has_candidate": bool(cands), "image": im is not None, "own": own,
                    "stamp_y": st["year"] if st else None, "stamp_quote": st["quote"] if st else None,
                    "now": ymdd(r), "before": None if r["cls"] != "stamp" else ymdd(before_item(doc, traw, sent))})
    return out


def frac(k, n):
    return {"k": k, "n": n, "pct": round(100 * k / n, 1) if n else None, "ci": P.wilson(k, n)}


def summarise(rs):
    S = {"documents": len(rs), "image_replies": sum(r["image"] for r in rs)}
    S["fires"] = {s: sum(r["cls"] == "stamp" for r in rs if r["set"] == s) for s in ("owner", "undated")}
    S["fired"] = [{k: r[k] for k in ("id", "set", "truth_y", "now", "before", "stamp_quote")}
                  for r in rs if r["cls"] == "stamp"]
    S["fired_by_path"] = {"own date a stamp": sum(r["cls"] == "stamp" and r["own"] is not None for r in rs),
                          "no own date": sum(r["cls"] == "stamp" and r["own"] is None for r in rs)}
    ow = [r for r in rs if r["set"] == "owner" and r["stamp_y"] is not None and r["truth_y"] is not None]
    S["owner_stamp"] = {"exact": frac(sum(r["stamp_y"] == r["truth_y"] for r in ow), len(ow)),
                        "later": sum(r["stamp_y"] > r["truth_y"] for r in ow),
                        "earlier": sum(r["stamp_y"] < r["truth_y"] for r in ow),
                        "route_wrong_stamp_right": [r["id"] for r in ow if r["year"] != r["truth_y"]
                                                    and r["stamp_y"] == r["truth_y"]],
                        "no_own_date": frac(sum(r["stamp_y"] == r["truth_y"] for r in ow if r["own"] is None),
                                            sum(r["own"] is None for r in ow)),
                        "no_text_year": frac(sum(r["stamp_y"] == r["truth_y"] for r in ow if not r["has_candidate"]),
                                             sum(not r["has_candidate"] for r in ow))}
    fo = [r for r in rs if r["cls"] == "stamp" and r["set"] == "owner" and r["truth_y"] is not None]
    S["fired_owner_exact"] = frac(sum(r["year"] == r["truth_y"] for r in fo), len(fo))
    un = [r for r in rs if r["set"] == "undated" and r["stamp_y"] is not None]
    ex = [r for r in un if r["cls"] in ("text", "image")]
    S["undated_stamp"] = {"n": len(un), "agrees_explicit": frac(sum(r["stamp_y"] == r["year"] for r in ex), len(ex)),
                          "no_own_date": sum(r["own"] is None for r in un)}
    return S


def cmd_score(_a=None):
    out = {}
    for model, name in READERS:
        rs = rows(model)
        if rs:
            out[model] = {"name": name, **summarise(rs)}
    RESULTS_JSON.write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n")
    RESULTS.write_text(report(out))
    print(f"wrote {RESULTS} and {RESULTS_JSON.name}")


def pc(f):
    if not f["n"]:
        return "–"
    return f"{f['pct']:.1f}% ({f['k']}/{f['n']}; {f['ci'][0]:.0f}-{f['ci'][1]:.0f})"


def report(out):
    g = out[P.GEMINI]
    os_, us = g["owner_stamp"], g["undated_stamp"]
    ek, en = ESTIMATE
    L = ["# W46.date-stamp-fallback — a stamp or postmark date when nothing better exists", "",
         "Generated by `scripts/segbench/date_stamp_fallback.py score` from W46.date-route-pipeline's cached replies "
         "($0, no model call). The route now gives a document whose text has no year and whose image pass finds no own "
         "date, but a written stamped date (a received stamp, a postmark), the earliest such year with `Date Uncertain` "
         "and evidence class `stamp` (its quote and place), ahead of the neighbour estimate; an own date the image pass "
         "quotes from a stamp takes the same class. The stamp keeps the month and day it is quoted with "
         "(W46.p16-stamp-own-date, owner 2026-11-18: a stamp that is the page's only date keeps its month and day, with "
         "Date Uncertain set; on the no-own-date path only where it is the one stamped date quoted), and a covering "
         "document's year still wins (step 3a).", "",
         "## Verdict", "",
         f"Stamp before estimate, as a judgement more than a measurement. The step writes the year on "
         f"{g['fires']['owner']} of the owner's and {g['fires']['undated']} of the undated documents "
         f"({pc(g['fired_owner_exact'])} exact on the owner's): almost always, a document whose text has no year and "
         "whose page shows a stamp has another own date on the page, or the image pass names the stamp as the document "
         "date, which now also goes to the stamp class (Date Uncertain, its month and day kept) instead of `image`. The "
         "support for the order is indirect: a stamp's year was the owner's year on "
         f"{pc(os_['exact'])} of his documents whose Gemini image pass quotes one, but most of those also carry a year "
         f"in their own text (only {os_['no_text_year']['n']} of them {'does' if os_['no_text_year']['n'] == 1 else 'do'} not); the neighbour estimate is "
         f"{100 * ek / en:.1f}% ({ek}/{en}; {P.wilson(ek, en)[0]:.0f}-{P.wilson(ek, en)[1]:.0f}) exact on the same set, "
         "on other documents (`date-route-pipeline.md`). On the undated set the stamp agrees with the route's explicit "
         f"year on {pc(us['agrees_explicit'])}. Evidence on the document's own page is put ahead of a neighbour's.", "",
         "## Per image reader", "",
         "| image reader | documents | the stamp step fires (owner, undated) | stamp year = owner year | stamp later, earlier | "
         "of them with no own date on the page | undated: stamp = explicit year |",
         "|---|---|---|---|---|---|---|"]
    for m in out.values():
        o, u = m["owner_stamp"], m["undated_stamp"]
        L.append(f"| {m['name']} | {m['documents']} | {m['fires']['owner']}, {m['fires']['undated']} | {pc(o['exact'])} | "
                 f"{o['later']}, {o['earlier']} | {pc(o['no_own_date'])} | {pc(u['agrees_explicit'])} |")
    fired = [f for m in out.values() for f in m["fired"]]
    def ymd(x):
        return "-".join(str(v) for v in (x["year"], x["month"], x["day"]) if v is not None) + (
            ", Date Uncertain" if x["du"] else "") + f" ({x['cls']})"
    bp = g["fired_by_path"]
    L += ["", "## Before and after the item, where the step fired", "",
          f"The step fired {bp['own date a stamp']} time(s) because the image pass named a stamped date as the "
          f"document's own and {bp['no own date']} time(s) on a page with no own date. Before the item is the route "
          "on the same cached replies with the stamp class and step switched off (`date_route_pipeline.STAMP_STEP`), "
          "not the route with no image pass.", "",
          "| document | set | before the item | now | owner's year | the stamp quoted |", "|---|---|---|---|---|---|"]
    L += [f"| {f['id']} | {f['set']} | {ymd(f['before'])} | {ymd(f['now'])} | {f['truth_y']} | {f['stamp_quote'] or '–'} |"
          for f in fired] or ["| nowhere | | | | | |"]
    if os_["route_wrong_stamp_right"]:
        L += ["", f"On {len(os_['route_wrong_stamp_right'])} owner document(s) the route's year is wrong and the "
                 f"stamp's right ({', '.join(os_['route_wrong_stamp_right'])}): an explicit text year, which a stamp "
                 "never overrides."]
    L += ["", "## Measurement card", "",
          "- **Truth.** The owner's own Finder year tags on his 300 documents (W46.date-route-pipeline's owner set); "
          "the undated set has no owner year, so there the stamp is compared with the route's explicit text or image "
          "year, a relative and not a truth. Nothing new was shown to the owner.",
          "- **Selection.** Every document of the pipeline's two sets with a readable first page and a trace reply; "
          "the stamp rows are those whose image reply quotes a written stamped date (where `stamp` or kind "
          "`stamped`), which is the condition the step reads. Not chosen by ABBYY text or by the year.",
          "- **Comparison.** Gemini 3.7 Flash's image pass (2,400 px, first two pages) as the route sends it, and the "
          "27B's where its replies are cached; the estimate figure is the same model's step 4 on the same owner set, "
          "but on other documents (no document both has a stamp and reaches step 4), so the order rests on two "
          "unpaired rates.",
          f"- **Noise.** n = {os_['exact']['n']} stamp documents, Wilson 95% intervals shown: the stamp's lower bound "
          f"({os_['exact']['ci'][0]:.0f}%) is above the estimate's upper one ({P.wilson(ek, en)[1]:.0f}%), but the "
          "two are different documents, so this is not a paired gap. The rerun floor (the same year on 94% of documents between two identical runs, "
          "`date-undated.md`) bounds how far either rate can be trusted to repeat.",
          "- **Scope.** Not settled: how a stamp does on a document with no own date at all (the step's real "
          "population; the owner rows here mostly carry their own date as well, and a received stamp lags the writing "
          "by days, so a December letter stamped in January would be a year late); the stamp's month and day against "
          "the page beyond the one firing (`date-full-date.md` scores it with the rest); stamps the image pass misses (it runs only where the text has no year). This is a dating route, "
          "not an OCR result, so the both-OCR-sets rule does not apply.", ""]
    return "\n".join(L)


if __name__ == "__main__":
    if sys.argv[1:] != ["score"]:
        print(__doc__)
        sys.exit(2)
    cmd_score()
