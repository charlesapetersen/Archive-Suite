"""Prove the scorer on hand-made toy streams whose answers are worked out by hand.
Run: python test_score.py   (no data, no OCR, no network)."""
import unittest
from pathlib import Path

from score import (Counts, TestSetGuard, boundaries_from_labels, canonical, check_prediction,
                   derived, guard, risk_coverage, score_labels, segment_ids)
from methods import AllNew, NoBoundaries, Prediction, RuleCues, RuleCuesSketch, SpringRun, from_labels
import data
import rules

B, F, N, C = "Box", "Folder", "New", "Cont"


def d(truth, pred):
    return derived(score_labels(truth, pred, "toy"))


class Segmenting(unittest.TestCase):
    def test_photos_are_own_segments_and_orphan_cont_opens_a_document(self):
        self.assertEqual(segment_ids([B, F, C, C, N, F, C]), [0, 1, 2, 2, 3, 4, 5])
        self.assertEqual(canonical([C, B, C, C, N]), [N, B, N, C, N])


class Toys(unittest.TestCase):
    # Truth: Box, Folder, then documents [2,3,4] [5] [6,7] -> 6 document pages, 3 documents.
    T = [B, F, N, C, C, N, N, C]

    def test_perfect(self):
        r = d(self.T, list(self.T))
        self.assertEqual(r["pages_in_exact_doc"], 1.0)
        self.assertEqual(r["docs_exact"], 1.0)
        self.assertEqual((r["false_splits"], r["false_merges"]), (0, 0))
        self.assertEqual(r["boundary_f1"], 1.0)
        self.assertEqual((r["pk"], r["windowdiff"], r["edits_per_100_pages"]), (0.0, 0.0, 0.0))
        self.assertEqual(r["folders_perfect"], 1.0)
        self.assertEqual(r["photo_accuracy"], 1.0)

    def test_one_merge(self):
        # [5] swallowed into [2,3,4]: documents [2..5] [6,7]; only [6,7] exact.
        r = d(self.T, [B, F, N, C, C, C, N, C])
        self.assertEqual(r["pages_in_exact_doc"], 2 / 6)
        self.assertEqual(r["docs_exact"], 1 / 3)
        self.assertEqual((r["false_splits"], r["false_merges"]), (0, 1))
        # Document gaps 2-3,3-4,4-5,5-6,6-7; truth boundaries at 4-5 and 5-6.
        self.assertEqual(r["boundary_precision"], 1.0)
        self.assertEqual(r["boundary_recall"], 0.5)
        self.assertAlmostEqual(r["boundary_f1"], 2 / 3)
        self.assertEqual(r["edits_per_100_pages"], 100 / 8)
        self.assertEqual(r["folders_perfect"], 0.0)

    def test_one_split(self):
        # [2,3,4] cut after 3: documents [2,3] [4] [5] [6,7]; [5] and [6,7] exact.
        r = d(self.T, [B, F, N, C, N, N, N, C])
        self.assertEqual(r["pages_in_exact_doc"], 3 / 6)
        self.assertEqual(r["docs_exact"], 2 / 3)
        self.assertEqual((r["false_splits"], r["false_merges"]), (1, 0))
        self.assertAlmostEqual(r["boundary_precision"], 2 / 3)
        self.assertEqual(r["boundary_recall"], 1.0)
        self.assertAlmostEqual(r["boundary_f1"], 0.8)

    def test_box_and_folder_photos(self):
        # Folder photo called Box: the type is wrong but the segmentation is untouched.
        r = d(self.T, [B, B, N, C, C, N, N, C])
        self.assertEqual(r["photo_accuracy"], 0.5)
        self.assertEqual(r["photo_type_swaps"], 1)
        self.assertEqual(r["pages_in_exact_doc"], 1.0)
        self.assertEqual(r["edits_per_100_pages"], 100 / 8)
        # Folder photo missed (called Cont): it opens a document with page 2, so [2,3,4] is lost.
        r = d(self.T, [B, C, C, C, C, N, N, C])
        self.assertEqual(r["photos_missed"], 1)
        self.assertEqual(r["pages_in_exact_doc"], 3 / 6)
        self.assertEqual(r["photo_accuracy"], 0.5)
        # A document page called a Folder photo: a false photo that splits [6,7] in two.
        r = d(self.T, [B, F, N, C, C, N, N, F])
        self.assertEqual(r["false_photos"], 1)
        self.assertEqual(r["pages_in_exact_doc"], 4 / 6)
        self.assertEqual(r["false_splits"], 1)

    def test_two_folders(self):
        # Folder 1: [1,2] [3]; folder 2: [5,6]. Folder 2 wrong, folder 1 right -> 1 of 2 perfect.
        t = [F, N, C, N, F, N, C]
        r = d(t, [F, N, C, N, F, N, N])
        self.assertEqual(r["folders"], 2)
        self.assertEqual(r["folders_perfect"], 0.5)
        # The gap Folder->New is not a document gap: 3 document gaps (1-2, 2-3, 5-6), 1 truth boundary.
        c = score_labels(t, [F, N, C, N, F, N, N])
        self.assertEqual((c.gaps, c.truth_bounds), (3, 1))

    def test_all_singletons(self):
        t = [B, F, N, N, N, N]
        r = d(t, [B, F, N, N, N, N])
        self.assertEqual(r["pages_in_exact_doc"], 1.0)
        # All-New is perfect here; no-boundaries merges four singletons into one: nothing exact.
        r = d(t, [B, F, N, C, C, C])
        self.assertEqual(r["pages_in_exact_doc"], 0.0)
        self.assertEqual((r["false_merges"], r["false_splits"]), (3, 0))
        self.assertEqual(r["boundary_recall"], 0.0)
        self.assertEqual(r["boundary_precision"], None)  # no predicted boundaries
        self.assertEqual(r["edits_per_100_pages"], 300 / 6)

    def test_orphan_cont_equals_new(self):
        r = d([F, N, C], [F, C, C])
        self.assertEqual(r["pages_in_exact_doc"], 1.0)
        self.assertEqual(r["edits_per_100_pages"], 0.0)

    def test_pk_windowdiff_by_hand(self):
        # 6 pages, truth [0,1,2][3,4,5] -> 2 segments, k = round(6/2/2) = 2 (round half to even -> 2).
        t = [N, C, C, N, C, C]
        p = [N, C, C, C, C, C]
        r = d(t, p)
        # windows i=0..3 compare i,i+2: truth same? (0,2)y (1,3)n (2,4)n (3,5)y; hyp all same.
        self.assertEqual(r["pk"], 2 / 4)
        self.assertEqual(r["windowdiff"], 2 / 4)

    def test_pooling_sums_counts(self):
        a = score_labels(self.T, list(self.T), "a")
        b = score_labels([F, N, N], [F, N, C], "b")
        r = derived(a + b)
        self.assertEqual(r["pages_in_exact_doc"], 6 / 8)
        self.assertEqual(r["collections"], "a+b")


