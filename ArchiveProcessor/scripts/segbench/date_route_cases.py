#!/usr/bin/env python3
"""W46.date-route: cases for the app's dating route, written by the bench's own code, so the Swift port
(Tagging/DateRoute.swift, checked by DateRouteTestDriver) is held to what date_route_pipeline measured.

Each case is one document: its own text, its neighbours, a trace reply and an image reply, and what the bench makes of
them: the rule candidates and pick (date_traceable.candidates, rule_pick), the trace prompt ("neigh"), the parsed reply
(parse_trace), the evidence check (date_scorers.evidence_check on context_of "neigh"), the image reading (date_image.read,
date_undated.own_date, the stamp count) and the route (date_route_pipeline.route), with the owner's one-way flag
(W46.date-route-owner-ok (a): the model's own flag may add Date Uncertain to an explicit text year).

    python3 date_route_cases.py             # the synthetic cases -> fixtures/date-route-cases.json (committed)
    python3 date_route_cases.py --check     # the committed fixture is what the bench gives now (exit 1 if not)
    python3 date_route_cases.py --real OUT  # every pipeline document with a Gemini reply -> OUT (the owner's text: it
                                            # stays in the private bench cache, never in the repo)
$0: no call is made; --real reads the replies W46.date-route-pipeline cached.
"""
import json, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import date_image as DI          # noqa: E402
import date_scorers as SC        # noqa: E402
import date_traceable as T       # noqa: E402
import date_undated as DU        # noqa: E402

FIXTURE = HERE / "fixtures" / "date-route-cases.json"


def route(doc, trace_raw, image_rec):
    import date_route_pipeline as P
    return P.route(doc, trace_raw, image_rec)


def doc_from(text, near):
    return {"text": text, "near": [{"label": n["label"], "dist": n["dist"], "text": n["text"],
                                   "pick": T.rule_pick(T.candidates(n["text"]))} for n in near]}


def case(cid, text, near, trace_raw, image_raw):
    """One case. text is the document's own text as the route reads it, near [{label, dist, text}]."""
    doc = doc_from(text, near)
    cands = T.candidates(doc["text"])
    y, m, _, best = T.rule_pick(cands)
    tr = T.parse_trace(trace_raw)
    chk = SC.evidence_check(tr["y"], tr["evidence"], T.context_of(doc, "neigh")) if tr["parsed"] else ("none", "unparsed")
    im = {"text": image_raw} if image_raw is not None else None
    sent = im if (im is not None and not cands) else None
    r = route(doc, trace_raw, sent)
    img = None
    if im is not None:
        ok, own, _ = DU.own_date(im)
        rd = DI.read(im)
        img = {"ok": ok, "own": own, "stamps": sum(1 for x in rd["dates"] if x["written"] and (
            x["where"] == "stamp" or x["kind"] == "stamped"))}
    return {"id": cid,
            "input": {"text": text, "near": near, "trace_raw": trace_raw, "image_raw": image_raw},
            "expect": {"candidates": [[c["year"], c["month"], c["kind"], c["line_no"], c["line"]] for c in cands],
                       "pick": [y, m],
                       "prompt": T.trace_prompt(doc, "neigh"),
                       "trace": {"parsed": tr["parsed"], "year": tr["y"], "lo": tr["lo"], "hi": tr["hi"],
                                 "uncertain": tr["du"]},
                       "check": list(chk),
                       "image": img,
                       "route": {"year": r["year"], "cls": r["cls"], "step": r["step"],
                                 "du": bool(r["du"] or (r["cls"] == "text" and r["model_du"] is True))}}}


def j(**kw):
    return json.dumps(kw)


LETTER = "UNITED STATES SENATE\nWashington, D. C.\nMarch 3, 1947\n\nDear Mr. Hale:\nThank you for your letter of 1946."
MEMO = "MEMORANDUM\nTo: Files\nRe: the budget\n\nThe committee met and agreed on the figures given above."
NEAR = [{"label": "P1", "dist": 1, "text": "Office memo\n12/4/58\nPlease file."},
        {"label": "P2", "dist": 2, "text": "A letter of\nJune 2, 1957\nregarding the {near} plan"},
        {"label": "N1", "dist": -1, "text": "No date here at all."}]


