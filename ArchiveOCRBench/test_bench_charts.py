"""Tests for ArchiveOCRBench tag-subset charts (W49.bench-more-kinds), NewsBench chart, and seg checking chart."""
import csv
import json
import unittest
from pathlib import Path

import build

ROOT = Path(__file__).resolve().parent


class BenchChartsTests(unittest.TestCase):
    def test_tag_subset_charts_cover_clippings_tables_and_table_forms_without_mixed(self):
        d = json.loads((ROOT / "data" / "panel-data.json").read_text())
        by_key = {c["key"]: c for c in d["tag_charts"]}
        self.assertEqual(list(by_key.keys()), ["clippings", "tables", "table_form"])
        self.assertNotIn("mixed", by_key)
        self.assertEqual(by_key["clippings"]["n"], 13)
        self.assertEqual(by_key["tables"]["n"], 12)
        self.assertEqual(by_key["table_form"]["n"], 4)

        # Clippings and tables include all 60 whole-page routes + 17 crop arms (12 open + 2 gateway + 3 layout-photo).
        self.assertEqual(len(by_key["clippings"]["scores"]), 77)
        self.assertEqual(len(by_key["tables"]["scores"]), 77)
        # Table forms covers all 60 whole-page routes.
        self.assertEqual(len(by_key["table_form"]["scores"]), 60)

        # Cross-check cloud panel scores against ocr-panel-cloud-groups.csv directly.
        with build.CLOUD_CSV.open(newline="") as f:
            cloud = {(r["route"], r["attribute"], r["value"]): r for r in csv.DictReader(f)}
        for key, attr in (("clippings", "clippings_tag"), ("tables", "tables_tag"), ("table_form", "table_form")):
            c = by_key[key]
            for (rid, a, v), row in cloud.items():
                if a == attr and v == "yes" and rid in c["scores"]:
                    self.assertAlmostEqual(c["scores"][rid][0], round(100 * float(row["nes"]), 2), places=2)
                    self.assertEqual(c["scores"][rid][1], int(row["ok"]))
                    self.assertEqual(c["scores"][rid][2], int(row["n"]))

        # OpenRouter-priced FarmShare runs carry subset-specific prices.
        self.assertIn("qwen3.6-27b-farmshare", by_key["clippings"]["prices"])
        self.assertGreater(by_key["clippings"]["prices"]["qwen3.6-27b-farmshare"]["std"], 0)
        # table_only runs also receive subset scores.
        for e in d["table_only"]:
            for key in ("clippings", "tables", "table_form"):
                self.assertIn(key, e["scores"])

    def test_template_handles_subset_charts_safely(self):
        html = (ROOT / "site" / "index.html").read_text()
        self.assertIn("DATA.tag_charts", html)
        self.assertIn('"clippings"', html)
        self.assertIn('"tables"', html)
        self.assertIn('"table_form"', html)

    def test_newsbench_chart_renders_all_measured_and_reference_rows(self):
        d = json.loads((ROOT / "data" / "panel-data.json").read_text())
        self.assertEqual(len(d["farmshare"]["news"]), 7)
        self.assertEqual(len(d["farmshare"]["news_reference"]), 5)
        for row in d["farmshare"]["news"] + d["farmshare"]["news_reference"]:
            for metric in ("overall", "broadsheet", "page"):
                self.assertGreater(row[metric], 0)
                self.assertLessEqual(row[metric], 1.0)
        html = (ROOT / "site" / "index.html").read_text()
        self.assertIn('id="fs-news-chart"', html)
        self.assertIn("renderNews()", html)

    def test_segmentation_checking_chart_covers_all_routes_and_identifies_shared_points(self):
        d = json.loads((ROOT / "data" / "panel-data.json").read_text())
        seg = d["segmentation"]
        self.assertEqual(len(seg), 15)
        groups = {}
        for row in seg:
            self.assertIsNotNone(row["checks"])
            self.assertIsNotNone(row["after"])
            key = (round(row["checks"], 1), round(row["after"], 1))
            groups.setdefault(key, []).append(row["name"])
        self.assertIn((10.2, 98.5), groups)
        self.assertEqual(sorted(groups[(10.2, 98.5)]), ["Claude and ChatGPT together", "Claude only"])
        self.assertIn((86.8, 100.0), groups)
        self.assertEqual(len(groups[(86.8, 100.0)]), 3)
        html = (ROOT / "site" / "index.html").read_text()
        self.assertIn('id="seg-check-canvas"', html)
        self.assertIn("renderSegCheck()", html)


if __name__ == "__main__":
    unittest.main()
