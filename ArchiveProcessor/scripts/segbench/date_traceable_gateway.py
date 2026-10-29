#!/usr/bin/env python3
"""W46.date-traceable-paid: Gemini 3.7 Flash through the Stanford AI API gateway on W46.date-traceable's trace prompts.

The same three trace prompts the 27B answered (plain; neigh, with the neighbours' rule dates; shots, with five labelled
same-collection examples), text only, sent for the owner's documents that need them: every document the rule stage
leaves undated (the pipeline's residue at any threshold, t=0 to t=3) and every one whose year is not in the corpus
text (the 131 that the one-shot figures are read on). 161 documents by three variants. The stated-confidence rerun
(B test 5) is dropped: the trace prompt already asks for a 90% interval, which the conformal check reads.

    python3 date_traceable_gateway.py run [--limit N] [--variant V]   # cached by destination, CAP bounds the spend
    python3 date_traceable_gateway.py score                           # segbench-results/date-traceable-paid.md/.json

The gateway is real money on a Stanford PTA (root CLAUDE.md). Spend is counted from the gateway's token usage at
Gemini 3.8 Flash's list price taken as a ceiling (gateway_gemini.PRICE; the gateway returns no cost) into the ledger
CACHE/calls.jsonl, written before a reply is used. The key is read by gateway_gemini.api_key, never printed or written.
Replies stay in the private bench cache (the prompts carry the owner's text). Gemini 3.7, not 3.8: the gateway serves
no 3.8; how far 3.7 sits from 3.8 on OCR is gateway_gemini's report. Run from scripts/segbench.
"""
import argparse
import collections
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.getcwd())
import date_tagging as DT
import date_traceable as T
import gateway_gemini as G

CACHE = os.path.join(T.CACHE, "gateway")
LABEL = "gemini3.7-flash-gw"
VARIANTS = ("plain", "neigh", "shots")
CAP = 2.50            # the item's total; estimate about $1.60-2.00, under the $7 rule
MAX_TOKENS = 4096     # 3.7 reasons first; 400 was enough for a short answer at the gate check
WORST = (12000 * G.PRICE[0] + MAX_TOKENS * G.PRICE[1]) / 1e6
RESULTS = T.RESULTS[:-3] + "-paid.md"
RESULTS_JSON = RESULTS[:-3] + ".json"


def ledger():
    p = os.path.join(CACHE, "calls.jsonl")
    return [json.loads(x) for x in open(p)] if os.path.exists(p) else []


def spent():
    return sum(r.get("cost", 0) for r in ledger())


def targets(owner):
    """The documents a trace reply is needed for: no rule pick (every threshold's residue) or year not in text."""
    return [d for d in owner
            if T.rule_pick(T.candidates(d["text"]))[0] is None or (d["cls"] != "in text" and "year" in d["truth"])]


def dest(variant, doc_id):
    return os.path.join(CACHE, variant, doc_id.replace(":", "_") + ".json")


