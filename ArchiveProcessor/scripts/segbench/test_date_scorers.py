#!/usr/bin/env python3
"""date_scorers.py: the dating scorer changes of the W46 gap audit, on hand-built rows.

    python3 -m unittest test_date_scorers
"""
import math
import unittest

import date_scorers as S


def row(year=None, y=None, du=False, du_pred=False, parsed=True, decade=None, lo=None, hi=None):
    truth = {"decade": decade, "du": du} if decade is not None else {"year": year, "du": du}
    r = {"truth": truth, "y": y, "du_pred": du_pred, "parsed": parsed}
    if y is not None:
        r["lo"], r["hi"] = (lo if lo is not None else y), (hi if hi is not None else y)
    return r


class Accuracy(unittest.TestCase):
    def test_invalid_rate_counts_unparsed_and_yearless(self):
        rows = [row(1960, 1960), row(1960, None), row(1960, None, parsed=False)]
        self.assertEqual(S.invalid_rate(rows), [2, 3])

    def test_tolerance_curve_keeps_no_year_in_the_denominator(self):
        rows = [row(1960, 1960), row(1960, 1962), row(1960, None)]
        self.assertEqual(S.tolerance_curve(rows, kmax=2), [[1, 3], [1, 3], [2, 3]])

    def test_decade_is_an_interval(self):
        self.assertEqual(S.interval_distance(1965, *S.truth_interval({"decade": 1960})), 0)
        self.assertEqual(S.interval_distance(1971, *S.truth_interval({"decade": 1960})), 2)
        self.assertEqual(S.interval_distance(1957, *S.truth_interval({"decade": 1960})), 3)
        self.assertIsNone(S.interval_distance(None, 1960, 1969))

    def test_tolerance_widens_an_estimated_year(self):
        self.assertEqual(S.truth_interval({"year": 1960}, tolerance=1), (1959, 1961))
        self.assertEqual(S.mean_distance([row(1960, 1963), row(1960, None)], tolerance=1), (2.0, 1))


class DateUncertain(unittest.TestCase):
    def test_two_error_rates(self):
        rows = [row(1960, 1960, du=False, du_pred=True), row(1960, 1960, du=False, du_pred=False),
                row(1960, 1960, du=True, du_pred=False), row(1960, 1960, du=True, du_pred=True),
                row(decade=1960, y=1965, du_pred=False)]
        e = S.du_error_rates(rows)
        self.assertEqual(e["certain_flagged_uncertain"], [1, 2])
        self.assertEqual(e["uncertain_flagged_certain"], [1, 2])

    def test_constant_certain_is_not_80_percent_right(self):
        rows = [row(1960, 1960, du=False)] * 8 + [row(1960, 1960, du=True)] * 2
        e = S.du_error_rates(rows)
        self.assertEqual(e["certain_flagged_uncertain"], [0, 8])
        self.assertEqual(e["uncertain_flagged_certain"], [2, 2])


class Evidence(unittest.TestCase):
    CTX = {"self": "Enclosure: report on the budget", "n-1": "Dear Sir, I e n c l o s e the report. June 3, 1962"}

    def test_valid_neighbour_quote_with_spacing(self):
        v, _ = S.evidence_check(1962, {"neighbour": "n-1", "quote": "June 3,1962"}, self.CTX)
        self.assertEqual(v, "valid")

    def test_right_year_wrong_neighbour_is_unsupported(self):
        self.assertEqual(S.evidence_check(1962, {"neighbour": "n-2", "quote": "June 3, 1962"}, self.CTX)[0],
                         "unsupported")

    def test_quote_not_in_text(self):
        self.assertEqual(S.evidence_check(1962, {"neighbour": "n-1", "quote": "July 4, 1962"}, self.CTX)[0],
                         "unsupported")

    def test_quote_without_the_year(self):
        self.assertEqual(S.evidence_check(1962, {"neighbour": "n-1", "quote": "I enclose the report"}, self.CTX)[0],
                         "unsupported")

    def test_self_quote_and_none(self):
        self.assertEqual(S.evidence_check(1962, {"quote": "report"}, self.CTX)[0], "unsupported")
        self.assertEqual(S.evidence_check(1962, None, self.CTX)[0], "none")
        self.assertEqual(S.evidence_check(None, {"neighbour": "n-1", "quote": "1962"}, self.CTX)[0], "unsupported")

    def test_region(self):
        self.assertEqual(S.evidence_check(1962, {"region": "RECEIVED JUN 5 1962"}, self.CTX)[0], "valid")
        self.assertEqual(S.evidence_check(1962, {"region": "RECEIVED"}, self.CTX)[0], "unsupported")
        self.assertEqual(S.evidence_check(1962, {"region": "Jun 5 1963"}, self.CTX)[0], "unsupported")


class Conformal(unittest.TestCase):
    def test_too_few_per_half(self):
        self.assertIsNone(S.conformal([row(1960, 1960)] * 29))
        self.assertIsNotNone(S.conformal([row(1960, 1960)] * 30))

    def test_quantile_rank(self):
        self.assertEqual(S._quantile(list(range(1, 20)), 0.1), 18)   # ceil(0.9 * 20) = 18th smallest
        self.assertEqual(S._quantile([1, 2, 3], 0.1), math.inf)      # ceil(0.9 * 4) = 4 > 3

    def test_point_answers_widened_to_coverage(self):
        # errors 0..3 years, each ten times: a 90% interval must reach +-3 and cover everything
        rows = [row(1960, 1960 + e) for e in range(4) for _ in range(10)]
        c = S.conformal(rows, alpha=0.1)
        self.assertEqual(c["coverage"], [40, 40])
        self.assertEqual(c["q"], [3, 3])
        self.assertEqual(c["width"], 6)
        self.assertEqual(c["no_year"], 0)

    def test_no_year_is_uncovered_not_widthless_credit(self):
        rows = [row(1960, 1960)] * 30 + [row(1960, None)] * 10
        c = S.conformal(rows, alpha=0.5)
        self.assertEqual(c["no_year"], 10)
        self.assertEqual(c["coverage"][1], 40)
        self.assertLess(c["coverage"][0], 40)

    def test_winkler(self):
        self.assertEqual(S.winkler(1960, 1962, 1961, 0.1), 2)
        self.assertAlmostEqual(S.winkler(1960, 1962, 1964, 0.1), 2 + 20 * 2)


if __name__ == "__main__":
    unittest.main()
