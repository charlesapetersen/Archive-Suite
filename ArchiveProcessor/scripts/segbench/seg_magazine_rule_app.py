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


# --- scoring --------------------------------------------------------------------------------------

def g2_box(name):
    """ensemble.Box for one box with voter G = the g2 answers, combined as seg_magazine_rule.test_boxes does."""
    import ensemble as E
    col = data.load(name, with_exif=False)
    with arm(name) as (_, W, _, M):
        comb = M.combine_units(col, W.windows(len(col.pages)), answer)
        box = E.Box(col, "")
        box.v = {"G": E._from_bounds(col, W.assemble(col, comb, True))}
    return box


def spend():
    with arm(DEV[0]) as (_, _, S, _):
        SB.check_reservations(S)
        import gateway_gemini as GW
        calls = S.settled()
        return {"calls": len(calls), "spent_usd": S.spent(), "billed": S.settled_billed(),
                "billed_note": GW.billed_note(calls, "estimate"),
                "retained_usd": S.spent() - sum(r["charge"] for r in calls),
                "invalid": sum(not r.get("valid") for r in calls),
                "item_total_usd": REDO_SPENT + S.spent()}


def gemini_row(old, level, test, dev_held):
    """options.json's Gemini row on g2: the voter, level and figures replaced, 3.8's tokens and price kept."""
    row = {k: v for k, v in old.items() if k != "replaces"}
    row.update(voters=[VOTER], level=level, figures={**test, "dev_held_out": dev_held}, evidence=EVIDENCE,
               figures_note="These figures were measured on Gemini 3.7 Flash with the same prompt; Gemini 3.8 Flash, "
                            "which this approach calls, has not been measured on it.",
               note="The app's voter is Gemini 3.8 Flash sending g2; its level and every figure here are Gemini "
                    "3.7 Flash's g2 answers through the Stanford gateway, the level fitted on them on the "
                    "development boxes (W46.seg-magazine-rule-app). Tokens and price are 3.8's, measured on g1.",
               replaces={"voters": old["voters"], "rule": old["rule"], "level": old["level"],
                         "test": old["figures"]["test"], "test_by_box": old["figures"]["test_by_box"],
                         "dev_held_out": old["figures"]["dev_held_out"]})
    return row


def cmd_score(_a):
    import rescore
    rescore.no_network()
    import ensemble as E
    import options as O
    missing = [(c.name, a, b) for c, a, b in jobs(DEV + TEST) if answer(c, a, b) is None]
    if missing:
        raise SystemExit(f"{len(missing)} windows have no answer, first {missing[:3]}")
    S = ("G",)
    dev = {n: g2_box(n) for n in DEV}
    with O.rule("min"):
        lo = E.loco(dev, S)
        level = E.fit_level(list(dev.values()), S)
        test = {n: g2_box(n) for n in TEST}
        per = [E.evaluate(test[n], S, level) | {"name": n} for n in TEST]
        old_level = json.loads((RESULTS / "options-frozen.json").read_text())["approaches"]["gemini"]["level"]
        at_old = O.figures(E.pooled([E.evaluate(test[n], S, old_level) | {"name": n} for n in TEST]))
        wrong = {n: SB.unflagged_gaps(test[n], S, level) for n in TEST}
    dev_held = O.figures(lo["pooled"])
    figs = {"test": O.figures(E.pooled(per)), "test_by_box": {r["name"]: O.figures(r) for r in per}}
    opts = json.loads((RESULTS / "options.json").read_text())
    k = next(i for i, a in enumerate(opts["approaches"]) if a["id"] == "gemini")
    old = opts["approaches"][k]
    if VOTER in old["voters"]:   # a rerun: rebuild the g1 row this item replaced from its own record
        r = old["replaces"]
        old = {**old, "voters": r["voters"], "rule": r["rule"], "level": r["level"],
               "figures": {"test": r["test"], "test_by_box": r["test_by_box"], "dev_held_out": r["dev_held_out"]}}
    out = {"tag": TAG, "date": dt.date.today().isoformat(), "evidence": EVIDENCE, "rule": "min", "level": level,
           "level_g1_3_8": old_level, "dev_levels_held_out": lo["levels"],
           "dev_held_out": dev_held, "dev_by_box": {r["name"]: O.figures(r) for r in lo["rows"]},
           "dev_reached": lo["reached"], "test": figs, "test_at_g1_level": at_old, "unflagged_gaps": wrong,
           "g1_3_8": {"level": old["level"], "test": old["figures"]["test"],
                      "dev_held_out": old["figures"]["dev_held_out"]},
           "gateway": spend()}
    (RESULTS / "seg-magazine-rule-app.json").write_text(json.dumps(out, indent=1) + "\n")
    (RESULTS / "seg-magazine-rule-app.md").write_text(render(out))
    opts["approaches"][k] = gemini_row(old, level, figs, dev_held)
    opts["gemini_g2"] = {"date": out["date"], "item": TAG, "level": level, "evidence": EVIDENCE,
                         "result": "segbench-results/seg-magazine-rule-app.md"}
    (RESULTS / "options.json").write_text(json.dumps(opts, indent=1) + "\n")
    O.render(opts)   # options.md; settings-routes.json is rebuilt by settings_routes.py from the stage notes
    print(json.dumps({k: out[k] for k in ("level", "dev_held_out", "test", "test_at_g1_level", "unflagged_gaps",
                                          "gateway")}, indent=1))


def _p(x, d=1):
    return "—" if x is None else f"{100 * x:.{d}f}%"


