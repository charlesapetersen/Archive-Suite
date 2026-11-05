#!/usr/bin/env python3
"""Tests for the cluster side's data preparation (synthetic AnnoPage tree and SignverOD parquet; no download)."""
import io
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

import marks_detect_cluster as C


class ClassMap(unittest.TestCase):
    def test_map(self):
        self.assertEqual(C.anno_class_map(["Image", "Handwritten inscription", "Stamp", "Table"]), {1: 0, 2: 1})

    def test_refuses_ambiguous_or_missing(self):
        with self.assertRaises(SystemExit):
            C.anno_class_map(["Handwritten inscription", "Handwritten signature", "Stamp"])
        with self.assertRaises(SystemExit):
            C.anno_class_map(["Image", "Stamp"])


class AnnoPage(unittest.TestCase):
    def test_prep(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            z = d / "AnnoPage_Dataset.zip"
            with zipfile.ZipFile(z, "w") as f:
                f.writestr("AnnoPage/data.yaml", "names:\n  0: Image\n  1: Handwritten inscription\n  2: Stamp\n")
                for sp, stem, lab in (("train", "a", "1 0.5 0.5 0.1 0.1\n0 0.2 0.2 0.1 0.1\n"),
                                      ("train", "b", "0 0.3 0.3 0.1 0.1\n"), ("val", "c", "2 0.5 0.5 0.2 0.2\n"),
                                      ("train", "e", "0 0.1 0.1 0.1 0.1\n")):
                    f.writestr(f"AnnoPage/images/{sp}/{stem}.jpg", b"x")
                    f.writestr(f"AnnoPage/labels/{sp}/{stem}.txt", lab)
                f.writestr("AnnoPage/images/train/d.jpg", b"x")      # no label file: unpaired
            out, log = d / "yolo", {}
            C.prep_annopage(z, d, out, log)
            a = log["annopage"]
            self.assertEqual((a["positive_pages"], a["negative_pages_seen"], a["negative_pages_kept"],
                              a["unpaired_images"]), (2, 2, 2, 1))
            self.assertEqual(a["boxes"], {"handwritten": 1, "stamp": 1})
            self.assertEqual((out / "labels/train/anno-train-a.txt").read_text(), "0 0.5 0.5 0.1 0.1\n")
            self.assertEqual((out / "labels/val/anno-val-c.txt").read_text(), "1 0.5 0.5 0.2 0.2\n")
            self.assertEqual((out / "labels/train/anno-train-b.txt").read_text(), "")


class SignverOD(unittest.TestCase):
    def test_prep(self):
        try:
            import pyarrow as pa
            import pyarrow.parquet as pq
            from PIL import Image
        except ImportError:
            self.skipTest("pyarrow/PIL not installed")
        buf = io.BytesIO()
        Image.new("RGB", (200, 100), "white").save(buf, "JPEG")
        rows = [dict(image=dict(bytes=buf.getvalue(), path=None), width=200.0, height=100.0, image_id=i,
                     objects=dict(id=[1, 2], area=[1.0, 1.0], bbox=[[20.0, 10.0, 40.0, 20.0], [190.0, 90.0, 30.0, 30.0]],
                                  category=[1, 4])) for i in range(10)]
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            pq.write_table(pa.Table.from_pylist(rows), d / "s.parquet")
            out, log = d / "yolo", {}
            C.prep_signver([d / "s.parquet"], out, log)
            self.assertEqual(log["signverod"]["val"], 1)
            lab = sorted((out / "labels").rglob("*.txt"))[0].read_text().splitlines()
            self.assertEqual(lab[0], "2 0.200000 0.200000 0.200000 0.200000")
            # The second box is clipped to the page: x 190-200, y 90-100.
            self.assertEqual(lab[1], "5 0.975000 0.950000 0.050000 0.100000")


if __name__ == "__main__":
    unittest.main()
