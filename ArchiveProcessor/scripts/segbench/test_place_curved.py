#!/usr/bin/env python3
"""W46.place-curved-owner: the pure geometry of place_curved.py (no Vision, no blla, no PDF).

  ~/.local/share/visionocr-ocrlab/venv-kraken/bin/python -m unittest test_place_curved
"""
import math
import unittest

import place_curved as P


def line(x0, y0, x1, y1, h=0.02, words=()):
    """A Vision line from its bottom-left to bottom-right corner, height h above it (upright page)."""
    q = [[x0, y0 - h], [x1, y1 - h], [x1, y1], [x0, y0]]
    return {'quad': q, 'text': ' '.join(words) or 'x', 'words': [{'text': w, 'quad': q} for w in words]}


class Turns(unittest.TestCase):
    def test_turn_points_cw(self):
        # a clockwise quarter turn sends the top-left corner to the top-right
        self.assertEqual(P.turn_points([[0, 0]], 1), [[1, 0]])
        self.assertEqual(P.turn_points([[0.2, 0.3]], 4), [[0.2, 0.3]])

    def test_sideways_page_is_turned_once(self):
        # text running bottom to top (as UIUC 00233 is stored) needs one clockwise turn
        # quad order is tl, tr, br, bl relative to the text: bottom-left (index 3) to bottom-right (index 2) runs
        # straight up the stored image
        d = {'width': 4032, 'height': 3024,
             'lines': [{'quad': [[x - 0.02, 0.8], [x - 0.02, 0.2], [x, 0.2], [x, 0.8]], 'text': 't', 'words': []}
                       for x in (0.1, 0.15, 0.2)]}
        self.assertEqual(P.quarter_turns(d), 1)
        up, k = P.upright(d)
        self.assertEqual((k, up['width'], up['height']), (1, 3024, 4032))
        q = up['lines'][0]['quad']
        self.assertAlmostEqual(math.degrees(math.atan2((q[2][1] - q[3][1]) * up['height'],
                                                       (q[2][0] - q[3][0]) * up['width'])), 0, places=6)

    def test_upright_page_untouched(self):
        d = {'width': 100, 'height': 140, 'lines': [line(0.1, 0.2 + i / 20, 0.9, 0.2 + i / 20) for i in range(5)]}
        self.assertEqual(P.quarter_turns(d), 0)


class Cues(unittest.TestCase):
    def test_level_text_has_low_fill_and_spread(self):
        d = {'width': 1000, 'height': 1400,
             'lines': [line(0.1, 0.1 + i * 0.03, 0.9, 0.1 + i * 0.03, h=0.02) for i in range(20)]}
        c = P.cues(d)
        self.assertAlmostEqual(c['spread'], 0, places=6)
        self.assertAlmostEqual(c['fill'], 0.02 / 0.03, places=3)

    def test_fanning_lines_have_spread(self):
        # line angle grows down the page, as on a bound page's curl
        d = {'width': 1000, 'height': 1400,
             'lines': [line(0.1, 0.1 + i * 0.04, 0.9, 0.1 + i * 0.04 + i * 0.004) for i in range(20)]}
        self.assertGreater(P.cues(d)['spread'], 5)


class Drag(unittest.TestCase):
    def test_vertical_mid_and_along(self):
        poly = [[0, 0.4], [1, 0.5], [1, 0.6], [0, 0.5]]
        self.assertAlmostEqual(P.vertical_mid(poly, 0.0), 0.45)
        self.assertAlmostEqual(P.vertical_mid(poly, 0.5), 0.5)
        self.assertIsNone(P.vertical_mid(poly, 1.5))
        bl = [[0, 0.5], [0.5, 0.5], [1, 0.6]]
        self.assertLess(P.along(bl, (0.2, 0.5)), P.along(bl, (0.8, 0.58)))

    def test_blla_expected_orders_and_skips(self):
        def w(t, x, y):
            return {'text': t, 'box': [x, y, 0.05, 0.02]}
        vwords = [w('b', 0.4, 0.29), w('a', 0.1, 0.29), w('c', 0.1, 0.59), w('d', 0.5, 0.59), w('e', 0.1, 0.8)]
        blines = [{'baseline': [[0, 0.31], [1, 0.31]], 'boundary': [[0, 0.27], [1, 0.27], [1, 0.33], [0, 0.33]]},
                  # two overlapping boundaries share 'c' and 'd': skipped as shared
                  {'baseline': [[0, 0.61], [1, 0.61]], 'boundary': [[0, 0.57], [1, 0.57], [1, 0.63], [0, 0.63]]},
                  {'baseline': [[0, 0.62], [1, 0.62]], 'boundary': [[0, 0.58], [1, 0.58], [1, 0.64], [0, 0.64]]},
                  {'baseline': [[0, 0.82], [1, 0.82]], 'boundary': [[0, 0.78], [1, 0.78], [1, 0.84], [0, 0.84]]},
                  {'baseline': [[0, 0.95], [1, 0.95]], 'boundary': [[0, 0.93], [1, 0.93], [1, 0.97], [0, 0.97]]}]
        out, skipped = P.blla_expected(blines, vwords)
        self.assertEqual([(i, ws) for i, ws, _ in out], [(0, [1, 0])])
        self.assertEqual(skipped, {'empty': 1, 'short': 1, 'shared': 2})


if __name__ == '__main__':
    unittest.main()
