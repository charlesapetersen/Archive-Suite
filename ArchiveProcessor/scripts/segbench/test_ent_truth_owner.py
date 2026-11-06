#!/usr/bin/env python3
"""Unit tests for the owner's entity fold and the sending-place rule (W46.ent-truth-owner-fold). No model, no corpus."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.chdir(os.path.dirname(os.path.abspath(__file__)))
import ent_truth as E
import ent_truth_owner as O


def ent(name, cls="named", quote=None, **kw):
    return {"name": name, "quote": quote, "class": cls, **kw}


def row(**fields):
    r = {"id": "d1", "is_correspondence": True, **{f: [] for f in E.FIELDS}}
    r.update(fields)
    return r


class PlaceKind(unittest.TestCase):
    def test_classes(self):
        self.assertEqual(E.place_kind(ent("Stanford, California", "correspondence-inferred"), "x"), "inferred")
        self.assertEqual(E.place_kind(ent("Stanford, California", "role-inferred", "STANFORD"), "STANFORD"), "inferred")
        self.assertEqual(E.place_kind(ent("Boston, Massachusetts"), "text"), "read in an image")

    def test_institution_name_is_not_a_place(self):
        t = "STANFORD UNIVERSITY\n\nDear Bob,"
        self.assertEqual(E.place_kind(ent("Stanford, California", quote="STANFORD UNIVERSITY"), t), "institution name")
        t = "Stanford University, Cal.\nMay 3, 1910"
        self.assertNotEqual(E.place_kind(ent("Stanford, California", quote="Stanford University, Cal."), t),
                            "institution name")
        t = "SWARTHMORE COLLEGE\nSWARTHMORE. PENNSYLVANIA\n"
        q = "SWARTHMORE COLLEGE\nSWARTHMORE. PENNSYLVANIA"
        self.assertEqual(E.place_kind(ent("Swarthmore, Pennsylvania", quote=q), t), "heading or address")

    def test_garbled_place_is_still_a_place(self):
        q = "C a m b r id g e 3 8 . Ma s s a c h u s e t t s"
        self.assertEqual(E.place_kind(ent("Cambridge, Massachusetts", quote=q), "HARVARD\n" + q + "\n"),
                         "heading or address")
        q = "EUasblngton, 3 .C ."
        self.assertEqual(E.place_kind(ent("Washington, D.C.", quote=q), q), "heading or address")

    def test_dateline_and_line_above(self):
        self.assertEqual(E.place_kind(ent("Belmont, California", quote="Belmont, Cal."),
                                      "Belmont, Cal., June 4, 1931\nDear Sir"), "dateline")
        self.assertEqual(E.place_kind(ent("Oakland, California", quote="Oakland. Ca. 94621"),
                                      "12 Main St\nOakland. Ca. 94621\nMarch 3, 1970\n"), "line above a date")
        self.assertEqual(E.place_kind(ent("Oakland, California", quote="Oakland. Ca. 94621"),
                                      "ACME\nOakland. Ca. 94621\n\nDear Sir"), "heading or address")


class Rule(unittest.TestCase):
    def test_drops_inferred_and_institution_keeps_written(self):
        r = row(sending_place=[ent("Stanford, California", "correspondence-inferred")])
        out = E.place_rule(r, "")
        self.assertEqual(out["sending_place"], [])
        self.assertEqual(out["place_rule_dropped"], ["Stanford, California"])
        r = row(sending_place=[ent("Stanford, California", quote="STANFORD UNIVERSITY")])
        self.assertEqual(E.place_rule(r, "STANFORD UNIVERSITY\n")["sending_place"], [])
        keep = row(sending_place=[ent("Philadelphia, Pennsylvania", quote="Philadelphia, Pa. 19104")])
        self.assertIs(E.place_rule(keep, "3500 Market St\nPhiladelphia, Pa. 19104\n"), keep)

    def test_owner_checked_place_is_left_alone(self):
        r = row(sending_place=[ent("Stanford, California", "correspondence-inferred")], owner_checked=["sending_place"])
        self.assertIs(E.place_rule(r, ""), r)


class Apply(unittest.TestCase):
    def test_actions(self):
        r = row(sender=[ent("John Pollard")], recipient=[ent("A Committee")],
                sending_place=[ent("Philadelphia, Pennsylvania")])
        corr = {"d1": {"sender": {"action": "set", "value": [ent("J. G. Pollard, Jr.")]},
                       "recipient": {"action": "unscored"},
                       "sending_place": {"action": "confirm", "alternates": ["Philadelphia, PA"]}}}
        out = E.apply_owner(r, corr)
        self.assertEqual(out["sender"][0]["name"], "J. G. Pollard, Jr.")
        self.assertEqual(out["unscored"], ["recipient"])
        self.assertEqual(sorted(out["owner_checked"]), ["sender", "sending_place"])
        self.assertEqual(out["sending_place"][0]["alternates"], ["Philadelphia, PA"])
        self.assertEqual(r["sender"][0]["name"], "John Pollard")          # the input row is not changed
        self.assertIs(E.apply_owner(r, {}), r)

    def test_unscored_field_is_left_out_of_every_count(self):
        t = row(recipient=[ent("Jane Doe")], unscored=["recipient"])
        s = E.score_rows([{"truth": t, "pred": {"recipient": "Somebody Else", "sending_place": "Paris"}, "text": ""}])
        self.assertEqual(s["recipient"]["docs"], 0)
        self.assertEqual(s["recipient"]["ed2"]["fp"], 0)
        self.assertEqual(s["recipient"]["truth_nonempty"], 0)
        self.assertEqual(s["sending_place"]["ed2"]["fp"], 1)            # other fields still scored
        self.assertEqual(s["sending_place"]["filled_when_empty"], 1)


class SameThing(unittest.TestCase):
    def test_place_by_city_names_by_ed2(self):
        self.assertTrue(O.same_thing("sending_place", ["Philadelphia, PA"], ["Philadelphia, Pennsylvania"]))
        self.assertTrue(O.same_thing("sending_place", ["St. Paul"], ["St. Paul, Minnesota"]))
        self.assertFalse(O.same_thing("sender", ["J. G. Pollard, Jr."], ["John Pollard"]))
        self.assertFalse(O.same_thing("recipient", ["Herbert Solomon"], ["Herbert Solomon", "A Committee"]))
        self.assertFalse(O.same_thing("sender", [], []))


if __name__ == "__main__":
    unittest.main()
