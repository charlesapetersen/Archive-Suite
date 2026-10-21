import json
import tempfile
import unittest
from pathlib import Path

import farmshare_truth96 as T


class Sacct(unittest.TestCase):
    def test_elapsed_forms(self):
        self.assertEqual(T.elapsed_seconds('00:02:55'), 175)
        self.assertEqual(T.elapsed_seconds('1-02:00:01'), 93601)
        self.assertEqual(T.elapsed_seconds('04:21'), 261)
        with self.assertRaises(ValueError):
            T.elapsed_seconds('Unknown')

    def test_parsable_sacct_rows_keyed_by_job(self):
        text = ('JobID|JobName|State|Elapsed|NodeList\n'
                '1861696|t96-glm-ocr|COMPLETED|00:02:55|oat-05\n'
                '1861703|t96-ling3-flash-vl-fp8|PENDING|00:00:00|None assigned\n')
        rows = T.read_sacct(text)
        self.assertEqual(rows['1861696']['elapsed_s'], 175)
        self.assertEqual(rows['1861703']['State'], 'PENDING')
        self.assertEqual(rows['1861703']['elapsed_s'], 0)


class Outcomes(unittest.TestCase):
    def test_each_failure_kind_is_named(self):
        ok = {'status': 'ok', 'finish': 'stop', 'raw': 'KIND: typewritten\nTABLE: no\nTEXT:\nhello'}
        self.assertEqual(T.outcome(ok, 'panel', 'hello'), 'ok')
        self.assertEqual(T.outcome(None, 'native', ''), 'missing')
        self.assertEqual(T.outcome({'status': 'cap', 'finish': 'length', 'raw': 'x' * 50}, 'native', ''), 'cap')
        self.assertEqual(T.outcome({'status': 'error', 'finish': None, 'raw': ''}, 'native', ''), 'error')
        self.assertEqual(T.outcome({'status': 'ok', 'finish': 'stop', 'raw': 'no panel headers'}, 'panel', ''),
                         'unparsable')
        self.assertEqual(T.outcome({'status': 'ok', 'finish': 'stop', 'raw': '  '}, 'native', ''), 'blank')
        # the pipeline has no decoder, so no finish reason: an empty status-ok reading is blank, not an error
        self.assertEqual(T.outcome({'status': 'ok', 'finish': None, 'raw': ''}, 'pipeline', ''), 'blank')

    def test_outcome_agrees_with_reading(self):
        for rec, mode in (({'status': 'ok', 'finish': 'stop', 'raw': 'text'}, 'native'),
                          ({'status': 'ok', 'finish': None, 'raw': 'lines'}, 'pipeline'),
                          ({'status': 'ok', 'finish': None, 'raw': 'lines'}, 'native')):
            text = T.X.reading(rec, mode)
            self.assertEqual(T.outcome(rec, mode, text) == 'ok', bool(text))

    def test_repetitive_cap(self):
        self.assertTrue(T.repetitive('the same line again\n' * 400))
        self.assertFalse(T.repetitive('A short varied reply, nothing repeated.'))
        self.assertFalse(T.repetitive(''))


class Wall(unittest.TestCase):
    def test_vllm_wall_adds_pilot_and_full_pass_and_pipeline_sums_pages(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / 'glm-ocr'
            (root / 'results' / 'ocr' / 'glm-ocr').mkdir(parents=True)
            (root / 'pilot-summary.json').write_text(json.dumps({'wall_s': 3.2}))
            (root / 'results' / 'ocr' / 'glm-ocr' / 'summary.json').write_text(json.dumps({'wall_s': 99.71}))
            self.assertAlmostEqual(T.collector_wall(root, 'native', {}), 102.91)
        recs = {'p001': {'wall_s': 1.5}, 'p002': {'wall_s': 0.5}, 'p003': {}}
        self.assertAlmostEqual(T.collector_wall(Path('/nowhere'), 'pipeline', recs), 2.0)
        self.assertEqual(T.readings_dir(Path('/x/ppocrv6-medium-native'), 'pipeline'), Path('/x/ppocrv6-medium-native/raw'))
        self.assertEqual(T.readings_dir(Path('/x/qwen35-4b'), 'panel'), Path('/x/qwen35-4b/results/ocr/qwen35-4b'))


if __name__ == '__main__':
    unittest.main()
