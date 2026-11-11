#!/usr/bin/env python3
"""W46.seg-magazine-rule-app: the app's Gemini window voter moved to prompt g2 (the article-within-issue rule), on
Gemini 3.7 Flash's evidence through the Stanford gateway.

  python3 seg_magazine_rule_app.py plan        # windows, cached answers and the gateway estimate (no calls)
  python3 seg_magazine_rule_app.py collect     # g2 on the development boxes through the gateway (paid, capped)
  python3 seg_magazine_rule_app.py retry-once  # one retry of a request the Mac's sleep cut off (allowance kept)
  <lab venv>/bin/python seg_magazine_rule_app.py score   # the level refit, the test boxes, options.json's Gemini
                                               # row -> segbench-results/seg-magazine-rule-app.{json,md} (no calls)

Owner, walkthrough 2026-11-10: no Gemini 3.8 run on the personal key ("Do we really need Gemini 3.8 for this? It
seems unlikely to be significantly different."). The app's voter, Gemini 3.8 Flash at thinking low, sends g2, and
everything shipped with it is measured on Gemini 3.7 Flash through the gateway and labelled so, as the
2026-11-06 call already labels the 3.8 card with 3.7's figures.

THE STEPS, fixed before any development answer:
- g2 on the development boxes (Dean, Deaver, Herrnstein: 551 pages) in method_window's 7-page windows at stride 3,
  with seg_magazine_rule's request, parser and gateway module (temperature 0, reasoning low), this item's own
  store and cap. The test boxes' g2 answers are W46.seg-magazine-rule-redo's, read from its store (no new call).
- The level is fitted exactly as options.py fits it (ensemble.fit_level on all three development boxes, rule min,
  the 98% bar after review); the held-out rows each use the level fitted on the other two (ensemble.loco).
- The test boxes (Stanton + RG165) are scored once at that level with options.py's five figures, and the gateway
  figures replace options.json's Gemini row, which keeps 3.8's token and price figures (the voter the app pays
  for; g2 adds one rule's words to the prompt). Nothing is chosen on the test boxes: the approach, rule and voter
  are fixed, and g2 was adopted by W46.seg-magazine-rule-redo.
- The engine fixture's Gemini answers on Deaver become these g2 answers (export_engine_fixture.py).
Money: the gateway is real money on a Stanford PTA. The redo spent $1.93 of this work; CAP keeps the item's total
under the $7 rule. Owner images and text go only to the gateway and the caches, never into git (the repo is public).
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import datetime as dt
import fcntl
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import data  # noqa: E402
import seg_boxes_score as SB  # noqa: E402
import seg_magazine_rule as MR  # noqa: E402

TAG = "W46.seg-magazine-rule-app"
STORE = SB.REHEARSAL / "seg-magazine-rule-app-gateway"
CAP = 2.60
REDO_SPENT = 1.9320   # W46.seg-magazine-rule-redo's counted gateway spend (seg-magazine-rule.md), part of this work
RESULTS = SB.RESULTS
DEV, TEST = tuple(data.DEV), tuple(data.TEST)
VOTER = "window-gemini-3.8-flash-low (Gemini 3.8 Flash, thinking low, prompt g2)"
EVIDENCE = ("Gemini 3.7 Flash through the Stanford gateway, prompt g2 (W46.seg-magazine-rule-app; the gateway "
            "does not serve 3.8, and the owner declined a 3.8 run on the personal key, 2026-11-10)")


@contextmanager
def arm(name):
    """seg_magazine_rule's g2 arm with the store that holds box `name`'s answers: this item's for a development box,
    the redo's for a test box."""
    with MR.arm("g2") as mods:
        S = mods[2]
        prev = S.STORE, S.CAP
        if name in DEV:
            S.STORE, S.CAP = STORE, CAP
        try:
            yield mods
        finally:
            S.STORE, S.CAP = prev


