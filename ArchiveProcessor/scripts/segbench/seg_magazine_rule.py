#!/usr/bin/env python3
"""W46.seg-magazine-rule-redo: the Gemini window prompt on the article-within-issue rule (g2) against the full-magazine
rule it replaces (g1), on the boxes where the rule decides gaps.

  python3 seg_magazine_rule.py plan      # windows, cached answers and the gateway estimate (no calls)
  python3 seg_magazine_rule.py collect   # Gemini 3.7 Flash g2 windows through the gateway (paid, capped)
  python3 seg_magazine_rule.py retry-once   # one retry of a request the Mac's sleep cut off (allowance kept)
  <lab venv>/bin/python seg_magazine_rule.py score   # -> segbench-results/seg-magazine-rule.{json,md} (no calls)

THE ARMS, fixed before any g2 answer:
- Prompt g2 is method_gemini's g1 with rule 10 replaced by the article-within-issue rule (method_gemini.RULE10_G2);
  nothing else in the prompt or request changes. g1's answers are W46.seg-boxes-score's, from its gateway store
  (no new g1 call): the same model (Gemini 3.7 Flash, the Stanford gateway), images, Vision text, temperature 0,
  reasoning low and seg_lincoln_gateway's request, ledger, cap check and parser, with this item's own store and cap.
- Boxes: the Illustrated Review (147 photos, the owner's article-within-issue rulings; trained-on for the students,
  which do not enter here) and the two test boxes, Stanton and RG165 (363 pages; Stanton holds the newsletter issue
  re-ruled on the new rule, photos 101-105), in method_window's 7-page windows at stride 3 (the offsets section's
  offset 0). No other box holds a magazine issue (W46.seg-truth-sheet's screen), so g2 is not run on them.
- Scoring: on the Illustrated Review seg_boxes_score.box_record's known gaps and kit_gate.documents' pages exact; on
  the test boxes options.py's five figures at the frozen Gemini rule and level (options-frozen.json, fitted for 3.8
  on g1), as the offsets section scores them; on both, paired gap decisions with an exact sign test.
- THE CALL, fixed now: g2 replaces g1 as the bench's Gemini prompt if the Illustrated Review gap accuracy rises with
  sign-test p < 0.05 and the test boxes' pages exact, before and after checking, fall by no more than the 3.2-point
  rerun floor. The app's voters run Gemini 3.8 and ChatGPT, which the gateway does not serve; this item does not
  change WindowPrompts.swift (its fixture test needs the shipped model's g2 answers).
Money: the gateway is real money on a Stanford PTA; CAP keeps this item under the $7 rule. Owner images and text go
only to the gateway and the caches, never into git (the repo is public).
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import data  # noqa: E402
import seg_boxes_score as SB  # noqa: E402

TAG = "W46.seg-magazine-rule-redo"
STORE = SB.REHEARSAL / "seg-magazine-rule-gateway"
CAP = 2.50
RESULTS = SB.RESULTS
REVIEW = "IllustratedReview"
TEST = ("Stanton", "RG165")
VERSIONS = ("g1", "g2")
STORES = {"g1": (SB.STORE, SB.CAP), "g2": (STORE, CAP)}
# The Stanton newsletter issue's gaps re-ruled on the article rule (seg-truth-rescore.md), as 1-based photo pairs.
NEWSLETTER = ((101, 102), (102, 103), (103, 104), (104, 105))
FLOOR = 3.2   # the top of the 1.4-3.2-point rerun floor in pages exact (seg-boxes-score.md)


@contextmanager
def arm(v):
    """The gateway module set to prompt v and its store; the previous prompt and store restored after, so arms nest."""
    G0, S0 = sys.modules.get("method_gemini"), sys.modules.get("seg_lincoln_gateway")
    prev = (G0.PROMPT, S0.STORE, S0.CAP) if G0 and S0 else None
    L, W, S, M = SB._mods()
    import method_gemini as G
    prev = prev or (G.PROMPT, SB.STORE, SB.CAP)
    G.PROMPT = G.PROMPTS[v]
    S.STORE, S.CAP = STORES[v]
    try:
        yield L, W, S, M
    finally:
        G.PROMPT, S.STORE, S.CAP = prev


def answer(v, col, a, b):
    """SB.gemini_answer under prompt v: the parsed reply, the neutral vote for an invalid model reply, or None."""
    with arm(v) as (L, _, S, _):
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


def jobs():
    with arm("g2") as (_, W, _, _):
        cols = [data.load(b, with_exif=False) for b in (REVIEW, *TEST)]
        return [(c, a, b) for c in cols for a, b in W.windows(len(c.pages))]


def cmd_plan(_a):
    js = jobs()
    with arm("g2") as (_, _, S, _):
        spent = S.spent()
    todo = [j for j in js if answer("g2", *j) is None]
    g1_missing = [j for j in js if answer("g1", *j) is None]
    print(f"g2 windows {len(js)}, uncached {len(todo)}, spent ${spent:.4f} of ${CAP:.2f}; "
          f"about ${0.0097 * len(todo):.2f} to go at W46.seg-boxes-score's $0.0097 a window; "
          f"g1 answers missing {len(g1_missing)}")


def cmd_collect(a):
    if a.workers != 1:
        raise SystemExit("collect requires --workers 1 to keep the item spending cap exact")
    js = jobs()
    STORE.mkdir(parents=True, exist_ok=True)
    with (STORE / "collect.lock").open("a") as fh, arm("g2") as (_, _, S, _):
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        SB.check_reservations(S)
        SB.check_prior_failures(S)
        todo = [j for j in js if answer("g2", *j) is None][: a.limit or None]
        SB.gateway_key()
        print(f"{len(todo)} windows to send, item spent ${S.spent():.4f} of ${CAP:.2f}", flush=True)
        invalid = []
        for col, lo, hi in todo:
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
        print(f"done; item spent ${S.spent():.4f}; invalid replies {len(invalid)}", flush=True)
        for x in invalid:
            print("  invalid", x)


def cmd_retry_once(_a):
    """seg_lincoln_gateway's explicit single retry for a request whose transport ended without usage (the Mac slept
    mid-request): at most once per request, only after its timeout, the original allowance kept in the item's spend."""
    STORE.mkdir(parents=True, exist_ok=True)
    with (STORE / "collect.lock").open("a") as fh, arm("g2") as (_, _, S, _):
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        S.retry_unsettled_once()
        print(f"retry approved; item spent ${S.spent():.4f} of ${CAP:.2f}")


