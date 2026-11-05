#!/usr/bin/env python3
"""Tests for marks_detect.py's matching and scoring (synthetic boxes, no record or model)."""
import unittest

import marks_detect as D


class Matching(unittest.TestCase):
    def test_iou(self):
        self.assertAlmostEqual(D.iou([0, 0, 1, 1], [0, 0, 1, 1]), 1.0)
        self.assertEqual(D.iou([0, 0, 0.1, 0.1], [0.5, 0.5, 0.6, 0.6]), 0.0)
        self.assertAlmostEqual(D.iou([0, 0, 0.2, 0.1], [0.1, 0, 0.3, 0.1]), 1 / 3)

    def test_one_to_one(self):
        # One prediction covering two truth boxes matches only one of them.
        gt = [[0, 0, 0.1, 0.1], [0.1, 0, 0.2, 0.1]]
        hit, n = D.match(gt, [[0, 0, 0.2, 0.1]], 0.1)
        self.assertEqual((len(hit), n), (1, 1))
        # Two predictions on one truth box: one matches, the other stays unmatched.
        hit, n = D.match(gt[:1], [[0, 0, 0.1, 0.1], [0, 0, 0.1, 0.1]], 0.5)
        self.assertEqual((len(hit), n), (1, 1))

    def test_threshold(self):
        gt = [[0, 0, 0.2, 0.1]]
        self.assertEqual(len(D.match(gt, [[0.1, 0, 0.3, 0.1]], 0.5)[0]), 0)
        self.assertEqual(len(D.match(gt, [[0.1, 0, 0.3, 0.1]], 0.1)[0]), 1)


class Scoring(unittest.TestCase):
    T = {"a": dict(core="A-core", marks=[dict(box=[0, 0, 0.1, 0.1], cls="stamp", overlaps=False)]),
         "b": dict(core="B-core", marks=[dict(box=[0.5, 0.5, 0.6, 0.6], cls="annotation", overlaps=True),
                                         dict(box=[0.7, 0.7, 0.8, 0.8], cls="stamp", overlaps=False)]),
         "c": dict(core="B-core", marks=[])}

    def test_counts(self):
        preds = {"a": [[0, 0, 0.1, 0.1]], "b": [[0.5, 0.5, 0.6, 0.6], [0.2, 0.2, 0.3, 0.3]], "c": [[0, 0, 1, 1]]}
        s = D.score(self.T, preds, dict(pages="all"))["iou50"]
        a = s["all"]
        self.assertEqual((a["recall"]["found"], a["recall"]["of"]), (2, 3))
        self.assertEqual((a["touching_print"]["found"], a["touching_print"]["of"]), (1, 1))
        self.assertEqual(a["by_class"]["stamp"]["found"], 1)
        self.assertEqual((a["predictions"], a["precision"]), (4, 0.5))
        self.assertEqual(s["A-core"]["recall"]["rate"], 1.0)
        self.assertEqual(s["B-core"]["pages"], 2)

    def test_a_core_only_arm(self):
        s = D.score(self.T, {}, dict(pages="A-core"))["hit"]
        self.assertEqual(s["all"]["pages"], 1)
        self.assertIsNone(s["B-core"])

    def test_missing_page_is_no_prediction(self):
        s = D.score(self.T, {}, dict(pages="all"))["hit"]["all"]
        self.assertEqual((s["recall"]["found"], s["predictions"], s["precision"]), (0, 0, None))

    def test_bootstrap_bounds(self):
        rows = [dict(marks=[("x", False, True)]), dict(marks=[("x", False, False)])]
        lo, hi = D.boot(rows, lambda s: D.ratio(s, lambda c, o: True))
        self.assertTrue(0 <= lo <= 0.5 <= hi <= 1)


if __name__ == "__main__":
    unittest.main()
