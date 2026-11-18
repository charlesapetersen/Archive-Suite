#!/usr/bin/env python3
"""W46.seg-truth-audit (part 2): the segmentation tie as paired comparisons at fixed windows.

The settings solver called two segmentation routes tied when their pooled test-box pages exact differed by less than
twice the larger of their window-offset ranges, a route with none borrowing g1's 2.5 points (5.0 or 10.4 points;
07-segmentation.md §3). The owner's review of 2026-11-17 replaced that floor: compare the two routes on the same
windows (offset 0, the cached answers every figure is), page by page, and resample the truth's documents. Two routes
tie when the paired 95% interval of their difference holds 0, as gap accuracy already decides
(seg-boxes-score.md §Paired differences).

For every route in the settings table with a `test-boxes` figure this rebuilds the per-page "in its exact document"
flags from cached answers at the route's own frozen rule and level, checks the count against the table's figure, and
bootstraps every pair over the 325 common-support document pages (the documents touching no unknown gap).

    python3 ops/autonomous/heavy-run.py run -- python3 seg_pair_ties.py   # -> segbench-results/seg-pair-ties.{json,md}

No model call, upload or key: `rescore.no_network()` refuses any.
"""
from __future__ import annotations

import datetime as dt
import itertools
import json
from collections import Counter

import data
import rescore

TAG = "W46.seg-truth-audit"
RESULTS = data.HERE.parent.parent / "segbench-results"
OUT_JSON = RESULTS / "seg-pair-ties.json"
ROUNDS, SEED = 10000, 46
# settings table id -> how its test-box figure is made (options.json approach, the gateway offset 0, or a rescore row)
OPTIONS = {"gemini3.8-flash": "gemini", "gemini3.8-flash-text": "gemini-text", "claude-sonnet5.5": "claude",
           "chatgpt-gpt6.1-sol": "openai", "mix-claude-chatgpt": "mix", "glm5.3-flash": "glm",
           "seg-qwen3.5-2b-8bit": "local"}
RESCORE = {"seg-qwen3.5-2b-bf16-cluster": "window-or-fs-seg-2b", "seg-qwen3.5-4b-cluster": "window-or-fs-seg-4b",
           "qwen3.5-27b-teacher": "window-or-fs-qwen3.5-27b"}
GATEWAY = "gemini3.7-flash-gateway"


def table_routes():
    t = json.loads((RESULTS / "settings-routes.json").read_text())
    st = next(s for s in t["stages"] if s["id"] == "segmentation")
    return {r["id"]: r["figures"]["test-boxes"]["value"] for r in st["routes"] if "test-boxes" in r["figures"]}


def exact_in_support(labels, pred, support):
    import seg_window_gateway as SWG
    return [x if i in support else None for i, x in enumerate(SWG.exact_pages(labels, pred))]


def route_labels():
    """{table id: {box: predicted page labels, no checking}} for every ranked route, from cached answers."""
    rescore.no_network()
    import ensemble as E
    import options as O
    import method_openrouter as R
    import seg_magazine_rule_app as G2
    import seg_text_tier_app as T
    import seg_boxes_score as B
    cols = {n: data.load(n, with_exif=False) for n in data.TEST}
    opts = {a["id"]: a for a in json.loads(O.OUT_JSON.read_text())["approaches"]}
    standard = {n: E.Box(data.load(n, with_exif=False), "CGO") for n in data.TEST}
    _, other = R.five_box([f"X:{R.GLM_KEY}", f"X:{R.LOCAL_SEG_KEY}"])
    failed = Counter()
    sets = {"claude": (standard, ("C",)), "openai": (standard, ("O",)),
            "mix": (standard, tuple(O.frozen_openai()["approaches"]["mix"]["voters"])),
            "glm": (other, (f"X:{R.GLM_KEY}",)), "local": (other, (f"X:{R.LOCAL_SEG_KEY}",)),
            "gemini": ({n: G2.g2_box(n) for n in data.TEST}, ("G",)),
            "gemini-text": ({n: T.box(n, failed) for n in data.TEST}, ("G",))}

    def judged(boxes, voters, level, rule):
        out = {}
        with O.rule(rule):
            for n in data.TEST:
                box = boxes[n]
                j = E.judge(box, voters, level)
                out[n] = list(box.labels_from({i: a for i, (a, _, _, _) in j.items()}))
        return out

    flags = {}
    for tid, aid in OPTIONS.items():
        a = opts[aid]
        boxes, voters = sets[aid]
        flags[tid] = judged(boxes, voters, a["level"], a["rule"])
    # The gateway row: Gemini 3.7 on g1 at offset 0, the shipped route's frozen rule and level (seg-boxes-score.md).
    _, W, _, M = B._mods()
    fz = json.loads((RESULTS / "options-frozen.json").read_text())["approaches"]["gemini"]
    js = B.judges()["gemini"]
    gw = {}
    for n in data.TEST:
        col = cols[n]
        comb = M.combine_units(col, M.spans(len(col.pages), 7, 0), lambda c, a, z: js(c, a, z))
        box = E.Box(col, "")
        box.v = {"G": E._from_bounds(col, W.assemble(col, comb, True))}
        gw[n] = box
    flags[GATEWAY] = judged(gw, tuple(fz["voters"]), fz["level"], fz["rule"])
    srcs = rescore.sources(False)
    for tid, key in RESCORE.items():
        predict, _ = srcs[key]
        flags[tid] = {n: list(predict(cols[n]).labels) for n in data.TEST}
    return flags, cols