def _row(label, f):
    return (f"| {label} | {_p(f['pages_exact_no_review'])} | {f['flagged_per_100_pages']:.1f} | "
            f"{_p(f['pages_exact_after_review'])} | {f['unflagged_errors']} | {f['unflagged_errors_per_500_pages']:.1f} |")


def render(out) -> str:
    import ensemble as E
    import seg_card
    t, g, d = out["test"]["test"], out["g1_3_8"], out["dev_held_out"]
    hdr = ["| | pages exact, no checking | checks per 100 pages | pages exact after checking | unflagged errors | "
           "per 500 pages |", "|---|---:|---:|---:|---:|---:|"]
    gw = out["gateway"]
    L = ["# The app's Gemini voter on prompt g2 (W46.seg-magazine-rule-app)", "",
         "Generated by `ArchiveProcessor/scripts/segbench/seg_magazine_rule_app.py score` from the gateway caches; no "
         "call is made in scoring.", "",
         "The app's Gemini window voter (Gemini 3.8 Flash, thinking low) now sends prompt g2, g1 with rule 10 on the "
         "owner's article-within-issue rule (W46.seg-magazine-rule-redo, seg-magazine-rule.md). Owner, walkthrough "
         "2026-11-10: no Gemini 3.8 run on the personal key, so **its level and every figure below are Gemini 3.7 "
         "Flash's g2 answers through the Stanford gateway**, labelled so wherever they are shown, as the 2026-11-06 "
         "call already labels the 3.8 card with 3.7's figures.", "",
         f"## The level, refit on g2 (rule min, {E.BAR:.0%} of pages right after checking)", "",
         f"Fitted on all three development boxes (Dean, Deaver, Herrnstein; {d['pages']} pages): **{E.lv(out['level'])}**, "
         f"against {E.lv(out['level_g1_3_8'])} fitted for 3.8 on g1. Held out, each box at the level fitted on the "
         "other two: " + ", ".join(f"{n} {E.lv(v)}" for n, v in out["dev_levels_held_out"].items())
         + f"; {out['dev_reached']} of 3 boxes reach the bar."
         + (" The refit level is the level already shipped, so the app's level does not change and the test-box "
            "figures are seg-magazine-rule.md's." if out["level"] == out["level_g1_3_8"] else ""), ""]
    L += hdr + [_row("g2 on 3.7, held out (pooled)", d)]
    L += [_row(f"  {n}", r) for n, r in out["dev_by_box"].items()]
    L += [_row("g1 on 3.8, held out (pooled; options-frozen.json)", g["dev_held_out"])]
    L += ["", "## The test boxes, Stanton + RG165 (363 pages), scored once at the refit level", ""]
    L += hdr + [_row(f"g2 on 3.7 at {E.lv(out['level'])} (the app's figures now)", t)]
    L += [_row(f"  {n}", r) for n, r in out["test"]["test_by_box"].items()]
    L += [_row(f"g2 on 3.7 at {E.lv(out['level_g1_3_8'])} (seg-magazine-rule.md)", out["test_at_g1_level"]),
          _row(f"g1 on 3.8 at {E.lv(g['level'])} (the figures it replaces)", g["test"])]
    uw = [f"{b} {x['gap']} (said {x['said']}, {x['confidence']:.3f})" for b, xs in out["unflagged_gaps"].items()
          for x in xs]
    L += ["", "Unflagged errors at the refit level: " + (", ".join(uw) if uw else "none") + ".", "",
          "## Gateway", "",
          f"{gw['calls']} settled calls on the development boxes, ${gw['spent_usd']:.4f} counted of the "
          f"${CAP:.2f} cap ({gw['billed_note']}), {gw['invalid']} invalid. With W46.seg-magazine-rule-redo's "
          f"${REDO_SPENT:.4f} the work's total is ${gw['item_total_usd']:.4f}, inside the $7 rule.", ""]
    L += seg_card.card(
        truth="The owner's development boxes (Dean, Deaver, Herrnstein) for the level and the test boxes (Stanton with "
              "the owner's 2026-10-31 newsletter rulings on the article rule, RG165), truth photo labels; no route "
              "drafted any of it. The Illustrated Review's article rulings are seg-magazine-rule.md's.",
        selection="The boxes options.py fits and scores on, fixed since 2026-10-11; nothing chosen by a route's "
                  "answers or ABBYY text.",
        comparison="g2 on Gemini 3.7 against g1 on Gemini 3.8: two changes at once (prompt and model). The 3.7 g1 "
                   "against 3.7 g2 comparison, one change, is seg-magazine-rule.md's. Same windows, images, Vision "
                   "text and scorer.",
        noise="Single runs. The rerun floor is 1.4-3.2 points of pages exact a box (seg-boxes-score.md); the error "
              "counts are a few gaps, so a difference of one or two is within noise.",
        scope="Gemini 3.7, not the 3.8 the app sends (the gateway does not serve 3.8; the owner declined the "
              "personal-key run): the level shipped to 3.8 is fitted on 3.7's answers. Not the ChatGPT voter's c1, "
              "which keeps g1's rule 10 until the plan-route hold lifts (W46.gateway-models-ok). The magazine figure "
              "the 3.8 card now ranks on (93.8%) is the Illustrated Review set g2 was adopted on, not a held-out one. "
              "The settings solver's profile D5 now picks Gemini over Claude by 3.3 points, 0.1 past the 3.2 floor, "
              "on this one run.")
    return "\n".join(L) + "\n"


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
