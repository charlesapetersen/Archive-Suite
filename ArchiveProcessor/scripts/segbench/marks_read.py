#!/usr/bin/env python3
"""Whether found marks can be read: the transcription arm of W46.marks-detect.

  <lab venv>/bin/python marks_read.py crops               # mark crops: truth boxes (oracle) and detector boxes
  heavy-run.py run -- <lab venv>/bin/python marks_read.py read vision     # Apple Vision (segbench-ocr) on the crops
  heavy-run.py run -- <lab venv>/bin/python marks_read.py read lighton    # LightOnOCR-3 4B 8-bit, mlx-vlm (*)
  <lab venv>/bin/python marks_read.py report              # segbench-results/marks-read.{json,md}

The 35 owner-reviewed mark texts on the 32 detector-eligible core pages (reconciled record). Each mark is cropped
from the freeze's 2,400 px copy with 1% of the page added on every side, since the truth boxes are rough drafts,
and a crop whose longer side is under 768 px is enlarged to it. The oracle arm crops the truth box. The detector arms
crop the YOLO11m box (Sherlock PyTorch run) matched to the mark one to one at IoU >= 0.1 over all the page's marks,
at the default floor 0.25 and at 0.05; a mark with no matched box reads as nothing. Scored per box: NES, 1 -
Levenshtein / longer length, on NFKC text with whitespace collapsed, case kept; a mark counts as read at NES >= 0.8.
A box that contains other marks (RG165) is scored on its own text, so the others' words count against it.
(*) With ARCHIVE_MODEL_HF_HOME="~/Library/Application Support/Vision OCR/Models" where the shared cache lacks the
weights (the Vision OCR app holds them); loaded by path, offline, read only.
Mark texts and readings stay in the private cache; the report holds aggregates only. No network, no money.
"""
from __future__ import annotations

import json
import random
import subprocess
import sys
import time
import unicodedata
from pathlib import Path

import marks_detect as D

WORK = D.WORK / "read"
CROPS = WORK / "crops"
RESULTS = D.RESULTS
OCR_BIN = Path.home() / "Library/Caches/ArchiveSuiteRehearsal/segbench/bin/segbench-ocr"
FLOORS = {"det25": 0.25, "det05": 0.05}
PAD, MIN_SIDE, READ = 0.01, 768, 0.8
READERS = {"vision": "Apple Vision (the app's settings)", "lighton": "LightOnOCR-3 4B 8-bit (mlx-vlm)",
           # Chosen after seeing LightOnOCR answer nothing on 8 short marks, so a hypothesis, not a ranked route.
           "fallback": "LightOnOCR-3 4B, Vision where it answers nothing (post hoc)"}


def marks():
    """[(page, index, mark)] for the owner-reviewed texts on detector-eligible pages, with every mark per page."""
    pages = json.loads((D.RECORD / "reconciled.json").read_text())["pages"]
    out, allm = [], {}
    for pid, p in sorted(pages.items()):
        if not p["detector_evaluable"]:
            continue
        allm[pid] = p["marks"]
        out += [(pid, i, m) for i, m in enumerate(p["marks"]) if m.get("transcription_evaluable")]
    return out, allm


def pairs(gt, pred, thr):
    """{truth index: prediction index}, the same one-to-one greedy match as marks_detect.match."""
    cand = sorted(((D.iou(g, p), i, j) for i, g in enumerate(gt) for j, p in enumerate(pred)), reverse=True)
    got, used = {}, set()
    for v, i, j in cand:
        if v < thr:
            break
        if i not in got and j not in used:
            got[i] = j
            used.add(j)
    return got


def plan():
    """{arm: {mark id: box or None}} — the box each arm reads for each scored mark."""
    todo, allm = marks()
    preds = json.loads((D.CLUSTER / "public.json").read_text())["pages"]
    out = {"oracle": {f"{pid}#{i}": m["box"] for pid, i, m in todo}}
    for arm, floor in FLOORS.items():
        boxes = D.boxes(preds, floor)
        got = {pid: pairs([m["box"] for m in allm[pid]], boxes.get(pid, []), D.RULES["hit"]) for pid in allm}
        out[arm] = {f"{pid}#{i}": (boxes[pid][got[pid][i]] if i in got[pid] else None) for pid, i, _ in todo}
    return out


def crop_name(pid, box):
    return f"{pid}_" + "_".join(f"{v:.4f}" for v in box) + ".png"


