#!/usr/bin/env python3
"""The place rule W46.ent-place-rule-paid measured is the one the app's tagging prompt ships, and the earlier arms'
prompts are still the ones their cached replies answered.

    python3 -m unittest test_ent_place_rule
"""
import unittest

import date_tagging as DT
import ent_place_rule as R
import ent_prompt_app as EPA
import ent_score_paid as P

TEXT, CONTEXT = "Dear Sir,\nThank you for your letter.", "an earlier letter"


class PlaceRule(unittest.TestCase):
    def test_measured_rule_is_shipped(self):
        self.assertIn("\n" + R.TAGGING_PLACE + "\n", DT.PROMPT)

    def test_measured_prompt_is_the_apps(self):
        app = DT.build_prompt(TEXT, CONTEXT)
        before = P.with_rules(app, {"author_location": EPA.AUTHOR_LOCATION_BEFORE})
        self.assertEqual(P.with_rules(before, {"author_location": R.TAGGING_PLACE}), app)

    def test_earlier_prompts_pinned(self):
        before = P.with_rules(DT.build_prompt(TEXT, CONTEXT), {"author_location": EPA.AUTHOR_LOCATION_BEFORE})
        self.assertNotIn("Only a place the document writes", before)
        self.assertIn(EPA.AUTHOR_LOCATION_BEFORE + "\n", before)
        old = P.tagging_prompt_before(TEXT, CONTEXT)
        self.assertIn(P.TAGGING_RULES_BEFORE["author_location"] + "\n", old)
        self.assertNotIn("Only a place the document writes", old)

    def test_entity_prompt_unchanged(self):
        self.assertNotIn("Only a place the document writes", P.ENTITY_PROMPT)
        self.assertEqual(P.with_rules(P.ENTITY_PROMPT.format(text=TEXT), {"sending_place": R.ENTITY_PLACE}).count(
            "Only a place the document writes"), 1)


if __name__ == "__main__":
    unittest.main()
