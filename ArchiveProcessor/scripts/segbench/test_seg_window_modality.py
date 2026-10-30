"""W46.seg-window-modality: window shapes, the text-only and w1 prompt rewrites, the combine and the vote rule, the
runner's per-request images and token limit, and the submit guard, on toy data.
Run: /usr/local/bin/python3 test_seg_window_modality.py   (no bench data, no model call, no cluster)."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import seg_window_modality as M

HERE = Path(__file__).resolve().parent
data, L, R, W, WH, SC = M._seg()


def toy(labels, name="Toy"):
    pages = [SimpleNamespace(n=i + 1, label=lab) for i, lab in enumerate(labels)]
    return SimpleNamespace(name=name, pages=pages, labels=labels, text=lambda i: f"text of page {i + 1}")


def answer(nums, new=(), conf=0.9):
    return {"pages": {n: "document" for n in nums},
            "boundaries": {x: {"decision": "new" if x in new else "continue", "confidence": conf, "cue": "c"}
                           for x in nums[:-1]}}


class Units(unittest.TestCase):
    def test_k7_offset0_is_the_bench_window(self):
        for n in range(2, 400):
            self.assertEqual(M.spans(n, 7), W.windows(n))

    def test_every_gap_judged_at_every_size_and_offset(self):
        for n in range(2, 200):
            for k in (3, 5, 7, 10):
                for o in range((k - 1) // 2):
                    s = M.spans(n, k, o)
                    self.assertEqual({i for a, b in s for i in range(a, b - 1)}, set(range(n - 1)), (n, k, o))
                    self.assertTrue(all(2 <= b - a <= k for a, b in s))

    def test_arm_names_pick_their_units(self):
        col = toy(["Folder"] + ["New", "Cont"] * 10 + ["Folder", "New", "Cont", "Cont"])
        self.assertEqual(M.units(col, "k5-t"), M.spans(25, 5))
        self.assertEqual(M.units(col, "o2-w1"), M.spans(25, 7, 2))
        self.assertEqual(M.units(col, "folder-it"), [(1, 21), (22, 25)])
        self.assertEqual(len(M.part_arms("sweep")), 8)
        self.assertEqual(len(M.vote_arms()), 6)


class Prompts(unittest.TestCase):
    def setUp(self):
        p = mock.patch.object(data, "thumbnail", return_value=Path("/nonexistent/p.jpg"))
        p.start()
        self.addCleanup(p.stop)
        self.col = toy(["New", "Cont", "New", "Cont", "New", "Cont", "New"])

    def test_text_only_changes_one_paragraph_and_sends_no_image(self):
        base, _, nums, imgs, lim = M.request(self.col, 0, 7, "k7-it")
        text, _, _, none, _ = M.request(self.col, 0, 7, "k7-t")
        self.assertEqual(imgs, nums)
        self.assertEqual(none, [])
        self.assertNotIn("images attached", text)
        self.assertIn("The photographs are not shown", text)
        self.assertNotIn("page-0001.jpg", text)
        self.assertEqual(base.split("WHAT THE STREAM CONTAINS")[1], text.split("WHAT THE STREAM CONTAINS")[1])
        self.assertEqual(lim, R.MAX_TOKENS)

    def test_w1_has_its_images_attached_not_read_from_files(self):
        p, _, nums, imgs, _ = M.request(self.col, 0, 7, "o0-w1")
        self.assertNotIn("Read tool", p)
        self.assertIn("They are attached in this order", p)
        self.assertIn("Answer from the images (do not run commands), using the OCR text", p)
        self.assertEqual(imgs, nums)

    def test_folder_token_limit_grows_with_the_unit(self):
        col = toy(["New"] + ["Cont"] * 39)
        *_, lim = M.request(col, 0, 40, "folder-it")
        self.assertEqual(lim, 40 * M.FOLDER_TOKENS_PER_PAGE)
        *_, lim = M.request(col, 0, 5, "folder-it")
        self.assertEqual(lim, R.MAX_TOKENS)

    def test_a_changed_prompt_is_refused_not_silently_kept(self):
        with self.assertRaises(ValueError):
            M.text_only("no such paragraph", [1, 2])


class Combine(unittest.TestCase):
    def test_folder_gaps_beside_photos_are_new_and_others_must_be_judged(self):
        col = toy(["Folder", "New", "Cont", "Cont", "Folder", "New", "Cont"])
        ans = {(1, 4): answer([2, 3, 4]), (5, 7): answer([6, 7])}
        judge = lambda c, a, b: ans.get((a, b))  # noqa: E731
        comb = M.combine_units(col, M.units(col, "folder-it"), judge, photo_gaps_new=True)
        self.assertEqual([g["decision"] for g in comb["gaps"]], ["new", "continue", "continue", "new", "new", "continue"])
        with self.assertRaises(RuntimeError):
            M.combine_units(col, M.units(col, "folder-it"), judge)

    def test_k7_combine_equals_the_bench_combine(self):
        col = toy(["New", "Cont", "New"] * 6)
        n = len(col.pages)

        def judge(c, a, b, allow_call=False):
            nums = [c.pages[i].n for i in range(a, b)]
            return answer(nums, new={x for x in nums if x % 3 == 0 or (a + x) % 5 == 0}, conf=0.6 + 0.05 * (a % 4))
        mine = M.combine_units(col, M.spans(n, 7), judge)
        bench = W.combine(col, judge)
        self.assertEqual([round(g["p_new"], 9) for g in mine["gaps"]], [round(g["p_new"], 9) for g in bench["gaps"]])
        self.assertEqual(mine["photo"], bench["photo"])


class Vote(unittest.TestCase):
    def comb(self, decs, ps):
        return {"gaps": [{"decision": d, "p_new": p} for d, p in zip(decs, ps)], "kind_votes": [["document"]] * 3}

    def test_majority_then_mean_on_a_tie(self):
        combs = [self.comb(["new", "new", "new"], [0.9, 0.9, 0.9])] * 3 + \
                [self.comb(["continue", "continue", "new"], [0.1, 0.4, 0.6])] * 3
        v = M.vote(combs)
        # gap 0: 3-3, mean 0.5 -> new; gap 1: 3-3, mean 0.65 -> new; gap 2: 6-0 new
        self.assertEqual([g["decision"] for g in v["gaps"]], ["new", "new", "new"])
        combs[0] = self.comb(["continue", "new", "new"], [0.2, 0.9, 0.9])
        self.assertEqual(M.vote(combs)["gaps"][0]["decision"], "continue")
        self.assertEqual(M.vote(combs)["gaps"][2]["confidence"], 1.0)


class Pooled(unittest.TestCase):
    def row(self, box, arm, pages, exact, tp, fs, fm, model="2b"):
        c = {"doc_pages": pages, "pages_exact": exact, "tp": tp, "false_splits": fs, "false_merges": fm}
        return {"model": model, "box": box, "arm": arm, "failed_units": 0, "counts": c}

    def test_pools_sum_counts_and_skip_a_cell_missing_a_box(self):
        rows = [self.row(b, "k7-it", 100, 90, 10, 1, 1) for b in M.DEV] + \
               [self.row(b, "folder-it", 100, 50, 10, 5, 5) for b in M.DEV[1:]]
        p = M.pooled(rows)
        self.assertEqual([(r["pool"], r["arm"]) for r in p], [("development", "k7-it")])
        self.assertEqual(p[0]["pages"], 300)
        self.assertAlmostEqual(p[0]["pages_exact"], 0.9)
        self.assertAlmostEqual(p[0]["boundary_f1"], 60 / 66)

    def test_mean_of_singles_needs_all_six_runs(self):
        rows = [self.row(b, arm, 100, 70 + i, 10, 2, 2) for i, arm in enumerate(M.vote_arms()) for b in ("Stanton", "RG165")]
        p = M.pooled(rows)
        mean = [r for r in p if r["arm"] == "mean-of-singles"]
        self.assertEqual(len(mean), 1)
        self.assertAlmostEqual(mean[0]["pages_exact"], 0.725)
        self.assertFalse([r for r in M.pooled(rows[2:]) if r["arm"] == "mean-of-singles"])


class Runner(unittest.TestCase):
    def test_cluster_seg_sends_only_the_named_images_at_the_named_limit(self):
        sys.path.insert(0, str(HERE / "institutional-compute"))
        import cluster_seg as CS
        with tempfile.TemporaryDirectory() as d:
            pack = Path(d)
            (pack / "images" / "B").mkdir(parents=True)
            for n in (1, 2):
                (pack / "images" / "B" / f"{n}.jpg").write_bytes(b"jpg")
            sent = []

            def send(url, body, timeout=900):
                sent.append(body)
                return {"choices": [{"message": {"content": json.dumps(
                    {"pages": [{"page": 1, "kind": "document"}, {"page": 2, "kind": "document"}],
                     "boundaries": [{"between": [1, 2], "decision": "new", "cue": "c", "confidence": 0.9}]})}}]}, "ok"
            with mock.patch.object(CS, "send", send):
                CS.read_window("u", pack, {"box": "B", "window": [1, 2], "cache_key": "k", "prompt": "p",
                                           "images": [], "max_tokens": 4000})
                CS.read_window("u", pack, {"box": "B", "window": [1, 2], "cache_key": "k", "prompt": "p"})
            imgs = [sum(c["type"] == "image_url" for c in b["messages"][0]["content"]) for b in sent]
            self.assertEqual(imgs, [0, 2])
            self.assertEqual([b["max_tokens"] for b in sent], [4000, R.MAX_TOKENS])


class Submit(unittest.TestCase):
    def test_unattended_sessions_may_only_dry_run(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "freeze.json").write_text("{}")
            r = subprocess.run(["bash", str(HERE / "sherlock/seg-window-modality/submit.sh"), d],
                               env={**os.environ, "ARCHIVE_UNATTENDED": "1"}, capture_output=True, text=True)
            self.assertEqual(r.returncode, 2)
            self.assertIn("owner-attended", r.stdout)


if __name__ == "__main__":
    unittest.main()
