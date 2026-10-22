"""Tests for enh_ocr_input's invented-text measures and gate, and enh_ocr_arms' classical control."""
import unittest

import numpy as np

import enh_ocr_input as E


class Aligned(unittest.TestCase):
    def test_identity(self):
        self.assertEqual(E.aligned('the cat sat', 'the cat sat'), {'words': 3, 'read': 3, 'inserted': 0, 'rewritten': 0})

    def test_insertion_and_near_miss(self):
        r = E.aligned('the cat sat on the mat', 'the cat sat quietly on the mst')
        self.assertEqual(r['inserted'], 1)   # 'quietly'
        self.assertEqual(r['rewritten'], 0)  # mat -> mst is one edit: an OCR error, not new text

    def test_far_substitution_and_surplus(self):
        r = E.aligned('dear sir', 'dear madam and friends')
        self.assertEqual(r['rewritten'], 1)  # sir -> madam
        self.assertEqual(r['inserted'], 2)   # the replace block's surplus

    def test_illegible_marker_is_not_a_word(self):
        self.assertEqual(E.aligned('a [illegible] b', 'a b')['words'], 2)


class Novel(unittest.TestCase):
    def test_restoration_only(self):
        self.assertEqual(E.novel('the quick brown fox', 'the brown fox', 'the quick'), [])
        self.assertEqual(E.novel('the quick brown fox', 'the brown fox'), ['quick'])

    def test_repeats_count(self):
        self.assertEqual(E.novel('zz zz a', 'a'), ['zz', 'zz'])


class Unstable(unittest.TestCase):
    def test_multiset_difference(self):
        self.assertEqual(E.unstable('a b b c', 'a b c c'), (2, 8))
        self.assertEqual(E.unstable('a b', 'a b'), (0, 4))


class Gate(unittest.TestCase):
    def test_falls_back_above_threshold(self):
        rows = [{'nes': .9, 'raw_nes': .8, 'suspect_k': 5}, {'nes': .2, 'raw_nes': .7, 'suspect_k': 100}]
        (t0, n0, k0), (t1, n1, k1) = E.gate(rows, (10, 1e9))
        self.assertAlmostEqual(n0, (.9 + .7) / 2)
        self.assertEqual(k0, 1)
        self.assertAlmostEqual(n1, (.9 + .2) / 2)
        self.assertEqual(k1, 2)


class Shading(unittest.TestCase):
    def test_flattens_a_gradient_and_keeps_ink(self):
        import enh_ocr_arms as A
        h, w = 400, 300
        light = np.linspace(120, 240, w)[None, :, None].repeat(h, 0).repeat(3, 2)
        img = light.copy()
        img[200:204, 50:250] *= 0.3  # a dark stroke across the gradient
        out = A.shading(img.astype(np.uint8)).astype(float)
        paper = np.r_[out[50:150, 20:280].ravel()]
        self.assertGreater(paper.mean(), 240)  # the background is lifted to white
        self.assertLess(paper.std(), 6)
        self.assertLess(out[201, 60:240].mean(), 120)  # the stroke survives, rescaled
        self.assertEqual(out.shape, img.shape)


if __name__ == '__main__':
    unittest.main()
