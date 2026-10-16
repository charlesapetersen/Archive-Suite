"""Full cloud panel authority, cap and subscription-route tests: synthetic scratch, no network, no key, no CLI."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import ocr_cloud as C
import ocr_cloud_full as F
import ocr_panel as P


class Full(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.cache = Path(self.tmp.name)
        self.patch = patch.multiple(P, CACHE=P.CACHE, MODELS=P.MODELS, CAP=P.CAP,
            body=P.body, manifest=P.manifest, endpoint=P.endpoint, reservation=P.reservation, estimate=P.estimate)
        self.patch.start(); self.addCleanup(self.patch.stop)
        self.env = patch.dict('os.environ'); self.env.start(); self.addCleanup(self.env.stop)
        self.fc = patch.object(F, 'CACHE', self.cache); self.fc.start(); self.addCleanup(self.fc.stop)
        F.configure()
        (self.cache / 'images').mkdir()
        self.jobs = []
        for i in range(1, 100):
            name = f'p{i:03d}-original'
            (self.cache / 'images' / (name + '.jpg')).write_bytes(b'image')
            self.jobs.append({'id': name, 'page': name[:4], 'scale': 'original', 'sha256': P.digest(b'image')})
        self.m = json.loads(json.dumps({'jobs': self.jobs, 'models': F.PAID, 'subscription': F.SUB, 'cap': F.CAP,
                                        'prompt': P.PROMPT}))

    def test_cap_is_the_item_total_with_the_ocr_reserve_held_apart(self):
        self.assertAlmostEqual(F.CAP, 9.31)
        self.assertLessEqual(F.CAP, F.PILOT_SPENT + 9)
        self.assertAlmostEqual(P.CAP + F.MISTRAL_RESERVE, F.CAP)
        self.assertEqual(P.MODELS, F.PAID)
        self.assertNotIn('gpt5.6-sol', F.PAID)  # Sol runs only by subscription (owner)
        self.assertNotIn('claude-sonnet5.5', F.PAID)
        for k in F.PAID:
            # the pilot's exact routes, plus the one route added to the full panel alone (never the pilot)
            self.assertEqual(F.PAID[k], F.ADDED[k] if k in F.ADDED else C.MODELS[k])
        self.assertEqual(set(F.ADDED), {'qwen3.8-flash'})
        self.assertFalse(set(F.ADDED) & set(C.MODELS))

    def test_manifest_refuses_anything_but_99_originals_and_the_approved_routes(self):
        for alter in ('short', 'dup', 'ladder', 'cap', 'sub'):
            m = copy.deepcopy(self.m)
            if alter == 'short': m['jobs'].pop()
            if alter == 'dup': m['jobs'][1] = m['jobs'][0]
            if alter == 'ladder': m['jobs'][0]['scale'] = 'half'
            if alter == 'cap': m['cap'] = 20
            if alter == 'sub': m['subscription']['gpt5.6-sol'][2] = 'high'
            with self.subTest(alter=alter), patch.object(F, '_base_manifest', return_value=m):
                with self.assertRaises(SystemExit): F.manifest()
        with patch.object(F, '_base_manifest', return_value=self.m):
            self.assertEqual(len(F.manifest()['jobs']), 99)

    def test_only_an_uncalled_pilot_route_may_be_added(self):
        old = copy.deepcopy(self.m); old['models'].pop('gpt5.6-luna')
        self.assertTrue(F.fallback_added(old, self.m))
        P.append({'key': 'gpt5.6-luna', 'status': 'ok', 'cost': .001, 'pilot': True})
        self.assertTrue(F.fallback_added(old, self.m))  # bought in the pilot, not yet in the full run
        changed = copy.deepcopy(self.m); changed['models']['gpt5.6-luna'][3] = 'low'
        self.assertFalse(F.fallback_added(old, changed))
        foreign = copy.deepcopy(self.m); foreign['models']['x'] = ['m', 'p', None, 'off', None]
        self.assertFalse(F.fallback_added(old, foreign))
        moved = copy.deepcopy(self.m); moved['cap'] = 10
        self.assertFalse(F.fallback_added(old, moved))
        P.append({'key': 'gpt5.6-luna', 'status': 'ok', 'cost': .001})
        self.assertFalse(F.fallback_added(old, self.m))

    def test_seed_requires_the_settled_pilot_and_carries_its_ledger(self):
        pilot = self.cache / 'pilot'; (pilot / 'pending').mkdir(parents=True); (pilot / 'catalog').mkdir()
        (pilot / 'responses' / 'gemini3.1-pro').mkdir(parents=True)
        (pilot / 'responses' / 'gemini3.1-pro' / 'p010-original.json').write_text('{}')
        (pilot / 'responses' / 'gpt5.6-sol').mkdir(parents=True)
        (pilot / 'responses' / 'gpt5.6-sol' / 'p010-original.json').write_text('{}')
        recs = [{'key': 'gemini3.1-pro', 'cost': .2}, {'key': 'gpt5.6-sol', 'cost': .112211}]
        (pilot / 'calls.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in recs))
        with patch.object(F, 'PILOT', pilot):
            (pilot / 'pending' / 'x.json').write_text('{}')
            with self.assertRaisesRegex(SystemExit, 'settled'): F.seed()
            (pilot / 'pending' / 'x.json').unlink()
            F.seed()
        self.assertAlmostEqual(P.spent(), F.PILOT_SPENT)
        self.assertTrue(all(r['pilot'] for r in P.records()))
        self.assertTrue((self.cache / 'responses' / 'gemini3.1-pro' / 'p010-original.json').exists())
        self.assertFalse((self.cache / 'responses' / 'gpt5.6-sol').exists())  # subscription-only now

    def run_sub(self, route, calls):
        with patch.object(F, '_base_manifest', return_value=self.m), \
             patch.object(F, 'call_codex', side_effect=calls), patch.object(F, 'call_claude', side_effect=calls), \
             patch.object(F, 'usage_percent', return_value=10):
            F.subscription(route, concurrency=1)

    def test_subscription_reads_once_retries_only_a_harness_error_and_stops_on_a_limit(self):
        good = 'KIND: typewritten\nTABLE: no\nTEXT:\nhello'
        answers = iter([RuntimeError('crash'), (good, {}), ('no form', {})] + [F.UsageLimit('out of credits')] * 200)

        def call(*a):
            x = next(answers)
            if isinstance(x, Exception): raise x
            return x
        self.run_sub('gpt5.6-luna', call)
        first = json.loads(F.sub_path('gpt5.6-luna', self.jobs[0]).read_text())
        self.assertEqual(first['meta']['status'], 'ok'); self.assertEqual(len(first['meta']['harness_errors']), 1)
        second = json.loads(F.sub_path('gpt5.6-luna', self.jobs[1]).read_text())
        self.assertEqual(second['meta']['status'], 'failed'); self.assertIsNone(second['parsed'])
        self.assertFalse(F.sub_path('gpt5.6-luna', self.jobs[2]).exists())  # left open for a later pass
        done = []
        self.run_sub('gpt5.6-luna', lambda *a: done.append(1) or (good, {}))
        self.assertEqual(len(done), 97)  # cached pages are never re-asked

    def test_claude_route_stops_at_the_usage_guard(self):
        with patch.object(F, '_base_manifest', return_value=self.m), \
             patch.object(F, 'call_claude', side_effect=AssertionError('called')), \
             patch.object(F, 'usage_percent', return_value=F.CLAUDE_GUARD):
            F.subscription('claude-sonnet5.5', concurrency=1)
        self.assertFalse((self.cache / 'sub').exists())


if __name__ == '__main__':
    unittest.main()
