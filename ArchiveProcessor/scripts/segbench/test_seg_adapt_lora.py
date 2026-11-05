"""W46.seg-adapt-lora: a corrected target changes only the wrong decisions and refuses a reply it cannot correct."""
import json
import unittest

import seg_adapt_lora as L

REPLY = {"pages": [{"page": 4, "kind": "document"}, {"page": 5, "kind": "document"}, {"page": 6, "kind": "document"}],
         "boundaries": [{"between": [4, 5], "decision": "new", "cue": "Signature then a new heading", "confidence": 0.9},
                        {"between": [5, 6], "decision": "continue", "cue": "Text flows", "confidence": 0.99}]}
LABELS = ["New", "Cont", "Cont", "Cont", "Cont", "New"]          # truth: 4|5 continue, 5|6 new


class Corrected(unittest.TestCase):
    def test_flips_only_wrong_decisions(self):
        text, flips = L.corrected(json.dumps(REPLY), [4, 5, 6], LABELS)
        got = json.loads(text)
        self.assertEqual(flips, 2)
        self.assertEqual([b["decision"] for b in got["boundaries"]], ["continue", "new"])
        self.assertTrue(all(b["cue"] == "corrected by the reviewer" and b["confidence"] == 0.95
                            for b in got["boundaries"]))
        self.assertEqual(got["pages"], REPLY["pages"])

    def test_agreeing_reply_unchanged(self):
        labels = ["New", "Cont", "Cont", "New", "New", "Cont"]       # 4|5 new, 5|6 continue
        text, flips = L.corrected(json.dumps(REPLY), [4, 5, 6], labels)
        self.assertEqual(flips, 0)
        self.assertEqual(json.loads(text), REPLY)

    def test_layout_matches_the_2b(self):
        text, _ = L.corrected(json.dumps(REPLY), [4, 5, 6], ["New", "Cont", "Cont", "New", "New", "Cont"])
        self.assertTrue(text.startswith('{\n"pages": [\n{"page": 4, "kind": "document"},\n'))
        self.assertTrue(text.endswith('"confidence": 0.99}\n]\n}'))

    def test_unusable_replies_refused(self):
        missing = {**REPLY, "boundaries": REPLY["boundaries"][:1]}
        foreign = {**REPLY, "boundaries": [*REPLY["boundaries"], {"between": [6, 7], "decision": "new"}]}
        odd = {**REPLY, "boundaries": [{**REPLY["boundaries"][0], "decision": "maybe"}, REPLY["boundaries"][1]]}
        for bad in ("not json", json.dumps([1]), json.dumps(missing), json.dumps(foreign), json.dumps(odd)):
            self.assertIsNone(L.corrected(bad, [4, 5, 6], LABELS))


if __name__ == "__main__":
    unittest.main()
