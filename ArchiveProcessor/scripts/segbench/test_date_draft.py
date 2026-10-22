#!/usr/bin/env python3
"""Unit tests for date_draft.py's reply parsing and verdicts (W46.fix-date-truth-score). No model, no corpus."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(os.path.dirname(os.path.abspath(__file__)))
import date_draft as D


class Parse(unittest.TestCase):
    def test_fenced_json(self):
        d = D.parse('```json\n{"date_on_page": true, "as_read": "8-3-87", "year": 1987}\n```')
        self.assertEqual((d["date_on_page"], d["year"]), (True, 1987))

    def test_junk_and_out_of_range(self):
        self.assertIsNone(D.parse("no json here"))
        self.assertIsNone(D.parse('{"year": 1987,'))
        d = D.parse('{"date_on_page": true, "as_read": null, "year": 3021}')
        self.assertIsNone(d["year"])
        self.assertFalse(d["date_on_page"])  # neither a year nor a reading

    def test_year_as_string(self):
        self.assertEqual(D.parse('{"date_on_page": true, "as_read": "1958", "year": "1958"}')["year"], 1958)


class Verdict(unittest.TestCase):
    def v(self, read, year, tag):
        return D.verdict(D.parse('{"date_on_page": true, "as_read": %s, "year": %s}'
                                 % ("null" if read is None else '"%s"' % read, year)), tag)

    def test_supported_and_differs(self):
        self.assertEqual(self.v("May 24, 1958", 1958, 1958), "own page (supported)")
        self.assertEqual(self.v("5/24/58", 1958, 1958), "own page (supported)")
        self.assertEqual(self.v("Sept. '58", 1958, 1958), "own page (supported)")
        self.assertEqual(self.v("WED. SEP. 1 1971", 1971, 1975), "page year differs")

    def test_year_not_in_reading(self):
        self.assertEqual(self.v("TUESDAY, MARCH 7", 1984, 1984), "date without a year")
        self.assertEqual(self.v("No. 158", 1958, 1958), "date without a year")
        self.assertEqual(self.v("JUL 31", "null", 1958), "date without a year")

    def test_none_and_unreadable(self):
        self.assertEqual(D.verdict(D.parse('{"date_on_page": false, "as_read": null, "year": null}'), 1958),
                         "no date found")
        self.assertEqual(D.verdict(None, 1958), "unreadable reply")


if __name__ == "__main__":
    unittest.main()
