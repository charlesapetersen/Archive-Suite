"""Feature extraction and the classifier of the feature model (W36.seg-features), on toy data.
Run: <lab venv>/bin/python test_features.py   (needs numpy and PIL; no bench data, no OCR, no network)."""
import math
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

import numpy as np

import features as F
import method_features as M
from methods import METHODS
from score import TestSetGuard, guard

B, Fo, N, C = "Box", "Folder", "New", "Cont"


class PageNumbers(unittest.TestCase):
    def test_forms_recognised(self):
        self.assertEqual(F.page_number(["- 2 -"]), 2)
        self.assertEqual(F.page_number(["Page 3 of 5"]), 3)
        self.assertEqual(F.page_number(["p. 4"]), 4)
        self.assertEqual(F.page_number(["12"]), 12)

    def test_years_and_prose_are_not_page_numbers(self):
        self.assertIsNone(F.page_number(["1950", "Dear Sir:", "page two of the report"]))
        self.assertIsNone(F.page_number(["34.77"]))

    def test_page_of(self):
        self.assertEqual(F.page_of("blah\nPage 2 of 3\n"), (2, 3))
        self.assertIsNone(F.page_of("no numbers here"))


LETTER = "SULLIVAN & CROMWELL\nFebruary 2, 1950\nMr. Joel Dean\nDear Joel:\nI enclose a reprint.\nSincerely yours,\nHenry\n(Enclosure)"
PAGE2 = "- 2 -\nand so the matter rests with the board\nwhich meets in March"


class TextCues(unittest.TestCase):
    def test_letter(self):
        c = F.text_cues(LETTER)
        self.assertTrue(c["salutation"])
        self.assertTrue(c["date_top"])
        self.assertTrue(c["closing"])
        self.assertTrue(c["enclosure"])
        self.assertFalse(c["blank"])
        self.assertIsNone(c["pn_top"])

    def test_continuation_page(self):
        c = F.text_cues(PAGE2)
        self.assertEqual(c["pn_top"], 2)
        self.assertFalse(c["salutation"])
        self.assertFalse(c["starts_lower"])   # the first line is "- 2 -"
        self.assertTrue(c["ends_open"])       # "...in March" ends on a lower-case letter, no full stop

    def test_memo_and_blank(self):
        self.assertTrue(F.text_cues("MEMORANDUM\nTO: All staff\nFROM: J.D.")["memo"])
        self.assertTrue(F.text_cues("")["blank"])
        self.assertTrue(F.text_cues(" . ,\n")["blank"])


class Tfidf(unittest.TestCase):
    def test_identical_disjoint_and_unit_rows(self):
        cos = F.adjacent_cosine(["tariff wool tariff", "tariff wool tariff", "orange grove sunshine", None])
        self.assertAlmostEqual(cos[0], 1.0, places=6)
        self.assertAlmostEqual(cos[1], 0.0, places=6)
        self.assertEqual(cos[2], 0.0)   # an empty page has a zero row, not NaN
        m = F.tfidf_matrix(["a bb cc", "bb dd"])
        self.assertTrue(np.allclose(np.linalg.norm(m, axis=1), 1.0))

    def test_shared_rare_word_beats_shared_common_word(self):
        texts = ["the the senate", "the the senate", "the the house", "the the court"]
        m = F.tfidf_matrix(texts)
        self.assertGreater(m[0] @ m[1], m[2] @ m[3])


class TimeGap(unittest.TestCase):
    def test_gap(self):
        self.assertAlmostEqual(F.log_gap("2022:04:14 10:16:50", "2022:04:14 10:17:50"), math.log1p(60))
        self.assertEqual(F.log_gap(None, "2022:04:14 10:17:50"), 0.0)
        self.assertEqual(F.log_gap("2022:04:14 10:17:50", "2022:04:14 10:16:50"), 0.0)


class ImageStats(unittest.TestCase):
    def test_paper_and_ink_on_a_synthetic_page(self):
        from PIL import Image
        im = Image.new("RGB", (100, 200), (240, 230, 200))      # cream paper, portrait
        for x in range(40, 60):                                  # a black bar inside the central crop
            for y in range(80, 120):
                im.putpixel((x, y), (0, 0, 0))
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "page.jpg"
            im.save(p, quality=95)
            s = F.image_stats(p)
        self.assertEqual((s["w"], s["h"]), (100, 200))
        self.assertTrue(np.allclose(s["paper"], [240, 230, 200], atol=4))
        crop_px = 60 * 120                                       # central 60% of 100x200
        self.assertAlmostEqual(s["ink"], 20 * 40 / crop_px, delta=0.02)


