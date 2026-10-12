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


def test_mix_label_names_its_voters():
    assert O.label_of("mix", ("C", "G")) == "Claude and Gemini together"
    assert O.label_of("mix", ("C", "G", "O")) == "Claude, Gemini and ChatGPT together"
    assert O.label_of("openai", ("O",)) == "ChatGPT only"


def test_openai_voter_string_resolves_like_the_app():
    # SegmentationApproach.swift WindowVoter.resolve: the name before " (" and a "prompt <id>" inside
    v = O.VOTER_NAMES["O"]
    assert v.split(" (")[0] == "window-openai" and "prompt c1" in v


def test_codex_usage_reads_the_last_total(tmp=None):
    import json, os, tempfile
    import method_window_cues as WC
    sid = "01a12d7b-db81-70e1-b772-0f1be915e3a5"
    with tempfile.TemporaryDirectory() as d:
        f = os.path.join(d, "sessions", "2026", "10", "11")
        os.makedirs(f)
        ev = lambda i, o: json.dumps({"payload": {"type": "token_count", "info": {"total_token_usage": {  # noqa: E731
            "input_tokens": i, "cached_input_tokens": 7, "output_tokens": o, "reasoning_output_tokens": 1}}}})
        with open(os.path.join(f, f"rollout-2026-10-11T17-20-54-{sid}.jsonl"), "w") as fh:
            fh.write("\n".join([ev(10, 2), json.dumps({"payload": {"type": "token_count", "info": None}}),
                                 "not json", ev(30, 5)]) + "\n")
        old = os.environ.get("CODEX_HOME")
        os.environ["CODEX_HOME"] = d
        try:
            u = WC.codex_usage(f"header\nsession id: {sid}\n--------")
            assert u == {"input_tokens": 30, "cached_input_tokens": 7, "output_tokens": 5,
                         "reasoning_output_tokens": 1}, u
            assert WC.codex_usage("no session line") is None
        finally:
            if old is None:
                del os.environ["CODEX_HOME"]
            else:
                os.environ["CODEX_HOME"] = old


def test_cost_uses_input_without_the_harness():
    O.PRICES["toy"] = {"in": 1.0, "out": 10.0, "batch_in": .5, "batch_out": 5.0, "read": "x", "source": "y"}
    try:
        c = O.cost({"model": "toy", "input_per_1000_pages": 3e6, "input_excluding_harness_per_1000_pages": 1e6,
                    "output_per_1000_pages": 1e5})
        assert abs(c["list_usd_per_1000_pages"] - 2.0) < 1e-9
    finally:
        del O.PRICES["toy"]


def test_usage_guard_ignores_a_reading_from_a_reset_window():
    """A stale reading stood at 91% past its window's reset until something called Codex (W36.seg-opt-openai)."""
    import subprocess, time
    import method_window_cues as WC

    class R:
        def __init__(self, out): self.stdout = out  # noqa: E704
    real = subprocess.run
    outs = {}
    subprocess.run = lambda *a, **k: R(outs["raw"])  # noqa: E731
    try:
        outs["raw"] = f"91 {int(time.time()) - 60}\n"      # the window reset a minute ago
        assert WC.used_pct("codex") == 0
        outs["raw"] = f"91 {int(time.time()) + 3600}\n"    # still inside its window
        assert WC.used_pct("codex") == 91
        outs["raw"] = ""                                   # no reading at all
        assert WC.used_pct("codex") == 100
        outs["raw"] = "junk\n"
        assert WC.used_pct("codex") == 100
    finally:
        subprocess.run = real


def main() -> int:
    tests = [v for k, v in globals().items() if k.startswith("test_")]
    for t in tests:
        t()
    print(f"{len(tests)} passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
