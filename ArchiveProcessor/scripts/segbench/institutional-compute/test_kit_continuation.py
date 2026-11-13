#!/usr/bin/env python3
"""W46.kit-continuation: the continuation's packs and rows, on synthetic review records and images (scratch only).
Needs Pillow and numpy (`../torch-env.sh` on the Mac), as the Check tests do."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import kit_continuation as KC  # noqa: E402
import train_seg as T  # noqa: E402


def image(path: Path, i: int):
    from PIL import Image
    path.parent.mkdir(parents=True, exist_ok=True)
    import random
    # noise seeded by i: flat colours a step apart can encode to the same JPEG bytes, and so the same hash
    Image.frombytes("RGB", (30, 40), random.Random(i).randbytes(30 * 40 * 3)).save(path, "JPEG")
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Fixture(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.src = self.root / "sources"

    def tearDown(self):
        self._tmp.cleanup()

    def collection(self, name, first, n_pages, rulings, new_every=4, skip=(), cid=None, named_only=False):
        """A collection's output folder with one gaps record over source pages first..first+n_pages-1. rulings(g)
        gives gap g's ruling; every new_every-th gap is a document start; gaps in `skip` are not recorded."""
        pages = []
        for k in range(n_pages):
            p = self.src / name / f"IMG_{first + k:04d}.jpg"
            pages.append({"name": p.name, "sha256": None if named_only else image(p, first + k), "output": None})
            if named_only:
                image(p, first + k)
        gaps = []
        for g in range(n_pages - 1):
            if g in skip:
                continue
            final = "new" if g % new_every == new_every - 1 else "continue"
            r = rulings(g)
            gaps.append({"gap": g, "left": pages[g], "right": pages[g + 1], "confidence": 0.8, "flagged": r == "checked",
                         "proposed": final if r != "changed" else ("new" if final == "continue" else "continue"),
                         "final": final, "ruling": r})
        d = self.root / name / ".archivesuite" / "corrections"
        d.mkdir(parents=True)
        (d / f"gaps-run-{name}.json").write_text(json.dumps({
            "schemaVersion": 1, "kind": "gaps", "runID": f"run-{name}", "recordedAt": "2026-11-13T00:00:00Z",
            "owner": {"collectionID": cid or name, "collectionName": name}, "approach": "seg-2b", "pages": n_pages,
            "gaps": gaps}))
        return self.root / name

    def run_kc(self, *argv):
        return KC.main([str(x) for x in argv])

    def pack(self, *dirs, out="train"):
        self.run_kc("pack", *dirs, "--sources", self.src, "--text", "none", "--out", self.root / out)
        return self.root / out


