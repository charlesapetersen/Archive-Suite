"""W46.seg-truth-rescore offline tests: the fold of the owner's rulings and the SC0122 controls' error.
No corpus. Run: python3 -m unittest test_seg_truth_rescore (from this directory)."""
import unittest

import seg_truth_rescore as R

RULINGS = [
    {"id": "st01", "section": "stanton", "left": 1, "right": 2, "current": "Cont", "answer": "new"},
    {"id": "st02", "section": "stanton", "left": 2, "right": 3, "current": "Cont", "answer": "same"},
    {"id": "cr01", "section": "crest", "left": 1, "right": 2, "current": "Cont", "answer": "unsure"},
    {"id": "cr02", "section": "crest", "left": 2, "right": 3, "current": "New", "answer": "same"},
    {"id": "cr03", "section": "crest", "left": 3, "right": 4, "current": "New", "answer": "new"},
]


def manifest():
    return {"pages": [{"n": i, "label": lab, "audit": f"a{i}"} for i, lab in enumerate(["New", "Cont", "New", "New"], 1)]}


class Fold(unittest.TestCase):
    def test_manifest_takes_differing_rulings_and_lists_unsure_once(self):
        m = R.fold_manifest(manifest(), RULINGS, "crest")
        self.assertEqual([p["label"] for p in m["pages"]], ["New", "Cont", "Cont", "New"])
        self.assertIn("cr02", m["pages"][2]["audit"])
        self.assertTrue(m["pages"][2]["audit"].endswith("a3"))
        self.assertEqual(m["unsure"], [{"id": "cr01", "left": 1, "right": 2}])
        again = R.fold_manifest(m, RULINGS, "crest")
        self.assertEqual(again["pages"][2]["audit"], m["pages"][2]["audit"])   # idempotent

    def test_csv_changes_only_the_ruled_rows(self):
        text = "File Number,Status\r\n1,New\r\n2,Cont\r\n3,Cont\r\n"
        self.assertEqual(R.fold_csv(text, RULINGS), "File Number,Status\r\n1,New\r\n2,New\r\n3,Cont\r\n")
        self.assertEqual(R.fold_csv(R.fold_csv(text, RULINGS), RULINGS), R.fold_csv(text, RULINGS))

    def test_an_unknown_answer_is_refused(self):
        with self.assertRaises(ValueError):
            R.changes([{"id": "x", "section": "crest", "left": 1, "right": 2, "current": "New", "answer": "earlier"}],
                      "crest")


class Controls(unittest.TestCase):
    def test_weighted_and_unweighted_with_kish(self):
        strata = {"a": [30, 10], "b": [10, 10]}
        rows = [{"section": "sc0122", "stratum": "a", "current": "Cont", "answer": "same"} for _ in range(10)]
        rows += [{"section": "sc0122", "stratum": "b", "current": "Cont", "answer": "same"} for _ in range(9)]
        rows += [{"section": "sc0122", "stratum": "b", "current": "Cont", "answer": "new"}]
        r = R.sc0122(rows, strata)
        self.assertEqual((r["controls"], r["errors"], r["agreed_gaps"]), (20, 1, 40))
        self.assertAlmostEqual(r["unweighted"], 0.05)
        self.assertAlmostEqual(r["weighted"], 1 / 40)
        self.assertAlmostEqual(r["kish_n"], 40 * 40 / (10 * 9 + 10))
        lo, hi = r["unweighted_wilson"]
        self.assertTrue(lo < 0.05 < hi)

    def test_zero_errors_still_has_an_upper_bound(self):
        lo, hi = R.wilson(0, 60)
        self.assertEqual(lo, 0.0)
        self.assertAlmostEqual(hi, 0.0602, places=3)


if __name__ == "__main__":
    unittest.main(verbosity=1)
