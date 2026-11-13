#!/usr/bin/env python3
"""W46.kit-continuation-replay: the k = 200 continuation without the owner's corpus replay set.

  python3 seg_adapt_replay.py pack  --lora LORA_PACK --tabme TABME_PACK --out PACK   # the Sherlock pack (Mac)
  python3 seg_adapt_replay.py check --root PACK                                      # every frozen file unchanged
  <torch-env python> seg_adapt_replay.py score --pack PACK --lora LORA_PACK --root1 BOX1_ROOT --root2 BOX2_ROOT
                                                                      # runs -> segbench-results/seg-adapt-replay.json

THE QUESTION. W46.seg-adapt-lora's k = 200 arm (Lincoln box 2: 17.2 to 4.9 errors per 100 gaps) replayed three
windows of the corpus 2B's own training set for each correction window. A kit user other than the owner has no such
set (kit_continuation.py rows --replay names one; the kit does not distribute it). Two arms, fixed before any run:

- `none`: box 1's k = 200 correction rows alone (kit_continuation.py rows --no-replay), the same 62 rows.
- `public`: the same rows plus three public windows for each: TABME++ (W46.seg-tabme's frozen stream, its 2,080
  fs-seg-2b requests with page text), each target the shipped 2B's own reply from that run with every boundary set to
  TABME++'s truth (the rows' own construction, seg_adapt_lora.corrected). A kit user has all of it: the shipped 2B, a
  public set and its truth. The windows are a seeded draw (seed 41) of those whose reply parses and covers every gap.

Both train onto the merged corpus 2B exactly as k = 200 did (train_seg.py, rank 16, lr 1e-4, two epochs,
--max-len 20480) and answer the same 175 frozen scoring windows. `score` pairs them against the base and k = 200
arms' answers already home (W46.seg-adapt-lora's pack): box 2 whole, and box 1's gaps after 200.

THE RULE, fixed here before any answer: the default for `kit_continuation.py rows` is the cheapest arm whose box-2
change against k = 200 has its interval's high end below +3 errors per 100 gaps and that loses no more catalogue
starts on box 2 than k = 200 did (`none` is cheaper: no public set to fetch or answer). If neither meets it, the
default stays `--no-replay` only if its box-2 change against the base is below zero with its interval, and the README
states each arm's measured shortfall against k = 200.

NO CALLS, NO MONEY. Only public pages (Lincoln, TABME++) go into the pack.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import random
import shutil
import sys
import time

import seg_adapt_lora as SAL

TAG = "W46.kit-continuation-replay"
NAME = "seg-adapt-replay-20261113"
K = 200
ARMS = ("none", "public")
OLD_ARMS = ("base", "k200")
SEED = 41


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def public_rows(tabme: Path, want: int):
    """`want` TABME++ rows: the shipped 2B's replies (runs/2b-it) with every boundary set to the stream's truth."""
    pack = tabme / "2b-it"
    meta = json.loads((pack / "pack.json").read_text())
    if meta.get("key") != SAL.KEY or meta.get("boxes") != ["TABME"]:
        raise SystemExit(f"{pack}: not W46.seg-tabme's fs-seg-2b pack")
    labels = [p["label"] for p in json.loads((tabme / "stream.json").read_text())["pages"]]
    if len(labels) != meta["pages"]:
        raise SystemExit("stream.json and the pack disagree on the page count")
    wins = {w["cache_key"]: w for w in map(json.loads, (pack / "windows.jsonl").read_text().splitlines())}
    answers = {}
    for line in (tabme / "runs" / "2b-it" / "answers.jsonl").read_text().splitlines():
        r = json.loads(line)
        if r.get("cache_key") in wins and r.get("status") == "ok":
            answers.setdefault(r["cache_key"], r)
    order = sorted(wins)
    random.Random(SEED).shuffle(order)
    rows, skipped = [], {"not answered": 0, "reply not usable": 0}
    for key in order:
        if len(rows) == want:
            break
        w = wins[key]
        if key not in answers:
            skipped["not answered"] += 1
            continue
        got = SAL.corrected(answers[key]["result"], w["window"], labels)
        if got is None:
            skipped["reply not usable"] += 1
            continue
        rows.append({"box": "TABME", "window": w["window"], "prompt": w["prompt"], "target": got[0], "text": "it",
                     "flips": got[1], "source": "W46.seg-tabme 2b-it"})
    if len(rows) < want:
        raise SystemExit(f"only {len(rows)} usable TABME++ windows of {want} wanted")
    return rows, skipped, meta


def cmd_pack(a):
    out, here = a.out, Path(__file__).resolve().parent
    lora, tabme = a.lora.resolve(), a.tabme.resolve()
    if out.exists():
        raise SystemExit(f"{out} exists; inspect it instead of overwriting")
    old = SAL.check(lora)
    mine = [json.loads(x) for x in (lora / "corrections" / f"k{K}.jsonl").read_text().splitlines()]
    if len(mine) != old["corrections"][f"k{K}"]["windows"]:
        raise SystemExit("the k = 200 correction rows are not as frozen")
    replay, skipped, tmeta = public_rows(tabme, SAL.REPLAY_RATIO * len(mine))
    tmp = out.with_name(out.name + ".tmp")
    if tmp.exists():
        raise SystemExit(f"{tmp} exists; a failed earlier pack, inspect it")
    # The scoring windows and box images, byte for byte the k = 200 arm's, so its answers pair with these.
    shutil.copytree(lora / "windows", tmp / "windows")
    images = tmp / "rows" / "images"
    images.mkdir(parents=True)
    (images / "Lincoln").symlink_to(Path("../../windows/images/Lincoln"))
    for n in sorted({n for r in replay for n in r["window"]}):
        SAL.write_new(images / "TABME" / f"{n}.jpg", (tabme / "2b-it" / "images" / "TABME" / f"{n}.jpg").read_bytes())
    data = {}
    for arm, rows in (("none", list(mine)), ("public", mine + replay)):
        random.Random(SEED).shuffle(rows)
        body = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)
        SAL.write_new(tmp / "rows" / arm / "train.jsonl", body.encode())
        data[arm] = {"item": TAG, "arm": arm, "k": K, "corrections": len(mine),
                     "replay": len(rows) - len(mine), "windows": len(rows),
                     "rule": "corrections only" if arm == "none" else "corrections+public replay",
                     "replay_from": None if arm == "none" else f"W46.seg-tabme 2b-it ({tmeta['made']})",
                     "train_sha256": hashlib.sha256(body.encode()).hexdigest()}
        SAL.write_new(tmp / "rows" / arm / "data.json", (json.dumps(data[arm], indent=1) + "\n").encode())
    code = tmp / "support" / "segbench"
    code.mkdir(parents=True)
    for p in sorted(here.glob("*.py")):
        if not p.name.startswith("test_"):
            shutil.copy2(p, code / p.name)
    for name in SAL.SUPPORT_CODE:
        shutil.copy2(here / "institutional-compute" / name, code / name)
    jobs = tmp / "support" / "job"
    shutil.copytree(here / "sherlock" / "seg-adapt-replay", jobs)
    shutil.copy2(here / "sherlock" / "sh.env", jobs / "sh.env")
    shutil.copytree(here / "sherlock" / "bin", jobs / "bin", symlinks=True)
    files = {str(p.relative_to(tmp)): sha(p) for p in sorted(tmp.rglob("*")) if p.is_file() and not p.is_symlink()}
    freeze = {"tag": TAG, "made": time.strftime("%Y-%m-%dT%H:%M:%S"), "name": NAME,
              "scoring_from": {"pack": old["tag"], "made": old["made"], "windows": old["windows"],
                               "windows_sha256": sha(lora / "windows" / "windows.jsonl")},
              "windows": old["windows"], "arms": data, "public_skipped": skipped,
              "public_pages": len(list((images / "TABME").iterdir())), "files": files}
    SAL.write_new(tmp / "freeze.json", (json.dumps(freeze, indent=1) + "\n").encode())
    tmp.rename(out)
    print(json.dumps({k: v for k, v in freeze.items() if k != "files"}, indent=1), f"\n{len(files)} files -> {out}")


def check(root):
    root = Path(root)
    freeze = json.loads((root / "freeze.json").read_text())
    if freeze.get("tag") != TAG:
        raise SystemExit(f"not a {TAG} pack")
    bad = [rel for rel, h in freeze["files"].items() if not (root / rel).is_file() or sha(root / rel) != h]
    if bad:
        raise SystemExit(f"{len(bad)} frozen files missing or changed (first {bad[0]})")
    if sha(root / "windows" / "windows.jsonl") != freeze["scoring_from"]["windows_sha256"]:
        raise SystemExit("the scoring windows are not the k = 200 arm's")
    for arm in ARMS:
        rows = [json.loads(x) for x in (root / "rows" / arm / "train.jsonl").read_text().splitlines()]
        missing = [(r["box"], n) for r in rows for n in r["window"]
                   if not (root / "rows" / "images" / r["box"] / f"{n}.jpg").is_file()]
        if missing:
            raise SystemExit(f"{arm}: {len(missing)} page images missing (first {missing[0]})")
    print(f"pack ok: {len(freeze['files'])} files, {freeze['windows']} scoring windows, " +
          ", ".join(f"{arm} {d['windows']} training windows" for arm, d in freeze["arms"].items()))
    return freeze


def score_box(name, root, judges, old):
    """One box's figures for every arm: box 2 whole, box 1 on the gaps after K (its first K trained every arm)."""
    import data  # noqa: F401  (method_window's imports need it on the path first)
    import method_window as W
    import public_segmentation as PS
    import seg_adapt_curve as SAC
    every = OLD_ARMS + ARMS
    col, manifest = PS.load(name, root)
    if hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest() != \
            old["boxes"][col.name]["truth_sha256"]:
        raise SystemExit(f"{col.name}: the truth changed since the pack")
    p = {arm: {i: g["p_new"] for i, g in enumerate(W.combine(col, judges[arm])["gaps"])} for arm in every}
    box = SAC.Box(col, {})
    kinds, groups = SAL.gap_kinds(manifest), {i: pg["id"] for i, pg in enumerate(manifest["pages"][:-1])}
    new = {arm: SAC.decide(p[arm]) for arm in every}
    gaps = box.gaps if name == "lincoln2" else [i for i in box.gaps if i >= K]
    s = {"gaps": "whole box" if name == "lincoln2" else f"gaps after {K}",
         "arms": {arm: SAL.tally(box, kinds, new[arm], gaps) for arm in every},
         "against_base": {arm: SAL.paired(box, groups, new["base"], new[arm], gaps) for arm in every[1:]},
         "against_k200": {arm: SAL.paired(box, groups, new["k200"], new[arm], gaps) for arm in ARMS}}
    if name == "lincoln2":
        s["whole"] = {arm: box.score(new[arm]) for arm in every}
    s["unsure_calls"] = {str(i + 1): {arm: round(p[arm][i], 3) for arm in every} for i in sorted(box.unsure)}
    return col.name, s


