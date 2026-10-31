"""kit_gate.py's per-document records leave unsure gaps out (W46.seg-unsure-mask).
Run: python test_kit_gate.py   (no data, no network)."""
import random
import unittest

import kit_gate as K

N, C = "New", "Cont"


def rec(unsure):
    # Truth: documents [0,1] [2,3] [4,5]. Gap 1|2 (right page 2) may be unsure. The model joins 1|2, else exact.
    labels = [N, C, N, C, N, C]
    truth = ["continue", "new", "continue", "new", "continue"]
    gaps = [i for i in range(5) if i + 1 not in unsure]
    model = [N, C, C, C, N, C]
    calls = ["continue", "continue", "continue", "new", "continue"]
    return {"box": "toy", "labels": labels, "unsure": sorted(unsure),
            "gaps": [{"i": i, "truth": truth[i]} for i in gaps],
            "models": {"m": {"labels": model, "gaps": [[calls[i], 0.9] for i in gaps]},
                       "ref": {"labels": labels, "gaps": [[truth[i], 0.9] for i in gaps]}}}


class Documents(unittest.TestCase):
    def test_unsure_gap_is_no_error_and_its_documents_are_unresolved(self):
        docs = K.documents(rec({2}))
        self.assertEqual([d["exact_pages"] for d in docs], [0, 0, 2])
        self.assertEqual([d["m"]["m"][:2] for d in docs], [(0, 0), (0, 0), (1, 0)])
        self.assertEqual([d["m"]["ref"][0] for d in docs], [0, 0, 1])   # the reference is scored on the same support

    def test_no_unsure_is_unchanged(self):
        docs = K.documents(rec(set()))
        self.assertEqual([d["exact_pages"] for d in docs], [2, 2, 2])
        self.assertEqual([d["m"]["m"][:2] for d in docs], [(0, 0), (0, 1), (1, 0)])

    def test_bootstrap_pages_exact_is_over_resolved_pages(self):
        b = K.bootstrap(K.documents(rec({2})), "ref", "m", 3, random.Random(0))
        self.assertEqual((b["pages exact"]["lo"], b["pages exact"]["hi"]), (0.0, 0.0))
        self.assertEqual((b["gap accuracy"]["lo"], b["gap accuracy"]["hi"]), (0.0, 0.0))


if __name__ == "__main__":
    unittest.main(verbosity=1)
