#!/usr/bin/env python3
"""W46.kit-mac-lora: whether the kit can train on a Mac at all (H test 1, gap audit §5 item 35).

  kit_mac_lora.py seg-data  [--n 200] [--pages K] [--side PX]   # agree-set training windows: 1024 px images,
                                            #   Vision text, rows; --pages/--side cut them for the memory ladder
  kit_mac_lora.py date-data [--n 1000]      # text-only dating rows on Vision text
  kit_mac_lora.py render    DIR             # one row through mlx-vlm's chat template: tokens, image tokens
  kit_mac_lora.py train     ARGS...         # mlx_vlm.lora ARGS, the loss's vocabulary projection on the reply only
  kit_mac_lora.py probe     DIR [--row N]   # peak memory of one row's vision, forward and LoRA step
  kit_mac_lora.py measure   LOG...          # seconds a step, peak memory and loss from mlx_vlm.lora logs

The training itself is mlx-vlm's own CLI, the one a kit user would run, under the Vision OCR lab's memory guard
(which takes the Mac-wide heavy lock first):

  run-guarded.sh --label kit-mac-lora-seg20-r8 -- env PYTHONPATH=<pylib> <lab venv>/bin/python -m mlx_vlm.lora \\
      --model-path <shipped 2B 8-bit> --dataset <dir> --batch-size 1 --epochs 1 --lora-rank 8 --lora-alpha 16 \\
      --grad-checkpoint --train-on-completions --max-seq-length 16384 --learning-rate 1e-4 --output-path <dir>

<pylib> holds `datasets` and its missing dependencies (mlx-vlm's `train` extra), installed with
`uv pip install --target` so the lab's venv is not changed.

THE DATA. Seg rows are training windows (corpus_pairs.py windows.jsonl, split train) whose every gap is in the agree
set (labels.jsonl `keep`) and whose every page has a JPEG. The request is corpus_pairs.window_prompt, the one the
shipped 2B was trained and is scored on, with Apple Vision text (the app's OCR, segbench-ocr) in place of ABBYY's
layer, which is banned as an input since 2026-10-30 (CLAUDE.md "No ABBYY text"); a window the pack marked
`text: none` keeps "(no text found)", as in training. The teacher's replies are on the cluster, so the target is
written from the agreed labels: each page's kind from its label, each gap's decision from `label_agree`, its
confidence the teacher's P(new) on the decided side (labels.jsonl `p_new`), and one fixed cue. On agreed gaps the
decisions are the teacher's; the cue text is not. Dating rows are date_tagging.py's train split (its prompt, its
target) with every document and context text re-read by Vision from the page JPEGs. Selection is a seeded sample
of folders, never by a route's answer or by ABBYY text.

Writes only under the bench cache (kit-mac-lora/); the corpus JPEGs and tags are read, never written.
"""
from __future__ import annotations
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import random
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import corpus_pairs as CP  # noqa: E402

OUT = Path.home() / "Library/Caches/ArchiveSuiteRehearsal/kit-mac-lora"
OCR_BIN = Path.home() / "Library/Caches/ArchiveSuiteRehearsal/segbench/bin/segbench-ocr"
SIDE = 1024
SEED = 46
CUE = "the folder's tags"
KIND = {"Box": "box", "Folder": "folder"}


def labels():
    lab = {}
    for line in open(os.path.join(CP.CACHE, "labels.jsonl"), encoding="utf-8"):
        g = json.loads(line)
        lab[(g["folder_id"], g["n"])] = g
    return lab


def jpeg_of(rel):
    return os.path.join(CP.JPEGS, rel)


