"""Scoring a subset of readers on the whole bank: the bank run is Qwen alone."""
import json
import unittest
from unittest.mock import patch
import regions_cells as R
import regions_cells_bank as B
import test_regions_cells as F


class Bank(unittest.TestCase):
    setUp = F.Pilot.setUp
    runtime = F.Pilot.runtime

    def collect(self, route, phase='all'):
        def post(url, body, timeout):
            fields = json.loads(body['messages'][0]['content'][1]['text'].split('Fields: ')[1])
            vals = {'heading': 'A heading', 'text': 'some words', 'blank': '', 'unknown': 'guessed', 'num': '10.5'}
            return json.dumps({k: vals[k] for k in fields}), 'stop', {}
        for arm in R.ARMS:
            with patch.object(R.C, 'post', side_effect=post), patch('builtins.print'):
                R.read(self.root, route, arm, 'http://127.0.0.1:12345', self.runtime(route), phase)

    def test_qwen_only_scores_every_page_and_restores_module(self):
        self.collect('qwen3.6-27b')
        with self.assertRaisesRegex(ValueError, 'incomplete collection'):
            R.score(self.root, 'all')   # the plain scorer wants GLM receipts too
        out = B.score(self.root, ['qwen3.6-27b'])
        self.assertEqual(R.ROUTES, ('glm-ocr', 'qwen3.6-27b'))
        self.assertIsNot(R.check, None); self.assertEqual(R.check.__name__, 'check')
        self.assertEqual(out['routes_scored'], ['qwen3.6-27b'])
        self.assertEqual(set(out['requests']), {'qwen3.6-27b'})
        self.assertEqual(out['requests']['qwen3.6-27b']['cell']['ok'], 15)
        self.assertEqual({x['page'] for x in out['rows']}, {'public1', 'p024', 'public2'})
        self.assertTrue(out['capability']['qwen3.6-27b']['schema_and_coverage_ok'])

    def test_capability_receipts_alone_are_incomplete_for_the_bank(self):
        self.collect('qwen3.6-27b', 'capability')
        with self.assertRaisesRegex(ValueError, 'incomplete collection'):
            B.score(self.root, ['qwen3.6-27b'])

    def test_still_checks_the_freeze(self):
        self.collect('qwen3.6-27b')
        (self.root / 'truth.json').write_bytes(b'{}')
        with self.assertRaisesRegex(ValueError, 'frozen truth changed'):
            B.score(self.root, ['qwen3.6-27b'])

    def test_unknown_or_repeated_reader_refused(self):
        for routes in ([], ['tesseract'], ['qwen3.6-27b', 'qwen3.6-27b']):
            with self.assertRaises(ValueError):
                B.score(self.root, routes)


if __name__ == '__main__':
    unittest.main()
