"""W46.ocr-regions: the crop geometry the cluster job sends (regions_cluster.py). No model, no cluster.

    python3 -m unittest test_regions
"""
import unittest

import regions_cluster as C


class Tiles(unittest.TestCase):
    def covered(self, boxes):
        return all(any(b[1] <= y <= b[3] for b in boxes) for y in [i / 200 for i in range(201)])

    def test_portrait_page_is_three_overlapping_bands(self):
        b = C.tile_boxes(1700, 2400)
        self.assertEqual(len(b), 3)
        self.assertTrue(all(x[0] == 0 and x[2] == 1 for x in b))
        self.assertEqual((b[0][1], b[-1][3]), (0, 1))
        for a, n in zip(b, b[1:]):
            self.assertGreaterEqual((a[3] - n[1]) / (a[3] - a[1]), C.TILE_OVERLAP - 1e-9)
        self.assertTrue(self.covered(b))

    def test_short_page_is_one_tile(self):
        self.assertEqual(C.tile_boxes(2000, 800), [[0.0, 0.0, 1.0, 1.0]])

    def test_wide_page_reads_down_each_column(self):
        b = C.tile_boxes(4000, 2400)
        self.assertEqual(len({x[0] for x in b}), 2)
        firsts = [x[0] for x in b]
        self.assertEqual(firsts, sorted(firsts))   # column 0's tiles all come before column 1's


class Regions(unittest.TestCase):
    def r(self, label, box):
        return {'label': label, 'box': box}

    def test_pictures_and_nested_boxes_are_dropped_order_kept(self):
        rs = [self.r('text', [0, 0.5, 1, 1]), self.r('image', [0, 0, 1, 0.4]), self.r('text', [0.1, 0.6, 0.5, 0.7]),
              self.r('doc_title', [0, 0, 1, 0.1])]
        got = C.keep_regions(rs)
        self.assertEqual([g['label'] for g in got], ['text', 'doc_title'])

    def test_degenerate_box_is_dropped(self):
        self.assertEqual(C.keep_regions([self.r('text', [0.5, 0.5, 0.5, 0.6])]), [])

    def test_pixel_box_pads_clamps_and_widens_tiny_boxes(self):
        self.assertEqual(C.pixel_box([0, 0, 1, 1], 1000, 2000, 0.01), (0, 0, 1000, 2000))
        x0, y0, x1, y1 = C.pixel_box([0.5, 0.5, 0.501, 0.501], 1000, 1000, 0)
        self.assertEqual((x1 - x0, y1 - y0), (C.MIN_SIDE, C.MIN_SIDE))
        x0, y0, x1, y1 = C.pixel_box([0.999, 0.999, 1, 1], 1000, 1000, 0)
        self.assertEqual((x1, y1, x1 - x0, y1 - y0), (1000, 1000, C.MIN_SIDE, C.MIN_SIDE))

    def test_crops_for_a_page_with_no_regions_record_is_an_error(self):
        with self.assertRaises(KeyError):
            C.crops_for('pp-doclayoutv3', {'id': 'x'}, {'pp-doclayoutv3': {}}, 100, 100)
        self.assertEqual(C.crops_for('pp-doclayoutv3', {'id': 'x'}, {'pp-doclayoutv3': {'x': []}}, 100, 100), [])


if __name__ == '__main__':
    unittest.main()
