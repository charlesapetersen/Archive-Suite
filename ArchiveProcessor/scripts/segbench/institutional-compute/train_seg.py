#!/usr/bin/env python3
"""W41.seg-finetune. LoRA-train a small Qwen3.5 vision model to answer the bench's segmentation windows.

  train_seg.py data  --pack DIR --answers FILE --labels FILE --windows FILE --out DIR [--rule agree|start-trust]
                                                                        # Mac or node: the training set
  train_seg.py train --data DIR --model Qwen/Qwen3.5-4B --out DIR [--epochs 1] [--max-windows N]
  train_seg.py merge --adapter DIR --out DIR                            # base + LoRA -> one model vLLM can serve
  train_seg.py mac   --merged DIR --out DIR --pack DIR [--bits 8] [--windows 8]
                                                                        # on the Mac: the MLX build + its figures
  train_seg.py check --run shipped=DIR --run NAME=DIR[,DIR] --run NAME=DIR[,DIR] --candidate NAME --anchor-truth BOX.json
                     [--labels labels.jsonl] [--ruled FILE] [--weights DIR] [--data DIR] [--out manifest.json]
                                                                        # W46.kit-gate: the held-out gate + manifest

MAC (W46.kit-mac-build). Run with a Python that has mlx-vlm (the app's local route uses the same). It converts the
merged student (`merge`, copied from the cluster) to MLX and quantises it (8 bits: seg-students.md §On the Mac found
4 bits two to five points worse), then times a warm-up on a pack's windows (the anchor pack the cluster answered: the
request the gate scores, 1024 px images, thinking off, temperature 0, a retry at twice the token limit) and writes the
Mac figures as `archive-seg-mac.json` in the build. `--build DIR` times an existing build instead. Then `check
--weights DIR` hashes the build, takes the figures from it, and writes `archive-seg-manifest.json` beside it; the two
kit files are left out of the weights hash, so writing them does not change it. The gate's answers come from the
cluster's full-precision run: say so in `--note` (the command `mac` prints does).

TEXT ROWS (W41.date-model). A row with no `box` is a text-only request: one user message holding the prompt, no
images, trained the same way (thinking off, loss over the reply). public_dates.py mix writes such a set.

The data: a training window (corpus_pairs.py pack, split train) whose every gap the teacher (Qwen3.5 27B, frozen in
seg-teacher.json) and the tags agree on (corpus_pairs.py clean's `keep`), with the teacher's own reply as the
target, so the student learns the whole answer: page kinds, decisions, confidences and cues. A window marked
`text: none` by corpus_pairs.py goes with every page's text replaced by "(no text found)", which is what the bench
sends for a page without OCR (the pack's prompt_notext), because the app's segmenter sees the app's OCR, never ABBYY's. Held-out windows are
never trained on.

CHECK (W46.kit-gate). Reads cluster_seg.py answers only: each run's per-gap P(new), averaged over the windows that
cover a gap, scored on the held-out collections' gaps against their tags (and against the owner's rulings where a
file of them is given), and on a locked public anchor box (pages in the exact document, gap accuracy, the review load
to 98%), paired against the shipped model. Held-out intervals resample folders and, inside each drawn folder, its
documents, so a one-box held-out set has a real interval (W46.kit-gate-groups); the anchor's resample documents. Held-out figures
count every expected gap: expected, answered and missing, the strict accuracy (a missing answer is wrong) beside the
answered-only one, and the paired difference over every gap the shipped run answered, the candidate's missing answers
counted wrong; a candidate with no shipped run or no paired gap fails (W46.kit-gate-coverage). The acceptance rule
(call 7.2, W46.kit-gate-rule): two scored runs, each passing; in each, the paired interval's low end above -3 points
on at least 267 known held-out gaps in at least 10 documents (W46.kit-gate-docs), and anchor pages exact less than 3.2 points below the shipped run's. It writes the
candidate's manifest (`archive-seg-manifest.json` beside the weights is what the app reads): prompt id, kit version,
weights and training-data hashes, the scores, and the gate's verdict; it exits 1 when the gate fails. The app refuses a
model whose manifest lacks the anchor score or names another prompt (`LocalSegmenter.refusal`). Sizes, from
kit_gate.py (2026-10-31 truth): separating 3 points of pages exact takes about 1,850 held-out gaps; gap accuracy
about 150-270 (seg-kit-gate.md is recomputed by `kit_gate.py report`).

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


# --- check: the held-out gate and the manifest (W46.kit-gate) ------------------------------------------------------

KIT_VERSION = "seg-kit-1"
PROMPT_ID = "c1"          # the app's id for the request these models are trained and scored on (`WindowVoter.catalog`)
# The acceptance rule, as decided (14-owner-calls.md call 7.2, 2026-11-06; W46.kit-gate-rule). Gap accuracy, paired
# against the shipped 2B: the low end of the paired held-out interval above -GATE_POINTS. No rerun floor has been
# measured in gap accuracy, so the pages-exact floor is not reused as its tie unit (P7-4); rerun wobble is met by
# scoring RUNS_NEEDED runs instead, each of which must pass.
GATE_POINTS = 3.0         # a candidate may trail the shipped model by less than this on held-out gaps (kit_gate.py)
# The support the 3-point interval needs: seg-kit-gate.md's "needed" column for gap accuracy is 147 (4B against the
# 2B) and 267 (the 27B teacher against the 2B). A candidate's disagreement with the 2B is not known beforehand, so
# the larger is the floor. Below it the interval is too wide to mean anything, and the gate refuses. Derived again on
# the gate's own resampling, folders and inside each documents (W46.kit-gate-groups, seg-kit-gate.md §The minimum
# support): documents alone, the unit a one-box held-out set has, give 254-282 over five seeds, so 267 stands.
MIN_KNOWN_GAPS = 267
# The documents the interval needs (W46.kit-gate-docs, seg-kit-gate.md §The minimum number of documents). With few
# documents the draw has few outcomes, so the interval is too narrow: on 280 gaps with a per-document spread of 3
# points, a candidate truly 3.5 points worse passes about a quarter of the time with two documents and about one in
# ten with three to five; from ten it is at the 4-5% that many documents give. The case is a box of a few long
# documents (bound volumes, registers); owner-like boxes hold about 1.8 gaps a document.
MIN_DOCUMENTS = 10
RUNS_NEEDED = 2
# On the public anchor, a candidate may score below the shipped run in pages exact by less than this, in each run:
# the top of the rerun floor measured in pages exact (SEG-10, 1.4-3.2 points a box). The shipped build's anchor is
# Lincoln 33.07% (20.96 to 47.83), seg-kit-manifest-shipped.json.
ANCHOR_MARGIN = 3.2
BAR = 0.98                # the review load is counted to 98% of pages in the exact document
DRAWS, CHECK_SEED = 2000, 46
MANIFEST = "archive-seg-manifest.json"   # what the app reads beside the weights (LocalSegmenter.manifestName)
MAC_FIGURES = "archive-seg-mac.json"     # `mac`'s warm-up figures, which `check` puts in the manifest
KIT_FILES = (MANIFEST, MAC_FIGURES)


def run_votes(dirs):
    """(collection, first page of the gap) -> the mean P(new) over the windows covering it, from cluster_seg.py
    answers.jsonl files; and the count of windows that failed or did not parse."""
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    import method_window as W
    votes, failed = {}, 0
    for d in dirs:
        for line in (Path(d) / "answers.jsonl").read_text().splitlines():
            try:
                r = json.loads(line)
                j = W.parse_answer(r["result"], r["window"]) if r.get("status") == "ok" else None
            except Exception:
                j = None
            if j is None:
                failed += 1
                continue
            for x, bd in j["boundaries"].items():
                p = bd["confidence"] if bd["decision"] == "new" else 1 - bd["confidence"]
                votes.setdefault((r["collection"], int(x)), []).append(p)
    return {k: sum(v) / len(v) for k, v in votes.items()}, failed


def pct_interval(xs):
    xs = sorted(xs)
    return [round(100 * xs[int(0.025 * len(xs))], 2), round(100 * xs[int(0.975 * len(xs)) - 1], 2)]


def two_level(folders, rng):
    """One bootstrap draw of a held-out set: folders with replacement, then, inside each drawn folder, its documents
    with replacement (W46.kit-gate-groups). folders: [[doc totals, ...], ...], each doc's totals a tuple; returns the
    summed totals. With one folder this is a document bootstrap, so a one-box held-out set has a real interval; with
    many single-document folders it is the folder bootstrap the gate used before."""
    tot = None
    for _ in folders:
        docs = folders[rng.randrange(len(folders))]
        for _ in docs:
            d = docs[rng.randrange(len(docs))]
            tot = d if tot is None else tuple(x + y for x, y in zip(tot, d))
    return tot


def gap_score(groups, rng, reference=False):
    """groups: {folder: [document, ...]}, each document the list of (model right, reference right) over its expected
    held-out gaps, each True, False or None when that run has no answer for it (W46.kit-gate-coverage). Strict figures
    count a missing answer as wrong, so a run cannot raise its score by leaving hard gaps unanswered; answered-only
    figures sit beside them as diagnostics. With a reference (the shipped model), the paired difference model -
    reference is taken over every gap the reference answered, the model's missing answers counted wrong. Intervals
    resample folders and, inside each, documents (`two_level`)."""
    keys = sorted(groups)
    flat = [x for k in keys for doc in groups[k] for x in doc]
    answered = [a for a, _ in flat if a is not None]
    out = {"expected_gaps": len(flat), "answered_gaps": len(answered), "missing_gaps": len(flat) - len(answered),
           "folders": len(keys), "documents": sum(len(groups[k]) for k in keys),
           "accuracy": round(100 * sum(a is True for a, _ in flat) / max(1, len(flat)), 2),
           "accuracy_answered": round(100 * sum(answered) / len(answered), 2) if answered else None}
    if not flat:
        return out
    folders = [[(len(doc), sum(a is True for a, _ in doc)) for doc in groups[k] if doc] for k in keys]
    folders = [f for f in folders if f]
    acc = []
    for _ in range(DRAWS):
        n, right = two_level(folders, rng)
        acc.append(right / n)
    out["interval"] = pct_interval(acc)
    if not reference:
        return out
    paired = {k: [d for d in ([(a is True, b) for a, b in doc if b is not None] for doc in groups[k]) if d] for k in keys}
    paired = {k: v for k, v in paired.items() if v}
    both = [(a, b) for a, b in flat if a is not None and b is not None]
    out["paired_gaps"] = sum(len(d) for v in paired.values() for d in v)
    out["paired_folders"] = len(paired)
    out["paired_documents"] = sum(len(v) for v in paired.values())
    out["paired_missing_gaps"] = sum(1 for _, b in flat if b is not None) - sum(1 for a, b in both)
    out["reference_missing_gaps"] = sum(1 for _, b in flat if b is None)
    out["difference_answered"] = round(100 * sum(a - b for a, b in both) / len(both), 2) if both else None
    if not paired:
        return out
    pk = sorted(paired)
    pflat = [x for k in pk for d in paired[k] for x in d]
    out["difference"] = round(100 * sum(a - b for a, b in pflat) / len(pflat), 2)
    pfolders = [[(len(d), sum(a - b for a, b in d)) for d in paired[k]] for k in pk]
    diff = []
    for _ in range(DRAWS):
        n, d = two_level(pfolders, rng)
        diff.append(d / n)
    out["difference_interval"] = pct_interval(diff)
    return out


def heldout_groups(labels, ruled, p_a, p_b):
    """Per folder, its documents, each the (model right, reference right) on its expected held-out gaps: against the
    tags, and against the owner's rulings where given. Each is None when that run has no answer for the gap, and the
    reference's is None throughout when p_b (the reference) is None. No gap is dropped for want of an answer
    (W46.kit-gate-coverage). Documents follow the truth being scored, in page order: a gap whose truth is "new"
    starts one (it belongs to the document its right page opens), any other joins the one before (W46.kit-gate-groups)."""
    tags, own = {}, {}

    def right(p, k, truth):
        return None if p is None or k not in p else (p[k] >= 0.5) == (truth == "new")
    for g in sorted((g for g in labels if g["split"] == "holdout"), key=lambda g: (g["folder_id"], g["n"])):
        k = (g["folder_id"], g["n"])
        for truth, dst in ((g["tag"], tags), (ruled.get(k), own)):
            if truth is None:
                continue
            docs = dst.setdefault(g["folder_id"], [])
            if truth == "new" or not docs:
                docs.append([])
            docs[-1].append((right(p_a, k, truth), right(p_b, k, truth)))
    return tags, own


def anchor_docs(truth_pages, box, p, unsure=()):
    """The anchor box's truth documents, each (pages, exact) for the predicted labels, and its gaps (confidence,
    right), from the per-gap P(new). None when a gap was not answered. ``unsure`` holds the manifest's unsure gaps
    (right-page numbers): those gaps are not scored (W46.seg-unsure-mask, as score.py), and a document that touches
    one is left out of pages exact and review load, so every model is scored on the same resolvable documents."""
    labels = [q["label"] for q in truth_pages]
    nums = [q["n"] for q in truth_pages]
    pnew = [p.get((box, nums[i])) for i in range(len(nums) - 1)]
    if any(x is None for x in pnew):
        return None
    pred = ["New"] + ["New" if x >= 0.5 else "Cont" for x in pnew]
    known = [nums[i + 1] not in set(unsure) for i in range(len(pnew))]

    def seg_ids(ls):
        out, k = [], -1
        for t in ls:
            k += t == "New"; out.append(k)
        return out

    tid = seg_ids(labels)
    tsets: dict[int, set] = {}
    for i, a in enumerate(tid):
        tsets.setdefault(a, set()).add(i)
    # A truth document is resolved when no unsure gap lies inside it or at either edge.
    resolved = [s for s in tsets.values() if all(known[i - 1] for i in range(min(s), max(s) + 2)
                                                 if 0 < i < len(labels))]

    def exact_docs(pred_labels):
        psets = {}
        for i, b in enumerate(seg_ids(pred_labels)):
            psets.setdefault(b, set()).add(i)
        pfs = {frozenset(s) for s in psets.values()}
        return [(len(s), frozenset(s) in pfs) for s in resolved]

    gaps = [(max(x, 1 - x), (x >= 0.5) == (labels[i + 1] == "New")) for i, x in enumerate(pnew) if known[i]]
    docs = exact_docs(pred)
    resolved_pages = sum(len(s) for s in resolved)
    # Review load at the bar: check the least confident known gaps first (each corrected to the truth) until 98% of
    # the resolved documents' pages sit in the exact document; the number checked per 100 pages.
    order = sorted((i for i in range(len(pnew)) if known[i]), key=lambda i: max(pnew[i], 1 - pnew[i]))
    fixed, checked = list(pred), None
    for k in range(len(order) + 1):
        if sum(n for n, e in exact_docs(fixed) if e) >= BAR * resolved_pages:
            checked = k
            break
        if k < len(order):
            i = order[k]
            fixed[i + 1] = labels[i + 1]
    return {"docs": docs, "gaps": gaps, "unscored_gaps": known.count(False),
            "unresolved_pages": len(labels) - resolved_pages,
            "review_load_per_100_pages": None if checked is None else round(100 * checked / len(labels), 1)}


def anchor_score(a_docs, b_docs, rng):
    """The model's (a) anchor figures with a document-bootstrap interval, and with a reference (b, the shipped model)
    the paired difference a - b in pages exact."""
    pages = sum(n for n, _ in a_docs["docs"])
    if not pages or not a_docs["gaps"]:
        raise SystemExit("the anchor box has no resolved document or no known gap left to score (every gap unsure?)")
    out = {"pages": pages, "documents": len(a_docs["docs"]),
           "pages_exact": round(100 * sum(n for n, e in a_docs["docs"] if e) / pages, 2),
           "gap_accuracy": round(100 * sum(r for _, r in a_docs["gaps"]) / len(a_docs["gaps"]), 2),
           "review_load_per_100_pages": a_docs["review_load_per_100_pages"],
           "unscored_gaps": a_docs["unscored_gaps"], "unresolved_pages": a_docs["unresolved_pages"]}
    xs, ds = [], []
    for _ in range(DRAWS):
        idx = [rng.randrange(len(a_docs["docs"])) for _ in a_docs["docs"]]
        n = sum(a_docs["docs"][i][0] for i in idx)
        ea = sum(a_docs["docs"][i][0] for i in idx if a_docs["docs"][i][1])
        xs.append(ea / n)
        if b_docs:
            ds.append((ea - sum(b_docs["docs"][i][0] for i in idx if b_docs["docs"][i][1])) / n)
    out["pages_exact_interval"] = pct_interval(xs)
    if b_docs:
        out["difference_from_shipped"] = round(
            100 * (sum(n for n, e in a_docs["docs"] if e) - sum(n for n, e in b_docs["docs"] if e)) / pages, 2)
        out["difference_interval"] = pct_interval(ds)
    return out


def sha256_of(path):
    """A file's hash, or a folder's over every file's relative path and bytes, the kit's own files beside the
    weights (KIT_FILES) left out, so a build hashes the same before and after its manifest is written."""
    import hashlib
    h = hashlib.sha256()
    files = (sorted(q for q in Path(path).rglob("*") if q.is_file() and q.relative_to(path).as_posix() not in KIT_FILES)
             if Path(path).is_dir() else [Path(path)])
    for q in files:
        h.update(q.relative_to(path).as_posix().encode() if Path(path).is_dir() else b"")
        with open(q, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    return h.hexdigest()


def run_row(p, failed, cmp, labels, ruled, truth, rng):
    """One run's figures: held-out against the tags and the rulings, and the anchor, paired against cmp (a shipped
    run's per-gap P(new)) when given."""
    row = {"failed_windows": failed}
    if labels:
        tags, own = heldout_groups(labels, ruled, p, cmp)
        row["heldout_tags"] = gap_score(tags, rng, cmp is not None) if tags else None
        row["heldout_ruled"] = gap_score(own, rng, cmp is not None) if own else None
    unsure = [u["right"] for u in truth.get("unsure", ())]
    ad = anchor_docs(truth["pages"], truth["box"], p, unsure)
    sd = anchor_docs(truth["pages"], truth["box"], cmp, unsure) if cmp else None
    row["anchor"] = anchor_score(ad, sd, rng) if ad else None
    return row


