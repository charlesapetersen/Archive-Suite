#!/usr/bin/env python3
"""date_image_gateway.py: the spending cap refusing before any request, and the typeface probe's scoring.

    python3 -m unittest test_date_image_gateway
"""
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import date_image_gateway as GW


class Cap(unittest.TestCase):
    def test_refuses_before_a_request_when_the_worst_case_would_pass_the_cap(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(GW, "OUT", Path(tmp)), \
                mock.patch.object(GW.G, "request") as req:
            (Path(tmp) / "calls.jsonl").write_text(json.dumps({"id": "x", "cost": GW.CAP - GW.WORST / 2}) + "\n")
            with self.assertRaises(SystemExit):
                GW.call("k", [b"jpeg"], "prompt", Path(tmp) / "out.json")
            req.assert_not_called()

    def test_a_cached_reply_is_returned_without_a_request(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(GW, "OUT", Path(tmp)), \
                mock.patch.object(GW.G, "request") as req:
            dest = Path(tmp) / "out.json"
            dest.write_text(json.dumps({"id": "k", "text": "{}"}))
            self.assertEqual(GW.call("k", [b"jpeg"], "prompt", dest)["id"], "k")
            req.assert_not_called()


class Probe(unittest.TestCase):
    req = {"doc": "o:1", "cls": "D", "truth": {"year": 1962}}

    def row(self, reply):
        return GW.probe_row(self.req, "body", {"text": json.dumps(reply)})

    def test_named_with_features_and_a_range_holding_the_year_is_consistent(self):
        r = self.row({"content": "typewritten", "typeface": "Courier", "machine": "IBM Selectric",
                      "features": ["slab serifs"], "earliest_year": 1961, "latest_year": 1990})
        self.assertTrue(r["checkable"] and r["consistent"])
        self.assertEqual(r["width"], 29)

    def test_an_earliest_year_after_the_owners_is_inconsistent(self):
        r = self.row({"typeface": "Helvetica", "features": ["flat terminals"], "earliest_year": 1970})
        self.assertTrue(r["checkable"])
        self.assertFalse(r["consistent"])

    def test_no_features_or_no_year_is_not_checkable(self):
        self.assertFalse(self.row({"typeface": "Pica", "features": [], "earliest_year": 1920})["checkable"])
        self.assertFalse(self.row({"typeface": "Pica", "features": ["x"], "earliest_year": None})["checkable"])
        self.assertFalse(GW.probe_row(self.req, "body", {"text": None})["parsed"])


if __name__ == "__main__":
    unittest.main()
