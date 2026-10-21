"""W46.fix-seg-scorers: the document-count prior and the rank statistic on hand-made streams.
Run: <lab venv>/bin/python test_rescore.py   (no bench data, no cache, no network)."""
import unittest

from methods import Prediction
from rescore import count_prior, spearman, truth_docs

B, F, N, C = "Box", "Folder", "New", "Cont"


def pred(labels, p_new):
    """A prediction whose gap i has P(new) = p_new[i]; the decision follows it."""
    bounds = [{"decision": "new" if p >= 0.5 else "continue", "confidence": max(p, 1 - p)} for p in p_new]
    return Prediction(labels, bounds)


class CountPrior(unittest.TestCase):
    def test_keeps_the_most_probable_boundaries(self):
        truth = [F, N, C, N, C, C]          # one stream, two documents
        p = pred(truth, [1.0, 0.2, 0.9, 0.6, 0.4])
        # count 2: one document-gap boundary beyond the stream's start, the most probable (gap 2)
        self.assertEqual(count_prior(truth, p, 2), [F, N, C, N, C, C])
        # count 3: gaps 2 and 3
        self.assertEqual(count_prior(truth, p, 3), [F, N, C, N, N, C])

    def test_photo_gaps_are_not_counted_and_streams_open_documents(self):
        truth = [F, N, C, F, N, C]          # two streams
        p = pred(truth, [1.0, 0.7, 1.0, 1.0, 0.8])
        # count 2 = the two streams' first documents: no document-gap boundary at all
        self.assertEqual(count_prior(truth, p, 2), [F, N, C, F, N, C])
        self.assertEqual(count_prior(truth, p, 3), [F, N, C, F, N, N])  # gap 4 (0.8) beats gap 1 (0.7)
        self.assertEqual(count_prior(truth, p, 1), [F, N, C, F, N, C])  # never fewer than the streams

    def test_no_confidences_means_no_prior(self):
        truth = [N, C, C]
        self.assertIsNone(count_prior(truth, Prediction(truth, [{"decision": "continue", "confidence": None}] * 2), 2))

    def test_truth_docs(self):
        self.assertEqual(truth_docs([B, F, C, C, N, F, N]), 3)  # an orphan Cont opens a document


class Rank(unittest.TestCase):
    def test_spearman(self):
        self.assertAlmostEqual(spearman([1, 2, 3, 4], [10, 20, 30, 40]), 1.0)
        self.assertAlmostEqual(spearman([1, 2, 3, 4], [4, 3, 2, 1]), -1.0)
        self.assertAlmostEqual(spearman([1, 2, 2, 3], [1, 2, 2, 3]), 1.0)   # ties take mean ranks
        self.assertIsNone(spearman([1, 2], [1, 2]))


if __name__ == "__main__":
    unittest.main()
