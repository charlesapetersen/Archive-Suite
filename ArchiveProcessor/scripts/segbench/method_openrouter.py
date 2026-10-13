"""W41.seg-large: open-weight 27B-122B vision models over Deaver's windows, through OpenRouter.

    python method_openrouter.py endpoints                      # candidate ids, providers, precisions, prices
    python method_openrouter.py collect <model> [Deaver] [--limit N]
    python method_openrouter.py report [Deaver]                # rows into segbench-results/local-models-<box>.md

Owner, 2026-10-11 (SUITE_TODO W41): do the models a 64 GB Mac could hold segment any better than the 4B-12B
ones did on device (method_local, 47-57% pages in exact doc), or come near the cloud's 97.9% on Deaver? So the
request is method_local's, unchanged: method_window_cues's codex prompt (the owner's cues), the same windows,
combining and assembly, the images shrunk to method_local.MAX_SIDE px. Only the route differs.

THE ROUTE. OpenRouter's chat completions, the images inline as JPEG data URLs in page order, temperature 0,
reasoning off. One provider pinned per model for the whole run (``allow_fallbacks: false``), and the
provider and its precision are recorded with every call, since providers serve the same weights at bf16, fp8
or fp4 and two rows are only comparable at one precision. The key is the owner's (Keychain service
com.archiveprocessor.app, account OpenRouter), read once into memory, never printed or written. Every valid
answer is cached by content hash in ``ResponseCache("window-or-<model>")``. A window that does not parse after
one retry at a longer token limit is recorded as failed and votes 0.5 "new" on its gaps, as method_local's do.

MONEY. Each call's cost is read from OpenRouter's usage record and logged; ``collect`` stops before the item's
spend (every model's log summed) would pass CAP_USD.
"""
from __future__ import annotations

import base64
import concurrent.futures as cf
import io
import json
import subprocess
import sys
import threading
import time

import data
from methods import METHODS  # noqa: F401  (loads method_window and method_gemini in order)
import method_window as W
import method_local as L
from score import derived, score_labels

API = "https://openrouter.ai/api/v1"
CAP_USD = 1.00
MAX_TOKENS = L.MAX_TOKENS
PROMPT_VERSION = "o1"
CONCURRENCY = int(__import__("os").environ.get("SEGBENCH_OR_CONCURRENCY", 4))
TIMEOUT_S = 300
# key: (OpenRouter id, label, pinned provider, its precision, parameters (total, active), local 4-bit GB)
MODELS = {
    # fp8 where offered (between the full bf16 weights and a Mac's 4-bit), the cheapest fp8 provider with full
    # uptime on 2026-10-13 (``endpoints``). Gemma 4 31B's fp8 endpoints refuse images (OpenRouter: "Filter by
    # Image Support removed ... deepinfra/fp8"), so it runs at bf16 on Crusoe, the cheapest image-capable one.
    "qwen3.5-27b": ("qwen/qwen3.5-27b", "Qwen3.5 27B", "deepinfra", "fp8", "27B dense", 17),
    "qwen3.6-35b-a3b": ("qwen/qwen3.6-35b-a3b", "Qwen3.6 35B-A3B", "deepinfra", "fp8", "35B, 3B active", 21),
    "gemma4-31b": ("google/gemma-4-31b-it", "Gemma 4 31B", "crusoe", "bf16", "31B dense", 19),
    "qwen3.5-122b-a10b": ("qwen/qwen3.5-122b-a10b", "Qwen3.5 122B-A10B", "siliconflow", "fp8", "122B, 10B active", 70),
    # The one 4-bit-class build offered for any of the four: the nearest a cloud run gets to a Mac's 4-bit.
    "qwen3.6-35b-a3b-fp4": ("qwen/qwen3.6-35b-a3b", "Qwen3.6 35B-A3B", "darkbloom", "fp4", "35B, 3B active", 21),
}
FAILED = L.FAILED

_key = None
_key_lock = threading.Lock()
_log_lock = threading.Lock()


def api_key() -> str:
    """Read once from the Keychain into memory. Never printed or written."""
    global _key
    with _key_lock:
        if _key is None:
            r = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "com.archiveprocessor.app",
                                "-a", "OpenRouter", "-w"], capture_output=True, text=True)
            k = r.stdout.strip()
            if r.returncode != 0 or not k:
                raise SystemExit("no OpenRouter key in the Keychain (com.archiveprocessor.app / OpenRouter)")
            _key = k
        return _key


