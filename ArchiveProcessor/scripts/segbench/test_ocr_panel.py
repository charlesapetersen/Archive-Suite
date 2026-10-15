"""Contract and failure tests on synthetic scratch inputs; no corpus, network or Keychain."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import ocr_panel as P


class Panel(unittest.TestCase):
    def test_owner_prompt_replaces_draft_exclusions(self):
        for text in ['headers, footers, citations, stamps and copyright lines',
                     'Leave out only text on a different sheet', 'Write each bullet point as "*"',
                     'letter on printed letterhead is handwritten or typewritten, not mixed',
                     'Text from a computer printer or word processor is typewritten', '[illegible]',
                     'cells separated by " | "', 'KIND:', 'TABLE:', 'TEXT:']:
            self.assertIn(text, P.PROMPT)
        self.assertNotIn("an archive's copyright slip", P.PROMPT)
        self.assertIn("an archive's copyright slip", P.T.PROMPT)  # historical drafts unchanged

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cache = Path(self.tmp.name)
        self.patcher = patch.object(P, 'CACHE', self.cache)
        self.patcher.start(); self.addCleanup(self.patcher.stop)
        (self.cache / 'images').mkdir()
        (self.cache / 'images/p001-original.jpg').write_bytes(b'image')
        self.job = {'id': 'p001-original', 'page': 'p001', 'scale': 'original', 'sha256': P.digest(b'image')}
        self.endpoint = {'context_length': 1000, 'pricing': {'prompt': '0.000001', 'completion': '0.000002'}}

    def test_route_and_price_pinned_and_reasoning(self):
        for key, spec in P.MODELS.items():
            b = P.body(key, self.job, self.endpoint['pricing'])
            self.assertEqual(b['provider']['order'], [spec[1]])
            self.assertFalse(b['provider']['allow_fallbacks'])
            self.assertEqual(b['provider']['max_price'], {'prompt': 1, 'completion': 2})
            if spec[2]:
                self.assertEqual(b['provider']['quantizations'], [spec[2]])
            if spec[3] == 'off':
                self.assertEqual(b['reasoning'], {'enabled': False})
            elif spec[3] == 'minimal':
                self.assertEqual(b['reasoning']['effort'], 'minimal')
            else:
                self.assertNotIn('reasoning', b)

    def collect(self, post):
        import method_openrouter as OR
        with patch.object(P, 'manifest', return_value={'jobs': [self.job]}), \
             patch.object(P, 'endpoint', return_value=self.endpoint), \
             patch.object(OR, 'api_key', return_value='fake-key'), \
             patch('requests.post', post), patch.object(P, 'estimate'):
            P.collect(only='qwen3.5-9b')

    def test_cost_reservation_stops_before_network(self):
        P.append({'cost': 1.999})
        from unittest.mock import Mock
        post = Mock()
        with self.assertRaisesRegex(SystemExit, 'cap:'):
            self.collect(post)
        post.assert_not_called()

    def test_network_timeout_preserves_reservation_no_retry(self):
        import requests
        from unittest.mock import Mock
        post = Mock(side_effect=requests.Timeout())
        with self.assertRaisesRegex(SystemExit, 'uncertain network'):
            self.collect(post)
        self.assertEqual(post.call_count, 1)
        self.assertEqual(len(list((self.cache / 'pending').glob('*.json'))), 1)
        with self.assertRaisesRegex(SystemExit, 'uncertain paid call'):
            self.collect(post)
        self.assertEqual(post.call_count, 1)

    def test_truncation_counted_and_cached_as_failure(self):
        from unittest.mock import Mock
        response = Mock(status_code=200)
        response.json.return_value = {'usage': {'cost': .01}, 'choices': [{'finish_reason': 'length',
            'message': {'content': 'KIND: printed\nTABLE: no\nTEXT:\nOnly the first words'}}]}
        post = Mock(return_value=response)
        self.collect(post)
        r = json.loads((self.cache / 'responses/qwen3.5-9b/p001-original.json').read_text())
        self.assertIsNone(r['parsed']); self.assertEqual(P.spent(), .01)
        self.assertFalse(list((self.cache / 'pending').glob('*.json')))
        self.collect(post)
        self.assertEqual(post.call_count, 1)  # resume doesn't buy the failure again

    def test_missing_usage_cost_fails_closed(self):
        from unittest.mock import Mock
        response = Mock(status_code=200); response.json.return_value = {'choices': []}
        with self.assertRaisesRegex(SystemExit, 'uncertain cost'):
            self.collect(Mock(return_value=response))
        self.assertTrue(list((self.cache / 'pending').glob('*.json')))

    def test_explicit_empty_provider_error_preserves_evidence_and_no_retry(self):
        from unittest.mock import Mock
        for http in (200, 503):
            with self.subTest(http=http):
                r = Mock(status_code=http)
                r.json.return_value={'id':'error-generation', 'error':{'code':503,'message':'overloaded'}}
                post=Mock(return_value=r)
                # Different job per subtest, preserving each failed response.
                self.job['id']=f'p{http}-original'
                (self.cache/'images'/(self.job['id']+'.jpg')).write_bytes(b'image')
                self.collect(post)
                out=json.loads((self.cache/'responses/qwen3.5-9b'/(self.job['id']+'.json')).read_text())
                self.assertIsNone(out['parsed']);self.assertEqual(out['meta']['cost'],0)
                self.assertTrue(out['meta']['cost_policy_zero'])
                self.assertTrue((self.cache/'responses/qwen3.5-9b'/(self.job['id']+'.raw.json')).exists())
                self.collect(post);self.assertEqual(post.call_count,1)
        self.assertFalse(P.insured_empty_error({'choices':[], 'error':{'code':503},'usage':{'cost':.01}}))

    def test_unbilled_error_reply_charged_its_whole_reservation_no_retry(self):
        from unittest.mock import Mock
        r = Mock(status_code=200)
        r.json.return_value = {'id': 'gen-x', 'provider': 'SiliconFlow', 'choices': [
            {'finish_reason': 'error', 'message': {'role': 'assistant', 'content': None}}]}
        post = Mock(return_value=r)
        self.collect(post)  # does not stop the run
        reserve = 1000 * 0.000001 + P.MAX_TOKENS * 0.000002
        self.assertAlmostEqual(P.spent(), reserve)
        out = json.loads((self.cache / 'responses/qwen3.5-9b/p001-original.json').read_text())
        self.assertTrue(out['meta']['cost_upper_bound']); self.assertEqual(out['meta']['status'], 'failed')
        self.assertFalse(list((self.cache / 'pending').glob('*.json')))
        self.collect(post); self.assertEqual(post.call_count, 1)
        # Any usage, content or error object, or a non-error finish, keeps the old fail-closed path.
        for j in [{'choices': [{'finish_reason': 'error', 'message': {'content': None}}], 'usage': {}},
                  {'choices': [{'finish_reason': 'error', 'message': {'content': 'TEXT: x'}}]},
                  {'choices': [{'finish_reason': 'stop', 'message': {'content': None}}]},
                  {'choices': [{'finish_reason': 'error', 'message': {}}], 'error': {'code': 500}},
                  {'choices': []}]:
            self.assertFalse(P.unbilled_error_reply(j), j)

    def test_reported_charge_on_http_error_always_counts(self):
        from unittest.mock import Mock
        r=Mock(status_code=429)
        r.json.return_value={'error':{'code':429}, 'usage':{'cost':.005}}
        self.collect(Mock(return_value=r))
        self.assertEqual(P.spent(),.005)
        out=json.loads((self.cache/'responses/qwen3.5-9b/p001-original.json').read_text())
        self.assertEqual(out['meta']['status'],'failed')
        self.assertFalse(out['meta']['cost_policy_zero'])

    def test_changed_image_refused(self):
        (self.cache / 'images/p001-original.jpg').write_bytes(b'changed')
        with self.assertRaisesRegex(SystemExit, 'image changed'):
            P.body('qwen3.5-9b', self.job, self.endpoint['pricing'])


class Scores(unittest.TestCase):
    def test_exact_empty_and_order(self):
        from ocr_panel_score import score
        self.assertEqual(score('A word.', 'A word.')['nes'], 1)
        self.assertEqual(score('', '')['chrf'], 1)
        self.assertEqual(score('A word.', '')['missed'], 2)
        r = score('one two three', 'three two one')
        self.assertLess(r['nes'], 1)
        self.assertEqual((r['missed'], r['added']), (0, 0))  # multiset deliberately ignores order

    def test_insert_delete_and_marker(self):
        from ocr_panel_score import score
        r = score('one one two [illegible]', 'one two two [illegible]')
        self.assertEqual((r['words'], r['missed'], r['added'], r['illegible']), (3, 1, 1, 1))
        # Reporting unknown spans as literal makes no claim these words were read correctly.
        self.assertLess(r['nes'], 1)

    def test_bullets_and_typography(self):
        from ocr_panel_score import normal
        self.assertEqual(normal('* One\n* Two'), normal('• One\n- Two'))
        self.assertEqual(normal('“Text” | word'), '"Text" word')
        self.assertNotEqual(normal('state-of-the-art'), normal('state of the art'))

    def test_group_labels_are_truth_and_overlapping(self):
        from ocr_panel_score import group_values
        r = {'collection':'a', 'source':'original', 'date_bin':'undated', 'kind':'typewritten',
             'table_form':'', 'camera':'', 'year_taken':'2018', 'ladder':'yes', 'handwritten':'',
             'clippings':'yes', 'tables':'', 'long_side':'2592', 'sharpness':'1000', 'tags':'A; B'}
        g = group_values(r, {'long_side':[2592,2592], 'sharpness':[699,1407], 'year_taken':[2016,2018]})
        self.assertIn(('long_side_tertile','middle'),g)
        self.assertIn(('kind','typewritten'),g)
        self.assertIn(('tag','A'),g); self.assertIn(('tag','B'),g)

class FrozenInputs(unittest.TestCase):
    def test_prepare_refusal_preserves_previous_images(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); source=root/'truth'; cache=root/'cache'
            (source/'pages').mkdir(parents=True); (source/'truth').mkdir()
            (source/'truth/p001.txt').write_text('known words')
            (source/'pages.tsv').write_text('frozen table')
            (source/'ladder.json').write_text('[]')
            Image.new('RGB',(20,20),'white').save(source/'pages/p001.jpg')
            with patch.object(P,'TRUTH',source), patch.object(P,'CACHE',cache), \
                 patch.object(P,'rows',return_value=[{'page':'p001'}]):
                P.prepare()
                before=(cache/'images/p001-original.jpg').read_bytes()
                Image.new('RGB',(20,20),'black').save(source/'pages/p001.jpg')
                with self.assertRaisesRegex(SystemExit,'manifest changed'):
                    P.prepare()
                self.assertEqual((cache/'images/p001-original.jpg').read_bytes(),before)


class ConcurrentMoney(unittest.TestCase):
    def test_overlapping_reservations_never_exceed_cap(self):
        import threading
        import time
        from unittest.mock import Mock
        import method_openrouter as OR
        with tempfile.TemporaryDirectory() as td:
            c = Path(td); (c/'images').mkdir()
            jobs = []
            for i in range(12):
                ident = f'p{i:03d}-original'
                (c/'images'/(ident+'.jpg')).write_bytes(b'image')
                jobs.append({'id':ident,'page':f'p{i:03d}','scale':'original','sha256':P.digest(b'image')})
            # $0.50 worst case per call, charged at the full reservation.
            endpoint = {'context_length': 1, 'pricing': {'prompt':'.5', 'completion':'0'}}
            mutex, peak, calls = threading.Lock(), [], []
            def post(*args, **kwargs):
                with mutex:
                    held = sum(json.loads(p.read_text())['reserve'] for p in (c/'pending').glob('*.json'))
                    charged = P.spent()
                    peak.append(charged + held); calls.append(1)
                time.sleep(.01)
                r = Mock(status_code=200)
                r.json.return_value = {'usage':{'cost':.5}, 'choices':[{'finish_reason':'stop',
                    'message':{'content':'KIND: printed\nTABLE: no\nTEXT:\nword'}}]}
                return r
            with patch.object(P,'CACHE',c), patch.object(P,'manifest',return_value={'jobs':jobs}), \
                 patch.object(P,'endpoint',return_value=endpoint), patch.object(OR,'api_key',return_value='fake'), \
                 patch('requests.post',side_effect=post), patch.object(P,'estimate'):
                with self.assertRaisesRegex(SystemExit,'cap:'):
                    P.collect(only='qwen3.5-9b')
                self.assertLessEqual(max(peak), P.CAP)
                self.assertLessEqual(P.spent(),P.CAP)
                self.assertEqual(len(calls),4)
                self.assertFalse(list((c/'pending').glob('*.json')))


class Reconcile(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cache = Path(self.tmp.name)
        self.patcher = patch.object(P, 'CACHE', self.cache)
        self.patcher.start(); self.addCleanup(self.patcher.stop)

    def _uncertain(self, now):
        P.append({'key': 'qwen3.5-27b', 'job': 'p001-original', 't': now - 900, 'cost': 0.3, 'status': 'ok'})
        P.append({'key': 'qwen3.5-27b', 'job': 'p002-original', 't': now - 800, 'cost': 0.08,
                  'cost_upper_bound': True, 'status': 'failed'})
        P.save(self.cache / 'responses/qwen3.5-27b/p002-original.json', {'meta': {'cost': 0.08}, 'parsed': None})
        P.save(self.cache / 'pending/qwen3.5-27b-p003-original.json',
               {'key': 'qwen3.5-27b', 'job': 'p003-original', 't': now - 700, 'reserve': 0.08})

    def test_reconcile_bounds_uncertain_calls_by_key_day_usage(self):
        now = 86400 * 20000 + 50000
        self._uncertain(now)
        P.reconcile(usage=0.3005, now=now)
        rr = P.records()
        self.assertEqual([r['job'] for r in rr], ['p001-original', 'p002-original', 'p003-original'])
        self.assertEqual(rr[0]['cost'], 0.3)
        for r in rr[1:]:  # each carries the whole joint bound, still flagged as a ceiling
            self.assertTrue(r['cost_upper_bound']); self.assertGreaterEqual(r['cost'], 0.0005)
            self.assertLess(r['cost'], 0.0006); self.assertEqual(r['cost_basis'], 'key-usage-daily')
        self.assertEqual(rr[2]['status'], 'failed')
        self.assertFalse(list((self.cache / 'pending').glob('*.json')))
        self.assertTrue((self.cache / 'responses/qwen3.5-27b/p003-original.json').exists())  # never retried
        self.assertEqual(json.loads((self.cache / 'responses/qwen3.5-27b/p002-original.json').read_text())['meta']['cost'], rr[1]['cost'])
        self.assertEqual(len(list((self.cache / 'reconciliation').glob('key-usage-*.json'))), 1)

    def test_reconcile_settles_a_pending_unbilled_error_reply_then_bounds_it(self):
        now = 86400 * 20000 + 50000
        self._uncertain(now)
        P.save(self.cache / 'responses/qwen3.5-27b/p003-original.raw.json',
               {'id': 'gen-y', 'choices': [{'finish_reason': 'error', 'message': {'content': None}}]})
        P.reconcile(usage=0.3005, now=now)
        rr = P.records()
        self.assertEqual([r['job'] for r in rr], ['p001-original', 'p002-original', 'p003-original'])
        self.assertTrue(all(r['cost_upper_bound'] and r['cost'] < 0.0006 for r in rr[1:]))
        self.assertEqual(rr[2]['reserve_ceiling'], 0.08)
        self.assertFalse(list((self.cache / 'pending').glob('*.json')))
        self.assertIsNone(json.loads((self.cache / 'responses/qwen3.5-27b/p003-original.json').read_text())['parsed'])

    def test_reconcile_releases_a_pending_429_reply_at_no_cost_and_leaves_it_open(self):
        now = 86400 * 20000 + 50000
        self._uncertain(now)
        P.save(self.cache / 'responses/qwen3.5-27b/p003-original.raw.json',
               {'error': {'code': 429, 'metadata': {'limit_source': 'upstream_provider_shared_pool'}}})
        P.reconcile(usage=0.3005, now=now)
        rr = P.records()
        self.assertEqual([(r['job'], r['status']) for r in rr],
                         [('p001-original', 'ok'), ('p002-original', 'failed'), ('p003-original', 'http-rejected')])
        self.assertEqual(rr[2]['cost'], 0)
        self.assertLess(rr[1]['cost'], 0.08)  # the one remaining ceiling is still bounded by the key
        self.assertFalse(list((self.cache / 'pending').glob('*.json')))
        self.assertFalse((self.cache / 'responses/qwen3.5-27b/p003-original.json').exists())  # retried later
        for j in [{'error': {'code': 429}, 'usage': {'cost': 0.001}}, {'error': {'code': 500}},
                  {'error': {'code': 429}, 'choices': [{}]}, {'error': 'x'}]:
            self.assertFalse(P.rejected_error_reply(j), j)

    def test_reconcile_refuses_unsafe_evidence(self):
        now = 86400 * 20000 + 50000
        self._uncertain(now)
        before = (self.cache / 'calls.jsonl').read_text()
        for kwargs, msg in [({'usage': 0.29, 'now': now}, 'below measured'),
                            ({'usage': 0.3005, 'now': now - 300}, 'settled'),
                            ({'usage': 0.3005, 'now': now + 86400}, 'spans UTC days'),
                            ({'usage': 0.0, 'now': now, 'after': now + 86400}, 'UTC day ended')]:
            with self.assertRaisesRegex(SystemExit, msg):
                P.reconcile(**kwargs)
        P.save(self.cache / 'responses/qwen3.5-27b/p003-original.raw.json', {'usage': {'cost': 0.001}})
        with self.assertRaisesRegex(SystemExit, 'saved a reply'):
            P.reconcile(usage=0.3005, now=now)
        self.assertEqual((self.cache / 'calls.jsonl').read_text(), before)
        self.assertTrue((self.cache / 'pending/qwen3.5-27b-p003-original.json').exists())


if __name__ == '__main__':
    unittest.main()
