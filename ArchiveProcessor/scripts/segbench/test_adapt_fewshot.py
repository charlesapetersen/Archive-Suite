"""Few-shot gateway arm: prompt, draw and money contract. No credentials, paid calls or real corpus."""
import json
import random
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

import seg_adapt_fewshot as M
import seg_lincoln_gateway as SL


def fake_base(route, col, a, b, whole=False):
    body = {'model': 'gemini-3.7-flash', 'max_tokens': 4096, 'messages': [{'role': 'user', 'content': [
        {'type': 'text', 'text': 'Page 1:'}, {'type': 'text', 'text': 'RULES' + M.MARKER + '{}'}]}]}
    return body, 'base-key', [1, 2]


class Page:
    def __init__(self, n):
        self.n = n


class Col:
    name = 'Box'
    labels = ['New', 'Cont', 'New', 'Cont', 'Cont'] * 10
    pages = [Page(n) for n in range(1, 51)]

    def text(self, i):
        return f'text of page {i + 1}'


class FewShot(unittest.TestCase):
    def test_draw_replays_the_curve_loop(self):
        gaps = list(range(100))
        rng = random.Random(11)
        rng.sample(gaps, 0)
        first25 = rng.sample(gaps, 25)
        self.assertEqual(M.draw(gaps, 25), sorted(first25))
        for _ in range(29):
            rng.sample(gaps, 25)
        self.assertEqual(M.draw(gaps, 50), sorted(rng.sample(gaps, 50)))

    def test_block_goes_before_the_schema_and_changes_the_key(self):
        col = Col()
        with patch.object(M, '_BASE_REQUEST', fake_base), M.fewshot(col, 25):
            body, key, _ = M.request('gemini', col, 0, 2)
        text = body['messages'][0]['content'][-1]['text']
        self.assertTrue(text.startswith('RULES\nGAPS THE ARCHIVIST'))
        self.assertTrue(text.endswith(M.MARKER + '{}'))
        self.assertNotEqual(key, 'base-key')
        self.assertEqual(text.count('Pages '), 25)

    def test_context_restores_the_baseline_store_and_request(self):
        before = SL.STORE, SL.CAP, SL.request
        with patch.object(M, '_BASE_REQUEST', fake_base), M.fewshot(Col(), 25):
            self.assertEqual((SL.STORE, SL.CAP, SL.request), (M.STORE, M.CAP, M.request))
        self.assertEqual((SL.STORE, SL.CAP, SL.request), before)
        self.assertEqual(M.BLOCKS, {})

    def test_refuses_without_a_block_or_off_route(self):
        with patch.object(M, '_BASE_REQUEST', fake_base):
            self.assertRaises(ValueError, M.request, 'gemini', Col(), 0, 2)
            self.assertRaises(ValueError, M.request, 'glm', Col(), 0, 2)

    def test_cap_stops_before_sending(self):
        col = Col()
        with tempfile.TemporaryDirectory() as d, patch.object(M, 'STORE', Path(d)), \
                patch.object(M, '_BASE_REQUEST', fake_base), \
                patch.object(SL.GW, 'request', side_effect=AssertionError('sent')), M.fewshot(col, 25):
            SL.append({'id': 'x', 'event': 'settle', 'charge': M.CAP - 0.001})
            with self.assertRaisesRegex(RuntimeError, 'cap'):
                SL.call('gemini', col, 0, 2)
            self.assertEqual(len((Path(d) / 'calls.jsonl').read_text().splitlines()), 1)


if __name__ == '__main__':
    unittest.main()