def route_flags():
    """{table id: per-page exact flags over Stanton then RG165 (None outside common support)}, the truth documents
    (global page indices)."""
    from score import resolved_documents
    labels, cols = route_labels()
    support = {n: {i for d in resolved_documents(c.labels) for i in d} for n, c in cols.items()}
    docs, off = [], 0
    for n in data.TEST:
        docs += [[k + off for k in sorted(d)] for d in resolved_documents(cols[n].labels)]
        off += len(cols[n].labels)
    flags = {tid: sum((exact_in_support(cols[n].labels, by[n], support[n]) for n in data.TEST), [])
             for tid, by in labels.items()}
    return flags, docs


def bootstrap(fa, fb, docs):
    """The paired interval (the tie), and beside it, for reference only, gap accuracy's own form: McNemar's exact sign
    test on the documents exactly right in one route and not the other, unweighted by pages."""
    import seg_window_gateway as SWG
    from kit_gate_sherlock import paired_row
    r = SWG.bootstrap([bool(x) for x in fa], [bool(x) for x in fb], docs, rounds=ROUNDS, seed=SEED)
    sign = paired_row("", "", [(bool(fa[d[0]]), bool(fb[d[0]])) for d in docs])
    return {k: round(100 * r[k], 2) for k in ("delta", "lo", "hi")} | {
        "pages": r["pages"], "documents": r["runs"], "docs_only_a": sign["only first right"],
        "docs_only_b": sign["only second right"], "sign_p": round(sign["sign test p"], 4),
        "tie": r["lo"] <= 0 <= r["hi"]}   # on the unrounded interval


def main():
    want = table_routes()
    flags, docs = route_flags()
    if set(flags) != set(want):
        raise SystemExit(f"routes differ from the table: {sorted(set(flags) ^ set(want))}")
    pages = sum(len(d) for d in docs)
    exact = {}
    for tid, f in flags.items():
        n = sum(bool(x) for x in f)
        exact[tid] = {"exact_pages": n, "pct": round(100 * n / pages, 1)}
        if abs(exact[tid]["pct"] - want[tid]) > 0.05:
            raise SystemExit(f"{tid}: {n} of {pages} pages exact ({exact[tid]['pct']}%) against the table's {want[tid]}")
    ids = sorted(flags, key=lambda k: -exact[k]["exact_pages"])
    pairs = []
    for a, b in itertools.combinations(ids, 2):
        p = bootstrap(flags[a], flags[b], docs)
        pairs.append({"a": a, "b": b, **p})
    out = {"tag": TAG, "date": dt.date.today().isoformat(), "set": "test-boxes", "pages": pages,
           "documents": len(docs), "rounds": ROUNDS, "seed": SEED, "routes": exact,
           "rule": "a tie when the paired 95% percentile interval of a minus b, resampling truth documents, holds 0",
           "pairs": pairs}
    OUT_JSON.write_text(json.dumps(out, indent=1) + "\n")
    OUT_JSON.with_suffix(".md").write_text(render(out))
    ties = sum(p["tie"] for p in pairs)
    print(f"{len(ids)} routes, {len(pairs)} pairs, {ties} ties; {pages} pages in {len(docs)} documents")
    for p in pairs:
        print(f"  {p['a']:28} {p['b']:28} {p['delta']:+6.2f} [{p['lo']:+6.2f}, {p['hi']:+6.2f}] {'tie' if p['tie'] else ''}")


