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

W46.p16-seg-tie-floor (measurement review pass 16, P16-1): the paired interval covers document sampling only. A
byte-identical vLLM rerun of the self-hosted students moved a box's pages exact by 1.4 to 3.2 points (SEG-10,
seg-kit-gate.md, seg-window-modality.md), so each pair also carries `tie_floor`: a tie unless the interval clears 0 and
its near end clears the larger recorded rerun floor of the two routes. The cloud routes have no recorded rerun floor
(an identical-window rerun was never scored for one), which counts as 0 here and is said on the card. The rule in force
(`tie`, which the settings table reads) is unchanged until the owner answers. `seg11` counts, per differing pair, the
discordant documents whose deciding gaps the owner never re-judged (SEG-11).

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
# The recorded rerun floor, points of pages exact a box: the top of SEG-10's 1.4-3.2 between byte-identical vLLM reruns
# (the 2B on Stanton 75.3, 76.1, 78.6: seg-window-modality.md; seg-kit-gate.md §Reading). Measured on the 2B and the
# teacher; the 4B is the same family on the same server and carries it too. The Mac 2B row's test-box answers are the
# FarmShare bf16 run (method_openrouter.LOCAL_SEG_KEY), so its floor is the bf16 run's.
RERUN_FLOOR = {"seg-qwen3.5-2b-8bit": 3.2, "seg-qwen3.5-2b-bf16-cluster": 3.2, "seg-qwen3.5-4b-cluster": 3.2,
               "qwen3.5-27b-teacher": 3.2}


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
    return flags, docs, labels, cols


def bootstrap(fa, fb, docs, floor=0.0):
    """The paired interval (the tie), and beside it, for reference only, gap accuracy's own form: McNemar's exact sign
    test on the documents exactly right in one route and not the other, unweighted by pages."""
    import seg_window_gateway as SWG
    from kit_gate_sherlock import paired_row
    r = SWG.bootstrap([bool(x) for x in fa], [bool(x) for x in fb], docs, rounds=ROUNDS, seed=SEED)
    sign = paired_row("", "", [(bool(fa[d[0]]), bool(fb[d[0]])) for d in docs])
    return {k: round(100 * r[k], 2) for k in ("delta", "lo", "hi")} | {
        "pages": r["pages"], "documents": r["runs"], "docs_only_a": sign["only first right"],
        "docs_only_b": sign["only second right"], "sign_p": round(sign["sign test p"], 4),
        "tie": r["lo"] <= 0 <= r["hi"],   # on the unrounded interval
        "floor": floor, "tie_floor": r["lo"] <= 0 <= r["hi"] or min(abs(r["lo"]), abs(r["hi"])) * 100 < floor}


def rejudged() -> set[str]:
    """"<box> <left>|<right>" of every test-box gap the owner has looked at again since his capture labels: the 92 the
    app's Gemini route flagged (13 Nov), Stanton's magazine rulings, and the 50 agreed gaps of the audit."""
    import seg_truth_audit as A
    return A.answered() | set(json.loads(A.RECORD.read_text())["keys"])


def seg11(a, b, flags, labels, cols, winner):
    """SEG-11 for one pair: the discordant documents (exact in one route only) and those among them decided at a gap the
    owner never re-judged, a gap in or bounding the document where the two routes' calls differ. `neutral` is the
    winner's edge with those documents set to the loser's flags (as if each such gap's truth were wrong)."""
    from score import resolved_documents, segment_ids
    done = rejudged()
    loser = b if winner == a else a
    out = {"discordant": 0, "unrejudged": 0, "unrejudged_for_winner": 0, "gaps": []}
    neutral = list(flags[winner])
    off = 0
    for n in data.TEST:
        col = cols[n]
        ia, ib = segment_ids(labels[a][n]), segment_ids(labels[b][n])
        for d in resolved_documents(col.labels):
            k = sorted(d)
            ea, eb = bool(flags[a][k[0] + off]), bool(flags[b][k[0] + off])
            if ea == eb:
                continue
            out["discordant"] += 1
            open_ = [f"{n} {col.pages[i].n}|{col.pages[i + 1].n}" for i in range(max(k[0] - 1, 0), min(k[-1] + 1,
                     len(col.labels) - 1)) if (ia[i] != ia[i + 1]) != (ib[i] != ib[i + 1])]
            open_ = [g for g in open_ if g not in done]
            if open_:
                out["unrejudged"] += 1
                out["gaps"] += open_
                if (ea if winner == a else eb):
                    out["unrejudged_for_winner"] += 1
                    for i in k:
                        neutral[i + off] = flags[loser][i + off]
        off += len(col.labels)
    return out, neutral


