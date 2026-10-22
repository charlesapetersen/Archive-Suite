#!/usr/bin/env python3
"""date_truth_sets.py: the truth records from hand-built cases and answers (no cache, no corpus).

    python3 -m unittest test_date_truth_sets
"""
import unittest

import date_truth_sets as T


def case(cid, cls="A", prev=True):
    c = {"id": cid, "doc": "d" + cid, "class": cls, "folder": "F", "this": {"position": 5}}
    if prev:
        c["prev"] = {"position": 4}
    return c


class Parsing(unittest.TestCase):
    def test_date_string_after_colon(self):
        self.assertEqual(T.date_string("Upper right: 11th November 1915"), "11th November 1915")
        self.assertEqual(T.date_string("Stamped Wednesday, September 19, 1975"), "Wednesday, September 19, 1975")
        self.assertIsNone(T.date_string("stamp just below the byline"))

    def test_year_of(self):
        for s, y in (("8-3-87", 1987), ("25.1.73", 1973), ("Sept '69", 1969), ("Sept 10-26", 1926),
                     ("December 10, 1947", 1947), ("8/4/68", 1968), ("Friday 29", None)):
            self.assertEqual(T.year_of(s), y, s)

    def test_location(self):
        self.assertEqual(T.location("Date at top left: May 2, 1960"), "upper left")
        self.assertEqual(T.location("Last line, bottom right"), "lower right, last line")
        self.assertIsNone(T.location("Date: September 5, 1969"))


class Records(unittest.TestCase):
    def test_cover_is_relation_truth(self):
        r = T.truth_record(case("a10"), {"source": "cover"}, {"year": 1968})
        self.assertIs(r["sent_with"], True)
        self.assertIsNone(r["page_date"])

    def test_prev_other_and_note_kept(self):
        r = T.truth_record(case("a27"), {"source": "prev_other", "note": "a reply"}, {"year": 1922, "du": True})
        self.assertIs(r["sent_with"], False)
        self.assertEqual(r["relation"], "reply")
        self.assertEqual(r["note"], "a reply")

    def test_inferred_overrides_basis(self):
        r = T.truth_record(case("a23"), {"source": "unsure", "note": "guessed"}, {"year": 1977, "du": True})
        self.assertEqual(r["basis"], "inferred from neighbours")
        self.assertIsNone(r["sent_with"])

    def test_image_year_conflict_with_tag(self):
        r = T.truth_record(case("d18", "D"), {"source": "image", "kind": "printed or typed",
                                              "note": "Upper right: July 18, 1936"}, {"year": 1935, "du": True})
        self.assertEqual(r["page_date"]["year"], 1936)
        self.assertTrue(any("1936" in c for c in r["conflicts"]))

    def test_page_date_on_other_basis_and_illegible(self):
        r = T.truth_record(case("a19"), {"source": "prev_other", "kind": "printed or typed", "note": "page 2, far left"},
                           {"year": 1968, "du": True})
        self.assertIs(r["sent_with"], False)
        self.assertFalse(r["page_date"]["legible"])
        self.assertIsNone(r["page_date"]["year"])

    def test_later_hand_has_no_page_year(self):
        r = T.truth_record(case("a32"), {"source": "image", "kind": "handwritten", "note": "upper right (Friday 29)"},
                           {"year": 1955, "du": True})
        self.assertEqual(r["page_date"]["as_read"], "Friday 29")
        self.assertIsNone(r["page_date"]["year"])

    def test_note_kind_fills_blank(self):
        r = T.truth_record(case("a07"), {"source": "image", "note": "Handwritten on top: 2/9/78"}, {"year": 1978})
        self.assertEqual(r["page_date"]["kind"], "handwritten")
        self.assertEqual(r["page_date"]["year"], 1978)

    def test_build_counts_every_note_and_unanswered(self):
        cs = [case("a01"), case("a02")]
        t = T.build(cs, {"a01": {"source": "image", "note": "x"}}, {"da01": {"year": 1975}, "da02": {"year": 1987}})
        self.assertEqual(t["notes_carried"], 1)
        self.assertEqual(t["unanswered"], ["a02"])
        self.assertEqual(t["image"], ["a01"])


if __name__ == "__main__":
    unittest.main()
