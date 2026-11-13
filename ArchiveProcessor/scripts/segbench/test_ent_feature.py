#!/usr/bin/env python3
"""ent_feature.py measures what the app sends and keeps: EntityExtractor.prompt is its prompt, EntityExtractor.evidence
gives its verdict on the shared cases (fixtures/ent-evidence-cases.json, which EntityFeatureTestDriver also runs), and
the correspondence gate names the same formats.

    python3 -m unittest test_ent_feature
"""
import json
import os
import re
import unittest

import ent_feature as F
import ent_place_rule as R
import ent_score_paid as P

CASES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "ent-evidence-cases.json")


def swift_source():
    with open(F.SWIFT, encoding="utf-8") as fh:
        return fh.read()


def swift_prompt():
    """EntityExtractor.prompt(text:)'s literal with Swift's indentation rule applied, {text} for its interpolation."""
    src = swift_source()
    body = src[src.index("static func prompt(text: String) -> String {"):]
    start = body.index('"""\n') + 4
    end = body.index('\n        """', start)
    lines = body[start:end].split("\n")
    assert all(not l or l.startswith("        ") for l in lines)
    text = "\n".join(l[8:] for l in lines).replace(r"\(sent(text))", "{text}", 1)
    assert "\\(" not in text, "an interpolation this test does not know about"
    return text


class Prompt(unittest.TestCase):
    def test_template_matches_swift(self):
        self.assertEqual(F.TEMPLATE.replace("{{", "{").replace("}}", "}"), swift_prompt())

    def test_is_the_measured_entity3k_place_prompt(self):
        text = "Dear Sir,\nThank you.\nYours, A. Green"
        self.assertEqual(F.prompt(text), P.with_rules(P.ENTITY_PROMPT.format(text=text), {"sending_place": R.ENTITY_PLACE}))
        self.assertEqual(F.prompt("a" * 3100), F.TEMPLATE.format(text="a" * 3000))
        self.assertNotIn("Nearby documents", F.prompt(text))

    def test_caps_match_swift(self):
        src = swift_source()
        self.assertIn(f"static let textCap = {F.TEXT_CAP}", src)
        self.assertIn(f"static let nearLetters = {F.NEAR_LETTERS}", src)
        self.assertIn(f"static let nearDistance = {F.NEAR_DISTANCE}", src)

    def test_correspondence_formats_match_swift(self):
        src = swift_source()
        m = re.search(r"correspondenceFormats: Set<String> = \[(.*?)\]", src, re.S)
        self.assertEqual(set(re.findall(r'"([^"]+)"', m.group(1))), set(F.CORRESPONDENCE))


class Evidence(unittest.TestCase):
    def test_shared_cases(self):
        cases = json.load(open(CASES, encoding="utf-8"))
        self.assertGreaterEqual(len(cases), 10)
        for c in cases:
            text = "x" * c.get("pad", 0) + c["text"]
            ev, d, why = F.evidence(c["quote"], text)
            with self.subTest(c["id"]):
                self.assertEqual(ev, c["evidence"])
                if ev == "quoted":
                    self.assertEqual(d, c["distance"])
                else:
                    self.assertEqual(why, c["why"])

    def test_confidence(self):
        self.assertEqual(F.confidence("quoted", 0), "high")
        self.assertEqual(F.confidence("quoted", 2), "medium")
        self.assertEqual(F.confidence("inferred", None), "low")


class Names(unittest.TestCase):
    def test_shapes(self):
        self.assertEqual(F.names(None), [])
        self.assertEqual(F.names("Boston, Massachusetts"), [{"name": "Boston, Massachusetts", "quote": None}])
        got = F.names([{"name": "Charles Brown", "quote": "Dr. Brown"}, {"name": "Unknown", "quote": None},
                       {"name": "charles  brown", "quote": "Brown"}, "Edith Black", 3])
        self.assertEqual([e["name"] for e in got], ["Charles Brown", "Edith Black"])


class InsideAddress(unittest.TestCase):
    def test_place_in_the_address_block(self):
        t = "Mr. John Doe\n12 Elm Street\nSalem, Mass.\n\nDear Mr. Doe,\nThank you.\nBoston, Mass."
        self.assertTrue(F.inside_address(t, "Salem, Mass.", ["John Doe"]))
        self.assertFalse(F.inside_address("BOSTON, MASS.\nMr. John Doe\nDear Mr. Doe,", "BOSTON, MASS.", ["John Doe"]))


if __name__ == "__main__":
    unittest.main()
