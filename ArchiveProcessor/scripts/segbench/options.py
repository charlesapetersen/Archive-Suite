"""W36.seg-opt-measure: the figures for every segmentation approach the Processor will offer.

    python options.py tokens-claude        # Anthropic count_tokens (free) on every cached window-claude window
    python options.py report               # development set: each approach's level held out per box, the mix
                                           # rule chosen; writes options-dev.md and freezes options-frozen.json
    python options.py estimate-test        # what collecting the frozen approaches on Stanton + RG165 costs
    python options.py collect-test --final # those calls (cached); the paid step
    python options.py final --final        # score the frozen approaches on the test set, once; writes
                                           # segbench-results/options.md and options.json

THE APPROACHES (owner, 2026-10-11; execution-plans/segmentation/04-options-build.md):
- ``manual``: the Processor's modes today; nothing proposed, every boundary judged by the user.
- ``claude`` (voter C): window-claude, Claude Sonnet 5.5 over 7-page windows, stride 3, prompt w1;
- ``gemini`` (voter G): Gemini 3.8 Flash at thinkingLevel low over the same windows, prompt g1 (the owner's
  cues), compare_gemini's ``gemini-3.8-flash-low`` cache;
- ``openai``: an OpenAI model over the same windows. NOT MEASURED in this run: no OpenAI API key is in the
  Keychain and the Codex route answered "Your workspace is out of credits" (2026-10-11). The one box measured
  earlier (Deaver, Codex gpt-6.1-sol, cues prompt c1) is reported as that and nothing more.
- ``mix``: the window voters combined. Two combining rules are compared on the development set, and the one
  the ranking below prefers is the mix offered:
    MIN  (ensemble.py's rule) a gap is auto-accepted when every voter takes the same decision and the lowest
         of their confidences is above the level; otherwise flagged.
    MEAN each voter's P(new) averaged; decision new when the mean is >= 0.5; flagged when the combined
         confidence max(m, 1 - m) is at or below the level. A disagreement can be auto-accepted when the
         mean is confident.
  For one voter the two rules are the same: flag a gap whose confidence is at or below the level.

THE LEVEL per approach is fitted exactly as in ensemble.py: leave-one-collection-out on Dean, Deaver and
Herrnstein (the smallest level at which the other two reach 98% of pages in an exact document after review),
and for the test set on all three. Truth photo labels throughout, as in ensemble.py: only gaps between two
document pages are voted on.

THE FREEZE. ``report`` writes options-frozen.json (approaches, the mix rule, the levels). The test set's
paid calls and its scoring refuse to run without it, and the scoring runs once: ``final`` refuses when
options.json exists. Commit the frozen file BEFORE ``collect-test`` so the history shows the order.

TOKENS AND COST are per 1,000 pages, measured, never assumed:
- Gemini: the usage the API returned on every logged call (input, output, thinking billed as output),
  retries and parse failures included, over the boxes collected.
- Claude: the bench ran through ``claude -p`` (agentic, the images read with a tool, ~8 turns a window), which
  is the subscription route and says nothing about what one API request costs. So every cached window is
  rebuilt as ONE Messages API request (images inline, then the w1 prompt) and counted with Anthropic's free
  count_tokens endpoint; output = the cached answer's own token count (count_tokens of the answer minus that
  of an empty one). The CLI's notional list-price figure for the subscription route is reported beside it.
Dollars = tokens x list price; batch = the provider's batch price (50% for both).
"""
from __future__ import annotations

import base64
import concurrent.futures as cf
import datetime as dt
import json
import subprocess
import sys
import threading
import time

import data
from methods import METHODS  # noqa: F401  (imports the voter modules in order)
import compare_gemini as CG
import ensemble as E
import method_gemini as G
import method_window as W
from score import score_labels

# window-gemini at gemini-3.8-flash/low for the whole process (method_gemini's globals; W36.seg-second's
# Flash-Lite voter L is therefore NOT available in this process and is not used)
GEMINI = ("gemini-3.8-flash", "low", 0.75, 3.75)
CG.use(*GEMINI)

RESULTS = E.RESULTS
FROZEN = RESULTS / "options-frozen.json"
OUT_MD, OUT_JSON = RESULTS / "options.md", RESULTS / "options.json"
TOKENS_CLAUDE = data.CACHE_DIR / "tokens-claude.json"

