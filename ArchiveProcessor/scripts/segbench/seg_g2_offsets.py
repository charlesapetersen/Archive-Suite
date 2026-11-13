#!/usr/bin/env python3
"""W46.seg-g2-offsets (measurement review pass 14, P14-1): Gemini 3.7 Flash on prompt g2 at window offsets 1 and 2 on
the test boxes, so the app's Gemini figure (one offset-0 run) becomes the range over three offsets.

  python3 seg_g2_offsets.py plan        # windows, cached answers and the gateway estimate (no calls)
  python3 seg_g2_offsets.py collect     # the offset 1 and 2 windows through the gateway (paid, capped)
  python3 seg_g2_offsets.py retry-once  # one retry of a request the Mac's sleep cut off (allowance kept)
  <lab venv>/bin/python seg_g2_offsets.py score   # -> segbench-results/seg-g2-offsets.{json,md}, options.json's
                                                  # Gemini range (no calls)

THE ARMS, fixed before any answer:
- Prompt g2 (method_gemini.RULE10_G2) with seg_magazine_rule's request, parser and gateway module: Gemini 3.7 Flash
  through the Stanford gateway, 1600 px images and cached Vision text, temperature 0, reasoning low, this item's own
  store and cap. Offset 0 is W46.seg-magazine-rule-redo's g2 run, read from its store (no new call); a window an
  offset shares with it (the box's last) is read from there too.
- Windows: Stanton and RG165 (363 pages) in seven-page windows at stride 3, starting 1 and 2 pages later
  (seg_window_modality.spans, as W46.seg-boxes-score ran g1).
- Scoring: options.py's five figures at the app's rule and level (min, <= 0.965: fitted for 3.8 on g1 and refit on
  3.7's g2, W46.seg-magazine-rule-app), each offset alone; nothing refit or chosen on the test boxes. The shown
  Gemini figure becomes the range over the three offsets (07-segmentation.md §6); options.json's Gemini row keeps its
  offset-0 figures and gains the range beside them.
Money: the gateway is real money on a Stanford PTA; CAP keeps this item under the $7 rule. Owner images and text go
only to the gateway and the caches, never into git (the repo is public).
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

TAG = "W46.seg-g2-offsets"
STORE = SB.REHEARSAL / "seg-g2-offsets-gateway"
CAP = 3.00
RESULTS = SB.RESULTS
TEST = ("Stanton", "RG165")
NEW_OFFSETS = (1, 2)
OFFSETS = (0, 1, 2)
RULE, LEVEL = "min", 0.965   # the app's (seg-magazine-rule-app.json), asserted against options.json when scoring


@contextmanager
def arm(store):
    """seg_magazine_rule's g2 arm reading and writing `store` (this item's, or the redo's for offset 0)."""
    with MR.arm("g2") as mods:
        S = mods[2]
        prev = S.STORE, S.CAP
        S.STORE, S.CAP = store
        try:
            yield mods
        finally:
            S.STORE, S.CAP = prev


OWN, REDO = (STORE, CAP), (MR.STORE, MR.CAP)


def _hit(store, col, a, b):
    with arm(store) as (L, _, S, _):
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


def answer(col, a, b):
    """The g2 reply for a window from the redo's store or this item's, the neutral vote for an invalid model reply,
    or None if never asked."""
    got = _hit(REDO, col, a, b)
    return got if got is not None else _hit(OWN, col, a, b)


def spans(col, o):
    with arm(OWN) as (_, _, _, M):
        return M.spans(len(col.pages), 7, o)


def jobs():
    """[(col, a, b)] the new offsets' windows, without repeats."""
    out, seen = [], set()
    for o in NEW_OFFSETS:
        for b in TEST:
            col = data.load(b, with_exif=False)
            for a, z in spans(col, o):
                if (b, a, z) not in seen:
                    seen.add((b, a, z))
                    out.append((col, a, z))
    return out


def cmd_plan(_a):
    js = jobs()
    with arm(OWN) as (_, _, S, _):
        spent = S.spent()
    todo = [j for j in js if answer(*j) is None]
    print(f"g2 offset 1-2 windows {len(js)}, uncached {len(todo)}, spent ${spent:.4f} of ${CAP:.2f}; about "
          f"${0.0107 * len(todo):.2f} to go at the redo's test-box $0.0107 a window")


