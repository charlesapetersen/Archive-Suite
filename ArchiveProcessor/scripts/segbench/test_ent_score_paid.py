#!/usr/bin/env python3
"""Unit tests for ent_score_paid.py's pure helpers (no cache, no gateway): python3 test_ent_score_paid.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import date_tagging as DT  # noqa: E402
import ent_score_paid as P  # noqa: E402


def truth(**fields):
    t = {"id": "d", "sender": [], "recipient": [], "sending_place": []}
    for f, names in fields.items():
        t[f] = [{"name": n, "quote": None, "class": c} for n, c in names]
    return t


class Context(unittest.TestCase):
    def test_round_trip(self):
        ctx = "Doc A: 1951 letter\nDoc B: 1952 memo"
        self.assertEqual(P.context_of(DT.build_prompt("some text", ctx)), ctx)

    def test_none(self):
        self.assertIsNone(P.context_of(DT.build_prompt("some text", None)))


class Parse(unittest.TestCase):
    def test_fenced(self):
        self.assertEqual(P.parse('```json\n{"sender": []}\n```'), {"sender": []})

    def test_bad(self):
        self.assertIsNone(P.parse("no json here"))
        self.assertIsNone(P.parse(None))
        self.assertIsNone(P.parse("[1, 2]"))


class Evidence(unittest.TestCase):
    def test_groups(self):
        tr = {"d": truth(sender=[("Ada Fielding", "named")], recipient=[("Basil Thorne", "role-inferred")])}
        pred = {"d": {"sender": [{"name": "Ada Fielding", "quote": "Ada Fielding"},
                                 {"name": "John Doe", "quote": "Jon Doe"}],
                      "recipient": [{"name": "Basil Thorne", "quote": None}],
                      "sending_place": [{"name": "Chicago, Illinois", "quote": None}]}}
        ev = P.evidence(pred, tr, {"d": "Yours, Ada Fielding"}, 3000)
        self.assertEqual(ev["sender"]["quote in text"], [1, 0])
        self.assertEqual(ev["sender"]["quote not in text"], [0, 1])
        self.assertEqual(ev["recipient"], {})            # an inferred truth's match is set aside
        self.assertEqual(ev["sending_place"]["no quote"], [0, 1])


class Paired(unittest.TestCase):
    def test_sign_and_interval(self):
        ids = [f"d{i}" for i in range(20)]
        tr = {i: {**truth(sender=[("Ada Fielding", "named")]), "id": i} for i in ids}
        a = {i: {"sender": None} for i in ids}
        b = {i: {"sender": "Ada Fielding"} for i in ids}
        r = P.paired(a, b, ids, tr, "sender")
        self.assertEqual(r["n"], 20)
        self.assertAlmostEqual(r["diff"], 1.0)
        self.assertLessEqual(r["lo"], r["diff"])
        self.assertGreaterEqual(r["hi"], r["diff"])
        self.assertEqual(P.paired(a, a, ids, tr, "sender")["diff"], 0.0)


class City(unittest.TestCase):
    def test_both_sides_cut(self):
        tr = {"d": {**truth(), "sending_place": [{"name": "Springfield, IL", "quote": None, "class": "named",
                                                  "alternates": ["Springfield, Illinois"]}]}}
        pc, tc = P.by_city({"d": {"sending_place": [{"name": "Springfield, Illinois", "quote": "SPRINGFIELD"}]}}, tr)
        self.assertEqual(pc["d"]["sending_place"], ["Springfield"])
        self.assertEqual(tc["d"]["sending_place"][0]["name"], "Springfield")
        self.assertEqual(P.doc_counts(tc["d"], pc["d"], "sending_place"), (1, 0, 0))
        self.assertEqual(P.by_city({"d": {"sending_place": None}}, tr)[0]["d"]["sending_place"], [])


if __name__ == "__main__":
    unittest.main()
