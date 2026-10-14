#!/usr/local/bin/python3
"""Tests for ocr_truth.py on hand-made tags and readings (no corpus access). /usr/local/bin/python3 test_ocr_truth.py"""
import unittest

import ocr_truth as T


class Strata(unittest.TestCase):
    def test_date_bins(self):
        self.assertEqual(T.date_bin(["1899", "Reports"]), "before 1900")
        self.assertEqual(T.date_bin(["1949"]), "1900-1949")
        self.assertEqual(T.date_bin(["1950"]), "1950-1984")
        self.assertEqual(T.date_bin(["1985"]), "1985 on")
        self.assertEqual(T.date_bin(["1970s"]), "1950-1984")
        self.assertEqual(T.date_bin(["1880s"]), "before 1900")
        self.assertEqual(T.date_bin(["Date Uncertain"]), "undated")
        self.assertEqual(T.date_bin(["Unread", "P10"]), "undated")
        self.assertEqual(T.date_bin(["1990", "1948"]), "1900-1949")   # the earliest of several
        self.assertEqual(T.date_bin(["1970s", "1982"]), "1950-1984")  # a year wins over a decade

    def test_kinds(self):
        self.assertEqual(T.strata(["1960", "Handwritten", "Statistics"]), ["1950-1984", "handwritten", "tables"])
        self.assertEqual(T.strata(["Clippings"]), ["undated", "clippings"])
        self.assertEqual(T.strata(["Salary Data", "1975"]), ["1950-1984", "tables"])


class Documents(unittest.TestCase):
    def test_runs_and_labels(self):
        photos = [("1", ["Red"]), ("2", ["1960", "Unread"]), ("3", ["1960", "Read"]), ("4", ["1961"]),
                  ("5", ["Purple"]), ("6", ["1961"])]
        docs = T.documents("f", photos)
        self.assertEqual([[n for n, _ in d] for d in docs], [["2", "3"], ["4"], ["6"]])

    def test_long_run_cut_into_blocks(self):
        photos = [(str(i), ["Stanford"]) for i in range(T.LONG_RUN + 1)]
        docs = T.documents("f", photos)
        self.assertEqual([len(d) for d in docs], [T.BLOCK, T.BLOCK, 1])

    def test_run_at_the_limit_kept_whole(self):
        photos = [(str(i), ["Stanford"]) for i in range(T.LONG_RUN)]
        self.assertEqual([len(d) for d in T.documents("f", photos)], [T.LONG_RUN])


class Tertile(unittest.TestCase):
    def test_ordinary(self):
        self.assertEqual([T.tertile(v, [10, 20]) for v in (5, 10, 19, 20, 30)], [0, 1, 1, 2, 2])

    def test_one_dominant_value(self):
        self.assertEqual([T.tertile(v, [2592, 2592]) for v in (1296, 2592, 4032)], [0, 1, 2])


class Drafts(unittest.TestCase):
    def test_parse(self):
        d = T.parse_draft("KIND: Typewritten\nTABLE: no\nTEXT:\nDear Harvey:\n  When time permits")
        self.assertEqual(d, {"kind": "typewritten", "table": False, "text": "Dear Harvey:\n  When time permits"})

    def test_parse_fenced_and_table(self):
        d = T.parse_draft("KIND: mixed\nTABLE: yes\nTEXT:\n```\nA | B\n1 | 2\n```")
        self.assertEqual((d["kind"], d["table"], d["text"]), ("mixed", True, "A | B\n1 | 2"))

    def test_parse_rejects(self):
        self.assertIsNone(T.parse_draft("Here is the text: Dear Harvey"))
        self.assertIsNone(T.parse_draft("KIND: cursive\nTABLE: no\nTEXT:\nx"))


class Compare(unittest.TestCase):
    def test_normalisation(self):
        self.assertEqual(T.words("“It’s” — a | b\nc"), ['"It\'s"', "-", "a", "b", "c"])

    def test_spans_and_merge(self):
        a = T.words("The quick brown fox jumps")
        b = T.words("The quiet brown fox leaps over")
        sp = T.spans(a, b)
        self.assertEqual(sp, [{"agreed": "The"}, {"a": "quick", "b": "quiet"}, {"agreed": "brown fox"},
                              {"a": "jumps", "b": "leaps over"}])
        self.assertIsNone(T.merge(sp, {"1": "a"}))                       # one span still open
        self.assertEqual(T.merge(sp, {"1": "a", "3": "b"}), "The quick brown fox leaps over")
        self.assertEqual(T.merge(sp, {"1": "=quick", "3": "="}), "The quick brown fox")  # typed, and typed empty

    def test_identical_readings_need_no_answers(self):
        sp = T.spans(T.words("a b c"), T.words("a  b\nc"))
        self.assertEqual(sp, [{"agreed": "a b c"}])
        self.assertEqual(T.merge(sp, {}), "a b c")


if __name__ == "__main__":
    unittest.main()
