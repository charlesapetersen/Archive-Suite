"""W47.ct-truth offline tests: the stratified allocation, field agreement, where a field sits, the fold and the tree
set. No corpus, no model. Run: python3 -m unittest test_ct_truth (from this directory)."""
import json
import random
import unittest

import ct_truth as T


class Sampling(unittest.TestCase):
    def test_allocation_floors_caps_and_sums(self):
        counts = {"big": 800, "mid": 100, "small": 1, "two": 2}
        a = T.allocate(counts, 120)
        self.assertEqual(sum(a.values()), 120)
        self.assertEqual(a["small"], 1)          # never more than it has
        self.assertEqual(a["two"], 2)            # the floor
        self.assertGreater(a["big"], a["mid"])
        self.assertLess(a["big"], 120 * 800 / 903)  # square root, not proportional
        self.assertEqual(sum(T.allocate({"a": 3, "b": 4}, 120).values()), 7)  # short of total: everything

    def test_repository_skips_workflow_level(self):
        self.assertEqual(T.repository_of("05 Final Tagging/Hoover Institute/Zschau"), "Hoover Institute")
        self.assertEqual(T.repository_of("Hoover Institute/Zschau/Box 2"), "Hoover Institute")
        self.assertEqual(T.collection_dir("05 Final Tagging/Hoover Institute/Zschau/x"),
                         "05 Final Tagging/Hoover Institute/Zschau")

    def test_draw_spreads_across_collections(self):
        rows = [{"collection": "a", "i": k} for k in range(50)] + [{"collection": "b", "i": k} for k in range(2)]
        got = T.draw(rows, 4, random.Random(1))
        self.assertEqual(sum(r["collection"] == "b" for r in got), 2)


class Agreement(unittest.TestCase):
    def test_container_spellings(self):
        self.assertTrue(T.agree("container", "BOX NO. 17", "Box 17"))
        self.assertTrue(T.agree("container", "17", "Box 17"))
        self.assertTrue(T.agree("container", "SC 122 Box 82", "Box 82"))
        self.assertFalse(T.agree("container", "Box 17", "Box 71"))
        self.assertFalse(T.agree("container", "Carton 9", "Box 9"))

    def test_text_fields_ignore_case_and_punctuation(self):
        self.assertTrue(T.agree("repository", "HOOVER INSTITUTION ARCHIVES", "Hoover Institution Archives."))
        self.assertTrue(T.agree("folder", "Folder 8", "8"))
        self.assertTrue(T.agree("series", None, None))
        self.assertFalse(T.agree("series", "Series II", None))

    def test_disputes_and_parse(self):
        a = T.parse('{"kind": "Box label", "repository": "Hoover", "container": "BOX NO. 17", "folder": null, '
                    '"label_box": [100, 200, 900, 800]}')
        b = T.parse('```json\n{"kind": "box label", "repository": "hoover", "container": "Box 18", "folder": 3}```')
        self.assertEqual(a["kind"], "box label")
        self.assertEqual(a["label_box"], [0.1, 0.2, 0.8, 0.6])
        self.assertEqual(b["folder"], "3")
        self.assertEqual(T.disputes(a, b), ["container", "folder"])
        self.assertIsNone(T.parse("no json here"))
        self.assertIsNone(T.parse('{"kind": "label", "label_box": [9, 9, 1, 1]}')["label_box"])

    def test_readings_order_is_blind_but_fixed(self):
        o1 = T.order_readings("p1", "container", ["Box 17", "Box 71"])
        self.assertEqual(o1, T.order_readings("p1", "container", ["Box 17", "Box 71"]))
        flips = {tuple(T.order_readings(f"p{k}", "container", ["A", "B"])) for k in range(20)}
        self.assertEqual(flips, {("A", "B"), ("B", "A")})


class Placement(unittest.TestCase):
    LINES = [{"box": [0.1, 0.1, 0.9, 0.15], "text": "HOOVER INSTITUTION ARCHIVES"},
             {"box": [0.1, 0.2, 0.5, 0.25], "text": "BOX NO. 17"},
             {"box": [0.1, 0.3, 0.6, 0.35], "text": "ACCESSION NO. 91006-10.V"}]

    def test_value_found_on_its_line(self):
        b = T.place_of("Hoover Institution Archives", self.LINES)
        self.assertAlmostEqual(b[1], 0.09)
        self.assertIsNone(T.place_of("Stanford", self.LINES))
        self.assertIsNotNone(T.place_of("17", self.LINES))    # a bare number as its own token
        self.assertIsNone(T.place_of("7", self.LINES))         # not inside 17

    def test_fallbacks(self):
        box, how = T.field_place("container", ["Box 17", "Box 71"], self.LINES, [None, None])
        self.assertEqual(how, "lines")
        box, how = T.field_place("series", ["Series IV", None], self.LINES, [None, [0, 0, 1, 1]])
        self.assertEqual((box, how), ([0, 0, 1, 1], "label"))
        self.assertEqual(T.field_place("series", ["Series IV"], [], [None]), (None, "none"))


