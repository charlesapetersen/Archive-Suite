"""W46.fix-ocr-scorers: unit tests for ocr_scorers.py. Run: uv run --offline --with rapidfuzz --with numpy
python -m unittest test_ocr_scorers"""
import unittest

import numpy as np

import ocr_scorers as S


class AddedRewritten(unittest.TestCase):
    def test_counts(self):
        truth = 'the quick brown fox jumps'.split()
        reading = 'the quick browm cat fox jumps high'.split()
        r = S.added_rewritten(truth, reading)
        # browm is one edit from brown (not rewritten); cat and high are insertions.
        self.assertEqual((r['inserted'], r['substituted'], r['rewritten'], r['deleted']), (2, 1, 0, 0))
        self.assertAlmostEqual(r['added_rate'], 2 / 5)
        r = S.added_rewritten('a letter from home'.split(), 'a lettuce from home'.split())
        self.assertEqual((r['rewritten'], r['inserted']), (1, 0))

    def test_pairs_near_misses_in_a_stretch(self):
        # a unit-cost alignment may pair 'tbe' with 'zzz'; the weighted pass pairs it with 'the'
        r = S.added_rewritten('x the cat y'.split(), 'x zzz tbe cat y'.split())
        self.assertEqual((r['inserted'], r['rewritten']), (1, 0))

    def test_large_stretch_falls_back(self):
        old, S.LOCAL_CELLS = S.LOCAL_CELLS, 1
        try:
            r = S.added_rewritten('a b c d'.split(), 'a x y z w d'.split())
            self.assertEqual((r['inserted'], r['substituted'], r['deleted']), (2, 2, 0))
        finally:
            S.LOCAL_CELLS = old

    def test_empty(self):
        self.assertEqual(S.added_rewritten([], [])['added_rate'], 0.0)
        self.assertEqual(S.added_rewritten([], ['x'])['added_rate'], 1.0)


class ReferenceFree(unittest.TestCase):
    def test_restoration_only(self):
        r = S.restoration_only('Dear Sir I am glad'.split(), 'Dear Sir I am'.split(), 'Dear Sir I'.split())
        self.assertEqual(r['words'], ['glad'])
        self.assertAlmostEqual(r['per_1000'], 200.0)

    def test_suspect(self):
        r = S.suspect_words('One Two three'.split(), [['one', 'two'], ['two']])
        self.assertEqual(r['words'], ['three'])
        self.assertEqual(S.suspect_words(['a'], [])['rate'], 1.0)

    def test_reseed(self):
        self.assertEqual(S.reseed_instability('a b c'.split(), 'a b c'.split()), 0.0)
        self.assertAlmostEqual(S.reseed_instability('a b c d'.split(), 'a x c d'.split()), 0.25)


class MarkRegion(unittest.TestCase):
    def test_removed_mark(self):
        raw = np.full((20, 20), 255, np.uint8)
        raw[2:8, 2:8] = 0       # a mark, 36 ink pixels
        raw[12:18, 12:18] = 0   # print that survives
        enh = raw.copy()
        enh[2:8, 2:6] = 255     # two thirds of the mark erased
        out = S.mark_region_check(raw, enh, [(0, 0, 10, 10), (10, 10, 20, 20)])
        self.assertTrue(out[0]['removed'])
        self.assertAlmostEqual(out[0]['ink_loss'], 24 / 36)
        self.assertFalse(out[1]['removed'])
        with self.assertRaises(ValueError):
            S.mark_region_check(raw, enh[:5], [])


class Cmer(unittest.TestCase):
    def test_bounded_and_folded(self):
        self.assertEqual(S.cmer('Hello, World!', 'hello world'), 0.0)
        self.assertAlmostEqual(S.cmer('abcd', 'abxd'), 1 / 4)
        # insertions can push CER over 1; cMER stays at most 1
        self.assertLessEqual(S.cmer('ab', 'ab' + 'x' * 50), 1.0)
        self.assertEqual(S.cmer('', ''), 0.0)


class NewsBench(unittest.TestCase):
    def test_gap_is_order(self):
        ref = 'alpha beta gamma delta\n\nepsilon zeta eta theta'
        hyp = 'epsilon zeta eta theta alpha beta gamma delta'
        r = S.newsbench(ref, hyp)
        self.assertEqual(r['bowF1'], 1.0)
        self.assertLess(r['overall'], 0.8)
        self.assertAlmostEqual(r['gap'], r['bowF1'] - r['overall'])
        self.assertEqual(S.newsbench(ref, ref)['overall'], 1.0)

    def test_pool_weights_pages_alike(self):
        # NewsBench's table averages the page CERs: a perfect long page and a wrong short one give 0.5
        a, b = S.newsbench('abcdefghij', 'abcdefghij'), S.newsbench('ab', 'xy')
        self.assertAlmostEqual(S.newsbench_pool([a, b])['overall'], 0.5)


class ReadingOrder(unittest.TestCase):
    TRUTH = ('the first paragraph is about apples\n\nthe second paragraph concerns bananas\n\n'
             'a third paragraph covers cherries')

    def test_in_order(self):
        r = S.reading_order_edit(self.TRUTH, self.TRUTH.replace('\n\n', ' '))
        self.assertEqual((r['matched'], r['edit']), (3, 0.0))

    def test_swapped(self):
        hyp = ('a third paragraph covers cherries the first paragraph is about apples '
               'the second paragraph concerns bananas')
        r = S.reading_order_edit(self.TRUTH, hyp)
        self.assertEqual(r['matched'], 3)
        self.assertGreater(r['edit'], 0.0)

    def test_duplicate_blocks_both_found(self):
        truth = 'the same header line here\n\nthe body of the letter follows\n\nthe same header line here'
        r = S.reading_order_edit(truth, truth.replace('\n\n', ' '))
        self.assertEqual((r['matched'], r['edit']), (3, 0.0))

    def test_single_block(self):
        self.assertIsNone(S.reading_order_edit('only one block of words here', 'anything'))


class Preservation(unittest.TestCase):
    def test_kept_and_inserted(self):
        r = S.preservation('the ſhip ſail', 'the ſhip sail ﬁne')
        self.assertEqual((r['truth'], r['kept'], r['inserted']), (2, 1, 1))


class Markup(unittest.TestCase):
    def test_strip(self):
        md = '# Heading\n\n**Dear** Sir,\n\n<table><tr><td>one</td><td>two</td></tr></table>\n| a | b |\n|---|---|\n![x](y)'
        self.assertTrue(S.has_markup(md))
        out = ' '.join(S.strip_markup(md).split())
        self.assertEqual(out, 'Heading Dear Sir, one two | a | b |')
        self.assertFalse(S.has_markup('Dear Sir, a plain letter.'))
        self.assertFalse(S.has_markup('paid $5 and $10 | 1972 | total'))
        self.assertTrue(S.has_markup('the area $\\alpha$ of'))
        self.assertEqual(S.strip_markup('cost $5 and $6'), 'cost $5 and $6')


if __name__ == '__main__':
    unittest.main()
