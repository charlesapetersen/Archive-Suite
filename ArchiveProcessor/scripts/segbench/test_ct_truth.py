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


if __name__ == "__main__":
    unittest.main()
