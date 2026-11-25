#!/usr/bin/env python3
"""Offline checks of metadata_unified.py: the template's fields and priors, the neighbour split, the reply parser.

    python3 test_metadata_unified.py
"""
import json
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import metadata_unified as M  # noqa: E402


def fake_doc(near, first="f/0010.pdf"):
    return {"id": "x", "pages": [first, "f/0011.pdf"], "near": near}


class Template(unittest.TestCase):
    def test_every_field_is_asked_and_no_prior_phrase(self):
        for f in M.FIELDS:
            self.assertIn(f'"{f}"', M.PROMPT)
        for w in M.PRIORS:
            self.assertNotIn(w, M.PROMPT)

    def test_prompt_renders(self):
        texts = {"f/0007.pdf": "A" * 2000, "f/0009.pdf": "Dear Sir,\nI enclose the report.\nMay 3, 1931\n" + "b" * 2000,
                 "f/0012.pdf": "c"}
        d = fake_doc(["f/0007.pdf", "f/0009.pdf", "f/0012.pdf"])
        with mock.patch.object(M.IR, "page_text", side_effect=lambda p: texts[p]), \
                mock.patch.object(M.IR, "doc_text", return_value="[page 1 of 2]\nhello"):
            p = M.prompt(d)
        self.assertIn("[P2]\n" + "A" * M.NEAR_CHARS + "\n---", p)
        self.assertNotIn("A" * (M.NEAR_CHARS + 1), p)
        self.assertIn("[P1]\nDear Sir,", p)                 # P1 at PREV_CHARS
        self.assertIn('[P1] 1931 ("May 3, 1931")', p)
        self.assertIn("[N1]\nc\n---", p)
        self.assertNotIn("{", p.split("Reply with JSON only")[0])


class Neighbours(unittest.TestCase):
    def test_split_by_folder_order(self):
        d = fake_doc(["f/0007.pdf", "f/0009.pdf", "f/0012.pdf"])
        with mock.patch.object(M.IR, "page_text", side_effect=lambda p: p):
            self.assertEqual([lab for lab, _ in M.neighbours(d)], ["P2", "P1", "N1"])

    def test_no_previous(self):
        d = fake_doc(["f/0012.pdf", "f/0013.pdf"])
        with mock.patch.object(M.IR, "page_text", side_effect=lambda p: p):
            self.assertEqual([lab for lab, _ in M.neighbours(d)], ["N1", "N2"])

    def test_out_of_order_refused(self):
        d = fake_doc(["f/0012.pdf", "f/0007.pdf"])
        with mock.patch.object(M.IR, "page_text", side_effect=lambda p: p):
            self.assertRaises(ValueError, M.neighbours, d)


class Parse(unittest.TestCase):
    def test_full_reply_in_fence_with_thinking(self):
        js = {"kind": "letter", "title": None, "byline": [], "sender": [{"name": "A B", "quote": "A. B."}],
              "date": {"year": 1931, "month": None}, "enclosure": {"announces": True}}
        r = M.parse("<think>hm</think>```json\n" + json.dumps(js) + "\n```")
        self.assertEqual(r["kind"], "letter")
        self.assertEqual(r["recipient"], [])
        self.assertEqual(r["date"]["year"], 1931)
        self.assertIsNone(r["publication"])

    def test_bad_replies(self):
        self.assertIsNone(M.parse(""))
        self.assertIsNone(M.parse("no json"))
        self.assertIsNone(M.parse('{"foo": 1}'))
        self.assertIsNone(M.parse('{"kind": '))

    def test_coercions(self):
        r = M.parse('{"kind": "poem", "byline": "X", "date": 1931}')
        self.assertEqual(r["kind"], "other")
        self.assertEqual(r["byline"], [])
        self.assertIsNone(r["date"])

    def test_quote_found(self):
        self.assertTrue(M.quote_found("John  Smith", "Yours,\nJohn Smith"))
        self.assertFalse(M.quote_found("Jon Smith", "John Smith"))
        self.assertFalse(M.quote_found(None, "x"))


if __name__ == "__main__":
    unittest.main()