def cmd_collect(a):
    if a.workers != 1:
        raise SystemExit("collect requires --workers 1 to keep the item spending cap exact")
    js = jobs()
    STORE.mkdir(parents=True, exist_ok=True)
    with (STORE / "collect.lock").open("a") as fh, arm(OWN) as (_, _, S, _):
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
    with (STORE / "collect.lock").open("a") as fh, arm(OWN) as (_, _, S, _):
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        S.retry_unsettled_once()
        print(f"retry approved; item spent ${S.spent():.4f} of ${CAP:.2f}")


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


# --- scoring --------------------------------------------------------------------------------------

KEYS = ("pages_exact_no_review", "flagged_per_100_pages", "pages_exact_after_review",
        "unflagged_errors_per_500_pages", "usd_per_1000_pages")


def offset_row(o):
    """options.py's five figures for one offset on Stanton + RG165 at the app's rule and level, and its cost."""
    import ensemble as E
    import options as O
    store = REDO if o == 0 else OWN
    per, costs, failed, wrong = [], {}, 0, {}
    for b in TEST:
        col = data.load(b, with_exif=False)
        sp = spans(col, o)
        with arm(store) as (_, W, S, M):
            SB.check_reservations(S)
            costs[b] = SB.offset_cost(S, col, sp)
            for a, z in sp:
                j = answer(col, a, z)
                failed += j is not None and bool(j["boundaries"]) and all(
                    x.get("cue") == "(window failed)" for x in j["boundaries"].values())
            comb = M.combine_units(col, sp, lambda c, a, z: answer(c, a, z))
            box = E.Box(col, "")
            box.v = {"G": E._from_bounds(col, W.assemble(col, comb, True))}
        with O.rule(RULE):
            per.append(E.evaluate(box, ("G",), LEVEL) | {"name": b})
            wrong[b] = SB.unflagged_gaps(box, ("G",), LEVEL)
    p = E.pooled(per)
    fig = O.figures(p)
    fig["usd_per_1000_pages"] = 1000 * sum(c["charged_usd"] for c in costs.values()) / p["pages"]
    fig["usd_settled_per_1000_pages"] = 1000 * sum(c["settled_usd"] for c in costs.values()) / p["pages"]
    return {"figures": fig, "by_box": {r["name"]: O.figures(r) for r in per}, "cost_by_box": costs,
            "failed_windows": failed, "unflagged_gaps": wrong}


def spend():
    with arm(OWN) as (_, _, S, _):
        SB.check_reservations(S)
        import gateway_gemini as GW
        calls = S.settled()
        return {"calls": len(calls), "spent_usd": S.spent(), "billed": S.settled_billed(),
                "billed_note": GW.billed_note(calls, "estimate"),
                "retained_usd": S.spent() - sum(r["charge"] for r in calls),
                "invalid": sum(not r.get("valid") for r in calls),
                "retries": sum(r["event"] == "retry-approved" for r in S.effective_records()),
                "input_tokens": sum(r["usage"].get("prompt_tokens", 0) for r in calls),
                "output_tokens": sum(r["usage"].get("completion_tokens", 0) for r in calls)}


