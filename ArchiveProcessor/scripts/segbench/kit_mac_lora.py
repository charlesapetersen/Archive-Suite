#!/usr/bin/env python3
"""W46.kit-mac-lora: whether the kit can train on a Mac at all (H test 1, gap audit §5 item 35).

  kit_mac_lora.py seg-data  [--n 200]       # agree-set training windows: 1024 px images, Vision text, rows
  kit_mac_lora.py date-data [--n 1000]      # text-only dating rows on Vision text
  kit_mac_lora.py render    DIR             # one row through mlx-vlm's chat template: tokens, image tokens
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


def image(src, dst):
    from PIL import Image
    if dst.exists():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    im = Image.open(src).convert("RGB")
    im.thumbnail((SIDE, SIDE), Image.LANCZOS)
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
    texts = vision_texts(sorted({jpeg_of(p["jpeg"]) for w in picked for p in w["pages"] if w["text"] != "none"}))
    rows = []
    for w in picked:
        nums = [p["n"] for p in w["pages"]]
        imgs = []
        for p in w["pages"]:
            dst = OUT / "images" / w["folder_id"] / f"{p['n']}.jpg"
            image(jpeg_of(p["jpeg"]), dst)
            imgs.append(str(dst))
        t = [None if w["text"] == "none" else (texts[jpeg_of(p["jpeg"])].strip() or None) for p in w["pages"]]
        rows.append({"images": imgs, "messages": [{"role": "user", "content": CP.window_prompt(nums, t)},
                                                  {"role": "assistant", "content": reply(w, lab)}],
                     "box": w["folder_id"], "window": nums, "text": w["text"]})
    for n in sorted({min(a.n, k) for k in (20, 200, a.n)}):
        d = OUT / f"seg-{n}"
        d.mkdir(parents=True, exist_ok=True)
        (d / "train.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows[:n]))
    summary = {"windows": len(rows), "pages": sum(len(r["window"]) for r in rows),
               "no-text windows": sum(r["text"] == "none" for r in rows), "skipped": dict(why),
               "folders": len({r["box"] for r in rows})}
    (OUT / "seg-data.json").write_text(json.dumps(summary, indent=1))
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
    """Token count and image tokens of the first row through mlx-vlm's template, the reply's tail as trained."""
    from mlx_vlm import load
    from mlx_vlm.trainer.datasets import VisionDataset
    row = json.loads(Path(a.dir, "train.jsonl").read_text().splitlines()[0])
    model, processor = load(a.model)
    ds = VisionDataset([row], model.config.__dict__, processor, train_on_completions=True)
    item = ds[0]
    ids = item["input_ids"].reshape(-1).tolist()
    tok = processor.tokenizer if hasattr(processor, "tokenizer") else processor
    img_id = model.config.__dict__.get("image_token_id") or model.config.__dict__.get("image_token_index")
    print(json.dumps({"tokens": len(ids), "image tokens": ids.count(img_id),
                      "trained tokens": int(item["completion_mask"].sum()) if "completion_mask" in item else None}))
    print(repr(tok.decode(ids[-200:])))


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
    s = sub.add_parser("seg-data"); s.add_argument("--n", type=int, default=200); s.set_defaults(f=cmd_seg_data)
    s = sub.add_parser("date-data"); s.add_argument("--n", type=int, default=1000); s.set_defaults(f=cmd_date_data)
    s = sub.add_parser("render"); s.add_argument("dir")
    s.add_argument("--model", default=str(Path.home() / ".local/share/visionocr-ocrlab/mlx/seg-qwen3.5-2b-8bit"))
    s.set_defaults(f=cmd_render)
    s = sub.add_parser("measure"); s.add_argument("logs", nargs="+"); s.set_defaults(f=cmd_measure)
    a = p.parse_args()
    a.f(a)


if __name__ == "__main__":
    main()
