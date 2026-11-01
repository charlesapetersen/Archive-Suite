"""W46.seg-boxes-score: paid cap, failure taxonomy and weighted owner support, synthetic inputs only."""
import argparse
import contextlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import seg_boxes_score as B
import seg_lincoln_gateway as S
import seg_truth_sheet as TS


class Collection(unittest.TestCase):
    def test_multiple_workers_refused_before_credentials_or_calls(self):
        with patch.object(B, "_mods", return_value=(None, None, S, None)), \
                patch.object(B, "gateway_key") as key:
            with self.assertRaisesRegex(SystemExit, "workers 1"):
                B.cmd_collect(argparse.Namespace(workers=2, limit=None))
            key.assert_not_called()

    def test_cap_refuses_next_request_and_preserves_first_charge(self):
        body = {"max_tokens": 100, "messages": [{"content": [{"type": "text", "text": "P"}]}]}
        raw = json.dumps({"pages": [{"page": n, "kind": "document"} for n in (1, 2)],
                          "boundaries": [{"between": [1, 2], "decision": "continue", "confidence": .9}]})
        response = SimpleNamespace(status_code=200, json=lambda: {
            "usage": {"prompt_tokens": 100, "completion_tokens": 50},
            "choices": [{"finish_reason": "stop", "message": {"content": raw}}]})
        cols = [SimpleNamespace(name=k) for k in ("a", "b")]
        with tempfile.TemporaryDirectory() as folder, \
                patch.object(B, "STORE", Path(folder)), patch.object(S, "STORE", Path(folder)), \
                patch.object(S, "CAP", .002), \
                patch.object(B, "_mods", return_value=(None, None, S, None)), \
                patch.object(B, "gateway_key"), patch.object(B, "release_unsent"), \
                patch.object(B, "jobs", return_value=[("boxes", c, 0, 2) for c in cols]), \
                patch.object(B, "gemini_answer", return_value=None), \
                patch.object(S, "request", side_effect=lambda route, col, *args: (body, col.name, [1, 2])), \
                patch.object(S.GW, "request", return_value=response) as send, \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "cap:"):
                B.cmd_collect(argparse.Namespace(workers=1, limit=None))
            self.assertEqual(send.call_count, 1)
            self.assertAlmostEqual(S.spent(), .0002625)
            self.assertEqual([r["event"] for r in S.records()], ["reserve", "settle"])

    def test_only_billed_parse_failure_can_vote_neutral(self):
        hit = {"valid": False, "request": {"charge": .03}, "response": {
            "choices": [{"finish_reason": "stop"}],
            "usage": {"prompt_tokens": 100, "completion_tokens": 50}}}
        rec = {"event": "settle", "http": 200, "charge": .001}
        self.assertTrue(B.invalid_model_reply(hit, rec))
        for change in ({"http": 429}, {"http": 503}, {"event": "unknown"}, {"charge": .04}):
            with self.subTest(change=change):
                self.assertFalse(B.invalid_model_reply(hit, {**rec, **change}))
        hit["response"]["usage"] = {}
        self.assertFalse(B.invalid_model_reply(hit, rec))


class OwnerSupport(unittest.TestCase):
    def estimate(self, missing_control=False):
        draft = {"pages": [{"n": 1}] + [{"n": n, "ask": n < 4, "p_new": .1 if n in (4, 5) else .9}
                                                  for n in range(2, 7)]}
        controls = [{"id": "a", "right": 4, "stratum": "low"}]
        if not missing_control:
            controls.append({"id": "b", "right": 6, "stratum": "high"})
        lock = {"owner_ruled_controls": {"gaps": controls}}
        rec = {"gaps": [{"i": i, "truth": "new"} for i in range(5)], "models": {
            "m": {"gaps": [[c, .9] for c in ("new", "continue", "new", "continue", "continue")]}}}
        col = SimpleNamespace(pages=[SimpleNamespace(n=n) for n in range(1, 7)])
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "lock.json").write_text(json.dumps(lock))
            (root / "draft.json").write_text(json.dumps(draft))
            with patch.object(B.data, "DATA_DIR", root), patch.object(B.data, "LOCKED", {"SC0122": "."}), \
                    patch.object(B, "SEED_DRAFT", root / "draft.json"), \
                    patch.object(TS, "stratum_of", side_effect=lambda p: "low" if p < .5 else "high"):
                return B.sc0122_owner(col, rec)

    def test_controls_weighted_to_full_strata_instead_of_pooled_as_a_census(self):
        r = self.estimate()
        self.assertEqual(r["strata"], {"low": [2, 1], "high": [1, 1]})
        self.assertEqual((r["asked_known"], r["controls"]), (2, 2))
        self.assertAlmostEqual(r["models"]["m"]["agreed_weighted_accuracy"], 2 / 3)
        self.assertAlmostEqual(r["models"]["m"]["owner_weighted_accuracy"], 3 / 5)

    def test_missing_control_stratum_cannot_silently_shrink_the_population(self):
        with self.assertRaisesRegex(ValueError, "high"):
            self.estimate(missing_control=True)

    def test_training_status_belongs_to_the_route(self):
        for box in B.BOXES:
            for route in ("gemini", "teacher"):
                self.assertEqual(B.route_split(route, box), "not fine-tuned")
            for route in ("mac-2b", "fs-2b", "fs-4b"):
                self.assertEqual(B.route_split(route, box), "held-out" if box == "Sasha" else "trained-on")


if __name__ == "__main__":
    unittest.main()
