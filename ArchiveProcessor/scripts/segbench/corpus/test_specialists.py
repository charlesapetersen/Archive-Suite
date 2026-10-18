#!/usr/bin/env python3
"""Tests for specialists.py (no kraken, no network).
uv run --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex python test_specialists.py"""
import csv
import tempfile
import unittest
from pathlib import Path

import common as C
import routes as R
import specialists as SP


class Specialists(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.saved = (R.MANIFEST, R.INDEX, C.FROZEN, R.RESULTS, SP.RUN, SP.MODELS_DIR)
        R.MANIFEST, R.INDEX, C.FROZEN = self.tmp / 'manifest.jsonl', self.tmp / 'index.jsonl', self.tmp
        R.RESULTS, SP.RUN, SP.MODELS_DIR = self.tmp / 'results', self.tmp / 'run', self.tmp / 'models'
        R.RESULTS.mkdir()
        index, manifest = [], []
        for i, (stratum, script) in enumerate([('L7', 'Latn'), ('L7', 'Latn'), ('N4', 'Hebr')]):
            img, truth = self.tmp / f'p{i}.jpg', self.tmp / f'p{i}.txt'
            img.write_bytes(b'image %d' % i); truth.write_text('in nomine domini amen')
            index.append({'key': f's:p{i}', 'stratum': stratum, 'image': img.name, 'truth': truth.name})
            manifest.append({'source': 's', 'page_id': f'p{i}', 'stratum': stratum, 'script': script,
                             'image_sha256': C.sha256(img), 'truth_sha256': C.sha256(truth)})
        C.write_jsonl(R.INDEX, index); C.write_jsonl(R.MANIFEST, manifest)

    def tearDown(self):
        R.MANIFEST, R.INDEX, C.FROZEN, R.RESULTS, SP.RUN, SP.MODELS_DIR = self.saved

    def test_batches_cover_every_page_once(self):
        xs = list(range(23))
        self.assertEqual(sum(SP.batches(xs), []), xs)
        self.assertTrue(all(len(b) <= SP.BATCH for b in SP.batches(xs)))

    def test_missing_model_names_the_download(self):
        with self.assertRaises(SystemExit) as e:
            SP.model_path('catmus-medieval')
        self.assertIn('10.5281/zenodo.12743230', str(e.exception))

    def test_collect_refuses_unsegmented_pages(self):
        f = SP.MODELS_DIR / 'u' / SP.MODELS['catmus-medieval']['file']
        f.parent.mkdir(parents=True); f.write_bytes(b'')
        with self.assertRaises(SystemExit) as e:
            SP.collect(['catmus-medieval'])
        self.assertIn('not segmented', str(e.exception))

    def test_visual_order_reverses_by_grapheme(self):
        # The point (U+05B4) stays after the letter it was stored after.
        self.assertEqual(SP.logical('ןירסח\nםִכ'), 'חסרין\nכםִ')

    def test_report_pairs_against_the_general_routes(self):
        [a, b] = SP.pages(['L7'])
        for r, text in ((a, 'in nomine domini amen'), (b, '')):
            p = SP.text_path('catmus-medieval', r); p.parent.mkdir(parents=True, exist_ok=True); p.write_text(text)
        with open(R.RESULTS / 'routes-pages.csv', 'w', newline='') as f:
            w = csv.DictWriter(f, ['route', 'page', 'ok', 'nes'])
            w.writeheader()
            for r in (a, b):
                w.writerow({'route': 'gemini3.8-flash', 'page': R.job_id(r), 'ok': 'True', 'nes': '0.5'})
                w.writerow({'route': 'qwen3-vl-235b', 'page': R.job_id(r), 'ok': 'False', 'nes': ''})
        SP.report()
        with open(R.RESULTS / 'specialists.csv', newline='') as f:
            [row] = list(csv.DictReader(f))
        self.assertEqual((row['route'], row['stratum'], row['n'], row['ok']), ('catmus-medieval', 'L7', '2', '1'))
        self.assertAlmostEqual(float(row['nes']), 0.5)
        self.assertAlmostEqual(float(row['vs_gemini']), 0.0)    # (1 - .5 + 0 - .5) / 2
        self.assertAlmostEqual(float(row['vs_qwen']), 0.5)      # a failed general route scores 0


if __name__ == '__main__':
    unittest.main()
