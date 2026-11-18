#!/usr/bin/env python3
"""The inference prompt is the shipped item-field prompt with one rule changed (W47.item-fields-inference), and its
marked values are read and left out the way the score says.

    python3 -m unittest test_item_fields_infer
"""
import json
import unittest

import item_fields_infer as X
import item_fields_retruth as R


class Prompt(unittest.TestCase):
    def test_one_rule_and_one_key_changed(self):
        self.assertEqual(R.PROMPT.count(X.SHIPPED_LINE), 1)
        self.assertEqual(R.PROMPT.count(X.SHIPPED_KEYS), 1)
        self.assertNotIn(X.SHIPPED_LINE, X.INFER_PROMPT)
        back = X.INFER_PROMPT.replace(X.INFER_LINE, X.SHIPPED_LINE).replace(X.INFER_KEYS, X.SHIPPED_KEYS)
        self.assertEqual(back, R.PROMPT)

    def test_no_set_document_in_the_examples(self):
        for words in ("M.Y.", "Lyman", "P.A.T.", "University Hall", "Riesman"):
            self.assertNotIn(words, X.INFER_PROMPT)

    def test_text_goes_in(self):
        self.assertEqual(X.INFER_PROMPT.count("{text}"), 1)


class Marks(unittest.TestCase):
    def reply(self, **kw):
        base = {"kind": "newsletter", "title": "Notes", "byline": ["Jane Kay"], "publication": "Town Times",
                "publication_date": "1970", "recipient_place": [], "quotes": {}, "inferred": {"byline": "J.K."}}
        base.update(kw)
        return json.dumps(base)

    def test_marked_field_read(self):
        r, m = X.parse(self.reply())
        self.assertEqual(m, {"byline": "J.K."})
        self.assertEqual(r["byline"], ["Jane Kay"])

    def test_mark_on_an_empty_or_unknown_field_is_dropped(self):
        _r, m = X.parse(self.reply(inferred={"recipient_place": "Main St", "sender": "x", "title": ""}))
        self.assertEqual(m, {})

    def test_mark_on_a_field_the_definitions_empty_is_dropped(self):
        _r, m = X.parse(self.reply(kind="letter", inferred={"byline": "J.K."}))
        self.assertEqual(m, {})

    def test_no_inferred_key(self):
        r, m = X.parse(json.dumps({"kind": "report", "title": "T", "byline": [], "publication": None,
                                   "publication_date": None, "recipient_place": []}))
        self.assertIsNotNone(r)
        self.assertEqual(m, {})

    def test_unparsable(self):
        self.assertEqual(X.parse("no json"), (None, {}))


if __name__ == "__main__":
    unittest.main()
