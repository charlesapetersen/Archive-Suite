"""Tests for enh_ocr_marks' ink check. Run in the enh-ocr-input venv (numpy, OpenCV)."""
import unittest

import numpy as np

import enh_ocr_marks as M


def page(ink=(40, 40, 40)):
    """A 400 x 300 grey-white page with one dark stroke block (the mark) and one black bar (the print)."""
    img = np.full((400, 300, 3), 235, np.uint8)
    img[100:110, 50:150] = ink
    img[300:310, 50:250] = 0
    return img


class InkCheck(unittest.TestCase):
    def check(self, raw, enh, t=0.30):
        ys, xs = M.box_pixels([0.1, 0.2, 0.6, 0.3], raw.shape[:2])
        r, e = M.darkness(raw), M.darkness(enh)
        return M.measure((r[0][ys, xs], r[1][ys, xs]), (e[0][ys, xs], e[1][ys, xs]), t)

    def test_identity_keeps_everything(self):
        r = self.check(page(), page())
        self.assertEqual(r['kept'], 1.0)
        self.assertAlmostEqual(r['contrast'], 1.0)
        self.assertEqual(r['added'], 0.0)
        self.assertIsNone(r['colour'])   # grey ink has no spread

    def test_erased_mark_is_lost(self):
        enh = page()
        enh[100:110, 50:150] = 235
        r = self.check(page(), enh)
        self.assertEqual(r['kept'], 0.0)
        self.assertLess(r['kept'], M.LOST)

    def test_colour_lost_to_grey(self):
        raw, enh = page(ink=(200, 30, 30)), page(ink=(60, 60, 60))   # red pencil made grey, still dark
        r = self.check(raw, enh)
        self.assertEqual(r['kept'], 1.0)
        self.assertEqual(r['colour'], 0.0)

    def test_faint_ink_only_at_the_low_threshold(self):
        raw = page(ink=(180, 180, 180))   # about 0.23 darker than the page
        self.assertIsNone(self.check(raw, raw, 0.30))
        self.assertEqual(self.check(raw, raw, 0.15)['kept'], 1.0)

    def test_box_pixels_clip_and_order(self):
        ys, xs = M.box_pixels([0.5, 0.5, 1.2, 1.0], (100, 200))
        self.assertEqual((ys.start, ys.stop, xs.start, xs.stop), (50, 100, 100, 200))

    def test_boot_interval_contains_mean(self):
        b = M.boot([0.1, 0.2, 0.3, 0.4])
        self.assertLessEqual(b['lo'], b['mean'])
        self.assertLessEqual(b['mean'], b['hi'])
        self.assertIsNone(M.boot([]))


if __name__ == '__main__':
    unittest.main()
