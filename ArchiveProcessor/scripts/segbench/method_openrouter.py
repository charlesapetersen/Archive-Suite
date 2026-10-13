"""W41.seg-large: open-weight 27B-122B vision models over Deaver's windows, through OpenRouter.
W41.seg-cheap: the cheap cloud models over the same windows (the ``CHEAP`` set, below).

    python method_openrouter.py endpoints [cheap]              # candidate ids, providers, precisions, prices
    python method_openrouter.py collect <model> [Deaver] [--limit N]
    python method_openrouter.py report [Deaver]                # rows into segbench-results/local-models-<box>.md
    python method_openrouter.py report-cheap [Deaver]          # rows into segbench-results/cheap-models-<box>.md
    python method_openrouter.py freeze-cheap <model>...        # the finalists, frozen BEFORE any test-box call
    python method_openrouter.py estimate-five                  # what the finalists' uncached five-box windows cost
    python method_openrouter.py collect-five <model> --final   # those calls (dev boxes, then the test boxes)
    python method_openrouter.py report-five                    # each finalist on all five boxes, flagged at <= 0.85

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
spend (every model's log in the model's set summed) would pass that set's cap: CAP_USD for seg-large's,
CHEAP_CAP_USD for seg-cheap's.

THE CHEAP SET (owner, 2026-10-11, W41 question 3: do models cheaper than Gemini or Claude segment well enough?).
These are the cloud models, so they get what the cloud runs of ``cues-models-Deaver.md`` got: the images at the
bench's 1600 px (W.THUMB_PX), not the 1024 px the local-sized set was held to. Reasoning at each model's lowest
setting (OpenRouter's ``effort``), since the cheapest Gemini 3.8 Flash setting matched its highest. The provider
is the model's own maker where it serves it (precision unpublished), else one pinned build. Batch: OpenRouter's
``:batch`` (or the maker's flex tier) price, applied to each call's logged tokens, beside the standard price paid.

THE FINALISTS (``*-five``). Chosen on the Deaver screen alone and written to ``cheap-finalists.json``, committed
before any test-box call: ``collect-five`` refuses Stanton and RG 165 without it, as ``options.py`` does. Then
each finalist runs on all five boxes and is scored as ``ensemble-test.md`` scored its voters: truth photo labels,
the development boxes and the test boxes reported apart, and review as option F did it, a lone model with every
gap it is 85% sure of or less flagged and corrected (LEVEL, fixed in advance, not fitted). Gemini 3.8 Flash's
cached windows (options.py's voter G) are scored the same way beside them, at no cost.
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
# key: (OpenRouter id, label, pinned provider, its precision or None, reasoning effort or None,
#       batch price in and out per million tokens or None). Prices and providers from ``endpoints cheap``, 2026-10-13.
CHEAP_CAP_USD = 2.00   # the Deaver screen
ITEM_CAP_USD = 3.00    # seg-cheap in total, the five-box run included: past it the owner is asked first
CHEAP = {
    "gemini3.5-flash-lite": ("google/gemini-3.5-flash-lite", "Gemini 3.5 Flash-Lite", "google-ai-studio", None, "minimal", (0.15, 1.25)),
    "gpt5.6-luna": ("openai/gpt-5.6-luna", "GPT-5.6 Luna", "openai", None, "minimal", (0.10, 0.60)),
    "gpt5.4-nano": ("openai/gpt-5.4-nano", "GPT-5.4 Nano", "openai", None, "minimal", (0.10, 0.625)),
    "gpt5.4-mini": ("openai/gpt-5.4-mini", "GPT-5.4 Mini", "openai", None, "minimal", (0.375, 2.25)),
    "glm5.3-flash": ("z-ai/glm-5.3-flash", "GLM-5.3 Flash", "z-ai", "fp8", "minimal", (0.06, 0.20)),
    "qwen3.5-flash": ("qwen/qwen3.5-flash-02-23", "Qwen3.5 Flash", "alibaba", None, "none", None),
    "qwen3.6-flash": ("qwen/qwen3.6-flash", "Qwen3.6 Flash", "alibaba", None, "none", None),
    "mistral-small": ("mistralai/mistral-small-2603", "Mistral Small (2603)", "mistral", None, "none", (0.075, 0.30)),
    "gemma4-26b-a4b": ("google/gemma-4-26b-a4b-it", "Gemma 4 26B-A4B", "dekallm", "bf16", "none", None),
    "llama4-maverick": ("meta-llama/llama-4-maverick", "Llama 4 Maverick", "novita", "fp8", None, None),
    # the known point, re-run on this route to show what the route itself moves (72.3% through the Gemini API)
    "gemini3.1-flash-lite": ("google/gemini-3.1-flash-lite", "Gemini 3.1 Flash-Lite", "google-ai-studio", None, "minimal", (0.125, 0.75)),
}
FAILED = L.FAILED


def entry(key):
    return MODELS.get(key) or CHEAP[key]


def models_of(key):
    return CHEAP if key in CHEAP else MODELS


def cap_of(key):
    return CHEAP_CAP_USD if key in CHEAP else CAP_USD


def side_of(key):
    return W.THUMB_PX if key in CHEAP else L.MAX_SIDE

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


def spent(table=None) -> float:
    return sum(r.get("cost", 0) or 0 for k in (MODELS if table is None else table) for r in records(k))


def cache_key(key, prompt, thumbs):
    m = entry(key)
    hashes = [data.file_hash(t) for t in thumbs]
    if key in CHEAP:
        return data.response_cache_key(m[0], m[2], m[3], m[4], PROMPT_VERSION, W.THUMB_PX, prompt, hashes)
    return data.response_cache_key(m[0], m[2], PROMPT_VERSION, L.MAX_SIDE, prompt, hashes)


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


def image_url(path, side=L.MAX_SIDE) -> str:
    from PIL import Image
    im = Image.open(path).convert("RGB")
    im.thumbnail((side, side), Image.LANCZOS)
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
    model, _, provider, precision, *rest = entry(key)
    content = []
    for t in thumbs:
        content.append({"type": "image_url", "image_url": {"url": image_url(t, side_of(key))}})
    content.append({"type": "text", "text": prompt})
    body = {"model": model, "messages": [{"role": "user", "content": content}], "temperature": 0,
            "max_tokens": max_tokens, "reasoning": {"enabled": False}, "usage": {"include": True}}
    if key in CHEAP:
        effort = rest[0]
        if effort is None:
            body.pop("reasoning")
        else:
            body["reasoning"] = {"effort": effort, "exclude": True}
    if provider:
        body["provider"] = {"order": [provider], "allow_fallbacks": False}
        if precision:
            body["provider"]["quantizations"] = [precision]
    t0 = time.time()
    j = post(body)
    msg = (j.get("choices") or [{}])[0].get("message") or {}
    u = j.get("usage") or {}
    return msg.get("content") or "", {"wall_s": round(time.time() - t0, 1), "provider": j.get("provider"),
                                      "prompt_tokens": u.get("prompt_tokens"), "gen_tokens": u.get("completion_tokens"),
                                      "reasoning_tokens": (u.get("completion_tokens_details") or {}).get("reasoning_tokens"),
                                      "cost": u.get("cost"), "finish": (j.get("choices") or [{}])[0].get("finish_reason")}


def collect(key, names, limit=None, final=False):
    if final:
        if key not in finalists():
            raise SystemExit(f"{key} is not a frozen finalist ({CHEAP_FROZEN.name})")
    else:
        W.refuse_test(names)
    jw = judge(key)
    jobs = [(c, a, b) for n in names for c in [data.load(n, with_exif=False)] for a, b in W.windows(len(c.pages))]
    todo = [j for j in jobs if jw(*j) is None][: limit or None]
    table, cap = models_of(key), (ITEM_CAP_USD if final else cap_of(key))
    print(f"{key}: {len(jobs)} windows, {len(todo)} to call; item spend so far ${spent(table):.3f}", flush=True)
    stop, done, t0 = threading.Event(), [0], time.time()

    def work(job):
        if stop.is_set():
            return
        if spent(table) >= cap:
            stop.set()
            print(f"COST CAP: ${spent(table):.3f} >= ${cap}, stopping", flush=True)
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
            rec = {"collection": col.name, "window": nums, "attempt": attempt, "model": entry(key)[0], **meta,
                   "t": time.time()}
            try:
                W.parse_answer(text, nums)
                status = "ok"
            except (W.ParseError, TypeError, ValueError, KeyError, AttributeError) as e:
                # a malformed answer (e.g. a null confidence raises TypeError in parse_answer) is unparsed
                rec["error"] = f"{type(e).__name__}: {e}"[:200]
            rec["event"] = status
            with _log_lock:
                with open(log_path(key), "a") as fh:
                    fh.write(json.dumps(rec) + "\n")
            if status == "ok":
                break
        cache(key).put(cache_key(key, prompt, thumbs), {"status": status, "result": text, "model": entry(key)[0],
                                                        "provider": rec.get("provider")})
        done[0] += 1
        print(f"[{done[0]}/{len(todo)} {time.time() - t0:.0f}s] {col.name} {nums[0]}-{nums[-1]} {status} "
              f"{rec.get('provider')} {rec.get('wall_s')}s ${rec.get('cost')}", flush=True)

    with cf.ThreadPoolExecutor(CONCURRENCY) as ex:
        for f in cf.as_completed([ex.submit(work, j) for j in todo]):
            f.result()
    print(f"{key}: done in {time.time() - t0:.0f}s; item spend ${spent(table):.3f}", flush=True)


def endpoints(table=MODELS):
    import requests
    for key, (model, *_rest) in table.items():
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


RESULTS = data.HERE.parent.parent / "segbench-results"
CHEAP_FROZEN = RESULTS / "cheap-finalists.json"
LEVEL = 0.85
FIVE = data.DEV + data.TEST


def finalists() -> list[str]:
    if not CHEAP_FROZEN.exists():
        raise SystemExit("no freeze: run `freeze-cheap <model>...` and commit cheap-finalists.json first")
    return json.loads(CHEAP_FROZEN.read_text())["finalists"]


def freeze_cheap(keys) -> None:
    bad = [k for k in keys if k not in CHEAP]
    if bad or not keys:
        raise SystemExit(f"not cheap-set models: {bad}")
    if CHEAP_FROZEN.exists():
        raise SystemExit(f"{CHEAP_FROZEN.name} exists; the freeze is written once")
    CHEAP_FROZEN.write_text(json.dumps({"finalists": keys, "level": LEVEL, "chosen_on": "Deaver",
                                        "frozen": time.strftime("%Y-%m-%d %H:%M"),
                                        "rule": "within about two points of Gemini 3.8 Flash's 97.9% on Deaver "
                                                "at a lower cost per 1,000 pages (SUITE_TODO W41.seg-cheap)"},
                                       indent=1) + "\n")
    print(f"wrote {CHEAP_FROZEN}")


def five_jobs(key):
    jw = judge(key)
    return [(c, a, b) for n in FIVE for c in [data.load(n, with_exif=False)] for a, b in W.windows(len(c.pages))
            if jw(c, a, b) is None]


def estimate_five() -> float:
    total = 0.0
    for key in finalists():
        recs = [r for r in records(key) if r["collection"] == "Deaver"]
        per_window = sum(r.get("cost") or 0 for r in recs) / max(1, len({tuple(r["window"]) for r in recs}))
        todo = five_jobs(key)
        total += per_window * len(todo)
        print(f"{key}: {len(todo)} uncached windows x ${per_window:.4f} (Deaver's mean) = ${per_window * len(todo):.2f}")
    print(f"estimate ${total:.2f}; seg-cheap spent so far ${spent(CHEAP):.3f}; total ${total + spent(CHEAP):.2f}")
    return total


def five_box(codes):
    """ensemble.Box per collection, with the cheap models as voters "X:<key>" beside options.py's G."""
    import ensemble as E
    import options  # noqa: F401  (installs voter G on E.voter_gaps)
    base = E.voter_gaps

    def voter_gaps(code, col):
        if code.startswith("X:"):
            return E._from_bounds(col, W.assemble(col, W.combine(col, judge(code[2:])), True))
        return base(code, col)
    E.voter_gaps = voter_gaps
    try:
        return E, {n: E.Box(data.load(n), codes) for n in FIVE}
    finally:
        E.voter_gaps = base


