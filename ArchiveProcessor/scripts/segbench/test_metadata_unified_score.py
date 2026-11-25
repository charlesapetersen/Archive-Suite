#!/usr/bin/env python3
"""Offline checks of metadata_unified_score.py and metadata_unified_gemini.py: the reply's shapes for each truth, the
date and enclosure measures, the sign test, and the runner's caps. No key, no network, no cache.

    python3 test_metadata_unified_score.py
"""
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import metadata_unified as M  # noqa: E402
import metadata_unified_gemini as G  # noqa: E402
import metadata_unified_score as S  # noqa: E402

REPLY = {"kind": "letter", "title": None, "byline": [], "publication": None, "publication_date": None,
         "sender": [{"name": "Jane Roe", "quote": "Jane Roe"}], "recipient": [{"name": "John Doe", "quote": "Dear Mr. Doe"}],
         "sending_place": [{"name": "Oxford", "quote": "OXFORD"}], "recipient_place": [],
         "date": {"year": 1947, "month": 3, "day": None, "lo": 1947, "hi": 1947, "date_uncertain": False,
                  "source": "self", "quote": "March 3, 1947"},
         "subject_tags": ["a", "b", "c"],
         "enclosure": {"announces": True, "announces_quote": "I enclose the report", "sent_with_previous": False,
                       "sent_with_quote": None, "confidence": 0.1}}


class Shapes(unittest.TestCase):
    def test_entity_pred_keeps_name_and_quote(self):
        p = S.ent_pred(REPLY)
        self.assertEqual(p["sender"], [{"name": "Jane Roe", "quote": "Jane Roe"}])
        self.assertEqual(p["sending_place"][0]["name"], "Oxford")
        self.assertEqual(S.ent_pred({"sender": "not a list"})["sender"], [])

    def test_item_pred_reads_value_objects(self):
        js = dict(REPLY, kind="clipping", title={"value": "The  Title", "quote": "THE TITLE"},
                  byline=[{"name": "A. Writer", "quote": "By A. Writer"}], publication={"value": "The Times", "quote": "x"},
                  publication_date={"value": "1931-05", "quote": "May 1931"})
        p = S.item_pred(js)
        self.assertEqual(p["kind"], "clipping")
        self.assertEqual(p["title"], "The Title")
        self.assertEqual(p["byline"], ["A. Writer"])
        self.assertEqual(p["publication_date"], (1931, 5, None))
        self.assertEqual(S.item_pred(dict(REPLY, kind="poster"))["kind"], "other")
        self.assertIsNone(S.item_pred(REPLY)["publication_date"])

    def test_date_pred_bounds(self):
        self.assertEqual(S.date_pred(REPLY), (1947, 3, False, "self", "March 3, 1947"))
        y, m, du, src, q = S.date_pred(dict(REPLY, date={"year": "1947", "month": 13, "date_uncertain": True, "source": "P1"}))
        self.assertEqual((y, m, du, src, q), (None, None, True, "P1", None))
        self.assertEqual(S.date_pred({})[:3], (None, None, False))


