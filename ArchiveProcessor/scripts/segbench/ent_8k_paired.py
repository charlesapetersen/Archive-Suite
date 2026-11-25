#!/usr/bin/env python3
"""W47.wh-ent-8k-paired: the 8,000-character entity prompt paired against the shipped entity call, neither from a cache.

    python3 ent_8k_paired.py models                 # free: is MODEL served to the personal key (frozen into CACHE)
    python3 ent_8k_paired.py run --limit 2           # pilot: two documents, every label
    python3 ent_8k_paired.py run                     # all 138, every label (paid, capped)
    python3 ent_8k_paired.py report                  # segbench-results/ent-8k-paired.md and .json

Why (owner call 15, 2026-11-19: ask again after the named work; 16-withheld-review.md section 8). The 8,000-character
dedicated prompt led on the sender (0.76 against the shipped call's 0.69) but was never paired with the shipped call
itself, and 88 of its 138 replies against the 3,000-character twin came from the gateway's response cache, equal by
construction (ent-score-paid.md card). The shipped call is EntityExtractor.swift: the dedicated prompt with the
sending-place rule on the first 3,000 characters (ent_feature.TEMPLATE, which test_ent_feature checks against the
Swift). The withheld feature is the same prompt on the first 8,000 (ent_truth.TEXT_CAP), nothing else changed.

Labels, every one called fresh on all 138 correspondence documents (ent_score_paid.rows), same Vision text as every
entity arm since W46.ent-score-paid:
- shipped, shipped-b: the shipped call, twice.
- 8k, 8k-b: the 8,000-character prompt, twice.
The two runs of each give the rerun drift on all 138 (not 40), and two independent pairings of 8k against shipped.
On a document of 3,000 characters or fewer the two prompts are byte-identical, so there the pairing measures only
drift; the report gives the documents that run past 3,000 apart, where the prompts differ.

Route: Gemini 3.8 Flash, the app's own Gemini model, called directly on AI Studio's v1beta generateContent with the
personal key (Keychain com.archiveprocessor.app / Gemini), as ocr_hydrogen96.py does: the Stanford gateway's
November budget is spent, and root CLAUDE.md lets the personal key serve Gemini bench work to 1 Dec 2026, $5 in all
across items. Every earlier entity arm was Gemini 3.7 Flash through the gateway, but this key answers a request for
gemini-3.7-flash with modelVersion gemini-3.8-flash (all 8 calls of the first pilot, 2026-11-19, kept in the ledger)
and lists no pinned 3.7 name, so the arms ask for 3.8 by name; the comparison is paired inside this run, and figures
across the two models are not. Text only, temperature 0, MAX_TOKENS output tokens, no thinkingConfig (the model's default; the gateway
arms sent none either). AI Studio has no response cache, so no reply is a copy of another. Real money: CAP bounds this
item, counted from usageMetadata at gateway_gemini.PRICE (Gemini 3.8 Flash's list price to 31 Dec 2026, $0.75/$3.75; the key reports no cost, so
it is an estimate), thinking billed as output; a call is refused unless its worst case still fits under CAP and,
with the other items' ledgers on this key (KEY_LEDGERS), under KEY_TOTAL. A 402 or a billing or free-tier answer
stops the run. Texts and replies stay in the bench cache (the owner's material); the report carries aggregates only.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ent_feature as F  # noqa: E402
import ent_score_paid as P  # noqa: E402
import ent_truth as ET  # noqa: E402

API = "https://generativelanguage.googleapis.com/v1beta/models"
MODEL = "gemini-3.8-flash"
REHEARSAL = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal")
CACHE = os.path.join(REHEARSAL, "ent-8k-paired")
RESULTS = os.path.join(HERE, "..", "..", "segbench-results", "ent-8k-paired.md")
CAP = 2.80                # this item's total, under the owner's $7 a piece of work
KEY_TOTAL = 5.00          # the personal key's allowance across items to 1 Dec 2026 (root CLAUDE.md)
KEY_LEDGERS = [os.path.join(REHEARSAL, "gemini4-hydrogen-96", "calls.jsonl")]   # the key's other spend, 2026-11-18
MAX_TOKENS = 8192         # the gateway arms' (gateway_gemini.MAX_TOKENS)
WORKERS = 4
SHIPPED_CAP = 3000        # EntityExtractor.textCap as measured; 8,000 since W47.wh-ent-8k-apply (F.TEXT_CAP)
LONG_CAP = ET.TEXT_CAP    # 8,000
LABELS = {"shipped": SHIPPED_CAP, "shipped-b": SHIPPED_CAP, "8k": LONG_CAP, "8k-b": LONG_CAP}
_key = None
_lock = threading.Lock()


class Stop(SystemExit):
    pass


def price():
    import gateway_gemini as G
    return G.PRICE


def worst():
    pin, pout = price()
    return (4000 * pin + MAX_TOKENS * pout) / 1e6


def api_key():
    """Read once from the Keychain into memory. Never printed or written."""
    global _key
    if _key is None:
        r = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "com.archiveprocessor.app",
                            "-a", "Gemini", "-w"], capture_output=True, text=True)
        if r.returncode != 0 or not r.stdout.strip():
            raise Stop("no Gemini key in the Keychain (com.archiveprocessor.app / Gemini)")
        _key = r.stdout.strip()
    return _key


def request(path, body=None, timeout=300):
    import requests
    h = {"x-goog-api-key": api_key()}
    if body is None:
        return requests.get(API + path, headers=h, timeout=timeout)
    return requests.post(API + path, headers=h, json=body, timeout=timeout)


def ledger(f=None):
    f = f or os.path.join(CACHE, "calls.jsonl")
    return [json.loads(x) for x in open(f)] if os.path.exists(f) else []


def spent():
    return sum(r.get("cost") or 0 for r in ledger())


def key_spent():
    return spent() + sum(r.get("cost") or 0 for f in KEY_LEDGERS for r in ledger(f))


def cost(u):
    pin, pout = price()
    out = (u.get("candidatesTokenCount") or 0) + (u.get("thoughtsTokenCount") or 0)
    return ((u.get("promptTokenCount") or 0) * pin + out * pout) / 1e6


def cmd_models(_a):
    r = request("?pageSize=1000", timeout=60)
    if r.status_code != 200:
        raise Stop(f"models list answered {r.status_code}: {r.text[:300]}")
    entry = next((m for m in r.json().get("models", []) if m.get("name") == "models/" + MODEL), None)
    if entry is None:
        raise Stop(MODEL + " is not served to this key")
    os.makedirs(CACHE, exist_ok=True)
    json.dump(entry, open(os.path.join(CACHE, "model.json"), "w"), indent=1)
    print(json.dumps(entry, indent=1))


def prompt_for(label, d):
    """The shipped call's prompt (ent_feature.prompt) at the label's length."""
    return F.TEMPLATE.format(text=P.vision_text(d)[:LABELS[label]])


def body(prompt):
    return {"contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {"temperature": 0, "maxOutputTokens": MAX_TOKENS}}


def reply_path(label, doc_id):
    return P.reply_path(label, doc_id, CACHE)


def call(label, doc_id, prompt):
    """One call, kept by destination and refused on a prompt mismatch; the ledger line is written before the reply."""
    dest = reply_path(label, doc_id)
    sha = P.prompt_sha(prompt)
    if os.path.exists(dest):
        m = json.load(open(dest)).get("meta", {})
        if m.get("prompt_sha256") != sha or m.get("model_asked") != MODEL:
            raise Stop(f"{dest}: kept reply answered another prompt or model; move it aside to call again")
        return
    with _lock:   # reserve the worst case: spent plus every call in flight
        call.inflight = getattr(call, "inflight", 0)
        w = (call.inflight + 1) * worst()
        if spent() + w > CAP:
            raise Stop(f"cap: ${spent():.4f} spent of ${CAP}")
        if key_spent() + w > KEY_TOTAL:
            raise Stop(f"key total: ${key_spent():.4f} spent of the key's ${KEY_TOTAL}")
        call.inflight += 1
    try:
        b = body(prompt)
        t = time.time()
        for attempt in range(4):
            r = request(f"/{MODEL}:generateContent", b)
            if r.status_code in (429, 500, 502, 503, 504) and attempt < 3:
                time.sleep(15 * (attempt + 1)); continue
            break
        got = r.json() if r.headers.get("content-type", "").startswith("application/json") else {"raw": r.text[:2000]}
        u = got.get("usageMetadata") or {}
        rec = {"arm": label, "doc": doc_id, "http": r.status_code, "t": t, "wall_s": round(time.time() - t, 3),
               "model_asked": MODEL, "model": got.get("modelVersion"), "usage": u, "cost": round(cost(u), 6),
               "prompt_sha256": sha, "request": {k: v for k, v in b.items() if k != "contents"}}
        with _lock:
            os.makedirs(CACHE, exist_ok=True)
            with open(os.path.join(CACHE, "calls.jsonl"), "a") as fh:
                fh.write(json.dumps(rec) + "\n")
    finally:
        with _lock:
            call.inflight -= 1
    msg = json.dumps(got)[:400]
    if r.status_code == 402 or "billing" in msg.lower() or "free_tier" in msg.lower():
        raise Stop(f"{doc_id}: {r.status_code} {msg}")
    cand = (got.get("candidates") or [{}])[0]
    parts = (cand.get("content") or {}).get("parts") or []
    raw = "".join(p.get("text", "") for p in parts if not p.get("thought")) if r.status_code == 200 else None
    if r.status_code == 200 and raw:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        P.write_reply(dest, {"meta": {**rec, "finish": cand.get("finishReason")}, "raw": raw})
    else:
        print(label, doc_id, r.status_code, cand.get("finishReason"), msg[:300])


def cmd_run(a):
    rs = P.rows()[: a.limit or None]
    jobs = [(lab, d) for lab in LABELS for _r, d in rs]
    with ThreadPoolExecutor(WORKERS) as ex:
        list(ex.map(lambda j: call(j[0], j[1]["id"], prompt_for(j[0], j[1])), jobs))
    for lab in LABELS:
        n = sum(os.path.exists(reply_path(lab, d["id"])) for _r, d in rs)
        print(f"{lab}: {n}/{len(rs)} answered")
    print(f"${spent():.4f} spent of ${CAP}; the key ${key_spent():.4f} of ${KEY_TOTAL}")


# --- the report ------------------------------------------------------------------------------------

def cmd_report(_a):
    import ent_truth_owner as EO
    truth = {r["id"]: r for r in ET.load_truth()}
    for lab in LABELS:   # every kept reply answered this label's prompt and model
        for _r, d in P.rows():
            p = reply_path(lab, d["id"])
            if os.path.exists(p):
                m = json.load(open(p))["meta"]
                if m["prompt_sha256"] != P.prompt_sha(prompt_for(lab, d)) or m["model_asked"] != MODEL:
                    raise Stop(f"{p}: answered another prompt or model")
    A = {lab: P.preds(lab, CACHE) for lab in LABELS}
    pr = {k: v[0] for k, v in A.items()}
    texts = {d["id"]: P.vision_text(d) for _r, d in P.rows()}
    long_ids = {i for i, t in texts.items() if len(t) > SHIPPED_CAP}
    s = {"docs": len(truth), "long_docs": len(long_ids & set(truth)),
         "answered": {k: len(v[0]) for k, v in A.items()}, "unparsed": {k: v[1] for k, v in A.items()},
         "scores": {k: EO.scores(p, truth) for k, p in pr.items()}, "paired": {}, "paired_long": {}}
    comps = (("8k against shipped (first runs)", "shipped", "8k"),
             ("8k against shipped (second runs)", "shipped-b", "8k-b"),
             ("rerun drift: shipped again", "shipped", "shipped-b"),
             ("rerun drift: 8k again", "8k", "8k-b"))
    for key, sub in (("paired", truth), ("paired_long", {i: truth[i] for i in long_ids if i in truth})):
        for name, a_, b_ in comps:
            ids = sorted(set(pr[a_]) & set(pr[b_]) & set(sub))
            s[key][name] = {"a": a_, "b": b_, **{f: P.paired(pr[a_], pr[b_], ids, sub, f) for f in ET.FIELDS},
                            "city": EO.paired_city(pr[a_], pr[b_], sub)["city"]}
    s["scores_long"] = {k: EO.scores({i: p for i, p in v.items() if i in long_ids}, {i: truth[i] for i in long_ids})
                        for k, v in pr.items()}
    s["evidence"] = {k: P.evidence(p, truth, texts, LABELS[k]) for k, p in pr.items()}
    allc = ledger()
    led = [r for r in allc if r.get("model_asked") == MODEL]   # the pilot that asked for 3.7 is counted in spent only
    s["calls"] = {"n": len(led), "ok": sum(r["http"] == 200 for r in led), "spent": round(spent(), 4),
                  "other_model_calls": len(allc) - len(led),
                  "key_spent": round(key_spent(), 4), "models": dict(collections.Counter(r.get("model") for r in led)),
                  "thoughts_mean": round(sum((r["usage"].get("thoughtsTokenCount") or 0) for r in led) / max(len(led), 1)),
                  "prompt_mean": {k: round(sum((r["usage"].get("promptTokenCount") or 0) for r in led if r["arm"] == k)
                                           / max(sum(r["arm"] == k for r in led), 1)) for k in LABELS},
                  "finish": dict(collections.Counter(json.load(open(reply_path(r["arm"], r["doc"])))["meta"].get("finish")
                                                     for r in led if r["http"] == 200 and os.path.exists(reply_path(r["arm"], r["doc"]))))}
    s["price"] = price()
    json.dump(s, open(RESULTS[:-3] + ".json", "w"), indent=1, default=str)
    open(RESULTS, "w").write(report(s))
    print(RESULTS)


def fmt(p):
    return f"{p['diff']:+.3f} [{p['lo']:+.3f}, {p['hi']:+.3f}]"


def report(s):
    L = ["# The 8,000-character entity prompt paired against the shipped entity call (W47.wh-ent-8k-paired)", "",
         "Generated by `scripts/segbench/ent_8k_paired.py report`; method in its header. The 138 correspondence "
         "documents, Apple Vision text of the JPEG originals, Gemini 3.8 Flash called directly on AI Studio (the "
         "personal key), every reply fresh, scored against the entity truth as it now stands (`ent_truth.load_truth()`:"
         " the owner's answers and the sending-place rule). The shipped call is EntityExtractor.swift's prompt on the "
         "first 3,000 characters; the 8k arm is the same prompt on the first 8,000. Each was run twice.", "",
         "Answered / unparsed: " + ", ".join(f"{k} {s['answered'][k]}/{s['unparsed'][k]}" for k in LABELS) + ".", "",
         f"{s['long_docs']} of the {s['docs']} documents run past 3,000 characters; on the rest the two prompts are "
         "byte-identical, so there the two arms differ only by drift between identical calls.", "",
         "## Scores (ed2)", "",
         "| arm | n | sender F1 | recipient F1 | place P / R / F1 | place by city | wrong-when-filled docs: sender / recipient / place |",
         "|---|---|---|---|---|---|---|"]
    for k, v in s["scores"].items():
        sp = v["sending_place"]
        L.append(f"| {k} | {v['n']} | {v['sender']['f1']:.3f} | {v['recipient']['f1']:.3f} | "
                 f"{sp['precision']:.2f} / {sp['recall']:.2f} / {sp['f1']:.3f} | {v['city']['f1']:.3f} | "
                 f"{v['sender']['wrong_when_filled_docs']} / {v['recipient']['wrong_when_filled_docs']} / "
                 f"{sp['wrong_when_filled_docs']} |")
    L += ["", f"On the {s['long_docs']} documents past 3,000 characters:", "",
          "| arm | n | sender F1 | recipient F1 | place F1 | place by city |", "|---|---|---|---|---|---|"]
    for k, v in s["scores_long"].items():
        L.append(f"| {k} | {v['n']} | {v['sender']['f1']:.3f} | {v['recipient']['f1']:.3f} | "
                 f"{v['sending_place']['f1']:.3f} | {v['city']['f1']:.3f} |")
    for key, title in (("paired", "all 138"), ("paired_long", f"the {s['long_docs']} documents past 3,000 characters")):
        L += ["", f"## Paired differences in ed2 F1, b minus a, on {title} (95% bootstrap interval)", "",
              "| comparison | a → b | n | sender | recipient | sending place | place by city |", "|---|---|---|---|---|---|---|"]
        for name, v in s[key].items():
            L.append(f"| {name} | {v['a']} → {v['b']} | {v['sender']['n']} | {fmt(v['sender'])} | "
                     f"{fmt(v['recipient'])} | {fmt(v['sending_place'])} | {fmt(v['city'])} |")
    L += ["", "## Precision (ed2) of each arm's names by their quote", "",
          "As ent-score-paid.md's table: the quote found verbatim (whitespace folded) in the text the arm sent, no quote, "
          "or a quote not in it; a name matching only a role- or correspondence-inferred truth entry is set aside.", "",
          "| arm | field | quote in text | no quote | quote not in text |", "|---|---|---|---|---|"]
    for k, v in s["evidence"].items():
        for f, c in v.items():
            cell = lambda g: (lambda x: f"{x[0]}/{sum(x)} ({x[0] / sum(x):.2f})" if sum(x) else "0/0")(c.get(g, [0, 0]))  # noqa: E731
            L.append(f"| {k} | {f} | {cell('quote in text')} | {cell('no quote')} | {cell('quote not in text')} |")
    c = s["calls"]
    L += ["", f"Spend: ${c['spent']:.2f} estimated over {c['n']} calls ({c['ok']} answered) and the "
          f"{c['other_model_calls']} pilot calls that asked for gemini-3.7-flash, at "
          f"${s['price'][0]}/${s['price'][1]} per million tokens in/out, thinking as output (the key reports no "
          f"cost); the personal key's total to date ${c['key_spent']:.2f} of $5. Model versions answered: {c['models']}. "
          f"Mean thinking tokens a call {c['thoughts_mean']}; mean prompt tokens {c['prompt_mean']}. "
          f"Finish reasons: {c['finish']}.", ""]
    L += [READING, "", CARD]
    return "\n".join(L) + "\n"


READING = """## Reading

