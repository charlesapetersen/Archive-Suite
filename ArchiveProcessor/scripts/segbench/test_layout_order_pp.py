"""Tests for layout_order_pp (W46.layout-order-newspapers-pp)."""
import unittest

import layout_order_pp as P


class ArmOrders(unittest.TestCase):
    # Two columns; PP's native order reads the right column first, the app sort left to right.
    regs = [{"order": 1, "box": [0, 0, 40, 100]}, {"order": 0, "box": [60, 0, 100, 100]}]
    lines = [[0, 10, 40, 20], [60, 10, 100, 20], [0, 50, 40, 60], [60, 50, 100, 60], [0, 200, 100, 210]]
    owner = [0, 1, 0, 1, None]

    def test_native_follows_detector_order_and_unowned_go_last(self):
        arms = P.arm_orders(self.lines, self.owner, self.regs, {"app_regions": [0, 1]}, None)
        self.assertEqual(arms["pp_native"], [1, 3, 0, 2, 4])
        self.assertEqual(arms["app_regions"], [0, 2, 1, 3, 4])
        self.assertNotIn("app_columns_lines", arms)

    def test_line_columns_passed_through(self):
        arms = P.arm_orders(self.lines, self.owner, self.regs, {}, [4, 3, 2, 1, 0])
        self.assertEqual(arms["app_columns_lines"], [4, 3, 2, 1, 0])


class Summary(unittest.TestCase):
    def row(self, page, arm, tau, valid=True):
        return {"page": page, "set": "own", "arm": arm, "valid": valid, "tau": tau, "word_acc": 0.5,
                "bow_f1": 0.6, "gap": 0.1, "roe": 0.2}

    def test_paired_only_where_both_valid(self):
        rows = [self.row("a", "pp_native", 0.8), self.row("a", "x", 0.9),
                self.row("b", "pp_native", 0.5, valid=False), self.row("b", "x", 0.1)]
        s = P.summarise(rows)["own"]
        self.assertEqual(s["x"]["valid"], 2)
        self.assertEqual(s["x"]["tau_vs_native"]["n"], 1)
        self.assertAlmostEqual(s["x"]["tau_vs_native"]["delta"], 0.1, places=4)
        self.assertEqual(s["x"]["gap_vs_native"]["n"], 2)
        self.assertNotIn("tau_vs_native", s["pp_native"])


if __name__ == "__main__":
    unittest.main()
