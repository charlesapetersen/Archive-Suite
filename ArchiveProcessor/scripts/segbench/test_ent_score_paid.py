#!/usr/bin/env python3
"""Unit tests for ent_score_paid.py's pure helpers (no cache, no gateway): python3 test_ent_score_paid.py"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import date_tagging as DT  # noqa: E402
import ent_score_paid as P  # noqa: E402


def truth(**fields):
    t = {"id": "d", "sender": [], "recipient": [], "sending_place": []}
    for f, names in fields.items():
        t[f] = [{"name": n, "quote": None, "class": c} for n, c in names]
    return t


class Context(unittest.TestCase):
    def test_round_trip(self):
        ctx = "Doc A: 1951 letter\nDoc B: 1952 memo"
        self.assertEqual(P.context_of(DT.build_prompt("some text", ctx)), ctx)

    def test_none(self):
        self.assertIsNone(P.context_of(DT.build_prompt("some text", None)))


class Parse(unittest.TestCase):
    def test_fenced(self):
        self.assertEqual(P.parse('```json\n{"sender": []}\n```'), {"sender": []})

    def test_bad(self):
        self.assertIsNone(P.parse("no json here"))
        self.assertIsNone(P.parse(None))
        self.assertIsNone(P.parse("[1, 2]"))


class Evidence(unittest.TestCase):
    def test_groups(self):
        tr = {"d": truth(sender=[("Ada Fielding", "named")], recipient=[("Basil Thorne", "role-inferred")])}
        pred = {"d": {"sender": [{"name": "Ada Fielding", "quote": "Ada Fielding"},
                                 {"name": "John Doe", "quote": "Jon Doe"}],
                      "recipient": [{"name": "Basil Thorne", "quote": None}],
                      "sending_place": [{"name": "Chicago, Illinois", "quote": None}]}}
        ev = P.evidence(pred, tr, {"d": "Yours, Ada Fielding"}, 3000)
        self.assertEqual(ev["sender"]["quote in text"], [1, 0])
        self.assertEqual(ev["sender"]["quote not in text"], [0, 1])
        self.assertEqual(ev["recipient"], {})            # an inferred truth's match is set aside
        self.assertEqual(ev["sending_place"]["no quote"], [0, 1])


class Paired(unittest.TestCase):
    def test_sign_and_interval(self):
        ids = [f"d{i}" for i in range(20)]
        tr = {i: {**truth(sender=[("Ada Fielding", "named")]), "id": i} for i in ids}
        a = {i: {"sender": None} for i in ids}
        b = {i: {"sender": "Ada Fielding"} for i in ids}
        r = P.paired(a, b, ids, tr, "sender")
        self.assertEqual(r["n"], 20)
        self.assertAlmostEqual(r["diff"], 1.0)
        self.assertLessEqual(r["lo"], r["diff"])
        self.assertGreaterEqual(r["hi"], r["diff"])
        self.assertEqual(P.paired(a, a, ids, tr, "sender")["diff"], 0.0)


class City(unittest.TestCase):
    def test_both_sides_cut(self):
        tr = {"d": {**truth(), "sending_place": [{"name": "Springfield, IL", "quote": None, "class": "named",
                                                  "alternates": ["Springfield, Illinois"]}]}}
        pc, tc = P.by_city({"d": {"sending_place": [{"name": "Springfield, Illinois", "quote": "SPRINGFIELD"}]}}, tr)
        self.assertEqual(pc["d"]["sending_place"], ["Springfield"])
        self.assertEqual(tc["d"]["sending_place"][0]["name"], "Springfield")
        self.assertEqual(P.doc_counts(tc["d"], pc["d"], "sending_place"), (1, 0, 0))
        self.assertEqual(P.by_city({"d": {"sending_place": None}}, tr)[0]["d"]["sending_place"], [])



class TaggingBefore(unittest.TestCase):
    """The tagging arm keeps the prompt its cached replies answered: its three entity rules pinned, every other line
    as the app sends it. W46.ent-prompt-app changed those three and W46.tagging-prompt-revert put them back, so today
    the pinned prompt is the app's own."""
    def test_three_rules_pinned(self):
        app = DT.build_prompt("body", "ctx")
        self.assertEqual(P.tagging_prompt_before("body", "ctx"), app)
        for line in P.TAGGING_RULES_BEFORE.values():
            self.assertIn("\n" + line + "\n", app)


class TaggingPreds(unittest.TestCase):
    def test_array_joined_as_the_app_joins_it(self):
        import ent_score as ES
        self.assertEqual(ES.split_names("; ".join(["Jane Doe", "John Smith"])), ["Jane Doe", "John Smith"])


