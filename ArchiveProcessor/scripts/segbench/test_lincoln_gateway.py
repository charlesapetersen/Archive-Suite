"""Gateway money/scratch-cache contract. No credentials, paid calls or real corpus."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import seg_lincoln_gateway as M


class Money(unittest.TestCase):
    def test_explicit_transport_retry_keeps_old_allowance_and_allows_only_one_retry(self):
        with tempfile.TemporaryDirectory() as d, patch.object(M, 'STORE', Path(d)):
            M.append({'id': 'a', 'event': 'reserve', 'request_sha256': 'key', 'whole': False,
                      't': M.time.time() - 400, 'charge': .1})
            M.retry_unsettled_once()
            self.assertEqual(M.spent(), .1)
            self.assertEqual(M.effective_records()[0]['event'], 'retry-approved')
            M.append({'id': 'b', 'event': 'unknown', 'request_sha256': 'key', 'whole': False,
                      't': M.time.time() - 400, 'charge': .1})
            M.append({'id': 'b', 'event': 'reserve', 'request_sha256': 'key', 'whole': False,
                      't': M.time.time() - 400, 'charge': .1})
            with self.assertRaisesRegex(RuntimeError, 'already retried'):
                M.retry_unsettled_once()
            self.assertEqual(M.spent(), .2)

    def test_transport_retry_never_overlaps_the_timeout(self):
        with tempfile.TemporaryDirectory() as d, patch.object(M, 'STORE', Path(d)):
            M.append({'id': 'a', 'event': 'reserve', 'request_sha256': 'key', 'whole': False,
                      't': M.time.time(), 'charge': .1})
            with self.assertRaisesRegex(RuntimeError, 'timeout has not elapsed'):
                M.retry_unsettled_once()
            self.assertEqual(len(M.records()), 1)

    def test_only_explicit_preinference_size_rejection_releases_reservation(self):
        with tempfile.TemporaryDirectory() as d, patch.object(M, 'STORE', Path(d)):
            M.append({'id': 'a', 'event': 'settle', 'http': 413, 'charge': .9, 'request_sha256': 'key'})
            with patch.object(M, 'cached', return_value={'response': {'error': 'other'}}):
                with self.assertRaises(RuntimeError):
                    M.reconcile_413()
            self.assertEqual(M.spent(), .9)
            with patch.object(M, 'cached', return_value={
                    'response': {'error': 'Request size is too large. Max size is 32 MB'}}):
                M.reconcile_413()
                M.reconcile_413()
            self.assertEqual(M.spent(), 0)
            self.assertEqual(len(M.records()), 2)

    def test_reservations_survive_interruption_and_settle_once(self):
        rows = [{'id': 'a', 'charge': .4}, {'id': 'b', 'charge': .7},
                {'id': 'a', 'charge': .03}]
        self.assertAlmostEqual(M.spent(rows), .73)

    def run_call(self, response, finish='stop', usage=None, raises=False):
        raw = json.dumps({'pages': [{'page': 1, 'kind': 'document'}, {'page': 2, 'kind': 'document'}],
                          'boundaries': [{'between': [1, 2], 'decision': 'continue', 'confidence': .9}]})
        got = {'usage': usage if usage is not None else {'prompt_tokens': 100, 'completion_tokens': 50},
               'choices': [{'finish_reason': finish, 'message': {'content': raw}}]}
        reply = SimpleNamespace(status_code=response, json=lambda: got)
        body = {'max_tokens': 4096, 'messages': [{'content': [{'type': 'text', 'text': 'P'}]}]}
        col = SimpleNamespace(name='Toy')
        observed = []
        def post(*args, **kwargs):
            observed.extend(M.records())
            return reply
        with tempfile.TemporaryDirectory() as d, patch.object(M, 'STORE', Path(d)), \
                patch.object(M, 'request', return_value=(body, 'key', [1, 2])), \
                patch.object(M.GW, 'request', side_effect=post) as send:
            if raises:
                with self.assertRaises(RuntimeError):
                    M.call('gemini', col, 0, 2)
            else:
                M.call('gemini', col, 0, 2)
                M.call('gemini', col, 0, 2)  # cached: no second charge/call
            self.assertEqual(send.call_count, 1)
            self.assertEqual(observed[0]['event'], 'reserve')  # disk record precedes sending
            rows = M.records()
            self.assertEqual(len(rows), 2)
            hit = M.cached('key')
            self.assertEqual(hit['valid'], not raises)
            if raises:
                with self.assertRaises(RuntimeError):
                    M.call('gemini', col, 0, 2)  # recorded failure cannot silently retry
                self.assertEqual(send.call_count, 1)
            return rows

    def test_success_counts_reasoning_in_completion_and_cache_is_idempotent(self):
        rows = self.run_call(200)
        self.assertAlmostEqual(M.spent(rows), (100 * .75 + 50 * 3.75) / 1e6)

    def test_truncated_answer_is_billed_but_never_scored(self):
        self.run_call(200, finish='length', raises=True)

    def test_unknown_usage_keeps_the_full_reservation(self):
        rows = self.run_call(503, usage={}, raises=True)
        self.assertEqual(rows[0]['charge'], rows[1]['charge'])

    def test_cap_and_unsettled_request_stop_before_send(self):
        body = {'max_tokens': 4096, 'messages': [{'content': [{'type': 'text', 'text': 'P'}]}]}
        for existing in ({'id': 'old', 'charge': 2.999, 'event': 'settle'},
                         {'id': 'old', 'charge': .1, 'event': 'reserve', 'request_sha256': 'key'}):
            with self.subTest(existing=existing), tempfile.TemporaryDirectory() as d, \
                    patch.object(M, 'STORE', Path(d)), \
                    patch.object(M, 'request', return_value=(body, 'key', [1, 2])), \
                    patch.object(M.GW, 'request') as send:
                M.append(existing)
                with self.assertRaises(RuntimeError):
                    M.call('gemini', SimpleNamespace(name='Toy'), 0, 2)
                send.assert_not_called()


class Inputs(unittest.TestCase):
    def test_json_mode_reuses_valid_pilot_only_and_never_reuses_failure(self):
        body = {'model': 'gemini', 'messages': [], 'response_format': {'type': 'json_object'}}
        for valid in (True, False):
            with self.subTest(valid=valid), patch.object(M, 'cached', side_effect=[None, {'valid': valid}]) as read:
                self.assertEqual(M.cache_hit(body, 'new'), {'valid': True} if valid else None)
                self.assertNotEqual(read.call_args_list[1].args[0], 'new')

    def test_missing_second_box_does_not_overwrite_first_box_or_leave_stale_scores(self):
        import hashlib
        import public_segmentation as P
        import rescore
        import seg_lincoln_cloud as S
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            manifest = {'frozen': True}
            digest = hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()
            (root / 'lincoln.json').write_text(json.dumps(manifest))
            old = json.dumps({'truth_sha256': digest, 'pages': 1, 'models': {}})
            path = root / 'lincoln-scores.json'
            path.write_text(old)
            cols = [SimpleNamespace(name=n, pages=[None]) for n in ('Lincoln', 'CREST')]
            good = {'sources': {'gateway-gemini': {'counts': {'collections': ['Lincoln']}, 'metrics': {}}},
                    'missing': {}}
            bad = {'sources': {}, 'missing': {'gateway-glm': 'hole'}}
            with patch.object(M, 'public_columns', return_value=cols), patch.object(M, 'use_cache'), \
                    patch.object(M, 'RESULTS', root), patch.object(P, 'MANIFESTS', root), \
                    patch.object(M, 'spent', return_value=0), patch.object(M, 'effective_records', return_value=[]), \
                    patch.object(rescore, 'no_network'), patch.object(S, 'score_sources', side_effect=[good, bad]):
                with self.assertRaisesRegex(ValueError, 'incomplete sources'):
                    M.score(root)
            self.assertEqual(path.read_text(), old)
            self.assertFalse((root / 'seg-lincoln-gateway.json').exists())

    def test_complete_whole_json_fence_parses_but_missing_gap_does_not(self):
        raw = '```json\n' + json.dumps({'boundaries': [
            {'between': [1, 2], 'decision': 'new', 'confidence': .9}]}) + '\n```'
        self.assertEqual(M.parse(raw, [1, 2], True)[1]['decision'], 'new')
        with self.assertRaises(M.W.ParseError):
            M.parse(raw, [1, 2, 3], True)
        typo = raw.replace('"between": [1, 2]', '"between": 1, 2]')
        with self.assertRaises(M.W.ParseError):
            M.parse(typo, [1, 2], True)  # never invent missing JSON delimiters or values

    def test_missing_ocr_stops_before_build_or_send(self):
        col = SimpleNamespace(name='Toy', pages=[SimpleNamespace(n=1), SimpleNamespace(n=2)])
        with tempfile.TemporaryDirectory() as d, patch.object(M.data, 'CACHE_DIR', Path(d)), \
                patch.object(M.G, 'build_request') as build, patch.object(M.GW, 'request') as send:
            with self.assertRaisesRegex(ValueError, 'missing cached Vision text'):
                M.call('gemini', col, 0, 2)
            build.assert_not_called()
            send.assert_not_called()

    def test_request_keeps_page_order_and_cue_but_never_asks_for_tools(self):
        with tempfile.TemporaryDirectory() as d:
            paths = [Path(d) / f'{i}.jpg' for i in (1, 2)]
            for i, p in enumerate(paths):
                p.write_bytes(bytes([i]))
            with patch.object(M.G, 'build_request', return_value=('original g1', paths, [8, 9])), \
                    patch.object(M.C, 'cue_block', return_value='STATED CUES'):
                col = SimpleNamespace(name='Toy', pages=[])
                body, key, nums = M.request('claude-cue', col, 7, 9)
                parts = body['messages'][0]['content']
                self.assertEqual([parts[0]['text'], parts[2]['text']], ['Page 8:', 'Page 9:'])
                self.assertIn('original g1STATED CUES', parts[-1]['text'])
                self.assertNotIn('tools', body)
                other, other_key, _ = M.request('gemini', col, 7, 9)
                self.assertNotEqual(key, other_key)  # model/settings are in the cache key

    def test_existing_plan_reply_wins_and_fallback_is_read_only(self):
        with patch.object(M.C, 'judge', return_value=lambda *a, **k: {'old': True}), \
                patch.object(M, 'judge') as fallback:
            self.assertEqual(M.claude_cue(None, 0, 2, allow_call=True), {'old': True})
            fallback.assert_not_called()


if __name__ == '__main__':
    unittest.main()