def main():
    want = table_routes()
    flags, docs, labels, cols = route_flags()
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
        p = bootstrap(flags[a], flags[b], docs, max(RERUN_FLOOR.get(a, 0), RERUN_FLOOR.get(b, 0)))
        if not p["tie"]:   # the differing pairs: what the owner never re-judged could move
            w = a if p["delta"] > 0 else b
            s11, neutral = seg11(a, b, flags, labels, cols, w)
            l = b if w == a else a
            q = bootstrap(neutral, flags[l], docs, p["floor"])
            s11["neutral"] = {k: q[k] for k in ("delta", "lo", "hi", "tie", "tie_floor")}
            p["seg11"] = s11
        pairs.append({"a": a, "b": b, **p})
    out = {"tag": TAG, "date": dt.date.today().isoformat(), "set": "test-boxes", "pages": pages,
           "documents": len(docs), "rounds": ROUNDS, "seed": SEED, "routes": exact,
           "rule": "a tie when the paired 95% percentile interval of a minus b, resampling truth documents, holds 0",
           "rule_floor": "tie_floor: a tie unless the interval clears 0 and its near end clears the larger recorded "
                         "rerun floor of the two routes (W46.p16-seg-tie-floor; not in force until the owner answers)",
           "rerun_floor": RERUN_FLOOR,
           "pairs": pairs}
    OUT_JSON.write_text(json.dumps(out, indent=1) + "\n")
    OUT_JSON.with_suffix(".md").write_text(render(out))
    ties = sum(p["tie"] for p in pairs)
    print(f"{len(ids)} routes, {len(pairs)} pairs, {ties} ties, {sum(p['tie_floor'] for p in pairs)} with the floor; "
          f"{pages} pages in {len(docs)} documents")
    for p in pairs:
        print(f"  {p['a']:28} {p['b']:28} {p['delta']:+6.2f} [{p['lo']:+6.2f}, {p['hi']:+6.2f}] "
              f"{'tie' if p['tie'] else 'differs'} / {'tie' if p['tie_floor'] else 'differs'}")


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
         "**The rerun floor (W46.p16-seg-tie-floor, not in force until the owner answers).** The interval does not "
         "cover a rerun. Byte-identical vLLM reruns of the self-hosted students moved a box's pages exact by 1.4 to "
         "3.2 points (SEG-10; the 2B on Stanton 75.3, 76.1 and 78.6%, seg-window-modality.md; seg-kit-gate.md "
         "§Reading). The column *with the floor* calls a pair different only when its interval clears 0 and its near "
         "end also clears the larger recorded floor of its two routes (" + ", ".join(
             f"{k} {v}" for k, v in out["rerun_floor"].items()) + " points; a cloud route has none recorded, so 0).", "",
         "| route | exact pages | pages exact | rerun floor |", "|---|---:|---:|---:|"]
    for k, v in sorted(r.items(), key=lambda kv: -kv[1]["exact_pages"]):
        fl = out["rerun_floor"].get(k)
        L.append(f"| {k}{' (test-box answers: the FarmShare bf16 run)' if k == 'seg-qwen3.5-2b-8bit' else ''} | "
                 f"{v['exact_pages']} | {v['pct']:.1f}% | {fl if fl else 'none recorded'} |")
    L += ["", "The two 2B rows are the same answers: the Mac row's test-box figure is the full-precision FarmShare run "
          "(`method_openrouter.py` `LOCAL_SEG_KEY = \"fs-seg-2b\"`; the Mac's 8-bit build matched it on the development "
          "boxes, 90.3% against 90.5%, seg-students.md §On the Mac). Their identical figures say nothing about rerun "
          "noise."]
    L += ["", "## Every pair, a minus b, in points of pages exact", "",
          "The last two columns are for reference only: gap accuracy's paired form, McNemar's exact sign test, applied "
          "to the documents exactly right in one route and not the other (unweighted by pages). It does not decide.", "",
          "| a | b | a − b | 95% paired interval | tie (in force) | with the floor | documents only a / only b right | sign test p |",
          "|---|---|---:|---|---|---|---:|---:|"]
    for p in out["pairs"]:
        L.append(f"| {p['a']} | {p['b']} | {p['delta']:+.2f} | [{p['lo']:+.2f}, {p['hi']:+.2f}] | "
                 f"{'tie' if p['tie'] else 'differs'} | {'tie' if p['tie_floor'] else 'differs'} | "
                 f"{p['docs_only_a']} / {p['docs_only_b']} | {p['sign_p']:.3f} |")
    P = out["pairs"]
    n_tie, n_fl = sum(p["tie"] for p in P), sum(p["tie_floor"] for p in P)
    split = sum(p["tie"] and p["sign_p"] < 0.05 for p in P)
    diff = [p for p in P if not p["tie"]]
    unsep = [p for p in diff if p["sign_p"] >= 0.05]
    moved = [p for p in diff if p["tie_floor"]]
    still = [f"{p['a']} over {p['b']} ({p['delta']:+.2f} [{p['lo']:+.2f}, {p['hi']:+.2f}])" for p in diff
             if not p["tie_floor"]]
    L += ["", f"{n_tie} of {len(P)} pairs tie under the interval alone; {n_fl} with the floor. The sign test both ways: "
          f"it separates {split} of the {n_tie} tied pairs, and leaves {len(unsep)} of the {len(diff)} differing pairs "
          f"unseparated (p {', '.join(f'{p['sign_p']:.3f}' for p in sorted(unsep, key=lambda p: p['sign_p']))}), so "
          "the two methods agree on the ties only. It counts documents, so a long document weighs no more than a "
          "one-page letter, while pages exact, the figure the settings show, weighs each document by its pages.", "",
          f"With the floor, {len(moved)} of the {len(diff)} differing pairs become ties: each has the 2B, the 4B or the "
          f"teacher on a side and a near end inside {max(out['rerun_floor'].values())} points. {len(still)} still "
          f"differ: {'; '.join(still)}.", ""]
    edge = [f"{p['a']} against {p['b']}" for p in out["pairs"] if p["tie"] and (p["lo"] == 0 or p["hi"] == 0)
            and p["docs_only_a"] + p["docs_only_b"]]
    if edge:
        L += [f"On the boundary (an end of the interval exactly 0, counted as holding it): {'; '.join(edge)}. A one-document "
              "change in either route or the truth can move such a pair either way.", ""]
    same = [f"{p['a']} and {p['b']}" for p in out["pairs"] if p["docs_only_a"] == p["docs_only_b"] == 0]
    if same:
        L += [f"Identical page by page (no document right in one and not the other): {'; '.join(same)}; each pair is the "
              "same answers (the mix keeps ChatGPT's calls at its level; the 2B on the Mac row is scored from the "
              "bf16 FarmShare run, the same answers as the cluster row), not two runs.", ""]
    L += ["## The differing pairs and the gaps no one re-judged (SEG-11)", "",
          "Truth was re-judged only where models disagreed with it: the 92 gaps the app's Gemini route flagged (13 Nov), "
          "Stanton's magazine rulings and the 50 agreed gaps of the audit. For each pair the interval separates, the "
          "documents exactly right in one route only, and how many of them are decided at a gap the owner never looked "
          "at again (a gap in or bounding the document where the two routes' calls differ). *Neutralised* sets the "
          "winner's flags on those documents to the loser's, as if the truth were wrong at every such gap against "
          "the winner: the pair's edge if none of them counted.", "",
          "| a | b | discordant documents | decided at an un-re-judged gap (for the winner) | neutralised a − b | "
          "interval / with the floor |", "|---|---|---:|---:|---|---|"]
    for p in diff:
        s, q = p["seg11"], p["seg11"]["neutral"]
        sign = 1 if p["delta"] > 0 else -1
        L.append(f"| {p['a']} | {p['b']} | {s['discordant']} | {s['unrejudged']} ({s['unrejudged_for_winner']}) | "
                 f"{sign * q['delta']:+.2f} [{min(sign * q['lo'], sign * q['hi']):+.2f}, "
                 f"{max(sign * q['lo'], sign * q['hi']):+.2f}] | {'tie' if q['tie'] else 'differs'} / "
                 f"{'tie' if q['tie_floor'] else 'differs'} |")
    flip = [f"{p['a']} over {p['b']}" for p in diff if p["seg11"]["neutral"]["tie"]]
    L += ["", (f"Neutralised, {len(flip)} of the {len(diff)} pairs would tie under the interval alone: "
               f"{'; '.join(flip)}." if flip else f"Neutralised, every one of the {len(diff)} pairs still clears 0.")
          + " These are the verdicts an owner look at those gaps could move; no truth is changed here.", ""]
    L += seg_card.card(
        truth="Owner-ruled Stanton and RG165 (truth photo labels), with W46.seg-truth-owner-fixes' eight corrections; "
              "the two unknown RG165 gaps leave 325 of 330 document pages. Truth has been re-judged only where models "
              "disagreed; the agreed-gap audit (seg-truth-audit.md) asks the owner about agreed gaps.",
        selection="The whole frozen test boxes; no gap or document chosen by any route's answers.",
        comparison="Same pages, same windows (offset 0), each route's own frozen rule and level, as in the settings "
                   "table; each route's count is checked against its table figure before any pair is formed.",
        noise="The paired interval covers document sampling on these two boxes. It does not cover window placement "
              "(Gemini 3.7's offsets move pages exact 2.5 points on g1, 5.2 on g2: seg-g2-offsets.md), which pairing on "
              "the same windows takes out of the comparison, nor a rerun: a fixed window does not give a fixed answer. "
              "Byte-identical vLLM reruns of the self-hosted students moved a box 1.4-3.2 points (SEG-10), and the "
              "'with the floor' column carries the 3.2 for every pair with a student. No cloud route has an "
              "identical-window rerun scored, so its floor is unmeasured and counted 0; a g2 rerun of the 363 pages "
              "(about $1.3 at list) would measure one. Every differing pair has a student on a side.",
        scope="Pages exact with no checking only. Not a forecast for other material; per-box intervals are not formed "
              "(two boxes); checking cost and after-checking figures are compared as before.")
    return "\n".join(L) + "\n"


if __name__ == "__main__":
    main()
