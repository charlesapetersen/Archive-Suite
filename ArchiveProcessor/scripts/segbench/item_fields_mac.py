#!/usr/bin/env python3
"""W47.wh-item-fields-mac: the item fields read by the models that run on this Mac, on three inputs, scored on the
owner-checked pairs (owner, 2026-11-19, call 15: "This should be tested not only with Vision but with other models
that can run on the Mac").

    heavy-run.py run -- <lab venv>/bin/python item_fields_mac.py lighton        # the hand pages' LightOnOCR text
    heavy-run.py run -- <lab venv>/bin/python item_fields_mac.py run --model K --input I [--limit N]
    python3 item_fields_mac.py status
    python3 item_fields_score.py                                                # the score page, these rows in it

<lab venv> is ~/.local/share/visionocr-ocrlab/venv (mlx_vlm). K is a MODELS key; I is one of INPUTS:
- vision: the document's Apple Vision text, with page marks, as the drafters had it (item_fields_retruth.doc_text,
  its first TEXT_CAP characters); no image.
- mac: the text of the best reader that runs on the Mac for each page: LightOnOCR-3 4B (8-bit, its card's settings,
  ocr_mac_local.HW) on the handwritten part's pages, Apple Vision on the rest; no image. It differs from vision only
  on the handwritten part's documents, so it is run on those alone and the score takes the vision reading elsewhere.
- image: the drafters' own input, the capped pages' images (the upload copies, cut to IMAGE_SIDE px on the long
  side for the Mac) with the Vision text.

The prompt is item_fields_retruth.PROMPT, the image prompt the fill verdict chose, word for word; for the two text
inputs its first sentences say that no images come and read the text alone (TEXT_PROMPT). Temperature 0, thinking
off (Qwen3.5 thinks unless told not to), MAX_TOKENS tokens. The 299 documents of W47.item-fields-retruth; the score
item judges these routes on the drafted truth, as the other local rows, with the owner-checked pairs beside.

The models: Qwen3-VL 8B and Qwen3.5 4B, 4-bit MLX, from the shared model store. Qwen3.6 27B is not run: its 4-bit
weights are about 16 GB, this Mac has 18 GB of memory, of which a session may use 65% (11.7 GB), and the disk had
16 GB free, so the Mac does not hold it. No ABBYY text is read (owner, 2026-10-30). $0: nothing leaves the Mac.
Texts and readings stay in the bench cache (the owner's material); the report has counts only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import item_fields as IF  # noqa: E402
import item_fields_retruth as IR  # noqa: E402

CACHE = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal/item-fields-mac")
MODELS = {"qwen3-vl-8b": ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "Qwen3-VL 8B, 4-bit MLX"),
          "qwen3.5-4b": ("lmstudio-community/Qwen3.5-4B-MLX-4bit", "Qwen3.5 4B, 4-bit MLX")}
INPUTS = {"vision": "Apple Vision text", "mac": "the Mac readers' text (LightOnOCR on the hand pages)",
          "image": "the page images with the Vision text"}
HAND = "handwritten"
IMAGE_SIDE = 1280
MAX_TOKENS = 1024
LIGHTON = "lightonocr-3-4b-mlx8"

TEXT_OPENING = ("You get the text machine OCR read from the pages of one document (all of them, or for a long "
                "document the first 8 and the last 2), with page marks (it may be noisy). No images are given: "
                "read the text.")
IMAGE_OPENING = ("You get images of the pages of one document (all of them, or for a long document the first 8 and "
                 "the last 2) and the text machine OCR read from them, with page marks (it may be noisy). Read the "
                 "images as well as the text.")
assert IMAGE_OPENING in IR.PROMPT.replace("\\\n", ""), "item_fields_retruth.PROMPT changed: re-derive TEXT_PROMPT"
TEXT_PROMPT = IR.PROMPT.replace(IMAGE_OPENING, TEXT_OPENING)
assert TEXT_PROMPT != IR.PROMPT


def key(p):
    return hashlib.sha1(p.encode()).hexdigest()[:16]


def lighton_path(p):
    return os.path.join(CACHE, "lighton", key(p) + ".json")


def lighton_text(p):
    f = lighton_path(p)
    return json.load(open(f, encoding="utf-8"))["text"] if os.path.exists(f) else None


def small_path(p):
    return os.path.join(CACHE, "img", key(p) + ".jpg")


def doc_text(d, inp):
    """The text the model is shown: Vision's, or for `mac` LightOnOCR's on the hand part's pages."""
    if inp != "mac" or d["part"] != HAND:
        return IR.doc_text(d)
    ps = IR.capped(d["pages"])
    n = len(d["pages"])
    idx = {p: i + 1 for i, p in enumerate(d["pages"])}
    return "\n\n".join(f"[page {idx[p]} of {n}]\n{(lighton_text(p) or '').strip()}" for p in ps)


