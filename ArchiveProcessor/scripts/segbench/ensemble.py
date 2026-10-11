"""Approach F (W36.seg-ensemble): combine the voters, flag what they disagree on, and score the finalists
ONCE on the test collections.

    python ensemble.py report            # development set: voter sets, thresholds leave-one-collection-out,
                                         # risk-coverage curves, the finalists (no calls; caches only)
    python ensemble.py estimate-test     # what collecting the finalists' voters on Stanton + RG165 costs
    python ensemble.py collect-test --final   # those calls (cached); the only paid step
    python ensemble.py final --final     # score the frozen finalists on the test set, once

THE VOTERS, all read from their own caches with truth photo labels (only gaps between two document pages are
voted on; a gap beside a label photo is a boundary by construction):
- ``C`` window-claude (approach A): Claude Sonnet 5.5, 7-page windows, every gap judged twice;
- ``L`` window-gemini-lite (approach B): Gemini 3.1 Flash-Lite over the same windows;
- ``W`` whole-gemini (approach C): Gemini 3.8 Flash, one call per folder;
- ``F`` features-emb-lr-notime (approach D): the on-device logistic model with embeddings and without the
  capture-time gap (the owner's "not a very reliable clue"), each development collection predicted by a
  fit on the other two; on the test set, by a fit on all three.
Approach E (on-device VLMs, 47-57% on Deaver alone) was not run over the development set and is not a voter.

THE RULE, for a voter set S and a level v: a gap is AUTO-ACCEPTED when every voter in S takes the same
decision and the lowest of their confidences is above v; every other gap is FLAGGED for review. v = -1 is
plain unanimity. Fully automatic (no review), a disagreement takes the majority, a tie the most confident
voter. After review a flagged gap takes the truth's decision.

THE THRESHOLD is fitted leave-one-collection-out: for each development collection, v is the smallest level at
which the OTHER two collections each reach 98% of pages in an exact document after review (the owner's bar);
that v is then applied to the held-out collection. Raising v only adds reviews, so the smallest such v is the
least review. For the test set, v is fitted the same way on all three development collections.

THE FINALISTS are chosen on the development set only, by a rule fixed here before the test set is touched:
rank voter sets by (held-out collections reaching 98% after review, most first; pooled held-out review load,
least first); the top two are the finalists. Choosing among 15 voter sets on the development set is itself a
fit, which is why the test set is scored once and its numbers are the ones to trust.
"""
from __future__ import annotations

import concurrent.futures as cf
import csv
import datetime as dt
import itertools
import json
import sys
import threading
import time

import numpy as np

import data
from methods import METHODS  # first: it imports the voter modules
import method_features as MF
import method_gemini as G
import method_whole as WH
import method_window as W
from score import PHOTO, score_labels, segment_ids

BAR = 0.98
VOTERS = {"C": "window-claude", "L": "window-gemini-lite", "W": "whole-gemini", "F": "features-emb-lr-notime"}
CLOUD = ("C", "L", "W")
SETS = [s for k in range(1, 5) for s in itertools.combinations("CLWF", k)]
N_FINALISTS = 2
RESULTS = data.HERE.parent.parent / "segbench-results"
FINAL_RECORD = RESULTS / "ensemble-final.json"
FEAT_WITH_TIME, FEAT_WITH_EMB = False, True


# --- the voters' gap judgements -------------------------------------------------------------------

def doc_gap_index(labels) -> list[int]:
    return [i for i in range(len(labels) - 1) if labels[i] not in PHOTO and labels[i + 1] not in PHOTO]


def _from_bounds(col, pred) -> dict[int, tuple[str, float]]:
    return {i: (pred.boundaries[i]["decision"], float(pred.boundaries[i]["confidence"]))
            for i in doc_gap_index(col.labels)}


def features_all_dev() -> MF.Logistic:
    cols = MF.columns(FEAT_WITH_TIME, FEAT_WITH_EMB)
    X = np.vstack([MF.collection_xy(n)[1][MF.collection_xy(n)[2]][:, cols] for n in data.DEV])
    y = np.concatenate([MF.collection_xy(n)[3][MF.collection_xy(n)[2]] for n in data.DEV])
    return MF.Logistic().fit(X, y)


