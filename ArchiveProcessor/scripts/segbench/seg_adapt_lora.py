#!/usr/bin/env python3
"""W46.seg-adapt-lora: a user's corrections on one Lincoln box, as LoRA training rows for the corpus-trained 2B.

  python3 seg_adapt_lora.py data --root BOX1_ROOT --k 50 --out DIR    # -> DIR/train.jsonl, DIR/data.json
  python3 seg_adapt_lora.py pack --root1 BOX1_ROOT --root2 BOX2_ROOT --out PACK   # the Sherlock pack (Mac)
  python3 seg_adapt_lora.py check --root PACK                         # every frozen file unchanged
  python3 seg_adapt_lora.py replay --root PACK --k 50 --adapter A --search FS --out DIR   # on Sherlock, in a job

THE ROWS. A user reviews the start of box 1 (public-segmentation/lincoln.json) and corrects the 2B's calls on its
first k gaps. A training row is a box-1 window of the unchanged fs-seg-2b pack (its prompt and 1024 px images) whose
every gap lies inside those k; its target is the 2B's own cached reply with each boundary decision set to the
truth. A flipped decision gets confidence 0.95 and cue "corrected by the reviewer"; an agreeing one is left exactly
as the 2B wrote it. A window holding an unsure gap (the owner's rulings) trains nothing, nor does one whose reply
does not parse or lacks a gap. The rows are in train_seg.py's format, so `train_seg.py train` takes them beside a
replay sample of the corpus training rows (the Sherlock job mixes them; nothing here reads the corpus).

The second box (lincoln2.json) is never read here: it is only scored, after training.

NO CALLS, NO MONEY. BOX1_ROOT is the public source cache holding packs/lincoln-fs-seg-2b and cache/responses.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import time

import public_segmentation as PS

KEY, CACHE_KEY = "fs-seg-2b", "window-or-fs-seg-2b"
CORRECTED = {"confidence": 0.95, "cue": "corrected by the reviewer"}


def reply_text(obj) -> str:
    """The 2B's own layout: one page or boundary object per line."""
    pages = ",\n".join(json.dumps(p, ensure_ascii=False) for p in obj["pages"])
    bounds = ",\n".join(json.dumps(b, ensure_ascii=False) for b in obj["boundaries"])
    return '{\n"pages": [\n' + pages + '\n],\n"boundaries": [\n' + bounds + "\n]\n}"


def corrected(reply: str, nums: list[int], labels: list[str]):
    """(target text, flips) with every boundary set to the truth; None when the reply cannot be corrected safely."""
    try:
        obj = json.loads(reply)
    except ValueError:
        return None
    if not isinstance(obj, dict) or not isinstance(obj.get("pages"), list) or not isinstance(obj.get("boundaries"), list):
        return None
    want = {(a, b) for a, b in zip(nums, nums[1:])}
    seen, flips = set(), 0
    for bd in obj["boundaries"]:
        pair = tuple(bd.get("between") or ())
        if pair not in want or pair in seen or bd.get("decision") not in ("new", "continue"):
            return None
        seen.add(pair)
        truth = "new" if labels[pair[1] - 1] == "New" else "continue"
        if bd["decision"] != truth:
            bd.update(decision=truth, **CORRECTED)
            flips += 1
    if seen != want:
        return None
    return reply_text(obj), flips


def rows_for(root: Path, k: int):
    col, manifest = PS.load("lincoln", root)
    labels, unsure = col.labels, set(col.unsure)          # unsure: the right-hand page of each unsure gap
    pack = root / "packs" / f"lincoln-{KEY}"
    if json.loads((pack / "pack.json").read_text())["key"] != KEY:
        raise ValueError("not the fs-seg-2b pack")
    rows, why = [], {"outside the first k gaps": 0, "an unsure gap": 0, "no cached reply": 0, "reply not usable": 0}
    flips = 0
    for w in map(json.loads, (pack / "windows.jsonl").read_text().splitlines()):
        nums = w["window"]
        if nums[-1] > k + 1:                               # gap n|n+1 is the n-th gap; all must be <= k
            why["outside the first k gaps"] += 1; continue
        if any(n in unsure for n in nums[1:]):
            why["an unsure gap"] += 1; continue
        f = root / "cache/responses" / CACHE_KEY / w["cache_key"][:2] / f"{w['cache_key']}.json"
        if not f.exists():
            why["no cached reply"] += 1; continue
        r = json.loads(f.read_text())
        got = corrected(r["result"], nums, labels) if r.get("status") == "ok" else None
        if got is None:
            why["reply not usable"] += 1; continue
        rows.append({"box": w["box"], "window": nums, "prompt": w["prompt"], "target": got[0], "text": "vision",
                     "flips": got[1]})
        flips += got[1]
    return rows, why, flips, manifest