def prompt_of(d, inp):
    tpl = IR.PROMPT if inp == "image" else TEXT_PROMPT
    return tpl.replace("{text}", doc_text(d, inp)[:IR.TEXT_CAP])


def wanted(d, inp):
    return inp != "mac" or d["part"] == HAND


def ready(d, inp):
    if not IR.ready(d):
        return False
    if inp == "mac" and d["part"] == HAND:
        return all(lighton_text(p) is not None for p in IR.capped(d["pages"]))
    return True


def reading_path(model, inp, doc_id):
    return os.path.join(CACHE, "readings", model, inp, doc_id + ".json")


def reading(model, inp, doc_id):
    """The parsed reading for the score, or None. For `mac`, a document outside the hand part takes its vision
    reading, since its text is the same."""
    if inp == "mac" and doc_id not in hand_ids():
        inp = "vision"
    p = reading_path(model, inp, doc_id)
    if not os.path.exists(p):
        return None
    r = IF.parse(json.load(open(p, encoding="utf-8"))["raw"])
    return r if r is not None else {f: None for f in IF.FIELDS}   # an unparsed reply fills nothing


_HAND = None


def hand_ids():
    global _HAND
    if _HAND is None:
        _HAND = {d["id"] for d in IR.load_docs() if d["part"] == HAND}
    return _HAND


def route_rows():
    """(score key, label, short) for item_fields_score, one per model and input with any reading on disk."""
    out = []
    for m, (_repo, name) in MODELS.items():
        for inp, what in INPUTS.items():
            if os.path.isdir(os.path.join(CACHE, "readings", m, inp)):
                short = name.split(",")[0]
                out.append((f"mac-{m}-{inp}", f"{short}, item prompt on {what} (Mac)", f"{short} on {inp}"))
    return out


def predictions(ids):
    P = {}
    for m in MODELS:
        for inp in INPUTS:
            if os.path.isdir(os.path.join(CACHE, "readings", m, inp)):
                P[f"mac-{m}-{inp}"] = {i: reading(m, inp, i) for i in ids}
    return P


# --- runs (the lab venv, under the heavy lock) -------------------------------------------------------------------

def shrink(p):
    out = small_path(p)
    if not os.path.exists(out):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        from PIL import Image
        im = Image.open(IR.send_path(p))
        im.thumbnail((IMAGE_SIDE, IMAGE_SIDE))
        im.convert("RGB").save(out + ".tmp.jpg", quality=90)
        os.replace(out + ".tmp.jpg", out)
    return out


def save(path, rec):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w", encoding="utf-8") as fh:
        json.dump(rec, fh, ensure_ascii=False)
    os.replace(path + ".tmp", path)


def cmd_run(a):
    import model_store
    model_store.use()
    os.environ["HF_HUB_OFFLINE"] = "1"
    docs = [d for d in IR.load_docs() if wanted(d, a.input)]
    todo = [d for d in docs if not os.path.exists(reading_path(a.model, a.input, d["id"]))]
    missing = [d["id"] for d in todo if not ready(d, a.input)]
    if missing:
        sys.exit(f"{len(missing)} documents lack their inputs (run `lighton` first?): {missing[:5]}")
    todo = todo[: a.limit or None]
    print(f"{a.model} {a.input}: {len(todo)} of {len(docs)} documents to read", flush=True)
    if not todo:
        return
    import mlx.core as mx
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    mx.set_cache_limit(256 * 2**20)
    model, processor = load(IF.local_snapshot(MODELS[a.model][0]))
    for k, d in enumerate(todo, 1):
        imgs = [shrink(p) for p in IR.capped(d["pages"])] if a.input == "image" else []
        prompt = prompt_of(d, a.input)
        try:
            chat = apply_chat_template(processor, model.config, prompt, num_images=len(imgs), enable_thinking=False)
        except TypeError:
            chat = apply_chat_template(processor, model.config, prompt, num_images=len(imgs))
        start, text, last = time.time(), [], None
        kw = {"image": imgs} if imgs else {}
        for r in stream_generate(model, processor, chat, max_tokens=MAX_TOKENS, temperature=0.0, **kw):
            text.append(r.text)
            last = r
        rec = {"id": d["id"], "raw": "".join(text), "wall_s": round(time.time() - start, 2), "images": len(imgs),
               "tokens": [getattr(last, "prompt_tokens", 0), getattr(last, "generation_tokens", 0)],
               "peak_gb": round(mx.get_peak_memory() / 2**30, 2), "model": MODELS[a.model][0],
               "image_side": IMAGE_SIDE if imgs else None, "max_tokens": MAX_TOKENS}
        save(reading_path(a.model, a.input, d["id"]), rec)
        ok = IF.parse(rec["raw"]) is not None
        print(f"[{k}/{len(todo)}] {d['id']} {rec['wall_s']}s {len(imgs)} img {rec['tokens']} "
              f"{'ok' if ok else 'UNPARSED'}", flush=True)
        mx.clear_cache()


