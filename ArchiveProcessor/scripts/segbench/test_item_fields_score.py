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


    def test_typed_answer_read_by_hand_keeps_the_draw(self):
        r = row("d", reading(kind="magazine article", publication_date=(1969, None, None)),
                reading(kind="magazine article"), kind="magazine article")
        key = {"d:more-publication_date": {"doc": "d", "part": "draw", "field": "publication_date",
                                           "options": ["gemini"]}}
        (t,), _ = S.fold([r], key, {"d:more-publication_date": "=Summer 1969"},
                         {"d": {"answer": {"publication_date": [1969, None, None]}}})
        self.assertEqual(t["label"]["publication_date"], (1969, None, None))
        self.assertEqual(t["owner"]["publication_date"], "draw")

    def test_merge_fixes_keeps_both_sheets(self):
        m = S.merge_fixes({"d": {"set": {"title": "A"}, "drop": ["byline"], "themes": ["x"]}},
                          {"d": {"set": {"publication": "B"}, "drop": ["kind"], "themes": ["x", "y"]},
                           "e": {"answer": {"publication_date": [1970, None, None]}}})
        self.assertEqual(m["d"]["set"], {"title": "A", "publication": "B"})
        self.assertEqual(m["d"]["drop"], ["byline", "kind"])
        self.assertEqual(m["d"]["themes"], ["x", "y"])
        self.assertEqual(m["e"]["answer"], {"publication_date": [1970, None, None]})

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



def trow(i, title, how=None, kind="magazine article"):
    lab = reading(kind=kind, title=title)
    return {"id": i, "part": "base", "label": lab, "owner": {"title": how} if how else {}, "unknown": []}


class Stratified(unittest.TestCase):
    """A census of 10 hard pairs (5 right) and a pool of 90 the image prompt filled, 10 of them drawn (all right)."""
    def setUp(self):
        self.frows = [trow(f"c{i}", "T", "dispute") for i in range(10)]
        self.frows += [trow(f"p{i}", "T", "draw" if i < 10 else None) for i in range(90)]
        self.gem = {t["id"]: reading(title="T" if t["id"] in {f"c{i}" for i in range(5)} or t["id"][0] == "p"
                                     else "Wrong") for t in self.frows}

    def test_census_at_its_share_and_the_pool_from_the_draw(self):
        st = S.stratified(self.gem, self.gem, self.frows, "title", set())
        self.assertEqual(st["census"], [5, 10])
        self.assertEqual(st["pool"]["image prompt filled"], [90, 10, 10])
        self.assertAlmostEqual(st["precision"], 95 / 100)
        lo, hi = S.wilson(10, 10)
        self.assertAlmostEqual(st["lo"], (5 + 90 * lo) / 100)
        self.assertAlmostEqual(st["hi"], (5 + 90 * hi) / 100)

    def test_an_undrawn_part_widens_the_interval_not_the_point(self):
        other = {t["id"]: reading(title="T") for t in self.frows}
        gem = dict(self.gem)
        for i in range(10, 20):
            gem[f"p{i}"] = reading()        # the image prompt empty here, the other route filled: never drawn
        st = S.stratified(other, gem, self.frows, "title", set())
        self.assertEqual(st["pool"]["image prompt empty"], [10, 0, 0])
        self.assertAlmostEqual(st["precision"], 90 / 90)
        self.assertAlmostEqual(st["lo"], (10 + 80 * S.wilson(10, 10)[0]) / 100)

    def test_draws_to_fill_counts_right_readings(self):
        st = S.stratified(self.gem, self.gem, self.frows, "title", set())
        x = S.draws_to_fill(st)
        N, n, k = st["pool"]["image prompt filled"]
        ok = lambda y: (5 + N * S.wilson(k + y, n + y)[0]) / 100 >= S.LOWER  # noqa: E731
        self.assertTrue(ok(x))
        self.assertFalse(ok(x - 1))


class RuleStratified(unittest.TestCase):
    def s(self, right, filled, true):
        return {"docs": max(filled, true), "ed2": right, "pred_filled": filled, "truth_filled": true,
                "precision_ed2": right / filled if filled else None}

    def test_strat_overrides_the_pooled_figure_and_agreement(self):
        pooled = self.s(30, 40, 40)                 # the hard-leaning pool: below the bar alone
        st = {"precision": 0.95, "lo": 0.88, "hi": 0.98}
        self.assertEqual(S.verdict(pooled, strat=st), "fill")
        self.assertEqual(S.verdict(pooled, strat={"precision": 0.8, "lo": 0.7, "hi": 0.88},
                                   agreement=self.s(99, 100, 100)), "below the bar")

    def test_truth_error_lowers_the_fill_bound(self):
        self.assertEqual(S.verdict(self.s(98, 100, 100)), "fill")
        self.assertEqual(S.verdict(self.s(98, 100, 100), err_hi=0.2), "too close")

if __name__ == "__main__":
    unittest.main()