def cmd_score(_a):
    import rescore
    rescore.no_network()
    cols = [data.load(b, with_exif=False) for b in TEST]
    missing = [(c.name, a, z) for o in OFFSETS for c in cols for a, z in spans(c, o) if answer(c, a, z) is None]
    if missing:
        raise SystemExit(f"{len(missing)} windows have no answer, first {missing[:3]}")
    opts = json.loads((RESULTS / "options.json").read_text())
    k = next(i for i, x in enumerate(opts["approaches"]) if x["id"] == "gemini")
    row = opts["approaches"][k]
    if (row["rule"], row["level"]) != (RULE, LEVEL):
        raise SystemExit(f"options.json's Gemini row is at {row['rule']} {row['level']}, not {RULE} {LEVEL}")
    rows = {f"o{o}": offset_row(o) for o in OFFSETS}
    o0 = rows["o0"]["figures"]
    app = row["figures"]["test"]
    for key in ("pages_exact_no_review", "flagged_per_100_pages", "pages_exact_after_review", "unflagged_errors"):
        if abs(o0[key] - app[key]) > 1e-9:
            raise SystemExit(f"offset 0 {key} {o0[key]} is not options.json's {app[key]}")
    rng = {key: [min(r["figures"][key] for r in rows.values()), max(r["figures"][key] for r in rows.values())]
           for key in KEYS}
    g1 = json.loads((RESULTS / "seg-boxes-score.json").read_text())["offsets"]["rows"]
    g1_exact = [r["figures"]["pages_exact_no_review"] for r in g1.values()]
    spread = {"g2": 100 * (rng["pages_exact_no_review"][1] - rng["pages_exact_no_review"][0]),
              "g1": 100 * (max(g1_exact) - min(g1_exact))}
    claude = next(x for x in opts["approaches"] if x["id"] == "claude")["figures"]["test"]["pages_exact_no_review"]
    out = {"tag": TAG, "date": dt.date.today().isoformat(), "rule": RULE, "level": LEVEL, "rows": rows,
           "range": rng, "spread_points": spread, "claude_o0": claude, "gateway": spend()}
    (RESULTS / "seg-g2-offsets.json").write_text(json.dumps(out, indent=1) + "\n")
    (RESULTS / "seg-g2-offsets.md").write_text(render(out))
    row["offsets"] = {"item": TAG, "result": "segbench-results/seg-g2-offsets.md", "offsets": list(OFFSETS),
                      "range": {key: rng[key] for key in KEYS if key != "usd_per_1000_pages"}}
    (RESULTS / "options.json").write_text(json.dumps(opts, indent=1) + "\n")
    import options as O
    O.render(opts)
    print(json.dumps({"range": rng, "spread_points": spread, "gateway": out["gateway"]}, indent=1))


def _p(x, d=1):
    return "—" if x is None else f"{100 * x:.{d}f}%"


