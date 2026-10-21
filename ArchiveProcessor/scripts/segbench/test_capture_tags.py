"""Synthetic tests for capture_tags: the paired loss, provider failures, the ladder drop; no corpus or network."""
import csv
import json
from pathlib import Path
import tempfile
import unittest

import capture_tags as C

ATTRS = ['neighbour', 'curl']


def page(pid, source='original', **tags):
    return {'page': pid, 'source': source, **{a: tags.get(a, 0) for a in ATTRS}}


class CaptureTags(unittest.TestCase):
    def setUp(self):
        self.tags = {p['page']: p for p in [
            page('p1', neighbour=2), page('p2'), page('p3'), page('p4', 'pdf image', curl=1), page('p5', 'pdf image')]}
        self.kinds = {p: 'typewritten' for p in self.tags}
        self.scores = {'r': {'p1': 70.0, 'p2': 90.0, 'p3': 80.0, 'p4': 60.0, 'p5': 95.0}}

    def test_loss_is_paired_within_kind_and_source(self):
        res = C.analyse(ATTRS, self.tags, self.scores, self.kinds)
        self.assertEqual(res['neighbour']['per_route']['r'], (-15.0, 1))  # 70 against the originals' 85
        self.assertEqual(res['curl']['per_route']['r'], (-35.0, 1))       # 60 against the pdf image's 95
        self.assertEqual(res['neighbour']['severe'], 1)
        self.assertEqual(res['any']['per_route']['r'], (-25.0, 2))

    def test_baseline_is_pages_without_that_tag(self):
        self.tags['p2']['curl'] = 1  # p2 carries another tag, so it still counts against neighbour, not against any
        res = C.analyse(ATTRS, self.tags, self.scores, self.kinds)
        self.assertEqual(res['neighbour']['per_route']['r'], (-15.0, 1))
        self.assertEqual(res['any']['per_route']['r'][1], 3)  # p1, p2 against p3; p4 against p5
        self.assertAlmostEqual(res['any']['per_route']['r'][0], (-10 + 10 - 35) / 3)

    def test_unpaired_page_is_left_out(self):
        self.kinds['p4'] = 'printed'
        res = C.analyse(ATTRS, self.tags, self.scores, self.kinds)
        self.assertEqual(res['curl']['per_route']['r'], (None, 0))
        self.assertEqual(res['curl']['unpaired'], 1)

    def test_provider_failure_dropped_loop_kept(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'pages.csv'
            with open(path, 'w', newline='') as f:
                w = csv.writer(f)
                w.writerow(['route', 'page', 'kind', 'ok', 'nes', 'finish'])
                w.writerow(['r', 'p1', 'printed', 'False', '0.0', 'error'])
                w.writerow(['r', 'p2', 'printed', 'False', '0.0', 'length'])
                w.writerow(['r', 'p3', 'printed', 'True', '0.5', ''])
            scores, kinds = C.load_scores(path)
        self.assertEqual(scores['r'], {'p2': 0.0, 'p3': 50.0})
        self.assertEqual(kinds['p1'], 'printed')

    def test_ladder_drop_by_tag(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'scores.csv'
            with open(path, 'w', newline='') as f:
                w = csv.writer(f)
                w.writerow(['key', 'page', 'scale', 'ok', 'attempted', 'nes'])
                for pid, o, q in [('p1', 0.9, 0.5), ('p2', 0.9, 0.8)]:
                    w.writerow(['r', pid, 'original', 'True', 'True', o])
                    w.writerow(['r', pid, 'quarter', 'True', 'True', q])
            pages, out = C.ladder(path, self.tags, ATTRS)
        self.assertEqual(pages, ['p1', 'p2'])
        nt, th, tq, nu, uh, uq = out['neighbour']
        self.assertEqual((nt, nu, th), (1, 1, None))
        self.assertAlmostEqual(tq, 40.0)
        self.assertAlmostEqual(uq, 10.0)

    def test_report_renders(self):
        res = C.analyse(ATTRS, self.tags, self.scores, self.kinds)
        text = C.report(ATTRS, self.tags, self.kinds, res, 'method.')
        self.assertIn('| neighbour | 1 | 1 |', text)
        self.assertIn('too few', text)


if __name__ == '__main__':
    unittest.main()
