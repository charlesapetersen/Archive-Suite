#!/usr/bin/env python3
"""date_route_pipeline.py: the route's steps and Date Uncertain by class, the spending cap, and the false-year count.

    python3 -m unittest test_date_route_pipeline
"""
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import date_route_pipeline as P
import date_traceable as T


def doc(text, near=()):
    ns = [{"label": lab, "dist": dist, "text": t, "pick": T.rule_pick(T.candidates(t))} for lab, dist, t in near]
    return {"id": "o:x", "text": text, "near": ns}


def trace(year, quote=None, nb=None, lo=None, hi=None):
    ev = None if quote is None else ({"quote": quote} if nb is None else {"neighbour": nb, "quote": quote})
    return json.dumps({"year": year, "lo": lo if lo is not None else year, "hi": hi if hi is not None else year,
                       "date_uncertain": True, "evidence": ev})


def image(own=None, quote=None, dates=()):
    ds = [{"quote": q, "page": 1, "where": w, "kind": "typed", "year": y} for q, y, w in dates]
    dd = None if own is None else {"year": own, "quote": quote}
    return {"text": json.dumps({"dates": ds, "document_date": dd})}


class Route(unittest.TestCase):
    def test_a_year_printed_in_the_own_text_is_explicit_without_date_uncertain(self):
        d = doc("MEMORANDUM\nMarch 3, 1958\nTo the trustees")
        r = P.route(d, trace(1958, "March 3, 1958"), None)
        self.assertEqual((r["year"], r["du"], r["cls"], r["step"]), (1958, False, "text", 1))

    def test_a_two_digit_own_date_quoted_from_self_is_explicit(self):
        d = doc("Notes for the meeting 27 Oct 82\nagenda follows")
        self.assertEqual(T.candidates(d["text"]), [])
        r = P.route(d, trace(1982, "27 Oct 82"), None)
        self.assertEqual((r["year"], r["du"], r["cls"]), (1982, False, "text"))

    def test_the_image_date_counts_only_where_the_text_has_no_candidate(self):
        d = doc("an undated page of text")
        r = P.route(d, trace(None), image(1961, "June 29, 1961", [("June 29, 1961", 1961, "dateline")]))
        self.assertEqual((r["year"], r["du"], r["cls"], r["step"]), (1961, False, "image", 2))

    def test_an_image_year_not_written_in_a_quoted_date_is_not_used(self):
        d = doc("an undated page of text", near=[("P1", 1, "Letter of May 2, 1947")])
        r = P.route(d, trace(None), image(1961, "", []))
        self.assertEqual((r["year"], r["cls"]), (None, "none"))

    def test_a_checked_neighbour_estimate_is_written_with_date_uncertain(self):
        d = doc("an undated page", near=[("P1", 1, "Letter of May 2, 1947")])
        r = P.route(d, trace(1947, "May 2, 1947", "P1", 1946, 1948), image())
        self.assertEqual((r["year"], r["du"], r["cls"], r["step"]), (1947, True, "estimate", 4))

    def test_an_estimate_whose_evidence_fails_writes_no_year(self):
        d = doc("an undated page", near=[("P1", 1, "Letter of May 2, 1947")])
        r = P.route(d, trace(1952, "May 2, 1947", "P1"), image())
        self.assertEqual((r["year"], r["du"], r["cls"]), (None, True, "none"))
        self.assertEqual(r["verdict"], "unsupported")

    def test_a_printed_year_the_model_moves_from_without_evidence_keeps_the_rules_year(self):
        d = doc("Report of 1958\nbody text")
        r = P.route(d, trace(1960, "nothing like it", "P1"), None)
        self.assertEqual((r["year"], r["du"], r["cls"]), (1958, False, "text"))

    def test_an_unparsed_reply_on_a_printed_document_keeps_the_rules_year(self):
        r = P.route(doc("Report of 1958"), "not json", None)
        self.assertEqual((r["year"], r["cls"]), (1958, "text"))

    def test_the_models_own_flag_is_never_used(self):
        d = doc("March 3, 1958")
        raw = json.dumps({"year": 1958, "lo": 1958, "hi": 1958, "date_uncertain": True,
                          "evidence": {"quote": "March 3, 1958"}})
        self.assertFalse(P.route(d, raw, None)["du"])


class Undated(unittest.TestCase):
    def test_false_years_use_the_owners_ruling_then_the_page_reading(self):
        rows = [{"id": "u:a", "year": 1962, "du": False, "cls": "text", "page_own": None},     # ruled own 1962
                {"id": "u:b", "year": 1980, "du": False, "cls": "text", "page_own": 1980},     # ruled no own date
                {"id": "u:c", "year": 1970, "du": False, "cls": "text", "page_own": 1971},     # unruled, page differs
                {"id": "u:d", "year": 1970, "du": True, "cls": "estimate", "page_own": None},  # flagged: never false
                {"id": "u:e", "year": None, "du": True, "cls": "none", "page_own": None}]
        rul = {"documents": {"D1": {"id": "a", "owner": {"own": True, "lo": 1962, "hi": 1962}},
                             "D2": {"id": "b", "owner": {"own": False, "lo": None, "hi": None}}}}
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(P.DU, "SHEET", Path(tmp)):
            (Path(tmp) / P.DU.RULINGS_NAME).write_text(json.dumps(rul))
            s = P.undated_summary(rows)
        self.assertEqual(s["owner_ruled"], {"documents_ruled": 2, "explicit_ruled": 2, "false": 1})
        self.assertEqual(s["model_scored"], {"explicit_unruled": 1, "false": 1})
        self.assertEqual(s["false_year"]["k"], 2)
        self.assertEqual(s["estimates"], 1)


class Cap(unittest.TestCase):
    def test_refuses_before_a_request_when_the_worst_case_would_pass_the_cap(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(P, "CACHE", Path(tmp)), \
                mock.patch.object(P.G, "request") as req:
            (Path(tmp) / "calls.jsonl").write_text(json.dumps({"id": "x", "cost": P.CAP - P.WORST_TRACE / 2}) + "\n")
            with self.assertRaises(SystemExit):
                P.call("k", P.trace_body("p"), P.WORST_TRACE, Path(tmp) / "out.json")
            req.assert_not_called()

    def test_trace_body_is_the_measured_request(self):
        b = P.trace_body("p")
        self.assertEqual((b["temperature"], b["reasoning_effort"]), (0, "low"))


if __name__ == "__main__":
    unittest.main()
