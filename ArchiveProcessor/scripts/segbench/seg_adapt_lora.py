#!/usr/bin/env python3
"""W46.seg-adapt-lora: a user's corrections on one Lincoln box, as LoRA training rows for the corpus-trained 2B.

  python3 seg_adapt_lora.py data --root BOX1_ROOT --k 50 --out DIR    # -> DIR/train.jsonl, DIR/data.json
  python3 seg_adapt_lora.py pack --root1 BOX1_ROOT --root2 BOX2_ROOT --out PACK   # the Sherlock pack (Mac)
  python3 seg_adapt_lora.py check --root PACK                         # every frozen file unchanged
  python3 seg_adapt_lora.py replay --root PACK --k 50 --adapter A --search FS --out DIR   # on Sherlock, in a job
  <torch-env python> seg_adapt_lora.py score --pack PACK --root1 BOX1_ROOT --root2 BOX2_ROOT   # runs -> seg-adapt-lora.json
  <torch-env python> seg_adapt_lora.py report        # -> segbench-results/seg-adapt-lora.md (Findings: report-notes/)

THE ROWS. A user reviews the start of box 1 (public-segmentation/lincoln.json) and corrects the 2B's calls on its
first k gaps. A training row is a box-1 window of the unchanged fs-seg-2b pack (its prompt and 1024 px images) whose
every gap lies inside those k; its target is the 2B's own cached reply with each boundary decision set to the
truth. A flipped decision gets confidence 0.95 and cue "corrected by the reviewer"; an agreeing one is left exactly
as the 2B wrote it. A window holding an unsure gap (the owner's rulings) trains nothing, nor does one whose reply
does not parse or lacks a gap. The rows are in train_seg.py's format, so `train_seg.py train` takes them beside a
replay sample of the corpus training rows (the Sherlock job mixes them; nothing here reads the corpus).

The second box (lincoln2.json) is never read for training: it is only scored, after training (`score`: box 2 whole,
box 1 only on the gaps after each arm's k, paired intervals by catalogue item, and a rerun floor from FarmShare's
earlier answers to the same requests).

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


# --- scoring, on the Mac, after the runs come home -------------------------------------------------------------

ARMS = ("base", "k50", "k200")
BOOT, SEED = 2000, 43
RESULTS = Path(__file__).resolve().parents[2] / "segbench-results"


def arm_judges(pack: Path, runs: Path, arms=ARMS):
    """One judge per arm from runs/<arm>/answers.jsonl, through the pack's own windows (method_window's judge form)."""
    import method_local as L
    import method_window as W
    ws = {w["cache_key"]: w for w in map(json.loads, (pack / "windows" / "windows.jsonl").read_text().splitlines())}
    out, failed = {}, {}
    for arm in arms:
        got = {}
        for line in (runs / arm / "answers.jsonl").read_text().splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                continue                                   # a line a killed job left half-written
            w = ws.get(r["cache_key"])
            if w is None:
                raise SystemExit(f"{arm}: an answer for a request this pack never made ({r['window']})")
            got[(w["box"], tuple(w["window"]))] = r
        if len(got) != len(ws):
            raise SystemExit(f"{arm}: {len(got)} of {len(ws)} windows answered")
        failed[arm] = sum(r["status"] != "ok" for r in got.values())

        def judge(col, a, b, allow_call=False, got=got):
            nums = [col.pages[i].n for i in range(a, b)]
            r = got.get((col.name, tuple(nums)))
            if r is None:
                return None
            if r["status"] != "ok":
                return L.neutral(nums)                     # a window unparsed after the retry votes 0.5, as everywhere
            return W.parse_answer(r["result"], nums)
        out[arm] = judge
    return out, failed


def gap_kinds(manifest) -> dict[int, str]:
    """Gap index i (pages i+1 | i+2) -> "catalogue" (the right page begins a catalogue item), "internal" (a start
    inside one) or "continue"."""
    pages = manifest["pages"]
    out = {}
    for i in range(len(pages) - 1):
        a, b = pages[i], pages[i + 1]
        out[i] = "catalogue" if b["id"] != a["id"] else ("internal" if b["label"] == "New" else "continue")
    return out


def tally(box, kinds, new, gaps):
    """Errors and recalls over `gaps` (known gaps only)."""
    t = {"gaps": 0, "errors": 0, "fs": 0, "fm": 0}
    for kind in ("catalogue", "internal", "continue"):
        t[kind] = [0, 0]                                   # [right, of]
    for i in gaps:
        if i in box.unsure:
            continue
        t["gaps"] += 1
        right = new[i] == box.truth[i]
        t[kinds[i]][0] += right
        t[kinds[i]][1] += 1
        if not right:
            t["errors"] += 1
            t["fs" if new[i] else "fm"] += 1
    t["err_per_100"] = 100 * t["errors"] / t["gaps"] if t["gaps"] else None
    return t


def paired(box, groups, a_new, b_new, gaps):
    """b minus a, errors per 100 known gaps, with a 95% interval resampling catalogue items (paired: one draw serves
    both arms)."""
    import random
    by = {}
    for i in gaps:
        if i not in box.unsure:
            e = by.setdefault(groups[i], [0, 0, 0])
            e[0] += 1
            e[1] += a_new[i] != box.truth[i]
            e[2] += b_new[i] != box.truth[i]
    items = list(by.values())
    n = sum(x[0] for x in items)
    diff = 100 * (sum(x[2] for x in items) - sum(x[1] for x in items)) / n
    rng, ds = random.Random(SEED), []
    for _ in range(BOOT):
        s = [items[rng.randrange(len(items))] for _ in items]
        m = sum(x[0] for x in s)
        ds.append(100 * (sum(x[2] for x in s) - sum(x[1] for x in s)) / m)
    ds.sort()
    return {"diff": diff, "lo": ds[int(0.025 * BOOT)], "hi": ds[int(0.975 * BOOT) - 1], "gaps": n, "items": len(items)}


def rerun(box, col, root1: Path, new, gaps):
    """The base arm against the 2B's earlier FarmShare answers to the same requests (box 1's committed cache): how
    many held-out gap decisions a plain rerun changes, and its error difference. The floor an arm has to clear."""
    import data
    import method_openrouter as R
    import method_window as W
    data.CACHE_DIR = root1 / "cache"
    earlier = {i: g["p_new"] >= 0.5 for i, g in enumerate(W.combine(col, R.judge(KEY))["gaps"])}
    flips = sum(earlier[i] != new[i] for i in gaps if i not in box.unsure)
    return earlier, flips


def cmd_score(a):
    import data  # noqa: F401  (method_window's imports need it on the path first)
    import method_window as W
    import seg_adapt_curve as SAC
    pack, runs = a.pack.resolve(), a.pack.resolve() / "runs"
    freeze = check(pack)
    judges, failed = arm_judges(pack, runs)
    out = {"tag": TAG, "pack": str(pack), "failed_windows": failed, "boxes": {}}
    for name, root in (("lincoln", a.root1.resolve()), ("lincoln2", a.root2.resolve())):
        col, manifest = PS.load(name, root)
        if hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest() != \
                freeze["boxes"][col.name]["truth_sha256"]:
            raise SystemExit(f"{col.name}: the truth changed since the pack")
        p = {arm: {i: g["p_new"] for i, g in enumerate(W.combine(col, judges[arm])["gaps"])} for arm in ARMS}
        box = SAC.Box(col, {})
        kinds, groups = gap_kinds(manifest), {i: pg["id"] for i, pg in enumerate(manifest["pages"][:-1])}
        new = {arm: SAC.decide(p[arm]) for arm in ARMS}
        res = {"pages": box.pages, "gaps": len(box.gaps), "unsure": sorted(i + 1 for i in box.unsure),
               "kinds": {k: sum(1 for i in box.gaps if kinds[i] == k and i not in box.unsure)
                         for k in ("catalogue", "internal", "continue")}, "sets": {}}
        if name == "lincoln2":
            sets = {"whole box": (box.gaps, ARMS)}
        else:   # box 1: an arm's first k gaps are its training rows; only the gaps after them are held out
            sets = {f"gaps after {k}": ([i for i in box.gaps if i >= k], ("base", f"k{k}")) for k in KS}
        for label, (gaps, arms) in sets.items():
            s = {"arms": {arm: tally(box, kinds, new[arm], gaps) for arm in arms}, "paired": {}}
            for arm in arms[1:]:
                s["paired"][arm] = paired(box, groups, new["base"], new[arm], gaps)
            if name == "lincoln":
                earlier, flips = rerun(box, col, a.root1.resolve(), new["base"], gaps)
                s["rerun"] = {"flips": flips, "earlier": tally(box, kinds, earlier, gaps),
                              "paired": paired(box, groups, earlier, new["base"], gaps)}
            res["sets"][label] = s
        res["whole"] = {arm: {k: v for k, v in box.score(new[arm]).items()} for arm in ARMS}
        res["unsure_calls"] = {str(i + 1): {arm: round(p[arm][i], 3) for arm in ARMS} for i in sorted(box.unsure)}
        out["boxes"][col.name] = res
    path = RESULTS / "seg-adapt-lora.json"
    path.write_text(json.dumps(out, indent=1) + "\n")
    print(f"wrote {path}")


NOTES = Path(__file__).resolve().parent / "report-notes" / "seg-adapt-lora.md"
NAMES = {"base": "corpus 2B", "k50": "LoRA, k = 50", "k200": "LoRA, k = 200"}


def render(d: dict, notes: str) -> str:
    import seg_card
    f = lambda r: f"{r[0]}/{r[1]}" if r[1] else "—"  # noqa: E731
    ci = lambda p: f"{p['diff']:+.1f} ({p['lo']:+.1f} to {p['hi']:+.1f})"  # noqa: E731
    L = ["# LoRA continuation of the 2B on a user's corrected gaps, across two boxes of one material "
         "(W46.seg-adapt-lora)", "",
         "Generated by `scripts/segbench/seg_adapt_lora.py score` and `report` from the Sherlock runs' answers "
         "(no calls; the Findings are `report-notes/seg-adapt-lora.md`). Gaps are scored with the existing window "
         "combiner (method_window.combine, P(new) >= 0.5 is a start); unsure gaps are out of every count.", "",
         notes.strip(), "",
         "## Errors on gaps no training row saw", "",
         "Starts found are split into catalogue starts (the right page begins a catalogue item) and starts inside an "
         "item. The change is the arm's errors per 100 gaps minus the corpus 2B's on the same gaps, with a 95% "
         "interval from 2,000 resamples of catalogue items (paired). The rerun row is the corpus 2B on Sherlock "
         "minus FarmShare's earlier answers to the byte-identical requests.", "",
         "| box, gaps scored | arm | gaps | errors per 100 | false splits | false merges | catalogue starts | "
         "starts inside an item | continuations | change against the 2B |", "|---|---|---|---|---|---|---|---|---|---|"]
    for box, b in d["boxes"].items():
        for label, s in b["sets"].items():
            where = f"{'Box 2' if box == 'Lincoln2' else 'Box 1'}, {label}"
            for arm, t in s["arms"].items():
                L.append(f"| {where} | {NAMES[arm]} | {t['gaps']} | {t['err_per_100']:.1f} | {t['fs']} | {t['fm']} | "
                         f"{f(t['catalogue'])} | {f(t['internal'])} | {f(t['continue'])} | "
                         f"{ci(s['paired'][arm]) if arm in s['paired'] else '—'} |")
            if "rerun" in s:
                r = s["rerun"]
                L.append(f"| {where} | rerun of the 2B (FarmShare) | {r['earlier']['gaps']} | "
                         f"{r['earlier']['err_per_100']:.1f} | {r['earlier']['fs']} | {r['earlier']['fm']} | "
                         f"{f(r['earlier']['catalogue'])} | {f(r['earlier']['internal'])} | "
                         f"{f(r['earlier']['continue'])} | 2B minus rerun {ci(r['paired'])}; {r['flips']} decisions differ |")
    b2 = d["boxes"]["Lincoln2"]
    L += ["", "## Box 2 whole (segments)", "",
          "Pages in an exactly right document and PQ over all of box 2 (conditional on each arm's own call at the "
          "12 unsure gaps, as score.py reads them). Box 1's whole-box figures are not given: its first k gaps are "
          "the k arms' training rows.", "",
          "| arm | pages exact | false splits | false merges | boundaries found | PQ |", "|---|---|---|---|---|---|",
          *[f"| {NAMES[a]} | {100 * w['exact']:.1f}% | {w['fs']} | {w['fm']} | {w['tp']}/{w['bounds']} | "
            f"{w['pq']:.3f} |" for a, w in b2["whole"].items()], "",
          "## The arms' calls at the unsure gaps (descriptive, not scored)", "",
          "P(new) per gap; box 2's 12 are the within-item gaps Gemini 3.7 Flash called a new document.", "",
          "| box | gap (right page) | " + " | ".join(NAMES[a] for a in ARMS) + " |", "|---|---|---|---|---|"]
    for box, b in d["boxes"].items():
        for g, calls in b["unsure_calls"].items():
            L.append(f"| {box} | {g} | " + " | ".join(f"{calls[a]:.2f}" for a in ARMS) + " |")
    L += ["", *seg_card.card(
        truth="Box 1 is `public-segmentation/lincoln.json` (agent-audited, the owner's rulings on its disputed gaps "
              "folded in; 3 unsure gaps). Box 2 is `lincoln2.json`: the 70 catalogue starts, and Gemini 3.7 Flash's "
              "'same' calls on 175 within-item gaps as continuations; its 12 'new' calls are unsure gaps. Box 2's "
              "truth is one model family's reading and holds no scored start inside an item, so a box-2 count of "
              "false merges sees only catalogue starts. Gemini is not a scored route here.",
        selection="Box 2 is Lincoln Papers Shelf Order catalogue positions 74-143 of the snapshot box 1 (positions "
                  "2-73) came from, chosen by box 1's stop rule (whole items while under 250 pages). No model, "
                  "transcription or ABBYY text chose either box; k = 50 and 200 were fixed before any run.",
        comparison="Every arm answered the same 175 frozen fs-seg-2b windows (prompt o1, 1024 px images, Vision "
                   "text), served by vLLM 0.31.0 with the same arguments on one Sherlock GPU each; the corpus 2B "
                   "was merged on Sherlock and each LoRA continued from it (train_seg.py defaults, two epochs, three "
                   "no-text corpus windows replayed per correction window). No window failed.",
        noise="Paired 95% intervals resample catalogue items. The rerun floor is measured here: the corpus 2B on "
              "Sherlock against FarmShare's earlier answers to the same requests changes 3 of box 1's 207 gaps "
              "after k = 50 (+1.4 errors per 100). One training seed per arm, so the spread from retraining is not "
              "measured.",
        scope="One material (Lincoln Papers correspondence, June 1863 and earlier), two adjacent boxes of one series, "
              "one user's corrections taken as the truth on box 1's first k gaps. It does not show the gain on a "
              "material unlike Lincoln, on the owner's own boxes, or with fewer replayed windows; box 2 cannot see "
              "an arm that learns to miss starts inside an item.")]
    return "\n".join(L) + "\n"


def cmd_report(a):
    if not NOTES.exists():
        raise SystemExit(f"{NOTES}: the report's Findings are missing; the report is not written without them")
    d = json.loads((RESULTS / "seg-adapt-lora.json").read_text())
    (RESULTS / "seg-adapt-lora.md").write_text(render(d, NOTES.read_text()))
    print(f"wrote {RESULTS / 'seg-adapt-lora.md'}")


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
    s = sub.add_parser("score")
    s.add_argument("--pack", required=True, type=Path, help="the Mac pack folder, with runs/ brought home")
    s.add_argument("--root1", required=True, type=Path, help="box 1's public source cache")
    s.add_argument("--root2", required=True, type=Path, help="box 2's public source cache")
    sub.add_parser("report")
    a = ap.parse_args()
    if a.cmd == "check":
        check(a.root)
    else:
        {"data": cmd_data, "pack": cmd_pack, "replay": cmd_replay, "score": cmd_score, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
