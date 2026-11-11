#!/usr/local/bin/python3
"""Tests for ocr_truth.py on hand-made tags and readings (no corpus access). /usr/local/bin/python3 test_ocr_truth.py"""
import unittest

import ocr_truth as T


class Strata(unittest.TestCase):
    def test_date_bins(self):
        self.assertEqual(T.date_bin(["1899", "Reports"]), "before 1900")
        self.assertEqual(T.date_bin(["1949"]), "1900-1949")
        self.assertEqual(T.date_bin(["1950"]), "1950-1984")
        self.assertEqual(T.date_bin(["1985"]), "1985 on")
        self.assertEqual(T.date_bin(["1970s"]), "1950-1984")
        self.assertEqual(T.date_bin(["1880s"]), "before 1900")
        self.assertEqual(T.date_bin(["Date Uncertain"]), "undated")
        self.assertEqual(T.date_bin(["Unread", "P10"]), "undated")
        self.assertEqual(T.date_bin(["1990", "1948"]), "1900-1949")   # the earliest of several
        self.assertEqual(T.date_bin(["1970s", "1982"]), "1950-1984")  # a year wins over a decade

    def test_kinds(self):
        self.assertEqual(T.strata(["1960", "Handwritten", "Statistics"]), ["1950-1984", "handwritten", "tables"])
        self.assertEqual(T.strata(["Clippings"]), ["undated", "clippings"])
        self.assertEqual(T.strata(["Salary Data", "1975"]), ["1950-1984", "tables"])


class Documents(unittest.TestCase):
    def test_runs_and_labels(self):
        photos = [("1", ["Red"]), ("2", ["1960", "Unread"]), ("3", ["1960", "Read"]), ("4", ["1961"]),
                  ("5", ["Purple"]), ("6", ["1961"])]
        docs = T.documents("f", photos)
        self.assertEqual([[n for n, _ in d] for d in docs], [["2", "3"], ["4"], ["6"]])

    def test_long_run_cut_into_blocks(self):
        photos = [(str(i), ["Stanford"]) for i in range(T.LONG_RUN + 1)]
        docs = T.documents("f", photos)
        self.assertEqual([len(d) for d in docs], [T.BLOCK, T.BLOCK, 1])

    def test_run_at_the_limit_kept_whole(self):
        photos = [(str(i), ["Stanford"]) for i in range(T.LONG_RUN)]
        self.assertEqual([len(d) for d in T.documents("f", photos)], [T.LONG_RUN])


class Tertile(unittest.TestCase):
    def test_ordinary(self):
        self.assertEqual([T.tertile(v, [10, 20]) for v in (5, 10, 19, 20, 30)], [0, 1, 1, 2, 2])

    def test_one_dominant_value(self):
        self.assertEqual([T.tertile(v, [2592, 2592]) for v in (1296, 2592, 4032)], [0, 1, 2])


class Drafts(unittest.TestCase):
    def test_parse(self):
        d = T.parse_draft("KIND: Typewritten\nTABLE: no\nTEXT:\nDear Harvey:\n  When time permits")
        self.assertEqual(d, {"kind": "typewritten", "table": False, "text": "Dear Harvey:\n  When time permits"})

    def test_parse_fenced_and_table(self):
        d = T.parse_draft("KIND: mixed\nTABLE: yes\nTEXT:\n```\nA | B\n1 | 2\n```")
        self.assertEqual((d["kind"], d["table"], d["text"]), ("mixed", True, "A | B\n1 | 2"))

    def test_parse_rejects(self):
        self.assertIsNone(T.parse_draft("Here is the text: Dear Harvey"))
        self.assertIsNone(T.parse_draft("KIND: cursive\nTABLE: no\nTEXT:\nx"))


