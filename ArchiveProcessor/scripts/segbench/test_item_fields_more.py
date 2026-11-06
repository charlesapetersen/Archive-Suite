#!/usr/bin/env python3
"""Tests for item_fields_more.py (W47.item-fields-more-checks): the draw and the not-asked line. No cache needed."""
import os
import random
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import item_fields_more as M  # noqa: E402

FIELDS = M.IS.FIELDS


def frow(i, kind="letter", owner=None, unknown=(), **label):
    lab = {f: None for f in FIELDS}
    lab.update(kind=kind, **label)
    return {"id": i, "part": "base", "label": lab, "owner": owner or {}, "unknown": list(unknown)}


def pred(**v):
    p = {f: None for f in FIELDS}
    p.update(v)
    return p


class Eligible(unittest.TestCase):
    def test_scope_owner_unknown_and_skip(self):
        rows = [frow("a", kind="letter", owner={"kind": "kind"}, recipient_place=["Paris"]),
                frow("b", kind="newspaper article", unknown=["byline"], title="T"),
                frow("c", kind="memo"), frow("d")]
        P = {"a": pred(kind="letter", recipient_place=["Paris"]), "b": pred(kind="newspaper article", title="T"),
             "c": pred(kind="memo"), "d": pred(kind="letter")}
        got = M.eligible(rows, P, skip={"d"})
        self.assertEqual(got["kind"]["filled"], ["b", "c"])          # a's kind settled by the owner, d skipped
        self.assertEqual(got["recipient_place"]["filled"], ["a"])
        self.assertIn("c", got["recipient_place"]["empty"])
        self.assertNotIn("b", got["recipient_place"]["empty"])        # out of scope for an article
        self.assertNotIn("b", got["byline"]["empty"] + got["byline"]["filled"])   # unknown
        self.assertNotIn("a", got["byline"]["empty"])                 # a letter has no byline
        self.assertEqual(got["title"]["filled"], ["b"])

    def test_no_reply_is_not_eligible(self):
        got = M.eligible([frow("a")], {"a": None}, set())
        self.assertFalse(any(v["filled"] or v["empty"] for v in got.values()))


class Draw(unittest.TestCase):
    def pools(self):
        ids = [f"d{i:02d}" for i in range(60)]
        return {f: {"filled": ids[:50], "empty": ids[50:] if f != "kind" else []} for f in FIELDS}

    def test_counts_from_the_floor(self):
        have = {"kind": 38, "title": 20, "byline": 40, "publication": 45, "publication_date": 0,
                "recipient_place": 39}
        picks = M.draw(self.pools(), have, random.Random(1), floor=40, share=0.8, empty=10)
        n = lambda f, w: sum(1 for _d, g, x in picks if g == f and x == w)  # noqa: E731
        self.assertEqual(n("kind", "filled"), 3)          # ceil(2 / 0.8)
        self.assertEqual(n("title", "filled"), 25)
        self.assertEqual(n("byline", "filled"), 0)        # at the floor already
        self.assertEqual(n("publication_date", "filled"), 50)   # wants 50, has 50
        self.assertEqual(n("recipient_place", "filled"), 2)
        self.assertEqual(n("kind", "empty"), 0)
        self.assertEqual(n("title", "empty"), 10)
        self.assertEqual(len(set(picks)), len(picks))

    def test_seeded_and_one_order_shared_by_the_fields(self):
        have = {f: 30 for f in FIELDS}
        a = M.draw(self.pools(), have, random.Random(7))
        self.assertEqual(a, M.draw(self.pools(), have, random.Random(7)))
        self.assertNotEqual(a, M.draw(self.pools(), have, random.Random(8)))
        docs = {f: {d for d, g, w in a if g == f and w == "filled"} for f in FIELDS}
        self.assertEqual(docs["title"], docs["byline"])   # same pool, same order: the same documents

    def test_first_in_the_shuffle_within_each_pool(self):
        pools = {f: {"filled": [], "empty": []} for f in FIELDS}
        pools["title"]["filled"] = ["a", "b", "c", "d"]
        pools["byline"]["filled"] = ["c", "d"]
        picks = M.draw(pools, {f: 40 for f in FIELDS} | {"title": 39, "byline": 39}, random.Random(3),
                       share=1.0, empty=0)
        order = ["a", "b", "c", "d"]
        random.Random(3).shuffle(order)
        self.assertEqual([d for d, g, _ in picks if g == "title"], order[:1])
        self.assertEqual([d for d, g, _ in picks if g == "byline"], [x for x in order if x in "cd"][:1])


    def test_a_one_field_draw_continues_the_full_draw(self):
        """The third sheet: a longer draw of one field, ordered over every field's pools, starts with the full
        draw's picks for that field, so the two together are the first of one uniform draw."""
        pools = self.pools()
        have = {f: 30 for f in FIELDS}
        full = [d for d, g, w in M.draw(pools, have, random.Random(5)) if g == "title" and w == "filled"]
        longer = M.draw({"title": pools["title"]}, {}, random.Random(5), floor=len(full) + 4, share=1, empty=0,
                        fields=["title"], order_from=pools)
        ext = [d for d, _g, _w in longer]
        self.assertEqual(ext[:len(full)], full)
        self.assertEqual(len(ext), len(full) + 4)

class NotAsked(unittest.TestCase):
    def test_every_truth_listed_and_checked_marked(self):
        t = frow("a", kind="letter", owner={"kind": "kind"}, recipient_place=["Paris"], byline=["out of scope for a letter"])
        ent = {"is_correspondence": True, "sender": [{"name": "A. Smith"}], "recipient": [], "sending_place": None}
        got = dict(M.not_asked(t, {"recipient_place"}, ent, (1962, 5, "x")))
        self.assertEqual(got["kind"], "letter (you checked it on the first sheet)")
        self.assertNotIn("recipient_place", got)          # asked
        self.assertNotIn("byline", got)                    # out of scope for a letter
        self.assertEqual(got["sender"], "A. Smith")
        self.assertEqual(got["recipient"], "none given")
        self.assertEqual(got["sending_place"], "none given")
        self.assertEqual(got[M.DATE_NAME], "1962-05")

    def test_no_entity_for_a_printed_piece_and_year_only_tag(self):
        t = frow("a", kind="newspaper article", unknown=["publication"], publication="P", title="T")
        got = dict(M.not_asked(t, set(), {"is_correspondence": False, "sender": [{"name": "X"}]}, (1970, None, "y")))
        self.assertEqual(got, {"kind": "newspaper article", "title": "T", M.DATE_NAME: "1970"})


if __name__ == "__main__":
    unittest.main()
