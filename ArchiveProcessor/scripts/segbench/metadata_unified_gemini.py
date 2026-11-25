#!/usr/bin/env python3
"""W49.proc-metadata-consolidate: the unified metadata call (metadata_unified.PROMPT, the frozen Sherlock pack's prompts)
on Gemini 3.8 Flash through the personal AI Studio key, for the item-field set's 299 documents.

    python3 metadata_unified_gemini.py models            # free: is MODEL served to the key (frozen into CACHE/model.json)
    python3 metadata_unified_gemini.py pilot [--n 8]     # the first documents of the three parts in turn; cost per call and the projection
    python3 metadata_unified_gemini.py run [--limit N]   # the 138 correspondence documents first, then the rest in a seeded order (paid, capped)
    python3 metadata_unified_gemini.py status            # answered, spent, the key's total, the projection for what is left

Why. W49.proc-metadata-consolidate asks whether one structured call does the work of the app's four post-OCR calls
(tagging, the dating trace, entities, item fields; prompts.md §5, §8, §9, §10) on the lead cloud model. The lead
models (Claude Fable, GPT-6.2 Astra) are reached only through the Stanford gateway, whose November budget is spent
until 1 December (W46.gateway-budget-reset), so this is the cloud arm that can run now: Gemini 3.8 Flash, the app's own
Gemini model, on the personal AI Studio key (root CLAUDE.md, exception to 1 Dec: $5 in all across items; this item's
cap $2, owner 2026-11-24). The cluster arm is the same prompt on Qwen3.6 27B (metadata_unified.py, Sherlock); the
separate-call baselines are the replies already in the bench cache on the same Vision text
(metadata_unified_score.py lists them).

Route and settings. AI Studio's v1beta generateContent, the key from the Keychain (com.archiveprocessor.app / Gemini),
read once into memory, never printed or written; the model asked for by name (this key answers a request for
gemini-3.7-flash with modelVersion gemini-3.8-flash, ent_8k_paired's finding). Text only, the pack's prompt byte for
byte (a kept reply is refused if the prompt it answered differs from the prompt as it now renders), temperature 0,
MAX_TOKENS output tokens (the pack's 6,144), thinkingConfig thinkingLevel low. Low, not the model's default: the
app's item-field, trace and image-pass calls run at low reasoning (prompts.md §9, §10), the cluster arm runs with
thinking off, and the default's thought tokens (ent_8k_paired: about 800 a call on a short entity prompt) would put
the 299 past the key's remaining allowance. The tagging and entity calls the baselines come from were sent with no
thinking setting; the score item's card names this difference. AI Studio has no response cache, so no reply is a
copy of another.

Money. Real money on the personal key: CAP bounds this item, counted from usageMetadata at gateway_gemini.PRICE
(Gemini 3.8 Flash's list price to 31 Dec 2026, $0.75/$3.75 per million; thinking billed as output; the key reports
no cost, so it is an estimate), and every call is refused unless its worst case still fits under CAP and, with the
other items' ledgers on this key (KEY_LEDGERS), under KEY_TOTAL. The ledger line (CACHE/calls.jsonl) is written
before the reply is used; a call that never answers is counted at its worst case. A 402 or a billing or free-tier
answer stops the run. Order: the 138 correspondence documents first (they carry the entity, item-field and date
truths at once), then the other 161 in a seeded shuffle, so a run the cap stops early leaves a random sample of the
rest rather than one part. Replies and the ledger stay in the bench cache (the prompts carry the owner's text).
Run from scripts/segbench.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import statistics
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import metadata_unified as M  # noqa: E402

ITEM = "W49.proc-metadata-consolidate"
API = "https://generativelanguage.googleapis.com/v1beta/models"
MODEL = "gemini-3.8-flash"
ARM = "unified-gemini3.8-flash"
THINKING = {"thinkingLevel": "low"}
REHEARSAL = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal")
CACHE = str(M.CACHE)                                   # metadata-unified/: replies/<ARM>/, calls.jsonl, model.json
CAP = 2.00                 # the item's explicit cap (owner, 2026-11-24), under the $7 rule
KEY_TOTAL = 5.00           # the personal key's allowance across items to 1 Dec 2026 (root CLAUDE.md)
KEY_LEDGERS = [os.path.join(REHEARSAL, "gemini4-hydrogen-96", "calls.jsonl"),      # 2026-11-18
               os.path.join(REHEARSAL, "ent-8k-paired", "calls.jsonl")]            # 2026-11-19
MAX_TOKENS = M.MAX_TOKENS
WORST_PROMPT = 7000        # tokens: the largest pack prompt is 25,548 characters, about 6,400 tokens on the Mac pilot
WORKERS = 4
SEED = 20261124
_key = None
_lock = threading.Lock()


class Stop(SystemExit):
    pass


def price():
    import gateway_gemini as G
    return G.PRICE


def worst():
    pin, pout = price()
    return (WORST_PROMPT * pin + MAX_TOKENS * pout) / 1e6


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
    return [json.loads(x) for x in open(f) if x.strip()] if os.path.exists(f) else []


def spent():
    return sum(r.get("cost") or 0 for r in ledger())


def key_spent():
    return spent() + sum(r.get("cost") or 0 for f in KEY_LEDGERS for r in ledger(f))


def cost(u):
    pin, pout = price()
    out = (u.get("candidatesTokenCount") or 0) + (u.get("thoughtsTokenCount") or 0)
    return ((u.get("promptTokenCount") or 0) * pin + out * pout) / 1e6


def body(prompt):
    return {"contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {"temperature": 0, "maxOutputTokens": MAX_TOKENS, "thinkingConfig": THINKING}}


def reply_path(doc_id):
    return os.path.join(CACHE, "replies", ARM, doc_id + ".json")


# --- the order --------------------------------------------------------------------------------------------------

def correspondence_ids():
    """The 138 documents with entity truth (W46.fix-ent-truth's correspondence rows)."""
    import ent_score_paid as P
    return {r["id"] for r, _d in P.rows()}


def ordered(ds):
    """The correspondence documents first, in the set's order; the rest shuffled once with SEED."""
    corr = correspondence_ids()
    first = [d for d in ds if d["id"] in corr]
    rest = [d for d in ds if d["id"] not in corr]
    random.Random(SEED).shuffle(rest)
    return first + rest


def pilot_docs(ds, n):
    parts = [[d for d in ds if d["part"] == x] for x in ("base", "clippings", "handwritten")]
    return [d for k in range(len(ds)) for g in parts for d in g[k:k + 1]][:n]


# --- the call ---------------------------------------------------------------------------------------------------

def call(doc_id, prompt):
    """One call, kept by destination and refused on a prompt or model mismatch; the ledger line is written before
    the reply is used. Returns True when a reply is on disk afterwards."""
    dest = reply_path(doc_id)
    sha = M.sha(prompt)
    if os.path.exists(dest):
        m = json.load(open(dest)).get("meta", {})
        if m.get("prompt_sha256") != sha or m.get("model_asked") != MODEL:
            raise Stop(f"{dest}: kept reply answered another prompt or model; move it aside to call again")
        return True
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
        r = None
        for attempt in range(4):
            try:
                r = request(f"/{MODEL}:generateContent", b)
            except Exception as e:   # a read timeout or a dropped connection: counted at worst case, then retried
                with _lock:
                    os.makedirs(CACHE, exist_ok=True)
                    with open(os.path.join(CACHE, "calls.jsonl"), "a") as fh:
                        fh.write(json.dumps({"arm": ARM, "doc": doc_id, "http": None, "error": type(e).__name__,
                                             "t": t, "wall_s": round(time.time() - t, 3), "model_asked": MODEL,
                                             "usage": {}, "cost": round(worst(), 6), "prompt_sha256": sha}) + "\n")
                if attempt < 3:
                    time.sleep(15 * (attempt + 1)); continue
                print(doc_id, "no answer:", type(e).__name__)
                return False
            if r.status_code in (429, 500, 502, 503, 504) and attempt < 3:
                time.sleep(15 * (attempt + 1)); continue
            break
        got = r.json() if r.headers.get("content-type", "").startswith("application/json") else {"raw": r.text[:2000]}
        u = got.get("usageMetadata") or {}
        rec = {"arm": ARM, "doc": doc_id, "http": r.status_code, "t": t, "wall_s": round(time.time() - t, 3),
               "model_asked": MODEL, "model": got.get("modelVersion"), "usage": u, "cost": round(cost(u), 6),
               "prompt_sha256": sha, "request": b["generationConfig"]}
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
        out = {"meta": {**rec, "finish": cand.get("finishReason"), "runtime": "AI Studio, personal key",
                        "thinking": THINKING["thinkingLevel"]}, "raw": raw, "parsed": M.parse(raw)}
        tmp = dest + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(out, fh, ensure_ascii=False, indent=1)
        os.replace(tmp, dest)
        return True
    print(doc_id, r.status_code, cand.get("finishReason"), msg[:300])
    return False


def run_docs(ds):
    with ThreadPoolExecutor(WORKERS) as ex:
        return list(ex.map(lambda d: call(d["id"], M.prompt(d)), ds))


# --- commands ---------------------------------------------------------------------------------------------------

def cmd_models(_a):
    r = request(f"/{MODEL}")
    got = r.json() if r.headers.get("content-type", "").startswith("application/json") else {"raw": r.text[:500]}
    os.makedirs(CACHE, exist_ok=True)
    json.dump({"asked": MODEL, "http": r.status_code, "t": time.time(), "entry": got},
              open(os.path.join(CACHE, "model.json"), "w"), indent=1)
    print(r.status_code, {k: got.get(k) for k in ("name", "version", "displayName", "inputTokenLimit", "outputTokenLimit")})


def summary(ds=None):
    rows = [r for r in ledger() if r.get("http") == 200 and r.get("model_asked") == MODEL]
    ds = ds or M.docs()
    answered = sum(os.path.exists(reply_path(d["id"])) for d in ds)
    per = statistics.mean(r["cost"] for r in rows) if rows else None
    left = len(ds) - answered
    print(f"{answered}/{len(ds)} answered; ${spent():.4f} spent of ${CAP}; the key ${key_spent():.4f} of ${KEY_TOTAL}")
    if rows:
        u = [r["usage"] for r in rows]
        print(f"per call: ${per:.5f} mean; prompt {statistics.mean(x.get('promptTokenCount') or 0 for x in u):.0f}, "
              f"reply {statistics.mean(x.get('candidatesTokenCount') or 0 for x in u):.0f}, thoughts "
              f"{statistics.mean(x.get('thoughtsTokenCount') or 0 for x in u):.0f} tokens; "
              f"{statistics.median(r['wall_s'] for r in rows):.1f} s median")
        print(f"projection for the {left} left: ${per * left:.2f}; headroom ${min(CAP - spent(), KEY_TOTAL - key_spent()):.2f}")
    return per, left


def cmd_pilot(a):
    ds = M.docs()
    ok = run_docs(pilot_docs(ds, a.n))
    print(f"pilot: {sum(ok)}/{len(ok)} answered")
    for d in pilot_docs(ds, a.n):
        p = reply_path(d["id"])
        if os.path.exists(p):
            js = json.load(open(p))["parsed"]
            print(f"  {d['id']} {d['part']}: parsed {js is not None}, kind {js and js['kind']}, "
                  f"year {js and (js['date'] or {}).get('year')}, finish {json.load(open(p))['meta'].get('finish')}")
    summary(ds)


def cmd_run(a):
    ds = ordered(M.docs())[: a.limit or None]
    try:
        ok = run_docs(ds)
        print(f"run: {sum(ok)}/{len(ok)} answered")
    finally:
        summary()


def cmd_status(_a):
    summary()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("models")
    sub.add_parser("pilot").add_argument("--n", type=int, default=8)
    sub.add_parser("run").add_argument("--limit", type=int, default=0)
    sub.add_parser("status")
    a = ap.parse_args()
    {"models": cmd_models, "pilot": cmd_pilot, "run": cmd_run, "status": cmd_status}[a.cmd](a)


if __name__ == "__main__":
    main()
