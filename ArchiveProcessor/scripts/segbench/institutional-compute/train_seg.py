#!/usr/bin/env python3
"""W41.seg-finetune. LoRA-train a small Qwen3.5 vision model to answer the bench's segmentation windows.

  train_seg.py data  --pack DIR --answers FILE --labels FILE --windows FILE --out DIR [--rule agree|start-trust]
                                                                        # Mac or node: the training set
  train_seg.py train --data DIR --model Qwen/Qwen3.5-4B --out DIR [--epochs 1] [--max-windows N]
  train_seg.py merge --adapter DIR --out DIR                            # base + LoRA -> one model vLLM can serve
  train_seg.py check --run shipped=DIR --run NAME=DIR[,DIR] --candidate NAME --anchor-truth BOX.json
                     [--labels labels.jsonl] [--ruled FILE] [--weights DIR] [--data DIR] --out manifest.json
                                                                        # W46.kit-gate: the held-out gate + manifest

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
to 98%), with bootstrap intervals by folder and by document, paired against the shipped model. It writes the
candidate's manifest (`archive-seg-manifest.json` beside the weights is what the app reads): prompt id, kit version,
weights and training-data hashes, the scores, and the gate's verdict; it exits 1 when the gate fails. The app refuses a
model whose manifest lacks the anchor score or names another prompt (`LocalSegmenter.refusal`). Sizes, from
kit_gate.py: separating 3 points of pages exact takes about 2,000 held-out gaps; gap accuracy about 200.

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
GATE_POINTS = 3.0         # a candidate may trail the shipped model by less than this on held-out gaps (kit_gate.py)
BAR = 0.98                # the review load is counted to 98% of pages in the exact document
DRAWS, CHECK_SEED = 2000, 46


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


def gap_score(groups, rng):
    """groups: {group: [(model right, reference right or None), ...]}. The model's accuracy, its interval and, with
    a reference, the paired difference model - reference, all by resampling groups (folders) with replacement."""
    keys = sorted(groups)
    flat = [x for k in keys for x in groups[k]]
    out = {"gaps": len(flat), "accuracy": round(100 * sum(a for a, _ in flat) / max(1, len(flat)), 2)}
    if not flat:
        return out
    paired = [(a, b) for a, b in flat if b is not None]
    acc, diff = [], []
    for _ in range(DRAWS):
        n = ra = m = d = 0
        for _ in keys:
            for a, b in groups[keys[rng.randrange(len(keys))]]:
                n += 1; ra += a
                if b is not None:
                    m += 1; d += a - b
        acc.append(ra / max(1, n)); diff.append(d / max(1, m))
    out["interval"] = pct_interval(acc)
    if paired:   # over the gaps both answered
        out["paired_gaps"] = len(paired)
        out["difference"] = round(100 * sum(a - b for a, b in paired) / len(paired), 2)
        out["difference_interval"] = pct_interval(diff)
    return out


def heldout_groups(labels, ruled, p_a, p_b):
    """Per folder, (model right, reference right) on every held-out gap both answered: against the tags, and against
    the owner's rulings where given. p_b (the reference) None when there is none."""
    tags, own = {}, {}
    for g in labels:
        if g["split"] != "holdout":
            continue
        k = (g["folder_id"], g["n"])
        if k not in p_a:
            continue
        for truth, dst in ((g["tag"], tags), (ruled.get(k), own)):
            if truth is None:
                continue
            ra = (p_a[k] >= 0.5) == (truth == "new")
            rb = None if p_b is None or k not in p_b else (p_b[k] >= 0.5) == (truth == "new")
            dst.setdefault(g["folder_id"], []).append((ra, rb))
    return tags, own


def anchor_docs(truth_pages, box, p):
    """The anchor box's truth documents, each (pages, exact) for the predicted labels, and its gaps (confidence,
    right), from the per-gap P(new). None when a gap was not answered."""
    labels = [q["label"] for q in truth_pages]
    nums = [q["n"] for q in truth_pages]
    pnew = [p.get((box, nums[i])) for i in range(len(nums) - 1)]
    if any(x is None for x in pnew):
        return None
    pred = ["New"] + ["New" if x >= 0.5 else "Cont" for x in pnew]

    def seg_ids(ls):
        out, k = [], -1
        for t in ls:
            k += t == "New"; out.append(k)
        return out

    def exact_docs(pred_labels):
        tid, pid = seg_ids(labels), seg_ids(pred_labels)
        tsets, psets = {}, {}
        for i, (a, b) in enumerate(zip(tid, pid)):
            tsets.setdefault(a, set()).add(i); psets.setdefault(b, set()).add(i)
        pfs = {frozenset(s) for s in psets.values()}
        return [(len(s), frozenset(s) in pfs) for s in tsets.values()]

    gaps = [(max(x, 1 - x), (x >= 0.5) == (labels[i + 1] == "New")) for i, x in enumerate(pnew)]
    docs = exact_docs(pred)
    # Review load at the bar: check the least confident gaps first (each corrected to the truth) until 98% of pages
    # sit in the exact document; the number checked per 100 pages.
    order = sorted(range(len(pnew)), key=lambda i: gaps[i][0])
    fixed, checked = list(pred), None
    for k in range(len(order) + 1):
        if sum(n for n, e in exact_docs(fixed) if e) >= BAR * len(labels):
            checked = k
            break
        if k < len(order):
            i = order[k]
            fixed[i + 1] = labels[i + 1]
    return {"docs": docs, "gaps": gaps,
            "review_load_per_100_pages": None if checked is None else round(100 * checked / len(labels), 1)}