class Compare(unittest.TestCase):
    def test_normalisation(self):
        self.assertEqual(T.words("“It’s” — a | b\nc"), ['"It\'s"', "-", "a", "b", "c"])

    def test_spans_and_merge(self):
        a = T.words("The quick brown fox jumps")
        b = T.words("The quiet brown fox leaps over")
        sp = T.spans(a, b)
        self.assertEqual(sp, [{"agreed": "The"}, {"a": "quick", "b": "quiet"}, {"agreed": "brown fox"},
                              {"a": "jumps", "b": "leaps over"}])
        self.assertIsNone(T.merge(sp, {"1": "a"}))                       # one span still open
        self.assertEqual(T.merge(sp, {"1": "a", "3": "b"}), "The quick brown fox leaps over")
        self.assertEqual(T.merge(sp, {"1": "=quick", "3": "="}), "The quick brown fox")  # typed, and typed empty

    def test_identical_readings_need_no_answers(self):
        sp = T.spans(T.words("a b c"), T.words("a  b\nc"))
        self.assertEqual(sp, [{"agreed": "a b c"}])
        self.assertEqual(T.merge(sp, {}), "a b c")

    def test_corrections_apply_once_or_refuse(self):
        self.assertEqual(T.correct("p025", "Street San Francisco 4, California"), "Street San Francisco 6, California")
        self.assertEqual(T.correct("p088", "we do not know don t"), "we do not know")
        self.assertEqual(T.correct("p001", "San Francisco 4,"), "San Francisco 4,")  # other pages untouched
        with self.assertRaises(SystemExit):
            T.correct("p025", "San Francisco 6, California")  # already applied or changed: refuse, never guess
        with self.assertRaises(SystemExit):
            T.correct("p088", "we don t go, don t")  # ambiguous: two matches

    def test_struck_words_stay_in_the_scored_text_and_are_recorded(self):
        text = T.correct("p077", "which I think believe has")
        self.assertEqual(text, "which I believe think has")
        self.assertEqual(T.struck("p077", text), [{"fragment": "which I believe think", "offset": 0,
                                                    "struck": ["believe"], "owner_read": True}])
        self.assertEqual(T.struck("p001", "anything"), [])
        with self.assertRaises(SystemExit):
            T.struck("p077", "which I think believe has")  # the record follows the corrected text, never the old



class PrepareSource(unittest.TestCase):
    """W46.prepare-jpeg-pairs: the exact name first, then the pairs.tsv JPEG if it matches the PDF, else the PDF."""

    def setUp(self):
        import tempfile
        from pathlib import Path
        from unittest import mock
        import shutil
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        for d in ("corpus/F", "jpegs/A", "jpegs/B"):
            (self.tmp / d).mkdir(parents=True)
        for f in ("corpus/F/1.pdf", "corpus/F/2.pdf", "corpus/F/3.pdf", "jpegs/A/1.JPG", "jpegs/B/x 2.JPG"):
            (self.tmp / f).write_bytes(b"x")
        self.corr = {}
        self.calls = []

        def extract(kind, src, out, pdf=None):
            self.calls.append((kind, src.name))
            out.write_bytes(b"x")
            meta = {"taken": "2019:01:01", "camera": None, "rotated": 0, "width": 10, "height": 20}
            if kind == "original":
                meta["orient_corr"] = self.corr.get(src.name, 0.9)
            return meta

        for k, v in {"CORPUS": self.tmp / "corpus", "ORIGINALS": self.tmp / "jpegs", "CACHE": self.tmp / "cache",
                     "extract": extract, "sharpness": lambda _p: 1.0, "vision_words": lambda _p: 50}.items():
            p = mock.patch.object(T, k, v)
            p.start()
            self.addCleanup(p.stop)
        self.originals = {"1": ["A/1.JPG"], "3": ["A/3.JPG", "B/3.JPG"]}
        self.pairs = {"F/1.pdf": ("B/x 2.JPG", "number"), "F/2.pdf": ("B/x 2.JPG", "number")}

    def test_exact_name_first(self):
        rec = T.prepare("F", "1.pdf", [], self.originals, self.pairs)
        self.assertEqual((rec["source"], rec["source_method"], rec["source_path"]), ("original", "name", "A/1.JPG"))

    def test_paired_jpeg_kept(self):
        rec = T.prepare("F", "2.pdf", [], self.originals, self.pairs)
        self.assertEqual((rec["source"], rec["source_method"], rec["source_path"]),
                         ("original", "pairs.tsv number", "B/x 2.JPG"))
        self.assertNotIn("pair_rejected", rec)

    def test_paired_jpeg_below_min_corr_falls_back_to_pdf(self):
        self.corr["x 2.JPG"] = T.MIN_CORR - 0.01
        rec = T.prepare("F", "2.pdf", [], self.originals, self.pairs)
        self.assertTrue(rec["source"].startswith("pdf image (no original; pair below MIN_CORR"))
        self.assertIsNone(rec["source_method"])
        self.assertEqual((rec["source_path"], rec["pair_rejected"], rec["pair_method"]),
                         ("F/2.pdf", "B/x 2.JPG", "pairs.tsv number"))
        self.assertEqual([k for k, _ in self.calls], ["original", "pdf image (no original; pair below MIN_CORR)"])

    def test_name_match_skips_min_corr(self):
        self.corr["1.JPG"] = 0.1   # an exact-name original is taken as before, whatever its correlation
        self.assertEqual(T.prepare("F", "1.pdf", [], self.originals, self.pairs)["source_method"], "name")

    def test_two_name_matches_and_no_pair(self):
        rec = T.prepare("F", "3.pdf", [], self.originals, self.pairs)
        self.assertEqual((rec["source"], rec["source_method"]), ("pdf image (2 originals)", None))

if __name__ == "__main__":
    unittest.main()
