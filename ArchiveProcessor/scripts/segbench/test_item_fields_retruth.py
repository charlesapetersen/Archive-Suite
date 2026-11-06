"""item_fields_retruth.py: the page cap, the draw, the sheet's quotas and boxes, the ruling's sides, W46's kind
rule, and the reply cache's refusal of a changed request. No gateway, corpus or cache is touched."""
import json
import os
import random
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import item_fields_retruth as R  # noqa: E402


def reading(**kw):
    r = {"kind": None, "title": None, "byline": [], "publication": None, "publication_date": None,
         "recipient_place": []}
    r.update(kw)
    return r


class Cap(unittest.TestCase):
    def test_first_eight_and_last_two(self):
        self.assertEqual(R.capped(list(range(10))), list(range(10)))
        self.assertEqual(R.capped(list(range(14))), list(range(8)) + [12, 13])


class Draw(unittest.TestCase):
    def test_round_robin_over_collections(self):
        pool = [{"id": f"{c}{i}", "collection": c} for c in "abc" for i in range(5)]
        got = R.draw(pool, 6, random.Random(1))
        self.assertEqual(len(got), 6)
        self.assertEqual(sorted(collections_of(got).values()), [2, 2, 2])

    def test_draw_is_seeded(self):
        pool = [{"id": f"{c}{i}", "collection": c} for c in "ab" for i in range(9)]
        self.assertEqual(R.draw(pool, 5, random.Random(3)), R.draw(pool, 5, random.Random(3)))


def collections_of(docs):
    out = {}
    for d in docs:
        out[d["collection"]] = out.get(d["collection"], 0) + 1
    return out


class Quotas(unittest.TestCase):
    def test_floor_then_weight_near_the_bar(self):
        avail = {"kind": 50, "title": 50, "byline": 50, "publication": 50, "recipient_place": 3}
        prec = {"kind": 0.88, "title": 0.40, "byline": 0.6, "publication": 0.5, "recipient_place": 0.5}
        q = R.quotas(avail, prec)
        self.assertEqual(q["recipient_place"], 3)        # all there are
        self.assertEqual(q["kind"], R.MAX_PER_FIELD)     # nearest the bar, up to the ceiling
        self.assertGreaterEqual(q["byline"], q["title"])
        self.assertGreaterEqual(q["title"], R.MIN_PER_FIELD)
        self.assertEqual(sum(q.values()), min(R.SHEET_DISPUTES, 4 * R.MAX_PER_FIELD + 3))   # the ceilings bind

    def test_no_precision_takes_the_mean_weight(self):
        old, R.SHEET_DISPUTES = R.SHEET_DISPUTES, 40     # under the ceilings, so the weights show
        try:
            q = R.quotas({"kind": 50, "title": 50, "byline": 50}, {"kind": 0.30, "title": None, "byline": 0.89})
        finally:
            R.SHEET_DISPUTES = old
        self.assertGreater(q["title"], q["kind"])
        self.assertGreater(q["byline"], q["title"])

    def test_never_more_than_available(self):
        q = R.quotas({"kind": 5, "title": 4}, {"kind": 0.9, "title": 0.9})
        self.assertEqual(q, {"kind": 5, "title": 4})


class Sides(unittest.TestCase):
    def test_sides(self):
        a, b = reading(kind="letter", title=None), reading(kind="memo", title="Budget")
        dis = ["kind", "title"]
        self.assertEqual(R.side(dis, dict(a), a, b), "gemini")
        self.assertEqual(R.side(dis, dict(b), a, b), "luna")
        self.assertEqual(R.side(dis, reading(kind="letter", title="Budget"), a, b), "mixed")
        self.assertEqual(R.side(dis, reading(kind="report", title="Other"), a, b), "neither")


class W46Kind(unittest.TestCase):
    def test_kind_on_the_right_side_is_kept(self):
        self.assertEqual(R.w46_kind(reading(kind="memo"), None, None, True), ("memo", None))
        self.assertEqual(R.w46_kind(reading(kind="report"), None, None, False), ("report", None))

    def test_a_reader_on_the_right_side_first(self):
        got = R.w46_kind(reading(kind="report"), reading(kind="report"), reading(kind="telegram"), True)
        self.assertEqual(got, ("telegram", "reader"))

    def test_default_when_no_reader_is(self):
        self.assertEqual(R.w46_kind(reading(kind="letter"), reading(kind="memo"), reading(kind="letter"), False),
                         ("other", "default"))
        self.assertEqual(R.w46_kind(reading(kind="report"), reading(kind="report"), None, True),
                         ("letter", "default"))