def support(held, paired):
    """The known gaps the gate's held-out figure stands on: the paired gaps for a candidate scored against the shipped
    run (the interval is over those), every expected gap for the shipped model itself."""
    if held is None:
        return 0
    return held.get("paired_gaps", 0) if paired else held["expected_gaps"]


def gate_basis(row, paired):
    """Which held-out set the gate scores: the owner's rulings when they reach the minimum support (SEG-6: the tags
    carry label noise), otherwise the tags; the rulings stay reported either way."""
    own, tags = row.get("heldout_ruled"), row.get("heldout_tags")
    if own is not None and (support(own, paired) >= MIN_KNOWN_GAPS or tags is None):
        return "owner_ruled", own
    return ("tags", tags) if tags is not None else (None, None)


def gate_counts(row, paired):
    """The folders, documents and known gaps the gate's held-out figure stands on, as the manifest states them."""
    _, held = gate_basis(row, paired)
    if held is None:
        return {"gate_folders": 0, "gate_documents": 0, "gate_gaps": 0}
    pre = "paired_" if paired else ""
    return {"gate_folders": held.get(pre + "folders", 0), "gate_documents": held.get(pre + "documents", 0),
            "gate_gaps": support(held, paired)}


def run_reasons(row, paired, box, shipped_given):
    """Why one scored run fails the gate (an empty list when it passes). Missing evidence is a reason, never a pass
    (W46.kit-gate-coverage); so is support below MIN_KNOWN_GAPS (W46.kit-gate-rule)."""
    reasons = []
    if not row["anchor"]:
        reasons.append(f"no anchor score: the run has no answer for every gap of {box}")
    basis, held = gate_basis(row, paired)
    if held is None:
        reasons.append("no held-out score: no expected held-out gap (no --labels, or no held-out split)")
    elif not held["answered_gaps"]:
        reasons.append(f"no held-out score: the run answered none of the {held['expected_gaps']} expected held-out gaps")
    if paired:
        if not shipped_given:
            reasons.append("no shipped reference: there is no shipped run to pair the candidate against")
        elif held is not None and "difference_interval" not in held:
            reasons.append(f"no paired held-out comparison: the shipped run answered none of the "
                           f"{held['expected_gaps']} expected held-out gaps")
        elif held is not None and held["difference_interval"][0] <= -GATE_POINTS:
            reasons.append(f"on held-out gaps it may trail the shipped model by {GATE_POINTS:g} points or more "
                           f"(difference {held['difference']}, interval {held['difference_interval']}, over "
                           f"{held['paired_gaps']} gaps the shipped model answered, {held['paired_missing_gaps']} "
                           f"of them unanswered by the candidate and counted wrong)")
        if shipped_given and row["anchor"]:
            d = row["anchor"].get("difference_from_shipped")
            if d is None:
                reasons.append(f"no paired anchor comparison: the shipped run has no answer for every gap of {box}")
            elif d <= -ANCHOR_MARGIN:
                reasons.append(f"on the anchor {box} it scores {d} points of pages exact against the shipped run, "
                               f"{ANCHOR_MARGIN:g} or more below it")
    if held is not None and held["answered_gaps"]:
        n = support(held, paired)
        if n < MIN_KNOWN_GAPS:
            reasons.append(f"too few known held-out gaps: {n} ({basis.replace('_', '-')}"
                           f"{', paired with the shipped run' if paired else ''}), and the gate needs at least "
                           f"{MIN_KNOWN_GAPS} for its {GATE_POINTS:g}-point interval to mean anything")
        docs = held.get("paired_documents", 0) if paired else held["documents"]
        if docs < MIN_DOCUMENTS:
            reasons.append(f"too few held-out documents: {docs} ({basis.replace('_', '-')}"
                           f"{', paired with the shipped run' if paired else ''}), and the gate needs at least "
                           f"{MIN_DOCUMENTS}: its interval resamples documents, and with fewer it is too narrow, so a "
                           f"candidate {GATE_POINTS + 0.5:g} points worse passes too often")
    return reasons


