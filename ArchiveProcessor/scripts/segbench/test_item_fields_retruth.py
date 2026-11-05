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
        q = R.quotas({"kind": 50, "title": 50, "publication": 3}, {"kind": 0.88, "title": 0.40, "publication": 0.5})
        self.assertEqual(q["publication"], 3)            # all there are
        self.assertGreater(q["kind"], q["title"])        # nearer the bar
        self.assertGreaterEqual(q["title"], R.MIN_PER_FIELD)
        self.assertEqual(sum(q.values()), R.SHEET_DISPUTES)

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


if __name__ == "__main__":
    unittest.main()
