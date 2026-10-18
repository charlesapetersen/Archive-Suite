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
    python method_openrouter.py option-glm                     # GLM-5.3 Flash as an approach in options.json
    python method_openrouter.py option-local-seg               # the corpus-trained 2B as the `local` approach
    SEGBENCH_OR_API=http://127.0.0.1:8000/v1 python method_openrouter.py collect fs-qwen3.5-27b   # a local server

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
LOCAL_API = __import__("os").environ.get("SEGBENCH_OR_API", "").rstrip("/")  # FARMSHARE keys only (below)
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
ITEM_CAP_USD = 4.57    # seg-cheap in total, the five-box run included; owner approved $4.57 on 2026-10-13, past it ask first
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
# W41.farmshare-seg: the same windows against a local OpenAI-compatible server (vLLM on a FarmShare L40S), the
# seg-large request otherwise unchanged: 1024 px images, temperature 0, thinking off through the chat template
# (vLLM has no OpenRouter ``reasoning`` field), no provider, no key, no money. ``SEGBENCH_OR_API`` is where these
# keys' requests go, and only theirs: every other key, and every other caller of ``post``, stays on OpenRouter. On
# FarmShare the node cannot reach the Mac's thumbnails, so institutional-compute/cluster_seg.py packs these exact requests on the
# Mac, sends them on the node and imports the answers into this key's cache and log.
# key: (served model name, label, where, precision, parameters, local 4-bit GB)
FARMSHARE = {
    "fs-qwen3.5-27b": ("Qwen/Qwen3.5-27B-FP8", "Qwen3.5 27B", "FarmShare L40S vLLM", "fp8", "27B dense", 17),
    # W41.seg-finetune: the students, served by name (models.sh seg-student), and their untrained bases as baselines
    "fs-qwen3.5-4b": ("Qwen/Qwen3.5-4B", "Qwen3.5 4B, untrained", "FarmShare L40S vLLM", "bf16", "4B dense", 3),
    "fs-qwen3.5-2b": ("Qwen/Qwen3.5-2B", "Qwen3.5 2B, untrained", "FarmShare L40S vLLM", "bf16", "2B dense", 1.5),
    "fs-seg-4b-pilot": ("seg-4b-pilot", "Qwen3.5 4B, fine-tuned on a quarter of the corpus (pilot)",
                        "FarmShare L40S vLLM", "bf16", "4B dense", 3),
    "fs-seg-4b": ("seg-4b", "Qwen3.5 4B, fine-tuned", "FarmShare L40S vLLM", "bf16", "4B dense", 3),
    "fs-seg-2b": ("seg-2b", "Qwen3.5 2B, fine-tuned", "FarmShare L40S vLLM", "bf16", "2B dense", 1.5),
}


def entry(key):
    return MODELS.get(key) or FARMSHARE.get(key) or CHEAP[key]


def models_of(key):
    return CHEAP if key in CHEAP else FARMSHARE if key in FARMSHARE else MODELS


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
    if key in FARMSHARE:
        return data.response_cache_key(m[0], "farmshare", PROMPT_VERSION, L.MAX_SIDE, prompt, hashes)
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


def image_jpeg(path, side=L.MAX_SIDE) -> bytes:
    from PIL import Image
    im = Image.open(path).convert("RGB")
    im.thumbnail((side, side), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=90)
    return buf.getvalue()


def data_url(jpeg: bytes) -> str:
    return "data:image/jpeg;base64," + base64.b64encode(jpeg).decode()


def image_url(path, side=L.MAX_SIDE) -> str:
    return data_url(image_jpeg(path, side))


class Fatal(RuntimeError):
    pass


def api_of(key) -> str:
    """A FarmShare key goes to the local server and only there; every other key to OpenRouter."""
    if key not in FARMSHARE:
        return API
    if not LOCAL_API:
        raise SystemExit(f"{key} needs SEGBENCH_OR_API=<an OpenAI-compatible server>/v1")
    return LOCAL_API


def post(body: dict, api=API) -> dict:
    """POST with back-off on 429/5xx/network errors. Errors name the status, never the key, which is sent to
    OpenRouter alone."""
    import requests
    last = None
    headers = {"Content-Type": "application/json"}
    if api == API:
        headers["Authorization"] = f"Bearer {api_key()}"
    for attempt in range(5):
        try:
            r = requests.post(f"{api}/chat/completions", json=body, timeout=TIMEOUT_S, headers=headers)
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