def cmd_check(a):
    """Score base, shipped and candidate on the held-out collections (against the tags, and against the owner's
    rulings where given) and on a locked public anchor box, then write the candidate's manifest. Reads answers only.
    A name given in several --run flags has several scored runs; the candidate needs RUNS_NEEDED of them, and each
    must pass. Candidate run i is paired with shipped run i (the last shipped run when there are fewer).
    With --weights naming a Mac build (`mac`), the manifest goes beside it and its figures come from it by default."""
    built = Path(a.weights) if a.weights and Path(a.weights).is_dir() else None
    if not a.out and not built:
        raise SystemExit("--out is needed unless --weights names the model's folder (the manifest goes beside it)")
    out = Path(a.out) if a.out else built / MANIFEST
    mac = a.mac or (str(built / MAC_FIGURES) if built and (built / MAC_FIGURES).is_file() else None)
    runs = {}
    for spec in a.run:
        name, _, dirs = spec.partition("=")
        dirs = tuple(dirs.split(","))
        seen = {os.path.realpath(x) for d, _ in runs.get(name, ()) for x in d}
        if seen & {os.path.realpath(x) for x in dirs}:
            raise SystemExit(f"--run {name}={','.join(dirs)} shares a directory with another run of {name}, given twice: "
                             f"a second scored run is a second set of answers, not the same directories again")
        runs.setdefault(name, []).append((dirs, run_votes(dirs)))
    if a.candidate not in runs:
        raise SystemExit(f"--candidate {a.candidate} has no --run")
    shipped = [v for _, v in runs.get(a.shipped, ())]
    rng = random.Random(CHECK_SEED)
    labels = [json.loads(l) for l in Path(a.labels).read_text().splitlines()] if a.labels else []
    ruled = {}
    if a.ruled:
        for line in Path(a.ruled).read_text().splitlines():
            parts = line.strip().split(",")
            if len(parts) == 3 and parts[2] in ("new", "same"):
                ruled[(parts[0], int(parts[1]))] = "new" if parts[2] == "new" else "cont"
    truth = json.loads(Path(a.anchor_truth).read_text())
    box = truth["box"]
    report = {"models": {}}
    for name, rs in runs.items():
        rows = []
        for i, (dirs, (p, failed)) in enumerate(rs):
            cmp = shipped[min(i, len(shipped) - 1)][0] if shipped and name != a.shipped else None
            rows.append({"dirs": list(dirs), **run_row(p, failed, cmp, labels, ruled, truth, rng)})
        report["models"][name] = rows
    paired = a.candidate != a.shipped
    cand_runs = report["models"][a.candidate]
    reasons = []
    if len(cand_runs) < RUNS_NEEDED:
        reasons.append(f"{len(cand_runs)} scored run; the gate needs {RUNS_NEEDED}, each passing, because its "
                       f"intervals cover sampling the held-out set and not a model's own rerun wobble")
    for i, row in enumerate(cand_runs):
        row["gate_scored_on"] = gate_basis(row, paired)[0]
        row["gate_reasons"] = run_reasons(row, paired, box, bool(shipped))
        reasons += [(f"run {i + 1}: " if len(cand_runs) > 1 else "") + r for r in row["gate_reasons"]]
    cand = cand_runs[0]
    manifest = {
        "kit_version": KIT_VERSION, "prompt_id": PROMPT_ID, "bench_request": "method_local.request (o1), 1024 px",
        "model": a.candidate, "base_build": a.base_build,
        "weights_sha256": sha256_of(a.weights) if a.weights else None,
        "adapter": ({"sha256": sha256_of(a.adapter), **{k: v for k, v in
                     json.loads((Path(a.adapter).parent / "train.json").read_text()).items() if k in ("rank", "model")}}
                    if a.adapter else None),
        "training_data": ({"sha256": sha256_of(Path(a.data) / "train.jsonl"),
                           "rule": json.loads((Path(a.data) / "data.json").read_text()).get("rule")} if a.data else None),
        "heldout": {"tags": cand.get("heldout_tags"), "owner_ruled": cand.get("heldout_ruled"),
                    "gate_scored_on": cand["gate_scored_on"], **gate_counts(cand, paired)},
        "anchor": None if not cand["anchor"] else {"box": box, "truth_sha256": sha256_of(a.anchor_truth), **cand["anchor"]},
        "review_load_at_98": None if not cand["anchor"] else cand["anchor"]["review_load_per_100_pages"],
        "scored_runs": len(cand_runs),
        "mac": json.loads(Path(mac).read_text()) if mac else None, "note": a.note,
        "gate": {"rule": f"{RUNS_NEEDED} scored runs, each with an anchor score and a held-out score on at least "
                         f"{MIN_KNOWN_GAPS} known gaps in at least {MIN_DOCUMENTS} documents (the owner's rulings when they reach "
                         f"that, else the tags), its intervals resampling folders and, inside each, documents; "
                         f"for a candidate other than the shipped model, in each run, a paired held-out gap-accuracy "
                         f"interval against the shipped run, over every gap that run answered with the candidate's "
                         f"missing answers counted wrong, whose low end is above -{GATE_POINTS:g} points, and anchor "
                         f"pages exact less than {ANCHOR_MARGIN:g} points below the shipped run's (decided, "
                         f"call 7.2, W46.kit-gate-rule; coverage, W46.kit-gate-coverage). The heldout and anchor "
                         f"blocks are run 1's; every run is under compared",
                 "passed": not reasons, "reasons": reasons},
        "compared": report["models"], "made": time.strftime("%Y-%m-%dT%H:%M:%S")}
    out.write_text(json.dumps(manifest, indent=1) + "\n")
    print(json.dumps({k: manifest[k] for k in ("model", "anchor", "heldout", "gate")}, indent=1))
    print("wrote", out)
    return 0 if not reasons else 1



