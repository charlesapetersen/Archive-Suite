"""W46.seg-window-modality-paid: the text-only rewrite, the ledger's cap and retry rules, the per-page exact count and
the paired bootstrap, on toy data and a mocked gateway.
Run: /usr/local/bin/python3 test_seg_window_gateway.py   (no bench data, no gateway call)."""
import json
from pathlib import Path
import random
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import seg_window_gateway as S
from score import score_labels


def body(images=3, prompt=None):
    nums = list(range(1, images + 1))
    parts = []
    for n in nums:
        parts += [{"type": "text", "text": f"Page {n}:"}, {"type": "image_url", "image_url": {"url": "data:x"}}]
    parts.append({"type": "text", "text": prompt or ("intro " + S.OLD_PARA.format(k=len(nums)) + " rest")})
    return {"model": "gemini-3.7-flash", "temperature": 0, "max_tokens": 4096,
            "messages": [{"role": "user", "content": parts}]}, "key", nums


def reply(nums, new=()):
    return json.dumps({"pages": [{"page": n, "kind": "document"} for n in nums],
                       "boundaries": [{"between": [x, x + 1], "decision": "new" if x in new else "continue",
                                       "cue": "c", "confidence": 0.9} for x in nums[:-1]]})


class Response:
    def __init__(self, content, status=200, finish="stop", usage=(1000, 100)):
        self.status_code, self.headers, self.text = status, {}, ""
        self._j = {"model": "gemini-3.7-flash", "choices": [{"finish_reason": finish, "message": {"content": content}}],
                   "usage": {"prompt_tokens": usage[0], "completion_tokens": usage[1]} if usage else {}}

    def json(self):
        return self._j


class TextOnly(unittest.TestCase):
    def test_drops_images_and_rewrites_one_paragraph(self):
        with mock.patch.object(S.LG, "request", return_value=body()):
            b, key, nums = S.request(SimpleNamespace(name="Toy"), 0, 3, "k3-t")
        parts = b["messages"][0]["content"]
        self.assertEqual(len(parts), 1)
        self.assertNotIn("images above", parts[0]["text"])
        self.assertIn("pages 1 to 3. The photographs are not shown", parts[0]["text"])
        self.assertTrue(parts[0]["text"].startswith("intro ") and parts[0]["text"].endswith(" rest"))
        self.assertNotEqual(key, "key")
        self.assertEqual({k: v for k, v in b.items() if k != "messages"},
                         {k: v for k, v in body()[0].items() if k != "messages"})

    def test_refuses_when_the_paragraph_is_missing(self):
        with mock.patch.object(S.LG, "request", return_value=body(prompt="no such paragraph")):
            with self.assertRaises(ValueError):
                S.request(SimpleNamespace(name="Toy"), 0, 3, "k3-t")

    def test_image_arm_is_the_lincoln_request_unchanged(self):
        b = body()
        with mock.patch.object(S.LG, "request", return_value=b):
            self.assertIs(S.request(SimpleNamespace(name="Toy"), 0, 3, "k3-it")[0], b[0])


