#!/usr/bin/env python3
"""W46.seg-tabme-paid: Gemini's K = 7 windows on a TABME++ subset, with images and on the text alone, through the gateway.

  python3 seg_tabme_gateway.py plan  --root DIR              # the subset, request counts, an allowance (no calls)
  python3 seg_tabme_gateway.py collect --root DIR [--limit N] [--arm ARM]   # paid calls, cached, one item ledger
  python3 seg_tabme_gateway.py score --root DIR --pack DIR --results DIR    # no calls -> segbench-results/seg-tabme-gateway.*

The paid half of W46.seg-tabme (`seg-tabme.md`), whose open arms found the 27B teacher 3.0-5.2 boundary-F1 points
better on TABME++ without its images, against the owner's boxes, where images help. This asks the same of the cloud
route: does image input help Gemini on clean scans with commercial OCR, where A04 says it does not?

FIXED BEFORE ANY ANSWER:
- Pages: the TABME++ test stream `seg_tabme.py stage` builds (6,237 pages, the dataset's own JPEGs and Microsoft OCR),
  cut to its first whole documents reaching SUBSET_PAGES pages. The shards' document order is the dataset's, so the
  cut is chosen by nothing any route answered; how far it looks like the whole stream is reported.
- Route: Gemini 3.7 Flash through the Stanford gateway, the request seg_window_gateway sends (g1 with its schema,
  temperature 0, reasoning low, JSON mode, 4,096 output tokens), arms k7-it (images and text) and k7-t (text only,
  seg_window_gateway's rewrite), method_window.windows over the subset. The item was filed for Gemini 3.8 Flash on
  the image arm and 3.1 Flash-Lite on the full stream's text windows (A04's costed setting); the gateway serves
  neither (its /v1/models, 2026-11-05), and a direct key is the owner's call, so the A04 cell is asked in the Daemon
  Report rather than run on a stand-in here.
- Scoring: seg_tabme's: method_window.combine, the truth's (none) photo labels, boundary F1, pages exact, doc F1, a
  2,000-draw bootstrap over truth documents (seed 46), paired between arms. The students' and teacher's figures on the
  same documents come from W46.seg-tabme's Sherlock answers over the whole stream (its windows, so a subset document
  is judged with the same neighbours; the last document's exactness is the whole-stream one); no calls.
- Money: ITEM_CAP_USD below, under the $7 rule; seg_window_gateway's ledger rules (reserve before send, settle at the
  larger of the token estimate and the gateway's figure, refuse past the cap, one re-send of a failure).
Only public pages go to the gateway; replies stay in STORE.
"""
from __future__ import annotations

import argparse
from collections import Counter
import concurrent.futures as cf
import fcntl
import json
from pathlib import Path
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import seg_tabme as ST  # noqa: E402

TAG = "W46.seg-tabme-paid"
STORE = Path.home() / "Library/Caches/ArchiveSuiteRehearsal/seg-tabme-gateway"
RESULTS = HERE.parents[1] / "segbench-results"
ITEM_CAP_USD = 4.00
SUBSET_PAGES = 500
ARMS = ("k7-it", "k7-t")
CONCURRENCY = 6


def _gw():
    """seg_window_gateway's request, ledger and call, pointed at this item's store and cap."""
    import seg_window_gateway as SWG
    SWG.STORE, SWG.ITEM_CAP_USD, SWG.TAG = STORE, ITEM_CAP_USD, TAG
    return SWG


def cut(labels, at_least=SUBSET_PAGES):
    """Pages in the first whole documents whose total reaches ``at_least``."""
    n = 0
    for i, t in enumerate(labels):
        if t == "New" and i >= at_least:
            return i
        n = i + 1
    return n


def subset(root):
    data, *_ = ST._seg()
    col, stream = ST.load(root)
    n = cut([p.label for p in col.pages])
    return col, data.Collection(col.name, col.directory, col.pages[:n]), stream


def jobs(sub, arms=None):
    _, _, _, W, _ = ST._seg()
    return [(arm, sub, a, b) for arm in ARMS if not arms or arm in arms for a, b in W.windows(len(sub.pages))]


def describe(labels):
    starts = [i for i, t in enumerate(labels) if t == "New"]
    lens = [e - s for s, e in zip(starts, starts[1:] + [len(labels)])]
    return {"pages": len(labels), "documents": len(lens), "single_page_share": sum(x == 1 for x in lens) / len(lens),
            "mean_pages": len(labels) / len(lens), "longest": max(lens)}


def cmd_plan(a):
    SWG = _gw()
    full, sub, _ = subset(a.root)
    js = jobs(sub)
    per, total, todo = Counter(), 0.0, 0
    for arm, col, lo, hi in js:
        body, key, _ = SWG.request(col, lo, hi, arm)
        per[arm] += 1
        total += SWG.allowance(body)
        todo += not ((h := SWG.reply(key)) and h["valid"])
    print(json.dumps({"subset": describe([p.label for p in sub.pages]),
                      "stream": describe([p.label for p in full.pages])}, indent=1))
    for arm in ARMS:
        print(f"{arm:6} {per[arm]:4} windows")
    print(f"{todo} uncached; allowance ${total:.2f} at full output caps; spent ${SWG.spent():.4f} of ${ITEM_CAP_USD:.2f}")


