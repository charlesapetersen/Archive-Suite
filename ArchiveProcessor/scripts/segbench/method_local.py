"""Approach E (W36.seg-localvlm): on-device vision models over the same page windows, on one box.

    python method_local.py collect <model> [Deaver] [--limit N]   # run UNDER the lab's memory guard (below)
    python method_local.py report [Deaver]                         # segbench-results/local-models-<box>.md

    ~/Claude/vision-ocr/ops/ocrlab/run-guarded.sh --label seg-<model> --need-gb 8 -- \\
        <lab venv>/bin/python method_local.py collect <model>

Owner, 2026-10-05: test the free on-device models on segmentation as well, "Three: Qwen3.5-4B, Gemma 4 12B,
Qwen3-VL-8B", on Deaver alone so they join the one-box comparison, run tonight before the bake-off resumes
(the Mac to itself; the bake-off's exception, not a rule). Zero-shot.

THE PROMPT is method_window_cues's codex text: method_gemini's g1 (the owner's cues and approved rules) with
the images attached in order, so the five cloud runs and these differ only in the model. Windows, combining
and assembly are method_window's. One difference, forced by memory: the images are shrunk to MAX_SIDE px
(the cloud runs saw 1600 px), because seven pages at 1600 px are more vision tokens than a 12 GB guard allows.

THE ROUTE. mlx-vlm in the Vision OCR lab's venv, the model loaded once per process, temperature 0, thinking
off where the chat template has the switch. Every valid answer is cached by content hash in
``ResponseCache("window-local-<model>")``. A window whose answer does not parse after one retry at a longer
token limit is recorded as failed and votes 0.5 "new" on each of its gaps; since every gap lies in two windows,
the other window's decision then stands unchanged (a mean with 0.5 keeps its side of 0.5) and only the
confidence moves. The report counts failed windows; a gap whose windows all failed is decided "new", the
app's default.
"""
from __future__ import annotations

import json
import re
import sys
import tempfile
import time
from pathlib import Path

import data
from methods import METHODS  # noqa: F401  (loads method_window and method_gemini in order)
import method_window as W
import method_window_cues as C
from score import derived, score_labels

MAX_SIDE = 1024
MAX_TOKENS = 1500
PROMPT_VERSION = "l1"
MODELS = {  # key: (repo in the lab's Hugging Face cache, label)
    "qwen3.5-4b": ("lmstudio-community/Qwen3.5-4B-MLX-4bit", "Qwen3.5-4B, 4-bit"),
    "gemma4-12b": ("mlx-community/gemma-4-12B-it-4bit", "Gemma 4 12B, 4-bit"),
    "qwen3-vl-8b": ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "Qwen3-VL-8B, 4-bit"),
}
FAILED = "failed"


def cache(key):
    return data.ResponseCache(f"window-local-{key}")


def log_path(key):
    return data.CACHE_DIR / f"window-local-{key}-calls.jsonl"


def request(col, a, b):
    prompt, thumbs, nums = C.build_request("codex", col, a, b)
    return prompt, thumbs, nums


def cache_key(key, prompt, thumbs):
    return data.response_cache_key(MODELS[key][0], PROMPT_VERSION, MAX_SIDE, prompt, [data.file_hash(t) for t in thumbs])


def neutral(nums):
    return {"pages": {}, "boundaries": {x: {"decision": "new", "confidence": 0.5, "cue": "(window failed)"}
                                        for x in nums[:-1]}}


def judge(key):
    def judge_window(col, a, b, allow_call=False):
        prompt, thumbs, nums = request(col, a, b)
        hit = cache(key).get(cache_key(key, prompt, thumbs))
        if hit is None:
            return None
        if hit.get("status") == FAILED:
            return neutral(nums)
        return W.parse_answer(hit["result"], nums)
    return judge_window


def strip_thinking(text):
    return re.sub(r"<think>.*?</think>", "", text, flags=re.S)