class Pack(Fixture):
    def test_needs_200_gaps_ruled_by_a_person(self):
        # 199 ruled and 60 accepted: known 259, but accepted gaps do not count
        box = self.collection("a", 0, 260, lambda g: "checked" if g < 199 else "accepted")
        with self.assertRaises(SystemExit) as e:
            self.pack(box)
        self.assertIn("199 gaps ruled on by a person", str(e.exception))
        self.assertFalse((self.root / "train").exists())
        self.assertFalse((self.root / "train.tmp").exists())

    def test_200_ruled_builds_windows_of_known_gaps(self):
        box = self.collection("a", 0, 260, lambda g: "changed" if g % 3 == 0 else "checked" if g < 200 else "accepted",
                              skip={100})
        out = self.pack(box)
        meta = json.loads((out / "pack.json").read_text())
        self.assertEqual((meta["role"], meta["key"], meta["model"], meta["side"], meta["prompt_id"]),
                         ("train", "fs-seg-2b", "seg-2b", 1024, "c1"))
        self.assertEqual(meta["known_gaps"], 258)
        self.assertGreaterEqual(meta["ruled_gaps"], 200)
        wins = [json.loads(l) for l in (out / "windows.jsonl").read_text().splitlines()]
        # gap 100 (pages 101|102) was not recorded: no window spans it, and every window gap is a known one
        truth = {(t["folder_id"], t["n"]) for t in map(json.loads, (out / "truth.jsonl").read_text().splitlines())}
        for w in wins:
            self.assertFalse(101 in w["window"] and 102 in w["window"])
            self.assertTrue(all((w["box"], n) in truth for n in w["window"][:-1]))
            self.assertIn(f"--- page {w['window'][0]} ---\n(no text found)", w["prompt"])
        covered = {(w["box"], n) for w in wins for n in w["window"][:-1]}
        self.assertEqual(covered, truth)
        from PIL import Image
        n = wins[0]["window"][0]
        self.assertTrue((out / "images" / wins[0]["box"] / f"{n}.jpg").is_file())
        with Image.open(out / "images" / wins[0]["box"] / f"{n}.jpg") as im:
            self.assertLessEqual(max(im.size), 1024)

    def test_sources_are_found_by_hash_whatever_their_name(self):
        box = self.collection("a", 0, 210, lambda g: "checked")
        moved = self.root / "elsewhere"
        os.rename(self.src, moved)
        for i, p in enumerate(sorted((moved / "a").iterdir())):
            p.rename(p.with_name(f"renamed-{i}.jpg"))
        self.run_kc("pack", box, "--sources", moved, "--text", "none", "--out", self.root / "train")
        self.assertEqual(json.loads((self.root / "train" / "pack.json").read_text())["pages"], 210)

    def test_a_page_with_no_source_splits_the_run_and_can_lose_the_floor(self):
        box = self.collection("a", 0, 202, lambda g: "checked")
        (self.src / "a" / "IMG_0050.jpg").unlink()
        with self.assertRaises(SystemExit) as e:
            self.pack(box)
        self.assertIn("have both pages in --sources", str(e.exception))
        self.assertIn("IMG_0050.jpg", str(e.exception))

    def test_a_photo_tagged_to_turn_goes_in_upright(self):
        from PIL import Image
        p = self.src / "x.jpg"
        p.parent.mkdir(parents=True)
        exif = Image.Exif()
        exif[0x0112] = 6                      # rotate 90 CW to display, as an iPhone portrait photo is stored
        Image.new("RGB", (400, 200), (10, 20, 30)).save(p, "JPEG", exif=exif.tobytes())
        import io
        with Image.open(io.BytesIO(KC.upright_jpeg(p))) as im:
            self.assertEqual(im.size, (200, 400))
        (self.src / "bad.heic").write_bytes(b"not an image")
        self.assertIsNone(KC.upright_jpeg(self.src / "bad.heic"))

    def test_pdf_text_needs_pdftotext(self):
        box = self.collection("a", 0, 210, lambda g: "checked")
        found, KC.pdftotext = KC.pdftotext, lambda: None
        try:
            with self.assertRaises(SystemExit) as e:
                self.run_kc("pack", box, "--sources", self.src, "--out", self.root / "train")
            self.assertIn("brew install poppler", str(e.exception))
            self.assertFalse((self.root / "train.tmp").exists())
        finally:
            KC.pdftotext = found

    def test_several_materials_need_one_named(self):
        a = self.collection("a", 0, 210, lambda g: "checked")
        b = self.collection("b", 500, 20, lambda g: "checked")
        with self.assertRaises(SystemExit) as e:
            self.pack(a, b)
        self.assertIn("--material", str(e.exception))
        self.run_kc("pack", a, b, "--sources", self.src, "--text", "none", "--material", "a", "--out", self.root / "t")
        self.assertEqual(json.loads((self.root / "t" / "pack.json").read_text())["material"], "a")

    def test_the_output_pdf_text_page_is_read_after_its_header(self):
        fake = self.root / "bin"
        fake.mkdir()
        tool = fake / "pdftotext"
        tool.write_text("#!/bin/sh\nprintf 'Extracted text.\\nIMG.jpg\\nGemini · Flash · 1 May 2026\\n\\n"
                        "Dear Sir,\\nthe letter body\\n\\f'\n")
        tool.chmod(tool.stat().st_mode | stat.S_IEXEC)
        (self.root / "out").mkdir()
        (self.root / "out" / "IMG.pdf").write_bytes(b"%PDF-1.4")
        old = os.environ["PATH"]
        os.environ["PATH"] = f"{fake}:{old}"
        try:
            self.assertEqual(KC.pdf_text(self.root / "out", "IMG.pdf"), "Dear Sir,\nthe letter body")
            self.assertIsNone(KC.pdf_text(self.root / "out", "missing.pdf"))
            tool.write_text("#!/bin/sh\nprintf 'Extracted text.\\nx · y · z\\n\\nNo text returned by model.\\n\\nError'\n")
            self.assertEqual(KC.pdf_text(self.root / "out", "IMG.pdf"), "")
            tool.write_text("#!/bin/sh\nprintf 'Some other page\\n\\nbody'\n")
            self.assertIsNone(KC.pdf_text(self.root / "out", "IMG.pdf"))
        finally:
            os.environ["PATH"] = old


