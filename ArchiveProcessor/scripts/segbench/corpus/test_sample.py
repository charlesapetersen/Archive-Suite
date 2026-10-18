#!/usr/bin/env python3
"""Tests for sample.py's draw logic (no network). python3 test_sample.py"""
import collections
import unittest

import sample as S


def pool(spec):
    """spec: {collection: n} -> candidate rows."""
    return [{'source': 'src', 'collection': c, 'page_id': f'{c}-{i:03d}'} for c, n in spec.items() for i in range(n)]


class Draw(unittest.TestCase):
    def test_freeze_extends_but_refuses_changed_or_missing_old_page(self):
        import tempfile
        from pathlib import Path
        from unittest import mock
        import common as C
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            a = {f: '' for f in S.MANIFEST_FIELDS}
            a.update(source='a', page_id='1', stratum='L5', publish_image=True)
            b = {**a, 'source': 'b', 'stratum': 'N2'}
            with mock.patch.multiple(S, RESULTS=root / 'results', DRAW=root / 'draw.jsonl', DROPS=root / 'drops.jsonl'):
                C.write_jsonl(S.DRAW, [a]); S.cmd_freeze()
                original = (S.RESULTS / 'manifest.jsonl').read_bytes()
                C.write_jsonl(S.DRAW, [a, b]); S.cmd_freeze()
                extended = (S.RESULTS / 'manifest.jsonl').read_bytes()
                self.assertTrue(extended.startswith(original))
                for changed in ([b], [{**a, 'truth_sha256': 'different'}, b]):
                    C.write_jsonl(S.DRAW, changed)
                    with self.assertRaises(SystemExit):
                        S.cmd_freeze()
                    self.assertEqual((S.RESULTS / 'manifest.jsonl').read_bytes(), extended)

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

    def test_drawing_one_stratum_keeps_the_others(self):
        import tempfile
        from pathlib import Path
        from unittest import mock
        import common as C
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            cands = [{**r, 'stratum': s, **{f: '' for f in ('licence', 'item_url', 'convention', 'contamination',
                                                              'script', 'era', 'kind')},
                      'publish_image': False, 'fetch': {}}
                     for s in ('L5', 'L6') for r in pool({'a': 30, 'b': 30, 'c': 30, 'd': 30})]
            C.write_jsonl(d / 'cands.jsonl', cands)
            img = d / 'img.jpg'
            img.write_bytes(b'x')
            fake = mock.Mock()
            fake.materialise = lambda c: (img, f'text of {c.page_id}')
            with mock.patch.multiple(S, CANDIDATES=d / 'cands.jsonl', DRAW=d / 'draw.jsonl',
                                     DROPS=d / 'drops.jsonl', TRUTH=d / 'truth'), \
                    mock.patch.object(S, 'modules', lambda: {'src': fake}):
                S.cmd_draw(['L5'])
                l5 = C.read_jsonl(d / 'draw.jsonl')
                S.cmd_draw(['L6'])
                both = C.read_jsonl(d / 'draw.jsonl')
        self.assertEqual({r['stratum'] for r in l5}, {'L5'})
        self.assertEqual([r for r in both if r['stratum'] == 'L5'], l5)
        self.assertEqual(sum(r['stratum'] == 'L6' for r in both), 80)


if __name__ == '__main__':
    unittest.main()
