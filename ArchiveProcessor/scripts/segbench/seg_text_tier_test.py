#!/usr/bin/env python3
"""W46.seg-text-tier-test: the text-only cloud window on the test boxes, a candidate budget tier.

  python3 seg_text_tier_test.py plan      # windows, cached answers and an allowance (no calls)
  python3 seg_text_tier_test.py collect   # Gemini 3.7 Flash text-only g2 windows through the gateway (paid, capped)
  <lab venv>/bin/python seg_text_tier_test.py score   # -> segbench-results/seg-text-tier-test.{json,md} (no calls)

seg-window-gateway.md found Gemini 3.7's text-only K = 7 window 2.7 points under its image window on the development
boxes (-9.5 to +1.6) for 46% of the image arm's cost, and said a test-box run was needed before such a tier ships.

FIXED BEFORE ANY ANSWER:
- The arm: the app's Gemini window request as W46.seg-magazine-rule-app measures it (prompt g2, Gemini 3.7 Flash
  through the Stanford gateway, temperature 0, reasoning low, cached Apple Vision text, method_window's 7-page windows
  at stride 3), with the images dropped exactly as seg_window_gateway's k7-t arm drops them: the images and their
  "Page n:" parts removed and g1's one paragraph about them replaced (g2 changes only rule 10, so the paragraph is
  the same). Every other word of the request is unchanged.
- The control: the g2 image answers on the same windows, W46.seg-magazine-rule-redo's (read from its store, no call).
- Boxes: the two test boxes, Stanton and RG165 (363 pages), scored once.
- The level: the frozen one, the Gemini only approach's rule min at <= 0.965 (seg-magazine-rule-app.json, fitted on
  the image answers on the development boxes). No level is fitted for text alone: that would need text-only g2
  answers on the development boxes, and the question is what the tier gives at the shipped level.
- Figures: options.py's five, for both arms; a paired bootstrap over the truth's documents for pages exact with no
  checking and after checking; and the API cost per 1,000 pages photographed from each arm's own measured tokens on
  these windows at list rates ($0.75 / $3.75 per million, the gateway has no batch route; batch is half).
- A reply that fails is re-sent once (seg_window_gateway.call); a window still failed votes 0.5 on its gaps and is
  counted in the report.
- THE CALL, fixed now: a budget tier is worth offering if, at the frozen level, the text arm's pages exact after
  checking falls by no more than the 3.2-point rerun floor, its unflagged errors stay within two of the control's,
  and it costs at most 60% of the image arm per 1,000 pages.
Money: the gateway is real money on a Stanford PTA; CAP keeps this item well under the $7 rule (filed at about
$1.30). Owner images and text go only to the gateway and the caches, never into git (the repo is public).
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
import seg_magazine_rule as MR  # noqa: E402
import seg_magazine_rule_app as APP  # noqa: E402
import seg_window_gateway as SWG  # noqa: E402

TAG = "W46.seg-text-tier-test"
STORE = SB.REHEARSAL / "seg-text-tier-test-gateway"
CAP = 1.50
RESULTS = SB.RESULTS
TEST = tuple(data.TEST)
ARM = "k7-t"
FLOOR = 3.2       # the top of the 1.4-3.2-point rerun floor in pages exact (seg-boxes-score.md)
PRICE = SWG.PRICE


@contextmanager
def text_arm():
    """seg_window_gateway's request and ledger under prompt g2, writing to this item's store and cap."""
    prev = SWG.STORE, SWG.ITEM_CAP_USD, SWG.TAG
    SWG.STORE, SWG.ITEM_CAP_USD, SWG.TAG = STORE, CAP, TAG
    try:
        with MR.arm("g2") as mods:
            yield mods
    finally:
        SWG.STORE, SWG.ITEM_CAP_USD, SWG.TAG = prev


def cols():
    return {b: data.load(b, with_exif=False) for b in TEST}


def jobs(cs):
    with text_arm() as (_, W, _, _):
        return [(c, a, b) for c in cs.values() for a, b in W.windows(len(c.pages))]


def cached(col, a, b):
    _, key, _ = SWG.request(col, a, b, ARM)
    h = SWG.reply(key)
    return bool(h and h["valid"])


def cmd_plan(_a):
    cs = cols()
    js = jobs(cs)
    with text_arm():
        todo = [j for j in js if not cached(*j)]
        allow = sum(SWG.allowance(SWG.request(c, a, b, ARM)[0]) for c, a, b in todo)
        # The image paragraph must be found in every g2 prompt (SWG.request raises otherwise).
        print(f"text-only g2 windows {len(js)}, uncached {len(todo)}; allowance ${allow:.2f} at full output caps; "
              f"about ${0.0048 * len(todo):.2f} at seg-window-gateway's k7-t $0.0048 a window; "
              f"spent ${SWG.spent():.4f} of ${CAP:.2f}")
    missing = [(c.name, a, b) for c, a, b in js if APP.answer(c, a, b) is None]
    print(f"g2 image control answers missing {len(missing)}")


def cmd_collect(a):
    cs = cols()
    js = jobs(cs)
    STORE.mkdir(parents=True, exist_ok=True)
    with (STORE / "collect.lock").open("a") as lk, text_arm():
        fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        SB.gateway_key()
        for rnd in (1, 2):            # the second round re-sends each failure once
            pending = [j for j in js if not cached(*j)][: a.limit or None]
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

def text_answer(failed):
    def judge(col, a, b, allow_call=False):
        body, key, nums = SWG.request(col, a, b, ARM)
        hit = SWG.reply(key)
        if hit and hit["valid"]:
            return SWG.parse(hit["raw"], nums, False)
        if SWG.attempts(key) == 0:
            return None
        failed[col.name] += 1
        return SWG.SM._seg()[1].neutral(nums)
    return judge


def build(col, judge):
    """ensemble.Box with voter G from one arm's answers, combined as seg_magazine_rule_app.g2_box does."""
    import ensemble as E
    with text_arm() as (_, W, _, M):
        comb = M.combine_units(col, W.windows(len(col.pages)), judge)
        pred = W.assemble(col, comb, True)
    box = E.Box(col, "")
    box.v = {"G": E._from_bounds(col, pred)}
    return box


