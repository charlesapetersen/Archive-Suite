#!/usr/bin/env python3
"""date_undated.py: the spending cap refusing before any request, the app call's body, and the "own date on the
pages" reading.

    python3 -m unittest test_date_undated
"""
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import date_undated as U


class Cap(unittest.TestCase):
    def test_refuses_before_a_request_when_the_worst_case_would_pass_the_cap(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(U, "CACHE", Path(tmp)), \
                mock.patch.object(U.G, "request") as req:
            (Path(tmp) / "calls.jsonl").write_text(json.dumps({"id": "x", "cost": U.CAP - U.WORST_APP / 2}) + "\n")
            with self.assertRaises(SystemExit):
                U.call("k", U.app_body("p"), U.WORST_APP, Path(tmp) / "out.json")
            req.assert_not_called()

    def test_a_cached_reply_is_returned_without_a_request(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(U, "CACHE", Path(tmp)), \
                mock.patch.object(U.G, "request") as req:
            dest = Path(tmp) / "out.json"
            dest.write_text(json.dumps({"id": "k", "text": "{}"}))
            self.assertEqual(U.call("k", U.app_body("p"), U.WORST_APP, dest)["id"], "k")
            req.assert_not_called()


class AppCall(unittest.TestCase):
    def test_sends_no_temperature_or_reasoning_as_the_app(self):
        b = U.app_body("prompt")
        self.assertNotIn("temperature", b)
        self.assertNotIn("reasoning_effort", b)
        self.assertEqual(b["messages"], [{"role": "user", "content": "prompt"}])

    def test_parses_the_reply_as_the_app(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "r.json"
            dest.write_text(json.dumps({"text": '```json\n{"year": "1968", "month": null, "date_uncertain": true}\n```'}))
            self.assertEqual(U.app_reply(dest), {"y": 1968, "m": None, "du": True, "parsed": True})
            dest.write_text(json.dumps({"text": "no json"}))
            self.assertEqual(U.app_reply(dest), {"y": None, "m": None, "du": True, "parsed": False})
            self.assertIsNone(U.app_reply(Path(tmp) / "missing.json"))


class OwnDate(unittest.TestCase):
    def rec(self, dates, doc):
        return {"text": json.dumps({"dates": dates, "document_date": doc})}

    def test_own_date_needs_its_year_written_in_a_quote(self):
        ok, own, written = U.own_date(self.rec([{"quote": "March 3, 1968", "year": 1968}], {"year": 1968}))
        self.assertEqual((ok, own, written), (True, 1968, [1968]))

    def test_a_supplied_year_not_on_the_page_is_not_an_own_date(self):
        ok, own, written = U.own_date(self.rec([{"quote": "March 3", "year": 1968}], {"year": 1968}))
        self.assertEqual((ok, own, written), (True, None, []))

    def test_no_document_date_is_none_even_with_dates_quoted(self):
        self.assertIsNone(U.own_date(self.rec([{"quote": "1954", "year": 1954}], None))[1])

    def test_an_unparsed_reply(self):
        self.assertEqual(U.own_date({"text": "nothing"}), (False, None, []))


class Wilson(unittest.TestCase):
    def test_bounds(self):
        lo, hi = U.wilson(50, 100)
        self.assertAlmostEqual(lo, 0.404, places=2)
        self.assertAlmostEqual(hi, 0.596, places=2)
        self.assertEqual(U.wilson(0, 0), (0.0, 0.0))


if __name__ == "__main__":
    unittest.main()
