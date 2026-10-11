"""Toy checks for ensemble.py's rule, threshold fit and review accounting (W36.seg-ensemble).

Run: <lab venv>/bin/python test_ensemble.py   (no bench data, no network, no key)."""
from __future__ import annotations

import sys

import ensemble as E


class ToyBox(E.Box):
    """A box built from labels and per-voter (decision, confidence) lists, without loading anything."""

    def __init__(self, name, labels, votes):
        self.name, self.labels, self.pages = name, labels, len(labels)
        self.gaps = E.doc_gap_index(labels)
        ids = E.segment_ids(labels)
        self.truth = {i: "new" if ids[i] != ids[i + 1] else "continue" for i in self.gaps}
        self.v = {c: dict(zip(self.gaps, vs)) for c, vs in votes.items()}


# Folder photo, then pages New Cont New Cont: document gaps 1-2, 2-3, 3-4.
LABELS = ["Folder", "New", "Cont", "New", "Cont"]


def box(votes, name="toy"):
    return ToyBox(name, LABELS, votes)


def test_unanimous_right_is_exact():
    b = box({"A": [("continue", .9), ("new", .9), ("continue", .9)],
             "B": [("continue", .8), ("new", .8), ("continue", .8)]})
    r = E.evaluate(b, "AB", -1)
    assert r["flagged"] == 0 and r["acc_err"] == 0 and E.pe(r["auto"]) == 1.0


def test_disagreement_is_flagged_and_review_fixes_it():
    b = box({"A": [("continue", .9), ("continue", .9), ("continue", .9)],    # misses the boundary at 2-3
             "B": [("continue", .9), ("new", .6), ("continue", .9)]})
    r = E.evaluate(b, "AB", -1)
    assert r["flagged"] == 1 and r["acc_err"] == 0
    assert E.pe(r["auto"]) == 0.0          # tie goes to the more confident A: one merged document
    assert E.pe(r["rev"]) == 1.0


def test_agreed_error_survives_review_unless_below_level():
    b = box({"A": [("new", .7), ("new", .9), ("continue", .9)],              # both falsely split 1-2
             "B": [("new", .8), ("new", .9), ("continue", .9)]})
    r = E.evaluate(b, "AB", -1)
    assert r["flagged"] == 0 and r["acc_err"] == 1 and E.pe(r["rev"]) == 0.5
    r = E.evaluate(b, "AB", 0.7)           # the lowest confidence there is 0.7: flagged at v = 0.7
    assert r["flagged"] == 1 and r["acc_err"] == 0 and E.pe(r["rev"]) == 1.0


def test_majority_of_three():
    b = box({"A": [("continue", .6), ("new", .9), ("continue", .9)],
             "B": [("continue", .6), ("new", .9), ("continue", .9)],
             "C": [("new", .99), ("new", .9), ("continue", .9)]})
    r = E.evaluate(b, "ABC", -1)
    assert r["flagged"] == 1 and E.pe(r["auto"]) == 1.0   # two continues beat one confident new


def test_fit_level_is_the_smallest_that_reaches_the_bar():
    b1 = box({"A": [("new", .7), ("new", .9), ("continue", .9)]}, "one")
    b2 = box({"A": [("continue", .95), ("new", .9), ("new", .8)]}, "two")
    assert E.levels([b1, b2], "A") == [-1.0, .7, .8, .9, .95]
    assert E.fit_level([b1, b2], "A") == .8     # flags 0.7 and 0.8, the two wrong gaps
    perfect = box({"A": [("continue", .9), ("new", .9), ("continue", .9)]})
    assert E.fit_level([perfect], "A") == -1.0


def test_loco_applies_the_other_folds_level():
    import data
    saved = data.DEV
    try:
        data.DEV = ("x", "y", "z")
        boxes = {"x": box({"A": [("new", .7), ("new", .9), ("continue", .9)]}, "x"),
                 "y": box({"A": [("new", .7), ("new", .9), ("continue", .9)]}, "y"),
                 "z": box({"A": [("new", .6), ("new", .9), ("continue", .9)]}, "z")}
        r = E.loco(boxes, "A")
        assert r["levels"] == {"x": .7, "y": .7, "z": .7}
        # z's wrong gap (0.6) is below the level fitted on x and y, so it is flagged and fixed.
        assert r["reached"] == 3 and r["pooled"]["acc_err"] == 0
    finally:
        data.DEV = saved


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
        print(f"ok  {t.__name__}")
    print(f"{len(tests)}/{len(tests)} passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
