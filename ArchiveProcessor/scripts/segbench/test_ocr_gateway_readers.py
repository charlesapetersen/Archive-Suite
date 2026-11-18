"""W46.gateway-gpt-claude-readers' route choice, sample, estimate and cap, on toy data.
Run: python3 test_ocr_gateway_readers.py   (no bench data, no network, no key)."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import gateway_gemini as G
import ocr_gateway_readers as X


def jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(''.join(json.dumps(r) + '\n' for r in rows))


class Pick(unittest.TestCase):
    def test_strongest_listed_wins(self):
        ids = ['gemini-3.7-flash', 'gpt-5.6-luna', 'gpt-5.2', 'claude-sonnet-5', 'claude-opus-4-6']
        self.assertEqual(X.pick(ids, 'gpt')[0], 'gpt-5.2')
        self.assertEqual(X.pick(ids, 'claude')[0], 'claude-sonnet-5')

    def test_none_when_the_family_is_absent(self):
        self.assertIsNone(X.pick(['gemini-3.7-flash'], 'claude'))


class Sample(unittest.TestCase):
    jobs = [{'id': f'{s}-{i}', 'stratum': s} for s in ('L1', 'L9') for i in range(30 if s == 'L1' else 5)]

    def test_n_a_stratum_and_all_of_a_small_one(self):
        got = X.sample(self.jobs, 10)
        self.assertEqual(sum(j['stratum'] == 'L1' for j in got), 10)
        self.assertEqual(sum(j['stratum'] == 'L9' for j in got), 5)

    def test_deterministic_and_order_kept(self):
        a, b = X.sample(self.jobs, 7), X.sample(list(reversed(self.jobs)), 7)
        self.assertEqual({j['id'] for j in a}, {j['id'] for j in b})
        self.assertEqual(a, [j for j in self.jobs if j in a])


class Estimate(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        jsonl(self.tmp / 'panel' / 'calls.jsonl', [
            {'model': 'anthropic/claude-sonnet-5.5', 'status': 'ok', 'prompt_tokens': 1000, 'completion_tokens': 500, 'cost': 0.02},
            {'model': 'anthropic/claude-sonnet-5.5', 'status': 'http-rejected', 'prompt_tokens': None,
             'completion_tokens': None, 'cost': 0}])
        jsonl(self.tmp / 'gateway-gemini' / 'calls.jsonl', [{'http': 200, 'usage': {'completion_tokens': 100}}])
        jsonl(self.tmp / 'public' / 'calls.jsonl', [{'http': 200, 'usage': {'completion_tokens': 200}}])
        self.p = [mock.patch.object(G, 'PANEL', self.tmp / 'panel'), mock.patch.object(G, 'REHEARSAL', self.tmp),
                  mock.patch.object(X, 'PUBLIC', self.tmp / 'public')]
        for p in self.p:
            p.start()

    def tearDown(self):
        for p in self.p:
            p.stop()

    def test_bill_is_the_basis_and_failures_are_dropped(self):
        e = X.per_page('claude', 'claude-sonnet-5-5', (2.0, 10.0))
        self.assertAlmostEqual(e['per_page_96'], 0.02)
        # output share 5000/7000 of the bill doubles on the 895
        self.assertAlmostEqual(e['per_page_895'], 0.02 * (2 / 7 + 5 / 7 * 2))

    def test_other_model_scaled_by_price(self):
        e = X.per_page('claude', 'claude-opus-5-5', (5.0, 25.0))
        self.assertAlmostEqual(e['per_page_96'], 0.05)


class Cap(unittest.TestCase):
    def test_stops_before_a_batch_that_could_pass_the_cap(self):
        jobs = [{'id': f'j{i}', 'page': f'p{i}', 'image': b''} for i in range(8)]
        tmp = Path(tempfile.mkdtemp())
        calls = []
        with mock.patch.object(X, 'CACHE', tmp), mock.patch.object(X, 'chosen', return_value={
                'claude': {'model': 'claude-opus-5-5', 'price': [5.0, 25.0], 'label': 'x'}}), \
                mock.patch.object(X, 'panel_jobs', return_value=('prompt', jobs)), \
                mock.patch.object(G, 'spent', side_effect=lambda: X.CAP - 0.1 if calls else 0.0), \
                mock.patch.object(G, 'run', side_effect=lambda s, js, p, c: calls.append([j[0] for j in js])):
            with self.assertRaises(SystemExit) as e:
                X.run('claude', '96')
        self.assertEqual(calls, [['j0', 'j1', 'j2', 'j3']])
        self.assertIn('j4', str(e.exception))

    def test_worst_case_counts_the_full_output_cap(self):
        with mock.patch.object(G, 'PRICE', (5.0, 25.0)):
            self.assertAlmostEqual(X.worst_case(), (4000 * 5 + G.MAX_TOKENS * 25) / 1e6)


if __name__ == '__main__':
    unittest.main()