def features_gaps(col) -> dict[int, tuple[str, float]]:
    if col.name in data.DEV:
        model = MF.fit_fold(col.name, FEAT_WITH_TIME, FEAT_WITH_EMB)
        X = MF.collection_xy(col.name)[1]
    else:
        model = features_all_dev()
        import features as F
        X = F.collection_features(col)
    p = model.predict_proba(X[:, MF.columns(FEAT_WITH_TIME, FEAT_WITH_EMB)])
    return {i: ("new" if p[i] >= 0.5 else "continue", float(max(p[i], 1 - p[i]))) for i in doc_gap_index(col.labels)}


def voter_gaps(code: str, col) -> dict[int, tuple[str, float]]:
    """gap index -> (decision, confidence) over the document gaps, from the voter's cache (no call)."""
    if code == "C":
        return _from_bounds(col, W.assemble(col, W.combine(col, W.judge_window), True))
    if code == "L":
        return _from_bounds(col, W.assemble(col, W.combine(col, G.judge_window), True))
    if code == "W":
        return _from_bounds(col, WH.assemble(col, WH.predict_gaps(col, "whole")))
    if code == "F":
        return features_gaps(col)
    raise KeyError(code)


class Box:
    """One collection: its truth and every available voter's judgements."""

    def __init__(self, col, codes):
        self.name, self.labels = col.name, col.labels
        self.pages = len(col.labels)
        self.gaps = doc_gap_index(col.labels)
        ids = segment_ids(col.labels)
        self.truth = {i: "new" if ids[i] != ids[i + 1] else "continue" for i in self.gaps}
        self.v = {c: voter_gaps(c, col) for c in codes}

    def labels_from(self, dec: dict[int, str]) -> list[str]:
        out = []
        for i, t in enumerate(self.labels):
            if t in PHOTO:
                out.append(t)
            elif i == 0 or self.labels[i - 1] in PHOTO or dec[i - 1] == "new":
                out.append("New")
            else:
                out.append("Cont")
        return out


# --- the rule -------------------------------------------------------------------------------------

def judge(box: Box, S, v: float):
    """Per document gap: (auto decision, flagged, lowest confidence, agreed)."""
    out = {}
    for i in box.gaps:
        js = [box.v[c][i] for c in S]
        decs = [d for d, _ in js]
        agree = len(set(decs)) == 1
        lo = min(x for _, x in js)
        n_new = decs.count("new")
        if n_new * 2 != len(decs):
            auto = "new" if n_new * 2 > len(decs) else "continue"
        else:
            auto = max(js, key=lambda j: j[1])[0]
        out[i] = (auto, not (agree and lo > v), lo, agree)
    return out


def evaluate(box: Box, S, v: float) -> dict:
    j = judge(box, S, v)
    auto = {i: a for i, (a, _, _, _) in j.items()}
    rev = {i: (box.truth[i] if f else a) for i, (a, f, _, _) in j.items()}
    s_auto = score_labels(box.labels, box.labels_from(auto))
    s_rev = score_labels(box.labels, box.labels_from(rev))
    acc = [i for i, (_, f, _, _) in j.items() if not f]
    return {"pages": box.pages, "gaps": len(box.gaps), "flagged": len(box.gaps) - len(acc),
            "accepted": len(acc), "acc_err": sum(auto[i] != box.truth[i] for i in acc),
            "auto": s_auto, "rev": s_rev, "auto_err": sum(auto[i] != box.truth[i] for i in box.gaps)}


def pooled(rows: list[dict]) -> dict:
    out = {k: sum(r[k] for r in rows) for k in ("pages", "gaps", "flagged", "accepted", "acc_err", "auto_err")}
    out["auto"] = sum((r["auto"] for r in rows[1:]), rows[0]["auto"])
    out["rev"] = sum((r["rev"] for r in rows[1:]), rows[0]["rev"])
    return out


def pe(s) -> float:
    return s.pages_exact / s.doc_pages


def levels(boxes, S) -> list[float]:
    """-1 (unanimity only), then every distinct lowest confidence among agreed gaps: v = x flags them up to x."""
    vals = {round(judge(b, S, -1)[i][2], 6) for b in boxes for i in b.gaps}
    return [-1.0] + sorted(vals)


def fit_level(boxes, S) -> float | None:
    """Smallest v at which every box reaches the bar after review; None if not even flagging all does."""
    for v in levels(boxes, S) + [2.0]:
        if all(pe(evaluate(b, S, v)["rev"]) >= BAR for b in boxes):
            return v
    return None