def anchor_score(a_docs, b_docs, rng):
    """The model's (a) anchor figures with a document-bootstrap interval, and with a reference (b, the shipped model)
    the paired difference a - b in pages exact."""
    pages = sum(n for n, _ in a_docs["docs"])
    out = {"pages": pages, "documents": len(a_docs["docs"]),
           "pages_exact": round(100 * sum(n for n, e in a_docs["docs"] if e) / pages, 2),
           "gap_accuracy": round(100 * sum(r for _, r in a_docs["gaps"]) / len(a_docs["gaps"]), 2),
           "review_load_per_100_pages": a_docs["review_load_per_100_pages"]}
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
    import hashlib
    h = hashlib.sha256()
    files = sorted(q for q in Path(path).rglob("*") if q.is_file()) if Path(path).is_dir() else [Path(path)]
    for q in files:
        h.update(q.relative_to(path).as_posix().encode() if Path(path).is_dir() else b"")
        with open(q, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    return h.hexdigest()


def cmd_check(a):
    """Score base, shipped and candidate on the held-out collections (against the tags, and against the owner's
    rulings where given) and on a locked public anchor box, then write the candidate's manifest. Reads answers only."""
    runs = {}
    for spec in a.run:
        name, _, dirs = spec.partition("=")
        runs[name] = run_votes(dirs.split(","))
    if a.candidate not in runs:
        raise SystemExit(f"--candidate {a.candidate} has no --run")
    shipped = runs.get(a.shipped)
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
    for name, (p, failed) in runs.items():
        row = {"failed_windows": failed}
        cmp = shipped[0] if shipped and name != a.shipped else None
        if labels:
            tags, own = heldout_groups(labels, ruled, p, cmp)
            row["heldout_tags"] = gap_score(tags, rng) if tags else None
            row["heldout_ruled"] = gap_score(own, rng) if own else None
        ad = anchor_docs(truth["pages"], box, p)
        sd = anchor_docs(truth["pages"], box, cmp) if cmp else None
        row["anchor"] = anchor_score(ad, sd, rng) if ad else None
        report["models"][name] = row
    cand = report["models"][a.candidate]
    reasons = []
    if not cand["anchor"]:
        reasons.append(f"no anchor score: the run has no answer for every gap of {box}")
    held = cand.get("heldout_ruled") or cand.get("heldout_tags")
    if a.candidate != a.shipped and held and "difference_interval" in held and held["difference_interval"][0] <= -GATE_POINTS:
        reasons.append(f"on held-out gaps it may trail the shipped model by {GATE_POINTS:g} points or more "
                       f"(difference {held['difference']}, interval {held['difference_interval']})")
    if held is None:
        reasons.append("no held-out score")
    manifest = {
        "kit_version": KIT_VERSION, "prompt_id": PROMPT_ID, "bench_request": "method_local.request (o1), 1024 px",
        "model": a.candidate, "base_build": a.base_build,
        "weights_sha256": sha256_of(a.weights) if a.weights else None,
        "adapter": ({"sha256": sha256_of(a.adapter), **{k: v for k, v in
                     json.loads((Path(a.adapter).parent / "train.json").read_text()).items() if k in ("rank", "model")}}
                    if a.adapter else None),
        "training_data": ({"sha256": sha256_of(Path(a.data) / "train.jsonl"),
                           "rule": json.loads((Path(a.data) / "data.json").read_text()).get("rule")} if a.data else None),
        "heldout": {"tags": cand.get("heldout_tags"), "owner_ruled": cand.get("heldout_ruled")},
        "anchor": None if not cand["anchor"] else {"box": box, "truth_sha256": sha256_of(a.anchor_truth), **cand["anchor"]},
        "review_load_at_98": None if not cand["anchor"] else cand["anchor"]["review_load_per_100_pages"],
        "mac": json.loads(Path(a.mac).read_text()) if a.mac else None, "note": a.note,
        "gate": {"rule": f"an anchor score, a held-out score, and a held-out interval against the shipped model "
                         f"whose low end is above -{GATE_POINTS:g} points (proposed, W46.kit-gate)",
                 "passed": not reasons, "reasons": reasons},
        "compared": report["models"], "made": time.strftime("%Y-%m-%dT%H:%M:%S")}
    out = Path(a.out)
    out.write_text(json.dumps(manifest, indent=1) + "\n")
    print(json.dumps({k: manifest[k] for k in ("model", "anchor", "heldout", "gate")}, indent=1))
    print("wrote", out)
    return 0 if not reasons else 1


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
    p.add_argument("--run", action="append", required=True, help="NAME=DIR[,DIR]: cluster_seg.py run dirs (answers.jsonl)")
    p.add_argument("--candidate", required=True); p.add_argument("--shipped", default="shipped")
    p.add_argument("--anchor-truth", required=True, help="a locked public box, segbench-results/public-segmentation/<box>.json")
    p.add_argument("--labels", help="corpus_pairs.py labels.jsonl (held-out gaps and their tags)")
    p.add_argument("--ruled", help="owner rulings: folder_id,n,new|same per line")
    p.add_argument("--base-build"); p.add_argument("--weights"); p.add_argument("--adapter"); p.add_argument("--data")
    p.add_argument("--mac", help="the Mac figures as JSON (seconds a page, peak GB, download GB, measured on)")
    p.add_argument("--note", help="what the figures were measured on, if not the weights hashed")
    p.add_argument("--out", required=True)
    a = ap.parse_args()
    sys.exit({"data": cmd_data, "train": cmd_train, "merge": cmd_merge, "check": cmd_check}[a.cmd](a))


if __name__ == "__main__":
    main()
