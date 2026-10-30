"""W46.seg-truth-sheet offline tests: the SC0122 control draw, the blind sheet and the weighted fold.
No corpus. Run: python3 -m unittest test_seg_truth_sheet (from this directory)."""
import unittest

import seg_truth_sheet as T


def rows(p_news):
    out = [{"n": 1, "ask": False, "p_new": None, "draft": "Box"}]
    for i, p in enumerate(p_news, 2):
        out.append({"n": i, "ask": p is None, "p_new": p, "draft": "New" if (p or 0) >= 0.5 else "Cont"})
    return out


class Draw(unittest.TestCase):
    def test_strata_cover_zero_to_one(self):
        self.assertEqual(T.stratum_of(0.0), T.STRATA[0][0])
        self.assertEqual(T.stratum_of(0.02), T.STRATA[1][0])
        self.assertEqual(T.stratum_of(0.5), T.STRATA[2][0])
        self.assertEqual(T.stratum_of(1.0), T.STRATA[3][0])

    def test_draw_takes_only_agreed_gaps_is_seeded_and_records_sizes(self):
        r = rows([0.0] * 30 + [0.1] * 30 + [0.7] * 5 + [1.0] * 30 + [None] * 7)
        a, sizes = T.draw_controls(r)
        b, _ = T.draw_controls(r)
        self.assertEqual([x[0]["n"] for x in a], [x[0]["n"] for x in b])
        self.assertFalse(any(x[0]["ask"] for x in a))
        self.assertEqual(sizes[T.STRATA[2][0]], [5, 5])       # a small stratum is taken whole
        self.assertEqual(sizes[T.STRATA[1][0]], [30, 24])
        self.assertEqual(len(a), 12 + 24 + 5 + 12)
        self.assertEqual([x[0]["n"] for x in a], sorted(x[0]["n"] for x in a))


class Fold(unittest.TestCase):
    def test_weighted_error_and_open_cases(self):
        strata = {"lo": [40, 10], "hi": [20, 10]}
        keys = [{"id": f"sc{i:02d}", "section": "sc0122", "current": "Cont", "stratum": "lo"} for i in range(10)]
        keys += [{"id": f"sc{i:02d}", "section": "sc0122", "current": "New", "stratum": "hi"} for i in range(10, 20)]
        keys.append({"id": "st01", "section": "stanton", "current": "Cont"})
        ans = {k["id"]: ("same" if k["current"] == "Cont" else "new") for k in keys}
        ans["sc00"] = "new"           # one error in the heavier stratum: weight 4 of a total 58
        ans["sc10"] = "unsure"        # left out of the rate
        ans["st01"] = "fallback"
        s = T.fold(keys, strata, ans)
        self.assertEqual(s["open"], ["sc10"])
        self.assertAlmostEqual(s["sc0122_agreed_weighted_error"], round(4 / (40 + 9 * 2), 4))
        self.assertEqual(s["sections"]["stanton"], {"answered": 1, "agrees with current truth": 1})


if __name__ == "__main__":
    unittest.main()
