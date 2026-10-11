"""Units, parsing, assembly and voting of approach C (W36.seg-whole), on toy data.
Run: <lab venv>/bin/python test_whole.py   (no bench data, no network, no key)."""
import json
import unittest
from types import SimpleNamespace

import method_whole as M
from methods import METHODS, Prediction
from score import check_prediction


def toy(labels):
    pages = [SimpleNamespace(n=i + 1, label=l) for i, l in enumerate(labels)]
    return SimpleNamespace(name="Toy", pages=pages, labels=list(labels))


TRUTH = ["Box", "Folder", "New", "Cont", "New", "Folder", "New", "Folder", "New", "Cont", "Cont"]


class Units(unittest.TestCase):
    def test_folders_are_runs_between_photos_of_two_pages_or_more(self):
        # pages 3-5 (idx 2-4) and 9-11 (idx 8-10); the one-page folder at idx 6 needs no call
        self.assertEqual(M.folders(toy(TRUTH)), [(2, 5), (8, 11)])

    def test_a_run_at_the_very_start_or_end_counts(self):
        self.assertEqual(M.folders(toy(["New", "Cont", "Folder", "New", "New"])), [(0, 2), (3, 5)])

    def test_chunks_share_one_page_and_judge_every_gap_once(self):
        for a, b in ((0, 2), (0, 10), (0, 11), (5, 30), (3, 85)):
            cs = M.chunks(a, b)
            self.assertTrue(all(e - s <= M.CHUNK for s, e in cs))
            gaps = [g for s, e in cs for g in range(s, e - 1)]
            self.assertEqual(gaps, list(range(a, b - 1)), (a, b))
            self.assertTrue(all(cs[k][1] - 1 == cs[k + 1][0] for k in range(len(cs) - 1)))

    def test_a_short_folder_is_one_unit_in_both_variants(self):
        self.assertEqual(M.chunks(2, 9), [(2, 9)])


class Parse(unittest.TestCase):
    def ans(self, bs):
        return json.dumps({"boundaries": [{"between": [x, x + 1], "decision": d, "cue": "c", "confidence": c}
                                          for x, d, c in bs]})

    def test_every_gap_parsed(self):
        out = M.parse_answer(self.ans([(3, "continue", 0.9), (4, "new", 0.97)]), [3, 4, 5])
        self.assertEqual(out[3]["decision"], "continue")
        self.assertEqual(out[4]["confidence"], 0.97)

    def test_a_missing_gap_is_refused(self):
        with self.assertRaises(M.W.ParseError):
            M.parse_answer(self.ans([(3, "new", 0.9)]), [3, 4, 5])

    def test_a_repeated_or_foreign_gap_is_refused(self):
        with self.assertRaises(M.W.ParseError):
            M.parse_answer(self.ans([(3, "new", 0.9), (3, "new", 0.9), (4, "new", 0.9)]), [3, 4, 5])
        with self.assertRaises(M.W.ParseError):
            M.parse_answer(self.ans([(3, "new", 0.9), (7, "new", 0.9)]), [3, 4, 5])

    def test_bad_decision_or_confidence_is_refused(self):
        with self.assertRaises(M.W.ParseError):
            M.parse_answer(self.ans([(3, "maybe", 0.9)]), [3, 4])
        with self.assertRaises(M.W.ParseError):
            M.parse_answer(self.ans([(3, "new", 1.5)]), [3, 4])


class Request(unittest.TestCase):
    def test_body_uses_this_schema_and_thinking(self):
        body = M.request_body("P", [b"x", b"y"], [1, 2])
        cfg = body["generationConfig"]
        self.assertEqual(cfg["thinkingConfig"], {"thinkingLevel": "low"})
        self.assertEqual(list(cfg["responseSchema"]["properties"]), ["boundaries"])
        self.assertEqual(body["contents"][0]["parts"][-1]["text"], "P")

    def test_prompt_carries_the_owners_cues_and_drops_photo_kinds(self):
        p = M.PROMPT.lower()
        for cue in ("show-through", "(ap)", "magazine", "small item on a full sheet"):
            self.assertIn(cue, p)
        self.assertNotIn('kind "box"', p)


def judge_from(decisions):
    """A fake judge: decisions[(a, b)] -> {first page number: (decision, confidence)}."""
    def judge(col, a, b, allow_call=False):
        nums = [col.pages[i].n for i in range(a, b)]
        return {x: {"decision": d, "confidence": c, "cue": ""}
                for x, (d, c) in zip(nums[:-1], decisions[(a, b)])}
    return judge


class Assemble(unittest.TestCase):
    def test_labels_and_fixed_photo_gaps(self):
        col = toy(TRUTH)
        judge = judge_from({(2, 5): [("continue", 0.9), ("new", 0.8)],
                            (8, 11): [("continue", 0.99), ("new", 0.6)]})
        gaps = M.predict_gaps(col, "whole", judge)
        self.assertEqual(gaps[3]["unit_pages"], 3)
        self.assertEqual(gaps[3]["pos"], 2)
        pred = M.assemble(col, gaps)
        check_prediction(pred)
        self.assertEqual(pred.labels, ["Box", "Folder", "New", "Cont", "New", "Folder", "New", "Folder",
                                       "New", "Cont", "New"])
        self.assertTrue(pred.boundaries[0]["fixed"])        # box | folder
        self.assertFalse(pred.boundaries[2]["fixed"])

    def test_registered(self):
        self.assertIn("whole-gemini", METHODS)
        self.assertIn("whole-gemini-c10", METHODS)
        self.assertTrue(METHODS["whole-gemini"].oracle_photos)


def pred(labels, confs):
    from score import boundaries_from_labels
    return Prediction(labels, [{"decision": d, "confidence": c, "fixed": False}
                               for d, c in zip(boundaries_from_labels(labels), confs)])


class Vote(unittest.TestCase):
    def test_majority_then_most_confident(self):
        truth = ["New", "Cont", "New"]
        a = pred(["New", "Cont", "New"], [0.9, 0.9])
        b = pred(["New", "New", "New"], [0.95, 0.9])
        c = pred(["New", "Cont", "Cont"], [0.6, 0.7])
        # gap 0: cont, new, cont -> continue (majority); gap 1: new, new, cont -> new
        self.assertEqual(M.vote_labels(truth, [a, b, c], set()), ["New", "Cont", "New"])
        # two voters tie at gap 0: b is more confident -> new
        self.assertEqual(M.vote_labels(truth, [a, b], set()), ["New", "New", "New"])

    def test_review_takes_the_truth(self):
        truth = ["New", "Cont", "New"]
        b = pred(["New", "New", "Cont"], [0.95, 0.9])
        self.assertEqual(M.vote_labels(truth, [b], {0, 1}), truth)


if __name__ == "__main__":
    unittest.main()