class Interface(unittest.TestCase):
    class Fake:
        def __init__(self, labels):
            self.labels = labels
            self.name = "fake"

        def text(self, i):
            return ["", "", "Dear Sir,", "- 2 -\nmore", "Page 3 of 4", "Gentlemen:"][i]

    def test_baselines(self):
        c = self.Fake([B, F, N, C, C, N])
        self.assertEqual(AllNew().predict(c).labels, [B, F, N, N, N, N])
        self.assertEqual(NoBoundaries().predict(c).labels, [B, F, C, C, C, C])
        p = RuleCuesSketch().predict(c)
        self.assertEqual(p.labels, [B, F, N, C, C, N])
        check_prediction(p)
        rc = risk_coverage(c.labels, p)
        self.assertEqual(rc[-1][1:], (3, 0))  # 3 document gaps, none wrong

    def test_check_prediction_rejects_inconsistent_boundaries(self):
        p = from_labels([N, C, N])
        check_prediction(p)
        p.boundaries[0]["decision"] = "new"
        with self.assertRaises(ValueError):
            check_prediction(p)

    def test_risk_coverage(self):
        t = [N, C, N, C]
        p = Prediction([N, N, N, C], [
            {"decision": "new", "confidence": 0.2, "cue": ""},
            {"decision": "new", "confidence": 0.9, "cue": ""},
            {"decision": "continue", "confidence": 0.9, "cue": ""}])
        self.assertEqual(risk_coverage(t, p), [(0.9, 2, 0), (0.2, 3, 1)])
        self.assertIsNone(risk_coverage(t, from_labels(t)))