# --- scoring --------------------------------------------------------------------------------------

def judges():
    return {v: (lambda c, a, b, allow_call=False, v=v: answer(v, c, a, b)) for v in VERSIONS}


def review_box(js):
    import kit_gate as K
    import kit_gate_sherlock as KS
    col = data.load(REVIEW, with_exif=False)
    rec = SB.box_record(col, js)
    docs = K.documents(rec)
    pages = sum(d["exact_pages"] for d in docs)
    rows = {}
    for v, m in rec["models"].items():
        calls = [(m["gaps"][k][0], g["truth"]) for k, g in enumerate(rec["gaps"])]
        rows[v] = {"known gaps": len(calls), "right": sum(c == t for c, t in calls),
                   "gap accuracy": sum(c == t for c, t in calls) / len(calls),
                   "false splits": sum(c == "new" and t == "continue" for c, t in calls),
                   "false merges": sum(c == "continue" and t == "new" for c, t in calls),
                   "pages exact": sum(d["exact_pages"] for d in docs if d["m"][v][0]) / pages,
                   "resolved pages": pages, "failed windows": rec["failed_windows"][v]}
    paired = KS.paired_row("g2 vs g1", REVIEW, [
        (rec["models"]["g2"]["gaps"][k][0] == g["truth"], rec["models"]["g1"]["gaps"][k][0] == g["truth"])
        for k, g in enumerate(rec["gaps"])])
    return rows, paired


