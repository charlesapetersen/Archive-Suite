#!/usr/bin/env python3
"""W46.seg-text-tier-app: the text-only Gemini window as the budget segmentation tier, with its own level.

  python3 seg_text_tier_app.py plan      # windows, cached answers and an allowance (no calls)
  python3 seg_text_tier_app.py collect   # text-only g2 windows on the development boxes through the gateway (paid)
  <lab venv>/bin/python seg_text_tier_app.py score   # the level, the test boxes once, options.json's `gemini-text`
                                         # row -> segbench-results/seg-text-tier-app.{json,md} (no calls)

W46.seg-text-tier-test scored the text-only window on the test boxes at the image arm's level and found it worth
offering (seg-text-tier-test.md), and said a tier that ships fits its own level first, as options.py fits every
approach's. This is that fit.

FIXED BEFORE ANY DEVELOPMENT ANSWER:
- The request: seg_text_tier_test's text arm unchanged (prompt g2, Gemini 3.7 Flash through the Stanford gateway,
  temperature 0, reasoning low, cached Apple Vision text, 7-page windows at stride 3, the images and their "Page n:"
  parts dropped and the image paragraph replaced), on the development boxes (Dean, Deaver, Herrnstein: 551 pages),
  in this item's own store and cap. The test boxes' text answers are W46.seg-text-tier-test's, read from its store
  (no new call).
- The level is fitted exactly as options.py fits it: ensemble.fit_level on the three development boxes, rule min,
  options.json's 98% bar after review; the held-out rows each use the level fitted on the other two (ensemble.loco).
- The test boxes are scored once at that level with options.py's five figures. Nothing is chosen on them.
- The options.json row `gemini-text`: voter window-gemini-3.8-flash-low-text (Gemini 3.8 Flash, the voter the app
  calls, as the Gemini row is), rule min, that level, these figures labelled as Gemini 3.7's, and tokens per 1,000
  pages from the text arm's own settled calls on all five boxes priced at Gemini 3.8's rates (the Gemini row's
  prices, introductory to 2026-12-31 and the later price after it).
Money: the gateway is real money on a Stanford PTA. W46.seg-text-tier-test spent $0.63 of the tier's work; CAP keeps
this item well under the $7 rule (filed at about $0.90). Owner images and text go only to the gateway and the
caches, never into git (the repo is public).
"""
from __future__ import annotations

import argparse
from collections import Counter
from contextlib import contextmanager
import concurrent.futures as cf
import datetime as dt
import fcntl
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import data  # noqa: E402
import seg_boxes_score as SB  # noqa: E402
import seg_text_tier_test as STT  # noqa: E402
import seg_window_gateway as SWG  # noqa: E402

TAG = "W46.seg-text-tier-app"
STORE = SB.REHEARSAL / "seg-text-tier-app-gateway"
CAP = 1.50
TEST_SPENT = 0.6297   # W46.seg-text-tier-test's counted gateway spend (seg-text-tier-test.md), part of this work
RESULTS = SB.RESULTS
DEV, TEST = tuple(data.DEV), tuple(data.TEST)
ARM = STT.ARM
ID = "gemini-text"
CODE = "G"
VOTER = "window-gemini-3.8-flash-low-text (Gemini 3.8 Flash, thinking low, text alone, prompt g2t)"
EVIDENCE = ("Gemini 3.7 Flash through the Stanford gateway, prompt g2 with the images dropped (W46.seg-text-tier-test "
            "and W46.seg-text-tier-app; the gateway does not serve 3.8)")


@contextmanager
def arm(name):
    """The text arm with the store that holds box `name`'s answers: this item's for a development box, the test
    item's for a test box."""
    with STT.text_arm() as mods:
        prev = SWG.STORE, SWG.ITEM_CAP_USD, SWG.TAG
        if name in DEV:
            SWG.STORE, SWG.ITEM_CAP_USD, SWG.TAG = STORE, CAP, TAG
        try:
            yield mods
        finally:
            SWG.STORE, SWG.ITEM_CAP_USD, SWG.TAG = prev


def jobs(boxes):
    with arm(DEV[0]) as (_, W, _, _):
        cols = [data.load(b, with_exif=False) for b in boxes]
        return [(c, a, b) for c in cols for a, b in W.windows(len(c.pages))]


def answered(col, a, b):
    with arm(col.name):
        return SWG.attempts(SWG.request(col, a, b, ARM)[1]) > 0


