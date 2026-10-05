"""Request building, response parsing and voting of approach B (W36.seg-second), on toy data.
Run: <lab venv>/bin/python test_gemini.py   (no bench data, no network, no key)."""
import base64
import json
import sys
import types
import unittest
from types import SimpleNamespace

import method_gemini as G
from methods import METHODS, Prediction
from score import check_prediction


def reply(text=None, parts=None, finish="STOP", **extra):
    parts = parts if parts is not None else [{"text": text}]
    return {"candidates": [{"content": {"parts": parts, "role": "model"}, "finishReason": finish}],
            "usageMetadata": {"promptTokenCount": 1000, "candidatesTokenCount": 100, "thoughtsTokenCount": 20},
            **extra}


ANSWER = json.dumps({"pages": [{"page": 4, "kind": "document"}, {"page": 5, "kind": "folder"}],
                     "boundaries": [{"between": [4, 5], "decision": "new", "cue": "folder tab", "confidence": 0.9}]})


class Request(unittest.TestCase):
    def test_body_interleaves_pages_and_images_then_prompt(self):
        body = G.request_body("PROMPT", [b"img4", b"img5"], [4, 5])
        parts = body["contents"][0]["parts"]
        self.assertEqual([p.get("text") for p in parts[::2]], ["Page 4:", "Page 5:", "PROMPT"])
        self.assertEqual(base64.b64decode(parts[1]["inlineData"]["data"]), b"img4")
        self.assertEqual(parts[1]["inlineData"]["mimeType"], "image/jpeg")
        cfg = body["generationConfig"]
        self.assertEqual(cfg["temperature"], 0)
        self.assertEqual(cfg["thinkingConfig"], {"thinkingLevel": "minimal"})
        self.assertEqual(cfg["responseMimeType"], "application/json")
        self.assertIn("boundaries", cfg["responseSchema"]["properties"])

    def test_prompt_carries_the_owners_cues(self):
        p = G.PROMPT.lower()
        for cue in ("onion skin", "(ap)", "(upi)", "byline", "magazine", "never reordered", "small item",
                    "envelope", "carbon copy", "photographed twice"):
            self.assertIn(cue, p)

    def test_model_and_cache_namespace(self):
        self.assertEqual(G.MODEL, "gemini-3.1-flash-lite")
        self.assertEqual(G.CACHE.dir.name, "window-gemini-lite")


class Response(unittest.TestCase):
    def test_parse_ok_and_thought_parts_skipped(self):
        r = reply(parts=[{"text": "thinking...", "thought": True}, {"text": ANSWER}])
        p = G.parse_response(r, [4, 5])
        self.assertEqual(p["pages"], {4: "document", 5: "folder"})
        self.assertEqual(p["boundaries"][4]["decision"], "new")

    def test_blocked_and_truncated_replies_raise(self):
        for bad in ({"promptFeedback": {"blockReason": "SAFETY"}}, {"candidates": []},
                    reply(ANSWER, finish="MAX_TOKENS"), reply(ANSWER, finish="RECITATION"), reply("   ")):
            with self.assertRaises(G.Blocked):
                G.parse_response(bad, [4, 5])

    def test_bad_answers_are_parse_errors(self):
        with self.assertRaises(G.W.ParseError):
            G.parse_response(reply(ANSWER), [4, 5, 6])          # a gap missing
        with self.assertRaises(G.W.ParseError):
            G.parse_response(reply(ANSWER.replace('"new"', '"maybe"')), [4, 5])

    def test_usage_and_cost(self):
        u = G.usage(reply(ANSWER))
        self.assertEqual(u, {"in": 1000, "out": 100, "thought": 20})
        self.assertAlmostEqual(G.cost_usd(u), (1000 * G.PRICE_IN + 120 * G.PRICE_OUT) / 1e6)


class KeyHandling(unittest.TestCase):
    def test_key_goes_in_the_header_and_never_in_the_error(self):
        seen = {}

        class Resp:
            status_code, text, headers = 400, '{"error": "bad request"}', {}

        def fake_post(url, json=None, timeout=None, headers=None):
            seen.update(url=url, headers=headers)
            return Resp()

        fake = types.ModuleType("requests")
        fake.post, fake.RequestException = fake_post, Exception
        old_req, old_key = sys.modules.get("requests"), G._key
        sys.modules["requests"], G._key = fake, "SECRET-KEY-123"
        try:
            with self.assertRaises(G.Fatal) as cm:
                G.post("generateContent", {})
        finally:
            G._key = old_key
            if old_req is not None:
                sys.modules["requests"] = old_req
        self.assertEqual(seen["headers"]["x-goog-api-key"], "SECRET-KEY-123")
        self.assertNotIn("SECRET", seen["url"])
        self.assertNotIn("SECRET", str(cm.exception))


def pred(labels, decisions, confs):
    return Prediction(labels, [{"decision": d, "confidence": c, "cue": ""} for d, c in zip(decisions, confs)])


class Voting(unittest.TestCase):
    def test_flagged_and_review(self):
        truth = ["New", "Cont", "New", "New"]
        a = pred(["New", "Cont", "New", "Cont"], ["continue", "new", "continue"], [0.9, 0.9, 0.6])
        b = pred(["New", "Cont", "New", "New"], ["continue", "new", "new"], [0.9, 0.9, 0.95])
        check_prediction(a)
        check_prediction(b)
        self.assertEqual(G.flagged(a, b), [2])
        # unreviewed disagreement: the more confident model (b) wins
        self.assertEqual(G.vote_labels(truth, (a, b), set()), ["New", "Cont", "New", "New"])
        # both agree wrongly at gap 0: review of the flagged gap does not fix it
        truth2 = ["New", "New", "New", "Cont"]
        self.assertEqual(G.vote_labels(truth2, (a, b), {2}), ["New", "Cont", "New", "Cont"])

    def test_photo_disagreement_is_flagged(self):
        a = pred(["Folder", "New", "Cont"], ["new", "continue"], [1.0, 0.9])
        b = pred(["New", "New", "Cont"], ["new", "continue"], [0.9, 0.9])
        self.assertEqual(G.flagged(a, b), [0])


class Guard(unittest.TestCase):
    def test_refuses_test_collections(self):
        for name in ("Stanton", "RG165"):
            with self.assertRaises(SystemExit):
                G.refuse_test(["Dean", name])
            with self.assertRaises(SystemExit):
                METHODS["window-gemini-lite"].predict(SimpleNamespace(name=name))
        self.assertTrue(METHODS["window-gemini-lite"].tuning)
        self.assertTrue(METHODS["window-gemini-lite-truth-photos"].oracle_photos)


if __name__ == "__main__":
    unittest.main()