def collected_everywhere(key) -> bool:
    return not five_jobs(key)


def report_five() -> str:
    keys = [k for k in finalists() if collected_everywhere(k)]
    codes = ["G"] + [f"X:{k}" for k in keys]
    E, boxes = five_box(codes)
    label = {"G": "Gemini 3.8 Flash (low), the bar", **{f"X:{k}": CHEAP[k][1] for k in keys}}
    lines = ["| model | boxes | pages | no checking | flagged | per 100 pages | after checking | unflagged errors "
             "| reaches 99% |", "|---|---|---:|---:|---:|---:|---:|---:|---|"]
    for c in codes:
        for split, names in (("dev", data.DEV), ("test", data.TEST)):
            rows = [E.evaluate(boxes[n], (c,), LEVEL) for n in names]
            for n, r in zip(names, rows):
                lines.append(f"| {label[c]} | {n} | {r['pages']} | {100 * E.pe(r['auto']):.1f}% | {r['flagged']} "
                             f"| {100 * r['flagged'] / r['pages']:.1f} | {100 * E.pe(r['rev']):.1f}% | {r['acc_err']} | |")
            p = E.pooled(rows)
            lines.append(f"| {label[c]} | **{split} pooled** | {p['pages']} | {100 * E.pe(p['auto']):.1f}% "
                         f"| {p['flagged']} | {100 * p['flagged'] / p['pages']:.1f} | {100 * E.pe(p['rev']):.1f}% "
                         f"| {p['acc_err']} | {'yes' if E.pe(p['rev']) >= 0.99 else 'no'} |")
    cost = ["", "| model | pages | calls | cost paid | per 1,000 pages, standard | per 1,000 pages, batch |",
            "|---|---:|---:|---:|---:|---:|"]
    pages = sum(boxes[n].pages for n in FIVE)
    for k in keys:
        recs = [r for r in records(k) if r["collection"] in FIVE]
        paid = sum(r.get("cost") or 0 for r in recs)
        b = CHEAP[k][5]
        bk = (f"${1000 * sum((r.get('prompt_tokens') or 0) * b[0] + (r.get('gen_tokens') or 0) * b[1] for r in recs) / 1e6 / pages:.2f}"
              if b else "none offered")
        cost.append(f"| {CHEAP[k][1]} | {pages} | {len(recs)} | ${paid:.3f} | ${1000 * paid / pages:.2f} | {bk} |")
    # The fixed 0.85 is Claude's fitted level; models whose confidences run higher flag little at it. So, as
    # options.py fitted each approach: the level held out per development box (fitted on the other two), and
    # for the test boxes the level fitted on all three, at the item's 99% and at options.py's 98% bar.
    fit = ["", "| model | bar | dev, held out: after checking | flagged per 100 pages | level for the test boxes "
           "| test: no checking | after checking | flagged per 100 pages | unflagged errors |",
           "|---|---|---:|---:|---|---:|---:|---:|---:|"]
    dev = {n: boxes[n] for n in data.DEV}
    bar0 = E.BAR
    try:
        for c in codes:
            for bar in (0.99, 0.98):
                E.BAR = bar
                lo = E.loco(dev, (c,))["pooled"]
                v = E.fit_level(list(dev.values()), (c,))
                t = E.pooled([E.evaluate(boxes[n], (c,), 2.0 if v is None else v) for n in data.TEST])
                lv = "flag all" if v is None or v >= 1 else ("unanimity" if v < 0 else f"<= {v:.3f}")
                fit.append(f"| {label[c]} | {100 * bar:.0f}% | {100 * E.pe(lo['rev']):.1f}% "
                           f"| {100 * lo['flagged'] / lo['pages']:.1f} | {lv} | {100 * E.pe(t['auto']):.1f}% "
                           f"| {100 * E.pe(t['rev']):.1f}% | {100 * t['flagged'] / t['pages']:.1f} | {t['acc_err']} |")
    finally:
        E.BAR = bar0
    waiting = [CHEAP[k][1] for k in finalists() if k not in keys]
    note = [f"", f"Not yet run on all five boxes: {', '.join(waiting)}."] if waiting else []
    return "\n".join(lines + fit + cost + note)