def render(out) -> str:
    import seg_card
    r = out["routes"]
    L = ["# W46.seg-truth-audit — the segmentation tie as paired comparisons at fixed windows", "",
         f"Offline from cached answers; $0, no model call or upload. Each route's pages in an exact document, no "
         f"checking, on the two test boxes' {out['pages']} common-support document pages ({out['documents']} truth "
         "documents, Stanton and RG165, window offset 0), at its own frozen rule and level. Every pair is compared "
         "page by page on the same windows; the 95% interval resamples the truth's documents "
         f"({out['rounds']:,} rounds, seed {out['seed']}). **A pair ties when its interval holds 0**; the settings "
         "solver then takes the cheaper route. This replaces the floor of twice the larger window-offset range "
         "(5.0 points, or 10.4 for a pair with g2; owner review of the pipeline doc, 2026-11-17).", "",
         "| route | exact pages | pages exact |", "|---|---:|---:|"]
    for k, v in sorted(r.items(), key=lambda kv: -kv[1]["exact_pages"]):
        L.append(f"| {k} | {v['exact_pages']} | {v['pct']:.1f}% |")
    L += ["", "## Every pair, a minus b, in points of pages exact", "",
          "The last two columns are for reference only: gap accuracy's paired form, McNemar's exact sign test, applied "
          "to the documents exactly right in one route and not the other (unweighted by pages). It does not decide.", "",
          "| a | b | a − b | 95% paired interval | tie | documents only a / only b right | sign test p |",
          "|---|---|---:|---|---|---:|---:|"]
    for p in out["pairs"]:
        L.append(f"| {p['a']} | {p['b']} | {p['delta']:+.2f} | [{p['lo']:+.2f}, {p['hi']:+.2f}] | "
                 f"{'tie' if p['tie'] else 'differs'} | {p['docs_only_a']} / {p['docs_only_b']} | {p['sign_p']:.3f} |")
    n_tie = sum(p["tie"] for p in out["pairs"])
    split = sum(p["tie"] and p["sign_p"] < 0.05 for p in out["pairs"])
    L += ["", f"{n_tie} of {len(out['pairs'])} pairs tie. The sign test would separate {split} of the tied pairs "
          "(p under 0.05): it counts documents, so a long document weighs no more than a one-page letter, while pages "
          "exact, the figure the settings show, weighs each document by its pages.", ""]
    edge = [f"{p['a']} against {p['b']}" for p in out["pairs"] if p["tie"] and (p["lo"] == 0 or p["hi"] == 0)
            and p["docs_only_a"] + p["docs_only_b"]]
    if edge:
        L += [f"On the boundary (an end of the interval exactly 0, counted as holding it): {'; '.join(edge)}. A one-document "
              "change in either route or the truth can move such a pair either way.", ""]
    same = [f"{p['a']} and {p['b']}" for p in out["pairs"] if p["docs_only_a"] == p["docs_only_b"] == 0]
    if same:
        L += [f"Identical page by page (no document right in one and not the other): {'; '.join(same)}; each pair is the "
              "same model's answers at temperature 0 (the mix keeps ChatGPT's calls at its level; the 2B on the Mac and "
              "its bf16 cluster run), built from separate cached sources.", ""]
    L += seg_card.card(
        truth="Owner-ruled Stanton and RG165 (truth photo labels), with W46.seg-truth-owner-fixes' eight corrections; "
              "the two unknown RG165 gaps leave 325 of 330 document pages. Truth has been re-judged only where models "
              "disagreed; the agreed-gap audit (seg-truth-audit.md) asks the owner about agreed gaps.",
        selection="The whole frozen test boxes; no gap or document chosen by any route's answers.",
        comparison="Same pages, same windows (offset 0), each route's own frozen rule and level, as in the settings "
                   "table; each route's count is checked against its table figure before any pair is formed.",
        noise="The paired interval covers document sampling on these two boxes. It does not cover window placement "
              "(Gemini 3.7's offsets move pages exact 2.5 points on g1, 5.2 on g2: seg-g2-offsets.md) or a rerun; at "
              "temperature 0 a fixed window gives a fixed answer, so pairing on the same windows removes placement "
              "from the comparison rather than adding it to the floor.",
        scope="Pages exact with no checking only. Not a forecast for other material; per-box intervals are not formed "
              "(two boxes); checking cost and after-checking figures are compared as before.")
    return "\n".join(L) + "\n"


if __name__ == "__main__":
    main()
