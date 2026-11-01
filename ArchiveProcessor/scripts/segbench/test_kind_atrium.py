#!/usr/bin/env python3
"""Synthetic checks for kind_atrium.py (W46.kind-atrium): no corpus, no model, no cache.

  /usr/local/bin/python3 test_kind_atrium.py      (numpy needed)
"""
import os
import tempfile
import unittest

os.environ['KIND_ATRIUM_CACHE'] = tempfile.mkdtemp(prefix='kind-atrium-test-')
import numpy as np        # noqa: E402
import kind_atrium as K   # noqa: E402


def probs(**kw):
    p = np.full(len(K.CLASSES), 0.001)
    for c, v in kw.items():
        p[K.CLASSES.index(c)] = v
    return p / p.sum()


class Mapping(unittest.TestCase):
    def test_classes_read_as_ours(self):
        self.assertEqual(K.hand_argmax('TEXT_T'), 'typewritten')
        self.assertEqual(K.hand_argmax('LINE_P'), 'printed')
        self.assertEqual(K.hand_argmax('TEXT_HW'), 'handwritten')
        self.assertEqual(K.hand_argmax('TEXT'), 'mixed')
        self.assertEqual(K.hand_argmax('PHOTO'), 'none')
        self.assertEqual(K.hand_argmax('DRAW_L'), 'none')

    def test_hand_only_skips_mixed_and_pictures(self):
        self.assertEqual(K.hand_only(probs(TEXT=.6, PHOTO=.2, TEXT_P=.15, TEXT_T=.05)), ('printed', False))

    def test_hand_only_reports_a_form(self):
        self.assertEqual(K.hand_only(probs(LINE_HW=.5, TEXT_HW=.4)), ('handwritten', True))

    def test_hand6_is_the_six_text_classes(self):
        self.assertEqual(sorted(K.CLASSES[j] for j in K.HAND6),
                         ['LINE_HW', 'LINE_P', 'LINE_T', 'TEXT_HW', 'TEXT_P', 'TEXT_T'])

    def test_public_kinds_all_mapped(self):
        self.assertEqual(set(K.PUBLIC_HAND), {'typed', 'print', 'newspaper', 'handwritten', 'ledger'})
        self.assertTrue(set(K.PUBLIC_HAND.values()) <= set(K.KINDS3))


class Stats(unittest.TestCase):
    def test_wilson_contains_the_rate(self):
        lo, hi = K.wilson(90, 100)
        self.assertTrue(lo < .9 < hi)
        self.assertAlmostEqual(lo, .825, places=2)

    def test_wilson_at_the_edge(self):
        lo, hi = K.wilson(10, 10)
        self.assertLess(lo, 1)
        self.assertAlmostEqual(hi, 1)

    def test_mcnemar_counts_only_discordant_pages(self):
        a = [True, True, False, True, False]
        b = [True, False, False, False, True]
        x, y, p = K.mcnemar(a, b)
        self.assertEqual((x, y), (2, 1))
        self.assertAlmostEqual(p, 1.0)

    def test_mcnemar_one_sided_split(self):
        x, y, p = K.mcnemar([True] * 10, [False] * 10)
        self.assertEqual((x, y), (10, 0))
        self.assertAlmostEqual(p, 2 / 2 ** 10)

    def test_mcnemar_no_discordance(self):
        self.assertEqual(K.mcnemar([True, False], [True, False]), (0, 0, 1.0))

    def test_auc(self):
        self.assertEqual(K.auc([.9, .8, .1], [True, True, False]), 1.0)
        self.assertEqual(K.auc([.1, .9], [True, False]), 0.0)
        self.assertEqual(K.auc([.5, .5], [True, False]), 0.5)
        self.assertTrue(K.auc([.5], [True]) != K.auc([.5], [True]))   # nan when one side is empty

    def test_head_fits_separable_data(self):
        rng = np.random.default_rng(0)
        X = np.vstack([rng.normal(0, 1, (20, 5)), rng.normal(4, 1, (20, 5))])
        y = np.array([0] * 20 + [1] * 20)
        groups = [f'g{i % 5}' for i in range(40)]
        self.assertGreaterEqual((K.lofo(X, y, 2, groups) == y).mean(), .95)
        self.assertGreaterEqual((K.fit_all(X, y, 2)(X) == y).mean(), .95)


if __name__ == '__main__':
    unittest.main()
