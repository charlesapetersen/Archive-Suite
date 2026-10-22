#!/usr/bin/env python3
"""date_pool.py: the year masker and the stratified allocation (no cache, no corpus).

    python3 -m unittest test_date_pool
"""
import unittest

import date_pool as P


class Mask(unittest.TestCase):
    def test_every_written_form(self):
        t = P.mask_year("Convocation 5/24/58, FRESHMAN 1958, class of '58; 24.5.58", 1958)
        self.assertNotIn("1958", t)
        self.assertNotIn("58", t)

    def test_other_years_and_numbers_kept(self):
        t = P.mask_year("Class of 1962, 158 students, page 58, in 1958", 1958)
        self.assertIn("1962", t)
        self.assertIn("158 students", t)
        self.assertIn("page 58", t)


class Allocate(unittest.TestCase):
    def test_equal_when_all_large(self):
        self.assertEqual(P.allocate({"A": 100, "B": 100}, 50), {"A": 25, "B": 25})

    def test_small_class_gives_its_rest(self):
        a = P.allocate({"A": 5, "B": 100, "C": 100}, 60)
        self.assertEqual(a["A"], 5)
        self.assertEqual(sum(a.values()), 60)

    def test_never_more_than_available(self):
        self.assertEqual(P.allocate({"A": 3, "B": 2}, 50), {"A": 3, "B": 2})


if __name__ == "__main__":
    unittest.main()