# USD per million tokens, list (standard) and batch. Claude: platform.claude.com/docs/en/about-claude/pricing,
# read 2026-10-11. Gemini 3.8 Flash: the introductory price to 31 Dec 2026 (then $1.50 / $7.50), read
# 2026-10-05 (compare_gemini.py); the Gemini Batch API is half price.
PRICES = {
    "claude-sonnet-5-5": {"in": 2.00, "out": 10.00, "batch_in": 1.00, "batch_out": 5.00, "read": "2026-10-11",
                          "source": "https://platform.claude.com/docs/en/about-claude/pricing"},
    "gemini-3.8-flash": {"in": 0.75, "out": 3.75, "batch_in": 0.375, "batch_out": 1.875, "read": "2026-10-05",
                         "source": "Gemini API pricing page; introductory price to 2026-12-31, then $1.50 / $7.50",
                         "after_2026_12_31": {"in": 1.50, "out": 7.50, "batch_in": 0.75, "batch_out": 3.75}},
}

APPROACHES = {"claude": ("C",), "gemini": ("G",)}
VOTER_NAMES = {"C": "window-claude (Claude Sonnet 5.5, prompt w1)",
               "G": "window-gemini-3.8-flash-low (Gemini 3.8 Flash, thinking low, prompt g1)"}
MIX_CANDIDATES = [("C", "G")]
RULES = ("min", "mean")


# --- voters ---------------------------------------------------------------------------------------

_orig_voter_gaps = E.voter_gaps


def voter_gaps(code, col):
    if code == "G":
        return E._from_bounds(col, W.assemble(col, W.combine(col, G.judge_window), True))
    if code == "L":
        raise KeyError("L (Flash-Lite) is not loaded in options.py; see the module docstring")
    return _orig_voter_gaps(code, col)


E.voter_gaps = voter_gaps
_min_judge = E.judge


def mean_judge(box, S, v):
    out = {}
    for i in box.gaps:
        js = [box.v[c][i] for c in S]
        ps = [x if d == "new" else 1 - x for d, x in js]
        m = sum(ps) / len(ps)
        conf = max(m, 1 - m)
        agree = len({d for d, _ in js}) == 1
        out[i] = ("new" if m >= 0.5 else "continue", not conf > v, conf, agree)
    return out


class rule:
    """``with rule("mean"):`` swaps ensemble.judge, which evaluate/levels/fit_level/loco all call."""

    def __init__(self, name):
        self.fn = mean_judge if name == "mean" else _min_judge

    def __enter__(self):
        E.judge = self.fn

    def __exit__(self, *exc):
        E.judge = _min_judge


def figures(rows_or_pooled: dict) -> dict:
    p = rows_or_pooled
    return {"pages": p["pages"], "gaps": p["gaps"], "flagged": p["flagged"],
            "pages_exact_no_review": E.pe(p["auto"]), "flagged_per_100_pages": 100 * p["flagged"] / p["pages"],
            "pages_exact_after_review": E.pe(p["rev"]), "unflagged_errors": p["acc_err"],
            "unflagged_errors_per_500_pages": 500 * p["acc_err"] / p["pages"]}


# --- tokens ---------------------------------------------------------------------------------------

def _anthropic_key() -> str:
    r = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "com.archiveprocessor.app",
                        "-a", "Anthropic", "-w"], capture_output=True, text=True)
    k = r.stdout.strip()
    if r.returncode != 0 or not k:
        raise SystemExit("no Anthropic key in the Keychain (com.archiveprocessor.app / Anthropic)")
    return k


def _count(key: str, content) -> int:
    import requests
    for attempt in range(6):
        try:
            r = requests.post("https://api.anthropic.com/v1/messages/count_tokens", timeout=120,
                              headers={"x-api-key": key, "anthropic-version": "2023-06-01",
                                       "content-type": "application/json"},
                              json={"model": W.MODEL, "messages": [{"role": "user", "content": content}]})
        except requests.RequestException as e:
            print(f"  count_tokens: {type(e).__name__}, retrying", flush=True)
            time.sleep(5 * (attempt + 1))
            continue
        if r.status_code == 200:
            return int(r.json()["input_tokens"])
        if r.status_code in (429, 500, 502, 503, 529):
            time.sleep(5 * (attempt + 1))
            continue
        raise RuntimeError(f"count_tokens HTTP {r.status_code}: {r.text[:300]}")
    raise RuntimeError("count_tokens: gave up after retries")