def loco(dev: dict[str, Box], S) -> dict:
    rows, vs = [], {}
    for h in data.DEV:
        v = fit_level([dev[n] for n in data.DEV if n != h], S)
        vs[h] = v
        rows.append(evaluate(dev[h], S, 2.0 if v is None else v) | {"name": h})
    return {"rows": rows, "levels": vs, "pooled": pooled(rows),
            "reached": sum(pe(r["rev"]) >= BAR for r in rows)}


def curve(boxes, S) -> list[dict]:
    out = []
    for v in levels(boxes, S):
        rows = [evaluate(b, S, v) for b in boxes]
        p = pooled(rows)
        out.append({"v": v, "coverage": p["accepted"] / p["gaps"], "accepted": p["accepted"],
                    "acc_err": p["acc_err"], "flagged": p["flagged"],
                    "per100": 100 * p["flagged"] / p["pages"], "rev": pe(p["rev"]),
                    "worst": min(pe(r["rev"]) for r in rows)})
    return out


def name(S) -> str:
    return " + ".join(VOTERS[c] for c in S)


def short(S) -> str:
    return "".join(S)


def pct(x) -> str:
    return f"{100 * x:.1f}%"


def lv(v) -> str:
    return "none reaches" if v is None else ("unanimity" if v < 0 else f"<= {v:.3f}")


def rank(results: dict) -> list:
    return sorted(results, key=lambda S: (-results[S]["reached"], results[S]["pooled"]["flagged"]
                                          / results[S]["pooled"]["pages"], -pe(results[S]["pooled"]["rev"])))


# --- development report ---------------------------------------------------------------------------

def load_dev() -> dict[str, Box]:
    return {n: Box(data.load(n), "CLWF") for n in data.DEV}