def cheap_rows(name) -> list[str]:
    """One row per cheap model: score, cost paid, and cost per 1,000 pages at the standard and batch prices."""
    col = data.load(name)
    n_pages = len(col.pages)
    out = []
    for key, (model, label, provider, precision, effort, batch) in CHEAP.items():
        recs = [r for r in records(key) if r["collection"] == name]
        last = {}
        for r in recs:
            last[tuple(r["window"])] = r
        route = f"{provider}{' ' + precision if precision else ''}, reasoning {effort or 'n/a'}"
        try:
            pred = W.assemble(col, W.combine(col, judge(key)), False)
        except RuntimeError:
            out.append(f"| {label} | {route} | not collected ({len(last)} windows run) | | | | | | | |")
            continue
        r = derived(score_labels(col.labels, pred.labels, name))
        failed = sum(1 for x in last.values() if x["event"] == FAILED)
        cost = sum(x.get("cost") or 0 for x in recs)
        reasoning = sum(x.get("reasoning_tokens") or 0 for x in recs) / max(1, len(recs))
        per_k = 1000 * cost / n_pages
        if batch:
            b = sum((x.get("prompt_tokens") or 0) * batch[0] + (x.get("gen_tokens") or 0) * batch[1] for x in recs) / 1e6
            batch_k = f"${1000 * b / n_pages:.2f}"
        else:
            batch_k = "none offered"
        out.append(f"| {label} | {route} | {100 * r['pages_in_exact_doc']:.1f}% | {r['false_splits']} "
                   f"| {r['false_merges']} | {failed} | {reasoning:.0f} | ${cost:.3f} | ${per_k:.2f} | {batch_k} |")
    return out


def main(argv) -> int:
    if argv and argv[0] == "endpoints":
        endpoints(CHEAP if argv[1:] == ["cheap"] else MODELS)
    elif len(argv) >= 2 and argv[0] == "freeze-cheap":
        freeze_cheap(argv[1:])
    elif argv and argv[0] == "estimate-five":
        estimate_five()
    elif len(argv) >= 2 and argv[0] == "collect-five":
        if "--final" not in argv:
            raise SystemExit("collect-five calls the test boxes: pass --final once cheap-finalists.json is committed")
        collect(argv[1], list(FIVE), final=True)
    elif argv and argv[0] == "report-five":
        print(report_five())
    elif argv and argv[0] == "report-cheap":
        for name in argv[1:] or ["Deaver"]:
            W.refuse_test([name])
            print("\n".join(cheap_rows(name)))
    elif len(argv) >= 2 and argv[0] == "collect" and (argv[1] in MODELS or argv[1] in CHEAP):
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