def synthetic():
    img_own = j(dates=[{"quote": "Rec'd APR 4 1961", "page": 1, "where": "stamp", "kind": "stamped", "year": 1961},
                       {"quote": "March 30, 1961", "page": 1, "where": "dateline", "kind": "typed", "year": 1961, "month": 3}],
                document_date={"year": 1961, "month": 3, "quote": "March 30, 1961"})
    img_unwritten = j(dates=[{"quote": "the spring meeting", "page": 1, "where": "body", "kind": "typed", "year": 1950}],
                      document_date={"year": 1950, "month": None, "quote": "the spring meeting"})
    return [
        case("explicit-full", LETTER, NEAR, j(year=1947, lo=1947, hi=1947, date_uncertain=False,
                                              evidence={"neighbour": "self", "quote": "March 3, 1947"}), None),
        case("explicit-model-flag-adds", LETTER, NEAR, j(year=1946, lo=1946, hi=1947, date_uncertain=True,
                                                         evidence={"neighbour": "self", "quote": "letter of 1946"}), None),
        case("candidate-estimate-valid", LETTER, NEAR, j(year=1957, lo=1956, hi=1958, date_uncertain=True,
                                                         evidence={"neighbour": "P2", "quote": "June 2, 1957"}), None),
        case("candidate-reply-unchecked", LETTER, NEAR, j(year=1949, lo=1940, hi=1950, date_uncertain=True,
                                                          evidence={"neighbour": "P1", "quote": "June 2, 1949"}), None),
        case("candidate-unparsed", LETTER, NEAR, "I am not sure.", None),
        case("no-candidate-image-own", MEMO, NEAR, j(year=1958, lo=1957, hi=1959, date_uncertain=True,
                                                     evidence={"neighbour": "P1", "quote": "12/4/58"}), img_own),
        case("no-candidate-image-unwritten-estimate", MEMO, NEAR,
             j(year=1958, lo=1957, hi=1959, date_uncertain=True, evidence={"neighbour": "P1", "quote": "12/4/58"}),
             img_unwritten),
        case("no-candidate-estimate-two-digits", MEMO, NEAR,
             j(year=1958, lo=1957, hi=1959, date_uncertain=True, evidence={"neighbour": "P1", "quote": "12/4/58"}), None),
        case("no-candidate-short-evidence", MEMO, NEAR, "```json\n" + j(year=1957, lo=1957, hi=1958,
                                                                        evidence={"P2": "June 2, 1957"}) + "\n```", None),
        case("no-candidate-quote-not-in-text", MEMO, NEAR,
             j(year=1957, lo=1956, hi=1958, date_uncertain=True, evidence={"neighbour": "P2", "quote": "July 9, 1957"}),
             None),
        case("no-candidate-ocr-damage", MEMO, [{"label": "P1", "dist": 1, "text": "Dated 196L by the clerk"}],
             j(year=1961, lo=1960, hi=1962, date_uncertain=True, evidence={"neighbour": "P1", "quote": "Dated 196L"}),
             None),
        case("no-candidate-elision", MEMO, NEAR,
             "<think>the neighbour</think>" + j(year=1957, lo=1957, hi=1957, date_uncertain=True,
                                                 evidence={"neighbour": "P2", "quote": "A letter of ... 1957"}), None),
        case("no-candidate-null-year", MEMO, [], j(year=None, lo=None, hi=None, date_uncertain=True, evidence={}), None),
        case("no-candidate-cited-missing", MEMO, NEAR,
             j(year=1957, lo=1957, hi=1957, date_uncertain=True, evidence={"neighbour": "P3", "quote": "1957"}), None),
        case("string-year-bad-interval", MEMO, NEAR,
             j(year="1957", lo=1960, hi=1962, date_uncertain=False, evidence={"neighbour": "P2", "quote": "June 2, 1957"}),
             None),
        case("numeric-forms", "Report\n4.5.62 and 13/1/1963\n31-12-99\n" + "x\n" * 16 + "In 1970 and 1970 and 1971",
             [], j(year=1962, lo=1962, hi=1962, date_uncertain=False, evidence={"quote": "4.5.62"}), None),
        case("late-head-weighted", "x\n" * 20 + "the 1950 plan, 1950, and in May 1952", [],
             j(year=1950, lo=1950, hi=1950, date_uncertain=False, evidence={"neighbour": "self", "quote": "1950"}), None),
        case("day-of-month", "Signed the 3rd of October, 1938 at noon\nand again Sept. 4th 1939", [], None, None),
        case("crlf-and-feeds", "Line one\r\nDec. 1941\x0cpage two 1942 end", [], "", None),
        case("image-unparsable", MEMO, [], None, "no dates found"),
    ]


def real(out):
    import date_route_pipeline as P
    cases = []
    for d in P.targets():
        if not P.readable(d):
            continue
        traw, im = P.replies(P.GEMINI, d)
        if traw is None:
            continue
        doc = P.doc_of(d)
        near = [{"label": n["label"], "dist": n["dist"], "text": n["text"]} for n in doc["near"]]
        cases.append(case(d["id"], doc["text"], near, traw, (im or {}).get("text") if im else None))
    Path(out).write_text(json.dumps(cases, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {out}: {len(cases)} cases")


def main():
    a = sys.argv[1:]
    if a[:1] == ["--real"] and len(a) == 2:
        return real(a[1])
    text = json.dumps(synthetic(), ensure_ascii=False, indent=1) + "\n"
    if a == ["--check"]:
        ok = FIXTURE.exists() and FIXTURE.read_text(encoding="utf-8") == text
        print(("PASS" if ok else "FAIL") + f": {FIXTURE.name} is what the bench gives now")
        return 0 if ok else 1
    if a:
        print(__doc__)
        return 2
    FIXTURE.write_text(text, encoding="utf-8")
    print(f"wrote {FIXTURE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
