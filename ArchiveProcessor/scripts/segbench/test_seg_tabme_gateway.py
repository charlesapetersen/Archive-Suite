"""W46.seg-tabme-paid: the subset cut, the store and cap handed to seg_window_gateway, and the jobs' windows.
Run: /usr/local/bin/python3 test_seg_tabme_gateway.py   (no bench data, no gateway call)."""
from pathlib import Path
import unittest

import data
import method_window as W
import seg_tabme_gateway as T


def labels(lengths):
    out = []
    for n in lengths:
        out += ["New"] + ["Cont"] * (n - 1)
    return out


class Cut(unittest.TestCase):
    def test_whole_documents_reaching_the_size(self):
        ls = labels([200, 250, 49, 3, 10])      # 499 after three, so the fourth document is kept whole
        self.assertEqual(T.cut(ls), 502)
        self.assertEqual(ls[T.cut(ls)], "New")

    def test_exact_size_stops_at_the_boundary(self):
        self.assertEqual(T.cut(labels([250, 250, 7])), 500)

    def test_short_stream_is_kept_whole(self):
        self.assertEqual(T.cut(labels([3, 4])), 7)

    def test_describe(self):
        d = T.describe(labels([1, 1, 4]))
        self.assertEqual((d["pages"], d["documents"], d["longest"]), (6, 3, 4))
        self.assertAlmostEqual(d["single_page_share"], 2 / 3)


class Wiring(unittest.TestCase):
    def test_store_and_cap_are_this_items(self):
        SWG = T._gw()
        self.assertEqual(SWG.STORE, T.STORE)
        self.assertEqual(SWG.ITEM_CAP_USD, T.ITEM_CAP_USD)
        self.assertLess(T.ITEM_CAP_USD, 7.0)       # the owner's per-item ceiling
        self.assertNotEqual(T.STORE.name, "seg-window-gateway")

    def test_jobs_are_method_window_for_both_arms(self):
        col = data.Collection("TABME", Path("/nonexistent"), [data.Page(i + 1, t, None)
                                                              for i, t in enumerate(labels([5, 9, 6]))])
        js = T.jobs(col)
        spans = W.windows(20)
        self.assertEqual([(a, b) for arm, _, a, b in js if arm == "k7-it"], spans)
        self.assertEqual([(a, b) for arm, _, a, b in js if arm == "k7-t"], spans)
        self.assertEqual(len(T.jobs(col, ["k7-t"])), len(spans))


if __name__ == "__main__":
    unittest.main()
