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
        self.report_fixture()

    def test_report_acknowledged_lost_reply_is_failed_without_fabricated_response(self):
        self.report_fixture(missing=True)

    def report_fixture(self, missing=False):
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
                if not (missing and j['examples_n'] == 8):
                    H.dump(response, dict(choices=[dict(message=dict(content='a quiet morning'))]))
                rec = dict(id=j['id'], request_sha256=H.request_hash(H.body(pack, f, j)))
                H.append(out, dict(rec, event='reserve', reservation=.08))
                if missing and j['examples_n'] == 8:
                    continue
                H.append(out, dict(rec, event='settle', cost=.001, ok=True, model=H.G.MODEL,
                                   response_sha256=H.sha(response),
                                   usage={'prompt_tokens': 10, 'completion_tokens': 10}))
            a = SimpleNamespace(pack=pack, truth=truth, out=out)
            rows = H.journal(out)
            attempts = {j['id']: H.request_hash(H.body(pack, f, j)) for j in jobs if j['examples_n'] == 8}
            with (patch.object(H, 'check', return_value=(f, jobs, {'owner-p001': {'path': 'p.txt'}})),
                  patch.object(H, 'validate_receipt', return_value={}),
                  patch.object(H, 'RESULTS', results), patch.object(HS, 'HANDS', hands),
                  patch.object(H, 'DEFAULT_OUT', out),
                  patch.object(H, 'LEGACY_OUT', root / 'unused'),
                  patch.object(H, 'ACK_ROWS', len(rows)),
                  patch.object(H, 'ACK_PREFIX', H.prefix_hash(rows)),
                  patch.object(H, 'ACK_ATTEMPTS', attempts)):
                if missing:
                    H.append(out, H.ack_event())
                H.report(a)
                r = json.loads((results / 'ocr-ppocrv6-hands-paid.json').read_text())
                self.assertTrue(r['complete'])
                self.assertEqual(r['owner_clear']['groups'][0]['nes_answered'], 100.)
                if missing:
                    self.assertEqual(r['comparisons'][0]['both_answered']['n'], 0)
                    self.assertEqual(r['comparisons'][0]['strict']['delta'], -100.)
                    self.assertAlmostEqual(r['retained_allowance'], .08)
                    self.assertAlmostEqual(r['charged'], .082)
                    self.assertEqual(r['cost']['calls'], 2)
                else:
                    self.assertEqual(r['comparisons'][0]['both_answered']['delta'], 0.)
                # A changed prompt must never be relabelled as this frozen run.
                f['prompt'] += ' changed'
                with self.assertRaisesRegex(ValueError, 'request does not match'):
                    H.report(a)
                f['prompt'] = 'Read the target only'
                H.append(out, dict(id='lost-repeat', event='reserve', request_sha256='lost', reservation=.08))
                with self.assertRaisesRegex(ValueError, 'no accuracy report'):
                    H.report(a)


if __name__ == '__main__':
    unittest.main()