def cmd_collect(a):
    SWG = _gw()
    _, sub, _ = subset(a.root)
    STORE.mkdir(parents=True, exist_ok=True)
    with (STORE / "collect.lock").open("a") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        todo = jobs(sub, [a.arm] if a.arm else None)
        for rnd in (1, 2):            # the second round re-sends each failure once
            pending = [j for j in todo if not ((h := SWG.reply(SWG.request(j[1], j[2], j[3], j[0])[1])) and h["valid"])]
            if a.limit:
                pending = pending[:a.limit]
            print(f"round {rnd}: {len(pending)} windows to send, item ${SWG.spent():.4f}", flush=True)
            res = Counter()
            with cf.ThreadPoolExecutor(CONCURRENCY) as ex:
                for out in ex.map(lambda j: SWG.call(*j), pending):
                    res[out] += 1
            print(f"round {rnd}: {dict(res)}, item ${SWG.spent():.4f}", flush=True)
            if res["skipped"]:
                print("cap reached: the rest are left unsent", flush=True)
                break
            if a.limit:               # a pilot sends one round only
                break


# --- scoring --------------------------------------------------------------------------------------

def ledger_summary(SWG):
    last = SWG.latest().values()
    settled = [r for r in last if r["event"] == "settle"]
    gw = [r["gateway_cost"] for r in settled if isinstance(r.get("gateway_cost"), (int, float))]
    return {"calls": len(last), "settled": len(settled), "valid": sum(r.get("valid") is True for r in settled),
            "charged_usd": round(SWG.spent(), 4), "estimate_usd": round(sum(r.get("estimate") or 0 for r in settled), 4),
            "gateway_usd": round(sum(gw), 4), "gateway_lines": len(gw), "cap_usd": ITEM_CAP_USD,
            "prompt_tokens": sum((r.get("usage") or {}).get("prompt_tokens", 0) for r in settled),
            "completion_tokens": sum((r.get("usage") or {}).get("completion_tokens", 0) for r in settled)}


def cmd_score(a):
    import rescore
    rescore.no_network()
    SWG = _gw()
    _, _, _, W, SWM = ST._seg()
    full, sub, stream = subset(a.root)
    freeze = ST.check(a.pack)
    if ST.summary(stream)["stream_sha256"] != freeze["stream"]["stream_sha256"]:
        raise SystemExit("the staged stream is not the one W46.seg-tabme's pack froze")
    truth, ftruth = [p.label for p in sub.pages], [p.label for p in full.pages]
    docs = sum(t == "New" for t in truth)
    arms, rows, failed = {}, [], Counter()
    for arm in ARMS:
        spans = W.windows(len(truth))
        comb = SWM.combine_units(sub, spans, SWG.judge_for(arm, failed))   # RuntimeError: a window never sent
        pred = W.assemble(sub, comb, True).labels
        name = f"gemini-{arm}"
        arms[name] = ST.per_doc(truth, pred)
        rows.append({"arm": name, "route": "Gemini 3.7 Flash (gateway)", "modality": arm.split("-")[1],
                     "failed_windows": failed[(arm, sub.name)], "photo_calls": sum(x is not None for x in comb["photo"]),
                     **ST.metrics(arms[name])})
    for name, p in freeze["packs"].items():     # W46.seg-tabme's whole-stream answers, cut to the same documents
        got, nf = ST.answers(a.pack, a.results, name)
        comb = SWM.combine_units(full, W.windows(len(ftruth)), ST.judge_from(got))
        arms[name] = ST.per_doc(ftruth, W.assemble(full, comb, True).labels)[:docs]
        rows.append({"arm": name, "route": f"{p['role']} (Sherlock, W46.seg-tabme)", "modality": p["modality"],
                     "failed_windows": nf, **ST.metrics(arms[name])})
    if sum(r["pages"] for r in arms["2b-it"]) != len(truth):
        raise SystemExit("the cut documents do not line up with the whole stream's")
    for name, labels in {"all-new": ["New"] * len(truth),
                         "no-boundaries": ["New"] + ["Cont"] * (len(truth) - 1)}.items():
        rows.append({"arm": name, "route": "baseline", **ST.metrics(ST.per_doc(truth, labels))})
    intervals, paired = ST.bootstrap(arms)
    out = {"tag": TAG, "subset": describe(truth), "stream": describe(ftruth), "stream_sha256": freeze["stream"]["stream_sha256"],
           "windows": len(W.windows(len(truth))), "rows": rows, "intervals": intervals, "paired": paired,
           "ledger": ledger_summary(SWG), "bootstrap": {"draws": ST.DRAWS, "seed": ST.SEED, "unit": "truth document"},
           "scored": time.strftime("%Y-%m-%dT%H:%M:%S")}
    dest = Path(a.out) if a.out else RESULTS / "seg-tabme-gateway.json"
    dest.write_text(json.dumps(out, indent=1) + "\n")
    for r in rows:
        print(f"{r['arm']:14} boundary F1 {r['boundary_f1']:.3f}  pages exact {r['pages_exact']:.3f}  "
              f"doc F1 {r['doc_f1']:.3f}  splits {r['false_splits']} merges {r['false_merges']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("plan", "collect", "score"):
        p = sub.add_parser(name)
        p.add_argument("--root", required=True)
        if name == "collect":
            p.add_argument("--limit", type=int)
            p.add_argument("--arm", choices=ARMS)
        if name == "score":
            p.add_argument("--pack", required=True)
            p.add_argument("--results", required=True)
            p.add_argument("--out")
    a = ap.parse_args()
    {"plan": cmd_plan, "collect": cmd_collect, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    main()