def report() -> str:
    dev = load_dev()
    pages = sum(b.pages for b in dev.values())
    gaps = sum(len(b.gaps) for b in dev.values())
    res = {S: loco(dev, S) for S in SETS}
    order = rank(res)
    finalists = order[:N_FINALISTS]
    L = ["# W36.seg-ensemble — combining the voters (development set)", "",
         f"Run {dt.date.today().isoformat()} on Dean, Deaver and Herrnstein ({pages} pages, {gaps} gaps between two "
         "document pages); the test collections were not touched by anything on this page. Truth photo labels "
         "throughout. No new model call: every voter is read from its cache. Rule and threshold fitting: "
         "`scripts/segbench/ensemble.py` (module docstring).", "",
         "Voters: " + "; ".join(f"{c} = {VOTERS[c]}" for c in "CLWF") + ".", "",
         "## Every voter set, threshold fitted leave-one-collection-out", "",
         "Each development collection's row uses the level fitted on the other two (the smallest at which both "
         "reach 98% of pages in an exact document after review), so every figure here is held out in that sense. "
         "No review = the rule's decisions alone. Flagged = the gaps sent to review. Errors left = wrong "
         "decisions among the auto-accepted gaps, which review never sees.", "",
         "| rank | voters | held-out collections at 98% after review | flagged per 100 pages | errors left "
         "(per 500 pages) | pages in exact doc, no review | after review | worst collection after review | "
         "levels (Dean / Deaver / Herrnstein) |",
         "|---:|---|---:|---:|---:|---:|---:|---:|---|"]
    for k, S in enumerate(order, 1):
        r = res[S]
        p = r["pooled"]
        L.append(f"| {k} | {short(S)} | {r['reached']} of 3 | {100 * p['flagged'] / p['pages']:.1f} | "
                 f"{p['acc_err']} ({500 * p['acc_err'] / p['pages']:.1f}) | {pct(pe(p['auto']))} | "
                 f"{pct(pe(p['rev']))} | {pct(min(pe(x['rev']) for x in r['rows']))} | "
                 + " / ".join(lv(r["levels"][n]) for n in data.DEV) + " |")
    L += ["", f"Finalists (the top {N_FINALISTS} by the rule in the module docstring): "
          + "; ".join(f"**{short(S)}** ({name(S)})" for S in finalists) + ".", ""]
    # unanimity alone, no fitted parameter
    L += ["## Unanimity alone (no fitted parameter)", "",
          "| voters | flagged per 100 pages | errors left | after review | worst collection after review |",
          "|---|---:|---:|---:|---:|"]
    for S in order:
        rows = [evaluate(dev[n], S, -1.0) for n in data.DEV]
        p = pooled(rows)
        L.append(f"| {short(S)} | {100 * p['flagged'] / p['pages']:.1f} | {p['acc_err']} | {pct(pe(p['rev']))} | "
                 f"{pct(min(pe(x['rev']) for x in rows))} |")
    L.append("")
    # per collection for the finalists
    L += ["## The finalists by collection (held out)", "",
          "| voters | collection | level (fitted on the other two) | flagged | per 100 pages | errors left | "
          "no review | after review |", "|---|---|---|---:|---:|---:|---:|---:|"]
    for S in finalists:
        for r in res[S]["rows"]:
            L.append(f"| {short(S)} | {r['name']} | {lv(res[S]['levels'][r['name']])} | {r['flagged']} | "
                     f"{100 * r['flagged'] / r['pages']:.1f} | {r['acc_err']} | {pct(pe(r['auto']))} | "
                     f"{pct(pe(r['rev']))} |")
    L.append("")
    # risk-coverage curves (pooled dev, levels swept; not held out — the curve is the trade-off itself)
    L += ["## Risk–coverage, pooled development set", "",
          "The level swept over every value, pooled over the three collections. Coverage = share of the "
          f"{gaps} document gaps auto-accepted. This is the trade-off itself, read in-sample; the held-out "
          "levels are the table above. Full curves: ensemble-curves-dev.csv.", ""]
    curves = {S: curve(list(dev.values()), S) for S in SETS}
    for S in finalists + [s for s in (("C",), ("W",), ("C", "W")) if s not in finalists]:
        cv = curves[S]
        pick = [cv[0]]
        for target in (0.99, 0.98, 0.97, 0.95, 0.90, 0.80):
            ok = [x for x in cv if x["coverage"] >= target - 1e-9]
            if ok and ok[-1] not in pick:
                pick.append(ok[-1])
        for want in (0.98, 0.99, 1.0):
            hit = next((x for x in cv if x["worst"] >= want - 1e-9), None)
            if hit and hit not in pick:
                pick.append(hit)
        pick.sort(key=lambda x: x["v"])
        L += [f"### {short(S)} ({name(S)})", "",
              "| level | coverage | errors among accepted | error rate | flagged per 100 pages | after review, "
              "pooled | worst collection |", "|---|---:|---:|---:|---:|---:|---:|"]
        for x in pick:
            L.append(f"| {lv(x['v'])} | {pct(x['coverage'])} | {x['acc_err']} | "
                     f"{pct(x['acc_err'] / x['accepted']) if x['accepted'] else '—'} | {x['per100']:.1f} | "
                     f"{pct(x['rev'])} | {pct(x['worst'])} |")
        L.append("")
    with open(RESULTS / "ensemble-curves-dev.csv", "w", newline="") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(["voters", "level", "coverage", "accepted", "errors_among_accepted", "flagged",
                    "flagged_per_100_pages", "pages_in_exact_doc_after_review", "worst_collection_after_review"])
        for S in SETS:
            for x in curves[S]:
                w.writerow([short(S), f"{x['v']:.6f}", f"{x['coverage']:.6f}", x["accepted"], x["acc_err"],
                            x["flagged"], f"{x['per100']:.3f}", f"{x['rev']:.6f}", f"{x['worst']:.6f}"])
    L += approach_g()
    text = "\n".join(L) + "\n"
    (RESULTS / "ensemble-dev.md").write_text(text)
    sec = ["", "## W36.seg-ensemble — voters combined, thresholds fitted leave-one-collection-out", "",
           "A gap is auto-accepted when the voters agree and their lowest confidence is above a level fitted on the "
           "other development collections to reach 98% after review; the rest are flagged. Detail: ensemble-dev.md "
           "(development) and ensemble-test.md (the test collections, scored once).", "",
           "Development, held out per collection: " + "; ".join(
               f"{short(S)} {pct(pe(res[S]['pooled']['rev']))} after review at "
               f"{100 * res[S]['pooled']['flagged'] / res[S]['pooled']['pages']:.1f} flagged per 100 pages, "
               f"{res[S]['pooled']['acc_err']} errors left" for S in finalists) + "."]
    (RESULTS / "ensemble.summary-section.md").write_text("\n".join(sec) + "\n")
    import run
    run.write_summary()
    (RESULTS / "ensemble-finalists.json").write_text(json.dumps(
        {"finalists": [short(S) for S in finalists], "rule": "ensemble.py docstring", "bar": BAR,
         "decided": dt.date.today().isoformat(), "on": list(data.DEV)}, indent=1) + "\n")
    return text


