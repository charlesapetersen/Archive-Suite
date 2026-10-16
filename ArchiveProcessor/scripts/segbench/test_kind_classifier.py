#!/usr/bin/env python3
"""Synthetic checks for kind_classifier.py (W41.bench-kind-classifier): no corpus, no model, no cache.

  <lab venv>/bin/python test_kind_classifier.py      (numpy needed for the regression check)
"""
import tempfile
import unittest
from pathlib import Path

import kind_classifier as K


class Parse(unittest.TestCase):
    def test_two_words(self):
        self.assertEqual(K.parse_vlm('typewritten table'), ('typewritten', 'yes'))
        self.assertEqual(K.parse_vlm('Printed; text.'), ('printed', 'no'))

    def test_first_hand_wins_and_a_missing_second_word_is_none(self):
        self.assertEqual(K.parse_vlm('handwritten\nmixed'), ('handwritten', None))
        self.assertEqual(K.parse_vlm('I cannot tell'), (None, None))


class Threshold(unittest.TestCase):
    def test_cut_never_sees_its_own_group(self):
        # on all pages the cut is 8.5, which calls b's page right; learned without b it is 5.5, which calls it wrong
        xs, ys, gs = [1, 2, 9, 10, 8], [True, True, False, False, True], ['a', 'a', 'c', 'd', 'b']
        preds, cut = K.loo_threshold(xs, ys, gs)
        self.assertEqual(cut, 8.5)
        self.assertFalse(preds[4])
        self.assertEqual([preds[0], preds[1], preds[3]], [True, True, False])
        self.assertTrue(preds[2])           # and without c (9) the cut moves to 9, so c is called wrong too

    def test_both_directions(self):
        preds, cut = K.loo_threshold([0.1, 0.2, 0.8, 0.9], [False, False, True, True], ['a', 'b', 'c', 'd'], below=False)
        self.assertEqual(preds, [False, False, True, True])
        self.assertEqual(cut, 0.5)


class Regression(unittest.TestCase):
    def test_folder_left_out(self):
        import numpy as np
        rng = np.random.default_rng(0)
        X = np.vstack([rng.normal(0, 1, (20, 3)), rng.normal(4, 1, (20, 3))])
        y = np.array([0] * 20 + [1] * 20)
        groups = [f'g{i % 5}' for i in range(40)]
        self.assertGreaterEqual((K.loo_lr(X, y, 2, groups) == y).mean(), 0.95)


class PdfSide(unittest.TestCase):
    def test_largest_image_not_the_first(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'x.pdf'
            p.write_bytes(b'%PDF-1.4\n1 0 obj << /Type /XObject /Width 80 /Height 104 >>\n'
                          b'2 0 obj << /Subtype /Image /Height 1936 /BitsPerComponent 8 /Width 2592 >>\n')
            self.assertEqual(K.pdf_image_side(p), 2592)
            p.write_bytes(b'%PDF-1.4\n')
            self.assertIsNone(K.pdf_image_side(p))


if __name__ == '__main__':
    unittest.main()
