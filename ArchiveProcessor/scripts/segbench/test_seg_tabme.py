"""W46.seg-tabme: stream order, OCR text and the per-document scorer, synthetic inputs only."""
import json
import random
import unittest

import seg_tabme as T
from score import derived, score_labels


class Stream(unittest.TestCase):
    def test_pages_sorted_within_contiguous_documents(self):
        rows = [("a", 2), ("a", 0), ("a", 1), ("b", 0), ("c", 1), ("c", 0)]
        self.assertEqual([(d, p) for d, p, _ in T.order(rows)],
                         [("a", 0), ("a", 1), ("a", 2), ("b", 0), ("c", 0), ("c", 1)])
        self.assertEqual([i for _, _, i in T.order(rows)], [1, 2, 0, 3, 5, 4])

    def test_split_or_gapped_documents_refused(self):
        with self.assertRaises(SystemExit):
            T.order([("a", 0), ("b", 0), ("a", 1)])
        with self.assertRaises(SystemExit):
            T.order([("a", 0), ("a", 2)])

    def test_ocr_lines_in_order_blank_lines_dropped(self):
        raw = json.dumps({"lines_data": [{"Word": "Dear Sir"}, {"Word": "  "}, {"Word": "Yours"}], "words_data": []})
        self.assertEqual(T.ocr_text(raw), "Dear Sir\nYours")


class Scorer(unittest.TestCase):
    def test_per_document_sums_agree_with_the_bench_scorer(self):
        rng = random.Random(7)
        for _ in range(200):
            n = rng.randrange(2, 40)
            truth = ["New"] + [rng.choice(["New", "Cont"]) for _ in range(n - 1)]
            pred = ["New"] + [rng.choice(["New", "Cont"]) for _ in range(n - 1)]
            m = T.metrics(T.per_doc(truth, pred))
            d = derived(score_labels(truth, pred))
            self.assertEqual(m["documents"], truth.count("New"))
            self.assertAlmostEqual(m["pages_exact"], d["pages_in_exact_doc"])
            self.assertEqual((m["false_splits"], m["false_merges"]), (d["false_splits"], d["false_merges"]))
            if d["boundary_f1"] is not None:
                self.assertAlmostEqual(m["boundary_f1"], d["boundary_f1"])
            self.assertAlmostEqual(m["doc_f1"], d["doc_f1"] or 0.0)

    def test_perfect_and_degenerate(self):
        truth = ["New", "Cont", "New", "New", "Cont", "Cont"]
        m = T.metrics(T.per_doc(truth, truth))
        self.assertEqual((m["boundary_f1"], m["pages_exact"], m["page_f1"], m["doc_f1"]), (1.0, 1.0, 1.0, 1.0))
        m = T.metrics(T.per_doc(truth, ["New"] + ["Cont"] * 5))
        self.assertEqual((m["boundary_f1"], m["pages_exact"]), (0.0, 0.0))
        self.assertAlmostEqual(m["page_f1"], 2 / (2 + 2))   # page 1 forced right, two first pages missed

    def test_bootstrap_identical_arms_pair_to_zero(self):
        truth = ["New", "Cont", "New", "New", "Cont", "New", "Cont", "Cont", "New"]
        pred = ["New", "New", "New", "Cont", "Cont", "New", "Cont", "New", "New"]
        rows = T.per_doc(truth, pred)
        cis, paired = T.bootstrap({"a": rows, "b": list(rows)}, draws=200)
        self.assertEqual(paired["b - a"]["boundary_f1"], [0.0, 0.0])
        lo, hi = cis["a"]["pages_exact"]
        self.assertLessEqual(lo, T.metrics(rows)["pages_exact"])
        self.assertGreaterEqual(hi, T.metrics(rows)["pages_exact"])


if __name__ == "__main__":
    unittest.main()