class Heldout(Fixture):
    def setUp(self):
        super().setUp()
        self.train = self.pack(self.collection("a", 0, 210, lambda g: "checked"))

    def heldout(self, *dirs, out="held"):
        self.run_kc("heldout", *dirs, "--sources", self.src, "--text", "none", "--train", self.train,
                    "--out", self.root / out)
        return self.root / out

    def test_the_gate_minimum_is_checked_before_a_cluster_hour(self):
        small = self.collection("b", 1000, 200, lambda g: "accepted")
        with self.assertRaises(SystemExit) as e:
            self.heldout(small)
        self.assertIn(f"199 known gaps; the gate needs at least {T.MIN_KNOWN_GAPS}", str(e.exception))
        self.assertFalse((self.root / "held").exists())

    def test_few_long_documents_are_refused(self):
        long_docs = self.collection("c", 2000, 300, lambda g: "checked", new_every=40)
        with self.assertRaises(SystemExit) as e:
            self.heldout(long_docs)
        self.assertIn(f"documents; the gate needs at least {T.MIN_DOCUMENTS}", str(e.exception))

    def test_pages_the_continuation_trained_on_are_refused(self):
        again = self.collection("d", 0, 300, lambda g: "checked")   # the same source images as box a
        with self.assertRaises(SystemExit) as e:
            self.heldout(again)
        self.assertIn("are in the training pack", str(e.exception))

    def test_the_request_must_be_the_one_trained_on(self):
        nxt = self.collection("e", 3000, 290, lambda g: "checked")
        with self.assertRaises(SystemExit) as e:
            self.run_kc("heldout", nxt, "--sources", self.src, "--text", "pdf", "--train", self.train,
                        "--out", self.root / "held")
        self.assertIn("training pack was built with --text none", str(e.exception))

    def test_a_next_box_writes_what_check_reads(self):
        nxt = self.collection("e", 3000, 290, lambda g: "changed" if g % 7 == 0 else "accepted" if g % 2 else "checked")
        out = self.heldout(nxt)
        meta = json.loads((out / "pack.json").read_text())
        self.assertEqual((meta["role"], meta["known_gaps"]), ("heldout", 289))
        self.assertGreaterEqual(meta["documents"], T.MIN_DOCUMENTS)
        labels = [json.loads(l) for l in (out / "labels.jsonl").read_text().splitlines()]
        ruled = (out / "ruled.csv").read_text().splitlines()
        self.assertEqual(len(ruled), sum(1 for g in range(289) if g % 7 == 0 or not g % 2))
        self.assertTrue(all(x.split(",")[2] in ("new", "same") for x in ruled))
        # answers as cluster_seg.py run writes them, from the pack's own windows: run_votes keys every label
        wins = [json.loads(l) for l in (out / "windows.jsonl").read_text().splitlines()]
        run = self.root / "run"
        run.mkdir()
        with open(run / "answers.jsonl", "w") as f:
            for w in wins:
                nums = w["window"]
                reply = {"pages": [{"page": n, "kind": "document"} for n in nums],
                         "boundaries": [{"between": [x, x + 1], "decision": "continue", "cue": "c", "confidence": 0.7}
                                        for x in nums[:-1]]}
                f.write(json.dumps({"cache_key": w["cache_key"], "collection": w["box"], "window": nums,
                                    "status": "ok", "result": json.dumps(reply)}) + "\n")
        votes, failed = T.run_votes([run])
        self.assertEqual(failed, 0)
        self.assertEqual({(g["folder_id"], g["n"]) for g in labels}, set(votes))
        tags, own = T.heldout_groups(labels, {}, votes, votes)
        self.assertEqual(sum(len(d) for docs in tags.values() for d in docs), 289)