def tokens_claude() -> dict:
    """Per cached window-claude window: input tokens of the API-form request, output tokens of its answer."""
    have = json.loads(TOKENS_CLAUDE.read_text()) if TOKENS_CLAUDE.exists() else {}
    key = _anthropic_key()
    base = _count(key, [{"type": "text", "text": "."}])
    jobs = []
    for n in data.DEV + data.TEST:
        col = data.load(n, with_exif=False)
        for a, b in W.windows(len(col.pages)):
            prompt, thumbs, nums = W.build_request(col, a, b)
            k = W.cache_key(prompt, thumbs)
            hit = W.CACHE.get(k)
            if hit is not None and k not in have:
                jobs.append((n, nums, prompt, thumbs, k, hit))
    print(f"{len(jobs)} windows to count ({len(have)} already counted)", flush=True)
    lock = threading.Lock()

    def work(job):
        n, nums, prompt, thumbs, k, hit = job
        content = []
        for num, t in zip(nums, thumbs):
            content += [{"type": "text", "text": f"Page {num}:"},
                        {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg",
                                                     "data": base64.b64encode(t.read_bytes()).decode()}}]
        content.append({"type": "text", "text": prompt})
        tin = _count(key, content)
        tout = max(1, _count(key, [{"type": "text", "text": hit["result"]}]) - base + 1)
        with lock:
            have[k] = {"collection": n, "window": nums, "in": tin, "out": tout,
                       "notional_usd": hit.get("notional_usd")}
            if len(have) % 20 == 0:
                TOKENS_CLAUDE.write_text(json.dumps(have))
                print(f"  {len(have)} counted", flush=True)

    with cf.ThreadPoolExecutor(4) as ex:
        list(ex.map(work, jobs))
    TOKENS_CLAUDE.write_text(json.dumps(have))
    return have


def _pages(names) -> dict[str, int]:
    return {n: len(data.load(n, with_exif=False).pages) for n in names}


def usage_claude(names) -> dict:
    have = json.loads(TOKENS_CLAUDE.read_text()) if TOKENS_CLAUDE.exists() else {}
    recs = [r for r in have.values() if r["collection"] in names]
    got = sorted({r["collection"] for r in recs})
    pages = sum(_pages(got).values())
    tin, tout = sum(r["in"] for r in recs), sum(r["out"] for r in recs)
    notional = sum(r.get("notional_usd") or 0 for r in recs)
    return {"model": "claude-sonnet-5-5", "boxes": got, "pages": pages, "calls": len(recs),
            "input_per_1000_pages": 1000 * tin / pages if pages else None,
            "output_per_1000_pages": 1000 * tout / pages if pages else None,
            "subscription_route_notional_usd_per_1000_pages": 1000 * notional / pages if pages else None,
            "how": "count_tokens on each window rebuilt as one Messages API request (images inline); "
                   "output = the cached answer's token count"}


def usage_gemini(names) -> dict:
    recs = [json.loads(l) for l in G.LOG.read_text().splitlines()] if G.LOG.exists() else []
    recs = [r for r in recs if r.get("event") in ("call", "parse-failure") and r.get("model") == G.MODEL
            and r.get("collection") in names]
    got = sorted({r["collection"] for r in recs})
    pages = sum(_pages(got).values())
    tin = sum(r["in"] for r in recs)
    tout = sum(r["out"] + r["thought"] for r in recs)
    return {"model": G.MODEL, "thinking": G.THINKING, "boxes": got, "pages": pages, "calls": len(recs),
            "input_per_1000_pages": 1000 * tin / pages if pages else None,
            "output_per_1000_pages": 1000 * tout / pages if pages else None,
            "spent_usd": sum(r["usd"] for r in recs),
            "how": "the usage the Gemini API returned on every logged call, retries and parse failures included; "
                   "thinking tokens counted as output"}