def render(out) -> str:
    import ensemble as E
    import seg_card
    rows, rng, gw, sp = out["rows"], out["range"], out["gateway"], out["spread_points"]
    fmt = {"pages_exact_no_review": ("pages in an exact document, no checking", _p),
           "flagged_per_100_pages": ("boundaries to check per 100 pages", lambda x: f"{x:.1f}"),
           "pages_exact_after_review": ("pages right after checking", _p),
           "unflagged_errors_per_500_pages": ("unflagged errors per 500 pages", lambda x: f"{x:.1f}"),
           "usd_per_1000_pages": ("charged $ per 1,000 pages, all attempts", lambda x: f"${x:.2f}")}
    L = ["# W46.seg-g2-offsets — the app's Gemini voter on prompt g2 at three window offsets (Stanton and RG165)", "",
         "Generated by `ArchiveProcessor/scripts/segbench/seg_g2_offsets.py score` from the gateway caches; no call is "
         "made in scoring.", "",
         "Gemini 3.7 Flash through the Stanford gateway on prompt g2 (the article-within-issue rule), 1600 px images "
         "with Apple Vision text, temperature 0, reasoning low; seven-page windows at stride 3 starting 0, 1 and 2 "
         "pages later, as W46.seg-boxes-score ran g1. Offset 0 is W46.seg-magazine-rule-redo's run (the figures the "
         "app shows, seg-magazine-rule-app.md); offsets 1 and 2 are this item's. Each offset is scored alone at the "
         f"app's rule and level ({out['rule']}, {E.lv(out['level'])}); nothing refit or chosen on these boxes. The "
         "app's voter is Gemini 3.8 Flash; every figure here is 3.7's, labelled so (owner, 2026-11-10: no 3.8 run on "
         "the personal key). No ABBYY text.", "",
         "## The five figures at each offset", "",
         "| figure | offset 0 (shown) | offset 1 | offset 2 | range |", "|---|---:|---:|---:|---:|"]
    for key, (label, f) in fmt.items():
        L.append(f"| {label} | " + " | ".join(f(rows[f'o{o}']['figures'][key]) for o in OFFSETS)
                 + f" | {f(rng[key][0])}–{f(rng[key][1])} |")
    L += ["", "By box:", "", "| offset | box | no checking | to check per 100 pages | after checking | "
          "unflagged errors |", "|---|---|---:|---:|---:|---:|"]
    for o in OFFSETS:
        for b, r in rows[f"o{o}"]["by_box"].items():
            L.append(f"| o{o} | {b} | {_p(r['pages_exact_no_review'])} | {r['flagged_per_100_pages']:.1f} | "
                     f"{_p(r['pages_exact_after_review'])} | {r['unflagged_errors']} |")
    uw = [f"o{o} {b} {x['gap']} (said {x['said']}, {x['confidence']:.3f})" for o in OFFSETS
          for b, xs in rows[f"o{o}"]["unflagged_gaps"].items() for x in xs]
    fw = sum(r["failed_windows"] for r in rows.values())
    L += ["", "Unflagged errors: " + (", ".join(uw) if uw else "none at any offset") + f". Failed windows: {fw}.", "",
          "## Reading", "",
          f"Over three offsets g2 on Gemini 3.7 scores {_p(rng['pages_exact_no_review'][0])}–"
          f"{_p(rng['pages_exact_no_review'][1])} of pages in an exact document with no checking, a spread of "
          f"{sp['g2']:.1f} points (g1 on the same model and level spread {sp['g1']:.1f}, seg-boxes-score.md), "
          f"{rng['flagged_per_100_pages'][0]:.1f}–{rng['flagged_per_100_pages'][1]:.1f} checks per 100 pages and "
          f"{_p(rng['pages_exact_after_review'][0])}–{_p(rng['pages_exact_after_review'][1])} after checking. "
          f"Against Claude only's {_p(out['claude_o0'])} (prompt w1, one offset-0 run, options.md) the low end is "
          f"{100 * (rng['pages_exact_no_review'][0] - out['claude_o0']):+.1f} points and offset 0 "
          f"{100 * (rows['o0']['figures']['pages_exact_no_review'] - out['claude_o0']):+.1f}. "
          "The pooled spread is narrow because the boxes move apart: Stanton "
          + "–".join(_p(f(rows[f"o{o}"]["by_box"]["Stanton"]["pages_exact_no_review"] for o in OFFSETS)) for f in (min, max))
          + ", RG165 "
          + "–".join(_p(f(rows[f"o{o}"]["by_box"]["RG165"]["pages_exact_no_review"] for o in OFFSETS)) for f in (min, max))
          + ", so a per-box figure is far less settled than the pooled one.", "",
          f"The settings layer's tie rule (07-segmentation.md §3) is now reading's construction: twice the larger "
          f"offset range of the two routes compared, a route with none held to the largest measured (g1's "
          f"{sp['g1']:.1f}), so {2 * round(max(sp['g1'], sp['g2']), 1):.1f} points for every pair the table holds. "
          f"Gemini's {100 * (rng['pages_exact_no_review'][0] - out['claude_o0']):.1f}-"
          f"{100 * (rng['pages_exact_no_review'][1] - out['claude_o0']):.1f} points over Claude is under it, a tie, "
          "so profile D5 (a Claude plan and a Gemini key) goes back to the plan route on money; on the 3.2 floor of "
          "one range it had passed by 0.1. Claude's w1 carries no article rule, so the gap is not like for like either "
          "way.", "",
          "## Gateway", "",
          f"{gw['calls']} settled calls, {gw['input_tokens']:,} input and {gw['output_tokens']:,} output tokens, "
          f"${gw['spent_usd']:.4f} counted of the ${CAP:.2f} cap ({gw['billed_note']}), {gw['invalid']} invalid. "
          "Offset 0's windows are W46.seg-magazine-rule-redo's, already counted there.", ""]
    L += seg_card.card(
        truth="The test boxes as options.md scores them: Stanton with the owner's 2026-10-31 newsletter rulings on the "
              "article rule, RG165; truth photo labels; no route drafted any of it.",
        selection="options.py's test boxes, fixed since 2026-10-11, whole; the offsets are W46.seg-boxes-score's. "
                  "Nothing chosen by a route's answers or ABBYY text.",
        comparison="One model, prompt, gateway, image size, Vision text, rule, level and scorer at every offset; only "
                   "where the windows start changes. Claude's figure beside it is prompt w1, which carries no article "
                   "rule, at offset 0 only (a like-for-like Claude arm waits on W46.gateway-models-ok).",
        noise=f"Three runs of one route, at temperature 0, that differ only in window placement: the offset spread is "
              f"{sp['g2']:.1f} points of pooled pages exact (g1: {sp['g1']:.1f}). Not a rerun at fixed windows, and "
              "no other route's offset spread is measured on g2's terms; error counts of a few gaps move by one or two "
              "within noise.",
        scope="Gemini 3.7, not the 3.8 the app sends; the two test boxes only (363 pages). It does not measure "
              "Claude's or any other route's offset range, nor a level refit on these boxes.")
    return "\n".join(L) + "\n"


if __name__ == "__main__":
    main()