class Rows(Fixture):
    def setUp(self):
        super().setUp()
        self.train = self.pack(self.collection("a", 0, 210, lambda g: "changed" if g % 2 else "checked"))
        self.wins = [json.loads(l) for l in (self.train / "windows.jsonl").read_text().splitlines()]

    def answers(self, decide, broken=(), kind="document"):
        path = self.root / "answers.jsonl"
        with open(path, "w") as f:
            for i, w in enumerate(self.wins):
                nums = w["window"]
                reply = {"pages": [{"page": n, "kind": kind} for n in nums],
                         "boundaries": [{"between": [x, x + 1], "decision": decide(x), "cue": "2B", "confidence": 0.6}
                                        for x in nums[:-1]]}
                f.write(json.dumps({"cache_key": w["cache_key"], "collection": w["box"], "window": nums,
                                    "status": "ok", "result": "not json" if i in broken else json.dumps(reply)}) + "\n")
        return path

    def test_targets_carry_the_persons_calls(self):
        calls = {t["n"]: t["final"] for t in map(json.loads, (self.train / "truth.jsonl").read_text().splitlines())}
        self.run_kc("rows", "--pack", self.train, "--answers", self.answers(lambda x: "continue", broken={0}),
                    "--no-replay", "--out", self.root / "data")
        data = json.loads((self.root / "data" / "data.json").read_text())
        self.assertEqual((data["corrections"], data["replay"], data["measured_recipe"]), (len(self.wins) - 1, 0, False))
        self.assertEqual(data["dropped"]["reply not usable"], 1)
        self.assertIn("not the measured recipe", data["note"])
        rows = [json.loads(l) for l in (self.root / "data" / "train.jsonl").read_text().splitlines()]
        for r in rows:
            for bd in json.loads(r["target"])["boundaries"]:
                x = bd["between"][0]
                self.assertEqual(bd["decision"], calls[x])
                want = ("corrected by the reviewer", 0.95) if calls[x] == "new" else ("2B", 0.6)
                self.assertEqual((bd["cue"], bd["confidence"]), want)
        self.assertGreater(data["flipped_decisions"], 0)
        # train_seg.py train reads images/<box>/<n>.jpg below data.json's images
        img = Path(data["images"])
        self.assertTrue(all((img / r["box"] / f"{n}.jpg").is_file() for r in rows for n in r["window"]))

    def test_the_targets_parse_as_the_cluster_counted_them(self):
        nums = [4, 5, 6]
        calls = {4: "new", 5: "continue"}
        fenced = "```json\n" + json.dumps({"pages": [{"page": "4", "kind": "folder"}, {"page": 5, "kind": "document"},
                                                     {"page": 6, "kind": "document"}],
                                           "boundaries": [{"between": ["4", "5"], "decision": "continue", "cue": "x",
                                                           "confidence": 0.9},
                                                          {"between": [5, 6], "decision": "continue", "cue": "y",
                                                           "confidence": 0.8}]}) + "\n```"
        target, flips = KC.corrected(fenced, nums, calls)
        obj = json.loads(target)
        self.assertEqual(flips, 1)
        self.assertEqual([p["kind"] for p in obj["pages"]], ["document"] * 3)
        self.assertEqual([b["between"] for b in obj["boundaries"]], [[4, 5], [5, 6]])
        self.assertEqual(obj["boundaries"][0]["cue"], "corrected by the reviewer")
        nested = json.dumps({"pages": [{"page": n, "kind": "document"} for n in nums],
                             "boundaries": [{"between": [[4], [5]], "decision": "new"}]})
        self.assertIsNone(KC.corrected(nested, nums, calls))

    def test_too_few_usable_answers_are_refused(self):
        with self.assertRaises(SystemExit) as e:
            self.run_kc("rows", "--pack", self.train, "--answers",
                        self.answers(lambda x: "new", broken=set(range(len(self.wins))) - set(range(0, len(self.wins), 4))),
                        "--no-replay",
                        "--out", self.root / "data")
        self.assertIn("rerun the shipped 2B", str(e.exception))
        self.assertFalse((self.root / "data").exists())

    def test_replay_is_three_corpus_windows_a_correction(self):
        corpus = self.root / "corpus"
        for n in range(7):
            image(corpus / "images" / "F1" / f"{n}.jpg", 9000 + n)
        rows = []
        for i in range(400):
            rows.append({"box": "F1", "window": list(range(0, 7)), "prompt": f"p{i}", "target": "t",
                         "text": "none" if i % 4 else "abbyy"})
        rows.append({"box": "F1", "window": [0, 1], "prompt": "ABBYY text: x", "target": "t", "text": "none"})
        (corpus / "train.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
        # train_seg.py data records the images folder as given, often relative to where it ran
        (corpus / "data.json").write_text(json.dumps({"windows": len(rows), "images": "images"}))
        self.run_kc("rows", "--pack", self.train, "--answers", self.answers(lambda x: "new", kind="folder"),
                    "--replay", corpus, "--out", self.root / "data")
        data = json.loads((self.root / "data" / "data.json").read_text())
        self.assertEqual(data["replay"], min(3 * data["corrections"], 300))
        self.assertTrue(data["measured_recipe"])
        got = [json.loads(l) for l in (self.root / "data" / "train.jsonl").read_text().splitlines()]
        self.assertFalse(any(r.get("text") == "abbyy" or "ABBYY" in r["prompt"] for r in got))
        self.assertTrue((self.root / "data" / "images" / "F1" / "0.jpg").is_file())
        mine = [r for r in got if r["box"] != "F1"]
        self.assertTrue(all(p["kind"] == "document" for r in mine for p in json.loads(r["target"])["pages"]))

    def test_a_held_out_pack_is_not_a_training_pack(self):
        bogus = self.root / "bogus"
        bogus.mkdir()
        (bogus / "pack.json").write_text(json.dumps({"role": "heldout"}))
        with self.assertRaises(SystemExit):
            self.run_kc("rows", "--pack", bogus, "--answers", self.answers(lambda x: "new"), "--no-replay",
                        "--out", self.root / "data")


if __name__ == "__main__":
    unittest.main()