def collect(key, names, limit=None):
    import mlx.core as mx
    from mlx_vlm import load, generate
    from mlx_vlm.prompt_utils import apply_chat_template
    from PIL import Image

    W.refuse_test(names)
    repo = MODELS[key][0]
    jw = judge(key)
    jobs = [(c, a, b) for n in names for c in [data.load(n, with_exif=False)] for a, b in W.windows(len(c.pages))]
    todo = [j for j in jobs if jw(*j) is None][: limit or None]
    print(f"{key}: {len(jobs)} windows, {len(todo)} to run", flush=True)
    if not todo:
        return
    mx.set_cache_limit(256 * 2**20)   # as read-mlx.py: freed buffers otherwise count against the guard
    t0 = time.time()
    model, processor = load(repo)
    print(f"{key}: loaded in {time.time() - t0:.0f}s", flush=True)
    tmp = Path(tempfile.mkdtemp(prefix="seg-local-"))
    for k, (col, a, b) in enumerate(todo, 1):
        prompt, thumbs, nums = request(col, a, b)
        imgs = []
        for n, t in zip(nums, thumbs):
            im = Image.open(t).convert("RGB")
            im.thumbnail((MAX_SIDE, MAX_SIDE), Image.LANCZOS)
            imgs.append(str(tmp / f"{n}.jpg")); im.save(imgs[-1], quality=90)
        try:
            chat = apply_chat_template(processor, model.config, prompt, num_images=len(imgs), enable_thinking=False)
        except TypeError:
            chat = apply_chat_template(processor, model.config, prompt, num_images=len(imgs))
        status, text, rec = FAILED, "", {}
        for attempt, max_tokens in enumerate((MAX_TOKENS, 2 * MAX_TOKENS)):
            t1 = time.time()
            r = generate(model, processor, chat, image=imgs, max_tokens=max_tokens, temperature=0.0, verbose=False)
            text = strip_thinking(r.text)
            rec = {"collection": col.name, "window": nums, "attempt": attempt, "wall_s": round(time.time() - t1, 1),
                   "prompt_tokens": getattr(r, "prompt_tokens", 0), "gen_tokens": getattr(r, "generation_tokens", 0),
                   "peak_gb": round(mx.get_peak_memory() / 2**30, 2), "t": time.time()}
            try:
                W.parse_answer(text, nums)
                status = "ok"
                break
            except W.ParseError as e:
                rec["error"] = str(e)[:200]
        rec["event"] = status
        with open(log_path(key), "a") as fh:
            fh.write(json.dumps(rec) + "\n")
        cache(key).put(cache_key(key, prompt, thumbs), {"status": status, "result": text, "model": repo})
        print(f"[{k}/{len(todo)} {time.time() - t0:.0f}s] {col.name} {nums[0]}-{nums[-1]} {status} "
              f"{rec['wall_s']}s peak {rec['peak_gb']} GB", flush=True)


def report(name) -> str:
    col = data.load(name)
    lines = [f"# On-device models on {name} (development box)", "",
             f"Same windows, prompt (method_window_cues's, the owner's cues) and assembly as the cloud runs "
             f"(`cues-models-{name}.md`); images shrunk to {MAX_SIDE} px. Run under the Vision OCR lab's memory guard. "
             "Own photo labels. One box.", "",
             "| model | pages in exact doc | false splits | false merges | failed windows | mean s/window | peak GB |",
             "|---|---|---|---|---|---|---|"]
    for key, (repo, label) in MODELS.items():
        recs = [json.loads(l) for l in log_path(key).read_text().splitlines()] if log_path(key).exists() else []
        recs = [r for r in recs if r["collection"] == name]
        try:
            pred = W.assemble(col, W.combine(col, judge(key)), False)
        except RuntimeError:
            lines.append(f"| {label} | not collected ({len(recs)} windows run) | | | | | |")
            continue
        r = derived(score_labels(col.labels, pred.labels, name))
        failed = sum(1 for x in recs if x["event"] == FAILED)
        mean = sum(x["wall_s"] for x in recs) / max(1, len(recs))
        peak = max((x["peak_gb"] for x in recs), default=0)
        lines.append(f"| {label} | {100 * r['pages_in_exact_doc']:.1f}% | {r['false_splits']} | {r['false_merges']} "
                     f"| {failed} | {mean:.0f} | {peak:.1f} |")
    return "\n".join(lines) + "\n"


def main(argv) -> int:
    if len(argv) >= 2 and argv[0] == "collect" and argv[1] in MODELS:
        rest = argv[2:]
        limit = None
        if "--limit" in rest:
            i = rest.index("--limit"); limit = int(rest[i + 1]); rest = rest[:i] + rest[i + 2:]
        collect(argv[1], rest or ["Deaver"], limit)
    elif argv and argv[0] == "report":
        for name in argv[1:] or ["Deaver"]:
            W.refuse_test([name])
            text = report(name)
            print(text)
            (data.HERE.parent.parent / "segbench-results" / f"local-models-{name}.md").write_text(text)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