def vision_texts(jpegs):
    """{jpeg path: Vision text}, OCRing what is not cached (OUT/ocr, by the path's hash)."""
    cache = OUT / "ocr"
    cache.mkdir(parents=True, exist_ok=True)
    dest = {j: cache / (hashlib.sha1(j.encode()).hexdigest() + ".txt") for j in jpegs}
    todo = [(j, d) for j, d in dest.items() if not d.exists()]
    if todo:
        jobs = OUT / "ocr-jobs.tsv"
        jobs.write_text("".join(f"{j}\t{d}\n" for j, d in todo))
        print(f"Vision OCR: {len(todo)} pages", flush=True)
        subprocess.run([str(OCR_BIN), str(jobs)], check=False)
    return {j: d.read_text(encoding="utf-8") if d.exists() else "" for j, d in dest.items()}


def image(src, dst, side=SIDE):
    from PIL import Image
    if dst.exists():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    im = Image.open(src).convert("RGB")
    im.thumbnail((side, side), Image.LANCZOS)
    im.save(dst, "JPEG", quality=90)


def reply(w, lab):
    nums = [p["n"] for p in w["pages"]]
    pages = [{"page": p["n"], "kind": KIND.get(p["label"], "document")} for p in w["pages"]]
    bounds = []
    for n in nums[:-1]:
        g = lab[(w["folder_id"], n)]
        new = g["label_agree"] == "new"
        conf = g["p_new"] if new else 1 - g["p_new"]
        bounds.append({"between": [n, n + 1], "decision": "new" if new else "continue", "cue": CUE,
                       "confidence": round(max(0.5, min(1.0, conf)), 2)})
    return json.dumps({"pages": pages, "boundaries": bounds})