def answer(col, a, b, allow_call=False):
    """The parsed g2 reply, the neutral vote for a recorded invalid model reply, or None if never asked."""
    with arm(col.name) as (L, _, S, _):
        body, key, nums = S.request("gemini", col, a, b)
        hit = S.cache_hit(body, key)
        if hit is None:
            return None
        if hit.get("valid"):
            return S.parse(hit["raw"], nums, False)
        rec = next((r for r in S.effective_records() if r["id"] == hit["request"]["id"]), {})
        if not SB.invalid_model_reply(hit, rec):
            raise RuntimeError(f"{col.name} {nums[0]}-{nums[-1]}: provider/usage failure, not a model vote")
        return L.neutral(nums)


def jobs(boxes):
    with arm(DEV[0]) as (_, W, _, _):
        cols = [data.load(b, with_exif=False) for b in boxes]
        return [(c, a, b) for c in cols for a, b in W.windows(len(c.pages))]


def cmd_plan(_a):
    js = jobs(DEV)
    with arm(DEV[0]) as (_, _, S, _):
        spent = S.spent()
    todo = [j for j in js if answer(*j) is None]
    test_missing = [j for j in jobs(TEST) if answer(*j) is None]
    print(f"g2 development windows {len(js)}, uncached {len(todo)}, spent ${spent:.4f} of ${CAP:.2f}; about "
          f"${0.0112 * len(todo):.2f} to go at the redo's $0.0112 a window; item total with the redo "
          f"${REDO_SPENT + spent:.4f}; test-box g2 answers missing {len(test_missing)}")


def cmd_collect(a):
    if a.workers != 1:
        raise SystemExit("collect requires --workers 1 to keep the item spending cap exact")
    js = jobs(DEV)
    STORE.mkdir(parents=True, exist_ok=True)
    with (STORE / "collect.lock").open("a") as fh, arm(DEV[0]) as (_, _, S, _):
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        SB.check_reservations(S)
        SB.check_prior_failures(S)
        todo = [j for j in js if answer(*j) is None][: a.limit or None]
        SB.gateway_key()
        print(f"{len(todo)} windows to send, item spent ${S.spent():.4f} of ${CAP:.2f}", flush=True)
        invalid = []
        for k, (col, lo, hi) in enumerate(todo, 1):
            try:
                S.call("gemini", col, lo, hi)
            except RuntimeError as e:
                body, key, nums = S.request("gemini", col, lo, hi)
                hit = S.cache_hit(body, key)
                rec = next((r for r in S.effective_records()
                            if hit is not None and r["id"] == hit["request"]["id"]), {})
                if not SB.invalid_model_reply(hit, rec):
                    raise
                invalid.append(f"{col.name} {nums[0]}-{nums[-1]}: {e}")
                if len(invalid) > 5:
                    raise RuntimeError("more than five invalid model replies; inspect before continuing") from e
            if k % 10 == 0:
                print(f"  {k}/{len(todo)}, item spent ${S.spent():.4f}", flush=True)
        print(f"done; item spent ${S.spent():.4f}; invalid replies {len(invalid)}", flush=True)
        for x in invalid:
            print("  invalid", x)


def cmd_retry_once(_a):
    STORE.mkdir(parents=True, exist_ok=True)
    with (STORE / "collect.lock").open("a") as fh, arm(DEV[0]) as (_, _, S, _):
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        S.retry_unsettled_once()
        print(f"retry approved; item spent ${S.spent():.4f} of ${CAP:.2f}")


def cmd_score(_a):
    raise SystemExit("score: not written yet")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan")
    c = sub.add_parser("collect")
    c.add_argument("--workers", type=int, default=1)
    c.add_argument("--limit", type=int, default=0)
    sub.add_parser("retry-once")
    sub.add_parser("score")
    a = ap.parse_args()
    {"plan": cmd_plan, "collect": cmd_collect, "retry-once": cmd_retry_once, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    main()
