#!/usr/bin/env python3
"""date_traceable_gateway.py: which documents are sent, and the spending cap refusing before any request.

    python3 -m unittest test_date_traceable_gateway
"""
import json
import os
import tempfile
import unittest
from unittest import mock

import date_traceable_gateway as GW


def doc(i, text, cls):
    return {"id": f"o:{i}", "cls": cls, "text": text, "truth": {"year": 1947} if cls != "decade" else {"decade": 1940}}


class Targets(unittest.TestCase):
    def test_undated_or_not_in_text_are_sent_printed_years_are_not(self):
        docs = [doc(1, "March 3, 1947", "in text"),          # printed and in text: never sent
                doc(2, "no date here", "decade"),             # undated: the residue at every threshold
                doc(3, "the 1939 act", "C"),                 # a printed year, but not the document's: one-shot row
                doc(4, "no date here", "D")]
        self.assertEqual([d["id"] for d in GW.targets(docs)], ["o:2", "o:3", "o:4"])


class Cap(unittest.TestCase):
    def test_refuses_before_a_request_when_the_worst_case_would_pass_the_cap(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(GW, "CACHE", tmp), \
                mock.patch.object(GW.G, "request") as req:
            with open(os.path.join(tmp, "calls.jsonl"), "w") as fh:
                fh.write(json.dumps({"cost": GW.CAP - GW.WORST / 2}) + "\n")
            with self.assertRaises(SystemExit):
                GW.call("trace-plain|o:1", "prompt", os.path.join(tmp, "plain", "o_1.json"))
            req.assert_not_called()

    def test_a_cached_reply_is_returned_without_a_request(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(GW.G, "request") as req:
            p = os.path.join(tmp, "r.json")
            json.dump({"id": "x", "raw": "{}"}, open(p, "w"))
            self.assertEqual(GW.call("x", "prompt", p)["id"], "x")
            req.assert_not_called()


if __name__ == "__main__":
    unittest.main()