def cache(key):
    return data.ResponseCache(f"window-or-{key}")


def log_path(key):
    return data.CACHE_DIR / f"window-or-{key}-calls.jsonl"


def records(key) -> list[dict]:
    p = log_path(key)
    return [json.loads(l) for l in p.read_text().splitlines()] if p.exists() else []


def spent() -> float:
    return sum(r.get("cost", 0) or 0 for k in MODELS for r in records(k))


def cache_key(key, prompt, thumbs):
    m = MODELS[key]
    return data.response_cache_key(m[0], m[2], PROMPT_VERSION, L.MAX_SIDE, prompt, [data.file_hash(t) for t in thumbs])


def judge(key):
    def judge_window(col, a, b, allow_call=False):
        prompt, thumbs, nums = L.request(col, a, b)
        hit = cache(key).get(cache_key(key, prompt, thumbs))
        if hit is None:
            return None
        if hit.get("status") == FAILED:
            return L.neutral(nums)
        return W.parse_answer(hit["result"], nums)
    return judge_window


def image_url(path) -> str:
    from PIL import Image
    im = Image.open(path).convert("RGB")
    im.thumbnail((L.MAX_SIDE, L.MAX_SIDE), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=90)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()


class Fatal(RuntimeError):
    pass


def post(body: dict) -> dict:
    """POST with back-off on 429/5xx/network errors. Errors name the status, never the key."""
    import requests
    last = None
    for attempt in range(5):
        try:
            r = requests.post(f"{API}/chat/completions", json=body, timeout=TIMEOUT_S,
                              headers={"Authorization": f"Bearer {api_key()}", "Content-Type": "application/json"})
        except requests.RequestException as e:
            last = f"network: {type(e).__name__}"
        else:
            if r.status_code == 200:
                j = r.json()
                if "error" not in j:
                    return j
                last = f"error in body: {str(j['error'])[:300]}"
            else:
                last = f"HTTP {r.status_code}: {r.text[:300]}"
                if r.status_code != 429 and r.status_code < 500:
                    raise Fatal(last)
        time.sleep(min(120, 5 * 2 ** attempt))
    raise RuntimeError(f"gave up after 5 attempts: {last}")


def call(key, prompt, thumbs, max_tokens) -> tuple[str, dict]:
    model, _, provider, precision, *_ = MODELS[key]
    content = []
    for t in thumbs:
        content.append({"type": "image_url", "image_url": {"url": image_url(t)}})
    content.append({"type": "text", "text": prompt})
    body = {"model": model, "messages": [{"role": "user", "content": content}], "temperature": 0,
            "max_tokens": max_tokens, "reasoning": {"enabled": False}, "usage": {"include": True}}
    if provider:
        body["provider"] = {"order": [provider], "quantizations": [precision], "allow_fallbacks": False}
    t0 = time.time()
    j = post(body)
    msg = (j.get("choices") or [{}])[0].get("message") or {}
    u = j.get("usage") or {}
    return msg.get("content") or "", {"wall_s": round(time.time() - t0, 1), "provider": j.get("provider"),
                                      "prompt_tokens": u.get("prompt_tokens"), "gen_tokens": u.get("completion_tokens"),
                                      "reasoning_tokens": (u.get("completion_tokens_details") or {}).get("reasoning_tokens"),
                                      "cost": u.get("cost"), "finish": (j.get("choices") or [{}])[0].get("finish_reason")}


