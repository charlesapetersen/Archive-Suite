#!/usr/bin/env python3
"""The app's tagging prompt is back to its pre-November name rules (W46.tagging-prompt-revert, owner call 10), and the
arms that measured the November rules still send the prompts their cached replies answered.

    python3 -m unittest test_ent_place_rule
"""
import unittest

import date_tagging as DT
import ent_place_rule as R
import ent_prompt_app as EPA
import ent_score_paid as P

TEXT, CONTEXT = "Dear Sir,\nThank you for your letter.", "an earlier letter"


class PlaceRule(unittest.TestCase):
    def test_app_prompt_reverted(self):
        for line in P.TAGGING_RULES_BEFORE.values():
            self.assertIn("\n" + line + "\n", DT.PROMPT)
        self.assertNotIn("Only a place the document writes", DT.PROMPT)
        self.assertNotIn("Always a person", DT.PROMPT)
        self.assertEqual(P.tagging_prompt_before(TEXT, CONTEXT), DT.build_prompt(TEXT, CONTEXT, ocr_poor=False))
        self.assertIn(DT.OCR_POOR_RULE, DT.build_prompt(TEXT, CONTEXT))

    def test_earlier_prompts_pinned(self):
        new = P.with_rules(DT.build_prompt(TEXT, CONTEXT, ocr_poor=False), EPA.NEW_RULES)
        self.assertNotIn("OCR Poor", new)
        for line in EPA.NEW_RULES.values():
            self.assertIn(line + "\n", new)
        self.assertIn("Always a person", new)
        self.assertNotIn("Only a place the document writes", new)
        place = P.with_rules(new, {"author_location": R.TAGGING_PLACE})
        self.assertIn(R.TAGGING_PLACE + "\n", place)
        self.assertEqual(place.count("Only a place the document writes"), 1)

    def test_entity_prompt_unchanged(self):
        self.assertNotIn("Only a place the document writes", P.ENTITY_PROMPT)
        self.assertEqual(P.with_rules(P.ENTITY_PROMPT.format(text=TEXT), {"sending_place": R.ENTITY_PLACE}).count(
            "Only a place the document writes"), 1)


if __name__ == "__main__":
    unittest.main()
