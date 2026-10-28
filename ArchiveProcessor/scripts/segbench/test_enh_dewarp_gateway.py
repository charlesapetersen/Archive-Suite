#!/usr/bin/env python3
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import enh_dewarp_gateway as W
import gateway_gemini as G


class StatusTest(unittest.TestCase):
    def test_statuses(self):
        self.assertEqual(W.status_of({'http': 429}, None), 'error')
        self.assertEqual(W.status_of({'http': 200, 'finish': 'length'}, {'text': 'x'}), 'cap')
        self.assertEqual(W.status_of({'http': 200, 'finish': 'stop'}, {'text': 'x'}), 'ok')
        self.assertEqual(W.status_of({'http': 200, 'finish': 'stop'}, None), 'blank')


class CapTest(unittest.TestCase):
    def test_own_ledger_and_cap_stop_a_call(self):
        """The item's ledger, not gateway_gemini's, is what the cap counts, and a call near the cap is refused
        before any request is made."""
        with tempfile.TemporaryDirectory() as d, patch.object(W, 'CACHE', Path(d)), \
                patch.object(G, 'CACHE', G.CACHE), patch.object(G, 'CAP', G.CAP), \
                patch.object(G, 'request', side_effect=AssertionError('no request past the cap')):
            (Path(d) / 'calls.jsonl').write_text(json.dumps({'cost': W.CAP - 0.05}) + '\n')
            self.assertAlmostEqual(W.spent(), W.CAP - 0.05)
            with self.assertRaises(SystemExit):
                G.call('t', 'quad/p001', b'', 'prompt', Path(d) / 'r.json')


if __name__ == '__main__':
    unittest.main()
