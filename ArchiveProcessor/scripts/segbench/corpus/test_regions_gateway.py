"""Scratch-only contracts for the paid collector; never use keys or a live network."""
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock

from PIL import Image
import regions_gateway as B

RAW = 'KIND: typewritten\nTABLE: no\nTEXT:\nA complete reading.'


class Collector(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = Path(self.tmp.name)
        self.patch = patch.object(B, 'STORE', self.store)
        self.patch.start(); self.addCleanup(self.patch.stop)
        B.STOP.clear()
        buf = io.BytesIO(); Image.new('RGB', (100, 200), 'white').save(buf, 'JPEG')
        b = buf.getvalue(); image = self.store / 'page.jpg'; image.write_bytes(b)
        self.job = ({'id': 'test', 'set': 'public895', 'image': str(image), 'sha256': B.sha(b)},
                    'whole', 0, {'box': [0, 0, 1, 1], 'px': [0, 0, 100, 200]})
        self.m = {'prompt': 'Read the page.'}
        self.body, self.key = B.request(self.m, self.job)

    def reply(self, usage=None, finish='stop', raw=RAW):
        return Mock(status_code=200, json=lambda: {
            'model': B.G.MODEL, 'usage': usage if usage is not None else {'prompt_tokens': 100, 'completion_tokens': 200},
            'choices': [{'finish_reason': finish, 'message': {'content': raw}}]})

    def test_reservation_is_durable_before_send_and_same_reply_is_not_sent_twice(self):
        def send(*args):
            r, = B.effective()
            self.assertEqual(r['event'], 'reserve')
            self.assertGreater(B.spent(), 0)
            return self.reply()
        with patch.object(B.G, 'request', side_effect=send) as net:
            one = B.call(self.m, self.job)
            two = B.call(self.m, self.job)
        self.assertTrue(one['valid']); self.assertEqual(one, two)
        self.assertEqual(net.call_count, 1)
        self.assertAlmostEqual(B.spent(), (100*.75+200*3.75)/1e6)

    def test_interruption_retains_allowance_and_blocks_other_network(self):
        with patch.object(B.G, 'request', side_effect=TimeoutError) as net:
            with self.assertRaisesRegex(RuntimeError, 'unknown usage'):
                B.call(self.m, self.job)
            with self.assertRaisesRegex(RuntimeError, 'stopped'):
                B.call(self.m, self.job)
        self.assertEqual(net.call_count, 1)
        self.assertEqual(B.spent(), B.reservation(self.body))
        B.STOP.clear()  # simulate a new process
        with patch.object(B.G, 'request') as net:
            with self.assertRaisesRegex(RuntimeError, 'already attempted'):
                B.call(self.m, self.job)
            net.assert_not_called()

    def test_unknown_usage_is_saved_charged_and_stops(self):
        with patch.object(B.G, 'request', return_value=self.reply(usage={})):
            with self.assertRaisesRegex(RuntimeError, 'unknown usage'):
                B.call(self.m, self.job)
        self.assertEqual(B.spent(), B.reservation(self.body))
        self.assertFalse(json.loads((self.store/'replies'/f'{self.key}.json').read_text())['valid'])
        self.assertTrue(B.STOP.is_set())

    def test_cap_refuses_before_network(self):
        B.append({'id': 'previous', 'event': 'settle', 'charge': 2.99, 'request_sha256': 'old'})
        with patch.object(B.G, 'request') as net:
            with self.assertRaisesRegex(RuntimeError, 'cap:'):
                B.call(self.m, self.job)
            net.assert_not_called()

    def test_capped_and_invalid_replies_remain_charged_failures_without_retry(self):
        for finish, raw in [('length', RAW), ('stop', 'wrong format')]:
            with self.subTest(finish=finish):
                prompt = {'prompt': raw + finish}
                with patch.object(B.G, 'request', return_value=self.reply(finish=finish, raw=raw)) as net:
                    hit = B.call(prompt, self.job)
                    self.assertFalse(hit['valid'])
                    self.assertEqual(B.call(prompt, self.job), hit)
                self.assertEqual(net.call_count, 1)
        self.assertGreater(B.spent(), 0)

    def test_frozen_image_change_refuses_network(self):
        Path(self.job[0]['image']).write_bytes(b'changed')
        with patch.object(B.G, 'request') as net:
            with self.assertRaisesRegex(ValueError, 'image changed'):
                B.call(self.m, self.job)
            net.assert_not_called()

    def test_unknown_prior_request_blocks_resumed_collection_before_key(self):
        B.append({'id': 'old', 'event': 'reserve', 'charge': .1, 'request_sha256': 'old'})
        with patch.object(B, 'manifest', return_value={}), patch.object(B.G, 'api_key') as key:
            with self.assertRaisesRegex(RuntimeError, 'unsettled/unknown'):
                B.collect()
            key.assert_not_called()

    def test_allowance_overrun_blocks_resumed_collection(self):
        B.append({'id': 'old', 'event': 'settle', 'charge': .2, 'allowance': .1,
                  'known': True, 'request_sha256': 'old'})
        with patch.object(B, 'manifest', return_value={}), patch.object(B.G, 'api_key') as key:
            with self.assertRaisesRegex(RuntimeError, 'unsettled/unknown'):
                B.collect()
            key.assert_not_called()

    def test_wrong_returned_model_is_charged_but_not_a_reading(self):
        reply = self.reply().json(); reply['model'] = 'another-model'
        with patch.object(B.G, 'request', return_value=Mock(status_code=200, json=lambda: reply)):
            self.assertFalse(B.call(self.m, self.job)['valid'])
        self.assertGreater(B.spent(), 0)

    def test_truth_change_refuses_offline_preflight(self):
        truth = self.store/'truth.txt'; truth.write_text('changed')
        m = {'pages': [{'id': 'test', 'truth': str(truth), 'truth_sha256': B.sha(b'original')}]}
        with patch.object(B, 'manifest', return_value=m), patch.object(B.G, 'request') as net:
            with self.assertRaisesRegex(ValueError, 'truth changed'):
                B.verify()
            net.assert_not_called()

    def test_empty_detections_still_have_a_whole_and_tile_task(self):
        p = {'id': 'empty', 'crops': {'whole': [{}], 'pp-doclayoutv3': [], 'tiles': [{}, {}]}}
        jobs = B.tasks({'pages': [p], 'pilot': ['empty']})
        self.assertEqual([j[1] for j in jobs], ['whole', 'tiles', 'tiles'])

    def test_retry_unknown_is_explicit_and_keeps_the_first_allowance(self):
        bad = Mock(status_code=502, text='<html>Bad gateway</html>', json=Mock(side_effect=ValueError))
        with patch.object(B.G, 'request', return_value=bad):
            with self.assertRaisesRegex(RuntimeError, 'unknown usage'):
                B.call(self.m, self.job)
        u, = B.effective()
        self.assertEqual((u['event'], u['http'], u['body']), ('unknown', 502, '<html>Bad gateway</html>'))
        B.STOP.clear()
        with patch.object(B.G, 'request') as net:
            with self.assertRaisesRegex(RuntimeError, 'already attempted'):
                B.call(self.m, self.job)
            net.assert_not_called()
        with patch.object(B, 'RETRY_UNKNOWN', True), patch.object(B.G, 'request', return_value=self.reply()) as net:
            self.assertTrue(B.call(self.m, self.job)['valid'])
            B.call(self.m, self.job)
        self.assertEqual(net.call_count, 1)
        self.assertAlmostEqual(B.spent(), B.reservation(self.body) + (100*.75+200*3.75)/1e6)

    def test_set_and_arm_filters_select_a_complete_slice(self):
        crops = {'whole': [{}], 'pp-doclayoutv3': [{}], 'tiles': [{}, {}]}
        pages = [{'id': 'o', 'set': 'owner99', 'crops': crops}, {'id': 'p', 'set': 'public895', 'crops': crops}]
        jobs = B.tasks({'pages': pages, 'pilot': []}, sets=['owner99'], arms=('tiles',))
        self.assertEqual([(j[0]['id'], j[1], j[2]) for j in jobs], [('o', 'tiles', 0), ('o', 'tiles', 1)])
        self.assertEqual(len(B.tasks({'pages': pages, 'pilot': []})), 8)

    def test_whole_baseline_requires_exact_hash(self):
        own = ({**self.job[0], 'set': 'owner99'}, *self.job[1:])
        cache = self.store/'baseline'; (cache/'panel').mkdir(parents=True)
        hit = {'meta': {'request_sha256': 'wrong', 'model': B.G.MODEL, 'finish': 'stop', 'http': 200}, 'raw': RAW}
        (cache/'panel/test-original.json').write_text(json.dumps(hit))
        with patch.object(B.G, 'CACHE', cache):
            with self.assertRaisesRegex(ValueError, 'not the same request'):
                B.cached(self.m, own, self.body, self.key)


if __name__ == '__main__':
    unittest.main()
