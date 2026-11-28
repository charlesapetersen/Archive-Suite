#!/usr/bin/env python3
"""$0 unit tests for W46.marks-detect-own Colab pack builder and cluster check (synthetic data only)."""
from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import marks_detect_own_cluster as MC  # noqa: E402
import marks_detect_own_pack as MP  # noqa: E402


def _write_jpg(path: Path) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", (200, 300), "white").save(path, "JPEG")
    return hashlib.sha256(path.read_bytes()).hexdigest()


class MarksDetectOwnPackTests(unittest.TestCase):
    def test_build_pack_agreement_split_and_zero_core_leakage(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            ms = t / "marks-set"
            scan = t / "scan"
            pub = t / "public-pack"
            out = t / "out-pack"
            (ms / "gemini" / "replies").mkdir(parents=True)
            (ms / "qwen3-vl-8b-mlx4").mkdir(parents=True)
            (pub / "runs" / "public").mkdir(parents=True)
            (pub / "eval" / "images").mkdir(parents=True)
            (pub / "runs" / "public" / "best.pt").write_bytes(b"fake-yolo-weights")

            # 1 core eval page + 5 non-core pages (2 pos agreed, 2 clean neg, 1 unagreed-only)
            rows = [{"id": "core01", "core": True}] + [
                {"id": f"nc0{i}", "core": False} for i in range(1, 6)
            ]
            (ms / "selection.json").write_text(json.dumps({"rows": rows}))

            eval_sha = _write_jpg(pub / "eval" / "images" / "core01.jpg")
            (pub / "eval" / "pages.json").write_text(json.dumps(["core01"]))
            (pub / "freeze.json").write_text(json.dumps({"images": {"core01": eval_sha}}))
            for i in range(1, 6):
                _write_jpg(scan / "images" / f"nc0{i}.jpg")

            def write_pair(pid: str, g_marks: list[dict], q_marks: list[dict]):
                (ms / "gemini" / "replies" / f"{pid}.json").write_text(
                    json.dumps({"raw": json.dumps({"page_kind": "typed_printed", "marks": g_marks, "handwriting_amount": "none"})})
                )
                (ms / "qwen3-vl-8b-mlx4" / f"{pid}.json").write_text(
                    json.dumps({"raw": json.dumps({"page_kind": "typed_printed", "marks": q_marks, "handwriting_amount": "none"}),
                                "tokens": [10, 20], "wall_s": 1.0})
                )

            # core01: 2 truth marks; both agree on 1, both miss 1
            write_pair("core01",
                       [{"class": "stamp", "box_2d": [100, 200, 200, 400]}],
                       [{"class": "stamp", "bbox_2d": [205, 105, 395, 195]}])
            core_truth = {
                "core01": {
                    "core": "A-core",
                    "marks": [
                        {"box": [0.20, 0.10, 0.40, 0.20], "cls": "stamp", "overlaps": False},
                        {"box": [0.70, 0.70, 0.85, 0.80], "cls": "annotation", "overlaps": True},
                    ],
                }
            }
            # nc01 & nc02: positive agreed marks
            write_pair("nc01",
                       [{"class": "annotation", "box_2d": [100, 100, 300, 400]}],
                       [{"class": "annotation", "bbox_2d": [110, 110, 390, 290]}])
            write_pair("nc02",
                       [{"class": "signature_initials", "box_2d": [600, 500, 700, 800]}],
                       [{"class": "signature_initials", "bbox_2d": [510, 605, 790, 695]}])
            # nc03 & nc04: clean negatives (both empty)
            write_pair("nc03", [], [])
            write_pair("nc04", [], [])
            # nc05: unagreed-only (only Gemini saw a mark -> must be excluded, not treated as negative)
            write_pair("nc05", [{"class": "stamp", "box_2d": [50, 50, 150, 150]}], [])

            meta = MP.build_pack(out, ms, scan, pub, iou_thr=0.30, val_frac=0.5, core_truth=core_truth)
            self.assertEqual(meta["positive_pages"], 2)
            self.assertEqual(meta["clean_negative_pages"], 2)
            self.assertEqual(meta["skipped_unagreed_only"], 1)
            self.assertEqual(meta["train_images"] + meta["val_images"], 4)
            self.assertEqual(meta["core_audit"]["both_drafters_missed_iou10"], 1)
            self.assertEqual(meta["core_audit"]["agreed_precision_on_core"], 1.0)

            # Check integrity verifier passes and refuses leakage
            summary = MC.check(out)
            self.assertEqual(summary["eval_pages"], 1)
            self.assertEqual(summary["train_images"] + summary["val_images"], 4)


if __name__ == "__main__":
    unittest.main()
