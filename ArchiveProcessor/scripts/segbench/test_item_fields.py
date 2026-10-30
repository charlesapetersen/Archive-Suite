#!/usr/bin/env python3
"""Unit tests for item_fields.py's parsing, agreement, app mapping and scorer (W47.item-fields-truth). No model, no
corpus."""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(os.path.dirname(os.path.abspath(__file__)))
import item_fields as I


def label(**kw):
    t = {f: ([] if f in I.LISTS else None) for f in I.FIELDS}
    t.update(kw)
    return t


class Parse(unittest.TestCase):
    def test_reading(self):
        r = I.parse('```json\n{"kind": "Newspaper Article", "title": " Peace Talks Stall ", "byline": ["By John '
                    'Smith"], "publication": "null", "publication_date": "1968-07", "recipient_place": []}\n```')
        self.assertEqual(r["kind"], "newspaper article")
        self.assertEqual(r["title"], "Peace Talks Stall")
        self.assertIsNone(r["publication"])
        self.assertEqual(r["publication_date"], (1968, 7, None))

    def test_unknown_kind_is_other_and_bad_date_none(self):
        r = I.parse('{"kind": "brochure", "publication_date": "July 1968"}')
        self.assertEqual(r["kind"], "other")
        self.assertIsNone(r["publication_date"])
        self.assertEqual(I.date_of("1968-13-40"), (1968, None, None))

    def test_think_block_and_garbage(self):
        self.assertEqual(I.parse('<think>{"kind": "memo"}</think>{"kind": "letter"}')["kind"], "letter")
        self.assertIsNone(I.parse("no json here"))


class Agree(unittest.TestCase):
    def test_title_case_and_article_folded(self):
        self.assertTrue(I.agree("title", "The Peace Talks Stall", "peace talks stal"))
        self.assertFalse(I.agree("title", "Peace Talks Stall", "Budget Passes"))
        self.assertTrue(I.agree("title", None, None))
        self.assertFalse(I.agree("title", None, "Budget Passes"))

    def test_lists_need_same_names(self):
        self.assertTrue(I.agree("byline", ["John Smith"], ["Smith, John"]))
        self.assertFalse(I.agree("byline", ["John Smith"], ["John Smith", "Ann Lee"]))

    def test_disputes(self):
        a = label(kind="letter", recipient_place=["Boston, Massachusetts"])
        b = label(kind="memo", recipient_place=["Boston, Massachusetts"])
        self.assertEqual(I.disputes(a, b), ["kind"])


class Match(unittest.TestCase):
    def test_dates_at_truth_precision(self):
        self.assertTrue(I.date_match((1968, 7, 4), (1968, 7, None), "exact"))
        self.assertFalse(I.date_match((1968, None, None), (1968, 7, None), "exact"))
        self.assertTrue(I.date_match((1968, 7, 5), (1968, 7, 4), "ed2"))
        self.assertFalse(I.date_match((1968, 7, 5), (1968, 7, 4), "exact"))

    def test_kind_levels(self):
        self.assertTrue(I.kind_match("telegram", "letter", "ed2"))
        self.assertFalse(I.kind_match("telegram", "letter", "exact"))
        self.assertTrue(I.kind_match("clipping", "newspaper article", "ed2"))

    def test_app_kind(self):
        self.assertEqual(I.app_kind("Newspaper clipping"), "newspaper article")
        self.assertEqual(I.app_kind("memorandum"), "memo")
        self.assertEqual(I.app_kind("article"), "clipping")
        self.assertEqual(I.app_kind("brochure"), "other")
        self.assertIsNone(I.app_kind(None))


class Score(unittest.TestCase):
    def test_counts(self):
        pairs = [(label(publication="New York Times"), label(publication="The New York Times")),
                 (label(publication="Boston Globe"), label(publication="New York Times")),
                 (label(publication="Time"), label()),
                 (label(), label(publication="Life")),
                 (label(), label())]
        s = I.score(pairs, "publication")
        self.assertEqual((s["docs"], s["truth_filled"], s["pred_filled"]), (5, 3, 3))
        self.assertEqual((s["exact"], s["ed2"]), (1, 1))
        self.assertEqual(s["wrong_when_filled"], 2)
        self.assertEqual(s["filled_when_empty"], 1)
        self.assertEqual(s["null_when_truth"], 1)
        self.assertAlmostEqual(s["precision_ed2"], 1 / 3)
        self.assertAlmostEqual(s["recall_ed2"], 1 / 3)

    def test_scope_and_verdict(self):
        pairs = [(label(), label(kind="letter", byline=[])), (label(), label(kind="report", byline=["A B"]))]
        self.assertEqual(len(I.scoped(pairs, "byline")), 1)
        self.assertEqual(I.verdict({"truth_filled": 5, "precision_ed2": 1.0}), "too few to tell")
        self.assertEqual(I.verdict({"truth_filled": 30, "precision_ed2": 0.95}), "fill")
        self.assertEqual(I.verdict({"truth_filled": 30, "precision_ed2": 0.5}), "leave empty")


class AppReading(unittest.TestCase):
    def test_reply_fields(self):
        import tempfile
        import date_tagging as DT
        reply = {"year": "1968", "month": "07 July", "day": "Day 4", "format": "newspaper article",
                 "author_name": "Alfred D. Cook", "recipient_location": None, "publication_name": "Wall Street Journal"}
        with tempfile.TemporaryDirectory() as d:
            old = DT.answer_path
            DT.answer_path = lambda prompt, label: os.path.join(d, "a.json")
            try:
                with open(os.path.join(d, "a.json"), "w") as fh:
                    json.dump({"candidates": [{"content": {"parts": [{"text": json.dumps(reply)}]}}]}, fh)
                r = I.app_reading("p", None)
            finally:
                DT.answer_path = old
        self.assertEqual(r["kind"], "newspaper article")
        self.assertEqual(r["byline"], ["Alfred D. Cook"])
        self.assertEqual(r["publication"], "Wall Street Journal")
        self.assertEqual(r["publication_date"], (1968, 7, 4))
        self.assertEqual(r["recipient_place"], [])
        self.assertIsNone(r["title"])


if __name__ == "__main__":
    unittest.main()
