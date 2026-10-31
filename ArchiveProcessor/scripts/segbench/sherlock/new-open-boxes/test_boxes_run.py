#!/usr/bin/env python3
"""W46.ocr-new-open-boxes: boxes_run's pilot gate, records, resume and contract, with a fake adapter (no model).
   python3 test_boxes_run.py"""
import hashlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parents[1] / 'corpus'), str(HERE.parents[1])]
import boxes_run as R  # noqa: E402
import farmshare_results  # noqa: E402  (the scorers' reading(), below)


class Fake:
    kind = 'fake'
    replies = {}
    calls = []

    def __init__(self, cfg):
        self.cfg = cfg

    def settings(self):
        return {'fake': 1}

    def read(self, path):
        Fake.calls.append(path.stem)
        reply, finish = Fake.replies.get(path.stem, ('<|ref|>text<|/ref|><|det|>[[1, 2, 3, 4]]<|/det|>\nWords ' + path.stem, 'stop'))
        if reply is None:
            raise OSError('card fell over')
        text, boxes = R.B.unlimited(reply)
        return reply, text, boxes, (10, 20), {'prompt_tokens': 5, 'completion_tokens': 7}, finish


class Run(unittest.TestCase):
    def setUp(self):
        R.ADAPTERS['fake'] = Fake
        Fake.replies, Fake.calls = {}, []
        self.tmp = Path(tempfile.mkdtemp())
        img = self.tmp / 'img'
        img.mkdir()
        rows = []
        for i in range(6):
            p = img / f'p{i}.jpg'
            p.write_bytes(b'jpeg %d' % i)
            rows.append({'id': f'p{i}', 'image': str(p), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()})
        (self.tmp / 'public895.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
        (self.tmp / 'pilot3.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows[:3]))
        self.root = self.tmp / 'k'
        self.root.mkdir()
        (self.root / 'prepared.json').write_text(json.dumps({'key': 'k', 'state': 'ready', 'adapter': 'fake',
                                                             'model': 'org/m', 'revision': 'abc', 'prompt': 'go'}))
        os.environ['SESSION_ROOT'] = str(self.root)
        self.out = self.root / 'results/ocr/k'

    def main(self):
        sys.argv = ['boxes_run.py', 'public895.jsonl']
        R.main()

    def test_full_run_records_read_as_native(self):
        self.main()
        rec = json.loads((self.out / 'p4.json').read_text())
        self.assertEqual((rec['status'], rec['finish'], rec['mode'], rec['raw']), ('ok', 'stop', 'native', 'Words p4'))
        self.assertEqual(rec['boxes'][0]['box'], [1, 2, 3, 4])
        self.assertEqual(rec['model_raw'][:8], '<|ref|>t')
        self.assertEqual(farmshare_results.reading(rec, 'native'), 'Words p4')
        st = json.loads((self.root / 'status.json').read_text())
        self.assertEqual((st['state'], st['counts']), ('completed_raw', {'ok': 6, 'cap': 0}))
        self.assertEqual(sorted(Fake.calls), [f'p{i}' for i in range(6)])  # the pilot pages are not read twice

    def test_capped_pilot_stops(self):
        Fake.replies['p1'] = ('Words', 'length')
        with self.assertRaises(ValueError):
            self.main()
        self.assertFalse((self.out / 'p4.json').exists())
        self.assertEqual(json.loads((self.root / 'status.json').read_text())['state'], 'needs_inspection')

    def test_error_page_written_and_stops_then_resumes(self):
        Fake.replies['p4'] = (None, None)
        with self.assertRaises(RuntimeError):
            self.main()
        self.assertTrue((self.out / 'p4.error.json').exists())
        del Fake.replies['p4']
        Fake.calls = []
        self.main()
        self.assertEqual(Fake.calls, ['p4', 'p5'])  # the stopped run never reached p5

    def test_contract_binds_96_run(self):
        self.main()
        contract = json.loads((self.root / 'cache-contract.json').read_text())
        contract['max_new_tokens'] = 4096
        (self.root / 'sweep-contract.json').write_text(json.dumps(contract))
        with self.assertRaises(ValueError):
            self.main()

    def test_changed_image_refused(self):
        Path(json.loads((self.tmp / 'public895.jsonl').read_text().splitlines()[5])['image']).write_bytes(b'other')
        with self.assertRaises(ValueError):
            self.main()


if __name__ == '__main__':
    unittest.main()
