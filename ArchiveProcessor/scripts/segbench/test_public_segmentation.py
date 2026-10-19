"""Integrity failures that would silently turn public source omissions into benchmark truth."""
import copy
import hashlib
from pathlib import Path
import tempfile
import unittest

from public_segmentation import validate


class SourceIntegrity(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.pages = []
        for n in range(1, 4):
            image = self.root / f"{n}.jpg"
            image.write_bytes(f"fixture page {n}".encode())
            self.pages.append({"n": n, "id": "item", "page": n, "image": image.name,
                               "sha256": hashlib.sha256(image.read_bytes()).hexdigest(),
                               "label": "New" if n == 1 else "Cont", "reviewed": True,
                               "audit": "fixture page reviewed"})
        self.manifest = {"box": "PUBLIC", "source_documents": [{"id": "item", "pages": 3}],
                         "pages": self.pages}

    def test_complete_source(self):
        col = validate(self.manifest, self.root)
        self.assertEqual(col.labels, ["New", "Cont", "Cont"])
        self.assertEqual([p.n for p in col.pages], [1, 2, 3])

    def test_missing_final_or_middle_source_page(self):
        for index in (1, 2):
            m = copy.deepcopy(self.manifest)
            m["pages"].pop(index)
            for n, page in enumerate(m["pages"], 1):
                page["n"] = n
            with self.assertRaisesRegex(ValueError, "source pages"):
                validate(m, self.root)

    def test_reordered_or_duplicated_source_page(self):
        for values in ([1, 3, 2], [1, 2, 2]):
            m = copy.deepcopy(self.manifest)
            for page, value in zip(m["pages"], values):
                page["page"] = value
            with self.assertRaisesRegex(ValueError, "source pages"):
                validate(m, self.root)

    def test_changed_image(self):
        (self.root / "2.jpg").write_bytes(b"different image")
        with self.assertRaisesRegex(ValueError, "image changed"):
            validate(self.manifest, self.root)

    def test_unreviewed_page(self):
        self.pages[1]["reviewed"] = False
        with self.assertRaisesRegex(ValueError, "audited"):
            validate(self.manifest, self.root)

    def test_escaping_image_path(self):
        self.pages[1]["image"] = "../outside.jpg"
        with self.assertRaisesRegex(ValueError, "within the public cache"):
            validate(self.manifest, self.root)


if __name__ == "__main__":
    unittest.main()
