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
    def test_new_uncertain_outcomes_stop_on_resume_before_key_or_send(self):
        for event in ("reserve", "unknown"):
            with self.subTest(event=event), tempfile.TemporaryDirectory() as folder, \
                    patch.object(B, "STORE", Path(folder)), patch.object(S, "STORE", Path(folder)), \
                    patch.object(B, "_mods", return_value=(None, None, S, None)), \
                    patch.object(B, "gateway_key") as key, patch.object(S, "call") as send:
                S.append({"id": "a", "event": "reserve", "charge": .03, "request_sha256": "hash"})
                if event == "unknown":
                    S.append({**S.records()[0], "event": "unknown"})
                before = S.records()
                with self.assertRaisesRegex(RuntimeError, "unsettled request"):
                    B.cmd_collect(argparse.Namespace(workers=1, limit=None))
                key.assert_not_called()
                send.assert_not_called()
                self.assertEqual(S.records(), before)
                self.assertAlmostEqual(S.spent(), .03)

    def test_saved_provider_failure_stops_before_any_other_window(self):
        with tempfile.TemporaryDirectory() as folder, \
                patch.object(B, "STORE", Path(folder)), patch.object(S, "STORE", Path(folder)), \
                patch.object(B, "_mods", return_value=(None, None, S, None)), \
                patch.object(B, "gateway_key") as key, patch.object(S, "call") as send:
            S.append({"id": "a", "event": "reserve", "charge": .03, "request_sha256": "hash"})
            S.append({**S.records()[0], "event": "settle", "http": 502, "valid": False})
            with self.assertRaisesRegex(RuntimeError, "saved provider/usage failure"):
                B.cmd_collect(argparse.Namespace(workers=1, limit=None))
            key.assert_not_called()
            send.assert_not_called()
            self.assertAlmostEqual(S.spent(), .03)

    def test_existing_explicit_unsent_approval_keeps_allowance_without_new_approval(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(S, "STORE", Path(folder)):
            S.append({"id": "a", "event": "reserve", "charge": .03, "request_sha256": "hash"})
            S.append({**S.records()[0], "event": "retry-approved"})
            B.check_prior_failures(S)
            self.assertEqual(len(S.records()), 2)
            self.assertAlmostEqual(S.spent(), .03)

    def test_saved_success_cannot_bypass_a_prior_reservation_overrun(self):
        with tempfile.TemporaryDirectory() as folder, \
                patch.object(B, "STORE", Path(folder)), patch.object(S, "STORE", Path(folder)), \
                patch.object(B, "_mods", return_value=(None, None, S, None)), \
                patch.object(B, "gateway_key") as key, patch.object(S, "call") as send:
            S.append({"id": "a", "event": "reserve", "charge": .01})
            S.append({"id": "a", "event": "settle", "charge": .02, "valid": True})
            with self.assertRaisesRegex(RuntimeError, "reservation"):
                B.cmd_collect(argparse.Namespace(workers=1, limit=None))
            key.assert_not_called()
            send.assert_not_called()
            self.assertEqual(len(S.records()), 2)

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
                patch.object(B, "gateway_key"), \
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


class OffsetCost(unittest.TestCase):
    def cost(self, rows, missing=False):
        col = SimpleNamespace(pages=list(range(10)))
        def hit(body, key):
            return None if missing else {"request": {"id": key, "request_sha256": key}}
        with patch.object(S, "effective_records", return_value=rows), \
                patch.object(S, "request", side_effect=lambda route, col, a, b: ({}, str(a), [])), \
                patch.object(S, "cache_hit", side_effect=hit):
            return B.offset_cost(S, col, [(0, 7), (3, 10)])

    def test_standalone_offset_counts_retained_attempts_and_excludes_other_windows(self):
        rows = [{"id": "0", "request_sha256": "0", "event": "settle", "charge": .01},
                {"id": "prior", "request_sha256": "3", "event": "retry-approved", "charge": .03},
                {"id": "3", "request_sha256": "3", "event": "settle", "charge": .02},
                {"id": "other", "request_sha256": "9", "event": "settle", "charge": 1}]
        r = self.cost(rows)
        self.assertEqual((r["windows"], r["attempts"]), (2, 3))
        self.assertAlmostEqual(r["charged_usd"], .06)
        self.assertAlmostEqual(r["usd_per_1000_pages"], 6)
        # Another offset using the same windows has the same standalone cost, not zero from cache reuse.
        self.assertEqual(self.cost(rows), r)

    def test_missing_reply_or_billing_cannot_be_a_free_offset(self):
        with self.assertRaisesRegex(RuntimeError, "cached window"):
            self.cost([], missing=True)
        with self.assertRaisesRegex(RuntimeError, "settled billing"):
            self.cost([])


class PartialReport(unittest.TestCase):
    def test_missing_gateway_and_offsets_are_explicitly_unmeasured(self):
        routes = [k for k in B.ROUTES if k != "gemini"]
        out = {"status": "offline arms only; gateway and offsets pending", "offsets": None, "paired": [],
               "observed": [{"route": k, "box": b, "split": B.route_split(k, b), "known gaps": 10,
                             "gap accuracy": .8, "right": 8, "false splits": 1, "false merges": 1,
                             "pages exact": .6, "failed windows": 0, "unsure": 2, "resolved pages": 20}
                            for b in B.BOXES for k in routes],
               "gateway": {"calls": 0, "input_tokens": 0, "output_tokens": 0, "invalid": 0, "spent": .0291,
                           "billed": {"gateway": None, "estimate": 0, "gateway_calls": 0, "calls": 0},
                           "mean_seconds": 0},
               "sc0122_owner": {"asked_known": 2, "controls": 2, "agreed_doc_gaps": 3,
                                "strata": {"low": [2, 1], "high": [1, 1]}, "models": {
                                    k: {"asked_right": 1, "controls_right": 1,
                                        "agreed_weighted_accuracy": 2 / 3, "owner_weighted_accuracy": 3 / 5}
                                    for k in routes}}}
        out["note"] = B.reading(out)
        report = B.render(out)
        self.assertIn("offline arms only; gateway and offsets pending", report)
        self.assertIn("seg_boxes_score.py score --local-only`", report)
        self.assertIn("Only the three owner boxes scored", report)
        self.assertIn("unmeasured", report)
        self.assertNotIn("| Gemini 3.7", report)
        self.assertNotIn("| 3.7 o0", report)
        self.assertNotIn("READING", report)
        self.assertIn("document-exact scores there remain conditional", out["note"])
        self.assertIn("2 unsure gaps excluded, 20 resolved document pages", report)
        f = {"pages_exact_no_review": .8, "flagged_per_100_pages": 10,
             "pages_exact_after_review": .9, "unflagged_errors_per_500_pages": 2,
             "usd_per_1000_pages": 4, "unflagged_errors": 1}
        pair = [{"gap": g, "said": "continue", "truth": "new", "confidence": .98} for g in ("101|102", "102|103")]
        out["offsets"] = {"rule": "frozen", "level": .9, "rows": {
            f"o{o}": {"figures": {**f, "usd_per_1000_pages": 4 + o, "usd_settled_per_1000_pages": 3 + o},
                      "by_box": {"Stanton": f}, "unflagged_gaps": {"Stanton": pair, "RG165": []}}
            for o in (0, 1, 2)}, "gemini38_o0": f, "gemini38_o0_by_box": {"Stanton": f},
            "gemini38_o0_unflagged_gaps": {"Stanton": pair, "RG165": []}}
        out["newsletter_gaps"] = newsletter()
        full = B.render(out)
        self.assertIn("$4.00 | $5.00 | $6.00 | $4.00–$6.00 | $4.00", full)
        self.assertIn("$3.00 | $4.00 | $5.00 | $3.00–$5.00 | — |", full)
        self.assertIn("total experiment spend counts it once", full)
        self.assertIn("## Gemini 3.7 (gateway) at the shipped route's rule and level, three window offsets", full)
        self.assertIn("the shipped 3.8 route's own offset range is unmeasured", full)
        self.assertIn("which every cloud route merges with or without the magazine rule", full)
        self.assertIn("same two confident Stanton gaps", full)

    def test_unflagged_note_only_names_the_newsletter_pair_when_every_run_has_exactly_it(self):
        pair = [{"gap": g} for g in ("101|102", "102|103")]
        off = {"rows": {f"o{o}": {"unflagged_gaps": {"Stanton": pair, "RG165": []}} for o in (0, 1, 2)},
               "gemini38_o0_unflagged_gaps": {"Stanton": pair, "RG165": []}}
        nl = newsletter()
        self.assertTrue(B.newsletter_only(off))
        self.assertIn("Every run's are the same pair", B.unflagged_note(off, nl))
        off["rows"]["o1"]["unflagged_gaps"]["RG165"] = [{"gap": "9|10"}]
        self.assertFalse(B.newsletter_only(off))
        self.assertNotIn("Every run's are the same pair", B.unflagged_note(off, nl))
        self.assertIn("3.7 o1: RG165 9|10, Stanton 101|102", B.unflagged_note(off, nl))

    def test_newsletter_cause_drops_when_a_cloud_route_splits_the_pair(self):
        nl = newsletter()
        self.assertIn("only the 2B trained on the owner's corpus splits", B.newsletter_cause(nl))
        nl["approaches"][1]["gaps"]["101|102"]["said"] = "new"
        self.assertIsNone(B.newsletter_cause(nl))


def newsletter():
    """newsletter_calls' shape: two cloud routes (one with the magazine rule) merge the pair, the 2B splits it."""
    def gaps(said):
        return {g: {"truth": "new", "said": said, "confidence": .98, "flagged": False} for g in ("101|102", "102|103")}
    return {"approaches": [
        {"id": "gemini", "label": "Gemini", "prompts": ["g1"], "magazine_rule": True, "gaps": gaps("continue")},
        {"id": "claude", "label": "Claude", "prompts": ["w1"], "magazine_rule": False, "gaps": gaps("continue")},
        {"id": "local", "label": "2B", "prompts": ["l1"], "magazine_rule": False, "gaps": gaps("new")}]}


if __name__ == "__main__":
    unittest.main()
