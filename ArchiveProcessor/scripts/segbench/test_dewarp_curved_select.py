#!/usr/bin/env python3
"""Checks for dewarp_curved_select's arithmetic: the pooled paired delta, the per-page delta and the pair gap."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dewarp_curved_select as D  # noqa: E402


def row(key, group, route, uvdoc, guard, pair=None, cls='bound'):
    arms = {'route': {'n': route[1], 'pass': route[0], 'broken': 0, 'cut': 0},
            'uvdoc': {'n': uvdoc[1], 'pass': uvdoc[0], 'broken': 0, 'cut': uvdoc[1] - uvdoc[0] if guard else 1}}
    arms['guarded'] = arms['uvdoc' if guard else 'route']
    return {'key': key, 'group': group, 'pair': pair, 'class': cls, 'guard_pass': guard, 'arms': arms}


class Arithmetic(unittest.TestCase):
    def test_guarded_falls_back_to_route(self):
        xs = [row('a', 'curved', (5, 10), (10, 10), True), row('b', 'curved', (8, 10), (0, 10), False)]
        s = D.summary(xs)
        self.assertEqual(s['guard_pass'], 1)
        self.assertEqual(s['route']['pass'], 65.0)
        self.assertEqual(s['guarded']['pass'], 90.0)
        self.assertEqual(s['uvdoc']['pass'], 50.0)
        self.assertEqual(s['guarded']['pooled_delta'][0], 25.0)
        self.assertEqual(s['guarded']['page_delta'][0], 25.0)   # (+50 + 0) / 2
        self.assertEqual((s['guarded']['better'], s['guarded']['worse']), (1, 0))
        self.assertEqual(s['passing_only']['pages'], 1)

    def test_pages_without_lines_are_left_out(self):
        xs = [row('a', 'curved', (5, 10), (10, 10), True), row('z', 'curved', (0, 0), (0, 0), True)]
        self.assertEqual(D.summary(xs)['pages'], 1)

    def test_pair_gap(self):
        c = [row('c1', 'curved', (6, 10), (9, 10), True), row('c2', 'curved', (4, 10), (4, 10), False)]
        f = [row('f1', 'flat', (10, 10), (10, 10), True, pair='c1'), row('f2', 'flat', (8, 10), (8, 10), False, pair='c2'),
             row('f9', 'flat', (8, 10), (8, 10), False, pair='missing')]
        g = D.pair_gap(c, f, 'route')
        self.assertEqual(g['pairs'], 2)
        self.assertEqual(g['mean'][0], -40.0)                  # (-40 + -40) / 2
        self.assertEqual(D.pair_gap(c, f, 'guarded')['mean'][0], -25.0)   # (-10 + -40) / 2


if __name__ == '__main__':
    unittest.main()
