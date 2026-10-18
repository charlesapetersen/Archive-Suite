#!/usr/bin/env python3
"""W41.seg-finetune. LoRA-train a small Qwen3.5 vision model to answer the bench's segmentation windows.

  train_seg.py data  --pack DIR --answers FILE --labels FILE --windows FILE --out DIR [--rule agree|start-trust]
                                                                        # Mac or node: the training set
  train_seg.py train --data DIR --model Qwen/Qwen3.5-4B --out DIR [--epochs 1] [--max-windows N]
  train_seg.py merge --adapter DIR --out DIR                            # base + LoRA -> one model vLLM can serve

TEXT ROWS (W41.date-model). A row with no `box` is a text-only request: one user message holding the prompt, no
images, trained the same way (thinking off, loss over the reply). public_dates.py mix writes such a set.

The data: a training window (corpus_pairs.py pack, split train) whose every gap the teacher (Qwen3.5 27B, frozen in
seg-teacher.json) and the tags agree on (corpus_pairs.py clean's `keep`), with the teacher's own reply as the
target, so the student learns the whole answer: page kinds, decisions, confidences and cues. A window marked
`text: none` by corpus_pairs.py goes with every page's text replaced by "(no text found)", which is what the bench
sends for a page without OCR (the pack's prompt_notext), because the app's segmenter sees the app's OCR, never ABBYY's. Held-out windows are
never trained on.

The request is the one cluster_seg.py sends (the pack's prompt and 1024 px images), in the base model's chat template
with thinking off, so a trained model is scored by the same cluster_seg.py run and import as the teacher.
"""
from __future__ import annotations
import argparse
import json
import math
import os
from pathlib import Path
import random
import sys
import time

SEED = 41


def cmd_data(a):
    pack = Path(a.pack)
    wins = {w["cache_key"]: w for w in map(json.loads, (pack / "windows.jsonl").read_text().splitlines())}
    meta = {(m["folder_id"], tuple(p["n"] for p in m["pages"])): m
            for m in map(json.loads, Path(a.windows).read_text().splitlines())}
    keep = {}
    for line in Path(a.labels).read_text().splitlines():
        g = json.loads(line)
        # A gap is trained on when the rule labels it (corpus_pairs.py clean); `agree` is the same as its `keep`.
        keep[(g["folder_id"], g["n"])] = g["label_" + a.rule] is not None
    rows, why = [], {"not ok": 0, "held out": 0, "a gap disagrees": 0, "a gap unlabelled": 0}
    for line in Path(a.answers).read_text().splitlines():
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if r.get("status") != "ok" or r["cache_key"] not in wins:
            why["not ok"] += 1; continue
        w = wins[r["cache_key"]]
        m = meta[(w["box"], tuple(w["window"]))]
        if m["split"] != "train":
            why["held out"] += 1; continue
        ks = [keep.get((w["box"], n)) for n in w["window"][:-1]]
        if any(k is None for k in ks):
            why["a gap unlabelled"] += 1; continue
        if not all(ks):
            why["a gap disagrees"] += 1; continue
        prompt = w["prompt"] if m["text"] == "abbyy" else w["prompt_notext"]
        rows.append({"box": w["box"], "window": w["window"], "prompt": prompt, "target": r["result"].strip(),
                     "text": m["text"]})
    random.Random(SEED).shuffle(rows)
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    (out / "train.jsonl").write_text("".join(json.dumps(x) + "\n" for x in rows))
    summary = {"rule": a.rule, "windows": len(rows), "no_text": sum(x["text"] == "none" for x in rows), "dropped": why,
               "images": str(pack / "images")}
    (out / "data.json").write_text(json.dumps(summary, indent=1))
    print(json.dumps(summary, indent=1))


def load_images(images, box, nums):
    from PIL import Image
    return [Image.open(Path(images) / box / f"{n}.jpg").convert("RGB") for n in nums]


def encode(processor, row, images_dir):
    """input_ids, attention mask, pixel inputs and labels (-100 over the request, the reply's tokens trained).
    A text row (no `box`) has no images."""
    imgs = load_images(images_dir, row["box"], row["window"]) if "box" in row else []
    msgs = [{"role": "user", "content": [*({"type": "image"} for _ in imgs), {"type": "text", "text": row["prompt"]}]}]
    prompt = processor.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True, enable_thinking=False)
    full = prompt + row["target"] + processor.tokenizer.eos_token
    extra = {"images": imgs} if imgs else {}
    enc = processor(text=[full], return_tensors="pt", **extra)
    n_prompt = processor(text=[prompt], return_tensors="pt", **extra)["input_ids"].shape[1]
    labels = enc["input_ids"].clone()
    labels[:, :n_prompt] = -100
    enc["labels"] = labels
    return enc


def reply_loss(model, enc):
    """Cross-entropy over the reply's tokens only. The model is asked for logits at the last k positions
    (`logits_to_keep`): full-vocabulary logits for a whole window (about 12,000 tokens x 248,000) are a 10 GB
    allocation that ran an L40S out of memory on the first window (2026-10-16)."""
    import torch.nn.functional as F
    labels = enc["labels"]
    k = int((labels[0] != -100).sum()) + 1
    logits = model(**{key: v for key, v in enc.items() if key != "labels"}, logits_to_keep=k).logits
    # position t predicts token t+1: the k kept positions predict the last k-1 tokens, which are the reply's
    return F.cross_entropy(logits[0, :-1].float(), labels[0, -(k - 1):], ignore_index=-100)