class TruthOf(unittest.TestCase):
    """The label: definitions applied to the assembled label, the W46 kind rule, quotes from the reading taken."""

    def setUp(self):
        self._r = R.reading
        self.docs = {}
        R.reading = lambda stage, doc_id: self.docs.get((stage, doc_id))

    def tearDown(self):
        R.reading = self._r

    def put(self, doc_id, a, b, ruling=None):
        self.docs[("drafts/gemini", doc_id)] = a
        self.docs[("drafts/luna", doc_id)] = b
        if ruling:
            self.docs[("adjudicated", doc_id)] = ruling

    def test_a_ruled_memo_drops_the_agreed_byline(self):
        a = reading(kind="report", byline=["Ford Foundation"], quotes={"byline": "FORD FOUNDATION"})
        b = reading(kind="press release", byline=["Ford Foundation"])
        self.put("x", a, b, reading(kind="memo", byline=["Ford Foundation"]))
        t, how, det = R.truth_of({"id": "x", "set": "clippings", "group": "clippings"})
        self.assertEqual((how, det["disputed"], t["kind"], t["byline"]), ("ruled", ["kind"], "memo", []))
        self.assertNotIn("byline", t["quotes"])

    def test_the_rulings_publication_kept_on_an_agreed_article(self):
        a = reading(kind="newspaper article", publication="The Times")
        b = reading(kind="newspaper article", publication="Sunday Magazine")
        self.put("y", a, b, reading(kind="letter", publication="The Times", quotes={"publication": "THE TIMES"}))
        t, _how, _det = R.truth_of({"id": "y", "set": "clippings", "group": "clippings"})
        self.assertEqual((t["kind"], t["publication"]), ("newspaper article", "The Times"))
        self.assertEqual(t["quotes"]["publication"], "THE TIMES")

    def test_a_disputed_field_keeps_the_matched_readers_quote(self):
        a = reading(kind="clipping", title="Tax Cut", quotes={"title": "TAX CUT"})
        b = reading(kind="clipping", title="Kennedy Plan", quotes={"title": "KENNEDY PLAN"})
        self.put("z", a, b, reading(kind="clipping", title="Kennedy Plan"))
        t, _how, det = R.truth_of({"id": "z", "set": "clippings", "group": "clippings"})
        self.assertEqual((t["title"], det["field_sides"]["title"]), ("Kennedy Plan", "luna"))
        self.assertEqual(t["quotes"]["title"], "KENNEDY PLAN")

    def test_w46_kind_from_a_reader_brings_its_fields(self):
        a = reading(kind="letter", title="Dear Sir")
        b = reading(kind="report", title="Annual Report", byline=["Ford Foundation"])
        self.put("w", a, b, reading(kind="letter"))
        t, _how, det = R.truth_of({"id": "w", "set": "ent-added", "group": "ent-other"})
        self.assertEqual((t["kind"], t["title"], t["byline"]), ("report", "Annual Report", ["Ford Foundation"]))
        self.assertEqual(det["kind_from"], "w46 reader")
        self.assertNotIn("unknown_fields", det)

    def test_w46_default_kind_marks_its_fields_unknown(self):
        a, b = reading(kind="letter"), reading(kind="memo", title="Budget")
        self.put("v", a, b, reading(kind="letter", title=None))
        t, _how, det = R.truth_of({"id": "v", "set": "ent-added", "group": "ent-other"})
        self.assertEqual((t["kind"], det["kind_from"]), ("other", "w46 default"))
        self.assertEqual(det["unknown_fields"], list(R.DEFINED))


class Locate(unittest.TestCase):
    def setUp(self):
        self.lines = {"p1": [{"text": "THE NEW YORK TIMES, SUNDAY, MARCH 3, 1962", "box": [0.1, 0.05, 0.8, 0.02]},
                             {"text": "Kennedy Asks Tax Cut", "box": [0.2, 0.10, 0.5, 0.04]},
                             {"text": "for the Nation", "box": [0.2, 0.15, 0.3, 0.03]}],
                      "p2": [{"text": "unrelated words only", "box": [0.1, 0.5, 0.3, 0.02]}]}
        self._pl = R.page_lines
        R.page_lines = lambda p: self.lines.get(p)

    def tearDown(self):
        R.page_lines = self._pl

    def test_quote_found_on_its_line(self):
        got = R.locate({"pages": ["p1", "p2"]}, "The New York Times", "THE NEW YORK TIMES")
        self.assertEqual(got, [(0, [0.1, 0.05, 0.8, 0.02])])

    def test_two_line_span(self):
        got = R.locate({"pages": ["p2", "p1"]}, "Kennedy Asks Tax Cut for the Nation", None)
        self.assertEqual(got[0][0], 1)
        self.assertEqual(got[0][1], [0.2, 0.1, 0.5, 0.08])

    def test_nothing_when_not_there(self):
        self.assertEqual(R.locate({"pages": ["p1"]}, "Chicago Tribune", None), [])


