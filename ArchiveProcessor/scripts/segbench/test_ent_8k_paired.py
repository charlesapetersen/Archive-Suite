#!/usr/bin/env python3
"""Unit tests for ent_8k_paired.py (no cache, no network): python3 test_ent_8k_paired.py"""
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ent_8k_paired as E  # noqa: E402
import ent_feature as F  # noqa: E402


class Prompts(unittest.TestCase):
    def prompt(self, label, text):
        with mock.patch.object(E.P, "vision_text", return_value=text):
            return E.prompt_for(label, {"id": "d"})

    def test_shipped_is_the_feature_prompt(self):
        t = "x" * 5000
        self.assertEqual(self.prompt("shipped", t), F.prompt(t))
        self.assertEqual(self.prompt("shipped-b", t), F.prompt(t))

    def test_8k_differs_only_past_3000(self):
        short, long_ = "Dear Sir, " * 100, "Dear Sir, " * 700
        self.assertEqual(self.prompt("8k", short), self.prompt("shipped", short))
        self.assertNotEqual(self.prompt("8k", long_), self.prompt("shipped", long_))
        self.assertEqual(self.prompt("8k", long_), F.TEMPLATE.format(text=long_[:8000]))


class Cost(unittest.TestCase):
    def test_thinking_billed_as_output(self):
        u = {"promptTokenCount": 1_000_000, "candidatesTokenCount": 500_000, "thoughtsTokenCount": 500_000}
        pin, pout = E.price()
        self.assertAlmostEqual(E.cost(u), pin + pout)

    def test_caps_refuse_before_the_call(self):
        with mock.patch.object(E, "spent", return_value=E.CAP), mock.patch.object(E, "request") as req, \
                mock.patch.object(E.os.path, "exists", return_value=False):
            with self.assertRaises(E.Stop):
                E.call("shipped", "d", "p")
            req.assert_not_called()
        with mock.patch.object(E, "spent", return_value=0), mock.patch.object(E, "key_spent", return_value=E.KEY_TOTAL), \
                mock.patch.object(E, "request") as req, mock.patch.object(E.os.path, "exists", return_value=False):
            with self.assertRaises(E.Stop):
                E.call("shipped", "d", "p")
            req.assert_not_called()


if __name__ == "__main__":
    unittest.main()
