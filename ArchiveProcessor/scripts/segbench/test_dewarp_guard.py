#!/usr/bin/env python3
"""W46.dewarp-guard: the pure parts of dewarp_guard.py (no gateway, no Vision, no UVDoc).

  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy \
      python -m unittest test_dewarp_guard
"""
import unittest

import numpy as np

import dewarp_guard as D


def row(key, group, passed, n, pair=None):
    return {'key': key, 'group': group, 'pair': pair, 'route': 'raw', 'blla_failed': False,
            'arms': {'raw': {'blla_pass': passed, 'blla_n': n}}}


class Parse(unittest.TestCase):
    GOOD = ('{"page": "bound", "lines_bent": true, "perspective": "mild", "display_type": false, '
            '"handwritten": "none", "note": "gutter"}')

    def test_fenced_reply(self):
        self.assertEqual(D.parse('```json\n' + self.GOOD + '\n```')['page'], 'bound')

    def test_rejects_unknown_value(self):
        self.assertIsNone(D.parse(self.GOOD.replace('"bound"', '"spiral"')))

    def test_rejects_string_bool(self):
        self.assertIsNone(D.parse(self.GOOD.replace('true', '"yes"')))

    def test_empty(self):
        self.assertIsNone(D.parse(None))
        self.assertIsNone(D.parse('no json here'))

    def test_bent(self):
        self.assertTrue(D.bent({'page': 'curled'}))
        self.assertFalse(D.bent({'page': 'flat'}))
        self.assertFalse(D.bent(None))


class Gap(unittest.TestCase):
    def test_pooled_and_paired(self):
        pairs = [(row('c1', 'curved', 5, 10), row('f1', 'flat', 10, 10)),
                 (row('c2', 'curved', 30, 30), row('f2', 'flat', 20, 20))]
        g = D.gap(pairs, draws=200)
        self.assertEqual(g['curved'][:2], [35, 40])
        self.assertEqual(g['flat'][:2], [30, 30])
        self.assertAlmostEqual(g['diff'][0], -12.5, places=1)
        self.assertAlmostEqual(g['paired'][0], -25.0, places=1)   # (-50 + 0) / 2
        self.assertEqual(g['worse'], 1)

    def test_empty(self):
        self.assertIsNone(D.gap([]))


class OwnSheet(unittest.TestCase):
    QUAD = [[0.1, 0.1], [0.9, 0.1], [0.9, 0.9], [0.1, 0.9]]

    def test_split(self):
        words = [(0, np.array([0.5, 0.5]), 'a'),    # shown
                 (0, np.array([0.95, 0.5]), 'b'),   # cut, outside the quad, but its line is shown: own
                 (1, np.array([0.5, 0.2]), 'c'),    # cut, inside the quad: own
                 (2, np.array([0.97, 0.3]), 'd')]   # cut, outside, nothing of its line shown: neighbour
        shown = np.array([True, False, False, False])
        own, neigh = D.split_lost(words, shown, self.QUAD)
        self.assertEqual(own, [1, 2])
        self.assertEqual(neigh, [3])

    def test_nothing_lost(self):
        words = [(0, np.array([0.5, 0.5]), 'a')]
        self.assertEqual(D.split_lost(words, np.array([True]), self.QUAD), ([], []))


class Aligned(unittest.TestCase):
    def test_skips_unaligned_and_multi_token(self):
        words = [(0, np.zeros(2), 'the'), (0, np.zeros(2), None), (0, np.zeros(2), 'cat'),
                 (1, np.zeros(2), 'zzz'), (1, np.zeros(2), 'sat')]
        self.assertEqual(D.aligned(words, ['the', 'cat', 'sat']), [0, 2, 4])


class MeanCI(unittest.TestCase):
    def test_constant(self):
        self.assertEqual(D.mean_ci([0.01] * 5, draws=50), [1.0, 1.0, 1.0])

    def test_empty(self):
        self.assertIsNone(D.mean_ci([]))


if __name__ == '__main__':
    unittest.main()