class Ledger(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.p = mock.patch.object(S, "STORE", Path(self.tmp.name))
        self.p.start()
        self.col = SimpleNamespace(name="Toy")

    def tearDown(self):
        self.p.stop()
        self.tmp.cleanup()

    def run_call(self, response, cap=8.0):
        with mock.patch.object(S.LG, "request", return_value=body()), \
                mock.patch.object(S.GW, "request", return_value=response) as send, \
                mock.patch.object(S, "ITEM_CAP_USD", cap), mock.patch.object(S.time, "sleep"):
            return S.call("k3-it", self.col, 0, 3), send

    def test_ok_is_cached_and_settled_at_token_cost(self):
        out, send = self.run_call(Response(reply([1, 2, 3])))
        self.assertEqual(out, "ok")
        self.assertAlmostEqual(S.spent(), (1000 * .75 + 100 * 3.75) / 1e6)
        out, send = self.run_call(Response(reply([1, 2, 3])))
        self.assertEqual(out, "cached")
        send.assert_not_called()

    def test_cap_refuses_before_sending(self):
        out, send = self.run_call(Response(reply([1, 2, 3])), cap=0.001)
        self.assertEqual(out, "skipped")
        send.assert_not_called()
        self.assertEqual(S.records(), [])

    def test_failure_is_charged_and_resent_once_only(self):
        for want in ("failed", "failed"):
            out, _ = self.run_call(Response('{"pages": []}'))
            self.assertEqual(out, want)
        out, send = self.run_call(Response(reply([1, 2, 3])))
        self.assertEqual(out, "failed")       # two attempts made: no third send
        send.assert_not_called()
        self.assertAlmostEqual(S.spent(), 2 * (1000 * .75 + 100 * 3.75) / 1e6)

    def test_resend_skips_the_gateway_cache(self):
        _, first = self.run_call(Response('{"pages": []}'))
        self.assertNotIn("cache", first.call_args[0][1])
        out, second = self.run_call(Response(reply([1, 2, 3])))
        self.assertEqual(out, "ok")
        sent = second.call_args[0][1]
        self.assertEqual(sent["cache"], {"no-cache": True})
        self.assertEqual({k: v for k, v in sent.items() if k != "cache"}, body()[0])
        self.assertEqual(len({r["request_sha256"] for r in S.records()}), 1)   # the key is the uncached request's

    def test_transport_error_keeps_the_reservation(self):
        with mock.patch.object(S.LG, "request", return_value=body()), \
                mock.patch.object(S.GW, "request", side_effect=OSError("reset")):
            self.assertEqual(S.call("k3-it", self.col, 0, 3), "failed")
        self.assertAlmostEqual(S.spent(), S.allowance(body()[0]))

    def test_unfinished_reply_is_a_failure(self):
        out, _ = self.run_call(Response(reply([1, 2, 3]), finish="length"))
        self.assertEqual(out, "failed")

    def test_rate_limit_is_waited_out_uncharged(self):
        seq = [Response("", status=429, usage=None), Response(reply([1, 2, 3]))]
        with mock.patch.object(S.LG, "request", return_value=body()), \
                mock.patch.object(S.GW, "request", side_effect=seq), mock.patch.object(S.time, "sleep"):
            self.assertEqual(S.call("k3-it", self.col, 0, 3), "ok")
        self.assertEqual(sum(r["event"] == "reserve" for r in S.records()), 1)


class Scoring(unittest.TestCase):
    def test_exact_pages_matches_the_scorer(self):
        rng = random.Random(1)
        for _ in range(300):
            n = rng.randint(2, 30)
            truth = [rng.choice(["New", "Cont", "Cont", "Folder"]) for _ in range(n)]
            pred = [t if t == "Folder" else rng.choice(["New", "Cont"]) for t in truth]
            ex = S.exact_pages(truth, pred)
            self.assertEqual(sum(bool(x) for x in ex), score_labels(truth, pred).pages_exact, (truth, pred))
            self.assertEqual(sum(x is not None for x in ex), score_labels(truth, pred).doc_pages)

    def test_bootstrap_of_identical_arms_is_zero(self):
        a = [True, False, True, True]
        r = S.bootstrap(a, a, [[0, 1], [2, 3]], rounds=200)
        self.assertEqual((r["delta"], r["lo"], r["hi"]), (0, 0, 0))

    def test_bootstrap_delta_is_the_pooled_difference(self):
        r = S.bootstrap([True, True, True, False], [False, True, False, False], [[0, 1], [2, 3]], rounds=200)
        self.assertAlmostEqual(r["delta"], 0.5)
        self.assertLessEqual(r["lo"], r["delta"])
        self.assertGreaterEqual(r["hi"], r["delta"])

    def test_clusters_are_the_runs_between_label_photos(self):
        col = SimpleNamespace(labels=["Box", "Folder", "New", "Cont", "Folder", "New", "Folder"])
        self.assertEqual(S.clusters(col), [[2, 3], [5]])

    def test_loss_difference_is_the_difference_of_the_two_losses(self):
        # Per-page loss vectors (text less images) for two models: the bootstrap's delta is loss A less loss B.
        ga = [0, -1, 0, 0, -1, 0]          # Gemini loses 2 of 6
        gb = [-1, -1, -1, 0, -1, 0]        # the 2B loses 4 of 6
        r = S.bootstrap(ga, gb, [[0, 1], [2, 3], [4, 5]], rounds=200)
        self.assertAlmostEqual(r["delta"], 2 / 6)
        self.assertLessEqual(r["lo"], r["delta"])
        self.assertGreaterEqual(r["hi"], r["delta"])

    def test_two_b_pages_is_none_without_the_pack(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertIsNone(S.two_b_pages({}, Path(d)))


if __name__ == "__main__":
    unittest.main()