def cmd_data(a):
    if not 1 <= a.k <= 260:
        raise SystemExit("k is a count of box 1's 260 gaps")
    root = a.root.resolve()
    rows, why, flips, manifest = rows_for(root, a.k)
    out = a.out
    if out.exists():
        raise SystemExit(f"{out} exists; inspect it instead of overwriting")
    out.mkdir(parents=True)
    body = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)
    (out / "train.jsonl").write_text(body)
    summary = {"item": "W46.seg-adapt-lora", "k": a.k, "windows": len(rows), "flipped_decisions": flips,
               "dropped": why, "images": str(root / "packs" / f"lincoln-{KEY}" / "images"),
               "truth_sha256": hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest(),
               "train_sha256": hashlib.sha256(body.encode()).hexdigest()}
    (out / "data.json").write_text(json.dumps(summary, indent=1) + "\n")
    print(json.dumps(summary, indent=1))


# --- the Sherlock pack ------------------------------------------------------------------------------------------

TAG = "W46.seg-adapt-lora"
KS = (50, 200)
REPLAY_RATIO = 3          # corpus windows per correction window, so the continuation keeps what the 2B knows
SUPPORT_CODE = ("cluster_ocr.py", "cluster_seg.py", "train_seg.py")


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_new(path, blob):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "xb") as fh:  # never replace a frozen file
        fh.write(blob)


