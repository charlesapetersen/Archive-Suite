"""W46.layout-order: unit tests for layout_order.py. Run: uv run --offline --with rapidfuzz --with numpy
--with scikit-learn python -m unittest test_layout_order"""
import unittest

import layout_order as L


def two_columns(rows=8, head=True):
    """A page 1000 wide: an optional full-width heading, then a left and a right column of ``rows`` lines each.
    Returns boxes in a scrambled order and the true reading order of their indices."""
    truth = []
    if head:
        truth.append([100, 20, 900, 50])
    for r in range(rows):
        truth.append([100, 100 + 40 * r, 480, 125 + 40 * r])
    for r in range(rows):
        truth.append([520, 102 + 40 * r, 900, 127 + 40 * r])
    scramble = list(range(len(truth)))[::-1]
    boxes = [truth[i] for i in scramble]
    want = [scramble.index(i) for i in range(len(truth))]
    return boxes, want


class Orderers(unittest.TestCase):
    def test_column_orderers_read_down_each_column(self):
        boxes, want = two_columns(head=False)
        for name in ("columns", "app_regions", "hdbscan"):
            with self.subTest(name):
                self.assertEqual(L.ORDERERS[name](boxes, width=1000), want)

    def test_xycut_yfirst_cuts_rows_before_columns(self):
        # lines whose rows line up across the gutter are cut into rows first, so XY-cut reads across...
        boxes, want = two_columns(head=False)
        self.assertEqual(L.order_xycut_yfirst(boxes), L.order_topbottom(boxes))
        # ...while column blocks under a full-width heading come out heading, left, right
        blocks = [[520, 100, 900, 400], [100, 20, 900, 50], [100, 100, 480, 250], [100, 260, 480, 400]]
        self.assertEqual(L.order_xycut_yfirst(blocks), [1, 2, 3, 0])

    def test_topbottom_interleaves(self):
        boxes, want = two_columns(head=False)
        got = L.order_topbottom(boxes)
        self.assertNotEqual(got, want)
        self.assertEqual(got[:2], [want[0], want[8]])

    def test_benchmark_xycut_never_cuts_a_gutter(self):
        # the gutter (40) is narrower than 1.2 median box widths (456), so the benchmark's XY-cut reads across
        boxes, _ = two_columns(head=False)
        self.assertEqual(L.order_xycut(boxes), L.order_topbottom(boxes))

    def test_heading_first_then_columns(self):
        boxes, want = two_columns(head=True)
        self.assertEqual(L.order_hdbscan(boxes, width=1000), want)

    def test_single_box_and_empty(self):
        for f in L.ORDERERS.values():
            self.assertEqual(f([], width=1000), [])
            self.assertEqual(f([[0, 0, 10, 10]], width=1000), [0])


class Scoring(unittest.TestCase):
    def test_kendall(self):
        self.assertEqual(L.kendall([0, 1, 2, 3]), 1.0)
        self.assertEqual(L.kendall([3, 2, 1, 0]), -1.0)
        self.assertAlmostEqual(L.kendall([0, 2, 1, 3]), 4 / 6)

    def test_order_score_guard_and_word_error(self):
        texts = [f"w{i}" for i in range(20)]
        right = L.order_score({i: (i,) for i in range(20)}, texts, 20)
        self.assertEqual((right["tau"], right["oiwer"], right["valid"]), (1.0, 0.0, True))
        swapped = L.order_score({i: ((i + 10) % 20,) for i in range(20)}, texts, 20)
        self.assertLess(swapped["tau"], 1.0)
        self.assertGreater(swapped["oiwer"], 0.0)
        # 14 lines matched: under the 15-line floor
        self.assertFalse(L.order_score({i: (i,) for i in range(14)}, texts, 14)["valid"])
        # 15 of 30: under the 60% share
        self.assertFalse(L.order_score({i: (i,) for i in range(15)}, texts * 2, 30)["valid"])

    def test_assign_and_region_rank(self):
        regions = [[500, 0, 1000, 1000], [0, 0, 490, 1000]]
        lines = [[10, 10, 400, 30], [600, 10, 900, 30], [10, 50, 400, 70], [2000, 0, 2100, 10]]
        owner = L.assign(lines, regions)
        self.assertEqual(owner, [1, 0, 1, None])
        rank = L.region_rank(lines, owner, [1, 0])
        self.assertEqual(sorted(rank, key=rank.get), [0, 2, 1])

    def test_match_lines(self):
        gt = [[0, 0, 100, 10], [0, 20, 100, 30]]
        pred = [[0, 21, 100, 31], [0, 0, 100, 9], [500, 500, 600, 600]]
        self.assertEqual(L.match_lines(gt, pred), [(0, 1), (1, 0)])

    def test_bow_and_words(self):
        self.assertEqual(L.words("The Cat, the hat."), ["the", "cat", "the", "hat"])
        self.assertEqual(L.bow_f1(["a", "b"], ["b", "a"]), 1.0)
        self.assertEqual(L.bow_f1(["a"], ["b"]), 0.0)


if __name__ == "__main__":
    unittest.main()