def cmd_plan(_a):
    js = jobs(DEV)
    with arm(DEV[0]):
        todo = [j for j in js if not STT.cached(*j)]
        allow = sum(SWG.allowance(SWG.request(c, a, b, ARM)[0]) for c, a, b in todo)
        spent = SWG.spent()
    test_missing = [j for j in jobs(TEST) if not answered(*j)]
    print(f"text-only g2 development windows {len(js)}, uncached {len(todo)}; allowance ${allow:.2f} at full output "
          f"caps; about ${0.0051 * len(todo):.2f} at the test item's $0.0051 a window; spent ${spent:.4f} of "
          f"${CAP:.2f}; with the test item ${TEST_SPENT + spent:.4f}; test-box text answers missing {len(test_missing)}")


def cmd_collect(a):
    js = jobs(DEV)
    STORE.mkdir(parents=True, exist_ok=True)
    with (STORE / "collect.lock").open("a") as lk, arm(DEV[0]):
        fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        SB.gateway_key()
        for rnd in (1, 2):            # the second round re-sends each failure once
            pending = [j for j in js if not STT.cached(*j)][: a.limit or None]
            print(f"round {rnd}: {len(pending)} windows to send, item ${SWG.spent():.4f} of ${CAP:.2f}", flush=True)
            res = Counter()
            with cf.ThreadPoolExecutor(SWG.CONCURRENCY) as ex:
                for out in ex.map(lambda j: SWG.call(ARM, *j), pending):
                    res[out] += 1
            print(f"round {rnd}: {dict(res)}, item ${SWG.spent():.4f}", flush=True)
            if res["skipped"]:
                print("cap reached: the rest are left unsent", flush=True)
                break


# --- scoring --------------------------------------------------------------------------------------

def box(name, failed):
    """seg_text_tier_test.build under this item's arm (its own text_arm would point a development box at the test
    item's store)."""
    import ensemble as E
    col = data.load(name, with_exif=False)
    with arm(name) as (_, W, _, M):
        comb = M.combine_units(col, W.windows(len(col.pages)), STT.text_answer(failed))
        pred = W.assemble(col, comb, True)
    b = E.Box(col, "")
    b.v = {"G": E._from_bounds(col, pred)}
    return b


def settled_usage(boxes):
    """The text arm's settled valid calls on `boxes`, one per window, from the two stores."""
    rows = []
    for b in boxes:
        col = data.load(b, with_exif=False)
        with arm(b) as (_, W, _, _):
            got = {r["request_sha256"]: r for r in SWG.latest().values()
                   if r["event"] == "settle" and r.get("valid") and r.get("usage")}
            for a, z in W.windows(len(col.pages)):
                k = SWG.request(col, a, z, ARM)[1]
                if k in got:
                    rows.append(got[k])
    return rows


def text_row(old_gemini, level, figs, dev_held, use, pages):
    """options.json's `gemini-text` row: the Gemini row's voter model and prices, this arm's level, figures and
    tokens."""
    g = old_gemini["cost"]["per_model"]["G"]
    pr = g["prices_usd_per_mtok"]
    tin = 1000 * use["input_tokens"] / pages
    tout = 1000 * use["output_tokens"] / pages
    lst = (tin * pr["in"] + tout * pr["out"]) / 1e6
    bat = (tin * pr["batch_in"] + tout * pr["batch_out"]) / 1e6
    after = [k for k in g if k.startswith("after_")]
    if len(after) != 1:
        raise SystemExit(f"the Gemini row's price change is not one after_ key: {after}")
    ratio = g[after[0]]["list_usd_per_1000_pages"] / g["list_usd_per_1000_pages"]
    cost = {"list_usd_per_1000_pages": lst, "batch_usd_per_1000_pages": bat, "prices_usd_per_mtok": pr,
            "price_read": g["price_read"], "price_source": g["price_source"],
            after[0]: {"list_usd_per_1000_pages": lst * ratio, "batch_usd_per_1000_pages": bat * ratio}}
    return {
        "id": ID, "label": "Gemini only, text alone (budget)", "available": True, "voters": [VOTER],
        "rule": "min", "level": level, "flag_rule": "flag a gap whose confidence is at or below the level",
        "figures": {**figs, "dev_held_out": dev_held},
        "tokens_per_1000_pages": {CODE: {
            "model": old_gemini["tokens_per_1000_pages"]["G"]["model"], "thinking": "low",
            "boxes": sorted(DEV + TEST), "pages": pages, "calls": use["calls"],
            "input_per_1000_pages": tin, "output_per_1000_pages": tout, "spent_usd": use["list_usd"],
            "how": "the usage the gateway returned on each window's settled call (Gemini 3.7 Flash, text alone, "
                   "prompt g2), priced at Gemini 3.8 Flash's rates"}},
        "cost": {"per_model": {CODE: cost},
                 "total": {"list_usd_per_1000_pages": lst, "batch_usd_per_1000_pages": bat}},
        "evidence": EVIDENCE,
        "figures_note": "These figures were measured on Gemini 3.7 Flash with the same text-only prompt; Gemini 3.8 "
                        "Flash, which this approach calls, has not been measured on it.",
        "note": "The page images are not sent: the window's OCR text alone, about half the Gemini only approach's "
                "price, for more boundaries to check (W46.seg-text-tier-test, seg-text-tier-app.md)."}


