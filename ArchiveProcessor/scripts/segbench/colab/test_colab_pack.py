#!/usr/bin/env python3
"""$0 unit tests for ArchiveProcessor/scripts/segbench/colab/colab_pack.py and run_pack.ipynb."""
from __future__ import annotations

import ast
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import colab_pack as C  # noqa: E402


class ColabPackTests(unittest.TestCase):
    def test_stage_datasets_rewrites_and_verifies_sha256(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            pub_imgs, t99_imgs, mf895, mf96, dest = t / "pub_imgs", t / "t99_imgs", t / "mf895", t / "mf96", t / "dest"
            for d in (pub_imgs, t99_imgs, mf895, mf96):
                d.mkdir()

            p_bytes = b"public-image-bytes"
            o_bytes = b"owner-image-bytes"
            (pub_imgs / "a.jpg").write_bytes(p_bytes)
            (t99_imgs / "p001.jpg").write_bytes(o_bytes)

            pub_row = {"id": "a", "image": "/scratch/users/cp1/fs-ocr/interactive-20261019/ocr/images/a.jpg",
                       "sha256": hashlib.sha256(p_bytes).hexdigest()}
            t99_row = {"id": "p001", "image": "/home/users/cp1/fs-truthpack/images/p001.jpg",
                       "sha256": hashlib.sha256(o_bytes).hexdigest()}
            (mf895 / "public895.jsonl").write_text(json.dumps(pub_row) + "\n")
            (mf895 / "pilot3.jsonl").write_text(json.dumps(pub_row) + "\n")
            (mf96 / "truth99.jsonl").write_text(json.dumps(t99_row) + "\n")
            (mf96 / "pilot3.jsonl").write_text(json.dumps(t99_row) + "\n")

            rc = C.main([
                "stage-datasets",
                "--dest", str(dest),
                "--public-images", str(pub_imgs),
                "--truth-images", str(t99_imgs),
                "--manifests-895", str(mf895),
                "--manifests-96", str(mf96),
            ])
            self.assertEqual(rc, 0)
            out_pub = json.loads((dest / "datasets/public895/public895.jsonl").read_text().strip())
            self.assertEqual(out_pub["image"], "/content/drive/MyDrive/ArchiveSuite-Colab/datasets/public895/images/a.jpg")
            out_t99 = json.loads((dest / "datasets/truth99/truth99.jsonl").read_text().strip())
            self.assertEqual(out_t99["image"], "/content/drive/MyDrive/ArchiveSuite-Colab/datasets/truth99/images/p001.jpg")
            self.assertTrue((dest / "run_pack.ipynb").is_file())

    def test_stage_datasets_refuses_sha256_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            imgs = t / "imgs"
            imgs.mkdir()
            (imgs / "a.jpg").write_bytes(b"wrong-bytes")
            mf = t / "public895.jsonl"
            mf.write_text(json.dumps({"id": "a", "image": "/x/a.jpg", "sha256": "0" * 64}) + "\n")
            with self.assertRaises(SystemExit):
                C.rewrite_manifest(mf, t / "out.jsonl", imgs, "/drive/images")

    def test_pack_discovers_nested_candidates_and_bundles_all_support(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            art = t / "rerun-pack"
            nested = art / "support/sherlock/family-coverage"
            nested.mkdir(parents=True)
            (nested / "candidates-family-20261117.json").write_text(
                json.dumps([{"key": "mineru25-pro", "adapter": "mineru", "pip": ["mineru-vl-utils"]}]) + "\n"
            )
            dest = t / "dest"
            rc = C.main(["pack", str(art), "--dest", str(dest)])
            self.assertEqual(rc, 0)
            out = dest / "packs/rerun-pack"
            self.assertTrue((out / "candidates.json").is_file())
            meta = json.loads((out / "colab-pack.json").read_text())
            self.assertEqual(meta["pack_type"], "vllm-ocr")
            self.assertTrue(meta["needs_mineru"])
            for mod in ("colab_prepare.py", "family_run.py", "family_setup.py", "boxes_setup.py", "prompt_source.py"):
                self.assertTrue((out / "colab_support" / mod).is_file(), mod)

    def test_pack_and_fetch_no_clobber(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            art = t / "art-pack"
            art.mkdir()
            (art / "candidates.json").write_text("[]\n")
            dest = t / "dest"
            rc = C.main(["pack", str(art), "--dest", str(dest)])
            self.assertEqual(rc, 0)
            self.assertTrue((dest / "packs/art-pack/colab-pack.json").is_file())

            res = t / "drive-res"
            (res / "895/demo").mkdir(parents=True)
            (res / "895/demo/status.json").write_text('{"state":"done"}\n')
            rc2 = C.main(["fetch", str(res), "W46.test", "--artifact", str(art), "--no-release"])
            self.assertEqual(rc2, 0)
            self.assertTrue((art / "895/demo/status.json").is_file())

            (res / "895/demo/status.json").write_text('{"state":"changed"}\n')
            with self.assertRaises(SystemExit):
                C.main(["fetch", str(res), "W46.test", "--artifact", str(art), "--no-release"])

    def test_run_pack_notebook_cells_parse_as_valid_python(self):
        nb = json.loads((HERE / "run_pack.ipynb").read_text(encoding="utf-8"))
        code_cells = [c for c in nb["cells"] if c.get("cell_type") == "code"]
        self.assertGreaterEqual(len(code_cells), 4)
        for i, cell in enumerate(code_cells):
            src = "".join(cell["source"])
            ast.parse(src, filename=f"run_pack.ipynb#cell{i}")


if __name__ == "__main__":
    unittest.main()
