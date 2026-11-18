#!/usr/bin/env python3
"""The app's item-field call is the measured one (W47.item-fields-build): ItemFieldExtractor.template is
item_fields_retruth.PROMPT byte for byte, its page caps, image side, text cap, token cap and model are the bench's, its
kinds and the kinds each field fills on are item_fields' KINDS, CORRESP and PUBLISHED.

    python3 -m unittest test_item_fields_app
"""
import os
import re
import unittest

import item_fields as IF
import item_fields_retruth as R

SWIFT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "macOS", "Sources", "ArchiveProcessor",
                     "Tagging", "ItemFieldExtractor.swift")


def swift_source():
    with open(SWIFT, encoding="utf-8") as fh:
        return fh.read()


def swift_template():
    """ItemFieldExtractor.template's literal with Swift's indentation and line-continuation rules applied."""
    src = swift_source()
    body = src[src.index("static let template = \"\"\"\n"):]
    start = body.index('"""\n') + 4
    end = body.index('\n        """', start)
    lines = body[start:end].split("\n")
    assert all(not l or l.startswith("        ") for l in lines)
    text = "\n".join(l[8:] for l in lines).replace("\\\n", "")
    assert "\\" not in text, "an escape this test does not know about"
    return text


def swift_set(name):
    m = re.search(name + r": (?:Set<String>|\[String\]) = \[(.*?)\]", swift_source(), re.S)
    return set(re.findall(r'"([^"]+)"', m.group(1)))


class Prompt(unittest.TestCase):
    def test_template_is_the_measured_prompt(self):
        self.assertEqual(swift_template(), R.PROMPT)

    def test_caps_match(self):
        src = swift_source()
        self.assertIn(f"static let headPages = {R.HEAD_PAGES}", src)
        self.assertIn(f"static let tailPages = {R.TAIL_PAGES}", src)
        self.assertIn(f"static let imageLongSide = {R.SEND_SIDE}", src)
        self.assertIn(f"static let textCap = {R.TEXT_CAP}", src)
        self.assertIn(f"static let maxTokens = {R.MAX_TOKENS}", src)
        self.assertIn("static let gatewayModel = DateRoute.gatewayModel", src)
        self.assertEqual(R.MODELS["gemini"], "gemini-3.7-flash")

    def test_kinds_and_scopes_match(self):
        self.assertEqual(swift_set("kinds"), set(IF.KINDS))
        self.assertEqual(swift_set("correspondence"), IF.CORRESP)
        self.assertEqual(swift_set("published"), IF.PUBLISHED)
        self.assertEqual(IF.SCOPE["byline"], IF.PUBLISHED)
        self.assertEqual(IF.SCOPE["publication_date"], IF.PUBLISHED)
        self.assertEqual(IF.SCOPE["recipient_place"], IF.CORRESP)
        self.assertIsNone(IF.SCOPE["kind"])
        self.assertIsNone(IF.SCOPE["publication"])


if __name__ == "__main__":
    unittest.main()