def page_flags(box, S, level, r):
    """Per page (None for a label photo): whether its document is exact with no checking and after checking, built
    from the same decisions ensemble.evaluate scores, and checked against its counts."""
    import ensemble as E
    from score import doc_unsure, forgive
    j = E.judge(box, S, level)
    auto = {i: a for i, (a, _, _, _) in j.items()}
    rev = {i: (box.truth[i] if f else a) for i, (a, f, _, _) in j.items()}
    out = []
    for dec, s in ((auto, r["auto"]), (rev, r["rev"])):
        pred = box.labels_from(dec)
        # An unsure gap takes the route's own call, as the scorer counts it (score.py, UNSURE GAPS).
        ex = SWG.exact_pages(forgive(list(box.labels), pred, doc_unsure(box.labels)), pred)
        if sum(bool(x) for x in ex) != s.pages_exact:
            raise SystemExit(f"{box.name}: per-page exact {sum(bool(x) for x in ex)} != scorer's {s.pages_exact}")
        out.append(ex)
    return out


def usage(rows):
    inp = sum(r["usage"]["prompt_tokens"] for r in rows)
    out = sum(r["usage"]["completion_tokens"] for r in rows)
    return {"calls": len(rows), "input_tokens": inp, "output_tokens": out,
            "list_usd": (inp * PRICE[0] + out * PRICE[1]) / 1e6}


def arm_usage(cs):
    """Each arm's own measured tokens on the test-box windows: one settled valid call per window."""
    text, image = [], []
    with text_arm() as (_, W, S, _):
        img = {r["request_sha256"]: r for r in S.effective_records()
               if r["event"] == "settle" and r.get("valid") and r.get("usage")}
        txt = {r["request_sha256"]: r for r in SWG.latest().values()
               if r["event"] == "settle" and r.get("valid") and r.get("usage")}
        for c in cs.values():
            for a, b in W.windows(len(c.pages)):
                _, k, _ = SWG.request(c, a, b, ARM)
                if k in txt:
                    text.append(txt[k])
                _, k, _ = S.request("gemini", c, a, b)
                if k in img:
                    image.append(img[k])
    return usage(text), usage(image)


