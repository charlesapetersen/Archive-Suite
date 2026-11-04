#!/usr/bin/env python3
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import capture_ladder_gateway as W
import gateway_gemini as G


class VerdictParseTest(unittest.TestCase):
    def test_parses_fenced_json_and_drops_unknown_defects(self):
        v = W.parse_verdict({'raw': '```json\n{"quality": 2, "retake": true, "defects": ["glare", "smudge"], '
                                    '"worst": "glare"}\n```'})
        self.assertEqual(v, {'quality': 2, 'retake': True, 'defects': {'glare'}, 'worst': 'glare'})

    def test_refuses_a_reply_without_a_usable_quality(self):
        self.assertIsNone(W.parse_verdict({'raw': '{"quality": 9, "defects": []}'}))
        self.assertIsNone(W.parse_verdict({'raw': '{"quality": "good"}'}))
        self.assertIsNone(W.parse_verdict({'raw': 'no json here'}))
        self.assertIsNone(W.parse_verdict({'raw': None}))
        self.assertIsNone(W.parse_verdict(None))

    def test_retake_only_when_literally_true(self):
        self.assertFalse(W.parse_verdict({'raw': '{"quality": 4, "retake": "yes"}'})['retake'])
        self.assertEqual(W.parse_verdict({'raw': '{"quality": 4, "worst": "fog"}'})['worst'], 'none')

    def test_every_variant_has_a_tag_in_the_vocabulary(self):
        self.assertEqual(set(W.TAG), set(W.VARIANTS))
        self.assertTrue(set(W.TAG.values()) <= set(W.VERDICT_DEFECTS))


class StatusTest(unittest.TestCase):
    def test_statuses(self):
        self.assertEqual(W.status_of({'http': 500}, None), 'error')
        self.assertEqual(W.status_of({'http': 200, 'finish': 'length'}, {'text': 'x'}), 'cap')
        self.assertEqual(W.status_of({'http': 200, 'finish': 'stop'}, {'text': 'x'}), 'ok')
        self.assertEqual(W.status_of({'http': 200, 'finish': 'stop'}, None), 'blank')


class CapTest(unittest.TestCase):
    def test_own_ledger_and_cap_stop_a_call(self):
        """The item's ledger is what the cap counts, and a call near the cap is refused before any request."""
        with tempfile.TemporaryDirectory() as d, patch.object(W, 'CACHE', Path(d)), \
                patch.object(G, 'CACHE', G.CACHE), patch.object(G, 'CAP', G.CAP), \
                patch.object(G, 'request', side_effect=AssertionError('no request past the cap')):
            (Path(d) / 'calls.jsonl').write_text(json.dumps({'cost': W.CAP - 0.05}) + '\n')
            self.assertAlmostEqual(W.spent(), W.CAP - 0.05)
            with self.assertRaises(SystemExit):
                G.call('t', 'motion-31/p001', b'', W.VERDICT_PROMPT, Path(d) / 'r.json')

    def test_cap_is_under_the_seven_dollar_rule(self):
        self.assertLessEqual(W.CAP, 7.0)


class ImageCheckTest(unittest.TestCase):
    def test_an_image_that_differs_from_the_manifest_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / 'x.jpg'; f.write_bytes(b'not the image')
            with patch('capture_ladder.image', return_value=f), self.assertRaises(SystemExit):
                W.image_bytes('motion-31', 'p001', {'motion-31/p001': '0' * 64})


if __name__ == '__main__':
    unittest.main()