class Measures(unittest.TestCase):
    def test_sign_test(self):
        self.assertIsNone(S.binom_two_sided(0, 0))
        self.assertEqual(S.binom_two_sided(2, 4), 1.0)
        self.assertAlmostEqual(S.binom_two_sided(0, 6), 2 / 64)
        self.assertAlmostEqual(S.binom_two_sided(6, 6), 2 / 64)

    def test_date_scores_and_paired(self):
        ds = [{"id": "a"}, {"id": "b"}, {"id": "c"}, {"id": "d"}]
        tags = {"a": (1947, 3, "year+month"), "b": (1950, None, "year"), "c": (1960, None, "year+DU")}
        preds = {"a": (1947, 3, False), "b": (1951, None, False), "c": (None, None, True), "d": (1900, None, False)}
        s = S.date_scores(preds, tags, ds)
        self.assertEqual((s["docs"], s["year_given"], s["year_exact"], s["year_within_one"]), (3, 2, 1, 2))
        self.assertEqual((s["false_year"], s["uncertain"], s["month_docs"], s["month_exact"]), (1, 1, 1, 1))
        self.assertEqual(s["by_class"]["year"]["docs"], 1)
        other = {"a": (1946, None, True), "b": (1950, None, False), "c": (1960, None, True)}
        p = S.date_paired(other, preds, tags, ds)
        self.assertEqual((p.get("both", 0), p["only_a"], p["only_b"], p.get("neither", 0)), (0, 2, 1, 0))

    def test_date_evidence_checks_quote_in_cited_text(self):
        d = {"id": "x", "pages": ["f/0010.pdf", "f/0011.pdf"], "near": ["f/0009.pdf", "f/0012.pdf"]}
        texts = {"f/0009.pdf": "Letter of May 3, 1931 to the board", "f/0012.pdf": "later"}
        with mock.patch.object(M.IR, "page_text", side_effect=lambda p: texts[p]), \
                mock.patch.object(M.IR, "doc_text", return_value="[page 1 of 2]\nDear Sir, March 3, 1947"):
            full = {"x": (1947, 3, False, "self", "March 3, 1947")}
            ev = S.date_evidence(full, [d])
            self.assertEqual((ev["source_self"], ev["quote_in_text"], ev["quote_has_year"], ev["evidence_valid"]), (1, 1, 1, 1))
            full = {"x": (1931, None, True, "P1", "May 3, 1931")}
            ev = S.date_evidence(full, [d])
            self.assertEqual((ev["source_neighbour"], ev["neighbour_marked_uncertain"], ev["evidence_valid"]), (1, 1, 1))
            full = {"x": (1931, None, True, "P1", "March 3, 1947")}     # quoted from the wrong document, wrong year
            ev = S.date_evidence(full, [d])
            self.assertEqual((ev["quote_in_text"], ev["quote_has_year"], ev["evidence_valid"]), (0, 0, 0))
            ev = S.date_evidence({"x": (None, None, True, None, None)}, [d])
            self.assertEqual(ev, {"no_year": 1})

    def test_enclosure_stats_cues_and_quotes(self):
        d = {"id": "x", "pages": ["f/0010.pdf"], "near": ["f/0009.pdf"]}
        texts = {"f/0009.pdf": "I am sending you herewith the attached memo."}
        js = dict(REPLY, enclosure={"announces": True, "announces_quote": "I enclose the report", "sent_with_previous": True,
                                    "sent_with_quote": "sending you herewith the attached", "confidence": 0.95})
        with mock.patch.object(M.IR, "page_text", side_effect=lambda p: texts[p]), \
                mock.patch.object(M.IR, "doc_text", return_value="Dear Sir,\nI enclose the report.\n"):
            s = S.enclosure_stats({"x": js}, [d])
        self.assertEqual((s["docs"], s["with_p1"], s["announces"], s["announces_quote_in_text"]), (1, 1, 1, 1))
        self.assertEqual((s["sent_with_previous"], s["sent_with_quote_in_text"]), (1, 1))
        self.assertEqual(s["cues"], {"announces: enclose / enclosure": 1, "sent with P1: attach": 1})   # CUES order: the first cue found names the quote
        self.assertEqual(s["confidence"]["at_least_0.9"], 1)

    def test_ledger_means_reads_both_usage_shapes(self):
        with tempfile.TemporaryDirectory() as t:
            f = os.path.join(t, "calls.jsonl")
            with open(f, "w") as fh:
                fh.write(json.dumps({"http": 200, "cost": 0.002, "wall_s": 2.0, "usage": {"promptTokenCount": 100}}) + "\n")
                fh.write(json.dumps({"http": 200, "cost": 0.004, "wall_s": 4.0, "gateway_cost": 0.003,
                                     "usage": {"prompt_tokens": 300}}) + "\n")
                fh.write(json.dumps({"http": 500, "cost": 0.9, "wall_s": 9.0, "usage": {}}) + "\n")
            m = S.ledger_means(f)
        self.assertEqual((m["n"], m["cost_mean"], m["wall_mean"], m["prompt_mean"], m["gateway_cost_mean"]), (2, 0.003, 3.0, 200, 0.003))
        self.assertIsNone(S.ledger_means("/nonexistent/calls.jsonl"))


class Runner(unittest.TestCase):
    def test_cost_and_worst_case(self):
        with mock.patch.object(G, "price", return_value=(1.0, 2.0)):
            self.assertAlmostEqual(G.cost({"promptTokenCount": 1000, "candidatesTokenCount": 500, "thoughtsTokenCount": 500}), 0.003)
            self.assertAlmostEqual(G.worst(), (G.WORST_PROMPT * 1.0 + G.MAX_TOKENS * 2.0) / 1e6)

    def test_body_is_text_only_at_low_thinking(self):
        b = G.body("hello")
        self.assertEqual(b["contents"][0]["parts"], [{"text": "hello"}])
        self.assertEqual(b["generationConfig"]["thinkingConfig"], {"thinkingLevel": "low"})
        self.assertEqual(b["generationConfig"]["maxOutputTokens"], M.MAX_TOKENS)

    def test_caps_stop_before_sending(self):
        with tempfile.TemporaryDirectory() as t, \
                mock.patch.object(G, "CACHE", t), mock.patch.object(G, "KEY_LEDGERS", []), \
                mock.patch.object(G, "request", side_effect=AssertionError("must not call")), \
                mock.patch.object(G, "spent", return_value=1.99):
            with self.assertRaises(G.Stop):
                G.call("doc", "prompt")
        other = os.path.join(tempfile.mkdtemp(), "calls.jsonl")
        with open(other, "w") as fh:
            fh.write(json.dumps({"cost": 4.99}) + "\n")
        with tempfile.TemporaryDirectory() as t, \
                mock.patch.object(G, "CACHE", t), mock.patch.object(G, "KEY_LEDGERS", [other]), \
                mock.patch.object(G, "request", side_effect=AssertionError("must not call")):
            with self.assertRaises(G.Stop) as cm:
                G.call("doc", "prompt")
            self.assertIn("key total", str(cm.exception))

    def test_kept_reply_refused_on_another_prompt(self):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(G, "CACHE", t):
            dest = G.reply_path("doc")
            os.makedirs(os.path.dirname(dest))
            json.dump({"meta": {"prompt_sha256": M.sha("old"), "model_asked": G.MODEL}}, open(dest, "w"))
            with self.assertRaises(G.Stop):
                G.call("doc", "new prompt")
            self.assertTrue(G.call("doc", "old"))

    def test_order_puts_correspondence_first_and_is_seeded(self):
        ds = [{"id": str(i), "part": "base"} for i in range(10)]
        with mock.patch.object(G, "correspondence_ids", return_value={"3", "7"}):
            a = G.ordered(ds)
            b = G.ordered(ds)
        self.assertEqual([d["id"] for d in a[:2]], ["3", "7"])
        self.assertEqual(a, b)
        self.assertEqual(sorted(d["id"] for d in a), sorted(d["id"] for d in ds))


if __name__ == "__main__":
    unittest.main()
