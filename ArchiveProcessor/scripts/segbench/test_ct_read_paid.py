#!/usr/bin/env python3
"""W47.ct-read-paid: the gateway arm of ct_read.py against a fake gateway, in a temporary cache. No money, no key.

    python3 test_ct_read_paid.py

Needs the truth's photos in the bench cache (`ct_truth.POOL`); skips without them.
"""
import argparse
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ct_read as R
import gateway_gemini as G

REPLY = '{"kind": "box label", "container": "Box 7", "folder": null}'


class Resp:
    status_code = 200
    headers = {"content-type": "application/json", "x-litellm-response-cost": "0.0011"}

    def json(self):
        return {"model": "gpt-5.6-luna", "usage": {"prompt_tokens": 1500, "completion_tokens": 300},
                "choices": [{"finish_reason": "stop", "message": {"content": REPLY}}]}


@unittest.skipUnless(os.path.exists(R.TRUTH), "the label truth is not in the bench cache")
class GatewayArm(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = (R.CACHE, R.PAID_LEDGER, R.PAID_CAP, G.request)
        R.CACHE = self.tmp.name
        R.PAID_LEDGER = os.path.join(self.tmp.name, "gateway-calls.jsonl")
        self.bodies = []

        def fake(path, body=None, timeout=300):
            self.bodies.append((path, body))
            return Resp()
        G.request = fake

    def tearDown(self):
        R.CACHE, R.PAID_LEDGER, R.PAID_CAP, G.request = self.saved
        self.tmp.cleanup()

    def run_arm(self, limit):
        R.cmd_gateway(argparse.Namespace(model="luna-gw", limit=limit))

    def test_reads_ledgers_and_caches(self):
        self.run_arm(3)
        self.assertEqual(len(self.bodies), 3)
        path, body = self.bodies[0]
        self.assertEqual(path, "/chat/completions")
        self.assertEqual((body["model"], body["temperature"], body["reasoning_effort"]), ("gpt-5.6-luna", 0, "low"))
        self.assertEqual(body["messages"][0]["content"][1]["text"], R.PROMPT)
        led = R.paid_ledger()
        self.assertEqual(len(led), 3)
        self.assertTrue(all(x["key"] == "luna-gw" and x["gateway_cost"] == 0.0011 for x in led))
        # charged is the larger of the estimate (1500 * 0.20 + 300 * 1.20) / 1e6 = 0.00066 and the gateway's 0.0011
        self.assertAlmostEqual(R.paid_spent(), 3 * 0.0011)
        reads = os.listdir(R.draft_dir("luna-gw"))
        self.assertEqual(len(reads), 3)
        self.run_arm(3)   # the limit counts unread photos: three more, never the cached three again
        self.assertEqual(len(self.bodies), 6)
        self.assertEqual(len({x["id"] for x in R.paid_ledger()}), 6)

    def test_cap_stops_before_a_call(self):
        self.run_arm(2)
        R.PAID_CAP = R.paid_spent() + 0.001   # less than one worst-case call left
        n = len(self.bodies)
        self.run_arm(4)
        self.assertEqual(len(self.bodies), n)
        self.assertEqual(len(R.paid_ledger()), 2)

    def test_cap_reserves_calls_in_flight(self):
        worst = (R.PAID_WORST_IN * R.PAID["luna-gw"][2][0] + R.PAID_MAX_TOKENS * R.PAID["luna-gw"][2][1]) / 1e6
        R.PAID_CAP = 2.5 * worst   # room for two worst cases, never more, however many threads start
        self.run_arm(8)
        self.assertLessEqual(len(self.bodies), 2)
        self.assertGreaterEqual(len(self.bodies), 1)

    def test_scored_on_every_cell_like_a_non_drafter(self):
        self.assertNotIn("luna-gw", R.DRAFTERS)
        self.run_arm(2)
        rows = [r for r in R.truth() if os.path.exists(os.path.join(R.draft_dir("luna-gw"), r["id"] + ".json"))]
        self.assertEqual(len(rows), 2)
        self.assertEqual(R.reading(rows[0], "luna-gw")["container"], "Box 7")
        other = next(r for r in R.truth() if r["id"] not in {x["id"] for x in rows})
        self.assertEqual(R.reading(other, "luna-gw"), "missing")


if __name__ == "__main__":
    unittest.main()