class Guard(unittest.TestCase):
    def test_tuning_method_refused_on_test(self):
        with self.assertRaises(TestSetGuard):
            guard(RuleCuesSketch(), ["Dean", "Stanton"], final=True)
        with self.assertRaises(TestSetGuard):
            guard(AllNew(), ["RG165"], final=False)
        guard(AllNew(), ["RG165"], final=True)
        guard(RuleCuesSketch(), ["Dean", "Deaver"], final=False)

    def test_undeclared_method_counts_as_tuning(self):
        class M:
            name = "m"
        with self.assertRaises(TestSetGuard):
            guard(M(), ["Stanton"], final=True)


class Spring(unittest.TestCase):
    """The loader for the March 2026 saved Gemini outputs (data.read_spring, methods.SpringRun)."""

    def _write(self, rows):
        import json, tempfile
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(rows, f)
        f.close()
        self.addCleanup(lambda: __import__("os").unlink(f.name))
        return Path(f.name)

    ROWS = [{"file_num": "1", "predicted": "box_label"}, {"file_num": "2", "predicted": "folder_label"},
            {"file_num": "3", "predicted": "document_start"}, {"file_num": "4", "predicted": None},
            {"file_num": "5", "predicted": "document_continuation"},
            {"file_num": "6", "predicted": "folder_label"}]

    def test_failed_page_is_new_and_counted_not_the_truth(self):
        labels, failed = data.read_spring(self._write(self.ROWS), 6)
        self.assertEqual(labels, [B, F, N, N, C, F])
        self.assertEqual(failed, [4])

    def test_rejects_gaps_duplicates_and_unknown_labels(self):
        with self.assertRaises(ValueError):
            data.read_spring(self._write(self.ROWS[:5]), 6)
        with self.assertRaises(ValueError):
            data.read_spring(self._write(self.ROWS + [{"file_num": "6", "predicted": None}]), 6)
        with self.assertRaises(ValueError):
            data.read_spring(self._write([{"file_num": "1", "predicted": "maybe"}]), 1)

    def test_method_scores_failure_against_the_run_and_oracle_variant(self):
        path = self._write(self.ROWS)
        old = data.spring_path
        data.spring_path = lambda name, run: path
        self.addCleanup(lambda: setattr(data, "spring_path", old))

        class Col:
            name = "Dean"
            labels = [B, F, N, C, C, N]
            pages = [type("P", (), {"n": i + 1})() for i in range(6)]

        m = SpringRun("s", "v1", "toy")
        p = m.predict(Col())
        check_prediction(p)
        self.assertEqual(p.labels, [B, F, N, N, C, F])
        self.assertEqual(m.failed, {"Dean": [4]})
        self.assertTrue(p.boundaries[2]["cue"].startswith("run failed"))   # gap 3-4 is page 4's
        self.assertIn("1 (Dean 1)", m.notes()[0])
        # Page 4 (truth Cont) failed -> New: a false split; page 6 called a folder photo.
        r = d(Col.labels, p.labels)
        self.assertEqual((r["false_splits"], r["false_photos"]), (1, 1))
        o = SpringRun("o", "v1", "toy", oracle_photos=True).predict(Col())
        self.assertEqual(o.labels, [B, F, N, N, C, N])   # a document page called a photo becomes New
        self.assertFalse(SpringRun("s", "v1", "toy").tuning)


