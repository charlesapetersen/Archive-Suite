#!/usr/bin/env python3
"""Tests for marks_read.py's box pairing and text score (synthetic, no record, crop or model)."""
import unittest

import marks_read as R


class Read(unittest.TestCase):
    def test_pairs_one_to_one(self):
        gt = [[0, 0, 0.1, 0.1], [0.1, 0, 0.2, 0.1]]
        self.assertEqual(len(R.pairs(gt, [[0, 0, 0.2, 0.1]], 0.1)), 1)  # one box covering two marks takes one
        self.assertEqual(R.pairs(gt, [[0.1, 0, 0.2, 0.1], [0, 0, 0.1, 0.1]], 0.5), {0: 1, 1: 0})
        self.assertEqual(R.pairs(gt, [[0.5, 0.5, 0.6, 0.6]], 0.1), {})

    def test_nes(self):
        self.assertEqual(R.nes("Rec'd  May 3", "Rec'd May 3"), 1.0)
        self.assertEqual(R.nes("abcd", ""), 0.0)
        self.assertAlmostEqual(R.nes("abcd", "abce"), 0.75)
        self.assertEqual(R.nes("", ""), 1.0)
        self.assertLess(R.nes("Abc", "abc"), 1.0)  # case kept

    def test_boot_bounds(self):
        (lo, hi), (rlo, rhi) = R.boot([("a", 1.0), ("b", 0.0), ("b", 0.5)])
        self.assertTrue(0 <= lo <= hi <= 1 and 0 <= rlo <= rhi <= 1)


if __name__ == "__main__":
    unittest.main()
