"""Whole-page cluster price estimates use the strict accuracy pages."""
import csv
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import build


class FarmSharePrices(unittest.TestCase):
    def setUp(self):
        scratch = self.enterContext(tempfile.TemporaryDirectory())
        self.run = Path(scratch) / "fixture"
        self.run.mkdir()
        self.enterContext(patch.object(build, "FARMSHARE", self.run.parent))
        self.enterContext(patch.object(build, "agreement_pages", return_value={"agreement"}))
        self.prices = {"models": {"fixture": {"in": 1, "out": 2}}}
        self.rows = [
            ("read", "printed", "True", 1, 1000, 500),
            ("cap", "printed", "False", 0, 2000, 8192),
            ("zero", "printed", "False", 0, 0, 0),
            ("no-reading", "typed", "False", 0, 500, 0),
            ("agreement", "printed", "True", 1, 4000, 1500),
        ]
        self.throughput = dict(mean_prompt_tokens=2500, mean_completion_tokens=1000,
                               pages_per_hour_per_gpu=12, gpus=1)

    def build_run(self):
        with (self.run / "pages.csv").open("w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(("page", "kind", "ok", "nes", "prompt_tokens", "completion_tokens"))
            writer.writerows(self.rows)
        (self.run / "summary.json").write_text(json.dumps({
            "accuracy_96": {"n": 4, "ok": 1, "nes": .25},
            "env": {"FS_PRESET": "fixture"},
            "throughput": self.throughput,
        }))
        return build.farmshare_run("fixture", ["printed", "typed"], self.prices)

    def test_kind_cost_counts_all_attempts_and_overall_counts_panel_answers(self):
        scores, hw = self.build_run()
        self.assertEqual(scores["printed"], [33.33, 1, 3])
        self.assertEqual(scores["typed"], [0, 0, 1])
        self.assertEqual(hw["usd_per_1000"], 4.5)
        self.assertAlmostEqual(hw["usd_per_1000_by_kind"]["printed"], (3000 + 2 * 8692) / 3000)
        self.assertEqual(hw["usd_per_1000_by_kind"]["typed"], .5)
        self.assertEqual(hw["photos_per_hour"], 12)

    def test_missing_metering_is_distinct_from_reported_zero(self):
        self.rows[3] = ("no-reading", "typed", "False", 0, 0, 0)
        _, hw = self.build_run()
        self.assertEqual(build.kind_cents("fixture", "typed", hw["usd_per_1000_by_kind"]["typed"])["std"], 0)
        self.rows[3] = ("no-reading", "typed", "False", 0, 0, None)
        with self.assertRaisesRegex(SystemExit, "missing token usage for typed attempts: no-reading completion_tokens"):
            self.build_run()
        self.prices = {"models": {}}
        _, hw = self.build_run()
        self.assertIsNone(hw["usd_per_1000"])
        self.assertEqual(hw["usd_per_1000_by_kind"], {})

    def test_throughput_validation_still_uses_answered_pages(self):
        self.throughput["mean_completion_tokens"] = 500
        with self.assertRaisesRegex(SystemExit, "tokens over the answered pages"):
            self.build_run()