def call(key, prompt, path):
    if os.path.exists(path):
        return json.load(open(path))
    if spent() + WORST > CAP:
        raise SystemExit(f"cap: ${spent():.4f} spent of ${CAP}")
    b = {"model": G.MODEL, "temperature": 0, "max_tokens": MAX_TOKENS, "reasoning_effort": "low",
         "messages": [{"role": "user", "content": prompt}]}
    t = time.time()
    for attempt in range(3):
        r = G.request("/chat/completions", b)
        if r.status_code in (429, 500, 502, 503, 504) and attempt < 2:
            time.sleep(10 * (attempt + 1)); continue
        break
    got = r.json() if r.headers.get("content-type", "").startswith("application/json") else {"raw": r.text[:2000]}
    usage = got.get("usage") or {}
    rec = {"id": key, "http": r.status_code, "t": t, "wall_s": round(time.time() - t, 3), "model": got.get("model"),
           "usage": usage, "cost": round(G.cost(usage), 6)}
    os.makedirs(CACHE, exist_ok=True)
    with open(os.path.join(CACHE, "calls.jsonl"), "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    choice = (got.get("choices") or [{}])[0]
    out = {"id": key, "raw": (choice.get("message") or {}).get("content") if r.status_code == 200 else None,
           "usage": usage, "wall_s": rec["wall_s"], "finish": choice.get("finish_reason")}
    if r.status_code == 200 and out["raw"]:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        json.dump(out, open(path, "w"), ensure_ascii=False, indent=1)
    else:
        print(key, r.status_code, out.get("finish"), json.dumps(got)[:300])
    return out


def cmd_run(a):
    owner, _, pool = T.all_docs()
    docs = targets(owner)[: a.limit or None]
    jobs = [(f"trace-{v}|{d['id']}", T.trace_prompt(d, v, T.shots_for(d, pool) if v == "shots" else ()), dest(v, d["id"]))
            for v in ((a.variant,) if a.variant else VARIANTS) for d in docs]
    with ThreadPoolExecutor(4) as ex:
        res = list(ex.map(lambda j: call(*j), jobs))
    bad = [r["id"] for r in res if not T.parse_trace(r.get("raw"))["parsed"]]
    print(f"{len(res) - len(bad)}/{len(res)} parsed, ${spent():.4f} spent in all; unparsed: {bad[:20]}")


def answers():
    out = {}
    for v in VARIANTS:
        d = os.path.join(CACHE, v)
        if os.path.isdir(d):
            for f in os.listdir(d):
                r = json.load(open(os.path.join(d, f)))
                out[r["id"]] = r
    return out


STRATA = ("not in text", "A", "A'", "B", "C", "D", "C+D", "decade")


def cmd_score(a):
    owner, _, _ = T.all_docs(with_shots=False)
    tg = targets(owner)
    nit = [d for d in owner if d["cls"] != "in text" and "year" in d["truth"]]
    gw, q = answers(), T.load_answers(T.LABEL_27B)
    led = ledger()
    calls_n = len([r for r in led if r["http"] == 200])
    usage = collections.Counter()
    for r in led:
        for k in ("prompt_tokens", "completion_tokens"):
            usage[k] += (r.get("usage") or {}).get(k) or 0
    out = {"label": LABEL, "model": G.MODEL, "documents": len(tg), "answers": len(gw), "spent_estimate": round(spent(), 4),
           "price_assumed": G.PRICE, "calls": calls_n, "usage": dict(usage),
           "usd_per_reply": round(spent() / max(1, calls_n), 5), "one_shot": {}, "pipeline": {}}
    g38 = [T.row(d, "one-shot", *got) for d in nit for got in [T.one_shot(d, None)] if got is not None]
    out["one_shot"]["Gemini 3.8 Flash, app prompt (W41, OpenRouter)"] = T.summary(g38, "owner")
    for lab, ans in (("Gemini 3.7 Flash (gateway)", gw), ("Qwen3.6 27B", q)):
        for v in VARIANTS:
            rs = T.trace_rows(nit, ans, v)
            if len(rs) == len(nit):
                s = T.summary(rs, "owner")
                s["bad_interval"] = sum(r["bad_interval"] for r in rs)
                s["short_evidence"] = sum(r["short_evidence"] for r in rs)
                out["one_shot"][f"{lab}, trace-{v}"] = s
    for lab, ans in (("Gemini 3.7 trace", gw), ("27B trace", q)):
        for v in VARIANTS:
            res = {d["id"]: ans[f"trace-{v}|{d['id']}"] for d in tg if f"trace-{v}|{d['id']}" in ans}
            for t in T.THRESHOLDS:
                rs = [T.pipeline(d, "2b", res, t, v) for d in owner]
                s = T.summary(rs, "owner")
                s["residue_calls"] = sum(1 for r in rs if any(c.startswith("trace-") for c in r["calls"]))
                s["missing"] = sum(1 for r in rs if r["stage"] == "residue-missing")
                out["pipeline"][f"2B chooser|{lab}-{v}|t={t}"] = s
    # where staging loses: the 131 whose rule stage picks some other printed year, against Gemini on the same ones
    picked = [d for d in nit if T.rule_pick(T.candidates(d["text"]))[0] is not None]
    out["rule_picked_not_in_text"] = {
        "n": len(picked), "rule_right": sum(T.rule_pick(T.candidates(d["text"]))[0] == d["truth"]["year"] for d in picked),
        "gemini_neigh_right": sum(T.parse_trace(gw[f"trace-neigh|{d['id']}"]["raw"])["y"] == d["truth"]["year"]
                                  for d in picked if f"trace-neigh|{d['id']}" in gw)}
    os.makedirs(os.path.dirname(RESULTS_JSON), exist_ok=True)
    json.dump(out, open(RESULTS_JSON, "w"), indent=1)
    write_md(out)
    print(f"-> {RESULTS}")


def pc(x):
    return f"{100 * x[0] / x[1]:.1f}%" if x and x[1] else "–"


def write_md(out):
    O, P = out["one_shot"], out["pipeline"]
    n = out["calls"]
    L = ["# Dating: Gemini on the trace prompts and the residue (W46.date-traceable-paid)", "",
         "Written by `scripts/segbench/date_traceable_gateway.py score`. Gemini 3.7 Flash through the Stanford AI API "
         "gateway (temperature 0, reasoning low, text only) on W46.date-traceable's three trace prompts, for the "
         f"{out['documents']} of the owner's 300 that need them: every document the rule stage leaves undated and every "
         "one whose year is not in the corpus text. The 27B's rows are W46.date-traceable's replies to the same prompts; "
         "Gemini 3.8 Flash's are W41's one shot with the app's prompt (OpenRouter). The gateway serves no 3.8. "
         f"Spend: about ${out['spent_estimate']:.2f} for {n} replies ({out['usage'].get('prompt_tokens', 0):,} input, "
         f"{out['usage'].get('completion_tokens', 0):,} output tokens incl. reasoning), an estimate at 3.8's list price "
         f"${out['price_assumed'][0]} / ${out['price_assumed'][1]} per million, so about "
         f"${1000 * out['usd_per_reply']:.2f} per 1,000 replies. The stated-confidence rerun is dropped (the trace "
         "prompt's 90% interval is what the conformal column reads).", ""]
    L += findings(out)
    L += ["## One shot on the 131 whose year is not in the corpus text", "",
          "Exact year, by class. Evidence: the cited quote checked against the cited document (date_scorers.evidence_check). "
          "Coverage and width: split-conformal at 90%, swapped halves, on the 131.", "",
          "| configuration | not in text | A | A' | B | C | D | C+D | evidence valid / unsupported | coverage | width |",
          "|---|---|---|---|---|---|---|---|---|---|---|"]
    for k, s in O.items():
        cf = s["conformal"].get("not in text") or {}
        cov = cf.get("coverage")
        w = cf.get("width")
        L.append(f"| {k} | " + " | ".join(pc(s["exact"][c]) for c in STRATA[:-1]) +
                 f" | {s['evidence'].get('valid', 0)} / {s['evidence'].get('unsupported', 0)} | "
                 f"{pc(cov) if cov else '–'} | {f'{w:.1f}' if isinstance(w, (int, float)) else '–'} |")
    L += ["", "## The staged pipeline with Gemini as the residue", "",
          "Rules, the 2B chooser, propagation within t documents, the residue to the trace model. On all 300; "
          "'not in text' is the 131, 'in text' the 119.", "",
          "| configuration | residue calls of 300 | in text | not in text | A | B | C | D | C+D |",
          "|---|---|---|---|---|---|---|---|---|"]
    for k, s in P.items():
        L.append(f"| {k} | {s['residue_calls']} | " + " | ".join(
            pc(s["exact"][c]) for c in ("in text", "not in text", "A", "B", "C", "D", "C+D")) + " |")
    open(RESULTS, "w").write("\n".join(L) + "\n")


def findings(out):
    """The run's reading, from the figures in `out`."""
    O, P = out["one_shot"], out["pipeline"]
    k38 = "Gemini 3.8 Flash, app prompt (W41, OpenRouter)"
    gk = {v: f"Gemini 3.7 Flash (gateway), trace-{v}" for v in VARIANTS}
    qk = {v: f"Qwen3.6 27B, trace-{v}" for v in VARIANTS}
    if not all(k in O for k in (k38, *gk.values(), *qk.values())):
        return []
    f = lambda k, c: pc(O[k]["exact"][c])
    p = lambda k, c: pc(P[k]["exact"][c])
    best = max(VARIANTS, key=lambda v: P[f"2B chooser|Gemini 3.7 trace-{v}|t=0"]["exact"]["not in text"][0])
    t0, t3 = f"2B chooser|Gemini 3.7 trace-{best}|t=0", f"2B chooser|Gemini 3.7 trace-{best}|t=3"
    ev = O[gk["neigh"]]["evidence"]
    rp = out["rule_picked_not_in_text"]
    return ["## Findings", "",
            f"- **Gemini with the trace prompt comes within two points of Gemini with the app's prompt, and cites its evidence.** On the 131 "
            f"whose year is not in the corpus text, Gemini 3.7 Flash with the neighbour dates (trace-neigh) gets "
            f"{f(gk['neigh'], 'not in text')}, plain {f(gk['plain'], 'not in text')}, with five same-collection examples "
            f"{f(gk['shots'], 'not in text')}; Gemini 3.8 Flash one shot with the app's prompt got "
            f"{f(k38, 'not in text')}. The 27B with the same three prompts gets {f(qk['plain'], 'not in text')} to "
            f"{f(qk['neigh'], 'not in text')}, so the gap to Gemini is about 16 points whichever prompt. Gemini's "
            f"citations check better than the 27B's ({ev.get('valid', 0)} valid / {ev.get('unsupported', 0)} unsupported "
            f"on trace-neigh, the 27B {O[qk['neigh']]['evidence'].get('valid', 0)} / "
            f"{O[qk['neigh']]['evidence'].get('unsupported', 0)}), and its 90% intervals are narrower at the same coverage "
            f"(conformal width about 4 years against 10 to 16).",
            f"- **Neighbour dates help where the year is near and hurt where it is not.** With them, Gemini gains on A' "
            f"({f(gk['plain'], chr(65) + chr(39))} to {f(gk['neigh'], chr(65) + chr(39))}) and B "
            f"({f(gk['plain'], 'B')} to {f(gk['neigh'], 'B')}) and loses on C and D, the classes this arm was for "
            f"(C+D {f(gk['plain'], 'C+D')} to {f(gk['neigh'], 'C+D')}; the app prompt's 3.8 {f(k38, 'C+D')}): a "
            f"printed neighbour year is a strong pull, and on C and D it is the wrong year. The five labelled examples "
            f"add nothing ({f(gk['shots'], 'C+D')} on C+D). No trace variant beats the app prompt on C+D.",
            f"- **Staging still costs accuracy, even with Gemini as the residue.** Rules, the 2B chooser and Gemini "
            f"trace-{best} on every document the rules leave undated (t=0, {P[t0]['residue_calls']} calls of 300) get "
            f"{p(t0, 'not in text')} of the 131, against {f(gk[best], 'not in text')} for the same prompt one shot; at t=3 "
            f"({P[t3]['residue_calls']} calls) {p(t3, 'not in text')}. At t=0 the whole loss is the rule stage: {rp['n']} of the 131 print some "
            f"other year, the rule's pick stands and is right on {rp['rule_right']} of them, where Gemini one shot is right "
            f"on {rp['gemini_neigh_right']}; on the rest the pipeline gives Gemini's own answer. At higher t propagation "
            f"adds to the loss, passing a neighbour's year on to B, C and D. The printed years are unchanged "
            f"({p(t0, 'in text')}). So for the profile that pays for Gemini, one shot on every document is the better "
            f"route on the unprinted years; staging saves calls ({P[t0]['residue_calls']} or {P[t3]['residue_calls']} "
            f"of 300) at the cost of those points.",
            f"- **Cost.** About ${1000 * out['usd_per_reply']:.2f} per 1,000 replies at 3.8's list price taken as a ceiling "
            f"(about 2,300 input and 310 output tokens a reply, reasoning low); the gateway returns no price. Gemini 3.7, "
            f"not 3.8, because the gateway serves no 3.8.", ""]


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run"); r.add_argument("--limit", type=int, default=0); r.add_argument("--variant", choices=VARIANTS)
    sub.add_parser("score")
    a = ap.parse_args()
    {"run": cmd_run, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    main()