def approach_g() -> list[str]:
    return ["## Approach G — the phone's \"End segment\" marks on RG 165", "",
            "Not measurable: unknown. RG 165 is the only Live Capture box, but its ground-truth folder holds only "
            "the CSV and the camera's JPEGs (Pixel 9 HDR+ files, no Archive Capture metadata), and no staging "
            "manifest or recorded group list for it survives under Test Files/ (the only other RG 165 files there "
            "are the spring Gemini runs' outputs). How many errors "
            "the operator's segment marks would have removed cannot be counted from what is kept; it would need a "
            "fresh Live Capture box whose groups are saved.", ""]


# --- the test set ---------------------------------------------------------------------------------

def frozen() -> list[tuple]:
    f = RESULTS / "ensemble-finalists.json"
    if not f.exists():
        raise SystemExit("no finalists yet: run `ensemble.py report` on the development set first")
    return [tuple(s) for s in json.loads(f.read_text())["finalists"]]


def need_final(argv) -> None:
    if "--final" not in argv:
        raise SystemExit("the test collections are touched only with --final (once, for the frozen finalists)")


def test_jobs():
    codes = sorted({c for S in frozen() for c in S if c in CLOUD})
    jobs = []
    for n in data.TEST:
        col = data.load(n, with_exif=False)
        if "C" in codes:
            jobs += [("C", col, a, b) for a, b in W.windows(len(col.pages))]
        if "L" in codes:
            jobs += [("L", col, a, b) for a, b in W.windows(len(col.pages))]
        if "W" in codes:
            jobs += [("W", col, a, b) for a, b in WH.units(col, "whole")]
    judges = {"C": W.judge_window, "L": G.judge_window, "W": WH.judge_unit}
    return [(c, col, a, b, judges[c]) for c, col, a, b in jobs]


def estimate_test() -> None:
    jobs = test_jobs()
    todo = [j for j in jobs if j[4](j[1], j[2], j[3], allow_call=False) is None]
    dev_pages = sum(len(data.load(n, with_exif=False).pages) for n in data.DEV)
    test_pages = sum(len(data.load(n, with_exif=False).pages) for n in data.TEST)
    ratio = test_pages / dev_pages
    print(f"finalists {['+'.join(S) for S in frozen()]}; {len(jobs)} calls on the test set, {len(todo)} not cached")
    for c in sorted({j[0] for j in jobs}):
        k = sum(1 for j in todo if j[0] == c)
        if c == "C":
            print(f"  C window-claude: {k} `claude -p` calls (subscription usage, no API spend)")
        elif c == "L":
            print(f"  L window-gemini-lite: {k} calls; dev spend ${G.spent():.2f} x {ratio:.2f} pages -> "
                  f"about ${G.spent() * ratio:.2f} at most (dev includes probes)")
        else:
            print(f"  W whole-gemini: {k} calls; dev spend ${WH.spent():.2f} (both variants) x {ratio:.2f} -> "
                  f"about ${WH.spent() * ratio:.2f} at most")


def collect_test() -> None:
    if FINAL_RECORD.exists():
        raise SystemExit(f"{FINAL_RECORD.name} exists: the test set has been scored; nothing to collect")
    estimate_test()
    todo = [j for j in test_jobs() if j[4](j[1], j[2], j[3], allow_call=False) is None]
    stop, lock, done, t0 = threading.Event(), threading.Lock(), [0], time.time()

    def work(job):
        c, col, a, b, fn = job
        if stop.is_set():
            return
        try:
            fn(col, a, b)
        except (W.UsageLimit, G.Fatal) as e:
            stop.set()
            print(f"STOPPING ({c}): {str(e)[:300]}", flush=True)
            return
        except Exception as e:  # noqa: BLE001 - one unit failing does not stop the rest
            print(f"FAILED {c} {col.name} {col.pages[a].n}-{col.pages[b - 1].n}: {str(e)[:200]}", flush=True)
            return
        with lock:
            done[0] += 1
            print(f"[{done[0]}/{len(todo)} {time.time() - t0:.0f}s] {c} {col.name} "
                  f"{col.pages[a].n}-{col.pages[b - 1].n}", flush=True)

    # one pool per voter so a slow Claude call never holds up the Gemini ones
    pools = {"C": W.CONCURRENCY, "L": G.CONCURRENCY, "W": WH.CONCURRENCY}
    execs = {c: cf.ThreadPoolExecutor(k) for c, k in pools.items()}
    futs = [execs[j[0]].submit(work, j) for j in todo]
    for f in cf.as_completed(futs):
        f.result()
    for ex in execs.values():
        ex.shutdown()
    print(f"done in {time.time() - t0:.0f}s; Gemini spend so far: lite ${G.spent():.2f}, whole ${WH.spent():.2f}")


