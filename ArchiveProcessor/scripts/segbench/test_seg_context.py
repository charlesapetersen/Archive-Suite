"""W46.seg-context: the collection block, the paired requests, the pack check, the answer judge and the submit guard,
on toy data. Run: /usr/local/bin/python3 test_seg_context.py   (no bench data, no model call, no cluster)."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import seg_context as S

HERE = Path(__file__).resolve().parent


def toy(labels, texts, name="Toy"):
    pages = [SimpleNamespace(n=i + 1, label=lab) for i, lab in enumerate(labels)]
    return SimpleNamespace(name=name, pages=pages, labels=labels, text=lambda i: texts[i])


class Facts(unittest.TestCase):
    def test_doc_lengths_skip_label_photos(self):
        self.assertEqual(S.doc_lengths(["Box", "Folder", "New", "Cont", "New", "Folder", "New", "Cont", "Cont"]),
                         [2, 1, 3])

    def test_public_block_states_every_fact_from_the_box(self):
        texts = ["Washington, 1863. Dear Sir, " + "x" * 300, "1864 and 1865 " + "y" * 300, "", "1863", "1866 1867"]
        col = toy(["New", "Cont", "New", "Cont", "New"], texts)
        f, block = S.facts("Lincoln", col, {"source_documents": [{}, {}]}, [])
        self.assertTrue(block.startswith(S.HEADER))
        self.assertIn("The catalogue lists 2 items for these 5 pages.", block)
        self.assertIn("mostly from 1863 to 1867; the commonest decade is the 1860s", block)
        self.assertIn("3 of the 5 pages (60%) carry little machine-readable text", block)
        self.assertIn("the catalogue's items average 2.5 pages", block)
        self.assertEqual(f["era"], [1863, 1867])

    def test_owner_block_quotes_labels_and_uses_the_dev_prior(self):
        texts = ["SMITH COLLECTION  BOX 12", "Letters\n1970", "a" * 250 + " 1971", "1972 1973 1974"]
        col = toy(["Box", "Folder", "New", "New"], texts)
        f, block = S.facts("Stanton", col, None, [1, 1, 1, 5])
        self.assertIn('box label (page 1): "SMITH COLLECTION BOX 12"', block)
        self.assertIn('folder label (page 2): "Letters 1970"', block)
        self.assertIn("from the same owner's earlier boxes: 4 documents, median 1 page, mean 2.0; 75% one page", block)
        self.assertNotIn("The catalogue lists", block)

    def test_too_few_years_is_said_not_guessed(self):
        f, block = S.facts("CREST", toy(["New"], ["no dates here"]), {"source_documents": [{}]}, [])
        self.assertIsNone(f["era"])
        self.assertIn("too few years", block)


class Request(unittest.TestCase):
    def test_block_goes_above_the_ocr_heading_and_nothing_else_changes(self):
        base = "PROMPT HEAD\nTHE OCR TEXT OF EACH PAGE (truncated)\n--- page 4 ---\ntext four\nTAIL"
        L = SimpleNamespace(request=lambda col, a, b: (base, ["t4", "t5"], [4, 5]))
        with mock.patch.object(S, "_seg", return_value=(None, L, None, None, None)):
            self.assertEqual(S.request(None, 3, 5)[0], base)
            p, thumbs, nums = S.request(None, 3, 5, "COLLECTION FACTS. x")
        self.assertEqual(p, base.replace("THE OCR TEXT", "COLLECTION FACTS. x\n\nTHE OCR TEXT"))
        self.assertEqual((thumbs, nums), (["t4", "t5"], [4, 5]))

    def test_ambiguous_heading_refuses(self):
        base = "THE OCR TEXT OF EACH PAGE (a)\n--- page 4 ---\nquoted: THE OCR TEXT OF EACH PAGE (b)\n"
        L = SimpleNamespace(request=lambda col, a, b: (base, [], [4, 5]))
        with mock.patch.object(S, "_seg", return_value=(None, L, None, None, None)):
            with self.assertRaises(ValueError):
                S.request(SimpleNamespace(name="Toy"), 3, 5, "B")


def toy_pack(root):
    root = Path(root)
    (root / "images").mkdir(parents=True)
    (root / "images" / "a.jpg").write_bytes(b"jpeg")
    for role in ("teacher", "student"):
        (root / role).mkdir()
        ws = [{"box": "CREST", "window": [1, 2], "arm": arm, "cache_key": f"{role}-{arm}", "prompt": arm}
              for arm in S.ARMS]
        (root / role / "windows.jsonl").write_text("".join(json.dumps(w) + "\n" for w in ws))
        os.symlink("../images", root / role / "images")
    files = {str(p.relative_to(root)): S.sha(p) for p in root.rglob("*") if p.is_file() and not p.is_symlink()}
    (root / "freeze.json").write_text(json.dumps({"tag": S.TAG, "boxes": {"CREST": {"windows": 1}},
                                                  "models": {"teacher": {}, "student": {}}, "arms": list(S.ARMS),
                                                  "files": files}))


class Check(unittest.TestCase):
    def test_a_sound_pack_passes_and_a_changed_file_fails(self):
        with tempfile.TemporaryDirectory() as d:
            toy_pack(d)
            S.check(d)
            (Path(d) / "images" / "a.jpg").write_bytes(b"other")
            with self.assertRaises(SystemExit):
                S.check(d)

    def test_an_unpaired_window_fails(self):
        with tempfile.TemporaryDirectory() as d:
            toy_pack(d)
            p = Path(d) / "student" / "windows.jsonl"
            p.write_text(p.read_text().splitlines()[0] + "\n")
            f = json.loads((Path(d) / "freeze.json").read_text())
            f["files"]["student/windows.jsonl"] = S.sha(p)
            (Path(d) / "freeze.json").write_text(json.dumps(f))
            with self.assertRaises(SystemExit):
                S.check(d)


class Judge(unittest.TestCase):
    def test_each_arm_answers_only_from_its_own_requests(self):
        import method_window as W
        good = json.dumps({"pages": [{"page": 1, "kind": "document"}, {"page": 2, "kind": "document"}],
                           "boundaries": [{"between": [1, 2], "decision": "new", "cue": "c", "confidence": 0.9}]})
        with tempfile.TemporaryDirectory() as d:
            toy_pack(Path(d) / "pack")
            run = Path(d) / "runs" / "teacher"
            run.mkdir(parents=True)
            run.joinpath("answers.jsonl").write_text(
                json.dumps({"cache_key": "teacher-block", "window": [1, 2], "status": "ok", "result": good}) + "\n"
                + json.dumps({"cache_key": "teacher-base", "window": [1, 2], "status": "failed"}) + "\n{half")
            js, failed, n = S.judges(Path(d) / "pack", Path(d) / "runs", "teacher")
            col = toy(["New", "New"], ["", ""], name="CREST")
            self.assertEqual(js["block"](col, 0, 2)["boundaries"][1]["decision"], "new")
            self.assertEqual(js["base"](col, 0, 2)["boundaries"][1]["confidence"], 0.5)  # failed votes 0.5
            self.assertIsNone(js["block"](toy(["New", "New"], ["", ""], name="Lincoln"), 0, 2))
            self.assertEqual((dict(failed), n), ({"base": 1}, 2))
            self.assertIs(W.parse_answer, W.parse_answer)

    def test_an_answer_the_pack_never_asked_for_refuses(self):
        with tempfile.TemporaryDirectory() as d:
            toy_pack(Path(d) / "pack")
            run = Path(d) / "runs" / "student"
            run.mkdir(parents=True)
            run.joinpath("answers.jsonl").write_text(json.dumps({"cache_key": "stray", "window": [1, 2],
                                                                 "status": "ok", "result": "{}"}) + "\n")
            with self.assertRaises(SystemExit):
                S.judges(Path(d) / "pack", Path(d) / "runs", "student")


class Flips(unittest.TestCase):
    def test_block_and_rerun_flips_are_counted_against_the_earlier_answer(self):
        def answer(decision):
            return json.dumps({"pages": [{"page": 1, "kind": "document"}, {"page": 2, "kind": "document"}],
                               "boundaries": [{"between": [1, 2], "decision": decision, "cue": "c",
                                               "confidence": 0.9}]})
        with tempfile.TemporaryDirectory() as d:
            toy_pack(Path(d) / "pack")
            run = Path(d) / "runs" / "teacher"
            run.mkdir(parents=True)
            run.joinpath("answers.jsonl").write_text(
                json.dumps({"cache_key": "teacher-base", "window": [1, 2], "status": "ok",
                            "result": answer("new")}) + "\n"
                + json.dumps({"cache_key": "teacher-block", "window": [1, 2], "status": "ok",
                              "result": answer("continue")}) + "\n")
            earlier = Path(d) / "public" / "cache" / "responses" / f"window-or-{S.MODELS['teacher'][0]}" / "te"
            earlier.mkdir(parents=True)
            (earlier / "teacher-base.json").write_text(json.dumps(answer("new")))
            got = S.flips(Path(d) / "pack", Path(d) / "runs", "teacher", Path(d) / "public")
            self.assertEqual(got, {"CREST": {"votes": 1, "block_flips": 1, "rerun_votes": 1, "rerun_flips": 0,
                                             "unparsed": 0}})


class Submit(unittest.TestCase):
    SCRIPT = HERE / "sherlock" / "seg-context" / "submit.sh"

    def run_submit(self, pack, *extra, script=None):
        env = {**os.environ, "ARCHIVE_UNATTENDED": "1", "SCRATCH": "/scratch/users/t", "GROUP_HOME": "/g"}
        return subprocess.run(["bash", str(script or self.SCRIPT), str(pack), *extra], capture_output=True,
                              text=True, env=env)

    def test_unattended_real_submit_refuses_before_anything(self):
        with tempfile.TemporaryDirectory() as d:
            toy_pack(d)
            r = self.run_submit(d)
            self.assertEqual(r.returncode, 2)
            self.assertIn("owner-attended", r.stdout)

    def test_dry_run_checks_the_pack_and_orders_the_four_jobs(self):
        with tempfile.TemporaryDirectory() as d:
            toy_pack(d)
            code = Path(d) / "support" / "segbench"
            code.mkdir(parents=True)
            (code / "seg_context.py").write_text((HERE / "seg_context.py").read_text())
            job = Path(d) / "support" / "job"
            subprocess.run(["cp", "-R", str(self.SCRIPT.parent) + "/", str(job)], check=True)
            (job / "sh.env").write_text((HERE / "sherlock" / "sh.env").read_text())
            # the pack's own copy runs, beside its sh.env; support files added after the freeze are not checked
            r = self.run_submit(d, "--dry-run", script=job / "submit.sh")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("pack ok", r.stdout)
            jobs = [line.split("\t")[0] for line in r.stderr.splitlines() if "\t" in line]
            self.assertEqual(jobs, ["stage", "teacher", "merge", "student"])
            self.assertIn("--dependency=afterok:0", r.stderr)


if __name__ == "__main__":
    unittest.main()
