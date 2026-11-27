#!/usr/bin/env python3
"""$0 unit tests for ArchiveProcessor/scripts/segbench/colab/colab_pack.py."""
from pathlib import Path
import hashlib
import json
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import colab_pack as C  # noqa: E402


class ColabPackTests(unittest.TestCase):
    def test_stage_datasets_rewrites_and_verifies_sha256(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            pub_imgs = t / "pub_imgs"
            t99_imgs = t / "t99_imgs"
            mf895 = t / "mf895"
            mf96 = t / "mf96"
            dest = t / "dest"
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
            self.assertTrue((dest / "packs/art-pack/colab_support/family_run.py").is_file())

            res = t / "drive-res"
            (res / "895/demo").mkdir(parents=True)
            (res / "895/demo/status.json").write_text('{"state":"done"}\n')
            rc2 = C.main(["fetch", str(res), "W46.test", "--artifact", str(art), "--no-release"])
            self.assertEqual(rc2, 0)
            self.assertTrue((art / "895/demo/status.json").is_file())

            # Differing file collision refuses release
            (res / "895/demo/status.json").write_text('{"state":"changed"}\n')
            with self.assertRaises(SystemExit):
                C.main(["fetch", str(res), "W46.test", "--artifact", str(art), "--no-release"])


if __name__ == "__main__":
    unittest.main()
