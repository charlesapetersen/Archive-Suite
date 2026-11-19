#!/usr/bin/env python3
"""Checks for dewarp_placement: the carry-back through a lattice, the raw fill, the chunked runs and the paired
figure on the lines both arms score."""
import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dewarp_placement as D  # noqa: E402
from place_geom import identity_map  # noqa: E402


def lattice(fn, gh=9, gw=7):
    """A (gh, gw, 2) lattice whose node at output (u, v) holds source fn(u, v)."""
    u, v = np.meshgrid(np.linspace(0, 1, gw), np.linspace(0, 1, gh))
    return np.stack(fn(u, v), -1)


def word(text, x, y, w=0.1, h=0.04, line=0):
    q = [[x, y], [x + w, y], [x + w, y + h], [x, y + h]]
    return {'text': text, 'quad': q, 'line': line, 'box': [x, y, w, h]}


class CarryBack(unittest.TestCase):
    def test_identity_lattice_keeps_quads(self):
        g = lattice(lambda u, v: (u, v))
        fw = [word('a', 0.2, 0.3), word('b', 0.4, 0.3)]
        lines, words, filled = D.placed_words(g, [{'words': [0, 1]}], fw, [], [])
        self.assertEqual(filled, 0)
        self.assertEqual([w['text'] for w in words], ['a', 'b'])
        np.testing.assert_allclose(words[0]['quad'], fw[0]['quad'], atol=1e-9)

    def test_lattice_shrinks_into_source_and_fills_unshown_raw_words(self):
        # the flattened image shows the source's middle half only (x in 0.25..0.75)
        g = lattice(lambda u, v: (0.25 + 0.5 * u, v))
        fw = [word('mid', 0.4, 0.5)]
        raw = [word('mid', 0.45, 0.5, w=0.05), word('edge', 0.05, 0.5, w=0.05, line=1)]
        rl = [{'words': [0]}, {'words': [1]}]
        lines, words, filled = D.placed_words(g, [{'words': [0]}], fw, rl, raw)
        self.assertEqual(filled, 1)                       # 'edge' is outside the lattice, kept from the raw reading
        self.assertEqual([w['text'] for w in words], ['mid', 'edge'])
        self.assertAlmostEqual(words[0]['quad'][0][0], 0.25 + 0.5 * 0.4)
        self.assertEqual(len(lines), 2)


class Chunks(unittest.TestCase):
    def test_level_line_is_one_run(self):
        ws = [word(t, 0.1 + 0.12 * i, 0.5) for i, t in enumerate('abcd')]
        runs = D.chunk_lines(identity_map(1000, 1000), [{'words': [0, 1, 2, 3]}], ws)
        self.assertEqual([r['text'] for r in runs], ['a b c d'])

    def test_bent_line_splits_where_the_run_grows_tall(self):
        ys = [0.50, 0.505, 0.53, 0.545]                    # a word height 0.04: the third word pushes past 1.4 heights
        ws = [word(t, 0.1 + 0.12 * i, y) for i, (t, y) in enumerate(zip('abcd', ys))]
        runs = D.chunk_lines(identity_map(1000, 1000), [{'words': [0, 1, 2, 3]}], ws)
        self.assertEqual([r['text'] for r in runs], ['a b', 'c d'])
        self.assertAlmostEqual(runs[0]['box'][1], 0.50)


class Paired(unittest.TestCase):
    def test_common_lines_only(self):
        x = {'arms': {'route': {'lines': {'b1': True, 'b2': False, 'b3': False}},
                      'p': {'lines': {'b2': True, 'b3': True, 'b9': True}}}}
        self.assertEqual(D.common(x, 'p'), (2, 2, 0))
        s = D.paired([x], 'p')
        self.assertEqual((s['lines'], s['arm'], s['route'], s['delta'][0]), (2, 100.0, 0.0, 100.0))


class Variants(unittest.TestCase):
    def test_names(self):
        self.assertEqual((D.base('dvd.r2'), D.uses_quad('dvd.r2')), ('dvd', True))
        self.assertEqual((D.base('dvd.noquad'), D.uses_quad('dvd.noquad')), ('dvd', False))
        self.assertTrue(D.uses_quad('uvdoc'))
        arms = ['route', 'dvd-copy', 'dvd.r2-copy', 'dvd.noquad-copy', 'dvd.r3-guarded', 'uvdoc-copy']
        self.assertEqual(D.runs_of(arms, 'dvd'), ['dvd', 'dvd.r2', 'dvd.r3'])

    def test_no_quad_passes_the_whole_image(self):
        img = np.zeros((4, 6, 3), np.uint8)
        g = lattice(lambda u, v: (u, v))
        out, grid, found = D.after_quad(img, {'found': True, 'corners': [[0.2, 0.2], [0.8, 0.2], [0.8, 0.8],
                                                                           [0.2, 0.8]]},
                                        lambda im: (im, g), use_quad=False)
        self.assertEqual((out.shape, found), (img.shape, False))
        np.testing.assert_array_equal(grid, g)

    def test_floor_pairs_runs_and_counts_changed_lines(self):
        def row(r1, r2):
            return {'arms': {'route': {'n': 2, 'lines': {'b1': True, 'b2': True}},
                             'dvd-copy': {'lines': r1}, 'dvd.r2-copy': {'lines': r2}}}
        xs = [row({'b1': True, 'b2': False}, {'b1': True, 'b2': True}),
              row({'b1': False, 'b2': False}, {'b1': False, 'b2': False})]
        f = D.floor(xs, ['dvd', 'dvd.r2'])
        self.assertEqual(list(f), ['dvd.r2-copy vs dvd-copy'])
        s = f['dvd.r2-copy vs dvd-copy']
        self.assertEqual((s['lines'], s['lines_changed'], s['delta'][0], s['better'], s['worse']), (4, 1, 25.0, 1, 0))


if __name__ == '__main__':
    unittest.main()
