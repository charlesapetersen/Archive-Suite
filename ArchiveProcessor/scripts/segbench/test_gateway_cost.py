"""The gateway's own cost per call beside the token estimate (W46.gateway-cost-record), on toy responses.
Run: python3 test_gateway_cost.py   (no bench data, no network, no key)."""
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import gateway_gemini as G


def response(cost=None, status=200, usage=None):
    headers = {'content-type': 'application/json'}
    if cost is not None:
        headers['x-litellm-response-cost'] = cost
    got = {'model': G.MODEL, 'usage': usage or {'prompt_tokens': 1000, 'completion_tokens': 100},
           'choices': [{'message': {'content': 'reply'}, 'finish_reason': 'stop'}]}
    return SimpleNamespace(status_code=status, headers=headers, json=lambda: got, text=json.dumps(got))


class Header(unittest.TestCase):
    def test_reads_the_header(self):
        self.assertEqual(G.gateway_cost(response('0.00123')), 0.00123)

    def test_absent_empty_or_garbled_is_none(self):
        for v in (None, '', 'n/a'):
            self.assertIsNone(G.gateway_cost(response(v)), v)

    def test_record_gains_the_field_only_when_sent(self):
        self.assertEqual(G.with_gateway_cost({'cost': 1}, response('0.5')), {'cost': 1, 'gateway_cost': 0.5})
        self.assertEqual(G.with_gateway_cost({'cost': 1}, response()), {'cost': 1})


class Charge(unittest.TestCase):
    def test_the_larger_counts(self):
        self.assertEqual(G.charge({'cost': 0.2, 'gateway_cost': 0.5}), 0.5)
        self.assertEqual(G.charge({'cost': 0.2, 'gateway_cost': 0.0}), 0.2)   # a cache hit billed $0
        self.assertEqual(G.charge({'cost': 0.2}), 0.2)                        # an old line, no figure
        self.assertEqual(G.charge({'estimate': 0.3, 'charge': 9}, 'estimate'), 0.3)

    def test_billed_reports_both_and_the_ratio_on_the_lines_that_carry_it(self):
        rows = [{'cost': 0.2, 'gateway_cost': 0.1}, {'cost': 0.2, 'gateway_cost': 0.3}, {'cost': 0.4}]
        b = G.billed(rows)
        self.assertEqual((b['calls'], b['gateway_calls']), (3, 2))
        self.assertAlmostEqual(b['estimate'], 0.8)
        self.assertAlmostEqual(b['gateway'], 0.4)
        self.assertAlmostEqual(b['gateway_over_estimate'], 1.0)
        self.assertAlmostEqual(b['charged'], 0.2 + 0.3 + 0.4)
        self.assertIn('2 of 3 calls', G.billed_note(rows))

    def test_billed_without_any_figure(self):
        b = G.billed([{'cost': 0.2}])
        self.assertIsNone(b['gateway'])
        self.assertIsNone(b['gateway_over_estimate'])
        self.assertIn('no cost of its own', G.billed_note([{'cost': 0.2}]))


class SharedCall(unittest.TestCase):
    def test_ledger_line_carries_both_and_the_cap_counts_the_larger(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(G, 'CACHE', Path(d)):
            with mock.patch.object(G, 'request', return_value=response('0.05')):
                G.call('t', 'a', b'img', 'prompt', Path(d) / 'a.json')
            with mock.patch.object(G, 'request', return_value=response()):
                G.call('t', 'b', b'img', 'prompt', Path(d) / 'b.json')
            a, b = G.ledger()
            self.assertEqual(a['gateway_cost'], 0.05)
            self.assertAlmostEqual(a['cost'], (1000 * 0.75 + 100 * 3.75) / 1e6)
            self.assertNotIn('gateway_cost', b)
            self.assertAlmostEqual(G.spent(), 0.05 + b['cost'])


if __name__ == '__main__':
    unittest.main()