class Fold(unittest.TestCase):
    def test_fold_takes_agreed_then_answers(self):
        agreed = {f: None for f in T.FIELDS}
        agreed["kind"] = "box label"
        del agreed["container"], agreed["series"], agreed["accession"]
        rows = [{"id": "p1", "path": "x.pdf", "colour": "Red", "repository": "R", "parsed": [True, True],
                 "agreed": agreed,
                 "disputed": [{"field": "container", "readings": ["Box 17", "Box 71"]},
                              {"field": "series", "readings": ["Series II", None]},
                              {"field": "accession", "readings": ["91006", "91008"]}]},
                {"id": "p2", "parsed": [True, False], "agreed": {}, "disputed": []}]
        answers = {"p1": {"container": {"pick": "Box 71"}, "series": {"pick": "not on the label"}}}
        truth, missing = T.fold(rows, answers)
        self.assertEqual(len(truth), 1)
        self.assertEqual(truth[0]["fields"]["container"], "Box 71")
        self.assertIsNone(truth[0]["fields"]["series"])
        self.assertEqual(missing, 1)
        self.assertFalse(truth[0]["complete"])
        answers["p1"]["accession"] = {"pick": "other", "text": " 91006-10.V "}
        truth, missing = T.fold(rows, answers)
        self.assertEqual((truth[0]["fields"]["accession"], missing, truth[0]["complete"]), ("91006-10.V", 0, True))


class ThreeReaders(unittest.TestCase):
    def test_unanimity_and_odd_one(self):
        a = T.parse('{"kind": "box label", "container": "Box 17", "series": "Series II"}')
        b = T.parse('{"kind": "box label", "container": "BOX NO. 17", "series": null}')
        c = T.parse('{"kind": "box label", "container": "Box 71", "series": "Series III"}')
        self.assertEqual(T.disputes(a, b, c), ["series", "container"])
        self.assertEqual(T.disputes(a, b, a), ["series"])
        keys = ("x", "y", "z")
        self.assertEqual(T.odd_one("container", ["Box 17", "BOX NO. 17", "Box 71"], keys), "z")
        self.assertIsNone(T.odd_one("series", ["Series II", None, "Series III"], keys))
        self.assertEqual(len(T.order_readings("p", "series", ["Series II", None, "Series III"])), 3)

    def test_controls_are_drawn_from_unanimous_fields(self):
        rows = []
        for k in range(30):
            agreed = {f: None for f in T.FIELDS}
            agreed["kind"], agreed["container"] = "box label", f"Box {k}"
            rows.append({"id": f"p{k}", "agreed": agreed, "disputed": [], "controls": [], "_place": ([], [None])})
        T.pick_controls(rows, n=6)
        ctl = [(r["id"], d) for r in rows for d in r["controls"]]
        self.assertEqual(len(ctl), 6)
        self.assertEqual(sum(1 for _, d in ctl if d["readings"]), 3)
        for mid, d in ctl:
            r = next(x for x in rows if x["id"] == mid)
            self.assertEqual(d["readings"], [r["agreed"][d["field"]]] if r["agreed"][d["field"]] else [])
        items = T.sheet_items([dict(r, colour="Red") for r in rows])
        for it in items:   # a control's agreed value is not shown beside it
            self.assertFalse({f["field"] for f in it["fields"]} & set(it["agreed"]))

    def test_fold_records_rulings_and_overturned_controls(self):
        agreed = {f: None for f in T.FIELDS}
        agreed["kind"], agreed["container"] = "box label", "Box 3"
        del agreed["series"]
        rows = [{"id": "p1", "path": "x.pdf", "colour": "Red", "repository": "R", "parsed": [True] * 3,
                 "readers": list(T.READERS), "agreed": agreed,
                 "disputed": [{"field": "series", "readings": ["Series II", None]}],
                 "controls": [{"field": "container", "readings": ["Box 3"]},
                              {"field": "folder", "readings": []}]}]
        truth, missing = T.fold(rows, {"p1": {"series": {"pick": "Series II"}, "container": {"pick": "other",
                                                                                         "text": "Box 8"}}})
        t = truth[0]
        self.assertEqual((missing, t["fields"]["container"], t["fields"]["series"]), (0, "Box 8", "Series II"))
        self.assertEqual(sorted(t["ruled"]), ["container", "series"])
        self.assertEqual(t["controls_overturned"], ["container"])
        self.assertIsNone(t["fields"]["folder"])   # an unanswered control keeps its agreed value
        self.assertTrue(t["complete"])
        self.assertEqual(t["drafters"], list(T.READERS))
        self.assertIsNone(t["notes"])

    def test_fold_carries_notes_and_ignores_them_as_a_field(self):
        agreed = {f: None for f in T.FIELDS}
        agreed["kind"], agreed["series"] = "box label", "Series III"
        rows = [{"id": "p1", "path": "x.pdf", "colour": "Red", "repository": "R", "parsed": [True] * 3,
                 "agreed": agreed, "disputed": [], "controls": []}]
        truth, missing = T.fold(rows, {"p1": {T.NOTES: {"text": "  series also says Subseries A  "}}})
        self.assertEqual(truth[0]["notes"], "series also says Subseries A")
        self.assertEqual((truth[0]["ruled"], missing, truth[0]["fields"]["series"]), ([], 0, "Series III"))
        self.assertNotIn(T.NOTES, truth[0]["fields"])

    def test_sheet_html_fills_placeholders_and_has_a_notes_box(self):
        import os
        import tempfile
        agreed = {f: None for f in T.FIELDS}
        agreed["kind"], agreed["collection_title"] = "box label", "Edward Shils. Papers"
        rows = [{"id": "p1", "path": "x.pdf", "colour": "Red", "agreed": agreed, "disputed": [],
                 "controls": [{"field": "container", "readings": ["Box 5"], "box": None, "placed": "none"}]}]
        old, oldimg = T.SHEET, T.image_of
        with tempfile.TemporaryDirectory() as d:
            T.SHEET, T.image_of = d, (lambda mid: os.path.join(d, mid + ".jpg"))
            try:
                T.write_sheet(rows)
                html = open(os.path.join(d, "index.html"), encoding="utf-8").read()
            finally:
                T.SHEET, T.image_of = old, oldimg
        for ph in ("__DATA__", "__KINDS__", "__LABELS__", "__NOTES__"):
            self.assertNotIn(ph, html)
        self.assertIn("data-n=", html)
        self.assertIn('"Edward Shils. Papers"', html)


