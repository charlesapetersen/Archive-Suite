"""Windows, parsing and the two-window combination of approach A (W36.seg-window), on toy data.
Run: <lab venv>/bin/python test_window.py   (no bench data, no model call)."""
import unittest
from types import SimpleNamespace

import method_window as W
from methods import METHODS
from score import check_prediction


def toy(labels):
    pages = [SimpleNamespace(n=i + 1) for i in range(len(labels))]
    return SimpleNamespace(name="Dean", labels=labels, pages=pages)


class Windows(unittest.TestCase):
    def test_every_gap_judged_at_least_twice(self):
        for n in range(8, 260):   # shorter streams collapse to one window; the bench has none
            self.assertGreaterEqual(min(W.coverage(n)), 2, n)

    def test_shape(self):
        self.assertEqual(W.windows(10), [(0, 4), (0, 7), (3, 10), (6, 10)])
        self.assertTrue(all(b - a <= W.WINDOW for a, b in W.windows(200)))


class Parse(unittest.TestCase):
    def reply(self, **kw):
        return ('```json\n{"pages": [{"page": 4, "kind": "document"}, {"page": 5, "kind": "folder"}],'
                ' "boundaries": [{"between": [4, 5], "decision": "%s", "cue": "x", "confidence": %s}]}\n```'
                % (kw.get("d", "new"), kw.get("c", 0.9)))

    def test_ok_with_fence(self):
        p = W.parse_answer(self.reply(), [4, 5])
        self.assertEqual(p["pages"], {4: "document", 5: "folder"})
        self.assertEqual(p["boundaries"][4]["decision"], "new")

    def test_rejects(self):
        for bad in (self.reply(d="maybe"), self.reply(c=1.5), "no json here"):
            with self.assertRaises(W.ParseError):
                W.parse_answer(bad, [4, 5])
        with self.assertRaises(W.ParseError):
            W.parse_answer(self.reply(), [4, 5, 6])   # a gap missing


class Combine(unittest.TestCase):
    def setUp(self):
        self._orig = W.judge_window

    def tearDown(self):
        W.judge_window = self._orig

    def fake(self, judgements, kinds=None):
        """judgements: {gap index: [(decision, conf) per window, in window order]}."""
        seen = {}

        def jw(col, a, b, allow_call=False):
            out = {"pages": {}, "boundaries": {}}
            for i in range(a, b):
                out["pages"][col.pages[i].n] = (kinds or {}).get(i, "document")
            for i in range(a, b - 1):
                k = seen.get(i, 0)
                seen[i] = k + 1
                d, c = judgements[i][min(k, len(judgements[i]) - 1)]
                out["boundaries"][col.pages[i].n] = {"decision": d, "confidence": c, "cue": ""}
            return out
        W.judge_window = jw

    def test_agree_and_disagree(self):
        col = toy(["New", "Cont", "New", "Cont", "Cont", "New"])
        self.fake({0: [("continue", 0.9), ("continue", 0.7)],
                   1: [("new", 0.9), ("continue", 0.6)],     # disagree: new wins, P(new)=0.65
                   2: [("new", 0.6), ("continue", 0.6)],     # exact tie: P(new)=0.5 -> new, conf 0.5
                   3: [("continue", 0.8)], 4: [("new", 0.95)]})
        c = W.combine(col)
        g = c["gaps"]
        self.assertEqual(g[0]["decision"], "continue")
        self.assertAlmostEqual(g[0]["confidence"], 0.8)
        self.assertTrue(g[0]["agree"])
        self.assertEqual(g[1]["decision"], "new")
        self.assertAlmostEqual(g[1]["confidence"], 0.65)
        self.assertFalse(g[1]["agree"])
        self.assertEqual(g[2]["decision"], "new")
        self.assertAlmostEqual(g[2]["confidence"], 0.5)

    def test_photo_vote_and_assembly(self):
        col = toy(["Folder", "New", "Cont", "New"])
        self.fake({0: [("new", 0.9)], 1: [("continue", 0.9)], 2: [("new", 0.9)]}, kinds={0: "folder"})
        comb = W.combine(col)
        self.assertEqual(comb["photo"][0], "Folder")
        pred = W.assemble(col, comb, truth_photos=False)
        self.assertEqual(pred.labels, ["Folder", "New", "Cont", "New"])
        check_prediction(pred)
        # the model misses the photo; truth-photo variant still gets it
        self.fake({0: [("new", 0.9)], 1: [("continue", 0.9)], 2: [("new", 0.9)]})
        comb = W.combine(col)
        self.assertIsNone(comb["photo"][0])
        self.assertEqual(W.assemble(col, comb, truth_photos=True).labels, ["Folder", "New", "Cont", "New"])
        own = W.assemble(col, comb, truth_photos=False)
        self.assertEqual(own.labels, ["New", "New", "Cont", "New"])
        check_prediction(own)

    def test_review_fixes_a_gap(self):
        col = toy(["New", "Cont", "New"])
        self.fake({0: [("new", 0.6)], 1: [("new", 0.9)]})
        comb = W.combine(col)
        self.assertEqual(W.review(col, comb, True, set()), ["New", "New", "New"])
        self.assertEqual(W.review(col, comb, True, {0}), ["New", "Cont", "New"])


class Guard(unittest.TestCase):
    def test_refuses_test_collections(self):
        with self.assertRaises(SystemExit):
            W.refuse_test(["Dean", "Stanton"])
        with self.assertRaises(SystemExit):
            METHODS["window-claude"].predict(SimpleNamespace(name="RG165"))
        self.assertTrue(METHODS["window-claude"].tuning)


if __name__ == "__main__":
    unittest.main()