class RuleCueRules(unittest.TestCase):
    def names(self, text, prev=None, top=5, end=3, blank=0):
        return [r for r, _ in rules.fires(rules.lines_of(text), None if prev is None else rules.lines_of(prev),
                                          top, end, blank)]

    def test_each_rule_fires_on_its_cue(self):
        self.assertIn("page-number", self.names("Mr. T. O. Yntema\n- 2 -\nMarch 30, 1960\ntext"))
        self.assertIn("page-number", self.names("Page 3 of 4\nmore"))
        self.assertIn("page-number", self.names("68B P.4\nbody"))
        self.assertIn("page-one", self.names("Page 1 of 3\nbody"))
        self.assertNotIn("page-number", self.names("Page 1 of 3\nbody"))
        self.assertIn("bare-number", self.names("14\nbody"))
        self.assertNotIn("bare-number", self.names("1960\nbody"))
        self.assertIn("jump-from", self.names("BROWN VIEWS\nContinued from First Page\nbody"))
        self.assertIn("opening", self.names("Gentlemen:\nWe write"))
        self.assertIn("opening", self.names("MEMORANDUM\nTO: Mr. Welch"))
        self.assertIn("date-line", self.names("March 7, 1960\nMr. Theodore O. Yntema"))
        self.assertIn("date-line", self.names("5-18-60\nbody"))
        self.assertIn("prev-closing", self.names("Body", prev="text\nVery truly yours,\nJoel Dean\nJD/ne"))
        self.assertIn("prev-closing", self.names("Body", prev="text\nRJH: afa"))
        self.assertIn("prev-jump", self.names("Body", prev="text\n(Continued on next page)"))
        self.assertIn("flows-on", self.names("and so the argument goes\non"))
        self.assertEqual(self.names("", blank=20), ["blank"])
        self.assertEqual(self.names("SOME HEADLINE\nBody text."), [])

    def test_end_lines_window(self):
        prev = "Sincerely,\nA. Writer\nline\nline\nline"
        self.assertNotIn("prev-closing", self.names("Body", prev=prev, end=3))
        self.assertIn("prev-closing", self.names("Body", prev=prev, end=6))

    def test_first_enabled_rule_decides(self):
        fired = [("page-number", "Cont"), ("date-line", "New")]
        all_on = rules.Params(5, 3, 0, "New", rules.RULES)
        self.assertEqual(rules.decide(fired, all_on), ("Cont", "page-number"))
        off = rules.Params(5, 3, 0, "New", tuple(r for r in rules.RULES if r != "page-number"))
        self.assertEqual(rules.decide(fired, off), ("New", "date-line"))
        self.assertEqual(rules.decide([], rules.Params(5, 3, 0, "Cont", ())), ("Cont", "default"))

    def test_a_photo_is_not_the_previous_page(self):
        class Col:
            labels = [N, F, N]

            def text(self, i):
                return ["letter\nSincerely,", "FOLDER\ncc: x", "Body"][i]
        feats = rules._features(Col(), 5, 3, 0)
        self.assertIsNone(feats[1][1])
        self.assertEqual(feats[2][1], [])   # the folder photo's text cannot fire prev-closing

    def test_rule_stats_count_document_gaps_only(self):
        truth = [F, N, C, N, F, N]
        pred = [F, N, C, C, F, N]
        deciders = ["photo (oracle)", "date-line", "page-number", "default", "photo (oracle)", "date-line"]
        st = rules.rule_stats([(truth, pred, deciders)])
        # Gaps 1-2 (page-number, right) and 2-3 (default, wrong); page 1 and page 5 follow a photo.
        self.assertEqual(st, {"page-number": [1, 1], "default": [1, 0]})


class RuleCuesLOCO(unittest.TestCase):
    """The rule-cue method fits on the OTHER development collections only."""

    class Col:
        def __init__(self, name, labels, texts):
            self.name, self.labels, self._t = name, labels, texts
            self.pages = list(range(len(labels)))

        def text(self, i):
            return self._t[i]

    def cols(self):
        t = ["BOX", "FOLDER", "March 1, 1960\nDear Sir,", "- 2 -\nmore", "April 2, 1960\nbody",
             "Page 2\nbody", "HEADLINE"]
        lab = [B, F, N, C, N, C, N]
        return {n: self.Col(n, list(lab), list(t)) for n in data.DEV}

    def test_folds_exclude_the_held_out_collection(self):
        cols = self.cols()
        loaded = []
        m = RuleCues(train_loader=lambda n: loaded.append(n) or cols[n])
        for name in data.DEV:
            p = m.predict(cols[name])
            check_prediction(p)
            self.assertEqual(p.labels, cols[name].labels)
            self.assertNotIn(name, m.folds[name][2])
            self.assertEqual(sorted(m.folds[name][2]), sorted(n for n in data.DEV if n != name))
        self.assertTrue(all(0 < b["confidence"] <= 1 for b in p.boundaries))
        self.assertTrue(any("fitted on" in line for line in m.notes()))

    def test_marked_tuning_so_the_guard_refuses_the_test_set(self):
        with self.assertRaises(TestSetGuard):
            guard(RuleCues(), ["Stanton"], final=True)


if __name__ == "__main__":
    unittest.main(verbosity=1)