def cmd_seg_data(a):
    lab = labels()
    wins = [json.loads(l) for l in open(os.path.join(CP.CACHE, "windows.jsonl"), encoding="utf-8")]

    def usable(w):
        nums = [p["n"] for p in w["pages"]]
        return (w["split"] == "train" and all(p.get("jpeg") and os.path.exists(jpeg_of(p["jpeg"])) for p in w["pages"])
                and all((g := lab.get((w["folder_id"], n))) is not None and g["keep"] for n in nums[:-1]))
    pool = [w for w in wins if w["split"] == "train"]
    random.Random(SEED).shuffle(pool)
    picked, why = [], collections.Counter()
    for w in pool:
        if len(picked) == a.n:
            break
        if usable(w):
            picked.append(w)
        else:
            why["not agreed or no JPEG"] += 1
    if a.pages:   # the memory ladder: each window cut to its first pages, the reply cut with it
        picked = [dict(w, pages=w["pages"][:a.pages]) for w in picked]
    texts = vision_texts(sorted({jpeg_of(p["jpeg"]) for w in picked for p in w["pages"] if w["text"] != "none"}))
    rows = []
    for w in picked:
        nums = [p["n"] for p in w["pages"]]
        imgs = []
        for p in w["pages"]:
            dst = OUT / ("images" if a.side == SIDE else f"images-{a.side}") / w["folder_id"] / f"{p['n']}.jpg"
            image(jpeg_of(p["jpeg"]), dst, a.side)
            imgs.append(str(dst))
        t = [None if w["text"] == "none" else (texts[jpeg_of(p["jpeg"])].strip() or None) for p in w["pages"]]
        rows.append({"images": imgs, "messages": [{"role": "user", "content": CP.window_prompt(nums, t)},
                                                  {"role": "assistant", "content": reply(w, lab)}],
                     "box": w["folder_id"], "window": nums, "text": w["text"]})
    tail = (f"-p{a.pages}" if a.pages else "") + (f"-s{a.side}" if a.side != SIDE else "")
    for n in sorted({min(a.n, k) for k in (20, 200, a.n)}):
        d = OUT / f"seg-{n}{tail}"
        d.mkdir(parents=True, exist_ok=True)
        (d / "train.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows[:n]))
    summary = {"windows": len(rows), "pages": sum(len(r["window"]) for r in rows),
               "no-text windows": sum(r["text"] == "none" for r in rows), "skipped": dict(why),
               "folders": len({r["box"] for r in rows})}
    (OUT / f"seg-data{tail}.json").write_text(json.dumps(summary, indent=1))
    print(json.dumps(summary, indent=1))


def cmd_date_data(a):
    import date_tagging as DT
    lab = labels()
    rows = [json.loads(l) for l in open(os.path.join(DT.CACHE, "train", "train.jsonl"), encoding="utf-8")]
    want = {r["id"]: r for r in rows}
    jpeg = {p["pdf"]: p["jpeg"] for w in map(json.loads, open(os.path.join(CP.CACHE, "windows.jsonl"), encoding="utf-8"))
            for p in w["pages"] if p.get("jpeg")}
    folders = sorted({os.path.dirname(g["left"]) for g in lab.values()})
    random.Random(SEED).shuffle(folders)
    docs = []   # (row, its pages, the context documents' first pages)
    for f in folders:
        segs = DT.folder_documents(f, lab)
        for k, s in enumerate(segs):
            r = want.get(hashlib.sha1(s["pages"][0].encode()).hexdigest()[:16]) if s["kind"] == "doc" else None
            if r is None or not all(p in jpeg for p in s["pages"]):
                continue
            near = (segs[max(0, k - 3):k] + segs[k + 1:k + 4])[:3]
            docs.append((r, s["pages"], [n["pages"][0] for n in near if n["pages"][0] in jpeg]))
        if len(docs) >= a.n:
            break
    docs = docs[:a.n]
    texts = vision_texts(sorted({jpeg_of(jpeg[p]) for _, ps, ns in docs for p in ps + ns}))
    vt = lambda p: texts[jpeg_of(jpeg[p])].strip()  # noqa: E731
    out = []
    for r, ps, ns in docs:
        text = "\n\n".join(vt(p) for p in ps)
        context = "\n---\n".join(vt(p)[:300] for p in ns)
        out.append({"messages": [{"role": "user", "content": DT.build_prompt(text, context)},
                                 {"role": "assistant", "content": r["target"]}], "id": r["id"], "class": r["class"]})
    d = OUT / f"date-{len(out)}"
    d.mkdir(parents=True, exist_ok=True)
    (d / "train.jsonl").write_text("".join(json.dumps(x, ensure_ascii=False) + "\n" for x in out))
    summary = {"rows": len(out), "pages read": len(texts),
               "classes": dict(collections.Counter(x["class"] for x in out)),
               "empty text": sum(not "\n\n".join(vt(p) for p in ps).strip() for _, ps, _ in docs)}
    (OUT / "date-data.json").write_text(json.dumps(summary, indent=1))
    print(json.dumps(summary, indent=1))


def cmd_render(a):
    """Tokens, image tokens and trained tokens of each row through mlx-vlm's template (the sequence length a
    training step carries, which sets its memory), and the first reply's tail as trained."""
    import numpy as np
    from mlx_vlm import load
    from mlx_vlm.trainer.datasets import VisionDataset
    rows = [json.loads(l) for l in Path(a.dir, "train.jsonl").read_text().splitlines()][:a.rows]
    model, processor = load(a.model)
    cfg = model.config.__dict__
    img_id = cfg.get("image_token_id") or cfg.get("image_token_index")
    tok = processor.tokenizer if hasattr(processor, "tokenizer") else processor
    stats = []
    for k, row in enumerate(rows):
        item = VisionDataset([row], cfg, processor, train_on_completions=True)[0]
        ids = np.array(item["input_ids"]).reshape(-1).tolist()
        mask = item.get("completion_mask")
        stats.append({"pages": len(row.get("images") or []), "tokens": len(ids), "image tokens": ids.count(img_id),
                      "trained tokens": int(np.array(mask).sum()) if mask is not None else None})
        if k == 0:
            print(repr(tok.decode(ids[-200:])))
    for s in stats:
        print(json.dumps(s))
    t = sorted(s["tokens"] for s in stats)
    print(json.dumps({"rows": len(t), "tokens median": t[len(t) // 2], "tokens max": t[-1], "tokens min": t[0]}))


_LOSS = []


def reply_only_loss():
    """mlx-vlm's SFT loss with the vocabulary projection taken only at the trained positions.

    mlx-vlm 0.7.4's vision_language_loss_fn projects every position onto the 248,320-word vocabulary and casts the
    result to float32 before masking: about 1 MB a token, so 10 GB for a 7-page window (about 10,000 tokens) before
    its gradient, and 3.4 GB even for a 2-page one. This gathers the hidden states at the loss mask's positions (the
    reply, about 350 tokens) before the tied head and computes the same masked cross-entropy over them. Installed
    once per process: it wraps the embedding classes' as_linear, which only the tied head calls."""
    if _LOSS:
        return _LOSS[0]
    import mlx.core as mx
    import mlx.nn as nn
    import numpy as np
    keep = {}

    def gathered(orig):
        def as_linear(self, x):
            idx = keep.get("idx")
            return orig(self, x if idx is None else x[:, idx])
        return as_linear
    for cls in (nn.Embedding, nn.QuantizedEmbedding):
        cls.as_linear = gathered(cls.as_linear)

    def loss(model, batch, train_on_completions=False, assistant_id=77091):
        input_ids = batch["input_ids"][:, :-1]
        mask = batch["attention_mask"][:, :-1]
        labels = batch["input_ids"][:, 1:]
        seq = input_ids.shape[1]
        lengths = mx.minimum(mx.sum(mask, axis=1), seq)
        loss_mask = (mx.arange(seq)[None, :] < lengths[:, None]).astype(mx.float32)
        if train_on_completions:
            loss_mask = loss_mask * batch["completion_mask"][:, 1:]
        pos = np.nonzero(np.array(loss_mask).any(axis=0))[0]
        idx = mx.array(pos if pos.size else np.array([seq - 1]))
        rest = {key: v for key, v in batch.items()
                if key not in ("input_ids", "pixel_values", "attention_mask", "completion_mask")}
        keep["idx"] = idx
        try:
            logits = model(input_ids, batch["pixel_values"], mask, **rest).logits.astype(mx.float32)
        finally:
            keep.pop("idx", None)
        m = loss_mask[:, idx]
        ce = nn.losses.cross_entropy(logits, labels[:, idx])
        return (ce * m).sum() / mx.maximum(m.sum(), 1)
    _LOSS.append(loss)
    return loss


def cmd_train(a):
    """mlx_vlm.lora, its own arguments, with reply_only_loss in place of its loss (the memory fix, 2026-11-04)."""
    import runpy
    from mlx_vlm.trainer import sft_trainer as T
    loss = reply_only_loss()
    orig_train = T.train
    T.train = lambda *x, **kw: orig_train(*x, **{**kw, "loss_fn": loss})
    sys.argv = ["mlx_vlm.lora"] + a.rest
    runpy.run_module("mlx_vlm.lora", run_name="__main__", alter_sys=True)


def cmd_probe(a):
    """Peak MLX memory of one row's stages, each after a reset: the vision tower's embeddings, the forward pass and
    loss, and one LoRA value-and-grad step (grad checkpointing as mlx-vlm sets it). --full uses mlx-vlm's own loss."""
    import mlx.core as mx
    import mlx.nn as nn
    from mlx_vlm import load
    from mlx_vlm.trainer.datasets import VisionDataset
    from mlx_vlm.trainer.sft_trainer import iterate_batches, vision_language_loss_fn
    from mlx_vlm.trainer.utils import find_all_linear_names, get_peft_model, grad_checkpoint
    from functools import partial
    loss = partial(vision_language_loss_fn if a.full else reply_only_loss(), train_on_completions=True)
    model, processor = load(a.model)
    rows = [json.loads(l) for l in Path(a.dir, "train.jsonl").read_text().splitlines()][a.row:a.row + 1]
    ds = VisionDataset(rows, model.config.__dict__, processor, train_on_completions=True)
    batch = next(iterate_batches(ds, 1, 16384, train=False))
    gb = lambda: round(mx.get_peak_memory() / 2**30, 2)  # noqa: E731
    print(json.dumps({"tokens": int(batch["input_ids"].shape[1]), "weights GB": round(mx.get_active_memory() / 2**30, 2)}),
          flush=True)
    peft = False
    for stage in a.stages.split(","):
        if stage == "step" and not peft:
            model = get_peft_model(model, find_all_linear_names(model.language_model), rank=a.rank,
                                   alpha=2 * a.rank, dropout=0.0, verbose=False)
            for m in model.children().values():
                if hasattr(m, "layers") and not a.no_ckpt:
                    grad_checkpoint(m.layers[0])
            model.train()   # as the trainer does; the Gated DeltaNet's Metal kernel has no gradient
            peft = True
        mx.clear_cache(); mx.reset_peak_memory()
        if stage == "vision":
            rest = {k: v for k, v in batch.items() if k not in ("input_ids", "pixel_values", "attention_mask", "completion_mask")}
            out = model.get_input_embeddings(batch["input_ids"], batch["pixel_values"], **rest)
            mx.eval(getattr(out, "inputs_embeds", out))
            del out
        elif stage in ("forward", "trainforward"):
            model.train(stage == "trainforward")   # training mode takes the Gated DeltaNet's chunked ops path
            mx.eval(loss(model, batch))
        elif stage == "step":
            lv, g = nn.value_and_grad(model, loss)(model, batch)
            mx.eval(lv, g)
            del g
        print(json.dumps({"stage": stage, "peak GB": gb()}), flush=True)


STEP = re.compile(r"Iter (\d+).*?Train loss ([\d.]+).*?It/sec ([\d.]+).*?Peak mem ([\d.]+) GB")


def cmd_measure(a):
    for log in a.logs:
        rows = [m.groups() for m in STEP.finditer(Path(log).read_text(errors="replace"))]
        if not rows:
            print(f"{log}: no step reports"); continue
        it = [float(r[2]) for r in rows]
        print(json.dumps({"log": log, "last iter": int(rows[-1][0]), "loss first": float(rows[0][1]),
                          "loss last": float(rows[-1][1]), "s a step (median report)": round(1 / sorted(it)[len(it) // 2], 1),
                          "peak GB (MLX)": max(float(r[3]) for r in rows)}))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("seg-data"); s.add_argument("--n", type=int, default=200)
    s.add_argument("--pages", type=int, default=0); s.add_argument("--side", type=int, default=SIDE); s.set_defaults(f=cmd_seg_data)
    s = sub.add_parser("date-data"); s.add_argument("--n", type=int, default=1000); s.set_defaults(f=cmd_date_data)
    s = sub.add_parser("render"); s.add_argument("dir"); s.add_argument("--rows", type=int, default=1000000)
    s.add_argument("--model", default=str(Path.home() / ".local/share/visionocr-ocrlab/mlx/seg-qwen3.5-2b-8bit"))
    s.set_defaults(f=cmd_render)
    sub.add_parser("train", help="mlx_vlm.lora's own arguments follow")
    s = sub.add_parser("probe"); s.add_argument("dir"); s.add_argument("--row", type=int, default=0)
    s.add_argument("--stages", default="vision,forward,step"); s.add_argument("--rank", type=int, default=8)
    s.add_argument("--full", action="store_true"); s.add_argument("--no-ckpt", action="store_true")
    s.add_argument("--model", default=str(Path.home() / ".local/share/visionocr-ocrlab/mlx/seg-qwen3.5-2b-8bit"))
    s.set_defaults(f=cmd_probe)
    s = sub.add_parser("measure"); s.add_argument("logs", nargs="+"); s.set_defaults(f=cmd_measure)
    if sys.argv[1:2] == ["train"]:   # everything after is mlx_vlm.lora's, which argparse would not pass through
        return cmd_train(argparse.Namespace(rest=sys.argv[2:]))
    a = p.parse_args()
    a.f(a)


if __name__ == "__main__":
    main()