def test_boxes(js):
    """options.py's five figures per prompt on Stanton + RG165 at the frozen Gemini rule and level."""
    import ensemble as E
    import kit_gate_sherlock as KS
    import options as O
    fz = json.loads((RESULTS / "options-frozen.json").read_text())["approaches"]["gemini"]
    out, rights, newsletter = {}, [], {}
    boxes = {v: {} for v in VERSIONS}
    for v in VERSIONS:
        per, wrong = [], {}
        with arm(v) as (_, W, S, M):
            for b in TEST:
                col = data.load(b, with_exif=False)
                spans = W.windows(len(col.pages))
                comb = M.combine_units(col, spans, js[v])
                box = E.Box(col, "")
                box.v = {"G": E._from_bounds(col, W.assemble(col, comb, True))}
                boxes[v][b] = box
                with O.rule(fz["rule"]):
                    per.append(E.evaluate(box, tuple(fz["voters"]), fz["level"]) | {"name": b})
                    wrong[b] = SB.unflagged_gaps(box, tuple(fz["voters"]), fz["level"])
                    if b == "Stanton":
                        j = E.judge(box, tuple(fz["voters"]), fz["level"])
                        newsletter[v] = [{"gap": f"{x}|{y}", "truth": box.truth.get(x - 1),
                                          "said": box.v["G"][x - 1][0], "confidence": round(box.v["G"][x - 1][1], 4),
                                          "flagged": j[x - 1][1]} for x, y in NEWSLETTER]
        out[v] = {"figures": O.figures(E.pooled(per)), "by_box": {r["name"]: O.figures(r) for r in per},
                  "unflagged_gaps": wrong}
    for b in TEST:
        g1, g2 = boxes["g1"][b], boxes["g2"][b]
        rights += [(g2.v["G"][i][0] == g2.truth[i], g1.v["G"][i][0] == g1.truth[i])
                   for i in g2.gaps if i not in g2.unsure]
    changed = [{"box": b, "gap": f"{i + 1}|{i + 2}", "truth": boxes["g2"][b].truth[i],
                "g1": boxes["g1"][b].v["G"][i][0], "g2": boxes["g2"][b].v["G"][i][0]}
               for b in TEST for i in boxes["g2"][b].gaps
               if boxes["g1"][b].v["G"][i][0] != boxes["g2"][b].v["G"][i][0]]
    return {"rule": fz["rule"], "level": fz["level"], "prompts": out, "newsletter_gaps": newsletter,
            "paired": KS.paired_row("g2 vs g1", "+".join(TEST), rights), "changed_gaps": changed}


def g2_cost(pages):
    with arm("g2") as (_, _, S, _):
        SB.check_reservations(S)
        calls = S.settled()
        return {"calls": len(calls), "spent_usd": S.spent(), "billed_usd": S.settled_billed(),
                "invalid": sum(not r.get("valid") for r in calls),
                "input_tokens": sum(r["usage"].get("prompt_tokens", 0) for r in calls),
                "output_tokens": sum(r["usage"].get("completion_tokens", 0) for r in calls),
                "usd_per_1000_pages": 1000 * S.spent() / pages}


def verdict(rev, paired_rev, test):
    f1, f2 = test["prompts"]["g1"]["figures"], test["prompts"]["g2"]["figures"]
    up = rev["g2"]["gap accuracy"] > rev["g1"]["gap accuracy"] and paired_rev["sign test p"] < 0.05
    held = all(100 * (f1[k] - f2[k]) <= FLOOR for k in ("pages_exact_no_review", "pages_exact_after_review"))
    return {"review_better": up, "test_held": held, "adopt_g2": up and held}


