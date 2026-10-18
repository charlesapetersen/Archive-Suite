#!/usr/bin/env python3
"""public_dates.py reads a catalogue title's date as the catalogue states it, and its targets parse as the app parses.

    python3 -m unittest test_public_dates
"""
import json
import unittest

import date_tagging as D
import public_dates as P

LINCOLN = "Abraham Lincoln papers: Series 1. General Correspondence. 1833-1916: "


class CatalogueDate(unittest.TestCase):
    def check(self, title, want):
        got, _ = P.date_of(title)
        self.assertEqual(got and (got["year"], got["month"], got["day"], got["supplied"]), want, title)

    def test_full_dates(self):
        self.check(LINCOLN + "John Hay to Abraham Lincoln, Monday, May 20, 1861 (Telegram)", (1861, 5, 20, False))
        self.check(LINCOLN + "A. B. to Abraham Lincoln, Sept. 3, 1862", (1862, 9, 3, False))
        self.check("Carrie Chapman Catt Papers: Speech and Article File, 1892-1946; Speeches; "
                   "\"Be Joyful Today,\" Feb 13, 1920", (1920, 2, 13, False))
        self.check("Catt; 1902, 24 Feb., \"Are Homogeneous Divorce Laws in All the States Desirable?\"", (1902, 2, 24, False))
        self.check("Gladstone: pass Billy Smith to Petersburg, Va., 4 June 1863", (1863, 6, 4, False))

    def test_year_in_the_part_before(self):
        self.check("Susan B. Anthony Papers: Speeches and Writings, 1848-1895; 1853; Apr. 17 , Maine Law", (1853, 4, 17, False))

    def test_month_and_year(self):
        self.check(LINCOLN + "Edward D. Baker to Abraham Lincoln, February 1861 (Recommends Cameron)", (1861, 2, None, False))
        self.check("Letter from Leonard Bernstein to Helen Coates, April 1939", (1939, 4, None, False))

    def test_supplied(self):
        self.check(LINCOLN + "Joshua Speed to Abraham Lincoln, [March 1861]", (1861, 3, None, True))
        self.check("Terrell Papers: Speeches and Writings, 1866-1953; [ 1929 ], \"The Question Mark\"", (1929, None, None, True))

    def test_left_out(self):
        for t in ("Garfield Papers: Series 1, Diaries, 1848-1881; Vols. 19-21, 1879, Oct.-1881, July",
                  "Dickinson Papers: Speeches and Writings File, 1868-1907; Speeches; Andrew Johnson, undated",
                  "Stanton Papers: General Correspondence, 1814-1928; 1870-1878",
                  "Wilson Papers; 89, 1916-1917 , Mar.",
                  "Federal Theatre: Accent on Youth"):
            self.check(t, None)

    def test_folders(self):
        self.assertTrue(P.FOLDER.search(P.tail_of("Correspondence, John A. Lomax, February 1935, Lomax papers")))
        self.assertTrue(P.FOLDER.search(P.tail_of("Anthony Papers: Daybook and Diaries, 1856-1906; Diaries 1871")))
        self.assertFalse(P.FOLDER.search(P.tail_of(LINCOLN + "John Hay to Abraham Lincoln, Monday, May 20, 1861")))


class Target(unittest.TestCase):
    def test_round_trip(self):
        for truth in ({"year": 1861, "month": 5, "day": 20, "supplied": False},
                      {"year": 1929, "month": None, "day": None, "supplied": True}):
            resp = {"candidates": [{"content": {"parts": [{"text": P.target_of(truth)}]}}]}
            year, month, du, ok = D.app_parse(resp)
            self.assertTrue(ok)
            self.assertEqual((int(year), month, P.reply_day(resp), du),
                             (truth["year"], truth["month"], truth["day"], truth["supplied"]))

    def test_reply_day_shapes(self):
        for v, want in (("Day 15", 15), (15, 15), ("15", 15), (None, None), ("Day 40", None), (True, None)):
            resp = {"candidates": [{"content": {"parts": [{"text": json.dumps({"year": "1900", "day": v})}]}}]}
            self.assertEqual(P.reply_day(resp), want, v)

    def test_corpus_target_loses_only_the_day(self):
        t = D.target_of({"year": 1972, "month": 3, "du": False})
        self.assertEqual(json.loads(P.without_day(t)), {"year": "1972", "month": "03 March", "date_uncertain": False})

    def test_split_is_by_project(self):
        self.assertEqual(P.split_of("Letters to Lincoln/1864: Civil War"), P.split_of("Letters to Lincoln/1864: Civil War"))
        self.assertIn(P.split_of("x"), ("train", "val", "test"))


if __name__ == "__main__":
    unittest.main()
