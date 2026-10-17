#!/usr/bin/env python3
"""Tests for routes.py's frozen-page checks (no network, no paid call). python3 test_routes.py"""
import json
import tempfile
import unittest
from pathlib import Path

import common as C
import routes as R


class Frozen(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.saved = (R.MANIFEST, R.INDEX, C.FROZEN)
        R.MANIFEST, R.INDEX, C.FROZEN = self.tmp / 'manifest.jsonl', self.tmp / 'index.jsonl', self.tmp
        img, truth = self.tmp / 'p.jpg', self.tmp / 'p.txt'
        img.write_bytes(b'image'); truth.write_text('truth')
        row = {'source': 's', 'page_id': 'a/b', 'stratum': 'L5', 'script': 'Latn'}
        C.write_jsonl(R.INDEX, [{'key': 's:a/b', 'stratum': 'L5', 'image': 'p.jpg', 'truth': 'p.txt'}])
        C.write_jsonl(R.MANIFEST, [{**row, 'image_sha256': C.sha256(img), 'truth_sha256': C.sha256(truth)}])
        self.img, self.truth = img, truth

    def tearDown(self):
        R.MANIFEST, R.INDEX, C.FROZEN = self.saved

    def test_frozen_page_joins_its_paths(self):
        [r] = R.frozen()
        self.assertEqual(r['image'], str(self.img))
        self.assertEqual(R.job_id(r), 's__a_b')

    def test_changed_truth_is_refused(self):
        self.truth.write_text('truth, edited after the freeze')
        with self.assertRaises(SystemExit):
            R.frozen()

    def test_page_not_kept_is_refused(self):
        C.write_jsonl(R.INDEX, [])
        with self.assertRaises(SystemExit):
            R.frozen()

    def test_run_order_is_fixed_and_input_order_free(self):
        jobs = [{'id': f'j{i:03d}'} for i in range(50)]
        self.assertEqual(R.run_order(jobs), R.run_order(list(reversed(jobs))))
        self.assertNotEqual([j['id'] for j in R.run_order(jobs)], [j['id'] for j in jobs])

    def test_routes_are_the_two_pinned_reference_routes(self):
        self.assertEqual(set(R.ROUTES), {'gemini3.8-flash', 'qwen3-vl-235b'})
        self.assertLessEqual(R.CAP, 5.10)
        json.dumps(R.ROUTES)


if __name__ == '__main__':
    unittest.main()