def cost(u: dict) -> dict:
    p = PRICES[u["model"]]
    if u["input_per_1000_pages"] is None:
        return {}
    f = lambda a, b: (u["input_per_1000_pages"] * p[a] + u["output_per_1000_pages"] * p[b]) / 1e6  # noqa: E731
    out = {"list_usd_per_1000_pages": f("in", "out"), "batch_usd_per_1000_pages": f("batch_in", "batch_out"),
           "prices_usd_per_mtok": {k: p[k] for k in ("in", "out", "batch_in", "batch_out")},
           "price_read": p["read"], "price_source": p["source"]}
    if "after_2026_12_31" in p:
        q = p["after_2026_12_31"]
        out["after_2026_12_31"] = {
            "list_usd_per_1000_pages": (u["input_per_1000_pages"] * q["in"] + u["output_per_1000_pages"] * q["out"]) / 1e6,
            "batch_usd_per_1000_pages": (u["input_per_1000_pages"] * q["batch_in"]
                                         + u["output_per_1000_pages"] * q["batch_out"]) / 1e6}
    return out


def usage(code, names) -> dict:
    return usage_claude(names) if code == "C" else usage_gemini(names)


# --- development: levels, the mix rule, the freeze ------------------------------------------------

def load_dev():
    return {n: E.Box(data.load(n), "CG") for n in data.DEV}


def report() -> str:
    if OUT_JSON.exists():
        raise SystemExit(f"{OUT_JSON.name} exists: the test set has been scored; the freeze is final")
    dev = load_dev()
    pages = sum(b.pages for b in dev.values())
    gaps = sum(len(b.gaps) for b in dev.values())
    res = {}
    for a, S in APPROACHES.items():
        res[a] = {"S": S, "rule": "min", **E.loco(dev, S)}
    mix = {}
    for S in MIX_CANDIDATES:
        for r in RULES:
            with rule(r):
                mix[(S, r)] = {"S": S, "rule": r, **E.loco(dev, S)}
    order = sorted(mix, key=lambda k: (-mix[k]["reached"], mix[k]["pooled"]["flagged"] / mix[k]["pooled"]["pages"],
                                       mix[k]["pooled"]["acc_err"], -E.pe(mix[k]["pooled"]["rev"])))
    best = order[0]
    res["mix"] = mix[best]
    # levels for the test set: fitted on all three development collections
    frozen = {"decided": dt.date.today().isoformat(), "bar": E.BAR, "on": list(data.DEV),
              "gemini": {"model": GEMINI[0], "thinking": GEMINI[1]}, "approaches": {}}
    for a, r in res.items():
        with rule(r["rule"]):
            v = E.fit_level(list(dev.values()), r["S"])
        frozen["approaches"][a] = {"voters": list(r["S"]), "rule": r["rule"], "level": v}

    L = ["# W36.seg-opt-measure — the approaches on the development set", "",
         f"Run {dt.date.today().isoformat()} on Dean, Deaver and Herrnstein ({pages} pages, {gaps} gaps between two "
         "document pages); the test collections are not touched by anything on this page. Truth photo labels. "
         "Every figure is held out per box: each box's row uses the level fitted on the other two. Method: "
         "`scripts/segbench/options.py` (module docstring).", "",
         "Voters: " + "; ".join(f"{c} = {VOTER_NAMES[c]}" for c in "CG") + ".", "",
         "## Each approach, held out per box", "",
         "| approach | rule | boxes at 98% after review | pages in exact doc, no review | flagged per 100 pages | "
         "after review | worst box after review | unflagged errors (per 500 pages) | levels (Dean / Deaver / "
         "Herrnstein) |", "|---|---|---:|---:|---:|---:|---:|---:|---|"]
    for a, r in res.items():
        p = r["pooled"]
        L.append(f"| {a} ({''.join(r['S'])}) | {r['rule']} | {r['reached']} of 3 | {E.pct(E.pe(p['auto']))} | "
                 f"{100 * p['flagged'] / p['pages']:.1f} | {E.pct(E.pe(p['rev']))} | "
                 f"{E.pct(min(E.pe(x['rev']) for x in r['rows']))} | {p['acc_err']} "
                 f"({500 * p['acc_err'] / p['pages']:.1f}) | " + " / ".join(E.lv(r["levels"][n]) for n in data.DEV)
                 + " |")
    L += ["", "## The mix: combining rules compared", "",
          "Ranked by boxes reaching 98% after review, then flagged per 100 pages, then unflagged errors. The first "
          "is the mix offered.", "",
          "| voters | rule | boxes at 98% | flagged per 100 pages | unflagged errors | no review | after review |",
          "|---|---|---:|---:|---:|---:|---:|"]
    for k in order:
        r = mix[k]
        p = r["pooled"]
        L.append(f"| {''.join(r['S'])} | {r['rule']} | {r['reached']} of 3 | {100 * p['flagged'] / p['pages']:.1f} | "
                 f"{p['acc_err']} | {E.pct(E.pe(p['auto']))} | {E.pct(E.pe(p['rev']))} |")
    L += ["", "## By box (held out)", "",
          "| approach | box | level (fitted on the other two) | flagged | per 100 pages | unflagged errors | "
          "no review | after review |", "|---|---|---|---:|---:|---:|---:|---:|"]
    for a, r in res.items():
        for x in r["rows"]:
            L.append(f"| {a} | {x['name']} | {E.lv(r['levels'][x['name']])} | {x['flagged']} | "
                     f"{100 * x['flagged'] / x['pages']:.1f} | {x['acc_err']} | {E.pct(E.pe(x['auto']))} | "
                     f"{E.pct(E.pe(x['rev']))} |")
    L += ["", "## Frozen for the test set (levels fitted on all three development boxes)", "",
          "| approach | voters | rule | level |", "|---|---|---|---|"]
    for a, f in frozen["approaches"].items():
        L.append(f"| {a} | {''.join(f['voters'])} | {f['rule']} | {E.lv(f['level'])} |")
    L.append("")
    text = "\n".join(L) + "\n"
    (RESULTS / "options-dev.md").write_text(text)
    frozen["dev_held_out"] = {a: figures(r["pooled"]) for a, r in res.items()}
    FROZEN.write_text(json.dumps(frozen, indent=1) + "\n")
    return text