class ReplyCache(unittest.TestCase):
    """A cached reply is returned only for the prompt it answered (measurement review 2026-11-03, P6-5)."""
    def setUp(self):
        import tempfile
        self.dir = tempfile.mkdtemp()
        self.rows, P.rows = P.rows, lambda: [({}, {"id": "a"}), ({}, {"id": "b"})]

    def tearDown(self):
        import shutil
        P.rows = self.rows
        shutil.rmtree(self.dir)

    def put(self, label, doc, meta):
        P.write_reply(P.reply_path(label, doc, self.dir), {"meta": meta, "raw": "{}"})

    R = {"model": "m1", "temperature": 0, "max_tokens": 8192}

    def test_same_prompt_hit_other_refused(self):
        dest = P.reply_path("x", "a", self.dir)
        self.assertIsNone(P.cached(dest, "p", self.R))
        self.put("x", "a", {"prompt_sha256": P.prompt_sha("p"), "request": self.R})
        self.assertEqual(P.cached(dest, "p", self.R)["raw"], "{}")
        with self.assertRaises(SystemExit):
            P.cached(dest, "p\n", self.R)

    def test_other_settings_refused(self):
        """Measurement review 2026-11-04, P7-7: a model, temperature or token-cap change is a new call."""
        dest = P.reply_path("x", "a", self.dir)
        self.put("x", "a", {"prompt_sha256": P.prompt_sha("p"), "request": self.R})
        for k, v in (("model", "m2"), ("temperature", 0.5), ("max_tokens", 4096)):
            with self.assertRaises(SystemExit):
                P.cached(dest, "p", {**self.R, k: v})
        self.put("x", "b", {"prompt_sha256": P.prompt_sha("p")})          # a hash but no settings
        with self.assertRaises(SystemExit):
            P.cached(P.reply_path("x", "b", self.dir), "p", self.R)

    def test_unstamped_and_unknown_refused(self):
        self.put("x", "a", {})
        with self.assertRaises(SystemExit):
            P.cached(P.reply_path("x", "a", self.dir), "p", self.R)
        self.put("x", "b", {"prompt_sha256": None, "prompt_hash": "unknown"})
        with self.assertRaises(SystemExit):
            P.cached(P.reply_path("x", "b", self.dir), "p", self.R)

    def test_call_refuses_before_the_gateway(self):
        import types
        G = sys.modules.setdefault("gateway_gemini", types.ModuleType("gateway_gemini"))
        G.MODEL, G.MAX_TOKENS = getattr(G, "MODEL", "m1"), getattr(G, "MAX_TOKENS", 8192)
        self.put("x", "a", {"prompt_sha256": P.prompt_sha("old"), "request": P.request_settings()})
        with self.assertRaises(SystemExit):
            P.call("x", "a", "new", cache=self.dir)
        self.put("x", "a", {"prompt_sha256": P.prompt_sha("new"), "request": {**P.request_settings(), "model": "?"}})
        with self.assertRaises(SystemExit):
            P.call("x", "a", "new", cache=self.dir)

    def ledger(self, *recs):
        with open(os.path.join(self.dir, "calls.jsonl"), "w") as fh:
            for r in recs:
                fh.write(json.dumps(r) + "\n")

    def test_stamp(self):
        B = P.REQUEST_BEFORE
        self.ledger({"doc": "a", "t": 1, "http": 200, "model": B["model"]},
                    {"doc": "b", "t": 2, "http": 200, "model": B["model"]})
        self.put("x", "a", {"t": 1})
        self.put("x", "b", {"t": 2, "prompt_sha256": P.prompt_sha("other")})
        self.put("y", "a", {"t": 9})                                          # no ledger line for this call
        got = P.stamp({"x": lambda d: "prompt " + d["id"], "y": None}, self.dir)
        self.assertEqual(got["x"], {"reconstructed": 1, "had a hash, DIFFERENT": 1, "settings reconstructed": 2})
        self.assertEqual(got["y"], {"unknown": 1, "settings unknown": 1})
        a = P.cached(P.reply_path("x", "a", self.dir), "prompt a", B)["meta"]
        self.assertEqual((a["prompt_hash"], a["request_settings"], a["request"]), ("reconstructed", "reconstructed", B))
        b = json.load(open(P.reply_path("x", "b", self.dir)))["meta"]
        self.assertEqual(b["prompt_sha256"], P.prompt_sha("other"))   # a recorded hash is never changed
        with self.assertRaises(SystemExit):
            P.check_replies("y", self.dir, lambda d: "p", B)        # unknown and missing-hash replies stop a report
        again = P.stamp({"x": lambda d: "prompt " + d["id"]}, self.dir)["x"]
        self.assertEqual(again["had settings, same"], 2)              # recorded settings are compared, never changed

    def test_stamp_needs_the_ledger_model(self):
        self.ledger({"doc": "a", "t": 1, "http": 200, "model": "another-model"})
        self.put("x", "a", {"t": 1})
        self.assertEqual(P.stamp({"x": lambda d: "p"}, self.dir)["x"]["settings unknown"], 1)


if __name__ == "__main__":
    unittest.main()