def judges_for(pack, lora):
    """Every arm's judge: base and k200 from W46.seg-adapt-lora's answers, none and public from this pack's."""
    judges, failed = {}, {}
    for arms, src in ((OLD_ARMS, lora), (ARMS, pack)):
        j, f = SAL.arm_judges(src, src / "runs", arms)
        judges.update(j); failed.update(f)
    return judges, failed


def cmd_score(a):
    pack, lora = a.pack.resolve(), a.lora.resolve()
    check(pack)
    old = SAL.check(lora)
    judges, failed = judges_for(pack, lora)
    out = {"tag": TAG, "pack": str(pack), "failed_windows": failed, "boxes": {}}
    for name, root in (("lincoln", a.root1.resolve()), ("lincoln2", a.root2.resolve())):
        box, s = score_box(name, root, judges, old)
        out["boxes"][box] = s
    path = SAL.RESULTS / "seg-adapt-replay.json"
    path.write_text(json.dumps(out, indent=1) + "\n")
    print(f"wrote {path}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pack")
    p.add_argument("--lora", required=True, type=Path, help="W46.seg-adapt-lora's Mac pack (runs home)")
    p.add_argument("--tabme", required=True, type=Path, help="W46.seg-tabme's Mac pack (runs/2b-it home)")
    p.add_argument("--out", required=True, type=Path)
    c = sub.add_parser("check")
    c.add_argument("--root", required=True)
    s = sub.add_parser("score")
    s.add_argument("--pack", required=True, type=Path, help="this item's Mac pack, with runs/ brought home")
    s.add_argument("--lora", required=True, type=Path, help="W46.seg-adapt-lora's Mac pack (base and k200 runs)")
    s.add_argument("--root1", required=True, type=Path, help="box 1's public source cache")
    s.add_argument("--root2", required=True, type=Path, help="box 2's public source cache")
    a = ap.parse_args(argv)
    if a.cmd == "check":
        check(a.root)
    else:
        {"pack": cmd_pack, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
