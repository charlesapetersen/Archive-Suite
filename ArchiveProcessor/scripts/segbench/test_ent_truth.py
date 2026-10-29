#!/usr/bin/env python3
"""Unit tests for ent_truth.py's scorer, reply parsing and draft agreement (W46.fix-ent-truth). No model, no corpus."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(os.path.dirname(os.path.abspath(__file__)))
import ent_truth as E


def ent(name, cls="named", quote=None, **kw):
    return {"name": name, "quote": quote, "class": cls, **kw}


def truth(**fields):
    t = {f: [] for f in E.FIELDS}
    t.update(fields)
    return t


class Match(unittest.TestCase):
    def test_tokens_drop_titles_and_order(self):
        self.assertEqual(E.tokens("Mr. John Smith"), E.tokens("Smith, John"))
        self.assertEqual(E.tokens("Hon. Richard M. Nixon"), ("m", "nixon", "richard"))

    def test_levels(self):
        self.assertTrue(E.match("John Smith", "Smith, John", "exact"))
        self.assertFalse(E.match("J. Smith", "John Smith", "exact"))
        self.assertTrue(E.match("J. Smith", "John Smith", "overlap"))
        self.assertTrue(E.match("John Smyth", "John Smith", "ed2"))
        self.assertFalse(E.match("John Smyth", "John Smith", "exact"))
        self.assertFalse(E.match("Mary Jones", "John Smith", "ed2"))
        self.assertTrue(E.match("Bob Smith", "Robert Smith", "exact", alternates=("Bob Smith",)))

    def test_empty_name_never_matches(self):
        self.assertFalse(E.match("Mr.", "John Smith", "overlap"))


class Score(unittest.TestCase):
    def test_hits_misses_and_wrong(self):
        rows = [
            {"truth": truth(sender=[ent("John Smith")]), "pred": {"sender": "Smith, John"}, "text": "John Smith"},
            {"truth": truth(sender=[ent("Mary Jones")]), "pred": {"sender": None}, "text": "x"},
            {"truth": truth(sender=[ent("Ann Lee")]), "pred": {"sender": "Bill Gray"}, "text": "Bill Gray"},
            {"truth": truth(), "pred": {"sender": "Someone Else"}, "text": ""},
        ]
        r = E.score_rows(rows)["sender"]
        self.assertEqual((r["exact"]["tp"], r["exact"]["fp"], r["exact"]["fn"]), (1, 2, 2))
        self.assertEqual(r["null_when_truth"], 1)
        self.assertEqual(r["filled_when_empty"], 1)
        self.assertEqual(r["exact"]["wrong_when_filled_docs"], 2)
        self.assertEqual((r["names"], r["names_in_text"]), (3, 2))

    def test_inferred_is_neither_hit_nor_false_positive(self):
        rows = [{"truth": truth(recipient=[ent("Richard Nixon", "role-inferred")]),
                 "pred": {"recipient": "Richard Nixon"}, "text": "Dear Mr. President"}]
        r = E.score_rows(rows)["recipient"]["exact"]
        self.assertEqual((r["tp"], r["fp"], r["fn"], r["inferred_matched"]), (0, 0, 0, 1))
        self.assertIsNone(r["f1"])

    def test_one_prediction_matches_one_truth(self):
        rows = [{"truth": truth(recipient=[ent("John Smith"), ent("Jane Smith")]),
                 "pred": {"recipient": ["J. Smith", "J. Smith"]}, "text": ""}]
        r = E.score_rows(rows)["recipient"]["overlap"]
        self.assertEqual((r["tp"], r["fp"], r["fn"]), (2, 0, 0))

    def test_quote_validity_ignores_whitespace(self):
        rows = [{"truth": truth(sender=[ent("John Smith")]),
                 "pred": {"sender": [{"name": "John Smith", "quote": "JOHN  SMITH"},
                                     {"name": "John Smith", "quote": "J0HN SMITH"}]},
                 "text": "signed\nJOHN SMITH\n"}]
        r = E.score_rows(rows)["sender"]
        self.assertEqual((r["quotes"], r["quotes_valid"]), (2, 1))


class Parse(unittest.TestCase):
    def test_fenced_and_cleaned(self):
        d = E.parse('```json\n{"is_correspondence": true, "hand": "typed", "dateline": true, "signed": true, '
                    '"role_addressed": false, "sender": [{"name": " John Smith ", "quote": "", "class": "odd"}, '
                    '{"name": ""}], "recipient": null}\n```')
        self.assertEqual(d["sender"], [{"name": "John Smith", "quote": None, "class": "named"}])
        self.assertEqual((d["recipient"], d["sending_place"]), ([], []))

    def test_junk(self):
        self.assertIsNone(E.parse("no json"))
        self.assertIsNone(E.parse(None))
        self.assertIsNone(E.parse("[1, 2]"))


class Agreement(unittest.TestCase):
    def label(self, **kw):
        base = {"is_correspondence": True, "hand": "typed", "dateline": True, "signed": True,
                "role_addressed": False, "sender": [], "recipient": [], "sending_place": []}
        base.update(kw)
        return base

    def test_agree_within_ed2_and_class(self):
        a = self.label(sender=[ent("John Smith")])
        b = self.label(sender=[ent("John Smyth")])
        self.assertEqual(E.disagreements(a, b), [])
        c = self.label(sender=[ent("John Smith", "role-inferred")])
        self.assertEqual(E.disagreements(a, c), ["sender"])

    def test_flags_alone_need_no_ruling(self):
        a, b = self.label(hand="typed"), self.label(hand="mixed")
        self.assertEqual(E.disagreements(a, b), ["hand"])
        self.assertFalse(E.needs_ruling(a, b))
        self.assertTrue(E.needs_ruling(a, self.label(is_correspondence=False)))

    def test_side(self):
        a = self.label(sender=[ent("John Smith")])
        b = self.label(sender=[ent("Mary Jones")])
        self.assertEqual(E.side(b, a, b), "B")
        self.assertEqual(E.side(a, a, b), "A")
        self.assertEqual(E.side(self.label(sender=[ent("Ann Lee")]), a, b), "neither")

    def test_invalid_quote_is_nulled(self):
        lab = self.label(sender=[ent("John Smith", quote="JOHN SMITH"), ent("Ann Lee", quote="ANN LEE")])
        out = E.with_valid_quotes(lab, "from JOHN\nSMITH")
        self.assertEqual([e["quote"] for e in out["sender"]], ["JOHN SMITH", None])


class Strata(unittest.TestCase):
    def test_cues(self):
        letter = "Dear Mr. President:\nI write about the bill and the vote in the senate this week.\nSincerely,"
        self.assertEqual(E.stratum_of(letter), "role-addressed")
        self.assertEqual(E.stratum_of("Dear John,\nI write about the bill and the vote in the senate this week."),
                         "unsigned")
        self.assertIsNone(E.stratum_of("The report of the committee on the budget for the next year."))


if __name__ == "__main__":
    unittest.main()
