"""W46.ocr-regions: exact chart subsets and own-token prices, no inferred throughput."""
import json
import unittest
from pathlib import Path

import build


class RegionCharts(unittest.TestCase):
    def test_kind_subsets_and_capped_token_cost_are_independent_of_annotation_groups(self):
        rows = [dict(route='qwen3.6-27b', arm='tiles', group=g, n=n, ok=n-1, nes=nes,
                     prompt_tokens=96000, completion_tokens=9600)
                for g,n,nes in [('the 96',96,.9),('kind:typewritten',50,.95),('kind:printed',28,.8),
                                ('kind:handwritten',16,.7),('handwritten',20,.1)]]
        data = dict(rows=rows, readers=['qwen3.6-27b'], arms=['tiles'])
        op = {'models': {'qwen3.6-27b': {'in': .25, 'out': 2}}}
        r, = build.region_chart_routes(data, ['typewritten','printed','handwritten'], op)
        self.assertEqual(r['std'], .45)  # 1,000 input + 100 output tokens per page, including failed crops
        self.assertEqual(r['scores']['handwritten'], [70.0,15,16])
        self.assertIsNone(r['hw']['photos_per_hour'])
        self.assertIsNone(r['hw']['gpu_hours_per_100k'])
        self.assertFalse(r['free_cluster'])

    def test_committed_run_has_twelve_routes_on_all_four_eligible_charts(self):
        root = Path(__file__).parent
        d = json.loads((root/'data/panel-data.json').read_text())
        crop = [r for r in d['routes'] if r['id'].startswith('regions-')]
        self.assertEqual(len(crop),12)
        for chart in d['charts']:
            for r in crop:
                self.assertEqual(chart['scores'][r['id']][2], chart['n'])
        for r in crop:
            self.assertEqual(r['free_cluster'], 'qwen3.6-27b' not in r['id'])
            if 'qwen3.6-27b' in r['id']:
                self.assertGreater(r['std'],0)


if __name__ == '__main__':
    unittest.main()
