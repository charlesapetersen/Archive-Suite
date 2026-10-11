"""Toy checks for options.py's mix rules and cost arithmetic (W36.seg-opt-measure).

Run: uv run -q --python 3.12 --with numpy --with requests python test_options.py   (no bench data, no network,
no key)."""
from __future__ import annotations

import sys

import ensemble as E
import options as O
from test_ensemble import box


def test_one_voter_rules_agree():
    b = box({"A": [("continue", .9), ("new", .7), ("continue", .55)]})
    for v in (-1, .5, .6, .7, .8, .95):
        with O.rule("min"):
            m = E.judge(b, "A", v)
        with O.rule("mean"):
            n = E.judge(b, "A", v)
        assert [(x[0], x[1]) for x in m.values()] == [(x[0], x[1]) for x in n.values()], v


def test_mean_can_accept_a_confident_disagreement():
    # gap 2-3: A says new at .9, B continue at .6 -> mean P(new) .65 -> new, combined confidence .65
    b = box({"A": [("continue", .9), ("new", .9), ("continue", .9)],
             "B": [("continue", .9), ("continue", .6), ("continue", .9)]})
    with O.rule("mean"):
        j = E.judge(b, "AB", .6)
        assert j[2][0] == "new" and not j[2][1]
        assert E.judge(b, "AB", .7)[2][1]
    with O.rule("min"):
        assert E.judge(b, "AB", -1)[2][1]  # min flags any disagreement


def test_rule_restores_the_ensemble_judge():
    before = E.judge
    with O.rule("mean"):
        assert E.judge is O.mean_judge
    assert E.judge is before


def test_cost_arithmetic():
    c = O.cost({"model": "claude-sonnet-5-5", "input_per_1000_pages": 1e6, "output_per_1000_pages": 1e5})
    assert abs(c["list_usd_per_1000_pages"] - 3.0) < 1e-9
    assert abs(c["batch_usd_per_1000_pages"] - 1.5) < 1e-9
    g = O.cost({"model": "gemini-3.8-flash", "input_per_1000_pages": 1e6, "output_per_1000_pages": 1e6})
    assert abs(g["list_usd_per_1000_pages"] - 4.5) < 1e-9
    assert abs(g["after_2026_12_31"]["list_usd_per_1000_pages"] - 9.0) < 1e-9


def test_figures_scale():
    b = box({"A": [("continue", .9), ("continue", .9), ("continue", .9)]})  # misses 2-3, never flagged
    f = O.figures(E.evaluate(b, "A", -1))
    assert f["unflagged_errors"] == 1 and f["flagged"] == 0
    assert abs(f["unflagged_errors_per_500_pages"] - 500 / 5) < 1e-9


def main() -> int:
    tests = [v for k, v in globals().items() if k.startswith("test_")]
    for t in tests:
        t()
    print(f"{len(tests)} passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