def cmd_score(_a):
    import rescore
    rescore.no_network()
    import ensemble as E
    import options as O
    app = json.loads((RESULTS / "seg-magazine-rule-app.json").read_text())
    level, S = app["level"], ("G",)
    cs = cols()
    js = jobs(cs)
    with text_arm():
        missing = [(c.name, a, b) for c, a, b in js if SWG.attempts(SWG.request(c, a, b, ARM)[1]) == 0]
    if missing:
        raise SystemExit(f"{len(missing)} text windows never sent, first {missing[:3]}")
    failed = Counter()
    arms = {"image": APP.answer, "text": text_answer(failed)}
    out_arms, flags, docs, wrong = {}, {}, [], {}
    for name, judge in arms.items():
        per, auto, rev, off = [], [], [], 0
        for b, col in cs.items():
            box = build(col, judge)
            with O.rule("min"):
                r = E.evaluate(box, S, level) | {"name": b}
                wrong[f"{name} {b}"] = SB.unflagged_gaps(box, S, level)
                fa, fr = page_flags(box, S, level, r)
            per.append(r)
            auto += fa
            rev += fr
            if name == "image":
                docs += [[k + off for k in d] for d in SWG.documents(col)]
            off += len(col.labels)
        out_arms[name] = {"figures": O.figures(E.pooled(per)), "by_box": {r["name"]: O.figures(r) for r in per}}
        flags[name] = (auto, rev)
    paired = {k: SWG.bootstrap([bool(x) for x in flags["text"][n]], [bool(x) for x in flags["image"][n]], docs)
              for n, k in enumerate(("no_review", "after_review"))}
    gaps = changed_gaps(cs, arms, S, level)
    txt_use, img_use = arm_usage(cs)
    photographed = sum(len(c.pages) for c in cs.values())
    per1k = {k: {"list": 1000 * u["list_usd"] / photographed, "batch": 500 * u["list_usd"] / photographed}
             for k, u in (("text", txt_use), ("image", img_use))}
    with text_arm():
        spent = SWG.spent()
    out = {"tag": TAG, "date": dt.date.today().isoformat(), "level": level, "rule": "min", "boxes": list(TEST),
           "photographed_pages": photographed, "arms": out_arms, "paired": paired, "gaps_changed": gaps,
           "failed_windows": dict(failed), "unflagged_gaps": wrong,
           "tokens": {"text": txt_use, "image": img_use}, "per_1000_pages": per1k,
           "cost_ratio": txt_use["list_usd"] / img_use["list_usd"], "spent_usd": spent, "cap_usd": CAP}
    out["call"] = verdict(out)
    (RESULTS / "seg-text-tier-test.json").write_text(json.dumps(out, indent=1) + "\n")
    (RESULTS / "seg-text-tier-test.md").write_text(render(out))
    print(json.dumps({k: out[k] for k in ("arms", "paired", "gaps_changed", "per_1000_pages", "cost_ratio", "call",
                                          "failed_windows", "spent_usd")}, indent=1))


def changed_gaps(cs, arms, S, level):
    """The gaps where the text arm's automatic decision differs from the image arm's, with the truth (1-based photo
    pairs, as the reports write gaps)."""
    import ensemble as E
    out = []
    for b, col in cs.items():
        bx = {n: build(col, j) for n, j in arms.items()}
        js = {n: E.judge(x, S, level) for n, x in bx.items()}
        for i in bx["image"].gaps:
            (ai, fi, ci, _), (at, ft, ct, _) = js["image"][i], js["text"][i]
            if ai != at or fi != ft:
                out.append({"box": b, "gap": f"{i + 1}|{i + 2}", "truth": bx["image"].truth[i],
                            "image": [ai, round(ci, 4), fi], "text": [at, round(ct, 4), ft]})
    return out


def verdict(out):
    t, i = out["arms"]["text"]["figures"], out["arms"]["image"]["figures"]
    drop = 100 * (i["pages_exact_after_review"] - t["pages_exact_after_review"])
    errs = t["unflagged_errors"] - i["unflagged_errors"]
    ok = drop <= FLOOR and errs <= 2 and out["cost_ratio"] <= 0.60
    return {"after_review_drop_points": drop, "extra_unflagged_errors": errs, "cost_ratio": out["cost_ratio"],
            "offer": ok}


def _p(x):
    return f"{100 * x:.1f}%"


def _pt(d):
    return f"{100 * d['delta']:+.1f} ({100 * d['lo']:+.1f} to {100 * d['hi']:+.1f})"


