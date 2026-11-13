"""kit_corrections.py counts the Processor's review records per material (W46.kit-corrections-store).
Run: python3 test_kit_corrections.py   (no data, no network)."""
import json
import os
import tempfile
import unittest
from pathlib import Path

import kit_corrections as K


def gap(i, ruling, final="new", proposed="continue"):
    return {"gap": i, "left": {"name": f"p{i}.jpg", "sha256": f"s{i}"},
            "right": {"name": f"p{i + 1}.jpg", "sha256": f"s{i + 1}"},
            "proposed": proposed, "confidence": 0.6, "flagged": ruling == "checked", "final": final, "ruling": ruling}


def write(folder, name, record):
    c = Path(folder) / ".archivesuite" / "corrections"
    c.mkdir(parents=True, exist_ok=True)
    (c / name).write_text(json.dumps(record))


def gaps_record(run, at, coll, gaps, name="Box 1"):
    return {"schemaVersion": 1, "kind": "gaps", "runID": run, "recordedAt": at, "approach": "local", "pages": 9,
            "owner": {"collectionID": coll, "collectionName": name}, "gaps": gaps}


class Count(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def rows(self, *dirs, pool=None):
        return K.summary(K.gather([str(d) for d in dirs] or [str(self.root)], pool))

    def test_ruled_gaps_count_accepted_do_not(self):
        write(self.root / "a", "gaps-1.json", gaps_record("1", "2026-11-01T00:00:00Z", "A",
                                                          [gap(0, "checked"), gap(1, "changed"), gap(2, "accepted", "continue")]))
        (r,) = self.rows()
        self.assertEqual((r["gaps"]["ruled"], r["gaps"]["known"]), (2, 3))
        self.assertFalse(r["gaps"]["continuation_offered"])

    def test_a_pair_reviewed_twice_counts_once_newest_wins(self):
        write(self.root / "a", "gaps-1.json", gaps_record("1", "2026-11-01T00:00:00Z", "A", [gap(0, "accepted")]))
        write(self.root / "a", "gaps-2.json", gaps_record("2", "2026-11-02T00:00:00Z", "A", [gap(0, "checked")]))
        (r,) = self.rows()
        self.assertEqual((r["gaps"]["ruled"], r["gaps"]["known"]), (1, 1))

    def test_collections_are_materials_unless_pooled(self):
        write(self.root / "a", "gaps-1.json", gaps_record("1", "2026-11-01T00:00:00Z", "A", [gap(0, "checked")], "Box 1"))
        write(self.root / "b", "gaps-2.json", gaps_record("2", "2026-11-01T00:00:00Z", "B", [gap(5, "checked")], "Box 2"))
        self.assertEqual([r["name"] for r in self.rows()], ["Box 1", "Box 2"])
        (r,) = self.rows(self.root / "a", self.root / "b", pool="Lincoln")
        self.assertEqual((r["name"], r["gaps"]["ruled"]), ("Lincoln", 2))

    def test_floor(self):
        write(self.root / "a", "gaps-1.json", gaps_record("1", "2026-11-01T00:00:00Z", "A",
                                                          [gap(i * 2, "checked") for i in range(200)]))
        (r,) = self.rows()
        self.assertTrue(r["gaps"]["continuation_offered"])

    def test_lines_per_hand(self):
        lines = [{"page": {"name": "p.jpg", "sha256": "s"}, "line": i, "boundary": [], "recognised": "x",
                  "recognisedBy": "ocr-kraken-ppocrv6", "corrected": "y", "hand": "A. L." if i < 80 else None}
                 for i in range(81)]
        write(self.root / "a", "lines-1.json", {"schemaVersion": 1, "kind": "lines", "runID": "1",
                                               "recordedAt": "2026-11-01T00:00:00Z",
                                               "owner": {"collectionID": "A", "collectionName": "Box 1"}, "lines": lines})
        (r,) = self.rows()
        self.assertEqual([(h["hand"], h["lines"], h["fine_tune_offered"]) for h in r["lines"]],
                         [("", 1, False), ("A. L.", 80, True)])

    def test_unsafe_or_unknown_files_are_skipped(self):
        write(self.root / "a", "gaps-1.json", gaps_record("1", "2026-11-01T00:00:00Z", "A", [gap(0, "checked")]))
        c = self.root / "a" / ".archivesuite" / "corrections"
        (c / "gaps-newer.json").write_text(json.dumps(dict(gaps_record("3", "2026-11-03T00:00:00Z", "A",
                                                                       [gap(9, "checked")]), schemaVersion=2)))
        (c / "gaps-broken.json").write_text("not json")
        outside = self.root / "outside.json"
        outside.write_text(json.dumps(gaps_record("4", "2026-11-04T00:00:00Z", "A", [gap(20, "checked")])))
        os.symlink(outside, c / "gaps-link.json")
        # A linked .archivesuite elsewhere is not walked into.
        (self.root / "b").mkdir()
        write(self.root / "elsewhere", "gaps-5.json", gaps_record("5", "2026-11-05T00:00:00Z", "E", [gap(30, "checked")]))
        os.symlink(self.root / "elsewhere" / ".archivesuite", self.root / "b" / ".archivesuite")
        rows = self.rows(self.root / "a", self.root / "b")
        self.assertEqual([(r["material"], r["gaps"]["ruled"]) for r in rows], [("A", 1)])

    def test_malformed_entries_are_skipped_not_fatal(self):
        bad = [gap(0, "checked"), {"left": "x", "right": None}, 7, {"gap": 3}]
        write(self.root / "a", "gaps-1.json", gaps_record("1", "2026-11-01T00:00:00Z", "A", bad))
        write(self.root / "a", "gaps-2.json", dict(gaps_record("2", "2026-11-02T00:00:00Z", "A", [gap(4, "checked")]),
                                                  schemaVersion="1"))
        write(self.root / "a", "gaps-3.json", dict(gaps_record("3", 5, "A", [gap(6, "checked")])))
        write(self.root / "a", "lines-4.json", {"schemaVersion": 1, "kind": "lines", "runID": "4",
                                               "recordedAt": "2026-11-01T00:00:00Z", "owner": {"collectionID": "A"},
                                               "lines": [{"page": "p", "line": 0}, {"page": {"name": "p"}, "line": "x"}, 3]})
        (r,) = self.rows()
        self.assertEqual((r["gaps"]["ruled"], r["lines"]), (1, []))

    def test_a_missing_hash_never_splits_a_pair(self):
        unhashed = gap(0, "accepted")
        del unhashed["left"]["sha256"]
        write(self.root / "a", "gaps-1.json", gaps_record("1", "2026-11-01T00:00:00Z", "A", [unhashed]))
        later = gap(0, "checked")
        del later["left"]["sha256"]
        write(self.root / "a", "gaps-2.json", gaps_record("2", "2026-11-02T00:00:00Z", "A", [later]))
        (r,) = self.rows()
        self.assertEqual((r["gaps"]["known"], r["gaps"]["ruled"]), (1, 1))

    def test_unhashed_pages_of_two_boxes_stay_apart_when_pooled(self):
        a, b = gap(0, "checked"), gap(0, "checked")
        for g in (a, b):
            del g["left"]["sha256"], g["right"]["sha256"]
        write(self.root / "a", "gaps-1.json", gaps_record("1", "2026-11-01T00:00:00Z", "A", [a]))
        write(self.root / "b", "gaps-2.json", gaps_record("2", "2026-11-01T00:00:00Z", "B", [b]))
        (r,) = self.rows(self.root / "a", self.root / "b", pool="Lincoln")
        self.assertEqual(r["gaps"]["ruled"], 2)

    def test_a_record_without_an_id_joins_its_folder_and_paths_are_resolved(self):
        write(self.root / "a", "gaps-1.json", gaps_record("1", "2026-11-01T00:00:00Z", None, [gap(0, "checked")]))
        write(self.root / "a", "gaps-2.json", gaps_record("2", "2026-11-02T00:00:00Z", "A", [gap(2, "checked")]))
        cwd = os.getcwd()
        os.chdir(self.root)
        try:
            rows = K.summary(K.gather(["a", str(self.root / "a")]))
        finally:
            os.chdir(cwd)
        self.assertEqual([(r["material"], r["gaps"]["ruled"]) for r in rows], [("A", 2)])

    def test_export(self):
        write(self.root / "a", "gaps-1.json", gaps_record("1", "2026-11-01T00:00:00Z", "A", [gap(0, "checked")]))
        out = self.root / "gaps.jsonl"
        K.main(["export", str(self.root), "--out", str(out)])
        (row,) = [json.loads(l) for l in out.read_text().splitlines()]
        self.assertEqual((row["material"], row["ruling"], row["right"]["sha256"]), ("A", "checked", "s1"))


if __name__ == "__main__":
    unittest.main()
