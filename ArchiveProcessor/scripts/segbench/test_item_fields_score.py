"""item_fields_score.py: reading an answer, the fold (a note's set and drop, a kind change, an ignored dispute the
owner's kind brings in scope), the random controls' error, and the fill rule. No corpus or cache is touched."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import item_fields_score as S  # noqa: E402


def reading(**kw):
    r = {"kind": None, "title": None, "byline": [], "publication": None, "publication_date": None,
         "recipient_place": []}
    r.update(kw)
    return r


def row(i, gemini, luna, **kw):
    r = {"id": i, "part": "base", **reading(**kw), "readers": {"gemini": gemini, "luna": luna}, "disputed": [],
         "field_sides": {}}
    return r


class Answer(unittest.TestCase):
    def setUp(self):
        self.r = row("d", reading(kind="letter", publication="PTT"), reading(kind="memo", publication="Times"),
                     kind="letter", publication="PTT")

    def test_pick_reading(self):
        k = {"part": "dispute", "field": "publication", "options": ["luna", "gemini"]}
        self.assertEqual(S.answer_value(k, "1", self.r), ("value", "Times"))
        self.assertEqual(S.answer_value(k, "2", self.r), ("value", "PTT"))

    def test_kind_and_control_and_typed(self):
        self.assertEqual(S.answer_value({"part": "kind", "field": "kind", "options": ["memo", "letter"]}, "1",
                                        self.r), ("value", "memo"))
        self.assertEqual(S.answer_value({"part": "random", "field": "publication", "options": ["truth"]}, "1",
                                        self.r), ("value", "PTT"))
        self.assertEqual(S.answer_value({"part": "random", "field": "publication_date", "options": ["truth"]},
                                        "=1973-08-31", self.r), ("value", (1973, 8, 31)))
        self.assertEqual(S.answer_value({"part": "random", "field": "byline", "options": ["truth"]}, "=", self.r),
                         ("value", []))

    def test_cant_tell_and_unanswered(self):
        k = {"part": "dispute", "field": "publication", "options": ["luna", "gemini"]}
        self.assertEqual(S.answer_value(k, "?", self.r), ("cant", None))
        self.assertEqual(S.answer_value(k, None, self.r), (None, None))


class Fold(unittest.TestCase):
    def test_kind_to_printed_leaves_new_fields_unknown_unless_given(self):
        r = row("d", reading(kind="letter"), reading(kind="newspaper article", byline=["Fred Hargadon"],
                                                      title="A letter"), kind="letter")
        key = {"d:0": {"doc": "d", "part": "kind", "field": "kind", "options": ["letter", "newspaper article"]},
               # out of scope for the truth's kind (a letter), in scope for the owner's
               "d:1": {"doc": "d", "part": "dispute", "field": "byline", "options": ["gemini", "luna"],
                       "ignore": "byline is out of scope"}}
        fixes = {"d": {"set": {"publication": "Palo Alto Times", "publication_date": "1970-05-15"}}}
        (t,), _ = S.fold([r], key, {"d:0": "2", "d:1": "2"}, fixes)
        self.assertEqual(t["label"]["kind"], "newspaper article")
        self.assertEqual(t["label"]["publication"], "Palo Alto Times")
        self.assertEqual(t["label"]["publication_date"], (1970, 5, 15))
        self.assertEqual(t["label"]["byline"], ["Fred Hargadon"])
        self.assertEqual(t["unknown"], ["title"])
        self.assertEqual(t["owner"], {"kind": "kind", "byline": "ignored", "publication": "note",
                                      "publication_date": "note"})

    def test_ignored_dispute_stays_out_when_kind_unchanged(self):
        r = row("d", reading(kind="letter"), reading(kind="letter", byline=["X"]), kind="letter")
        key = {"d:0": {"doc": "d", "part": "dispute", "field": "byline", "options": ["gemini", "luna"],
                       "ignore": "out of scope"}}
        (t,), _ = S.fold([r], key, {"d:0": "2"}, {})
        self.assertEqual(t["owner"], {})
        self.assertEqual(t["label"]["byline"], [])

    def test_note_drop_overrides_an_answer(self):
        r = row("d", reading(kind="magazine article", title="A"), reading(kind="magazine article", title="B"),
                kind="magazine article", title="A")
        key = {"d:0": {"doc": "d", "part": "dispute", "field": "title", "options": ["gemini", "luna"]}}
        (t,), _ = S.fold([r], key, {"d:0": "1"}, {"d": {"drop": ["title"]}})
        self.assertIn("title", t["unknown"])
        self.assertNotIn("title", t["owner"])


class TruthError(unittest.TestCase):
    def test_note_answers_an_open_control(self):
        r = row("d", reading(kind="report"), reading(kind="report"), kind="report")
        key = {"d:0": {"doc": "d", "part": "random", "field": "publication_date", "options": ["truth"],
                       "filled": False, "stratum_pairs": 50}}
        _, chk = S.fold([r], key, {}, {"d": {"set": {"publication_date": "1973-08-31"}}})
        got, open_ = S.truth_error([r], key, chk)
        self.assertEqual((len(got), open_), (1, 0))
        self.assertTrue(got[0][3])     # wrong: the agreed empty date has a value

    def test_weighting_by_stratum(self):
        got = [("base", "kind", True, True, 300), ("base", "title", True, False, 100)]
        e = S.error_summary(got)
        self.assertAlmostEqual(e["weighted"], 0.75)
        self.assertEqual((e["wrong"], e["answered"]), (1, 2))


class Rule(unittest.TestCase):
    def s(self, right, filled, true):
        return {"docs": max(filled, true), "ed2": right, "pred_filled": filled, "truth_filled": true,
                "precision_ed2": right / filled if filled else None}

    def test_fill_needs_floor_lower_bound_and_point(self):
        self.assertEqual(S.verdict(self.s(98, 100, 100)), "fill")
        self.assertEqual(S.verdict(self.s(39, 39, 39)), "too close (n 39)")
        self.assertEqual(S.verdict(self.s(50, 100, 100)), "below the bar")
        self.assertEqual(S.verdict(self.s(88, 100, 100)), "too close")
        self.assertEqual(S.verdict(self.s(0, 0, 10)), "never filled")

    def test_truth_error_widens_below_the_bar(self):
        self.assertEqual(S.verdict(self.s(80, 100, 100)), "below the bar")
        self.assertEqual(S.verdict(self.s(80, 100, 100), err_hi=0.05), "too close")

    def test_family_route_below_only_when_agreement_is_too(self):
        hard = self.s(29, 38, 38)
        self.assertEqual(S.verdict(hard), "below the bar")
        self.assertEqual(S.verdict(hard, agreement=self.s(248, 268, 268)), "too close (n 38)")
        self.assertEqual(S.verdict(hard, agreement=self.s(58, 118, 87)), "below the bar")


if __name__ == "__main__":
    unittest.main()