def _row(label, f, cost=None):
    return (f"| {label} | {_p(f['pages_exact_no_review'])} | {f['flagged_per_100_pages']:.1f} | "
            f"{_p(f['pages_exact_after_review'])} | {f['unflagged_errors_per_500_pages']:.1f} "
            f"({f['unflagged_errors']}) | " + (f"${cost['list']:.2f} / ${cost['batch']:.2f}" if cost else "—") + " |")


def render(out) -> str:
    import ensemble as E
    import seg_card
    A, c, k, v = out["arms"], out["per_1000_pages"], out["tokens"], out["call"]
    hdr = ["| arm | pages in an exact document, no checking | boundaries to check per 100 pages | pages right after "
           "checking | unflagged errors per 500 pages (count) | API cost per 1,000 pages, list / batch |",
           "|---|---:|---:|---:|---:|---:|"]
    L = ["# The text-only cloud window on the test boxes (W46.seg-text-tier-test)", "",
         "Generated by `ArchiveProcessor/scripts/segbench/seg_text_tier_test.py score` from the gateway caches; no call "
         "is made in scoring.", "",
         "seg-window-gateway.md found Gemini 3.7 Flash's text-only K = 7 window 2.7 points under its image window on the "
         "development boxes (-9.5 to +1.6) for 46% of the image arm's cost, a lead for a cheaper tier that needed a "
         "test-box run before it ships. This is that run: the app's Gemini window request (prompt g2, Gemini 3.7 Flash "
         "through the Stanford gateway, temperature 0, reasoning low, cached Apple Vision text, 7-page windows at stride "
         "3) with the images dropped as seg-window-gateway's k7-t arm drops them, against the g2 image answers on the "
         "same windows (W46.seg-magazine-rule-redo's), on Stanton and RG165 "
         f"({out['photographed_pages']} pages), scored once at the frozen Gemini only level, rule min at "
         f"{E.lv(out['level'])} (fitted on the image answers on the development boxes).", "",
         "## The five figures (test boxes)", ""]
    L += hdr + [_row("Gemini only, images and text (the shipped approach)", A["image"]["figures"], c["image"]),
                _row("Gemini only, text alone (the candidate budget tier)", A["text"]["figures"], c["text"])]
    L += ["", "## By test box", "", "| arm | box | pages | no checking | to check per 100 pages | after checking | "
          "unflagged errors |", "|---|---|---:|---:|---:|---:|---:|"]
    for n, lab in (("image", "images and text"), ("text", "text alone")):
        for b, f in A[n]["by_box"].items():
            L.append(f"| {lab} | {b} | {f['pages']} | {_p(f['pages_exact_no_review'])} | "
                     f"{f['flagged_per_100_pages']:.1f} | {_p(f['pages_exact_after_review'])} | {f['unflagged_errors']} |")
    pr = out["paired"]
    L += ["", "## Text alone less images, paired over the truth's documents", "",
          f"In points of pages in an exact document, with a 95% paired bootstrap interval over the "
          f"{pr['no_review']['runs']} truth documents ({pr['no_review']['pages']} document pages): "
          f"**{_pt(pr['no_review'])}** with no checking, **{_pt(pr['after_review'])}** after checking.", ""]
    g = out["gaps_changed"]
    dec = [x for x in g if x["image"][0] != x["text"][0]]
    fl = Counter((x["image"][2], x["text"][2]) for x in g if x["image"][0] == x["text"][0])
    L += [f"Of the {A['image']['figures']['gaps']} gaps between two document pages, the arms take a different "
          f"automatic decision on {len(dec)}; on {fl[(False, True)]} more the text arm flags a gap the image arm "
          f"accepts, and on {fl[(True, False)]} the reverse (text alone is less sure: its confidences sit lower, so "
          "the image arm's level flags more of them).", ""]
    if dec:
        L += ["| box | gap | truth | images: said, confidence, flagged | text: said, confidence, flagged |",
              "|---|---|---|---|---|"]
        L += [f"| {x['box']} | {x['gap'].replace('|', chr(92) + '|')} | {x['truth']} | {x['image'][0]}, "
              f"{x['image'][1]:.3f}, {'yes' if x['image'][2] else 'no'} | {x['text'][0]}, {x['text'][1]:.3f}, "
              f"{'yes' if x['text'][2] else 'no'} |" for x in dec]
        L.append("")
    uw = [f"{arm} {x['gap']} (said {x['said']}, {x['confidence']:.3f})" for arm, xs in out["unflagged_gaps"].items()
          for x in xs]
    L += ["Unflagged errors at the frozen level: " + (", ".join(uw) if uw else "none") + ".", "",
          "## Tokens and cost", "",
          "Each arm's own measured tokens on the same 123 windows (one settled call a window; the gateway's usage "
          "figures), at list rates $0.75 / $3.75 per million input / output tokens; the gateway has no batch route, "
          "and batch is shown at half list as options.md does.", "",
          "| arm | calls | input tokens | output tokens | cost on these boxes | per 1,000 pages, list / batch |",
          "|---|---:|---:|---:|---:|---:|"]
    for n, lab in (("image", "images and text"), ("text", "text alone")):
        L.append(f"| {lab} | {k[n]['calls']} | {k[n]['input_tokens']:,} | {k[n]['output_tokens']:,} | "
                 f"${k[n]['list_usd']:.3f} | ${c[n]['list']:.2f} / ${c[n]['batch']:.2f} |")
    L += ["", f"Text alone costs {100 * out['cost_ratio']:.0f}% of the image arm. The figure options.md shows for "
          "Gemini only ($3.61 / $1.81) is Gemini 3.8 on g1 over all five boxes; 3.8 is at the same introductory list "
          "rates to 31 Dec 2026, and at its later $1.50 / $7.50 every Gemini figure here doubles.", "",
          f"This item spent ${out['spent_usd']:.4f} on the gateway (counted at the larger of the token estimate and "
          f"the gateway's figure) of its ${out['cap_usd']:.2f} cap; failed windows "
          f"{sum(out['failed_windows'].values())}.", "",
          "## The call", "",
          f"Fixed before any answer: offer the tier if, at the frozen level, pages right after checking fall by no "
          f"more than the {FLOOR}-point rerun floor, unflagged errors stay within two of the control's, and it costs "
          f"at most 60% of the image arm. Measured: after checking {-v['after_review_drop_points']:+.1f} points, "
          f"unflagged errors {v['extra_unflagged_errors']:+d}, cost {100 * v['cost_ratio']:.0f}%. "
          + ("**A budget tier is worth offering.**" if v["offer"] else "**No budget tier on this evidence.**"), "",
          "## Reading", "",
          f"- **What the tier saves is money; what it costs is checking.** At the shipped level text alone asks the user "
          f"to check {A['text']['figures']['flagged_per_100_pages']:.1f} boundaries per 100 pages against "
          f"{A['image']['figures']['flagged_per_100_pages']:.1f} with images, to save "
          f"${c['image']['list'] - c['text']['list']:.2f} per 1,000 pages at list. The call fixed beforehand did "
          "not weigh checks; a tier offered on it should show that figure beside the price.",
          f"- **Its one unflagged error is a gap other routes miss too.** Text alone accepts Stanton 144|145 as a "
          "continuation; Claude only and GLM-5.3 Flash only leave the same gap unflagged with images (options.md).",
          "- **The level is the image arm's.** Text alone is less sure of the same decisions, so a level fitted on its "
          "own development answers would differ (fewer checks, or more errors). Shipping the tier would fit one "
          "first, as options.py fits every approach's.", ""]
    L += seg_card.card(
        truth="The owner's ruled test boxes, Stanton (with the owner's 2026-10-31 newsletter rulings on the article "
              "rule) and RG165, truth photo labels; no unsure gaps, and no route drafted any of it.",
        selection="The two locked test boxes options.py scores on, whole, fixed since 2026-10-11; the level was frozen "
                  "on the development boxes before this run; no ABBYY text.",
        comparison="One model (Gemini 3.7 Flash), one route, prompt g2, the same windows, Vision text, settings and "
                   "scorer; the text arm drops only the images and the one paragraph about them. The level is the "
                   "image arm's, not refit for text alone.",
        noise="One run per arm, 363 pages. Paired bootstrap intervals over truth documents cover document sampling, "
              "not rerun variation; the rerun floor is 1.4-3.2 points of pages exact a box (SEG-10), so a gap inside "
              "it is a tie. The error counts are a few gaps, so a difference of one or two is within noise.",
        scope="Gemini 3.7, not the 3.8 the app sends (the gateway does not serve 3.8). Two boxes of one archive; not "
              "a level fitted for text alone, and not other material. Whether the app offers the tier is a product "
              "call on these figures.")
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