def cmd_train(a):
    import torch
    from transformers import AutoModelForImageTextToText, AutoProcessor
    from peft import LoraConfig, get_peft_model
    torch.manual_seed(SEED)
    data = Path(a.data)
    rows = [json.loads(l) for l in (data / "train.jsonl").read_text().splitlines()]
    if a.max_windows:
        rows = rows[:a.max_windows]
    images = a.images or json.loads((data / "data.json").read_text()).get("images")
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    processor = AutoProcessor.from_pretrained(a.model)
    model = AutoModelForImageTextToText.from_pretrained(a.model, dtype=torch.bfloat16 if dev == "cuda" else torch.float32)
    model.to(dev)
    model.gradient_checkpointing_enable()
    model.enable_input_require_grads()
    # LoRA on the language model's attention and MLP projections; the vision tower stays frozen.
    targets = r".*language_model.*\.(q_proj|k_proj|v_proj|o_proj|gate_proj|up_proj|down_proj)$"
    model = get_peft_model(model, LoraConfig(r=a.rank, lora_alpha=2 * a.rank, lora_dropout=0.05,
                                             target_modules=targets, task_type="CAUSAL_LM"))
    model.print_trainable_parameters()
    opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=a.lr, weight_decay=0.0)
    steps = math.ceil(len(rows) * a.epochs / a.accum)
    sched = torch.optim.lr_scheduler.LambdaLR(
        opt, lambda s: min(1.0, (s + 1) / max(1, int(0.03 * steps))) * max(0.0, 1 - s / max(1, steps)))
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    log = (out / "train-log.jsonl").open("a")
    model.train()
    t0, step, seen, run_loss, run_n = time.time(), 0, 0, 0.0, 0
    for epoch in range(math.ceil(a.epochs)):
        order = list(range(len(rows)))
        random.Random(SEED + epoch).shuffle(order)
        if epoch + 1 > a.epochs:
            order = order[:int(len(rows) * (a.epochs - epoch))]
        for k, i in enumerate(order):
            enc = {key: v.to(dev) for key, v in encode(processor, rows[i], images).items()}
            if enc["input_ids"].shape[1] > a.max_len:
                continue
            loss = reply_loss(model, enc) / a.accum
            loss.backward()
            run_loss += loss.item() * a.accum; run_n += 1; seen += 1
            if seen % a.accum == 0:
                torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                opt.step(); sched.step(); opt.zero_grad(); step += 1
                if step % 10 == 0 or step == steps:
                    rec = {"step": step, "of": steps, "loss": round(run_loss / max(1, run_n), 4), "lr": sched.get_last_lr()[0],
                           "elapsed_s": round(time.time() - t0), "epoch": epoch}
                    log.write(json.dumps(rec) + "\n"); log.flush(); print(json.dumps(rec), flush=True)
                    run_loss, run_n = 0.0, 0
                if a.save_every and step % a.save_every == 0:
                    model.save_pretrained(out / f"step-{step}")
    model.save_pretrained(out / "adapter")
    processor.save_pretrained(out / "adapter")
    (out / "train.json").write_text(json.dumps({"model": a.model, "windows": len(rows), "epochs": a.epochs,
                                                "rank": a.rank, "lr": a.lr, "accum": a.accum, "steps": step,
                                                "wall_s": round(time.time() - t0), "device": dev}, indent=1))
    print("saved", out / "adapter")


def cmd_merge(a):
    import torch
    from transformers import AutoModelForImageTextToText, AutoProcessor
    from peft import PeftModel
    cfg = json.loads((Path(a.adapter).parent / "train.json").read_text())
    base = AutoModelForImageTextToText.from_pretrained(cfg["model"], dtype=torch.bfloat16)
    model = PeftModel.from_pretrained(base, a.adapter).merge_and_unload()
    model.save_pretrained(a.out, safe_serialization=True)
    AutoProcessor.from_pretrained(cfg["model"]).save_pretrained(a.out)
    print("merged ->", a.out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("data")
    for k in ("pack", "answers", "labels", "windows", "out"):
        p.add_argument("--" + k, required=True)
    p.add_argument("--rule", choices=("agree", "start-trust"), default="agree")
    p = sub.add_parser("train")
    p.add_argument("--data", required=True); p.add_argument("--model", required=True); p.add_argument("--out", required=True)
    p.add_argument("--images"); p.add_argument("--epochs", type=float, default=1.0)
    p.add_argument("--max-windows", type=int); p.add_argument("--rank", type=int, default=16)
    p.add_argument("--lr", type=float, default=1e-4); p.add_argument("--accum", type=int, default=8)
    p.add_argument("--max-len", type=int, default=16384); p.add_argument("--save-every", type=int, default=0)
    p = sub.add_parser("merge"); p.add_argument("--adapter", required=True); p.add_argument("--out", required=True)
    a = ap.parse_args()
    {"data": cmd_data, "train": cmd_train, "merge": cmd_merge}[a.cmd](a)


if __name__ == "__main__":
    main()