def cmd_score(_a):
    import rescore
    rescore.no_network()
    import ensemble as E
    import options as O
    missing = [(c.name, a, b) for c, a, b in jobs(DEV + TEST) if not answered(c, a, b)]
    if missing:
        raise SystemExit(f"{len(missing)} text windows never sent, first {missing[:3]}")
    opts = json.loads((RESULTS / "options.json").read_text())
    S, failed = ("G",), Counter()
    dev = {n: box(n, failed) for n in DEV}
    bar0 = E.BAR
    try:
        E.BAR = opts["bar_after_review"]
        with O.rule("min"):
            lo = E.loco(dev, S)
            level = E.fit_level(list(dev.values()), S)
            if level is None or not 0 < level < 1:
                raise SystemExit(f"no usable text-only level at the {E.BAR} bar: {level}")
            test = {n: box(n, failed) for n in TEST}
            per = [E.evaluate(test[n], S, level) | {"name": n} for n in TEST]
            wrong = {n: SB.unflagged_gaps(test[n], S, level) for n in TEST}
            gem = next(a for a in opts["approaches"] if a["id"] == "gemini")
            at_image = O.figures(E.pooled([E.evaluate(test[n], S, gem["level"]) | {"name": n} for n in TEST]))
    finally:
        E.BAR = bar0
    dev_held = O.figures(lo["pooled"])
    figs = {"test": O.figures(E.pooled(per)), "test_by_box": {r["name"]: O.figures(r) for r in per}}
    pages = sum(len(data.load(b, with_exif=False).pages) for b in DEV + TEST)
    use = STT.usage(settled_usage(DEV + TEST))
    with arm(DEV[0]):
        spent = SWG.spent()
    row = text_row(gem, level, figs, dev_held, use, pages)
    out = {"tag": TAG, "date": dt.date.today().isoformat(), "evidence": EVIDENCE, "rule": "min", "level": level,
           "image_level": gem["level"], "bar": opts["bar_after_review"], "dev_levels_held_out": lo["levels"],
           "dev_held_out": dev_held, "dev_by_box": {r["name"]: O.figures(r) for r in lo["rows"]},
           "dev_reached": lo["reached"], "test": figs, "test_at_image_level": at_image, "unflagged_gaps": wrong,
           "image": {"test": gem["figures"]["test"], "cost": gem["cost"]["total"]},
           "tokens": use, "pages": pages, "cost": row["cost"]["total"], "failed_windows": dict(failed),
           "spent_usd": spent, "cap_usd": CAP, "work_total_usd": TEST_SPENT + spent}
    (RESULTS / "seg-text-tier-app.json").write_text(json.dumps(out, indent=1) + "\n")
    (RESULTS / "seg-text-tier-app.md").write_text(render(out))
    k = next((i for i, a in enumerate(opts["approaches"]) if a["id"] == ID), None)
    if k is None:
        opts["approaches"].append(row)
    else:
        opts["approaches"][k] = row
    opts["gemini_text_measured"] = {"date": out["date"], "item": TAG, "level": level, "evidence": EVIDENCE,
                                    "result": "segbench-results/seg-text-tier-app.md"}
    (RESULTS / "options.json").write_text(json.dumps(opts, indent=1) + "\n")
    O.render(opts)
    print(json.dumps({k: out[k] for k in ("level", "dev_held_out", "test", "test_at_image_level", "unflagged_gaps",
                                          "cost", "failed_windows", "spent_usd")}, indent=1))


def _p(x):
    return "—" if x is None else f"{100 * x:.1f}%"


def _row(label, f, cost=None):
    return (f"| {label} | {_p(f['pages_exact_no_review'])} | {f['flagged_per_100_pages']:.1f} | "
            f"{_p(f['pages_exact_after_review'])} | {f['unflagged_errors']} | "
            + (f"${cost['list_usd_per_1000_pages']:.2f} / ${cost['batch_usd_per_1000_pages']:.2f}" if cost else "—")
            + " |")


