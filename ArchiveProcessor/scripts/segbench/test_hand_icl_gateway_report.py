"""Synthetic end-to-end reporting: original receipts, owner wrapper, no API."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import hand_icl_gateway as H
import ocr_hands_rescore as HS


class Reporting(unittest.TestCase):
    def test_report_reads_wrapped_owner_rulings_and_pins_requests(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pack, truth, out, results, hands = [root / d for d in ('pack', 'truth', 'out', 'results', 'hands')]
            for d in (pack, truth, out, results, hands):
                d.mkdir()
            (pack / 'target.jpg').write_bytes(b'synthetic image bytes')
            (pack / 'freeze.json').write_text('{}')
            (truth / 'index.json').write_text('{}')
            (truth / 'p.txt').write_text('a quiet morning')
            (hands / 'rulings.json').write_text(json.dumps({'counts': {}, 'rulings': {'p001': {}}}))
            (results / 'ocr-hands-rescore.json').write_text(json.dumps({'pages': ['p001']}))
            f = dict(prompt='Read the target only', max_tokens=8192, cohorts={'owner-transfer': 1})
            jobs = [dict(id=f'owner-p001-n{n}', page='owner-p001', cohort='owner-transfer',
                         collection='owner', image='target.jpg', examples_n=n, examples=[]) for n in H.COUNTS]
            for j in jobs:
                response = out / 'responses' / (j['id'] + '.json')
                H.dump(response, dict(choices=[dict(message=dict(content='a quiet morning'))]))
                rec = dict(id=j['id'], request_sha256=H.request_hash(H.body(pack, f, j)))
                H.append(out, dict(rec, event='reserve', reservation=.08))
                H.append(out, dict(rec, event='settle', cost=.001, ok=True, model=H.G.MODEL,
                                   response_sha256=H.sha(response)))
            a = SimpleNamespace(pack=pack, truth=truth, out=out)
            with (patch.object(H, 'check', return_value=(f, jobs, {'owner-p001': {'path': 'p.txt'}})),
                  patch.object(H, 'validate_receipt', return_value={}),
                  patch.object(H, 'RESULTS', results), patch.object(HS, 'HANDS', hands),
                  patch.object(H, 'LEGACY_OUT', root / 'unused')):
                H.report(a)
                r = json.loads((results / 'ocr-ppocrv6-hands-paid.json').read_text())
                self.assertTrue(r['complete'])
                self.assertEqual(r['owner_clear']['groups'][0]['nes_answered'], 100.)
                self.assertEqual(r['comparisons'][0]['both_answered']['delta'], 0.)
                # A changed prompt must never be relabelled as this frozen run.
                f['prompt'] += ' changed'
                with self.assertRaisesRegex(ValueError, 'request does not match'):
                    H.report(a)


if __name__ == '__main__':
    unittest.main()
