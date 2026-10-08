#!/usr/bin/env python3
"""Tests for corpus_survey.py on hand-made tag streams (no corpus access). python3 test_corpus_survey.py"""
import os
import plistlib
import subprocess
import tempfile
import unittest

import corpus_survey as cs

DOC_A = ["1951", "09 September", "Manufacturing", "Unread"]
DOC_B = ["1951", "10 October", "Manufacturing", "Unread"]


class Analyse(unittest.TestCase):
    def test_boundaries_continuations_and_label_photos(self):
        photos = [("1", ["Red"]), ("2", DOC_A), ("3", DOC_A), ("4", DOC_B), ("5", ["Purple", "Unread"]),
                  ("6", DOC_B), ("7", DOC_B + ["Blue"])]
        m, pairs = cs.analyse(photos)
        self.assertEqual((m["labels"], m["pages"]), (2, 5))
        # 2-3 same, 3-4 change; the label photo 5 breaks 4-6; 6-7 same (colours ignored)
        self.assertEqual(pairs, [("2", "3", False), ("3", "4", True), ("6", "7", False)])
        self.assertEqual(m["docs"], 3)          # A, B, then B again after the folder card
        self.assertAlmostEqual(m["change"], 1 / 3)
        self.assertEqual(m["year"], 1.0)

    def test_unread_alone_is_untagged(self):
        m, _ = cs.analyse([(str(i), ["Unread"]) for i in range(10)])
        self.assertEqual(m["class"], "untagged")

    def test_classes(self):
        base = {"pages": 50, "tagged": 1.0, "year": 1.0}
        self.assertEqual(cs.classify({**base, "pages": 4, "change": .5}), "small")
        self.assertEqual(cs.classify({**base, "change": .02}), "per-collection")
        self.assertEqual(cs.classify({**base, "change": .5}), "per-document")
        self.assertEqual(cs.classify({**base, "change": .5, "year": .2}), "mixed")
        self.assertEqual(cs.classify({**base, "change": .05}), "mixed")

    def test_order_is_by_file_number(self):
        names = ["00010 — x.pdf", "00002 — x.pdf", "notes.pdf", "00100 — x.pdf"]
        self.assertEqual(sorted(names, key=cs.order_key),
                         ["00002 — x.pdf", "00010 — x.pdf", "00100 — x.pdf", "notes.pdf"])


class Tags(unittest.TestCase):
    def test_reads_finder_tags_from_xattr(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "00001 — t.pdf")
            open(p, "w").close()
            self.assertEqual(cs.read_tags(p), [])
            blob = plistlib.dumps(["Unread", "Purple\n3", "1951"], fmt=plistlib.FMT_BINARY)
            subprocess.run(["xattr", "-wx", cs.XATTR.decode(), blob.hex(), p], check=True)
            self.assertEqual(cs.read_tags(p), ["Unread", "Purple", "1951"])


class Score(unittest.TestCase):
    def test_score(self):
        key = [{"id": "c01", "implied": "new"}, {"id": "c02", "implied": "new"},
               {"id": "c03", "implied": "same"}, {"id": "c04", "implied": "same"}]
        res = cs.score(key, {"c01": "new", "c02": "same", "c03": "unsure"})
        self.assertEqual(res, {"new": [1, 1, 0], "same": [0, 0, 1]})


if __name__ == "__main__":
    unittest.main()
