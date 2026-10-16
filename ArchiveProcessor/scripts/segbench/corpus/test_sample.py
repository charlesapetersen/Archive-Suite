#!/usr/bin/env python3
"""Tests for sample.py's draw logic (no network). python3 test_sample.py"""
import collections
import unittest

import sample as S


def pool(spec):
    """spec: {collection: n} -> candidate rows."""
    return [{'source': 'src', 'collection': c, 'page_id': f'{c}-{i:03d}'} for c, n in spec.items() for i in range(n)]


class Draw(unittest.TestCase):
    def test_order_is_seeded_and_input_order_free(self):
        rows = pool({'a': 30, 'b': 30})
        self.assertEqual(S.order(rows, 'L1'), S.order(list(reversed(rows)), 'L1'))
        self.assertNotEqual(S.order(rows, 'L1'), S.order(rows, 'L2'))

    def test_quarter_cap_holds_when_collections_allow(self):
        got = S.choose(S.order(pool({c: 50 for c in 'abcde'}), 'L1'), 80, set())
        self.assertEqual(len(got), 80)
        self.assertLessEqual(max(collections.Counter(r['collection'] for r in got).values()), 20)
        self.assertFalse(any(r['over_cap'] for r in got))

    def test_shortfall_is_filled_and_marked(self):
        got = S.choose(S.order(pool({'a': 100, 'b': 5}), 'L1'), 40, set())
        self.assertEqual(len(got), 40)
        self.assertEqual(sum(not r['over_cap'] for r in got), 15)   # 10 of a (cap) + all 5 of b
        self.assertTrue(all(r['collection'] == 'a' for r in got if r['over_cap']))

    def test_drop_is_replaced_from_further_down(self):
        rows = S.order(pool({c: 50 for c in 'abcde'}), 'L1')
        first = S.choose(rows, 80, set())
        gone = first[3]['source'] + ':' + first[3]['page_id']
        second = S.choose(rows, 80, {gone})
        keys = lambda rr: [r['source'] + ':' + r['page_id'] for r in rr]
        self.assertNotIn(gone, keys(second))
        self.assertEqual(len(second), 80)
        self.assertEqual(len(set(keys(first)) & set(keys(second))), 79)


if __name__ == '__main__':
    unittest.main()
