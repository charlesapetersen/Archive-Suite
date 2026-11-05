import unittest

import layout_order_gemini as M


class Blocks(unittest.TestCase):
    def test_reads_the_wrapped_and_the_bare_list_in_order(self):
        wrapped = {"raw": '```json\n{"blocks": [{"label": "heading", "box_2d": [100, 50, 200, 950]},'
                          ' {"label": "paragraph", "box_2d": [210, 50, 900, 480]}]}\n```'}
        bare = {"raw": '[{"box_2d": [210, 50, 900, 480], "label": "paragraph"}, {"box_2d": [100, 50, 200, 950]}]'}
        a = M.blocks(wrapped)
        self.assertEqual([b["label"] for b in a], ["heading", "paragraph"])
        self.assertEqual(a[0]["box"], [0.05, 0.1, 0.95, 0.2])     # [ymin, xmin, ymax, xmax] -> [x0, y0, x1, y1]
        b = M.blocks(bare)
        self.assertEqual([x["order"] for x in b], [0, 1])
        self.assertEqual(b[1]["label"], "")

    def test_salvages_blocks_from_broken_json(self):
        # 3.7's own reply on an owner page: a stray key and a brace for a bracket in the last block
        raw = ('{"blocks": [{"label": "paragraph", "box_2d": [349, 94, 447, 891]}, "paragraph": '
               '{"label": "paragraph", "box_2d": [719, 72, 858, 984}}]}')
        got = M.blocks({"raw": raw})
        self.assertEqual(len(got), 2)
        self.assertFalse(M.strict_json({"raw": raw}))
        # and, on a rerun of eng_01, the key itself misspelt
        self.assertEqual(len(M.blocks({"raw": '{"blocks": [{"label": "header", "box_2": [41, 386, 53, 613]}]}'})), 1)
        self.assertEqual(M.blocks({"raw": '[{"label": "list", "box": [131, 100, 269, 494]}]'})[0]["box"],
                         [0.1, 0.131, 0.494, 0.269])

    def test_drops_empty_and_clamps(self):
        got = M.blocks({"raw": '[{"box_2d": [10, 10, 10, 50]}, {"box_2d": [-5, 0, 1200, 500]}]'})
        self.assertEqual(len(got), 1)
        self.assertEqual(got[0]["box"], [0.0, 0.0, 0.5, 1.0])
        self.assertIsNone(M.blocks({"raw": "no boxes"}))
        self.assertIsNone(M.blocks(None))


class Orders(unittest.TestCase):
    def test_native_keeps_gemini_order_and_lines_follow_their_block(self):
        # Gemini reads the right column first; its native order keeps that, the app's region sort does not
        regs = [{"order": 0, "label": "paragraph", "box": [55, 0, 105, 35]},
                {"order": 1, "label": "paragraph", "box": [0, 0, 45, 35]}]
        lines = [[0, 0, 40, 10], [60, 0, 100, 10], [0, 20, 40, 30], [60, 20, 100, 30]]
        orders = M.region_orders(regs, 100)
        owner = M.LO.assign(lines, [r["box"] for r in regs])
        rank = lambda ro: sorted(range(4), key=lambda i: M.LO.region_rank(lines, owner, ro)[i])
        self.assertEqual(rank(orders["native"]), [1, 3, 0, 2])
        self.assertEqual(rank(orders["app_regions"]), [0, 2, 1, 3])


if __name__ == "__main__":
    unittest.main()