class Shown(unittest.TestCase):
    def test_values(self):
        self.assertEqual(R.shown("publication_date", (1962, 3, None)), "1962-03")
        self.assertEqual(R.shown("byline", ["A B", "C D"]), "A B; C D")
        self.assertEqual(R.shown("title", None), "")


class Cache(unittest.TestCase):
    def test_a_changed_request_is_refused(self):
        with tempfile.TemporaryDirectory() as t:
            dest = os.path.join(t, "x.json")
            _b, settings, digest = R.request_of("gemini-3.7-flash", [], "prompt", None)
            with open(dest, "w") as fh:
                json.dump({"meta": {"content_sha256": digest, "request": settings}, "raw": "{}"}, fh)
            self.assertEqual(R.cached(dest, settings, digest)["raw"], "{}")
            _b, s2, d2 = R.request_of("gemini-3.7-flash", [], "prompt changed", None)
            with self.assertRaises(SystemExit):
                R.cached(dest, s2, d2)
            _b, s3, d3 = R.request_of("gemini-3.7-flash", [], "prompt", "low")
            with self.assertRaises(SystemExit):
                R.cached(dest, s3, d3)
            self.assertIsNone(R.cached(os.path.join(t, "none.json"), settings, digest))


class Parse(unittest.TestCase):
    def test_quotes_kept(self):
        r = R.parse('{"kind": "clipping", "title": "Tax Cut", "byline": [], "publication": null, '
                    '"publication_date": "1962-03-03", "recipient_place": [], "quotes": {"title": "TAX CUT"}}')
        self.assertEqual(r["kind"], "clipping")
        self.assertEqual(r["publication_date"], (1962, 3, 3))
        self.assertEqual(r["quotes"]["title"], "TAX CUT")


class SheetUpright(unittest.TestCase):
    def test_turn_box_maps_a_corner_and_four_turns_return(self):
        b = [0.1, 0.2, 0.3, 0.1]   # near the top-left
        self.assertEqual([round(v, 6) for v in R.turn_box(b, 90)], [0.7, 0.1, 0.1, 0.3])   # clockwise: top-right
        self.assertEqual([round(v, 6) for v in R.turn_box(b, 180)], [0.6, 0.7, 0.3, 0.1])
        self.assertEqual([round(v, 6) for v in R.turn_box(b, 270)], [0.2, 0.6, 0.1, 0.3])
        x = b
        for _ in range(4):
            x = R.turn_box(x, 90)
        self.assertEqual([round(v, 6) for v in x], b)
        self.assertEqual(R.turn_box(b, 0), b)

    def test_display_turns_needs_a_clear_win(self):
        with tempfile.TemporaryDirectory() as d:
            f = os.path.join(d, "o.tsv")
            with open(f, "w") as fh:
                fh.write("/x/send/a.jpg\t3.5\t102.0\t3.5\t233.2\n"     # left wins: 270
                         "/x/send/b.jpg\t2019.4\t86.8\t1492.2\t43.4\n"  # upright
                         "/x/send/c.jpg\t0.0\t65.5\t2.4\t14.4\n"        # right wins: 90
                         "/x/send/g.jpg\t0.0\t61.5\t2.5\t71.9\n"        # the sideways turns close: stays
                         "/x/send/d.jpg\t40\t70\t0\t0\n"                # under twice upright: stays
                         "/x/send/e.jpg\t1\t15\t0\t0\n"                 # under 20 characters: stays
                         "/x/send/f.jpg\t5\t0\t300\t0\n")               # upside down: 180
            self.assertEqual(R.display_turns(f, eye=os.path.join(d, "none.tsv")), {"a": 270, "c": 90, "f": 180})
            eye = os.path.join(d, "eye.tsv")
            with open(eye, "w") as fh:
                fh.write("d\t90\na\t0\n")   # an eye check adds a turn the scores missed, and can undo one
            self.assertEqual(R.display_turns(f, eye=eye), {"c": 90, "f": 180, "d": 90})

    def test_agreed_line_skips_asked_and_empty_fields(self):
        r = {"kind": "article", "title": "Tax cut", "publication": "The Times", "byline": [], "publication_date": None}
        got = dict(R.agreed_line(r, {"publication"}))
        self.assertIn("title", got)
        self.assertNotIn("publication", got)
        self.assertNotIn("byline", got)


if __name__ == "__main__":
    unittest.main()