# --- mac: the build the app loads, and its figures (W46.kit-mac-build) ---------------------------------------------

def safetensors_params(folder):
    """The parameters in a build's safetensors, read from their headers alone, as mlx-vlm counts them for its bits a
    weight: a quantised weight (one with a `.scales` beside it) packs 32/bits values into each uint32, and its scales
    and biases are overhead, not parameters. Counted on the build, not the merged model: convert drops the merged
    Qwen3.5's multi-token-prediction head (about 61M parameters of the 2B), which put the figure at 9.4, not 9.6."""
    import struct
    head = {}
    for f in sorted(Path(folder).glob("*.safetensors")):
        with open(f, "rb") as fh:
            head.update(json.loads(fh.read(struct.unpack("<Q", fh.read(8))[0])))
    head.pop("__metadata__", None)
    bits = (json.loads((Path(folder) / "config.json").read_text()).get("quantization") or {}).get("bits")
    n = 0
    for k, v in head.items():
        if k.endswith((".scales", ".biases")) and k.rsplit(".", 1)[0] + ".weight" in head and bits:
            continue
        packed = bits and k.endswith(".weight") and k[: -len("weight")] + "scales" in head
        n += math.prod(v["shape"]) * (32 // bits if packed else 1)
    return n


def folder_bytes(folder, pattern="*"):
    return sum(q.stat().st_size for q in Path(folder).rglob(pattern)
               if q.is_file() and q.relative_to(folder).as_posix() not in KIT_FILES)


def measured_on():
    """This Mac as the chooser names it: "18 GB M3 Pro"."""
    import subprocess
    sysctl = lambda k: subprocess.run(["sysctl", "-n", k], capture_output=True, text=True).stdout.strip()
    chip = sysctl("machdep.cpu.brand_string").removeprefix("Apple ") or "Mac"
    return f"{round(int(sysctl('hw.memsize') or 0) / 2**30)} GB {chip}"


def mac_figures(recs, load_s, pack_windows, pack_pages, build, size_bytes, on, pack_name):
    """The Mac figures from a warm-up's windows. The first window is not timed (its time includes building the
    kernels). Seconds a page are a window's mean times the pack's windows a page, as the bench counts a box's time
    (seg-students.md: each page sits in about 2.3 windows)."""
    timed = recs[1:] or recs
    s_window = sum(r["wall_s"] for r in timed) / len(timed)
    failed = sum(r["status"] != "ok" for r in recs)
    return {"build": build, "download_gb": round(size_bytes / 2**30, 1),
            "peak_memory_gb": round(max(r["peak_gb"] for r in recs), 1),
            "seconds_per_page": round(s_window * pack_windows / pack_pages, 1), "measured_on": on,
            "seconds_per_window": round(s_window, 1), "load_seconds": round(load_s, 1),
            "windows_timed": len(timed), "windows_unparsed": failed,
            "source": f"train_seg.py mac: a warm-up of {len(recs)} windows of {pack_name} ({len(timed)} timed), "
                      f"{time.strftime('%Y-%m-%d')}"}


def mlx_convert(merged, out, bits):
    """mlx-vlm's convert, quantising the language model (it leaves the vision tower as it is). mlx-vlm 0.7.4 copies
    the source's files keeping a read-only mode and then fails overwriting tokenizer.json before it writes the
    quantised config.json, which leaves a build that will not load; the copies are made writable (the Vision OCR
    lab's convert-mlx.py)."""
    import shutil
    from mlx_vlm.convert import convert
    copy = shutil.copy

    def writable(src, dst, **kw):
        r = copy(src, dst, **kw)
        os.chmod(r, 0o644)
        return r
    shutil.copy = writable
    try:
        convert(str(merged), str(out), quantize=True, q_bits=bits)
    finally:
        shutil.copy = copy


def warm_up(build, pack, rows, limit):
    """Each window as the cluster asks it (cluster_seg.read_window): the pack's prompt and images, thinking off,
    temperature 0, once more at twice the token limit (the window's own, else the pack's) if the answer does not
    parse. Wall time and peak memory."""
    import re
    import method_window as W
    import mlx.core as mx
    from mlx_vlm import load, generate
    from mlx_vlm.prompt_utils import apply_chat_template
    mx.set_cache_limit(256 * 2**20)   # as method_local.collect: freed buffers otherwise count as held
    t0 = time.time()
    model, processor = load(str(build))
    load_s = time.time() - t0
    recs = []
    for k, w in enumerate(rows, 1):
        imgs = [str(pack / "images" / w["box"] / f"{n}.jpg") for n in w.get("images", w["window"])]
        chat = apply_chat_template(processor, model.config, w["prompt"], num_images=len(imgs), enable_thinking=False)
        t1, status, own = time.time(), "failed", w.get("max_tokens", limit)
        for max_tokens in (own, 2 * own):
            r = generate(model, processor, chat, image=imgs, max_tokens=max_tokens, temperature=0.0, verbose=False)
            try:
                W.parse_answer(re.sub(r"<think>.*?</think>", "", r.text, flags=re.S), w["window"])
            except (W.ParseError, TypeError, ValueError, KeyError, AttributeError):
                continue
            status = "ok"
            break
        recs.append({"window": w["window"], "status": status, "wall_s": round(time.time() - t1, 1),
                     "peak_gb": mx.get_peak_memory() / 2**30})
        print(f"[{k}/{len(rows)}] {w['box']} {w['window'][0]}-{w['window'][-1]} {status} {recs[-1]['wall_s']}s "
              f"peak {recs[-1]['peak_gb']:.1f} GB", flush=True)
    return recs, load_s


def cmd_mac(a):
    """Convert and quantise the merged student into an MLX build (or take one already made), time a warm-up on the
    pack, and write the build's Mac figures beside its weights for `check`."""
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    import model_store
    model_store.use()   # before mlx_vlm (convert or load) imports huggingface_hub, which reads HF_HOME once
    pack = Path(a.pack)
    rows = [json.loads(l) for l in (pack / "windows.jsonl").read_text().splitlines() if l.strip()]
    if len(rows) < 2:
        raise SystemExit(f"{pack} has {len(rows)} windows; the warm-up needs two or more")
    if a.merged:
        if not a.out:
            raise SystemExit("--merged needs --out, a new folder for the build")
        out = Path(a.out)
        if out.exists():
            raise SystemExit(f"{out} exists; pick a new path")
        mlx_convert(a.merged, out, a.bits)
    else:
        out = Path(a.build)
    if not (out / "config.json").is_file():
        raise SystemExit(f"{out} holds no MLX build (no config.json)")
    q = json.loads((out / "config.json").read_text()).get("quantization") or {}
    build = f"{q['bits']}-bit MLX" if q.get("bits") else "MLX, not quantised"
    build += f" ({folder_bytes(out, '*.safetensors') * 8 / safetensors_params(out):.1f} bits a weight)"
    limit = json.loads((pack / "pack.json").read_text()).get("max_tokens", 1500) if (pack / "pack.json").is_file() else 1500
    recs, load_s = warm_up(out, pack, rows[: a.windows + 1], limit)
    pages = len({(w["box"], n) for w in rows for n in w["window"]})
    fig = mac_figures(recs, load_s, len(rows), pages, build, folder_bytes(out), measured_on(), pack.name)
    (out / MAC_FIGURES).write_text(json.dumps(fig, indent=1) + "\n")
    print(json.dumps(fig, indent=1))
    print(f"wrote {out / MAC_FIGURES}. Next, with the cluster's runs of this model and the shipped one:\n"
          f"  python3 train_seg.py check --run shipped=RUNS/shipped-holdout,RUNS/shipped-anchor "
          f"--run mine=RUNS/mine-holdout,RUNS/mine-anchor --candidate mine --anchor-truth ANCHOR.json "
          f"--labels labels.jsonl --weights {out} --note 'scores from the cluster run at full precision; the weights "
          f"and Mac figures are this {build} build'")
    if fig["windows_unparsed"]:
        print(f"{fig['windows_unparsed']} of {len(recs)} windows gave no answer that parses, after a retry: the build "
              f"may be broken; compare it with the cluster's answers before using it", file=sys.stderr)
        return 1
    return 0


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
    p = sub.add_parser("check")
    p.add_argument("--run", action="append", required=True, help="NAME=DIR[,DIR]: one scored run, its cluster_seg.py run dirs (answers.jsonl); repeat a NAME for a second run")
    p.add_argument("--candidate", required=True); p.add_argument("--shipped", default="shipped")
    p.add_argument("--anchor-truth", required=True, help="a locked public box, segbench-results/public-segmentation/<box>.json")
    p.add_argument("--labels", help="corpus_pairs.py labels.jsonl (held-out gaps and their tags)")
    p.add_argument("--ruled", help="owner rulings: folder_id,n,new|same per line")
    p.add_argument("--base-build"); p.add_argument("--weights"); p.add_argument("--adapter"); p.add_argument("--data")
    p.add_argument("--mac", help=f"the Mac figures as JSON (seconds a page, peak GB, download GB, measured on); "
                                 f"default {MAC_FIGURES} in the --weights folder")
    p.add_argument("--note", help="what the figures were measured on, if not the weights hashed")
    p.add_argument("--out", help=f"default {MANIFEST} in the --weights folder")
    p = sub.add_parser("mac")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--merged", help="the merged student (`merge`), to convert and quantise into --out")
    g.add_argument("--build", help="an MLX build already made, to time only")
    p.add_argument("--out", help="the new build's folder (with --merged)")
    p.add_argument("--pack", required=True, help="a cluster_seg.py pack (windows.jsonl, images/): the anchor pack")
    p.add_argument("--bits", type=int, choices=(4, 8), default=8)
    p.add_argument("--windows", type=int, default=8, help="windows timed, after one untimed")
    a = ap.parse_args()
    sys.exit({"data": cmd_data, "train": cmd_train, "merge": cmd_merge, "check": cmd_check, "mac": cmd_mac}[a.cmd](a))


if __name__ == "__main__":
    main()
