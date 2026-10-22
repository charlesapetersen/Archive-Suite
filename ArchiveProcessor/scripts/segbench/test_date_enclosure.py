#!/usr/bin/env python3
"""Tests for date_enclosure.py (W46.date-enclosure). No corpus, no model: python3 -m unittest test_date_enclosure"""
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import date_enclosure as E

DOC = {"id": "x", "cover_text": "Dear Sir,\nI enclose the report on harbour works.\nSincerely,\nJ. Smith\nEnc.",
       "first_page_text": "REPORT ON HARBOUR WORKS\nPrepared for the Board"}


class ParseRelate(unittest.TestCase):
    def test_plain_json(self):
        p = E.parse_relate('{"sent_with": true, "cue": "I enclose the report", "confidence": 0.9}')
        self.assertEqual(p, {"sent_with": True, "cue": "I enclose the report", "confidence": 0.9})

    def test_thinking_and_fence_stripped(self):
        p = E.parse_relate('<think>hmm {"sent_with": true}</think>```json\n{"sent_with": false, "cue": null}\n```')
        self.assertEqual(p["sent_with"], False)
        self.assertIsNone(p["confidence"])

    def test_string_verdict_and_clamped_confidence(self):
        p = E.parse_relate('{"sent_with": "yes", "confidence": 7}')
        self.assertTrue(p["sent_with"])
        self.assertEqual(p["confidence"], 1.0)

    def test_no_verdict_is_no_reply(self):
        for raw in ("", "no json here", '{"cue": "x"}', '{"sent_with": "maybe"}', "{broken"):
            self.assertIsNone(E.parse_relate(raw), raw)


class Cue(unittest.TestCase):
    def test_quote_found_in_either_document_folded(self):
        self.assertTrue(E.cue_found("i  ENCLOSE the report", DOC))
        self.assertTrue(E.cue_found('"Prepared for the Board."', DOC))
        self.assertFalse(E.cue_found("attached herewith", DOC))
        self.assertIsNone(E.cue_found(None, DOC))

    def test_rule_reads_the_tail_or_the_whole_cover(self):
        long = {"cover_text": "I enclose a copy.\n" + "x" * 1000 + "\nSincerely"}
        self.assertFalse(E.cue_rule(long))
        self.assertTrue(E.cue_rule(long, tail=0))
        self.assertTrue(E.cue_rule(DOC))

    def test_cover_excerpt_keeps_start_and_end(self):
        t = "A" * 2000 + "B" * 2000
        x = E.cover_excerpt(t)
        self.assertTrue(x.startswith("A" * E.COVER_HEAD) and x.endswith("B" * E.COVER_TAIL) and "[…]" in x)
        self.assertEqual(E.cover_excerpt("short"), "short")

    def test_prompt_carries_both_texts_and_no_year_hint(self):
        p = E.relate_prompt(DOC)
        self.assertIn("I enclose the report", p)
        self.assertIn("REPORT ON HARBOUR WORKS", p)
        self.assertIn('"sent_with"', p)


class Scores(unittest.TestCase):
    def test_wilson_and_auc(self):
        self.assertIsNone(E.wilson(0, 0))
        lo, hi = E.wilson(3, 10)
        self.assertTrue(0.1 < lo < 0.3 < hi < 0.61)
        self.assertEqual(E.auc([1, 1], [0, 0]), 1.0)
        self.assertEqual(E.auc([0.5], [0.5]), 0.5)
        self.assertIsNone(E.auc([], [1]))

    def test_confusion_counts_no_reply_apart(self):
        c = E.confusion([(True, True), (False, True), (True, False), (False, False), (True, None)])
        self.assertEqual(c, {"TP": 1, "FP": 1, "FN": 1, "TN": 1, "no reply": 1})

    def test_score_arm_groups_and_bound_issue(self):
        def item(i, group, **kw):
            return {"id": i, "group": group, "cover_text": "Dear X,\nMay 3, 1961\nSincerely", "first_page_text": "Report",
                    "truth": {"year": 1961}, **kw}
        items = [item("o1", "owner", sent_with=True, relation=None), item("o2", "owner", sent_with=True, relation="bound issue"),
                 item("o3", "owner", sent_with=False, relation=None), item("a1", "A"), item("n1", "neg")]
        pred = {i: {"yes": y, "score": float(y), "cue": None, "cue_found": None, "secs": None, "cls": None}
                for i, y in (("o1", True), ("o2", False), ("o3", True), ("a1", True), ("n1", False))}
        r = E.score_arm(items, pred)
        self.assertEqual(r["owner"]["precision"], [1, 2])
        self.assertEqual(r["owner"]["recall"], [1, 2])
        self.assertEqual(r["owner_no_bound"]["recall"], [1, 1])
        self.assertEqual(r["rate"]["A"]["fired"], 1)
        self.assertEqual(r["auc_proxy"], 1.0)
        self.assertEqual(r["propagation"]["pos_year_right"], 3)   # o1, o3 and a1 proposed; the cover prints 1961


@unittest.skipUnless(shutil.which("swiftc"), "needs swiftc")
class AppHelper(unittest.TestCase):
    """The app's own builder and parser, compiled into a scratch directory."""

    def test_build_and_parse(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(E, "HELPER", os.path.join(d, "h")), \
                mock.patch.object(E, "OUT", d):
            built = E.run_helper("build", [{"id": "a", "previous": "Sincerely,\nEnc."}])
            self.assertIn("[enclosure]", built["a"]["prompt"])
            self.assertIn("Sincerely,\nEnc.", built["a"]["prompt"])
            got = E.run_helper("parse", [{"id": "y", "raw": "[document_start] [enclosure]\n[rotate_0]\nREPORT"},
                                         {"id": "n", "raw": "[document_continuation] [enclosure]\n[rotate_0]\nx"},
                                         {"id": "b", "raw": "[document_start]\n[rotate_0]\nSee [enclosure]"}])
            self.assertEqual((got["y"]["enclosure"], got["y"]["classification"]), (True, "document_start"))
            self.assertFalse(got["n"]["enclosure"])
            self.assertFalse(got["b"]["enclosure"])


if __name__ == "__main__":
    unittest.main()
