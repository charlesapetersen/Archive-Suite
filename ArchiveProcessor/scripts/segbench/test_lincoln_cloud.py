"""W46.seg-lincoln-cloud: the stated letter cue, the prompt versions and the review load, on toy data.
Run: <lab venv>/bin/python test_lincoln_cloud.py   (no bench data, no model call)."""
import unittest
from types import SimpleNamespace
from unittest import mock

import method_window_cues as WC
import seg_lincoln_cloud as S
from methods import Prediction


def toy(texts):
    return SimpleNamespace(name="Toy", text=lambda i: texts[i])


class CueBlock(unittest.TestCase):
    def test_states_only_the_gaps_that_fire(self):
        col = toy(["Dear Sir:\nthe matter", "goes on here\nYours truly,\nJ. Smith", "Dear Madam,\nanother", "plain"])
        block = WC.cue_block(col, [1, 2, 3, 4], [0, 1, 2, 3])
        self.assertIn("- gap [2, 3]: page 3 opens with a salutation or memo heading; page 2 ends with a closing", block)
        self.assertNotIn("gap [1, 2]", block)
        self.assertNotIn("gap [3, 4]", block)

    def test_running_header_is_not_a_salutation(self):
        col = toy(["To: M. M. May\nPage 1 text", "To: M. M. May\nPage 2 text"])
        self.assertIn("- none in this window", WC.cue_block(col, [1, 2], [0, 1]))

    def test_versions_keep_c1_caches(self):
        self.assertEqual(WC.version_of("claude"), "c1")
        self.assertEqual(WC.version_of("codex"), "c1")
        self.assertEqual(WC.version_of("codex-cue"), "c2")
        self.assertEqual(WC.model_of("claude-cue"), WC.model_of("claude"))
        self.assertEqual(WC.model_of("codex-cue"), WC.model_of("codex"))


class Guard(unittest.TestCase):
    def test_claude_ignores_a_reset_reading_and_stops_blind(self):
        now = 1_000_000.0
        runs = iter([SimpleNamespace(stdout=f"24 {now - 10}"), SimpleNamespace(stdout=f"61 {now + 100}")])
        with mock.patch.object(WC.subprocess, "run", side_effect=lambda *a, **k: next(runs)), \
                mock.patch.object(WC.time, "time", return_value=now):
            self.assertEqual(WC.used_pct("claude"), 61)
        with mock.patch.object(WC.subprocess, "run", return_value=SimpleNamespace(stdout="")):
            self.assertEqual(WC.used_pct("claude-cue"), 100)
        just_reset = SimpleNamespace(stdout=f"71 {now - 120}")
        with mock.patch.object(WC.subprocess, "run", return_value=just_reset), \
                mock.patch.object(WC.time, "time", return_value=now):
            self.assertEqual(WC.used_pct("claude"), 0)
        days_old = SimpleNamespace(stdout=f"24 {now - 86400 * 12}")
        with mock.patch.object(WC.subprocess, "run", return_value=days_old), \
                mock.patch.object(WC.time, "time", return_value=now):
            self.assertEqual(WC.used_pct("claude"), 100)


class ReviewLoad(unittest.TestCase):
    def test_unrepairable_fixed_gap_does_not_claim_the_target_was_reached(self):
        truth = ["New", "Cont", "Cont", "New", "Cont"] * 2
        labels = list(truth)
        labels[1] = "New"
        bounds = [{"decision": "x", "confidence": .9, "fixed": i == 0} for i in range(9)]
        self.assertIsNone(S.review_load(truth, Prediction(labels, bounds)))

    def test_least_confident_wrong_gap_first(self):
        truth = ["New", "Cont", "Cont", "New", "Cont"] * 2
        labels = list(truth)
        labels[1] = "New"                       # one false split (7 of 10 pages exact), least confident
        bounds = [{"decision": "x", "confidence": 0.9} for _ in range(9)]
        bounds[0]["confidence"] = 0.55
        self.assertEqual(S.review_load(truth, Prediction(labels, bounds)), 1)
        self.assertEqual(S.review_load(truth, Prediction(truth, bounds)), 0)


if __name__ == "__main__":
    unittest.main()