def cmd_score(_a):
    import rescore
    rescore.no_network()
    js = judges()
    missing = [(c.name, a, b, v) for c, a, b in jobs() for v in VERSIONS if answer(v, c, a, b) is None]
    if missing:
        raise SystemExit(f"{len(missing)} windows have no answer, first {missing[:3]}")
    rev, paired_rev = review_box(js)
    test = test_boxes(js)
    pages = sum(len(data.load(b, with_exif=False).pages) for b in (REVIEW, *TEST))
    out = {"tag": TAG, "review": rev, "review_paired": paired_rev, "test": test, "gateway_g2": g2_cost(pages),
           "verdict": verdict(rev, paired_rev, test), "floor_points": FLOOR}
    (RESULTS / "seg-magazine-rule.json").write_text(json.dumps(out, indent=1) + "\n")
    (RESULTS / "seg-magazine-rule.md").write_text(render(out))
    print(json.dumps({"review": rev, "test": {v: test["prompts"][v]["figures"] for v in VERSIONS},
                      "verdict": out["verdict"]}, indent=1))


# --- the report -----------------------------------------------------------------------------------

def _p(x, d=1):
    return "—" if x is None else f"{100 * x:.{d}f}%"


def render(out) -> str:
    rev, pr, t, gw, vd = out["review"], out["review_paired"], out["test"], out["gateway_g2"], out["verdict"]
    f = {v: t["prompts"][v]["figures"] for v in VERSIONS}
    tp = t["paired"]
    L = ["# The Gemini window prompt on the article-within-issue rule (W46.seg-magazine-rule-redo)", "",
         "Generated by `ArchiveProcessor/scripts/segbench/seg_magazine_rule.py score` from the gateway caches; "
         "no call is made in scoring.", "",
         "Owner, 2026-10-29: an article inside an issue is its own document and takes the issue's date and title "
         "from its cover or contents page; the full-magazine rule of 2026-10-05 is only the fallback where "
         "splitting by article is too difficult. 2026-10-30: an advertisement photographed between an article's "
         "pages goes with that article. Prompt g2 is g1 with rule 10 rewritten to say this "
         "(`method_gemini.RULE10_G2`); nothing else changes. Gemini 3.7 Flash through the Stanford gateway, both "
         "prompts; g1's answers are W46.seg-boxes-score's.", "",
         "## Stanford Illustrated Review (the owner's article rulings)", "",
         "| Prompt | Known gaps | Right | Gap accuracy | False merges | False splits | Pages exact | Failed windows |",
         "|---|---|---|---|---|---|---|---|"]
    for v in VERSIONS:
        r = rev[v]
        L.append(f"| {v} | {r['known gaps']} | {r['right']} | {_p(r['gap accuracy'])} | {r['false merges']} | "
                 f"{r['false splits']} | {_p(r['pages exact'])} | {r['failed windows']} |")
    L += ["", f"Paired on the same {pr['gaps']} gaps: only g2 right {pr['only first right']}, only g1 right "
          f"{pr['only second right']}, {pr['difference points']:+.1f} points, exact sign test p "
          f"{pr['sign test p']:.3g}.", "",
          f"## Test boxes, Stanton + RG165, at the frozen Gemini rule and level ({t['rule']}, {t['level']})", "",
          "| Prompt | Pages exact, no checking | Checks per 100 pages | Pages exact after checking | "
          "Unflagged errors | per 500 pages |", "|---|---|---|---|---|---|"]
    for v in VERSIONS:
        x = f[v]
        L.append(f"| {v} | {_p(x['pages_exact_no_review'])} | {x['flagged_per_100_pages']:.1f} | "
                 f"{_p(x['pages_exact_after_review'])} | {x['unflagged_errors']} | "
                 f"{x['unflagged_errors_per_500_pages']:.1f} |")
    L += ["", "By box:", ""]
    for v in VERSIONS:
        for b, x in t["prompts"][v]["by_box"].items():
            L.append(f"- {v} {b}: pages exact {_p(x['pages_exact_no_review'])} no checking, "
                     f"{x['flagged_per_100_pages']:.1f} checks per 100 pages, {_p(x['pages_exact_after_review'])} "
                     f"after, unflagged {x['unflagged_errors']}")
    L += ["", "Unflagged errors:", ""]
    for v in VERSIONS:
        gaps = [f"{b} {g['gap']} (said {g['said']}, {g['confidence']:.3f})"
                for b, gs in t["prompts"][v]["unflagged_gaps"].items() for g in gs]
        L.append(f"- {v}: {', '.join(gaps) or 'none'}")
    L += ["", "The Stanton newsletter issue (photos 101-105, re-ruled on the article rule):", "",
          "| Gap | Truth | g1 | g2 |", "|---|---|---|---|"]
    for a, b in zip(t["newsletter_gaps"]["g1"], t["newsletter_gaps"]["g2"]):
        cell = lambda g: f"{g['said']} {g['confidence']:.3f}{' (flagged)' if g['flagged'] else ''}"  # noqa: E731
        L.append(f"| {a['gap']} | {a['truth']} | {cell(a)} | {cell(b)} |")
    L += ["", f"Paired raw decisions on the same {tp['gaps']} known gaps: only g2 right {tp['only first right']}, "
          f"only g1 right {tp['only second right']}, sign test p {tp['sign test p']:.3g}. Gaps whose decision "
          f"changed: {len(t['changed_gaps'])}"
          + (": " + ", ".join(f"{c['box']} {c['gap']} {c['g1']}→{c['g2']} (truth {c['truth']})"
                              for c in t["changed_gaps"]) if t["changed_gaps"] else "") + ".", "",
          "## The call", "",
          f"Fixed before the g2 answers: g2 replaces g1 as the bench's Gemini prompt if the Illustrated Review gap "
          f"accuracy rises with p < 0.05 and the test boxes' pages exact, before and after checking, fall by no "
          f"more than {out['floor_points']} points. Illustrated Review better: "
          f"{'yes' if vd['review_better'] else 'no'}; test boxes held: {'yes' if vd['test_held'] else 'no'}; "
          f"**{'g2 adopted' if vd['adopt_g2'] else 'g1 kept'}**.", "",
          "## Gateway", "",
          f"g2: {gw['calls']} settled calls, ${gw['spent_usd']:.4f} counted of the ${CAP:.2f} cap (gateway billed "
          f"${gw['billed_usd']:.4f}), {gw['invalid']} invalid, {gw['input_tokens']:,} input and "
          f"{gw['output_tokens']:,} output tokens, ${gw['usd_per_1000_pages']:.2f} per 1,000 pages.", "",
          "## Measurement card", "",
          "- **Truth.** The Illustrated Review: the owner's blind rulings on the article-within-issue rule "
          "(W46.seg-boxes-sir-article, locked), one issue on the fallback. Stanton: the owner re-ruled its newsletter "
          "issue's four gaps (W46.seg-truth-rescore); RG165 and the rest of Stanton are the 2026-10-05 truth, which "
          "the rule does not touch. No tested route drafted any of it.",
          "- **Selection.** The boxes holding magazine issues (W46.seg-truth-sheet's screen found none outside "
          "Stanton and the Illustrated Review), with RG165 as the test boxes' other half; chosen by box, never by a "
          "route's answers or ABBYY text.",
          "- **Comparison.** One model, gateway, images, Vision text, windows, settings and scorer; only rule 10 "
          "differs. The test boxes are scored at the level fitted for 3.8 on g1, as the offsets section does.",
          f"- **Noise.** Single runs. The 1.4-{out['floor_points']}-point rerun floor is in pages exact "
          "(seg-boxes-score.md); a pages-exact gap inside it is a tie. Gap decisions are paired, with an exact "
          "sign test on the discordant gaps.",
          "- **Scope.** Gemini 3.7 on the gateway, not the app's 3.8 voter (the gateway does not serve 3.8) and not "
          "the ChatGPT voter's c1 (plan routes wait for the gateway). WindowPrompts.swift is unchanged: its engine "
          "fixture test replays the shipped model's answers to the shipped prompt. The whole-folder prompt wh2 is "
          "written, not run. The Illustrated Review is one magazine and one alumni-magazine layout.", ""]
    return "\n".join(L)


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