def cmd_pack(a):
    """One scoring pack (box 1's and box 2's unchanged fs-seg-2b windows), the k=50/200 correction rows, the code."""
    import shutil
    out, here = a.out, Path(__file__).resolve().parent
    if out.exists():
        raise SystemExit(f"{out} exists; inspect it instead of overwriting")
    windows, boxes = [], {}
    for root, box in ((a.root1.resolve(), "lincoln"), (a.root2.resolve(), "lincoln2")):
        col, manifest = PS.load(box, root)                 # the committed truth, unchanged
        pack = root / "packs" / f"{box}-{KEY}"
        meta = json.loads((pack / "pack.json").read_text())
        if meta["key"] != KEY or meta["boxes"] != [col.name] or meta["pages"] != len(col.pages):
            raise SystemExit(f"{pack}: not the {KEY} pack of {col.name}")
        ws = [json.loads(x) for x in (pack / "windows.jsonl").read_text().splitlines()]
        for n in range(1, len(col.pages) + 1):
            write_new(out / "windows" / "images" / col.name / f"{n}.jpg",
                      (pack / "images" / col.name / f"{n}.jpg").read_bytes())
        windows += ws
        boxes[col.name] = {"pages": len(col.pages), "windows": len(ws), "pack_made": meta["made"],
                           "truth_sha256": hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()}
    if len({w["cache_key"] for w in windows}) != len(windows):
        raise SystemExit("two windows share a cache key")
    write_new(out / "windows" / "windows.jsonl", "".join(json.dumps(w) + "\n" for w in windows).encode())
    write_new(out / "windows" / "pack.json", json.dumps({
        "key": KEY, "model": "seg-2b", "side": 1024, "boxes": sorted(boxes), "windows": len(windows),
        "pages": sum(b["pages"] for b in boxes.values()),
        "max_images": max(len(w["window"]) for w in windows), "text": "vision", "item": TAG}, indent=1).encode())
    corrections = {}
    for k in KS:
        rows, why, flips, _ = rows_for(a.root1.resolve(), k)
        write_new(out / "corrections" / f"k{k}.jsonl",
                  "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows).encode())
        corrections[f"k{k}"] = {"windows": len(rows), "flipped_decisions": flips, "dropped": why}
    code = out / "support" / "segbench"
    code.mkdir(parents=True)
    for p in sorted(here.glob("*.py")):
        if not p.name.startswith("test_"):
            shutil.copy2(p, code / p.name)
    for name in SUPPORT_CODE:
        shutil.copy2(here / "institutional-compute" / name, code / name)
    jobs = out / "support" / "job"
    shutil.copytree(here / "sherlock" / "seg-adapt-lora", jobs)
    shutil.copy2(here / "sherlock" / "sh.env", jobs / "sh.env")
    shutil.copytree(here / "sherlock" / "bin", jobs / "bin", symlinks=True)
    files = {str(p.relative_to(out)): sha(p) for p in sorted(out.rglob("*")) if p.is_file() and not p.is_symlink()}
    freeze = {"tag": TAG, "made": time.strftime("%Y-%m-%dT%H:%M:%S"), "boxes": boxes, "windows": len(windows),
              "corrections": corrections, "replay_ratio": REPLAY_RATIO, "files": files}
    write_new(out / "freeze.json", (json.dumps(freeze, indent=1) + "\n").encode())
    print(json.dumps({k: v for k, v in freeze.items() if k != "files"}, indent=1), f"\n{len(files)} files -> {out}")


def check(root):
    root = Path(root)
    freeze = json.loads((root / "freeze.json").read_text())
    if freeze.get("tag") != TAG:
        raise SystemExit(f"not a {TAG} pack")
    bad = [rel for rel, h in freeze["files"].items() if not (root / rel).is_file() or sha(root / rel) != h]
    if bad:
        raise SystemExit(f"{len(bad)} frozen files missing or changed (first {bad[0]})")
    ws = [json.loads(x) for x in (root / "windows" / "windows.jsonl").read_text().splitlines()]
    if len({w["cache_key"] for w in ws}) != len(ws) or len(ws) != freeze["windows"]:
        raise SystemExit("scoring requests are not unique or not as frozen")
    print(f"pack ok: {len(freeze['files'])} files, {len(ws)} scoring windows, " +
          ", ".join(f"{k} {v['windows']} correction windows" for k, v in freeze["corrections"].items()))
    return freeze


def replay_candidates(search, windows):
    """Every folder under `search` holding train.jsonl and a data.json that counts `windows` windows and records an
    images folder: train_seg.py's data sets (not every one records its `rule`), never a replay set this script wrote."""
    found = set()
    # No symlinked folders (train/seg-2b links to full/qwen3.5-2b) and none of the big trees, so one data set is
    # found once and the walk stays short while the job holds a GPU.
    for top, dirs, files in os.walk(search, followlinks=False):
        dirs[:] = [d for d in dirs if d not in ("hf", "images", "cache", "runs", "logs", "adapter")
                   and not d.startswith("step-")]
        if "data.json" not in files or "train.jsonl" not in files:
            continue
        try:
            meta = json.loads((Path(top) / "data.json").read_text())
        except ValueError:
            continue
        if (isinstance(meta, dict) and meta.get("item") != TAG and isinstance(meta.get("images"), str)
                and isinstance(windows, int) and meta.get("windows") == windows):
            found.add(Path(top).resolve())
    return sorted(found)


def replay_source(search, windows, named=None):
    """The one corpus set to replay: `named` (SAL_REPLAY) when given, else the single search candidate. None or
    several stop with the search root, so a job never trains on a guess."""
    if named:
        src = Path(named).resolve()
        if not ((src / "train.jsonl").is_file() and (src / "data.json").is_file()):
            raise SystemExit(f"SAL_REPLAY={named}: no train.jsonl and data.json there")
        return src
    found = replay_candidates(search, windows)
    if len(found) != 1:
        listed = "".join(f"\n  {f}" for f in found)
        raise SystemExit(f"replay set: {len(found)} candidates under {search} with {windows} windows; "
                         f"name one with SAL_REPLAY{listed}")
    return found[0]


def cmd_replay(a):
    """On Sherlock: the correction rows plus REPLAY_RATIO times as many of the 2B's own no-text corpus training rows, with
    one images folder linking every box the rows name. The corpus set is the one whose data.json counts the windows
    the 2B's train.json says it trained on and records
    its images folder (replay_candidates); anything else (none, several, a missing images folder) stops here, and
    SAL_REPLAY=<dir holding train.jsonl and data.json> names it instead."""
    import random
    root, out = Path(a.root), Path(a.out)
    freeze = check(root)
    trained = json.loads((Path(a.adapter).parent / "train.json").read_text())
    src = replay_source(a.search, trained.get("windows"), os.environ.get("SAL_REPLAY"))
    meta = json.loads((src / "data.json").read_text())
    # FarmShare's scratch path, now inside the group copy; the copy first, because a scratch folder of the same path
    # may be a purged leftover. Every page a row names is checked below either way.
    recorded = Path(meta["images"])
    try:
        candidates = [Path(a.search) / recorded.relative_to("/scratch/users/cp1/fs-ocr"), recorded]
    except ValueError:
        candidates = [recorded]
    images = next((c for c in candidates if c.is_dir()), None)
    if images is None:
        raise SystemExit(f"replay images not found: {meta['images']}")
    mine = [json.loads(x) for x in (root / "corrections" / f"k{a.k}.jsonl").read_text().splitlines()]
    corpus = [json.loads(x) for x in (src / "train.jsonl").read_text().splitlines()]
    # Image windows only, and only those trained without page text: the owner's rule of 2026-10-30 bars ABBYY text
    # from every new training row, and the corpus rows marked `abbyy` carry it in the prompt.
    corpus = [r for r in corpus if "box" in r and r.get("text") == "none" and "ABBYY" not in r["prompt"]]
    if not corpus:   # fewer than REPLAY_RATIO times the corrections is used whole, and data.json says how many
        raise SystemExit("no no-text corpus windows to replay")
    # One seeded order for every k: k=200's replay holds k=50's, so the arms differ only by what k adds.
    random.Random(41).shuffle(corpus)
    replay = corpus[:REPLAY_RATIO * len(mine)]
    rows = mine + replay
    random.Random(41).shuffle(rows)
    if out.exists():
        raise SystemExit(f"{out} exists")
    tmp = out.with_name(out.name + ".tmp")
    if tmp.exists():                           # a failed earlier attempt of this job; scratch, rebuilt whole
        import shutil
        shutil.rmtree(tmp)
    (tmp / "images").mkdir(parents=True)
    for box in sorted({r["box"] for r in rows}):
        target = root / "windows" / "images" / box if box.startswith("Lincoln") else images / box
        missing = [n for r in rows if r["box"] == box for n in r["window"] if not (target / f"{n}.jpg").is_file()]
        if missing:
            raise SystemExit(f"{box}: {len(missing)} page images missing under {target} (first {missing[0]})")
        os.symlink(target, tmp / "images" / box)
    (tmp / "train.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    summary = {"item": TAG, "k": a.k, "corrections": len(mine), "replay": len(replay), "replay_from": str(src),
               "replay_images": str(images), "images": str(out / "images"), "rule": "corrections+replay",
               "windows": len(rows)}
    (tmp / "data.json").write_text(json.dumps(summary, indent=1) + "\n")
    tmp.rename(out)
    print(json.dumps(summary, indent=1))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("data")
    d.add_argument("--root", required=True, type=Path)
    d.add_argument("--k", required=True, type=int)
    d.add_argument("--out", required=True, type=Path)
    p = sub.add_parser("pack")
    p.add_argument("--root1", required=True, type=Path, help="box 1's public source cache")
    p.add_argument("--root2", required=True, type=Path, help="box 2's public source cache")
    p.add_argument("--out", required=True, type=Path)
    c = sub.add_parser("check")
    c.add_argument("--root", required=True)
    r = sub.add_parser("replay")
    r.add_argument("--root", required=True); r.add_argument("--k", required=True, type=int, choices=KS)
    r.add_argument("--adapter", required=True, help="the corpus 2B's adapter folder (train.json beside it)")
    r.add_argument("--search", required=True, help="the FarmShare copy's fs-ocr folder")
    r.add_argument("--out", required=True)
    a = ap.parse_args()
    if a.cmd == "check":
        check(a.root)
    else:
        {"data": cmd_data, "pack": cmd_pack, "replay": cmd_replay}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