class PairFeatures(unittest.TestCase):
    def test_sequence_orientation_and_missing_image(self):
        a, b = F.text_cues("- 1 -\nThe report begins"), F.text_cues(PAGE2)
        portrait = {"paper": [240, 230, 200], "ink": 0.05, "w": 100, "h": 200}
        landscape = {"paper": [200, 200, 200], "ink": 0.10, "w": 200, "h": 100}
        f = F.pair_features(a, b, 0.3, portrait, landscape, 2.0)
        self.assertEqual(f["pn_sequence"], 1.0)
        self.assertEqual(f["next_pn_top_ge2"], 1.0)
        self.assertEqual(f["orientation_change"], 1.0)
        self.assertAlmostEqual(f["aspect_change"], abs(math.log(0.5 / 2.0)))
        self.assertAlmostEqual(f["ink_diff"], 0.05)
        self.assertEqual(f["missing_image"], 0.0)
        self.assertEqual(f["log_time_gap"], 2.0)
        g = F.pair_features(a, b, 0.3, None, landscape, 0.0)
        self.assertEqual((g["missing_image"], g["paper_diff"]), (1.0, 0.0))
        self.assertEqual(set(F.FEATURES), set(f))

    def test_collection_features_shape_and_order(self):
        pages = [SimpleNamespace(n=i + 1, captured=f"2022:04:14 10:1{i}:00") for i in range(3)]
        texts = [LETTER, "Dear Sam:\nA second letter.", PAGE2]
        col = SimpleNamespace(name="toy", pages=pages, text=lambda i: texts[i])
        X = F.collection_features(col, with_images=False)
        self.assertEqual(X.shape, (2, len(F.FEATURES)))
        self.assertEqual(X[0, F.FEATURES.index("next_salutation")], 1.0)
        self.assertEqual(X[1, F.FEATURES.index("next_pn_top_ge2")], 1.0)
        self.assertEqual(X[0, F.FEATURES.index("missing_image")], 1.0)


class Classifier(unittest.TestCase):
    def test_learns_a_signal_and_ignores_constants(self):
        rng = np.random.default_rng(1)
        x = rng.normal(size=400)
        noise = rng.normal(size=400)
        y = (x + 0.3 * rng.normal(size=400) > 0).astype(float)
        X = np.column_stack([x, noise, np.ones(400)])
        m = M.Logistic(lam=1.0).fit(X, y)
        self.assertGreater(m.coef[0], 2.0)
        self.assertLess(abs(m.coef[1]), 0.5)
        self.assertEqual(m.coef[2], 0.0)
        p = m.predict_proba(X)
        self.assertTrue(((p >= 0) & (p <= 1)).all())
        self.assertGreater(((p >= 0.5) == (y > 0.5)).mean(), 0.9)

    def test_penalty_shrinks_and_separable_data_stays_finite(self):
        X = np.array([[0.], [1.], [2.], [3.]])
        y = np.array([0., 0., 1., 1.])
        weak, strong = M.Logistic(lam=0.1).fit(X, y), M.Logistic(lam=10.0).fit(X, y)
        self.assertTrue(np.isfinite(weak.w).all())
        self.assertGreater(abs(weak.coef[0]), abs(strong.coef[0]))

    def test_labels_from_probs(self):
        truth = [B, Fo, N, C, N, Fo, C, C]
        p = np.array([1, 1, 0.2, 0.9, 1, 1, 0.4])   # P(new) at gaps 0..6
        self.assertEqual(M.labels_from_probs(truth, p), [B, Fo, N, C, N, Fo, N, C])

    def test_doc_gaps(self):
        mask, y = M.doc_gaps([B, N, C, N, Fo, N])
        self.assertEqual(mask.tolist(), [False, True, True, False, False])
        self.assertEqual(y.tolist(), [1, 0, 1, 1, 1])


class Reporting(unittest.TestCase):
    P = np.array([0.99, 0.01, 0.9, 0.2, 0.6, 0.45])
    Y = np.array([1, 0, 0, 0, 1, 1])     # wrong at 0.9 and 0.45

    def test_risk_coverage(self):
        rows = {r[0]: r for r in M.risk_coverage_rows(self.P, self.Y, pages=100)}
        t, a, cov, e, er, rv = rows[0.95]
        self.assertEqual((a, e), (2, 0))
        self.assertAlmostEqual(rv, 4.0)
        t, a, cov, e, er, rv = rows[0.5]
        self.assertEqual((a, e, cov), (6, 2, 1.0))
        cov, rate, e, k = M.best_at_coverage(self.P, self.Y, 0.5)
        self.assertEqual((k, e), (5, 1))   # the five most confident hold one error (at 0.9)
        self.assertAlmostEqual(rate, 0.2)

    def test_calibration_bins_cover_everything(self):
        cal = M.calibration(self.P, self.Y)
        self.assertEqual(sum(r[2] for r in cal), len(self.P))
        top = cal[-1]
        self.assertEqual(top[2], 2)
        self.assertAlmostEqual(top[4], 0.5)


class Interface(unittest.TestCase):
    def test_registered_tuning_and_guarded(self):
        for name in ("features-lr", "features-lr-notime"):
            m = METHODS[name]
            self.assertTrue(m.tuning)
            with self.assertRaises(TestSetGuard):
                guard(m, ["Dean", "Stanton"], final=True)
        self.assertNotIn("log_time_gap", [F.FEATURES[i] for i in M.columns(False)])
        self.assertIn("log_time_gap", [F.FEATURES[i] for i in M.columns(True)])

    def test_refuses_a_collection_outside_the_development_set(self):
        with self.assertRaises(ValueError):
            METHODS["features-lr"].predict(SimpleNamespace(name="Stanton"))


if __name__ == "__main__":
    unittest.main()