# --- the test set ---------------------------------------------------------------------------------

def frozen() -> dict:
    if not FROZEN.exists():
        raise SystemExit("no freeze yet: run `options.py report` on the development set first")
    return json.loads(FROZEN.read_text())


def test_jobs():
    codes = sorted({c for f in frozen()["approaches"].values() for c in f["voters"]})
    judges = {"C": W.judge_window, "G": G.judge_window}
    jobs = []
    for n in data.TEST:
        col = data.load(n, with_exif=False)
        for c in codes:
            jobs += [(c, col, a, b, judges[c]) for a, b in W.windows(len(col.pages))]
    return jobs


def estimate_test() -> float:
    jobs = test_jobs()
    todo = [j for j in jobs if j[4](j[1], j[2], j[3], allow_call=False) is None]
    usd = 0.0
    for c in sorted({j[0] for j in jobs}):
        k = sum(1 for j in todo if j[0] == c)
        if c == "C":
            print(f"  C window-claude: {k} `claude -p` calls not cached (subscription, no API spend)")
        else:
            u = usage_gemini(data.DEV)
            per_call = u["spent_usd"] / u["calls"]
            usd += k * per_call
            print(f"  G {G.MODEL}/{G.THINKING}: {k} calls not cached; ${per_call:.4f} a call on the development "
                  f"boxes -> about ${k * per_call:.2f} (x1.2 for retries: ${1.2 * k * per_call:.2f})")
    return usd