def request_body(key, prompt, urls, max_tokens) -> dict:
    """The chat request for one window; ``urls`` are the images' data URLs in page order."""
    model, _, provider, precision, *rest = entry(key)
    content = [{"type": "image_url", "image_url": {"url": u}} for u in urls]
    content.append({"type": "text", "text": prompt})
    body = {"model": model, "messages": [{"role": "user", "content": content}], "temperature": 0,
            "max_tokens": max_tokens, "reasoning": {"enabled": False}, "usage": {"include": True}}
    if key in FARMSHARE:
        del body["reasoning"], body["usage"]
        body["chat_template_kwargs"] = {"enable_thinking": False}  # Qwen3.5's template honours the switch
        return body
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
    return body


def call(key, prompt, thumbs, max_tokens) -> tuple[str, dict]:
    body = request_body(key, prompt, [image_url(t, side_of(key)) for t in thumbs], max_tokens)
    t0 = time.time()
    j = post(body, api_of(key))
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
    api_of(key)
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
    for key, (model, label, provider, precision, params, gb) in {**MODELS, **FARMSHARE}.items():
        route, where = (provider, "L40S") if key in FARMSHARE else (f"OpenRouter {provider}", "cloud")
        recs = [r for r in records(key) if r["collection"] == name]
        if key in FARMSHARE and not recs:
            continue  # not run on FarmShare: no row, rather than a "not collected" one in every report
        last = {}
        for r in recs:
            last[tuple(r["window"])] = r
        try:
            pred = W.assemble(col, W.combine(col, judge(key)), False)
        except RuntimeError:
            out.append(f"| {label} ({params}), {route} {precision or '?'} | not collected "
                       f"({len(last)} windows run) | | | | | ~{gb} |")
            continue
        r = derived(score_labels(col.labels, pred.labels, name))
        failed = sum(1 for x in last.values() if x["event"] == FAILED)
        mean = sum(x["wall_s"] for x in recs) / max(1, len(recs))
        cost = sum(x.get("cost") or 0 for x in recs)
        out.append(f"| {label} ({params}), {route} {precision} | {100 * r['pages_in_exact_doc']:.1f}% "
                   f"| {r['false_splits']} | {r['false_merges']} | {failed} | {mean:.0f} ({where}) | ~{gb} (4-bit, est.) "
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


# W41.seg-27b-test: the FarmShare teacher, frozen the same way before its one test-box run (cluster_seg.py pack --final).
TEACHER_FROZEN = RESULTS / "seg-teacher.json"


def freeze_teacher(key) -> None:
    if key not in FARMSHARE:
        raise SystemExit(f"not a FarmShare key: {key}")
    if TEACHER_FROZEN.exists():
        raise SystemExit(f"{TEACHER_FROZEN.name} exists; the freeze is written once")
    TEACHER_FROZEN.write_text(json.dumps({"teacher": key, "level": LEVEL, "chosen_on": "Deaver",
                                          "frozen": time.strftime("%Y-%m-%d %H:%M"),
                                          "rule": "the open-weight model that cleans the corpus labels for the Mac "
                                                  "segmenter (SUITE_TODO W41.seg-27b-test); fixed on Deaver, "
                                                  "where it scored 96.5% of pages in the exact document"},
                                         indent=1) + "\n")
    print(f"wrote {TEACHER_FROZEN}")


def committed(path) -> dict:
    """A freeze file's contents, only while it is committed unchanged (git), as the test boxes require."""
    root = data.HERE.parent.parent.parent
    rel = path.relative_to(root)
    tracked = subprocess.run(["git", "-C", str(root), "ls-files", "--error-unmatch", str(rel)], capture_output=True)
    clean = subprocess.run(["git", "-C", str(root), "diff", "--quiet", "HEAD", "--", str(rel)])
    if tracked.returncode or clean.returncode:
        raise SystemExit(f"{rel} is not committed as it stands; commit the freeze before any test-box call")
    return json.loads(path.read_text())


def teacher() -> str:
    """The frozen teacher's key, only once its freeze is committed unchanged."""
    if not TEACHER_FROZEN.exists():
        raise SystemExit("no freeze: run `freeze-teacher <key>` and commit seg-teacher.json first")
    return committed(TEACHER_FROZEN)["teacher"]


# W41.seg-finetune: the students, frozen on the development boxes and the held-out collections before their one
# test-box run, as the teacher was.
STUDENTS_FROZEN = RESULTS / "seg-students.json"


def freeze_students(keys) -> None:
    bad = [k for k in keys if k not in FARMSHARE]
    if bad or not keys:
        raise SystemExit(f"not FarmShare keys: {bad}")
    if STUDENTS_FROZEN.exists():
        raise SystemExit(f"{STUDENTS_FROZEN.name} exists; the freeze is written once")
    STUDENTS_FROZEN.write_text(json.dumps({
        "students": keys, "level": LEVEL, "chosen_on": "Dean, Deaver, Herrnstein and the corpus's held-out collections",
        "frozen": time.strftime("%Y-%m-%d %H:%M"),
        "rule": "the two fine-tuned segmenters a Mac would run (SUITE_TODO W41.seg-finetune): the 4B for 16 GB, the "
                "2B for 8 GB; trained on the cleaned corpus windows, no test-box page seen"}, indent=1) + "\n")
    print(f"wrote {STUDENTS_FROZEN}")


def frozen_keys() -> list[str]:
    """Every key frozen for the test boxes (the teacher and the students), each freeze committed unchanged."""
    keys = []
    if TEACHER_FROZEN.exists():
        keys.append(committed(TEACHER_FROZEN)["teacher"])
    if STUDENTS_FROZEN.exists():
        keys += committed(STUDENTS_FROZEN)["students"]
    if not keys:
        raise SystemExit("no freeze: run `freeze-teacher <key>` or `freeze-students <key>...` and commit it first")
    return keys


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


def report_five(wanted=None) -> str:
    wanted = finalists() if wanted is None else wanted
    keys = [k for k in wanted if collected_everywhere(k)]
    codes = ["G"] + [f"X:{k}" for k in keys]
    E, boxes = five_box(codes)
    label = {"G": "Gemini 3.8 Flash (low), the bar", **{f"X:{k}": entry(k)[1] for k in keys}}
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
        b = CHEAP[k][5] if k in CHEAP else None
        bk = (f"${1000 * sum((r.get('prompt_tokens') or 0) * b[0] + (r.get('gen_tokens') or 0) * b[1] for r in recs) / 1e6 / pages:.2f}"
              if b else "none offered")
        cost.append(f"| {entry(k)[1]} | {pages} | {len(recs)} | ${paid:.3f} | ${1000 * paid / pages:.2f} | {bk} |")
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
    waiting = [entry(k)[1] for k in wanted if k not in keys]
    note = [f"", f"Not yet run on all five boxes: {', '.join(waiting)}."] if waiting else []
    return "\n".join(lines + fit + cost + note)


# W41.app-openrouter: GLM-5.3 Flash offered by the Processor as the budget approach, so options.json carries it
# the way options.py carries every approach. No new calls: the cached five-box windows, the level fitted on the
# development boxes at options.py's 98% bar (report-five's "fitted per model" table, which reproduced Gemini's
# options.md row), the test boxes scored at it. Tokens and dollars from the logged calls at the pinned endpoint's
# price; no batch price, because the app has no OpenRouter batch route.
GLM_KEY = "glm5.3-flash"
GLM_CODE = "Z"
GLM_VOTER = "window-openrouter-glm-5.3-flash (GLM-5.3 Flash on OpenRouter, z-ai fp8, reasoning minimal, prompt c1)"
GLM_PRICE = {"in": 0.15, "out": 0.50, "read": "2026-10-13",
             "source": "OpenRouter z-ai endpoint; 312 of the 313 logged five-box calls cost exactly this"}


def option_glm() -> dict:
    import options as O
    E, boxes = five_box(["G", f"X:{GLM_KEY}"])
    code = (f"X:{GLM_KEY}",)
    dev = {n: boxes[n] for n in data.DEV}
    out = json.loads(O.OUT_JSON.read_text())
    bar0 = E.BAR
    try:
        E.BAR = out["bar_after_review"]
        # The check on this path: Gemini's row, fitted and scored here, must equal the one options.py wrote.
        gv = E.fit_level(list(dev.values()), ("G",))
        g = O.figures(E.pooled([E.evaluate(boxes[n], ("G",), gv) for n in data.TEST]))
        shipped = next(a for a in out["approaches"] if a["id"] == "gemini")
        if round(gv, 6) != round(shipped["level"], 6) or g != shipped["figures"]["test"]:
            raise SystemExit(f"this path does not reproduce options.json's gemini row: {gv} {g}")
        v = E.fit_level(list(dev.values()), code)
        if v is None or not 0 < v < 1:
            raise SystemExit(f"no usable level for GLM at the {out['bar_after_review']} bar: {v}")
        lo = E.loco(dev, code)["pooled"]
        per = [E.evaluate(boxes[n], code, v) | {"name": n} for n in data.TEST]
    finally:
        E.BAR = bar0
    p = E.pooled(per)
    recs = [r for r in records(GLM_KEY) if r["collection"] in FIVE]
    pages = sum(boxes[n].pages for n in FIVE)
    tin = 1000 * sum(r.get("prompt_tokens") or 0 for r in recs) / pages
    tout = 1000 * sum(r.get("gen_tokens") or 0 for r in recs) / pages
    usd = (tin * GLM_PRICE["in"] + tout * GLM_PRICE["out"]) / 1e6
    entry = {
        "id": "glm", "label": "GLM-5.3 Flash only (budget)", "available": True, "voters": [GLM_VOTER],
        "rule": "min", "level": v, "flag_rule": "flag a gap whose confidence is at or below the level",
        "figures": {"test": O.figures(p), "test_by_box": {r["name"]: O.figures(r) for r in per},
                    "dev_held_out": O.figures(lo)},
        "tokens_per_1000_pages": {GLM_CODE: {
            "model": CHEAP[GLM_KEY][0], "provider": CHEAP[GLM_KEY][2], "precision": CHEAP[GLM_KEY][3],
            "reasoning": CHEAP[GLM_KEY][4], "boxes": sorted(FIVE), "pages": pages, "calls": len(recs),
            "input_per_1000_pages": tin, "output_per_1000_pages": tout,
            "spent_usd": sum(r.get("cost") or 0 for r in recs),
            "how": "the usage OpenRouter returned on every logged call, retries and parse failures included"}},
        "cost": {"per_model": {GLM_CODE: {"list_usd_per_1000_pages": usd, "batch_usd_per_1000_pages": None,
                                          "prices_usd_per_mtok": {"in": GLM_PRICE["in"], "out": GLM_PRICE["out"]},
                                          "price_read": GLM_PRICE["read"], "price_source": GLM_PRICE["source"]}},
                 "total": {"list_usd_per_1000_pages": usd, "batch_usd_per_1000_pages": None}},
        "note": "W41.seg-cheap (cheap-models.md): the budget option for a user who checks everything flagged; "
                "Gemini 3.8 Flash stays the better approach. Measured through method_openrouter.py, scored here "
                "by `option-glm`."}
    out["approaches"] = [a for a in out["approaches"] if a["id"] != "glm"] + [entry]
    out["glm_measured"] = {"date": "2026-10-14", "item": "W41.seg-cheap-more", "added": "W41.app-openrouter"}
    O.OUT_JSON.write_text(json.dumps(out, indent=1) + "\n")
    O.OUT_MD.write_text(O.render(out))
    return entry


# W41.app-local-seg: the corpus-trained 2B as the `local` approach. Scored as `option-glm` scores GLM: the level fitted
# on the development boxes at options.json's bar, the test boxes scored at it, from the full-precision FarmShare run
# (`fs-seg-2b`; the test boxes were scored once, there). The Mac's 8-bit build matched it on the development boxes
# (90.3% against 90.5%, seg-students.md §On the Mac). No money: the cost is zero, with the tokens the run logged.
LOCAL_SEG_KEY = "fs-seg-2b"
LOCAL_SEG_CODE = "L"
LOCAL_SEG_VOTER = ("window-local-seg-2b (Qwen3.5 2B fine-tuned on the owner's corpus, 8-bit MLX on this Mac, "
                   "thinking off, prompt c1)")
# The voter's model id in WindowVoter.catalog (SegmentationApproach.swift). It names the build, not where it is
# downloaded from: the app sends the repository the user's setting names (LocalSegmenter.modelID).
LOCAL_SEG_MODEL = "seg-qwen3.5-2b-8bit"


def option_local_seg() -> dict:
    import options as O
    E, boxes = five_box([f"X:{LOCAL_SEG_KEY}"])
    code = (f"X:{LOCAL_SEG_KEY}",)
    dev = {n: boxes[n] for n in data.DEV}
    out = json.loads(O.OUT_JSON.read_text())
    bar0 = E.BAR
    try:
        E.BAR = out["bar_after_review"]
        v = E.fit_level(list(dev.values()), code)
        if v is None or not 0 < v < 1:
            raise SystemExit(f"no usable level for the 2B at the {out['bar_after_review']} bar: {v}")
        lo = E.loco(dev, code)["pooled"]
        per = [E.evaluate(boxes[n], code, v) | {"name": n} for n in data.TEST]
    finally:
        E.BAR = bar0
    p = E.pooled(per)
    recs = [r for r in records(LOCAL_SEG_KEY) if r["collection"] in FIVE]
    pages = sum(boxes[n].pages for n in FIVE)
    tin = 1000 * sum(r.get("prompt_tokens") or 0 for r in recs) / pages
    tout = 1000 * sum(r.get("gen_tokens") or 0 for r in recs) / pages
    entry = {
        "id": "local", "label": "Corpus-trained Qwen3.5 2B on this Mac (no key)", "available": True,
        "voters": [LOCAL_SEG_VOTER],
        "rule": "min", "level": v, "flag_rule": "flag a gap whose confidence is at or below the level",
        "figures": {"test": O.figures(p), "test_by_box": {r["name"]: O.figures(r) for r in per},
                    "dev_held_out": O.figures(lo)},
        "tokens_per_1000_pages": {LOCAL_SEG_CODE: {
            "model": LOCAL_SEG_MODEL, "provider": "this Mac (mlx-vlm)", "precision": "8-bit MLX (scored at bf16)",
            "reasoning": "off", "boxes": sorted(FIVE), "pages": pages, "calls": len(recs),
            "input_per_1000_pages": tin, "output_per_1000_pages": tout, "spent_usd": 0,
            "how": "the usage vLLM returned on every logged FarmShare call of the bf16 model"}},
        "cost": {"per_model": {LOCAL_SEG_CODE: {"list_usd_per_1000_pages": 0.0, "batch_usd_per_1000_pages": None,
                                                "price_source": "runs on this Mac; no provider is paid"}},
                 "total": {"list_usd_per_1000_pages": 0.0, "batch_usd_per_1000_pages": None}},
        "mac": {"build": "8-bit MLX (9.6 bits a weight)", "download_gb": 2.5, "peak_memory_gb": 4.4,
                "seconds_per_window": 18, "seconds_per_page": 6, "measured_on": "18 GB M3 Pro",
                "thumbnail_long_edge_px": 1024,
                "dev_pooled_pages_exact_no_review": 0.903, "dev_pooled_bf16": 0.905,
                "source": "seg-students.md §On the Mac (W41.seg-mac-model)"},
        "note": "W41.seg-finetune and W41.seg-mac-model (seg-students.md): trained on one owner's archives (no test-box "
                "page seen); its confidences make no useful flag, so the review asks about most gaps. A no-key, "
                "no-cost first draft whose boundaries the user skims. Scored here by `option-local-seg`."}
    out["approaches"] = [a for a in out["approaches"] if a["id"] != "local"] + [entry]
    out["local_measured"] = {"date": "2026-10-17", "item": "W41.seg-finetune", "added": "W41.app-local-seg"}
    O.OUT_JSON.write_text(json.dumps(out, indent=1) + "\n")
    O.OUT_MD.write_text(O.render(out))
    return entry


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
    elif argv and argv[0] == "option-glm":
        e = option_glm()
        t = e["figures"]["test"]
        print(f"glm: level {e['level']:.3f}, test {100 * t['pages_exact_no_review']:.1f}% no checking, "
              f"{t['flagged_per_100_pages']:.1f} per 100 pages, {100 * t['pages_exact_after_review']:.1f}% after, "
              f"{t['unflagged_errors']} unflagged, ${e['cost']['total']['list_usd_per_1000_pages']:.2f} per 1,000")
    elif argv and argv[0] == "option-local-seg":
        e = option_local_seg()
        t = e["figures"]["test"]
        print(f"local: level {e['level']:.3f}, test {100 * t['pages_exact_no_review']:.1f}% no checking, "
              f"{t['flagged_per_100_pages']:.1f} per 100 pages, {100 * t['pages_exact_after_review']:.1f}% after, "
              f"{t['unflagged_errors']} unflagged")
    elif len(argv) == 2 and argv[0] == "freeze-teacher":
        freeze_teacher(argv[1])
    elif argv and argv[0] == "report-teacher":
        print(report_five([teacher()]))
    elif len(argv) >= 2 and argv[0] == "freeze-students":
        freeze_students(argv[1:])
    elif argv and argv[0] == "report-students":
        print(report_five(committed(STUDENTS_FROZEN)["students"]))
    elif argv and argv[0] == "report-cheap":
        for name in argv[1:] or ["Deaver"]:
            W.refuse_test([name])
            print("\n".join(cheap_rows(name)))
    elif len(argv) >= 2 and argv[0] == "collect" and (argv[1] in MODELS or argv[1] in CHEAP or argv[1] in FARMSHARE):
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
