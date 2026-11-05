import unittest

import layout_order_marks as M


class Cover(unittest.TestCase):
    def test_region_cover_is_the_best_single_region(self):
        mark = [0.0, 0.0, 1.0, 1.0]
        self.assertAlmostEqual(M.cover(mark, [[0, 0, 0.5, 1], [0, 0, 0.8, 1]]), 0.8)
        self.assertEqual(M.cover(mark, []), 0.0)

    def test_lines_cover_counts_only_lines_inside_the_mark(self):
        mark = [0.0, 0.0, 1.0, 1.0]
        # two lines filling the top and bottom halves; a long line mostly outside is ignored
        lines = [[0, 0, 1, 0.5], [0, 0.5, 1, 1.0], [-5, 0.4, 5, 0.6]]
        self.assertAlmostEqual(M.lines_cover(mark, lines), 1.0, places=2)
        self.assertAlmostEqual(M.lines_cover(mark, lines[:1]), 0.5, places=1)
        self.assertEqual(M.lines_cover(mark, lines[2:]), 0.0)


class Arms(unittest.TestCase):
    def test_two_columns_read_down_then_across(self):
        # left column lines 0, 2; right column lines 1, 3 (Vision's order runs across)
        lines = [[0, 0, 40, 10], [60, 0, 100, 10], [0, 20, 40, 30], [60, 20, 100, 30]]
        regs = {"yolo": [{"order": 1, "label": "plain text", "box": [0, 0, 45, 35]},
                         {"order": 2, "label": "plain text", "box": [55, 0, 105, 35]}]}
        arms = M.page_arms(lines, regs, 100)
        self.assertEqual(arms["none/vision_lines"], ([0, 1, 2, 3], 4))
        self.assertEqual(arms["yolo/app_regions"], ([0, 2, 1, 3], 4))
        self.assertNotIn("yolo/native", arms)

    def test_lines_outside_every_region_are_dropped_and_counted(self):
        lines = [[0, 0, 40, 10], [60, 0, 100, 10]]
        regs = {"pp": [{"order": 1, "label": "text", "box": [0, 0, 45, 15]}]}
        order, kept = M.page_arms(lines, regs, 100)["pp/native"]
        self.assertEqual((order, kept), ([0], 1))


if __name__ == "__main__":
    unittest.main()