def collect_test() -> None:
    if OUT_JSON.exists():
        raise SystemExit(f"{OUT_JSON.name} exists: the test set has been scored; nothing to collect")
    est = estimate_test()
    if 1.2 * est > G.COST_CAP_USD:
        raise SystemExit(f"estimate ${1.2 * est:.2f} exceeds the ${G.COST_CAP_USD:.0f} cap; not running")
    todo = [j for j in test_jobs() if j[4](j[1], j[2], j[3], allow_call=False) is None]
    if any(j[0] == "C" for j in todo):
        raise SystemExit("window-claude test windows are missing; collect them with ensemble.py first")
    stop, lock, done, t0 = threading.Event(), threading.Lock(), [0], time.time()

    def work(job, delay):
        time.sleep(delay)
        c, col, a, b, fn = job
        if stop.is_set():
            return
        try:
            fn(col, a, b)
        except G.Fatal as e:
            stop.set()
            print(f"STOPPING: {str(e)[:300]}", flush=True)
            return
        except Exception as e:  # noqa: BLE001 - one window failing does not stop the rest
            print(f"FAILED {c} {col.name} {col.pages[a].n}-{col.pages[b - 1].n}: {str(e)[:200]}", flush=True)
            return
        with lock:
            done[0] += 1
            print(f"[{done[0]}/{len(todo)} {time.time() - t0:.0f}s] {c} {col.name} "
                  f"{col.pages[a].n}-{col.pages[b - 1].n}", flush=True)

    with cf.ThreadPoolExecutor(G.CONCURRENCY) as ex:
        futs = [ex.submit(work, j, G.STAGGER_S * k if k < G.CONCURRENCY else 0) for k, j in enumerate(todo)]
        for f in cf.as_completed(futs):
            f.result()
    print(f"done in {time.time() - t0:.0f}s; {G.MODEL} spend so far ${G.spent():.2f}", flush=True)


def _money(x) -> str:
    return "—" if x is None else (f"${x:.2f}" if x >= 0.995 else f"${x:.3f}")


def _k(x) -> str:
    return "—" if x is None else f"{x / 1000:,.0f}k"