def final() -> str:
    if FINAL_RECORD.exists():
        raise SystemExit(f"{FINAL_RECORD.name} exists: the test set is scored once; see ensemble-test.md")
    fins = frozen()
    dev = load_dev()
    codes = sorted({c for S in fins for c in S})
    test = {n: Box(data.load(n), codes) for n in data.TEST}
    pages = sum(b.pages for b in test.values())
    L = ["# W36.seg-ensemble — the finalists on the test collections (scored once)", "",
         f"Run {dt.date.today().isoformat()} on Stanton and RG 165 ({pages} pages), never used to choose or tune "
         "anything: the finalists and the rule were frozen on the development set (ensemble-dev.md, "
         "ensemble-finalists.json) before these collections' calls were made, and each finalist's level was "
         "fitted on all three development collections. Truth photo labels throughout. The spring 2026 prompts "
         "saw all five collections; the voters' prompts here were written after reading development pages and "
         "the owner's notes, not test pages.", "",
         "| voters | level (fitted on dev) | collection | pages | flagged | per 100 pages | errors left | "
         "pages in exact doc, no review | after review | docs exact after review |",
         "|---|---|---|---:|---:|---:|---:|---:|---:|---:|"]
    record = {"date": dt.date.today().isoformat(), "finalists": {}}
    for S in fins:
        v = fit_level(list(dev.values()), S)
        vv = 2.0 if v is None else v
        rows = [evaluate(test[n], S, vv) | {"name": n} for n in data.TEST]
        p = pooled(rows) | {"name": "pooled"}
        for r in rows + [p]:
            L.append(f"| {short(S)} | {lv(v)} | {r['name']} | {r['pages']} | {r['flagged']} | "
                     f"{100 * r['flagged'] / r['pages']:.1f} | {r['acc_err']} | {pct(pe(r['auto']))} | "
                     f"{pct(pe(r['rev']))} | {pct(r['rev'].docs_exact / r['rev'].docs)} |")
        record["finalists"][short(S)] = {"level": v, **{r["name"]: {
            "flagged": r["flagged"], "errors_left": r["acc_err"], "pe_auto": pe(r["auto"]),
            "pe_review": pe(r["rev"])} for r in rows + [p]}}
    L += ["", "## Each voter alone on the test set (no review)", "",
          "| voter | collection | pages in exact doc | false splits | false merges |", "|---|---|---:|---:|---:|"]
    for c in codes:
        for n, b in test.items():
            s = b.labels_from({i: d for i, (d, _) in b.v[c].items()})
            sc = score_labels(b.labels, s)
            L.append(f"| {VOTERS[c]} | {n} | {pct(pe(sc))} | {sc.false_splits} | {sc.false_merges} |")
    L += ["", "Against the development set (ensemble-dev.md): a drop here is the honest size of what choosing "
          "the voter set and levels on the development set bought.", ""]
    text = "\n".join(L) + "\n"
    (RESULTS / "ensemble-test.md").write_text(text)
    FINAL_RECORD.write_text(json.dumps(record, indent=1, default=float) + "\n")
    sec = RESULTS / "ensemble.summary-section.md"
    sec.write_text(sec.read_text().rstrip() + "\n\nTest (Stanton + RG 165, scored once, levels fitted on all three "
                   "development collections): " + "; ".join(
                       f"{k} {pct(f['pooled']['pe_review'])} after review at "
                       f"{100 * f['pooled']['flagged'] / pages:.1f} flagged per 100 pages, "
                       f"{f['pooled']['errors_left']} errors left, {pct(f['pooled']['pe_auto'])} with no review"
                       for k, f in record["finalists"].items()) + ".\n")
    import run
    run.write_summary()
    return text


def main(argv) -> int:
    if not argv or argv[0] not in ("report", "estimate-test", "collect-test", "final"):
        print(__doc__)
        return 2
    cmd = argv[0]
    if cmd == "report":
        print(report())
    elif cmd == "estimate-test":
        estimate_test()
    elif cmd == "collect-test":
        need_final(argv)
        collect_test()
    else:
        need_final(argv)
        print(final())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