class Trees(unittest.TestCase):
    def test_committed_set_matches_generator(self):
        with open(T.TREES, encoding="utf-8") as fh:
            self.assertEqual(json.load(fh)["trees"], json.loads(json.dumps(T.make_trees())))

    def test_trees_are_sound(self):
        trees = T.make_trees()
        self.assertGreaterEqual(len(trees), 30)
        for t in trees:
            self.assertTrue(t["files"])
            for f in t["files"]:
                self.assertTrue(set(f["expect"]) <= set(T.FIELDS), f)
                self.assertTrue(f["path"].endswith(".pdf"))
                levels = f["path"].split("/")[:-1]
                self.assertEqual(len(levels), len(t["levels"]), t["id"])



class Repeats(unittest.TestCase):
    def test_a_reading_that_only_repeats_settled_text_is_a_repeat(self):
        fields = {"kind": "box label", "collection_title": "Applied Data Research Software Products Division Records, 1959-1987",
                  "collection_number": "CBI 154", "container": "Box 6"}
        self.assertTrue(T.repeat_of([None, "Applied Data Research Software Products Division"], fields))
        self.assertTrue(T.repeat_of(["Applied Data Research Software Products Division Records, 1959-1987", None], fields))
        self.assertTrue(T.repeat_of([None, "CBI 154"], fields))
        self.assertTrue(T.repeat_of([None, "1959-1987"], fields))
        self.assertFalse(T.repeat_of([None, "Correspondence, 1960"], fields))           # new text: asked
        self.assertFalse(T.repeat_of(["Records, 1959-1987, Series 2", None], fields))   # adds to it: asked
        self.assertFalse(T.repeat_of([None, None], fields))                              # nothing offered
        self.assertFalse(T.repeat_of([None, "CBI 15"], fields))                          # not on a word boundary
        self.assertFalse(T.repeat_of(["box label"], {"kind": "box label"}))              # kind is not settled text

    def test_still_asked_questions_drop_repeated_readings(self):
        fields = {"kind": "box label", "collection_number": "91/115 c", "collection_title": "Paul Seabury Papers"}
        self.assertEqual(T.drop_repeats(["c", "91/115 c", "UC-NRLF; W 94 937", None], fields),
                         ["UC-NRLF; W 94 937", None])
        self.assertEqual(T.repeats_in("2007-119", {"accession": "2007-119"}, T.TITLE_FIELDS), [])   # not a title
        self.assertEqual(T.repeats_in("1959-1987", {"collection_title": "X Records, 1959-1987"}, T.TITLE_FIELDS),
                         ["collection_title"])
        self.assertIn("folder", T.REPEAT_EXEMPT)   # "5" as the folder of "Box 5" is not a repeat
        f2 = {"kind": "box label", "collection_title": "American Jewish Congress Records, n.d., 1916-",
              "collection_number": "I-77", "container": "Box 34"}
        self.assertEqual(T.drop_repeats(["of 201", "Records; Box 34 of 201", None], f2), [None])   # parts, the count
        self.assertTrue(T.repeat_of(["of 201", "Records; Box 34 of 201"], f2))
        self.assertFalse(T.repeat_of(["Records; Shelf 12"], f2))   # one new part keeps it asked
        f3 = {"kind": "box label", "series": "Series III", "series_title": "Correspondence", "container": "Box 5",
              "folder": "9"}
        self.assertTrue(T.repeat_of(["Series III, Correspondence"], f3))   # pieces of two settled fields
        self.assertTrue(T.repeat_of(["5-9"], f3))                          # box and folder, the mark rule
        self.assertFalse(T.repeat_of(["Series III, Minutes"], f3))         # a new word keeps it asked


if __name__ == "__main__":
    unittest.main()
