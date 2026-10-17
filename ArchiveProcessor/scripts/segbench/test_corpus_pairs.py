"""W41.seg-corpus-pairs offline tests: the pairing rule on made-up names, and the image check's quarter turns.
No corpus. Run: python3 -m unittest test_corpus_pairs (from this directory)."""
import os
import tempfile
import unittest

import corpus_pairs as P


class Pairing(unittest.TestCase):
    def idx(self, *jpegs):
        return P.Index(list(jpegs))

    def test_numbers_are_the_set_of_long_digit_runs(self):
        self.assertEqual(P.number("01100 — Noyce 1490"), frozenset({1100, 1490}))
        self.assertEqual(P.number("01100 — Noyce M1490"), frozenset({1100, 1490}))
        self.assertEqual(P.number("UIUC — 00001"), frozenset({1}))
        self.assertIsNone(P.number("Public Interest — Issue 66"))

    def test_methods_in_order(self):
        i = self.idx("A/x/00001 — UIUC.jpg", "Bravo/00002 — UIUC.jpg", "Charlie/00002 — UIUC.jpg",
                     "D/UIUC — 00003.jpg")
        self.assertEqual(i.pair("A/x/00001 — UIUC.pdf")[:2], ("A/x/00001 — UIUC.jpg", "mirrored"))
        self.assertEqual(i.pair("Z/UIUC — 00003.pdf")[:2], ("D/UIUC — 00003.jpg", "stem"))
        # the stem is not unique, so the number rule finds two, and the folder settles it
        self.assertEqual(i.pair("Charlie papers/00002 — UIUC.pdf")[:2], ("Charlie/00002 — UIUC.jpg", "folder"))
        self.assertEqual(i.pair("Q/00003 — UIUC.pdf")[:2], ("D/UIUC — 00003.jpg", "number"))  # either order

    def test_owner_rule_same_numbers_near_name_any_order(self):
        i = self.idx("Tech/Noyce — M1490/01100 — Noyce M1490.jpg", "Tech/Noyce — M1490/01101 — Noyce M1490.jpg",
                     "Tech/Noyce — M1491/01100 — Noyce M1491.jpg")
        self.assertEqual(i.pair("Tech/Noyce 1490/01100 — Noyce 1490.pdf")[:2],
                         ("Tech/Noyce — M1490/01100 — Noyce M1490.jpg", "number"))
        self.assertEqual(i.pair("Tech/Noyce 1490/01102 — Noyce 1490.pdf")[1], "none")   # no such photo
        self.assertEqual(i.pair("Other/01100 — Fairchild 1490.pdf")[1], "none")          # the name differs

    def test_a_tie_goes_to_the_folder_then_stays_open(self):
        i = self.idx("Hoover/Zschau/00007 — Zschau.jpg", "Harvard/Lowell/00007 — Zschau.jpg")
        self.assertEqual(i.pair("Hoover Institute/Zschau/00007 Zschau.pdf")[:2],
                         ("Hoover/Zschau/00007 — Zschau.jpg", "folder"))
        j, m, tied = self.idx("A/00007 — Zschau.jpg", "B/00007 — Zschau.jpg").pair("C/00007 Zschau.pdf")
        self.assertEqual((j, m, sorted(tied)), (None, "tied", ["A/00007 — Zschau.jpg", "B/00007 — Zschau.jpg"]))


class Prompt(unittest.TestCase):
    def test_window_prompt_is_the_benchs_prompt(self):
        """The label-clean pack's prompt equals method_local.request's for the same pages and texts."""
        from pathlib import Path
        import unittest.mock
        import data
        import method_window_cues as C
        texts = ["MEMORANDUM\nTo: the Provost", None, "x" * 3000, "Dear Sir,"]
        pages = [data.Page(n=n, label="New", path=None, _text=t) for n, t in zip((5, 6, 7, 8), texts)]
        pages[1]._text = ""
        col = data.Collection(name="fake", directory=Path("/nonexistent"), pages=pages)
        with unittest.mock.patch.object(data, "thumbnail", lambda *a, **k: Path("/x.jpg")):
            prompt, _, nums = C.build_request("codex", col, 0, 4)
        self.assertEqual(P.window_prompt(nums, ["MEMORANDUM\nTo: the Provost", None, "x" * 3000, "Dear Sir,"]), prompt)