def crops():
    from PIL import Image
    CROPS.mkdir(parents=True, exist_ok=True)
    made = 0
    for arm, rows in plan().items():
        for mid, box in rows.items():
            if box is None:
                continue
            pid = mid.split("#")[0]
            dest = CROPS / crop_name(pid, box)
            if dest.exists():
                continue
            im = Image.open(D.IMAGES / f"{pid}.jpg").convert("RGB")
            W, H = im.size
            x0, y0 = max(0, box[0] - PAD) * W, max(0, box[1] - PAD) * H
            x1, y1 = min(1, box[2] + PAD) * W, min(1, box[3] + PAD) * H
            c = im.crop((round(x0), round(y0), round(x1), round(y1)))
            if max(c.size) < MIN_SIDE:
                k = MIN_SIDE / max(c.size)
                c = c.resize((round(c.size[0] * k), round(c.size[1] * k)), Image.LANCZOS)
            c.save(dest)
            made += 1
    print(f"{made} crops made, {len(list(CROPS.glob('*.png')))} in {CROPS}")


def read_vision():
    out = WORK / "vision"
    out.mkdir(parents=True, exist_ok=True)
    jobs = WORK / "vision-jobs.tsv"
    jobs.write_text("".join(f"{c}\t{out / (c.stem + '.txt')}\n" for c in sorted(CROPS.glob("*.png"))))
    t0 = time.time()
    subprocess.run([str(OCR_BIN), str(jobs)], check=True)
    print(f"vision: {time.time() - t0:.1f} s")


def read_lighton():
    import os
    import ocr_mac_local as L  # first: it calls model_store.use() before huggingface_hub is imported
    import mlx.core as mx
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    spec = L.HW["lightonocr-3-4b-mlx8"]
    os.environ["HF_HUB_OFFLINE"] = "1"
    out = WORK / "lighton"
    out.mkdir(parents=True, exist_ok=True)
    todo = [c for c in sorted(CROPS.glob("*.png")) if not (out / (c.stem + ".json")).exists()]
    print(f"lighton: {len(todo)} crops to read", flush=True)
    if not todo:
        return
    mx.set_cache_limit(256 * 2**20)
    model, processor = load(str(spec["repo"]), trust_remote_code=True)
    chat = apply_chat_template(processor, model.config, spec["prompt"], num_images=1)
    for c in todo:
        start = time.time()
        text, last = [], None
        for r in stream_generate(model, processor, chat, image=[str(c)], max_tokens=512, temperature=0.0):
            text.append(r.text)
            last = r
        (out / (c.stem + ".json")).write_text(json.dumps(dict(
            text="".join(text).strip(), wall_s=round(time.time() - start, 2),
            finish="length" if last is not None and last.generation_tokens >= 512 else "stop")))
    print(f"lighton: read {len(todo)}")


def reading(reader, pid, box):
    if reader == "fallback":
        got = reading("lighton", pid, box)
        return reading("vision", pid, box) if got is not None and not got.strip() else got
    stem = crop_name(pid, box)[:-4]
    if reader == "vision":
        f = WORK / "vision" / f"{stem}.txt"
        return f.read_text() if f.exists() else None
    f = WORK / "lighton" / f"{stem}.json"
    return json.loads(f.read_text())["text"] if f.exists() else None


def norm(s):
    return " ".join(unicodedata.normalize("NFKC", s or "").split())


def nes(truth, hyp):
    from rapidfuzz.distance import Levenshtein
    a, b = norm(truth), norm(hyp)
    n = max(len(a), len(b))
    return 1 - Levenshtein.distance(a, b) / n if n else 1.0


def boot(rows, n=2000, seed=46):
    """Page bootstrap of (mean NES, read share) over the rows [(page, nes)]."""
    by = {}
    for pid, v in rows:
        by.setdefault(pid, []).append(v)
    pages = list(by)
    rng = random.Random(seed)
    means, reads = [], []
    for _ in range(n):
        s = [v for _ in pages for v in by[pages[rng.randrange(len(pages))]]]
        means.append(sum(s) / len(s))
        reads.append(sum(v >= READ for v in s) / len(s))
    q = lambda xs: [round(sorted(xs)[int(0.025 * n)], 3), round(sorted(xs)[int(0.975 * n) - 1], 3)]
    return q(means), q(reads)


