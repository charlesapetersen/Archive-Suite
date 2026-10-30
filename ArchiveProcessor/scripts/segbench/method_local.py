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
import model_store
from methods import METHODS  # noqa: F401  (loads method_window and method_gemini in order)
import method_window as W
import method_window_cues as C
from score import derived, score_labels

MAX_SIDE = 1024
MAX_TOKENS = 1500
PROMPT_VERSION = "l1"
MODELS = {  # key: (repo in the shared Hugging Face cache, model_store.py; or a build's folder, label)
    "qwen3.5-4b": ("lmstudio-community/Qwen3.5-4B-MLX-4bit", "Qwen3.5-4B, 4-bit"),
    "gemma4-12b": ("mlx-community/gemma-4-12B-it-4bit", "Gemma 4 12B, 4-bit"),
    "qwen3-vl-8b": ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "Qwen3-VL-8B, 4-bit"),
    # W41.seg-mac-model: the FarmShare fine-tunes (W41.seg-finetune), merged there and converted here to 4-bit MLX
    # with the lab's convert-mlx.py; mlx_vlm loads a build from its folder.
    # seg-4b, seg-2b and seg-4b-8bit were offloaded on 2026-10-21 to the owner's OneDrive-Stanford folder
    # ("Offload to OneDrive/visionocr-seg-builds"); copy them back to ~/.local/share/visionocr-ocrlab/mlx/ to rerun.
    "seg-4b": (str(Path("~/.local/share/visionocr-ocrlab/mlx/seg-qwen3.5-4b-4bit").expanduser()),
               "Qwen3.5-4B fine-tuned for segmentation, 4-bit"),
    "seg-2b": (str(Path("~/.local/share/visionocr-ocrlab/mlx/seg-qwen3.5-2b-4bit").expanduser()),
               "Qwen3.5-2B fine-tuned for segmentation, 4-bit"),
    "seg-4b-8bit": (str(Path("~/.local/share/visionocr-ocrlab/mlx/seg-qwen3.5-4b-8bit").expanduser()),
                    "Qwen3.5-4B fine-tuned for segmentation, 8-bit"),
    "seg-2b-8bit": (str(Path("~/.local/share/visionocr-ocrlab/mlx/seg-qwen3.5-2b-8bit").expanduser()),
                    "Qwen3.5-2B fine-tuned for segmentation, 8-bit"),
    "seg-date-2b-8bit": ("/Users/cp1/Claude/Long term storage/FarmShare-20261018/seg-date-2b-8bit",
                         "Qwen3.5-2B segmentation + dating, 8-bit (experimental)"),
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
    model_store.use()   # before mlx_vlm imports huggingface_hub, which reads HF_HOME once
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
    import method_openrouter as O  # W41.seg-large: the larger open models, the same request through OpenRouter
    lines += ["", "## Larger open models through OpenRouter (W41.seg-large), and on FarmShare (W41.farmshare-seg)", "",
              "The same request, images at the same 1024 px, sent to OpenRouter (`method_openrouter.py`), one "
              "provider and precision pinned per model; reasoning off, temperature 0. Seconds are the cloud's, "
              "not a Mac's; the memory column is an estimate of the 4-bit weights alone, not measured.", "",
              "| model, route | pages in exact doc | false splits | false merges | failed windows | mean s/window "
              "| GB to hold | cost |", "|---|---|---|---|---|---|---|---|"]
    lines += O.rows(name)
    if name == "Deaver":
        lines += ["", "**Verdict (2026-10-13).** Local segmentation is not closed. Qwen3.5 27B, which a 32 GB Mac "
                  "could hold at 4-bit, reached 95.0% against the cloud models' 97.9% (two more false merges, no "
                  "false splits), with smaller images than theirs (1024 px against 1600). That is near enough for "
                  "a fine-tune, or a 4-bit run on a Mac, to be worth discussing; it is far from the 4B-12B models' "
                  "47-57%. Three cautions. It is one box of 149 pages, where each mistake moves the figure by "
                  "several points, and bigger did not mean better: the 122B scored below the 27B. These ran at fp8 "
                  "or bf16, and a Mac runs 4-bit: the one fp4 build offered (Qwen3.6 35B-A3B) lost 3.6 points to "
                  "its fp8 run, so expect a 4-bit 27B somewhat below 95%. And the seconds are the cloud's: a "
                  "dense 27B on a Mac reads seven pages far slower than the 4B-12B rows above."]
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