class Clean(unittest.TestCase):
    def test_teacher_votes_average_over_windows_and_keep_agreement(self):
        import json
        import unittest.mock
        d = tempfile.mkdtemp(prefix="corpus-pairs-clean-")
        pages = [{"n": n, "pdf": f"F/{n}.pdf", "jpeg": f"J/{n}.jpg", "label": lab}
                 for n, lab in zip(range(1, 5), ("New", "Cont", "New", "Cont"))]
        with open(os.path.join(d, "windows.jsonl"), "w") as f:
            f.write(json.dumps({"folder_id": "f1", "split": "train", "text": "abbyy", "pages": pages[:3]}) + "\n")
            f.write(json.dumps({"folder_id": "f1", "split": "train", "text": "none", "pages": pages[1:]}) + "\n")

        def ans(nums, gaps):
            body = {"pages": [{"page": n, "kind": "document"} for n in nums],
                    "boundaries": [{"between": [x, x + 1], "decision": dec, "confidence": c, "cue": "c"}
                                   for x, (dec, c) in gaps.items()]}
            return {"collection": "f1", "window": nums, "status": "ok", "result": json.dumps(body)}
        run = os.path.join(d, "run"); os.makedirs(run)
        with open(os.path.join(run, "answers.jsonl"), "w") as f:
            f.write(json.dumps(ans([1, 2, 3], {1: ("continue", 0.9), 2: ("new", 0.6)})) + "\n")
            f.write(json.dumps(ans([2, 3, 4], {2: ("new", 0.8), 3: ("new", 0.7)})) + "\n")
            f.write("{half a line\n")
        with unittest.mock.patch.object(P, "CACHE", d):
            g = P.gap_labels(run)
        self.assertEqual(sorted(g), [("f1", 1), ("f1", 2), ("f1", 3)])
        self.assertAlmostEqual(g[("f1", 2)]["p_new"], 0.7)          # (0.6 + 0.8) / 2, both windows
        self.assertEqual(g[("f1", 2)]["n_judged"], 2)
        self.assertEqual([(g[k]["tag"], g[k]["keep"]) for k in sorted(g)],
                         [("cont", True), ("new", True), ("cont", False)])  # gap 3: tags say cont, teacher new


class OwnerCheck(unittest.TestCase):
    def gap(self, tag, p):
        return {"tag": tag, **{f"label_{r}": P.rule_label(tag, p, r) for r in P.RULES}}

    def test_strata_follow_how_start_trust_kept_the_label(self):
        self.assertEqual([P.check_stratum(self.gap(t, p)) for t, p in
                          (("new", 0.9), ("new", 0.3), ("new", 0.1), ("cont", 0.9), ("cont", 0.7), ("cont", 0.2))],
                         ["A", "B", None, "C", None, "D"])

    def test_noise_is_weighted_by_stratum_population_and_agree_skips_its_drops(self):
        cases = [{"id": i, "stratum": s, **self.gap(t, p)} for i, s, t, p in
                 (("a1", "A", "new", 0.9), ("a2", "A", "new", 0.9), ("c1", "C", "cont", 0.9),
                  ("c2", "C", "cont", 0.9), ("d1", "D", "cont", 0.1), ("d2", "D", "cont", 0.1))]
        key = {"population": {"A": 100, "C": 100, "D": 200}, "cases": cases}
        # A: both right. C (start-trust says new): one wrong, one unsure. D: one wrong of two.
        answers = {"a1": "new", "a2": "new", "c1": "same", "c2": "unsure", "d1": "same", "d2": "new", "x9": "new"}
        per, noise = P.check_noise(key, answers)
        self.assertEqual(per["start-trust"], {"A": [2, 0, 0], "C": [0, 1, 1], "D": [1, 1, 0]})
        self.assertNotIn("C", per["agree"])                          # agree drops C's labels
        self.assertAlmostEqual(noise["agree"][0], (100 * 0 + 200 * 0.5) / 300)
        self.assertAlmostEqual(noise["start-trust"][0], (100 * 0 + 100 * 1 + 200 * 0.5) / 400)
        self.assertEqual([noise[r][1] for r in ("agree", "start-trust")], [4, 5])


class ImageCheck(unittest.TestCase):
    def test_a_quarter_turned_original_is_nearest_its_page(self):
        from PIL import Image, ImageDraw
        d = tempfile.mkdtemp(prefix="corpus-pairs-test-")
        os.makedirs(os.path.join(P.CACHE, "tmp"), exist_ok=True)

        def page(path, seed):
            im = Image.new("RGB", (600, 800), "white"); dr = ImageDraw.Draw(im)
            for k in range(12):
                y = 40 + 60 * k
                dr.rectangle([40, y, 40 + (seed * 37 + k * 53) % 480 + 40, y + 20], fill="black")
            im.save(path)
            return im
        a = page(os.path.join(d, "a.png"), 1)
        page(os.path.join(d, "b.jpg"), 2)
        a.rotate(90, expand=True).save(os.path.join(d, "a.jpg"))
        a.save(os.path.join(d, "a.pdf"))                      # Pillow writes a one-page PDF; sips renders it
        h = P.image_hash(os.path.join(d, "a.pdf"), True)
        mine = P.distance(h, P.image_hash(os.path.join(d, "a.jpg"), False))
        other = P.distance(h, P.image_hash(os.path.join(d, "b.jpg"), False))
        self.assertLess(mine, 20)
        self.assertGreater(other - mine, P.MARGIN)


if __name__ == "__main__":
    unittest.main()
