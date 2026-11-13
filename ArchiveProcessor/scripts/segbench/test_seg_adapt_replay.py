#!/usr/bin/env python3
"""W46.kit-continuation-replay: the public replay rows, on a synthetic TABME++ pack (scratch only, stdlib)."""
from __future__ import annotations
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import seg_adapt_replay as R  # noqa: E402


def reply(nums, decisions):
    pages = [{"page": n, "kind": "document"} for n in nums]
    bounds = [{"between": [a, b], "decision": d, "cue": "x", "confidence": 0.9}
              for (a, b), d in zip(zip(nums, nums[1:]), decisions)]
    return json.dumps({"pages": pages, "boundaries": bounds})


class PublicRows(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        # 10 pages; documents start at 1, 4 and 8
        labels = ["New" if n in (1, 4, 8) else "Cont" for n in range(1, 11)]
        (self.root / "stream.json").write_text(json.dumps({"pages": [{"n": n, "label": l}
                                                                     for n, l in enumerate(labels, 1)]}))
        pack = self.root / "2b-it"
        pack.mkdir()
        (pack / "pack.json").write_text(json.dumps({"key": "fs-seg-2b", "boxes": ["TABME"], "pages": 10,
                                                    "made": "t"}))
        self.wins = [[1, 2, 3, 4], [4, 5, 6, 7], [7, 8, 9, 10]]
        (pack / "windows.jsonl").write_text("".join(
            json.dumps({"box": "TABME", "window": w, "cache_key": f"k{i}", "prompt": f"p{i}"}) + "\n"
            for i, w in enumerate(self.wins)))
        runs = self.root / "runs" / "2b-it"
        runs.mkdir(parents=True)
        ans = [{"cache_key": "k0", "status": "ok", "result": reply(self.wins[0], ["continue", "continue", "continue"])},
               {"cache_key": "k1", "status": "ok", "result": reply(self.wins[1], ["continue", "new", "continue"])},
               {"cache_key": "k2", "status": "error", "result": ""}]
        (runs / "answers.jsonl").write_text("".join(json.dumps(a) + "\n" for a in ans))

    def tearDown(self):
        self.tmp.cleanup()

    def test_targets_set_to_the_public_truth(self):
        rows, skipped, _ = R.public_rows(self.root, 2)
        self.assertLessEqual(skipped["not answered"], 1)       # k2 failed: skipped only if drawn before the two
        by = {tuple(r["window"]): r for r in rows}
        self.assertEqual(set(by), {(1, 2, 3, 4), (4, 5, 6, 7)})
        first = json.loads(by[(1, 2, 3, 4)]["target"])
        self.assertEqual([b["decision"] for b in first["boundaries"]], ["continue", "continue", "new"])
        self.assertEqual(by[(1, 2, 3, 4)]["flips"], 1)
        second = json.loads(by[(4, 5, 6, 7)]["target"])     # its wrong "new" at 5|6 corrected
        self.assertEqual([b["decision"] for b in second["boundaries"]], ["continue", "continue", "continue"])
        self.assertTrue(all(r["box"] == "TABME" for r in rows))

    def test_refuses_when_too_few_usable(self):
        with self.assertRaises(SystemExit):
            R.public_rows(self.root, 3)                    # k2 failed, so only two are usable

    def test_refuses_another_pack(self):
        (self.root / "2b-it" / "pack.json").write_text(json.dumps({"key": "other", "boxes": ["TABME"], "pages": 10}))
        with self.assertRaises(SystemExit):
            R.public_rows(self.root, 1)


if __name__ == "__main__":
    unittest.main()
