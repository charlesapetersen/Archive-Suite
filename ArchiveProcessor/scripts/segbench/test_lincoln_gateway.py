"""Gateway money/scratch-cache contract. No credentials, paid calls or real corpus."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import seg_lincoln_gateway as M


class Money(unittest.TestCase):
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
