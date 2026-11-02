"""W46.kit-gate-sherlock: the checkpack's gaps to their covering windows, the owner's answers, the frozen-pack check
and the submit guard, on toy data.
Run: $(torch-env.sh) test_kit_gate_sherlock.py   (no bench data, no model call, no cluster)."""
import json
from copy import deepcopy
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import kit_gate_sherlock as K

HERE = Path(__file__).resolve().parent


def toy_cache(root, windows, labels, cases, answers):
    (root / "checkpack").mkdir(parents=True)
    (root / "windows.jsonl").write_text("".join(json.dumps(w) + "\n" for w in windows))
    (root / "labels.jsonl").write_text("".join(json.dumps(g) + "\n" for g in labels))
    (root / "checkpack" / "key.json").write_text(json.dumps({"population": {}, "cases": cases}))
    (root / "answers.csv").write_text("".join(f"{k},{v}\n" for k, v in answers.items()))


def win(fid, nums):
    return {"folder_id": fid, "split": "train", "text": "abbyy",
            "pages": [{"n": n, "pdf": f"{fid}/{n}.pdf", "jpeg": f"{fid}/{n}.jpg", "label": "Cont"} for n in nums]}


class Checkpack(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        windows = [win("f1", range(1, 5)), win("f1", range(1, 8)), win("f1", range(4, 11)), win("f1", range(7, 13)),
                   win("f2", range(1, 4))]
        labels = [{"folder_id": "f1", "n": 6, "left": "f1/6.pdf", "right": "f1/7.pdf", "split": "holdout"},
                  {"folder_id": "f2", "n": 1, "left": "f2/1.pdf", "right": "f2/2.pdf", "split": "train"}]
        cases = [{"id": "k01", "stratum": "A", "left": "f1/6.pdf", "right": "f1/7.pdf", "tag": "new"},
                 {"id": "k02", "stratum": "D", "left": "f2/1.pdf", "right": "f2/2.pdf", "tag": "cont"}]
        toy_cache(self.root, windows, labels, cases, {"k01": "same", "k02": "unsure"})

    def tearDown(self):
        self.tmp.cleanup()

    def test_cases_map_owner_answers(self):
        cs = K.checkpack_cases(self.root, self.root / "answers.csv")
        self.assertEqual([(c["id"], c["n"], c["split"], c["owner"]) for c in cs],
                         [("k01", 6, "holdout", "cont"), ("k02", 1, "train", "unsure")])

    def test_only_windows_holding_both_pages(self):
        cs = K.checkpack_cases(self.root, self.root / "answers.csv")
        out = K.checkpack_windows(cs, self.root)
        pages, wins = out["f1"]
        # gap 6|7: the windows 1-7 and 4-10 hold both pages; 1-4 and 7-12 hold one or neither
        self.assertEqual(sorted(map(tuple, wins)), [tuple(range(1, 8)), tuple(range(4, 11))])
        self.assertEqual(sorted(pages), list(range(1, 11)))
        self.assertEqual(out["f2"][1], [[1, 2, 3]])

    def test_a_gap_no_window_covers_is_refused(self):
        cs = [{"id": "k09", "folder_id": "f1", "n": 12}]
        with self.assertRaises(SystemExit):
            K.checkpack_windows(cs, self.root)

    def test_a_missing_answer_is_refused(self):
        (self.root / "answers.csv").write_text("k01,new\n")
        with self.assertRaises(SystemExit):
            K.checkpack_cases(self.root, self.root / "answers.csv")


class Frozen(unittest.TestCase):
    def pack(self, root):
        (root / "teacher" / "images").mkdir(parents=True)
        w = [{"box": "b", "window": [1, 2], "cache_key": "x", "prompt": "p"}]
        (root / "teacher" / "windows.jsonl").write_text("".join(json.dumps(r) + "\n" for r in w))
        files = {"teacher/windows.jsonl": K.sha(root / "teacher" / "windows.jsonl")}
        (root / "freeze.json").write_text(json.dumps({"tag": K.TAG, "packs": {"teacher": {"windows": 1}},
                                                      "files": files}))

    def test_check_passes_then_catches_a_change(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.pack(root)
            K.check(root)
            with open(root / "teacher" / "windows.jsonl", "a") as fh:
                fh.write("\n")
            with self.assertRaises(SystemExit):
                K.check(root)

    def test_submit_refuses_unattended(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.pack(root)
            r = subprocess.run(["bash", str(HERE / "sherlock" / "kit-gate" / "submit.sh"), str(root)],
                               env={**os.environ, "ARCHIVE_UNATTENDED": "1"}, capture_output=True, text=True)
            self.assertEqual(r.returncode, 2)
            self.assertIn("owner-attended", r.stdout)


class TruthProvenance(unittest.TestCase):
    """Real committed scores exercise the consuming refresh; no corpus, pack, models or money."""
    def setUp(self):
        self.source = K.RESULTS / K.OWNER_SOURCE
        self.local = json.loads(self.source.read_text())
        self.kit = json.loads((K.RESULTS / "seg-kit-gate-sherlock.json").read_text())

    def test_reuses_exact_owner_scores_and_keeps_original_diagnostics(self):
        before = deepcopy(self.kit)
        boxes = K.qualify_boxes(self.kit["boxes"])
        self.assertEqual(before["boxes"]["observed"], boxes["observed"])
        self.assertEqual(before["checkpack"], self.kit["checkpack"])
        sc = boxes["sc0122_owner"]
        self.assertEqual(sc["source_sha256"], K.sha(self.source))
        self.assertEqual((sc["asked_known"], sc["controls"], sc["agreed_doc_gaps"]), (30, 60, 158))
        for key, route in K.OWNER_ROUTES.items():
            self.assertEqual(sc["models"][key], self.local["sc0122_owner"]["models"][route])
        scrows = [r for r in boxes["observed"] if r["box"] == "SC0122"]
        self.assertTrue(all("teacher-drafted" in r["truth"] and "conditional" in r["interpretation"] for r in scrows))

    def reject_source(self, change, error=ValueError):
        change(self.local)
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / K.OWNER_SOURCE
            path.write_text(json.dumps(self.local))
            with self.assertRaises(error):
                K.qualify_boxes(self.kit["boxes"], path)

    def test_missing_route_refused(self):
        self.reject_source(lambda d: d["sc0122_owner"]["models"].pop("fs-4b"), KeyError)

    def test_changed_support_refused(self):
        self.reject_source(lambda d: d["sc0122_owner"].update(asked_known=37))

    def test_uncovered_stratum_refused(self):
        self.reject_source(lambda d: d["sc0122_owner"]["uncovered_strata"].append("missing"))

    def test_inconsistent_stratum_denominator_refused(self):
        self.reject_source(lambda d: next(iter(d["sc0122_owner"]["strata"].values())).__setitem__(1, 0))

    def test_unrelated_run_refused(self):
        def change(d):
            next(r for r in d["observed"] if r["box"] == "SC0122" and r["route"] == "fs-2b")["false merges"] += 1
        self.reject_source(change)

    def test_wrong_weighted_estimate_refused(self):
        self.reject_source(lambda d: d["sc0122_owner"]["models"]["fs-2b"].update(owner_weighted_accuracy=.99))

    def test_refresh_is_offline_and_idempotent(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / K.OWNER_SOURCE).write_bytes(self.source.read_bytes())
            target = root / "seg-kit-gate-sherlock.json"
            target.write_text(json.dumps(self.kit))
            with patch.object(K, "RESULTS", root), patch.object(K, "_seg", side_effect=AssertionError("no model/data")), \
                    patch.object(K, "import_answers", side_effect=AssertionError("no pack import")):
                K.cmd_refresh(None)
                first = [target.read_bytes(), target.with_suffix(".md").read_bytes()]
                K.cmd_refresh(None)
                self.assertEqual(first, [target.read_bytes(), target.with_suffix(".md").read_bytes()])
            report = first[1].decode()
            for text in ("tag/teacher-drafted", "30 disputes", "158 known agreed", "90 known owner rulings",
                         "not 188 independent", "not independent accuracy", "98.1%", "document-exact"):
                self.assertIn(text, report)
            self.assertNotIn("No drafter or relative", report)
            self.assertIn("89.1%", report)   # held-out Sasha unchanged


if __name__ == "__main__":
    unittest.main()
