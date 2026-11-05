#!/usr/bin/env python3
"""W46.seg-adapt-lora: a user's corrections on one Lincoln box, as LoRA training rows for the corpus-trained 2B.

  python3 seg_adapt_lora.py data --root BOX1_ROOT --k 50 --out DIR    # -> DIR/train.jsonl, DIR/data.json

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
from pathlib import Path
import sys

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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("data")
    d.add_argument("--root", required=True, type=Path)
    d.add_argument("--k", required=True, type=int)
    d.add_argument("--out", required=True, type=Path)
    a = ap.parse_args()
    {"data": cmd_data}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
