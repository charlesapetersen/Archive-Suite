"""W46.seg-adapt-lora: a corrected target changes only the wrong decisions and refuses a reply it cannot correct;
the replay search finds the 2B's own corpus set and stops plainly on none or several (W46.fix-sal-replay-search)."""
import json
import os
from pathlib import Path
import tempfile
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


def data_set(path, meta):
    path.mkdir(parents=True)
    (path / "train.jsonl").write_text("")
    (path / "data.json").write_text(json.dumps(meta))
    return path.resolve()


class ReplaySearch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "fs-ocr"
        self.root.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def test_finds_the_set_without_a_rule(self):
        # FarmShare's train/full/data: windows and images, no `rule` (the 2026-11-05 IndexError).
        want = data_set(self.root / "train" / "full" / "data",
                        {"windows": 5885, "no_text": 3000, "images": "/scratch/users/cp1/fs-ocr/images"})
        data_set(self.root / "train" / "other" / "data", {"windows": 412, "images": "/x"})
        data_set(self.root / "train" / "noimages", {"windows": 5885})
        data_set(self.root / "runs" / "skipped", {"windows": 5885, "images": "/x"})
        os.symlink(self.root / "train" / "full", self.root / "train" / "seg-2b")
        self.assertEqual(L.replay_candidates(self.root, 5885), [want])
        self.assertEqual(L.replay_source(self.root, 5885), want)

    def test_skips_a_replay_set_it_wrote(self):
        want = data_set(self.root / "a", {"windows": 300, "images": "/x"})
        data_set(self.root / "out", {"item": L.TAG, "windows": 300, "images": "/y", "rule": "corrections+replay"})
        self.assertEqual(L.replay_source(self.root, 300), want)

    def test_none_stops_naming_the_root(self):
        data_set(self.root / "a", {"windows": 10, "images": "/x"})
        with self.assertRaises(SystemExit) as e:
            L.replay_source(self.root, 5885)
        self.assertIn("replay set: 0 candidates", str(e.exception.code))
        self.assertIn(str(self.root), str(e.exception.code))

    def test_several_stop_listing_them(self):
        a = data_set(self.root / "a", {"windows": 5885, "images": "/x"})
        b = data_set(self.root / "b", {"windows": 5885, "images": "/y"})
        with self.assertRaises(SystemExit) as e:
            L.replay_source(self.root, 5885)
        msg = str(e.exception.code)
        self.assertIn("replay set: 2 candidates", msg)
        self.assertIn(str(self.root), msg)
        self.assertIn(str(a), msg)
        self.assertIn(str(b), msg)

    def test_unknown_window_count_matches_nothing(self):
        data_set(self.root / "a", {"images": "/x"})
        with self.assertRaises(SystemExit):
            L.replay_source(self.root, None)

    def test_named_set_wins_and_must_exist(self):
        named = data_set(self.root / "named", {"windows": 1, "images": "/x"})
        data_set(self.root / "a", {"windows": 5885, "images": "/x"})
        self.assertEqual(L.replay_source(self.root, 5885, str(named)), named)
        with self.assertRaises(SystemExit):
            L.replay_source(self.root, 5885, str(self.root / "missing"))


class Scoring(unittest.TestCase):
    """gap_kinds, tally and paired on a five-page box: items A (pages 1-3, a start inside it at 3) and B (4-5)."""
    def setUp(self):
        self.manifest = {"pages": [{"id": "A", "label": "New"}, {"id": "A", "label": "Cont"},
                                   {"id": "A", "label": "New"}, {"id": "B", "label": "New"},
                                   {"id": "B", "label": "Cont"}]}

        class Box:
            truth = {0: False, 1: True, 2: True, 3: False}
            unsure = {3}
        self.box = Box()

    def test_kinds(self):
        self.assertEqual(L.gap_kinds(self.manifest), {0: "continue", 1: "internal", 2: "catalogue", 3: "continue"})

    def test_tally_skips_unsure_and_splits_errors(self):
        new = {0: True, 1: False, 2: True, 3: True}     # a false split, a missed start, a right start, an unsure gap
        t = L.tally(self.box, L.gap_kinds(self.manifest), new, [0, 1, 2, 3])
        self.assertEqual((t["gaps"], t["errors"], t["fs"], t["fm"]), (3, 2, 1, 1))
        self.assertEqual((t["catalogue"], t["internal"], t["continue"]), ([1, 1], [0, 1], [0, 1]))

    def test_paired_difference(self):
        a = {0: True, 1: False, 2: True, 3: True}
        b = {0: False, 1: True, 2: True, 3: True}
        groups = {0: "A", 1: "A", 2: "A", 3: "B"}
        p = L.paired(self.box, groups, a, b, [0, 1, 2, 3])
        self.assertAlmostEqual(p["diff"], -200 / 3)
        self.assertEqual((p["gaps"], p["items"]), (3, 1))
        self.assertLessEqual(p["lo"], p["diff"])
        self.assertGreaterEqual(p["hi"], p["diff"])


if __name__ == "__main__":
    unittest.main()