- **Senders: the 8,000-character prompt is better, and the gain is real.** ed2 F1 0.70 with the shipped call, 0.81
  with the 8k prompt: +0.107 (95% +0.038 to +0.189), and +0.108 (+0.034 to +0.194) on the second, independent pair of
  runs. The rerun drift of either arm is about a point (-0.013 and -0.012, intervals across zero), so the gap is
  eight times the drift and clears it in both pairings. It is all in the 48 documents that run past 3,000
  characters: there 0.46 against 0.80 (+0.34, +0.16 to +0.52; +0.37 on the second runs), where the signature sits
  beyond the shipped call's window. The 8k prompt finds 19 more right senders (107 against 88 of 127 named), fills 5
  fewer wrong (22 against 27 documents) and misses 19 fewer.
- **Recipients and places: ties.** Recipient +0.01 and +0.00, place +0.01 and -0.01 on the full string, +0.01 by city
  (the city's interval touches zero from above in the first pairing; the drift moves it the same +0.008). The inside
  address and the letterhead sit at the top of a letter, inside the first 3,000 characters.
- **The evidence check holds.** Every quoted name in both arms was found in the text the arm sent; at most one sender a
  run came without a quote. Sender precision of quoted names 0.82 at 8,000 characters against 0.77 at 3,000.
- **Cost.** The 8k prompt sends about 210 more tokens a document on average and thinks a little longer (870 against
  770 thinking tokens): $4.39 against $3.84 per 1,000 correspondence documents at Gemini 3.8 Flash's price to 31
  December ($0.75/$3.75), +$0.55 (+14%); twice those figures from 1 January 2027 ($1.50/$7.50). Median 5.9 s a call
  against 5.2.
- **What it settles.** The earlier "8k against the shipped call" figure (ent-score-paid.md, +0.054, a tie inside a
  drift of +0.044) was against the tagging call, on 3.7 through the gateway, with 88 of 138 8k replies cached. Paired
  against the call the app ships, fresh, on the same model, the sender gain is about ten points and replicates.
  Nothing is changed by this item: whether EntityExtractor's window moves to 8,000 characters is the owner's call
  (call 13), asked in the Daemon Report."""
CARD = """## Measurement card

- **Truth:** the entity truth as it now stands (`ent_truth.load_truth()`): W46.fix-ent-truth's 138 correspondence
  documents, drafted blind by GPT 5.6 Luna and Claude Sonnet 5 and ruled by Sonnet 5, with the owner's answers and the
  sending-place rule (W46.ent-truth-owner-fold). Model truth except where the owner answered. No Gemini drafted or
  ruled, so no scored route is a drafter or a relative of one.
- **Selection:** the same 138 as every entity arm since W46.ent-score-paid (82 of the dating sample's correspondence
  plus 56 additions stratified by text cues read from the ABBYY text: chosen by the ABBYY text, not by any route
  tested here). The 48 long documents are those whose Vision text runs past 3,000 characters, fixed before the run.
- **Comparison:** the same Vision text of the same JPEG originals, the same model (Gemini 3.8 Flash; every reply's
  modelVersion), temperature 0, 8,192 output tokens, no thinking setting, the same prompt wording; only the window
  differs (EntityExtractor's 3,000 against 8,000). Every one of the 552 replies is a fresh call (AI Studio keeps no
  response cache). On the 90 documents of 3,000 characters or fewer the two requests are byte-identical.
  Not comparable with the earlier 3.7 figures: this key answers gemini-3.7-flash with 3.8 Flash.
- **Noise:** n 138 (48 long); paired document bootstrap, 2,000 draws, 95% intervals. Each arm was run twice on all
  138, so the rerun drift is measured on the whole set (sender -0.013 and -0.012, recipient within a point, place
  +0.02 and +0.01 full string, +0.008 by city) and the comparison is made twice on independent runs. A gap inside its
  interval or the drift is a tie.
- **Scope:** text only (Apple Vision text), one model, one prompt wording, correspondence only. It does not settle a
  multimodal read, a local model at 8,000 characters (W47.wh-names-small-mac's Mac models see 3,000), the tagging
  call's own window, or the figures on Gemini 3.7 Flash."""


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("models")
    r = sp.add_parser("run")
    r.add_argument("--limit", type=int)
    sp.add_parser("report")
    a = ap.parse_args()
    {"models": cmd_models, "run": cmd_run, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    main()
