"""Offline contracts for the paid runner: leakage, accounting, and outcomes."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from contextlib import ExitStack
from types import SimpleNamespace

import hand_icl_gateway as H


class Reply:
    status_code = 200
    headers = {'x-litellm-response-cost': '.004'}

    def __init__(self, finish='stop', text='a reading', usage=True):
        self.finish, self.text, self.usage = finish, text, usage

    def json(self):
        return {'model': H.G.MODEL, 'choices': [{'finish_reason': self.finish,
                                               'message': {'content': self.text}}],
                'usage': {'prompt_tokens': 100, 'completion_tokens': 100} if self.usage else None}


class Contracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / 'target.jpg').write_bytes(b'fake JPEG')
        self.job = dict(id='p-n0', page='p', cohort='test', examples_n=0,
                        image='target.jpg', examples=[])
        self.freeze = dict(prompt='Read the target', max_tokens=8192)
        self.out = self.root / 'out'
        self.legacy_patch = patch.object(H, 'LEGACY_OUT', self.root / 'legacy')
        self.legacy_patch.start()
        self.default_patch = patch.object(H, 'DEFAULT_OUT', self.out)
        self.default_patch.start()

    def tearDown(self):
        self.default_patch.stop()
        self.legacy_patch.stop()
        self.temp.cleanup()

    def call(self, reply=None):
        return H.call(self.root, self.freeze, self.job, self.out,
                      request=lambda *a, **k: reply or Reply())

    def test_no_target_truth_in_request(self):
        body = H.body(self.root, self.freeze, self.job)
        self.assertEqual(body['cache'], {'no-cache': True})
        self.assertEqual(len(body['messages'][0]['content']), 3)
        self.assertNotIn('truth', json.dumps(body))

    def test_reservation_precedes_request_and_larger_charge_wins(self):
        def request(*a, **k):
            pending, done, spent = H.state(H.journal(self.out))
            self.assertEqual(set(pending), {'p-n0'})
            self.assertFalse(done)
            self.assertEqual(spent, H.RESERVE)
            return Reply()
        H.call(self.root, self.freeze, self.job, self.out, request=request)
        pending, done, spent = H.state(H.journal(self.out))
        self.assertFalse(pending)
        self.assertEqual(spent, .004)
        self.assertTrue(done['p-n0']['ok'])

    def test_known_request_not_repeated(self):
        self.call()
        def fail(*a, **k):
            self.fail('duplicate request')
        H.call(self.root, self.freeze, self.job, self.out, request=fail)
        self.assertEqual(len(H.journal(self.out)), 2)

    def test_changed_prompt_rejected(self):
        self.call()
        self.freeze['prompt'] += ' changed'
        with self.assertRaisesRegex(ValueError, 'cached request differs'):
            self.call()

    def test_unknown_charge_never_retried(self):
        def lost(*a, **k):
            raise TimeoutError('lost response')
        with self.assertRaisesRegex(RuntimeError, 'uncertain paid attempt'):
            H.call(self.root, self.freeze, self.job, self.out, request=lost)
        self.assertEqual(H.state(H.journal(self.out))[2], H.RESERVE)
        with self.assertRaisesRegex(ValueError, 'uncertain billing'):
            self.call()

    def test_cap_blocks_before_request(self):
        self.out.mkdir()
        n = int(H.CAP / H.RESERVE)  # the most whole reservations under the cap
        for i in range(n):
            r = dict(id=str(i), request_sha256=str(i))
            H.append(self.out, dict(r, event='reserve', reservation=H.RESERVE))
            H.append(self.out, dict(r, event='settle', cost=.08,
                                   usage={'prompt_tokens': 0, 'completion_tokens': 0}))
        with self.assertRaisesRegex(ValueError, 'item cap'):
            self.call()
        self.assertEqual(len(H.journal(self.out)), 2 * n)

    def test_custom_output_still_counts_original_pilot(self):
        H.LEGACY_OUT.mkdir()
        H.append(H.LEGACY_OUT, dict(id='old', event='reserve', request_sha256='old', reservation=.08))
        with self.assertRaisesRegex(ValueError, 'outstanding'):
            self.call()
        H.append(H.LEGACY_OUT, dict(id='old', event='settle', request_sha256='old', cost=round(H.CAP - .04, 2),
                                  usage={'prompt_tokens': 0, 'completion_tokens': 0}))
        with self.assertRaisesRegex(ValueError, 'item cap'):
            self.call()
        self.assertEqual(H.journal(self.out), [])

    def test_new_output_cannot_escape_original_unknown(self):
        self.out.mkdir()
        H.append(self.out, dict(id='unknown', event='reserve', request_sha256='lost', reservation=.08))
        with self.assertRaisesRegex(ValueError, 'uncertain billing in another'):
            H.call(self.root, self.freeze, self.job, self.root / 'new-out', request=lambda *a, **k: self.fail('must not send'))

    def test_length_and_empty_are_failed_without_retry(self):
        for finish, text in [('length', 'cut off'), ('stop', ''), ('stop', None)]:
            with self.subTest(finish=finish, text=text):
                self.job['id'] = 'p-' + str(len(H.journal(self.out)))
                self.assertFalse(self.call(Reply(finish, text))['ok'])

    def test_missing_usage_reserves_full_cost(self):
        with self.assertRaisesRegex(ValueError, 'no complete billing usage'):
            self.call(Reply(usage=False))
        self.assertEqual(H.state(H.journal(self.out))[2], H.RESERVE)
        with self.assertRaisesRegex(ValueError, 'uncertain billing'):
            self.call()

    def test_partial_invalid_usage_is_unknown(self):
        for usage in [{}, {'prompt_tokens': 12}, {'prompt_tokens': 0, 'completion_tokens': -1},
                      {'prompt_tokens': float('nan'), 'completion_tokens': 1}]:
            self.assertFalse(H.known_usage(usage))
        self.assertTrue(H.known_usage({'prompt_tokens': 12, 'completion_tokens': 20}))

    def test_keychain_timeout_precedes_spend(self):
        import subprocess
        with patch.object(H.subprocess, 'run', side_effect=subprocess.TimeoutExpired('security', 20)):
            with self.assertRaisesRegex(ValueError, 'no paid call made'):
                H.load_key()
        self.assertFalse(H.journal(self.out))

    def test_partial_usage_charges_full_reservation(self):
        class Partial(Reply):
            def json(self):
                return dict(super().json(), usage={'prompt_tokens': 100})
        with self.assertRaisesRegex(ValueError, 'no complete billing usage'):
            self.call(Partial())
        self.assertEqual(H.state(H.journal(self.out))[2], H.RESERVE)

    def test_wrong_model_is_not_accepted(self):
        class Wrong(Reply):
            def json(self):
                return dict(super().json(), model='different-reader')
        self.assertFalse(self.call(Wrong())['ok'])

    def test_outcome_without_reservation_rejected(self):
        with self.assertRaisesRegex(ValueError, 'matching reservation'):
            H.state([dict(event='settle', id='p', request_sha256='x')])

    def test_path_escape_rejected(self):
        for name in ['../secret', '/etc/passwd']:
            with self.assertRaises(ValueError):
                H.inside(self.root, name)

    def test_output_rejection_writes_nothing(self):
        from types import SimpleNamespace
        pack, truth = self.root / 'pack', self.root / 'truth'
        pack.mkdir(); truth.mkdir()
        for out in [pack, truth / 'new']:
            a = SimpleNamespace(out=out, pack=pack, truth=truth)
            with self.assertRaisesRegex(ValueError, 'separate'):
                H.run(a)
        self.assertEqual(list(pack.iterdir()), [])
        self.assertEqual(list(truth.iterdir()), [])

    def test_examples_stay_separate_and_ordered(self):
        examples = [dict(id=str(i), image='target.jpg', text=f'corrected line {i}') for i in range(2)]
        self.job.update(examples=examples, examples_n=2)
        content = H.body(self.root, self.freeze, self.job)['messages'][0]['content']
        self.assertEqual(sum(x['type'] == 'image_url' for x in content), 3)
        self.assertEqual(content[3]['text'], 'Corrected reading: corrected line 0')
        self.assertEqual(content[6]['text'], 'Corrected reading: corrected line 1')

    def test_exact_acknowledgment_preserves_ledger_and_never_resends(self):
        self.out.mkdir()
        pack = self.root / 'pack'
        pack.mkdir()
        (pack / 'target.jpg').write_bytes(b'fake JPEG')
        ids = ['lost', 'bad-gateway']
        jobs = [dict(self.job, id=k) for k in ids]
        attempts = {j['id']: H.request_hash(H.body(self.root, self.freeze, j)) for j in jobs}
        for k in ids:
            H.append(self.out, dict(id=k, event='reserve', request_sha256=attempts[k], reservation=.08))
        H.append(self.out, dict(id=ids[1], event='settle', request_sha256=attempts[ids[1]],
                               cost=.08, usage={}, ok=False))
        prefix = (self.out / 'calls.jsonl').read_bytes()
        with ExitStack() as stack:
            for key, value in dict(ACK_ROWS=3, ACK_PREFIX=H.sha(self.out / 'calls.jsonl'),
                                   ACK_ATTEMPTS=attempts, DEFAULT_PACK=pack,
                                   DEFAULT_TRUTH=self.root / 'truth').items():
                stack.enter_context(patch.object(H, key, value))
            stack.enter_context(patch.object(H, 'check', return_value=(self.freeze, jobs, {})))
            stack.enter_context(patch.object(H, 'validate_receipt', return_value={}))
            a = SimpleNamespace(out=self.out, pack=pack, truth=self.root / 'truth')
            H.acknowledge(a)
            H.acknowledge(a)  # Recover an interruption after the single append.
            self.assertTrue((self.out / 'calls.jsonl').read_bytes().startswith(prefix))
            self.assertEqual(len(H.journal(self.out)), 4)
            pending, done, spent = H.state(H.journal(self.out))
            self.assertFalse(pending)
            self.assertAlmostEqual(spent, .16)
            self.assertTrue(all(not r['ok'] and r['acknowledged_uncertain'] for r in done.values()))
            H.require_clear_billing(self.out)
            for j in jobs:
                H.call(self.root, self.freeze, j, self.out,
                       request=lambda *a, **k: self.fail('acknowledged request repeated'))
            # No foreign ID, mutated prefix, duplicate acknowledgment or later
            # reservation can turn an authorized failure into a retry.
            rows = H.journal(self.out)
            for changed in [rows + [H.ack_event()],
                            [dict(rows[0], reservation=.01), *rows[1:]],
                            [*rows[:2], dict(rows[2], acknowledged_uncertain=True), rows[3]],
                            rows + [dict(rows[0])],
                            [*rows[:3], dict(rows[3], retained_per_attempt=.01)]]:
                with self.assertRaises(ValueError):
                    H.state(changed)
            H.append(self.out, dict(id='new-lost', event='reserve', request_sha256='new', reservation=.08))
            with self.assertRaisesRegex(ValueError, 'uncertain billing'):
                H.require_clear_billing(self.out)
            with self.assertRaisesRegex(ValueError, 'exact authorized ledger prefix'):
                H.state(H.journal(self.out) + [H.ack_event()])

    def test_paid_resume_rejects_other_output_before_credentials(self):
        a = SimpleNamespace(out=self.root / 'new-out', pack=self.root / 'pack', truth=self.root / 'truth', cmd='run')
        with patch.object(H, 'load_key', side_effect=AssertionError('must not read key')):
            with self.assertRaisesRegex(ValueError, 'original frozen'):
                H.run(a)

    def test_cluster_bootstrap_counts_collections(self):
        v = H.interval([1, 1, -3, -3], ['a', 'a', 'b', 'b'], rounds=1000)
        self.assertEqual(v['clusters'], 2)
        self.assertEqual(v['delta'], -1)
        self.assertEqual((v['lo'], v['hi']), (-3, 1))

    def test_failed_output_is_never_scored_as_a_reading(self):
        jobs = [dict(self.job, examples_n=n, id=f'p-n{n}', collection='a') for n in H.COUNTS]
        rows = {j['id']: dict(ok=j['examples_n'] != 8) for j in jobs}
        seen = []
        def score(truth, text, stratum):
            seen.append((text, stratum))
            return dict(nes=.9 if text else 0., missed=0 if text else 1, added=0, words=1)
        out = H.analyze(jobs, rows, {'p': 'truth'}, {j['id']: 'raw' for j in jobs}, score)
        self.assertEqual(seen[1], ('', 'L1'))
        self.assertEqual(out['groups'][1]['nes_strict'], 0)
        self.assertEqual(out['comparisons'][0]['both_answered']['n'], 0)
        self.assertEqual(out['comparisons'][0]['strict']['delta'], -90)


if __name__ == '__main__':
    unittest.main()
