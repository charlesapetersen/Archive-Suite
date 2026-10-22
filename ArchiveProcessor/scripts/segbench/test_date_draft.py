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


class Audit(unittest.TestCase):
    """W46.date-draft-audit: the second reader over every page, and the call that combines the two readers."""
    def page(self, k, reply):
        return {"page": k, "parsed": D.parse(reply)}

    NONE = '{"date_on_page": false, "as_read": null, "year": null}'

    def test_box(self):
        self.assertEqual(D.box_of({"box": [100, 200, 300, 250]}), [0.1, 0.2, 0.2, 0.05])
        self.assertIsNone(D.box_of({"box": [300, 200, 100, 250]}))   # x2 before x1
        self.assertIsNone(D.box_of({"box": [0, 0, 1200, 50]}))       # pixels, not thousandths
        self.assertIsNone(D.box_of({"box": None}))
        self.assertIsNone(D.box_of({"box": [1, 2, 3]}))

    def test_later_page_supports(self):
        v, rs = D.second_reading([self.page(1, self.NONE),
                                  self.page(2, '{"date_on_page": true, "as_read": "May 3, 1975", "year": 1975}')], 1975)
        self.assertEqual((v, [r["page"] for r in rs]), ("own page (supported)", [2]))

    def test_differs_and_supplied_year(self):
        v, _ = D.second_reading([self.page(1, '{"date_on_page": true, "as_read": "1971", "year": 1971}')], 1975)
        self.assertEqual(v, "page year differs")
        v, rs = D.second_reading([self.page(1, '{"date_on_page": true, "as_read": "MARCH 7", "year": 1975}')], 1975)
        self.assertEqual((v, rs[0]["year"]), ("date without a year", None))  # a year it supplied is no reading

    def test_incomplete(self):
        self.assertEqual(D.second_reading([self.page(1, self.NONE), None], 1975)[0], "not read")
        self.assertEqual(D.second_reading([], 1975)[0], "not read")
        self.assertEqual(D.second_reading([{"page": 1, "parsed": None}], 1975)[0], "unreadable reply")

    def test_outcome(self):
        self.assertEqual(D.outcome("page year differs", "own page (supported)"), "supported by the second reader")
        self.assertEqual(D.outcome("no date found", "page year differs"), "disputed: to the owner")
        self.assertEqual(D.outcome("page year differs", "no date found"), "disputed: to the owner")
        self.assertEqual(D.outcome("no date found", "date without a year"), "no year on the page: tag unsupported")
        self.assertEqual(D.outcome("page year differs", "not read"), "not audited")

    def test_sheet_choices_hide_the_tag(self):
        r = {"id": "x", "pages": 2, "owner_year": 1975,
             "first_draft": D.parse('{"date_on_page": true, "as_read": "1971", "year": 1971, "where": "top"}'),
             "second_readings": [{"page": 2, "as_read": "1957", "year": 1957, "where": "foot", "box": [0, 0, .1, .1]}]}
        s = D.sheet_items([r])[0]
        self.assertEqual(s["choices"], [1957, 1971, 1975])   # numeric order: the tag is not marked
        self.assertNotIn("owner", str(s))
        self.assertEqual([p["page"] for p in s["pages"]], [1, 2])
        self.assertIsNone(s["pages"][0]["marks"][0]["box"])    # the first reader's mark falls back to its words


if __name__ == "__main__":
    unittest.main()