def report():
    todo, _ = marks()
    text = {f"{pid}#{i}": m["text"] for pid, i, m in todo}
    cls = {f"{pid}#{i}": m["cls"] for pid, i, m in todo}
    res = {}
    for reader in READERS:
        for arm, rows in plan().items():
            got = []
            missing = 0
            for mid, box in rows.items():
                pid = mid.split("#")[0]
                hyp = "" if box is None else reading(reader, pid, box)
                if hyp is None:
                    missing += 1
                    hyp = ""
                got.append((pid, mid, nes(text[mid], hyp), box is not None))
            if missing:
                raise SystemExit(f"{reader}/{arm}: {missing} crops not read yet")
            vals = [(p, v) for p, _, v, _ in got]
            ci_mean, ci_read = boot(vals)
            boxed = [v for _, _, v, b in got if b]
            res[f"{reader}/{arm}"] = dict(
                marks=len(got), boxed=len(boxed), mean_nes=round(sum(v for _, v in vals) / len(vals), 3),
                mean_ci=ci_mean, read=sum(v >= READ for _, v in vals), read_ci=ci_read,
                mean_nes_boxed=round(sum(boxed) / len(boxed), 3) if boxed else None,
                by_class={c: dict(n=sum(1 for _, m, _, _ in got if cls[m] == c),
                                  read=sum(1 for _, m, v, _ in got if cls[m] == c and v >= READ))
                          for c in sorted(set(cls.values()))})
    lt = [json.loads(f.read_text())["wall_s"] for f in (WORK / "lighton").glob("*.json")]
    crops = {crop_name(mid.split("#")[0], b) for rows in plan().values() for mid, b in rows.items() if b is not None}
    meta = dict(crops=len(crops), lighton_median_s=round(sorted(lt)[len(lt) // 2], 2) if lt else None)
    (RESULTS / "marks-read.json").write_text(json.dumps(dict(meta=meta, arms=res), indent=1) + "\n")
    (RESULTS / "marks-read.md").write_text(markdown(res, meta))
    print(json.dumps({k: (v["read"], v["marks"], v["mean_nes"]) for k, v in res.items()}))


ARM_NAMES = {"oracle": "the owner's box (oracle)", "det25": "YOLO11m box, floor 0.25", "det05": "YOLO11m box, floor 0.05"}


def markdown(res, meta):
    n = next(iter(res.values()))["marks"]
    L = ["# Whether found marks can be read (W46.marks-detect, transcription arm)", "",
         f"{n} owner-reviewed mark texts on the 32 detector-eligible core pages, each read from a crop (`marks_read.py`; "
         "figures in `marks-read.json`). NES is 1 - edit distance / longer length, case kept; *read* is NES >= 0.8. "
         "A detector arm reads the YOLO11m box matched to the mark at IoU >= 0.1; a mark without one reads as "
         "nothing. Intervals: 95% page bootstrap.", "",
         "| Reader | Box | Marks with a box | Mean NES | Read |", "|---|---|---:|---|---|"]
    for key, r in res.items():
        reader, arm = key.split("/")
        L.append(f"| {READERS[reader]} | {ARM_NAMES[arm]} | {r['boxed']} of {r['marks']} | "
                 f"{r['mean_nes']:.2f} ({r['mean_ci'][0]:.2f}-{r['mean_ci'][1]:.2f}) | "
                 f"{r['read']} of {r['marks']} ({r['read_ci'][0] * 100:.0f}-{r['read_ci'][1] * 100:.0f}%) |")
    L += ["", "Read on the oracle box, by class:", "", "| Reader | " + " | ".join(
        next(iter(res.values()))["by_class"]) + " |", "|---|" + "---:|" * len(next(iter(res.values()))["by_class"])]
    for reader in READERS:
        bc = res[f"{reader}/oracle"]["by_class"]
        L.append(f"| {READERS[reader]} | " + " | ".join(f"{v['read']} of {v['n']}" for v in bc.values()) + " |")
    L += ["", f"{meta['crops']} crops; LightOnOCR-3 4B took a median {meta['lighton_median_s']} s a crop on the M3 Pro "
          "(an engine session's timing, so an upper bound).", ""]
    notes = Path(__file__).resolve().parent / "marks_read_notes.md"
    if notes.exists():
        L += notes.read_text().splitlines()
    return "\n".join(L) + "\n"


def main(argv):
    if argv == ["crops"]:
        crops()
    elif argv == ["read", "vision"]:
        read_vision()
    elif argv == ["read", "lighton"]:
        read_lighton()
    elif argv == ["report"]:
        report()
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