def final() -> str:
    if OUT_JSON.exists():
        raise SystemExit(f"{OUT_JSON.name} exists: the test set is scored once; see {OUT_MD.name}")
    fz = frozen()
    test = {n: E.Box(data.load(n), "CG") for n in data.TEST}
    tpages = sum(b.pages for b in test.values())
    tgaps = sum(len(b.gaps) for b in test.values())
    all_boxes = data.DEV + data.TEST
    use = {c: usage(c, all_boxes) for c in "CG"}
    out = {"version": 1, "measured": dt.date.today().isoformat(), "item": "W36.seg-opt-measure",
           "method": "ArchiveProcessor/scripts/segbench/options.py",
           "bar_after_review": fz["bar"],
           "window": {"pages": 7, "stride": 3, "each_gap_judged": 2, "thumbnail_long_edge_px": W.THUMB_PX,
                      "ocr_text_chars_per_page": W.MAX_TEXT},
           "figures_note": "test = Stanton + RG 165, scored once with the level frozen on the development boxes "
                           "(Dean, Deaver, Herrnstein); dev_held_out = each development box at the level fitted on "
                           "the other two. Fractions, not percentages. Truth photo labels: only the gaps between "
                           "two document pages are counted as boundaries the user may be asked about.",
           "approaches": []}
    # manual
    pooled_dev_pages = sum(_pages(data.DEV).values())
    dev_gaps = fz["dev_held_out"]["claude"]["gaps"]
    out["approaches"].append({
        "id": "manual", "label": "Full manual", "available": True, "voters": [], "rule": None, "level": None,
        "figures": {"test": {"pages": tpages, "gaps": tgaps, "flagged": tgaps, "pages_exact_no_review": None,
                             "flagged_per_100_pages": 100 * tgaps / tpages, "pages_exact_after_review": 1.0,
                             "unflagged_errors": 0, "unflagged_errors_per_500_pages": 0.0},
                    "dev_held_out": {"pages": pooled_dev_pages, "gaps": dev_gaps, "flagged": dev_gaps,
                                     "pages_exact_no_review": None,
                                     "flagged_per_100_pages": 100 * dev_gaps / pooled_dev_pages,
                                     "pages_exact_after_review": 1.0, "unflagged_errors": 0,
                                     "unflagged_errors_per_500_pages": 0.0}},
        "tokens_per_1000_pages": None, "cost": None,
        "note": "Nothing is proposed: the user judges every gap between two document pages. 'After review' "
                "assumes the user's own judgement is right."})
    labels = {"claude": "Claude only", "gemini": "Gemini only", "mix": "Claude and Gemini together"}
    rows = {}
    for a, f in fz["approaches"].items():
        S, v = tuple(f["voters"]), f["level"]
        with rule(f["rule"]):
            per = [E.evaluate(test[n], S, 2.0 if v is None else v) | {"name": n} for n in data.TEST]
        p = E.pooled(per)
        rows[a] = (per, p)
        tok = {c: use[c] for c in S}
        cs = {c: cost(use[c]) for c in S}
        total = {"list_usd_per_1000_pages": sum(x["list_usd_per_1000_pages"] for x in cs.values()),
                 "batch_usd_per_1000_pages": sum(x["batch_usd_per_1000_pages"] for x in cs.values())}
        out["approaches"].append({
            "id": a, "label": labels[a], "available": True, "voters": [VOTER_NAMES[c] for c in S],
            "rule": f["rule"], "level": v,
            "flag_rule": ("flag a gap whose confidence is at or below the level" if len(S) == 1 else
                          {"min": "flag a gap unless every model agrees and the lowest confidence is above the level",
                           "mean": "average the models' P(new); flag a gap whose combined confidence is at or "
                                   "below the level"}[f["rule"]]),
            "figures": {"test": figures(p), "test_by_box": {r["name"]: figures(r) for r in per},
                        "dev_held_out": fz["dev_held_out"][a]},
            "tokens_per_1000_pages": tok,
            "cost": {"per_model": cs, "total": total}})
    out["approaches"].append({
        "id": "openai", "label": "ChatGPT only", "available": False,
        "reason": "Not measured: no OpenAI API key in the Keychain, and the Codex route answered 'Your workspace "
                  "is out of credits' on 2026-10-11. Earlier, on one development box only (Deaver), Codex "
                  "gpt-6.1-sol at reasoning low with the cues prompt put 97.9% of pages in an exact document "
                  "with no review, level with Claude and Gemini on that box (cues-models-Deaver.md).",
        "figures": None, "tokens_per_1000_pages": None, "cost": None})
    OUT_JSON.write_text(json.dumps(out, indent=1) + "\n")

    # markdown
    def fig_row(a, f, c):
        t = f["test"]
        nr = "—" if t["pages_exact_no_review"] is None else E.pct(t["pages_exact_no_review"])
        lc = "none" if c is None else f"{_money(c['total']['list_usd_per_1000_pages'])} / " \
                                      f"{_money(c['total']['batch_usd_per_1000_pages'])}"
        return (f"| {a} | {nr} | {t['flagged_per_100_pages']:.1f} | {E.pct(t['pages_exact_after_review'])} | "
                f"{t['unflagged_errors_per_500_pages']:.1f} ({t['unflagged_errors']}) | {lc} |")

    L = ["# Segmentation approaches — the figures the Processor will show", "",
         f"W36.seg-opt-measure, run {out['measured']}. Data for the app: `options.json` beside this file. Method: "
         "`scripts/segbench/options.py`; the development-set detail is `options-dev.md`.", "",
         f"**Measured on the locked boxes, Stanton and RG 165 ({tpages} pages, {tgaps} gaps between two document "
         "pages), scored once**, with each approach's flag level and the mix rule frozen on the development boxes "
         "(Dean, Deaver, Herrnstein) before those boxes' new calls were made (`options-frozen.json`, committed "
         "first). Truth photo labels. Claude's test-box answers were collected for W36.seg-ensemble and its level "
         "(0.85) is the same one; Gemini 3.8 Flash's test-box windows are new.", "",
         "## The five figures, per approach (test boxes)", "",
         "| approach | pages in an exact document, no checking | boundaries to check per 100 pages | pages right "
         "after checking | unflagged errors per 500 pages (count) | API cost per 1,000 pages, list / batch |",
         "|---|---:|---:|---:|---:|---:|"]
    for ap in out["approaches"]:
        if ap["available"]:
            L.append(fig_row(ap["label"], ap["figures"], ap["cost"]))
        else:
            L.append(f"| {ap['label']} | not measured | | | | |")
    L += ["", "## Held out on the development boxes (each box at the level fitted on the other two)", "",
          "| approach | rule, level for the test | no checking | to check per 100 pages | after checking | "
          "unflagged per 500 pages |", "|---|---|---:|---:|---:|---:|"]
    for ap in out["approaches"]:
        if ap["available"] and ap["id"] != "manual":
            d = ap["figures"]["dev_held_out"]
            L.append(f"| {ap['label']} | {ap['rule']}, {E.lv(ap['level'])} | {E.pct(d['pages_exact_no_review'])} | "
                     f"{d['flagged_per_100_pages']:.1f} | {E.pct(d['pages_exact_after_review'])} | "
                     f"{d['unflagged_errors_per_500_pages']:.1f} |")
    L += ["", "## By test box", "", "| approach | box | pages | no checking | flagged | per 100 pages | "
          "after checking | unflagged errors |", "|---|---|---:|---:|---:|---:|---:|---:|"]
    for a, (per, _) in rows.items():
        for r in per:
            L.append(f"| {labels[a]} | {r['name']} | {r['pages']} | {E.pct(E.pe(r['auto']))} | {r['flagged']} | "
                     f"{100 * r['flagged'] / r['pages']:.1f} | {E.pct(E.pe(r['rev']))} | {r['acc_err']} |")
    L += ["", "## Tokens and cost per 1,000 pages", "",
          "Measured over every box collected (all five), not tuned on anything. Gemini: the API's own usage "
          "figures. Claude: each window rebuilt as one Messages API request and counted with count_tokens (free); "
          "the bench itself ran through `claude -p`, whose notional list-price figure is shown for the "
          "subscription route.", "",
          "| model | boxes | calls | input tokens | output tokens | list $ | batch $ | prices $/M in, out (read) |",
          "|---|---|---:|---:|---:|---:|---:|---|"]
    for c in "CG":
        u, k = use[c], cost(use[c])
        L.append(f"| {u['model']}{'/' + u['thinking'] if 'thinking' in u else ''} | {', '.join(u['boxes'])} | "
                 f"{u['calls']} | {_k(u['input_per_1000_pages'])} | {_k(u['output_per_1000_pages'])} | "
                 f"{_money(k.get('list_usd_per_1000_pages'))} | {_money(k.get('batch_usd_per_1000_pages'))} | "
                 f"{k['prices_usd_per_mtok']['in']}, {k['prices_usd_per_mtok']['out']} ({k['price_read']}) |")
    g = cost(use["G"]).get("after_2026_12_31")
    if g:
        L.append("")
        L.append(f"Gemini 3.8 Flash is at its introductory price to 31 Dec 2026; at the later $1.50 / $7.50 the "
                 f"Gemini figure becomes {_money(g['list_usd_per_1000_pages'])} list, "
                 f"{_money(g['batch_usd_per_1000_pages'])} batch.")
    n = use["C"].get("subscription_route_notional_usd_per_1000_pages")
    if n:
        L.append("")
        L.append(f"Claude through `claude -p` (the subscription route, about 8 agent turns a window as the images "
                 f"are read with a tool): the CLI's notional list price is {_money(n)} per 1,000 pages. A "
                 "subscription is not charged that; it is the size of the usage the route draws, which "
                 "W36.seg-opt-usage turns into a share of a plan's windows.")
    L += ["", "## Not measured: ChatGPT", "", next(a for a in out["approaches"] if a["id"] == "openai")["reason"],
          "", "## Reading", "",
          "Manual is the floor every other approach is measured against: no cost, every gap a decision for the user. "
          "The model approaches are first drafts; 'unflagged errors' are the mistakes the user is never shown, and "
          "no approach here reaches zero.", ""]
    text = "\n".join(L) + "\n"
    OUT_MD.write_text(text)
    return text


def main(argv) -> int:
    cmds = ("tokens-claude", "report", "estimate-test", "collect-test", "final")
    if not argv or argv[0] not in cmds:
        print(__doc__)
        return 2
    cmd = argv[0]
    if cmd in ("collect-test", "final"):
        E.need_final(argv)
    if cmd == "tokens-claude":
        tokens_claude()
        for names in (data.DEV, data.DEV + data.TEST):
            print(json.dumps(usage_claude(names), indent=1))
    elif cmd == "report":
        print(report())
    elif cmd == "estimate-test":
        estimate_test()
    elif cmd == "collect-test":
        collect_test()
    else:
        print(final())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
