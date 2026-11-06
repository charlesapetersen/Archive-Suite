#!/usr/bin/env python3
"""Tests for ent_place_sheet.py (W46.place-rule-sheet): the pools, the draw and the fallback. No cache needed."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ent_place_sheet as S  # noqa: E402

HEAD = "SECURITIES AND EXCHANGE COMMISSION\nWASHINGTON, D.C. 20549\n\nDear Sir:\nWe write about it."


def place(name, quote=None, cls="named"):
    return {"name": name, "quote": quote, "class": cls}


def row(i, places, **kw):
    return {"id": i, "sending_place": places, **kw}


class Pools(unittest.TestCase):
    def test_kept_emptied_and_owner_settled(self):
        wash, stan = place("Washington, D.C.", "WASHINGTON, D.C."), place("Stanford, California", cls="correspondence-inferred")
        rows = [row("a", [wash]), row("b", [], place_rule_dropped=["Stanford, California"]),
                row("c", [wash], owner_checked=["sending_place"]), row("d", [], unscored=["sending_place"])]
        before = [row("a", [wash]), row("b", [stan]), row("c", [wash]), row("d", [stan])]
        p = S.pools(rows, before, {i: HEAD for i in "abcd"})
        self.assertEqual(p["kept"], {"a": wash})
        self.assertEqual(p["emptied"], {"b": stan})

    def test_a_dateline_place_is_not_kept_class(self):
        dl = place("Washington, D.C.", "WASHINGTON, D.C.")
        p = S.pools([row("a", [dl])], [row("a", [dl])], {"a": "WASHINGTON, D.C. March 26, 1965\nDear Sir:"})
        self.assertEqual(p["kept"], {})


class Draw(unittest.TestCase):
    def pools(self):
        return {"kept": {f"k{i:02d}": {} for i in range(49)} | {"x": {}},
                "emptied": {f"e{i:02d}": {} for i in range(26)} | {"x": {}}}

    def test_counts_seeded_and_no_document_twice(self):
        got = S.draw(self.pools())
        self.assertEqual(sum(c == "kept" for _d, c in got), S.KEPT_N)
        self.assertEqual(sum(c == "emptied" for _d, c in got), S.EMPTIED_N)
        self.assertEqual(len({d for d, _c in got}), len(got))
        self.assertNotIn(("x", "kept"), got)
        self.assertEqual(got, S.draw(self.pools()))
        self.assertNotEqual(got, S.draw(self.pools(), seed=S.SEED + 1))


class Where(unittest.TestCase):
    def test_fallback(self):
        self.assertIn("not found", S.where(place("Vermont"), HEAD))
        self.assertIn("near the start", S.where(place("Washington, D.C.", "WASHINGTON, D.C."), HEAD + " body" * 100))
        self.assertIn("50%", S.where(place("Reno", "RENO"), "x" * 50 + "RENO" + "x" * 46))


class NotAsked(unittest.TestCase):
    def test_the_place_is_left_out_and_the_hint_first(self):
        t = {"id": "a", "label": {f: None for f in S.IS.FIELDS} | {"kind": "letter"}, "owner": {}, "unknown": []}
        ent = {"is_correspondence": True, "sender": [place("Ann Lee")], "recipient": [], "sending_place": [place("Rome")]}
        got = S.not_asked(t, ent, (1965, 3, None), hint="no box: x")
        names = [x[0] for x in got]
        self.assertEqual(names[0], "where the place stands")
        self.assertNotIn("sending_place", names)
        self.assertIn("sender", names)
        self.assertIn(S.IM.DATE_NAME, names)


if __name__ == "__main__":
    unittest.main()
