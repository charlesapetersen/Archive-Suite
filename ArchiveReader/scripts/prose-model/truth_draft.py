#!/usr/bin/env python3
"""W40.reader-prose-model: blind truth drafts of each page's structure, from the page image, on the Mac.

Two open models of different families (Qwen3-VL 8B, Gemma 3 12B; MLX, 4-bit) each see the rendered page and its
lines in reading order, numbered, text only, with no geometry and no label from either scored method, and give one
label a line: C continues, P new paragraph, H heading, I1-I4 list item at that level. Nothing leaves the Mac.
Run inside the heavy lock (they load a model):
  python3 ops/autonomous/heavy-run.py run -- <lab venv>/bin/python truth_draft.py CACHE_DIR MODEL_KEY
<lab venv> is ~/.local/share/visionocr-ocrlab/venv (mlx_vlm). Writes CACHE_DIR/draft-<MODEL_KEY>.jsonl, resumable.
"""
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../../ArchiveProcessor/scripts/segbench"))
MODELS = {"qwen3-vl-8b": "mlx-community/Qwen3-VL-8B-Instruct-4bit",
          "gemma3-12b": "mlx-community/gemma-3-12b-it-4bit"}
LABELS = {"C", "P", "H", "I1", "I2", "I3", "I4"}

PROMPT = """The image is a photographed page of a typed or printed document. Below are its text lines in reading \
order, numbered. An app will rebuild the page's paragraphs, headings and lists from one label per line. Looking at \
the page itself, give each line exactly one label:
C = the line continues the paragraph or list item of the line before;
P = the line starts a new paragraph (including the first line of a letter's address, date or signature block);
H = the line is a heading or title standing on its own line;
I1 = the line starts a list item; I2 = it starts a sub-item of an I1 item; I3, I4 = deeper sub-items.
Reply with JSON only, one entry for every line number from 1 to {n}: {{"1": "P", "2": "C", ...}}

{lines}"""


def parse(raw, n):
    """One label a row, keyed by line number so a skipped line cannot shift the rest; a row with no valid label
    is None (scored as disputed). None for the page when over a tenth of its rows have none."""
    m = re.search(r"\{.*\}", raw, re.S)
    try:
        got = json.loads(m.group(0)) if m else None
    except ValueError:
        return None
    if not isinstance(got, dict):
        return None
    labels = [got.get(str(i + 1)) if got.get(str(i + 1)) in LABELS else None for i in range(n)]
    return labels if sum(x is None for x in labels) * 10 <= n else None


def main():
    d, key = sys.argv[1], sys.argv[2]
    import model_store
    model_store.use()   # before mlx_vlm imports huggingface_hub
    import mlx.core as mx
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    pages = [json.loads(x) for x in open(f"{d}/rules40.jsonl", encoding="utf-8")]
    out = f"{d}/draft-{key}.jsonl"
    done = {json.loads(x)["id"] for x in open(out, encoding="utf-8")} if os.path.exists(out) else set()
    mx.set_cache_limit(256 * 2**20)
    model, processor = load(MODELS[key])
    for k, p in enumerate(pages):
        if p["id"] in done:
            continue
        rows = [r["t"].strip() for r in p["rows"]]
        prompt = PROMPT.format(n=len(rows), lines="\n".join(f"{i + 1}. {t}" for i, t in enumerate(rows)))
        chat = apply_chat_template(processor, model.config, prompt, num_images=1)
        start, text = time.time(), []
        for r in stream_generate(model, processor, chat, image=[f"{d}/img/{k}.png"], max_tokens=1200,
                                 temperature=0.0):
            text.append(r.text)
        raw = "".join(text)
        rec = {"id": p["id"], "labels": parse(raw, len(rows)), "raw": raw[:4000], "wall": round(time.time() - start, 1)}
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
        print(f"[{k + 1}/{len(pages)}] {rec['wall']}s {'ok' if rec['labels'] else 'unparsed'}", flush=True)


if __name__ == "__main__":
    main()
