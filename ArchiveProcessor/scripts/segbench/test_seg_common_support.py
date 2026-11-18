"""Common support, bounds and paired outcomes: synthetic pages only, no model or network."""
import itertools
import unittest

import ensemble as E
import options as O
from score import Truth, resolved_documents, score_labels
from test_ensemble import ToyBox
import seg_text_tier_test as T
import seg_common_support as C


class CommonSupport(unittest.TestCase):
    def test_interrupted_rescore_recovers_conditional_upper_from_export(self):
        b = ToyBox("unknown", Truth(["New", "Cont", "New", "New"], unsure=[1]),
                   {"G": [("new", .99), ("continue", .99), ("new", .99)]})
        b.unsure = {0}
        f = O.figures(E.evaluate(b, "G", -1))
        self.assertEqual(f["pages_exact_no_review"], .5)
        legacy = C.conditional_figures(f)
        self.assertEqual(legacy["pages_exact_no_review"], .5)
        b.v["G"][0] = ("continue", .99)
        f = O.figures(E.evaluate(b, "G", -1))
        self.assertEqual(f["pages_exact_no_review"], .5)
        self.assertEqual(C.conditional_figures(f)["pages_exact_no_review"], .25)
        self.assertEqual(C.conditional_figures(legacy), legacy)

    def test_support_is_invariant_to_unknown_storage_and_route_photo_errors(self):
        # Two adjacent unknowns; only the last two-page document is resolvable.
        raw = ["Folder", "New", "Cont", "New", "New", "Cont"]
        unknown = [2, 3]
        for stored in itertools.product(("New", "Cont"), repeat=2):
            labels = list(raw)
            for i, call in zip(unknown, stored):
                labels[i] = call
            truth = Truth(labels, unsure=unknown)
            self.assertEqual(resolved_documents(truth), [frozenset((4, 5))])
            for pred in itertools.product(("New", "Cont", "Folder"), repeat=5):
                pred = ["Folder", *pred]
                c = score_labels(truth, pred)
                readings = []
                for calls in itertools.product(("New", "Cont"), repeat=2):
                    fixed = list(labels)
                    for i, call in zip(unknown, calls):
                        fixed[i] = call
                    readings.append(score_labels(fixed, pred).pages_exact)
                self.assertEqual(c.resolved_doc_pages, 2)
                self.assertEqual(c.pages_exact_low, min(readings))
                self.assertEqual(c.pages_exact, max(readings))

    def test_paired_outcomes_exclude_unknown_documents_and_match_export(self):
        truth = Truth(["New", "Cont", "New", "New"], unsure=[1])
        outcomes = []
        for call in ("new", "continue"):
            b = ToyBox("unknown", truth, {"G": [(call, .5), ("continue", .99), ("new", .99)]})
            b.unsure = {0}
            r = E.evaluate(b, "G", .5)
            f = O.figures(r)
            flags = T.page_flags(b, "G", .5, r)
            self.assertEqual(flags, [[None, None, False, True], [None, None, False, True]])
            self.assertEqual(f["pages_exact_no_review"], sum(bool(x) for x in flags[0]) / 2)
            outcomes.append(flags)
        paired = T.SWG.bootstrap([bool(x) for x in outcomes[0][0]], [bool(x) for x in outcomes[1][0]],
                                 [sorted(g) for g in resolved_documents(truth)], rounds=50)
        self.assertEqual((paired["delta"], paired["pages"], paired["runs"]), (0, 2, 2))


if __name__ == "__main__":
    unittest.main()