def cmd_lighton(a):
    import ocr_mac_local as L   # first: it calls model_store.use() before huggingface_hub is imported
    import mlx.core as mx
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    from PIL import Image
    os.environ["HF_HUB_OFFLINE"] = "1"
    spec = L.HW[LIGHTON]
    pages = [p for d in IR.load_docs() if d["part"] == HAND for p in IR.capped(d["pages"])]
    todo = [p for p in pages if not os.path.exists(lighton_path(p))]
    print(f"lighton: {len(todo)} of {len(pages)} hand pages to read", flush=True)
    if not todo:
        return
    mx.set_cache_limit(256 * 2**20)
    model, processor = load(str(spec["repo"]), trust_remote_code=True)
    chat = apply_chat_template(processor, model.config, spec["prompt"], num_images=1)
    cap = spec["max_tokens"]
    os.makedirs(os.path.join(CACHE, "lighton"), exist_ok=True)
    for p in todo:
        # The upload copy (1,600 px) is the largest image the cache keeps; LightOnOCR's card allows up to 2,048.
        im = Image.open(IR.send_path(p))
        assert max(im.size) <= spec["max_side"]
        start, text, last = time.time(), [], None
        for r in stream_generate(model, processor, chat, image=[IR.send_path(p)], max_tokens=cap, temperature=0.0):
            text.append(r.text)
            last = r
        save(lighton_path(p), {"text": "".join(text).strip(), "wall_s": round(time.time() - start, 2),
                               "finish": "length" if last is not None and last.generation_tokens >= cap else "stop",
                               "side": max(im.size)})
        print(f"lighton: {key(p)} {time.time() - start:.0f} s", flush=True)
        mx.clear_cache()


def median(xs):
    xs = sorted(xs)
    return xs[len(xs) // 2] if xs else None


def run_summary():
    """For the score page: per route, documents read, unparsed replies, median seconds, images and peak memory; and
    the LightOnOCR pass."""
    if not os.path.isdir(CACHE):
        return {}
    docs = IR.load_docs()
    out = {}
    for m in MODELS:
        for inp in INPUTS:
            got = [json.load(open(reading_path(m, inp, d["id"]), encoding="utf-8")) for d in docs
                   if wanted(d, inp) and os.path.exists(reading_path(m, inp, d["id"]))]
            if got:
                out[f"mac-{m}-{inp}"] = {
                    "docs": len(got), "of": sum(wanted(d, inp) for d in docs),
                    "unparsed": sum(IF.parse(r["raw"]) is None for r in got),
                    "median_s": median([r["wall_s"] for r in got]), "total_h": round(sum(r["wall_s"] for r in got) / 3600, 2),
                    "median_prompt_tokens": median([r["tokens"][0] for r in got]),
                    "at_max_tokens": sum(r["tokens"][1] >= MAX_TOKENS for r in got),
                    "peak_gb": max(r.get("peak_gb") or 0 for r in got)}
    lt = [json.load(open(lighton_path(p), encoding="utf-8")) for d in docs if d["part"] == HAND
          for p in IR.capped(d["pages"]) if os.path.exists(lighton_path(p))]
    if lt:
        out["lighton"] = {"pages": len(lt), "median_s": median([r["wall_s"] for r in lt]),
                          "at_max_tokens": sum(r["finish"] == "length" for r in lt)}
    return out


def cmd_status(a):
    docs = IR.load_docs()
    hand = sum(1 for p in (p for d in docs if d["part"] == HAND for p in IR.capped(d["pages"])) if lighton_text(p) is not None)
    print(f"lighton: {hand} of {sum(len(IR.capped(d['pages'])) for d in docs if d['part'] == HAND)} hand pages")
    for m in MODELS:
        for inp in INPUTS:
            n = [d for d in docs if wanted(d, inp)]
            got = [json.load(open(reading_path(m, inp, d["id"]))) for d in n
                   if os.path.exists(reading_path(m, inp, d["id"]))]
            walls = sorted(r["wall_s"] for r in got)
            med = walls[len(walls) // 2] if walls else None
            bad = sum(IF.parse(r["raw"]) is None for r in got)
            print(f"{m} {inp}: {len(got)} of {len(n)}, median {med} s, unparsed {bad}, "
                  f"peak {max((r.get('peak_gb') or 0) for r in got) if got else '-'} GB")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--model", choices=MODELS, required=True)
    r.add_argument("--input", choices=INPUTS, required=True)
    r.add_argument("--limit", type=int)
    sub.add_parser("lighton")
    sub.add_parser("status")
    a = ap.parse_args()
    {"run": cmd_run, "lighton": cmd_lighton, "status": cmd_status}[a.cmd](a)


if __name__ == "__main__":
    main()