def collect(key, names, limit=None):
    W.refuse_test(names)
    jw = judge(key)
    jobs = [(c, a, b) for n in names for c in [data.load(n, with_exif=False)] for a, b in W.windows(len(c.pages))]
    todo = [j for j in jobs if jw(*j) is None][: limit or None]
    print(f"{key}: {len(jobs)} windows, {len(todo)} to call; item spend so far ${spent():.3f}", flush=True)
    stop, done, t0 = threading.Event(), [0], time.time()

    def work(job):
        if stop.is_set():
            return
        if spent() >= CAP_USD:
            stop.set()
            print(f"COST CAP: ${spent():.3f} >= ${CAP_USD}, stopping", flush=True)
            return
        col, a, b = job
        prompt, thumbs, nums = L.request(col, a, b)
        status, text, rec = FAILED, "", {}
        for attempt, max_tokens in enumerate((MAX_TOKENS, 2 * MAX_TOKENS)):
            try:
                text, meta = call(key, prompt, thumbs, max_tokens)
            except Fatal as e:
                stop.set()
                print(f"FATAL, stopping: {e}", flush=True)
                return
            except RuntimeError as e:
                print(f"FAILED {col.name} {nums[0]}-{nums[-1]}: {str(e)[:200]}", flush=True)
                return
            text = L.strip_thinking(text)
            rec = {"collection": col.name, "window": nums, "attempt": attempt, "model": MODELS[key][0], **meta,
                   "t": time.time()}
            try:
                W.parse_answer(text, nums)
                status = "ok"
            except W.ParseError as e:
                rec["error"] = str(e)[:200]
            rec["event"] = status
            with _log_lock:
                with open(log_path(key), "a") as fh:
                    fh.write(json.dumps(rec) + "\n")
            if status == "ok":
                break
        cache(key).put(cache_key(key, prompt, thumbs), {"status": status, "result": text, "model": MODELS[key][0],
                                                        "provider": rec.get("provider")})
        done[0] += 1
        print(f"[{done[0]}/{len(todo)} {time.time() - t0:.0f}s] {col.name} {nums[0]}-{nums[-1]} {status} "
              f"{rec.get('provider')} {rec.get('wall_s')}s ${rec.get('cost')}", flush=True)

    with cf.ThreadPoolExecutor(CONCURRENCY) as ex:
        for f in cf.as_completed([ex.submit(work, j) for j in todo]):
            f.result()
    print(f"{key}: done in {time.time() - t0:.0f}s; item spend ${spent():.3f}", flush=True)


def endpoints():
    import requests
    for key, (model, *_rest) in MODELS.items():
        r = requests.get(f"{API}/models/{model}/endpoints", timeout=60)
        if r.status_code != 200:
            print(f"{key}: {model} HTTP {r.status_code}")
            continue
        d = r.json().get("data") or {}
        print(f"{key}: {model} modalities={d.get('architecture', {}).get('input_modality') or d.get('architecture')}")
        for e in d.get("endpoints") or []:
            p = e.get("pricing") or {}
            print(f"   {e.get('provider_name'):<16} {e.get('quantization')!s:<8} in ${float(p.get('prompt', 0)) * 1e6:.3f}/M "
                  f"out ${float(p.get('completion', 0)) * 1e6:.3f}/M img {p.get('image')} ctx {e.get('context_length')} "
                  f"params={','.join(x for x in (e.get('supported_parameters') or []) if x in ('reasoning', 'temperature', 'include_reasoning'))} "
                  f"status={e.get('status')} uptime={e.get('uptime_last_30m')}")


def rows(name) -> list[str]:
    col = data.load(name)
    out = []
    for key, (model, label, provider, precision, params, gb) in MODELS.items():
        recs = [r for r in records(key) if r["collection"] == name]
        last = {}
        for r in recs:
            last[tuple(r["window"])] = r
        try:
            pred = W.assemble(col, W.combine(col, judge(key)), False)
        except RuntimeError:
            out.append(f"| {label} ({params}), OpenRouter {provider or '?'} {precision or '?'} | not collected "
                       f"({len(last)} windows run) | | | | | ~{gb} |")
            continue
        r = derived(score_labels(col.labels, pred.labels, name))
        failed = sum(1 for x in last.values() if x["event"] == FAILED)
        mean = sum(x["wall_s"] for x in recs) / max(1, len(recs))
        cost = sum(x.get("cost") or 0 for x in recs)
        out.append(f"| {label} ({params}), OpenRouter {provider} {precision} | {100 * r['pages_in_exact_doc']:.1f}% "
                   f"| {r['false_splits']} | {r['false_merges']} | {failed} | {mean:.0f} (cloud) | ~{gb} (4-bit, est.) "
                   f"| ${cost:.3f} |")
    return out


def main(argv) -> int:
    if argv and argv[0] == "endpoints":
        endpoints()
    elif len(argv) >= 2 and argv[0] == "collect" and argv[1] in MODELS:
        rest = argv[2:]
        limit = None
        if "--limit" in rest:
            i = rest.index("--limit"); limit = int(rest[i + 1]); rest = rest[:i] + rest[i + 2:]
        collect(argv[1], rest or ["Deaver"], limit)
    elif argv and argv[0] == "report":
        for name in argv[1:] or ["Deaver"]:
            W.refuse_test([name])
            print("\n".join(rows(name)))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