def render(out) -> str:
    import ensemble as E
    import seg_card
    t, d, im = out["test"]["test"], out["dev_held_out"], out["image"]
    hdr = ["| | pages exact, no checking | checks per 100 pages | pages exact after checking | unflagged errors | "
           "API cost per 1,000 pages, list / batch |", "|---|---:|---:|---:|---:|---:|"]
    L = ["# The text-only Gemini window as the budget tier, at its own level (W46.seg-text-tier-app)", "",
         "Generated by `ArchiveProcessor/scripts/segbench/seg_text_tier_app.py score` from the gateway caches; no call "
         "is made in scoring.", "",
         "seg-text-tier-test.md scored the text-only window (prompt g2 with the images dropped, Gemini 3.7 Flash "
         "through the Stanford gateway) on the test boxes at the image arm's level and found a budget tier worth "
         "offering. Here it gets its own level, fitted on its own answers on the development boxes as options.py fits "
         "every approach's, and the test boxes are scored once at it. The app's `gemini-text` approach carries these "
         "figures, labelled as Gemini 3.7's.", "",
         f"## The level (rule min, {out['bar']:.0%} of pages right after checking)", "",
         f"Fitted on all three development boxes ({d['pages']} pages): **{E.lv(out['level'])}**, against "
         f"{E.lv(out['image_level'])} for the image window. Held out, each box at the level fitted on the other two: "
         + ", ".join(f"{n} {E.lv(v)}" for n, v in out["dev_levels_held_out"].items())
         + f"; {out['dev_reached']} of 3 boxes reach the bar.", ""]
    L += hdr + [_row("text alone, held out (pooled)", d)] + [_row(f"  {n}", r) for n, r in out["dev_by_box"].items()]
    L += ["", f"## The test boxes, Stanton + RG165 ({t['pages']} pages), scored once at its level", ""]
    L += hdr + [_row(f"text alone at {E.lv(out['level'])} (the tier's figures)", t, out["cost"])]
    L += [_row(f"  {n}", r) for n, r in out["test"]["test_by_box"].items()]
    L += [_row(f"text alone at the image level {E.lv(out['image_level'])} (seg-text-tier-test.md)",
               out["test_at_image_level"]),
          _row("images and text, the Gemini only approach (options.json)", im["test"], im["cost"])]
    uw = [f"{b} {x['gap']} (said {x['said']}, {x['confidence']:.3f})" for b, xs in out["unflagged_gaps"].items()
          for x in xs]
    tk = out["tokens"]
    L += ["", "Unflagged errors at its level: " + (", ".join(uw) if uw else "none") + ".", "",
          "## Tokens and cost", "",
          f"{tk['calls']} settled text-only calls on all five boxes ({out['pages']} pages photographed): "
          f"{tk['input_tokens']:,} input and {tk['output_tokens']:,} output tokens, priced at Gemini 3.8 Flash's "
          f"rates as the Gemini only row is: ${out['cost']['list_usd_per_1000_pages']:.2f} list, "
          f"${out['cost']['batch_usd_per_1000_pages']:.2f} batch per 1,000 pages, against "
          f"${im['cost']['list_usd_per_1000_pages']:.2f} / ${im['cost']['batch_usd_per_1000_pages']:.2f} with the "
          "images. Both double after 2026-12-31.", "",
          f"This item spent ${out['spent_usd']:.4f} on the gateway of its ${out['cap_usd']:.2f} cap; with "
          f"W46.seg-text-tier-test's ${TEST_SPENT:.4f} the tier's work totals ${out['work_total_usd']:.4f}, inside the "
          f"$7 rule. Failed windows {sum(out['failed_windows'].values())}.", "",
          "## Reading", "",
          f"- **What the tier saves is money; what it costs is checking.** At its own level the user checks "
          f"{t['flagged_per_100_pages']:.1f} boundaries per 100 pages against {im['test']['flagged_per_100_pages']:.1f} "
          "with images; the app shows both figures beside the price.", ""]
    L += seg_card.card(
        truth="The owner's development boxes (Dean, Deaver, Herrnstein) for the level and the ruled test boxes "
              "(Stanton with the owner's 2026-10-31 newsletter rulings, RG165), truth photo labels; no route drafted "
              "any of it.",
        selection="The boxes options.py fits and scores on, fixed since 2026-10-11; the level fitted before the test "
                  "boxes were scored at it; nothing chosen by a route's answers or ABBYY text.",
        comparison="One model (Gemini 3.7 Flash), one route, prompt g2, the same windows, Vision text, settings and "
                   "scorer as the image window; the text arm drops only the images and the one paragraph about them. "
                   "The test boxes' text answers are the ones seg-text-tier-test.md scored.",
        noise="One run, 914 pages. The rerun floor is 1.4-3.2 points of pages exact a box (seg-boxes-score.md), so a "
              "gap inside it is a tie; the error counts are a few gaps, so a difference of one or two is within noise.",
        scope="Gemini 3.7, not the 3.8 the app sends (the gateway does not serve 3.8). Five boxes of one owner's "
              "archives; not other material.")
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan")
    c = sub.add_parser("collect")
    c.add_argument("--limit", type=int, default=0)
    sub.add_parser("score")
    a = ap.parse_args()
    {"plan": cmd_plan, "collect": cmd_collect, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    main()
