#!/usr/bin/env python3
"""W46.kit-gate-sherlock: the students and the teacher on owner-ruled gaps no cache holds answers for.

Two sets, each answered by the Qwen3.5 27B teacher (fs-qwen3.5-27b) and the fine-tuned 2B and 4B (fs-seg-2b, fs-seg-4b)
in one Sherlock submission:
  checkpack  the windows that cover the owner's 80 checkpack gaps (corpus_pairs.py checkpack; answers in
             segbench-results/label-clean-owner-answers.csv): 71 in collections the students trained on, 9 held out.
  boxes      the three locked boxes, whole: Sasha (the one locked box no student trained on), the Illustrated Review
             and SC0122 (both wholly in the students' training split: trained-on). The last two are W46.seg-boxes-score's
             teacher-and-4B arm, so that item shares this job rather than running the teacher twice.

  kit_gate_sherlock.py plan                  # request counts and the pages still without Vision text (no writes)
  kit_gate_sherlock.py ocr                   # Vision text for those pages into the segbench cache (heavy-run.py)
  kit_gate_sherlock.py pack  --out DIR       # the frozen pack for Sherlock (Mac only)
  kit_gate_sherlock.py check --root DIR      # the pack's hashes (Mac or Sherlock; stdlib only)
  kit_gate_sherlock.py score --pack DIR --results DIR   # -> segbench-results/seg-kit-gate-sherlock.json

FIXED BEFORE ANY ANSWER:
- The request is the bench's (method_local.request: 7-page windows at stride 3, the images at 1,024 px, temperature 0,
  thinking off, the codex prompt), for every model and both sets.
- No ABBYY text (owner, 2026-10-30). The students were trained on corpus windows carrying ABBYY's text layer; these
  windows carry Apple Vision's reading of the JPEG original instead (data.ocr_cache_path, segbench's ocr.swift), as
  every bench box does and as the app reads. The checkpack arm therefore measures the students on the app's input,
  not on their training input; the shift is named where the result is reported.
- Checkpack windows: every corpus_pairs window that holds both pages of a checkpack gap, as the label-clean run sent
  them (the folder's own page numbers; a page without a JPEG breaks a run). A gap's call is method_window.combine's:
  the mean P(new) over the windows that cover it. The owner's "same" is a continuation; his 6 unsure are not scored.
- Boxes: method_window.windows over the whole box; unsure gaps (lock.json) out of every count, as score.py does.
No money, no calls. Owner images and text go only into the pack, which stays outside git (the repo is public).
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
RESULTS = HERE.parents[1] / "segbench-results"
TAG = "W46.kit-gate-sherlock"
PACK_NAME = "kit-gate-sherlock-20261031"
BOXES = ("Sasha", "IllustratedReview", "SC0122")
HELD_OUT_BOXES = ("Sasha",)
# role: (method_openrouter.FARMSHARE key, the name the Sherlock job serves it under)
MODELS = {"teacher": ("fs-qwen3.5-27b", "Qwen/Qwen3.5-27B-FP8"), "2b": ("fs-seg-2b", "seg-2b"),
          "4b": ("fs-seg-4b", "seg-4b")}
PAIRS_CACHE = Path.home() / "Library/Caches/ArchiveSuiteRehearsal/corpus-pairs"
JPEGS = Path.home() / "Desktop/Google Drive/Archival Photos JPEGS"
ANSWERS = RESULTS / "label-clean-owner-answers.csv"
SUPPORT_CODE = ("cluster_ocr.py", "cluster_seg.py", "train_seg.py")  # institutional-compute/, beside the bench modules


def _seg():
    sys.path.insert(0, str(HERE))
    sys.path.insert(0, str(HERE / "institutional-compute"))
    import data
    import method_local as L
    import method_openrouter as R
    import method_window as W
    data.CACHE_DIR = Path(os.environ.get("SEGBENCH_CACHE",
                                         Path.home() / "Library/Caches/ArchiveSuiteRehearsal/segbench"))
    return data, L, R, W


# --- the checkpack's windows ----------------------------------------------------------------------

def checkpack_cases(pairs_cache=PAIRS_CACHE, answers=ANSWERS):
    """[{id, folder_id, n, split, owner}] for the 80 checkpack gaps: n is the gap after the folder's page n, owner
    'new', 'cont' or 'unsure'."""
    key = json.loads((pairs_cache / "checkpack" / "key.json").read_text())["cases"]
    lab = {(g["left"], g["right"]): g for g in map(json.loads, open(pairs_cache / "labels.jsonl", encoding="utf-8"))}
    with open(answers, newline="") as fh:
        ans = {r[0].strip(): r[1].strip() for r in csv.reader(fh) if len(r) >= 2}
    out = []
    for k in key:
        g = lab[(k["left"], k["right"])]
        a = ans.get(k["id"])
        if a not in ("new", "same", "unsure"):
            raise SystemExit(f"{k['id']}: no owner answer")
        out.append({"id": k["id"], "folder_id": g["folder_id"], "n": g["n"], "split": g["split"],
                    "stratum": k["stratum"], "tag": k["tag"], "owner": {"same": "cont"}.get(a, a)})
    return out


def checkpack_windows(cases, pairs_cache=PAIRS_CACHE):
    """{folder_id: (pages {n: jpeg}, [window nums, ...])}: the corpus windows covering any case's gap."""
    by = defaultdict(list)
    for w in map(json.loads, open(pairs_cache / "windows.jsonl", encoding="utf-8")):
        by[w["folder_id"]].append(w)
    out = {}
    for c in cases:
        cover = [w for w in by[c["folder_id"]] if {c["n"], c["n"] + 1} <= {p["n"] for p in w["pages"]}]
        if not cover:
            raise SystemExit(f"{c['id']}: no corpus window covers its gap")
        pages, wins = out.setdefault(c["folder_id"], ({}, []))
        for w in cover:
            nums = [p["n"] for p in w["pages"]]
            if nums != list(range(nums[0], nums[0] + len(nums))):
                raise SystemExit(f"{c['folder_id']} {nums}: a window's pages are not consecutive")
            if nums not in wins:
                wins.append(nums)
            pages.update({p["n"]: p["jpeg"] for p in w["pages"]})
    return out


def box_name(folder_id):
    return f"cp-{folder_id}"


def checkpack_collection(folder_id, pages):
    """A bench Collection over a folder's covered pages, so method_local.request builds its windows unchanged."""
    data, *_ = _seg()
    ps = [data.Page(n=n, label="Cont", path=JPEGS / pages[n]) for n in sorted(pages)]
    return data.Collection(name=box_name(folder_id), directory=JPEGS, pages=ps)


def all_units(pairs_cache=PAIRS_CACHE):
    """[(set, col, a, b)] every window of both sets, in pack order."""
    data, _, _, W = _seg()
    units = []
    cases = checkpack_cases(pairs_cache)
    for fid, (pages, wins) in sorted(checkpack_windows(cases, pairs_cache).items()):
        col = checkpack_collection(fid, pages)
        index = {p.n: i for i, p in enumerate(col.pages)}
        for nums in sorted(wins):
            units.append(("checkpack", col, index[nums[0]], index[nums[-1]] + 1))
    for box in BOXES:
        col = data.load(box, with_exif=False)
        units += [("boxes", col, a, b) for a, b in W.windows(len(col.pages))]
    return units


def missing_text(units):
    data, *_ = _seg()
    seen, out = set(), []
    for _, col, a, b in units:
        for p in col.pages[a:b]:
            if (col.name, p.n) not in seen:
                seen.add((col.name, p.n))
                if not data.ocr_cache_path(col.name, p.n).exists():
                    out.append((col.name, p))
    return out


def cmd_plan(a):
    units = all_units()
    c = Counter(s for s, *_ in units)
    print(f"per model: {c['checkpack']} checkpack windows, {c['boxes']} box windows; "
          f"{len(MODELS)} models, {len(MODELS) * len(units)} requests")
    print(f"{len(missing_text(units))} pages without Vision text (run `ocr` first)")


def cmd_ocr(a):
    """segbench's ocr.swift (the app's Vision call) on every page still without text: reads the JPEG, writes text
    into the segbench cache only."""
    data, *_ = _seg()
    todo = missing_text(all_units())
    if not todo:
        print("every page has Vision text")
        return
    tool = data.build_ocr_tool()
    if tool is None:
        raise SystemExit("ocr.swift did not compile")
    jobs = data.CACHE_DIR / "ocr" / "kit-gate-sherlock-jobs.tsv"
    jobs.parent.mkdir(parents=True, exist_ok=True)
    jobs.write_text("".join(f"{p.path}\t{data.ocr_cache_path(name, p.n)}\n" for name, p in todo), encoding="utf-8")
    subprocess.run([str(tool), str(jobs)], check=False)
    left = missing_text(all_units())
    print(f"{len(todo) - len(left)} of {len(todo)} pages read; {len(left)} still without text")


# --- the pack -------------------------------------------------------------------------------------

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_new(path, blob):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "xb") as fh:  # never replace a frozen file
        fh.write(blob)


def cmd_pack(a):
    data, L, R, W = _seg()
    out = Path(a.out)
    if out.exists():
        raise SystemExit(f"{out} exists; inspect it instead of overwriting")
    units = all_units()
    gone = missing_text(units)
    if gone:
        raise SystemExit(f"{len(gone)} pages have no Vision text (first {gone[0][0]} {gone[0][1].n}); run `ocr`")
    recs = {role: [] for role in MODELS}
    done, sets = set(), defaultdict(lambda: {"windows": 0, "boxes": set()})
    for s, col, lo, hi in units:
        prompt, thumbs, nums = L.request(col, lo, hi)
        if "ABBYY" in prompt:
            raise SystemExit(f"{col.name} {nums}: the prompt names ABBYY")
        for num, t in zip(nums, thumbs):
            if (col.name, num) not in done:
                write_new(out / "images" / col.name / f"{num}.jpg", R.image_jpeg(t, L.MAX_SIDE))
                done.add((col.name, num))
        for role, (key, _) in MODELS.items():
            recs[role].append({"box": col.name, "window": nums, "set": s, "cache_key": R.cache_key(key, prompt, thumbs),
                               "prompt": prompt})
        sets[s]["windows"] += 1
        sets[s]["boxes"].add(col.name)
    packs = {}
    for role, rs in recs.items():
        key, served = MODELS[role]
        if len({r["cache_key"] for r in rs}) != len(rs):
            raise SystemExit(f"{role}: two windows share a cache key")
        d = out / role
        write_new(d / "windows.jsonl", "".join(json.dumps(r) + "\n" for r in rs).encode())
        meta = {"key": key, "model": R.entry(key)[0], "side": L.MAX_SIDE, "max_tokens": R.MAX_TOKENS,
                "prompt_version": R.PROMPT_VERSION, "boxes": sorted({r["box"] for r in rs}), "pages": len(done),
                "windows": len(rs), "max_images": max(len(r["window"]) for r in rs), "text": "vision",
                "made": time.strftime("%Y-%m-%dT%H:%M:%S")}
        write_new(d / "pack.json", json.dumps(meta, indent=1).encode())
        os.symlink("../images", d / "images")  # cluster_seg.py reads <pack>/images/<box>/<n>.jpg
        packs[role] = {"windows": len(rs), "served": served, "key": key}
    code = out / "support" / "segbench"
    code.mkdir(parents=True)
    for p in sorted(HERE.glob("*.py")):
        if not p.name.startswith("test_"):
            shutil.copy2(p, code / p.name)
    for name in SUPPORT_CODE:
        shutil.copy2(HERE / "institutional-compute" / name, code / name)
    jobs = out / "support" / "job"
    shutil.copytree(HERE / "sherlock" / "kit-gate", jobs)
    shutil.copy2(HERE / "sherlock" / "sh.env", jobs / "sh.env")
    shutil.copytree(HERE / "sherlock" / "bin", jobs / "bin", symlinks=True)
    files = {str(p.relative_to(out)): sha(p) for p in sorted(out.rglob("*")) if p.is_file() and not p.is_symlink()}
    freeze = {"tag": TAG, "made": time.strftime("%Y-%m-%dT%H:%M:%S"), "pages": len(done),
              "sets": {s: {"windows": v["windows"], "boxes": len(v["boxes"])} for s, v in sets.items()},
              "packs": packs, "files": files}
    write_new(out / "freeze.json", (json.dumps(freeze, indent=1) + "\n").encode())
    print(f"{sum(p['windows'] for p in packs.values())} requests "
          f"({', '.join(f'{k} {v['windows']}' for k, v in packs.items())}), {len(done)} pages, {len(files)} files -> {out}")


def check(root):
    """Every frozen file present and unchanged; each model's requests unique and as many as frozen."""
    root = Path(root)
    freeze = json.loads((root / "freeze.json").read_text())
    if freeze.get("tag") != TAG:
        raise SystemExit("not a W46.kit-gate-sherlock pack")
    bad = [rel for rel, h in freeze["files"].items() if not (root / rel).is_file() or sha(root / rel) != h]
    if bad:
        raise SystemExit(f"{len(bad)} frozen files missing or changed (first {bad[0]})")
    for name, p in freeze["packs"].items():
        ws = [json.loads(x) for x in (root / name / "windows.jsonl").read_text().splitlines()]
        if len({w["cache_key"] for w in ws}) != len(ws) or len(ws) != p["windows"]:
            raise SystemExit(f"{name}: requests are not unique or not as frozen")
        if not (root / name / "images").is_dir():
            raise SystemExit(f"{name}: images link missing")
    print(f"pack ok: {len(freeze['files'])} files, " +
          ", ".join(f"{k} {v['windows']}" for k, v in freeze["packs"].items()))
    return freeze


# --- scoring --------------------------------------------------------------------------------------

def read_answers(path):
    out = []
    for line in Path(path).read_text().splitlines():
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            pass  # a line a killed job left half-written
    return out


def import_answers(pack, results):
    """Each model's answers into its response cache under the pack's own keys, after checking this checkout still
    makes exactly those requests (so the bench's judge finds them). The call logs are left alone: they hold the
    earlier FarmShare runs. Returns {role: {"answers", "failed", "missing"}}."""
    data, L, R, W = _seg()
    want = {}
    for s, col, lo, hi in all_units():
        prompt, thumbs, nums = L.request(col, lo, hi)
        for role, (key, _) in MODELS.items():
            want[(role, R.cache_key(key, prompt, thumbs))] = (col.name, nums)
    out = {}
    for role, (key, _) in MODELS.items():
        packed = {json.loads(x)["cache_key"] for x in (Path(pack) / role / "windows.jsonl").read_text().splitlines()}
        stale = [k for k in packed if (role, k) not in want]
        if stale:
            raise SystemExit(f"{role}: {len(stale)} packed requests this checkout no longer makes; the prompt, OCR "
                             "text or thumbnails changed since the pack")
        last = {}
        path = Path(results) / "runs" / role / "answers.jsonl"
        for r in (read_answers(path) if path.exists() else []):
            if r["cache_key"] not in packed:
                raise SystemExit(f"{role}: an answer for a request this pack never made ({r['window']})")
            last[r["cache_key"]] = r
        for k, r in last.items():
            if r["status"] in ("ok", R.FAILED):
                R.cache(key).put(k, {"status": r["status"], "result": r.get("result", ""), "model": R.entry(key)[0],
                                     "provider": "Sherlock vLLM", "run": f"{PACK_NAME}/{role}"})
        done = {k for k, r in last.items() if r["status"] in ("ok", R.FAILED)}
        out[role] = {"answers": len(done), "failed": sum(last[k]["status"] == R.FAILED for k in done),
                     "missing": len(packed - done)}
    return out


def score_checkpack():
    """Per model, each case's call (mean P(new) over the windows covering it) against the owner's answer."""
    data, L, R, W = _seg()
    cases = checkpack_cases()
    cols = {fid: checkpack_collection(fid, pages) for fid, (pages, _) in checkpack_windows(cases).items()}
    wins = {fid: w for fid, (_, w) in checkpack_windows(cases).items()}
    calls = {}
    for role, (key, _) in MODELS.items():
        judge = R.judge(key)
        per = {}
        for c in cases:
            col = cols[c["folder_id"]]
            index = {p.n: i for i, p in enumerate(col.pages)}
            ps = []
            for nums in wins[c["folder_id"]]:
                if c["n"] not in nums or c["n"] + 1 not in nums:
                    continue
                j = judge(col, index[nums[0]], index[nums[-1]] + 1)
                if j is None:
                    ps = None
                    break
                bd = j["boundaries"][c["n"]]
                ps.append(bd["confidence"] if bd["decision"] == "new" else 1 - bd["confidence"])
            if ps:
                p = sum(ps) / len(ps)
                per[c["id"]] = {"p_new": p, "call": "new" if p >= 0.5 else "cont"}
        calls[role] = per
    rows = []
    for role in MODELS:
        for split in ("holdout", "train", "all"):
            cs = [c for c in cases if c["owner"] != "unsure" and split in ("all", c["split"])]
            got = [c for c in cs if c["id"] in calls[role]]
            right = sum(calls[role][c["id"]]["call"] == c["owner"] for c in got)
            rows.append({"model": role, "split": split, "gaps": len(cs), "answered": len(got), "right": right,
                         "accuracy": right / len(got) if got else None,
                         "false_splits": sum(calls[role][c["id"]]["call"] == "new" and c["owner"] == "cont" for c in got),
                         "false_merges": sum(calls[role][c["id"]]["call"] == "cont" and c["owner"] == "new" for c in got),
                         "tag_right": sum(c["tag"] == c["owner"] for c in cs)})
    split = []
    for role in ("2b", "4b"):
        for sp in ("holdout", "train", "all"):
            cs = [c for c in cases if c["owner"] != "unsure" and sp in ("all", c["split"])
                  and c["id"] in calls[role] and c["id"] in calls["teacher"]]
            sw = [c for c in cs if calls[role][c["id"]]["call"] != c["owner"]]
            split.append({"student": role, "split": sp, "gaps": len(cs), "student wrong": len(sw),
                          "teacher wrong the same way": sum(calls["teacher"][c["id"]]["call"] != c["owner"] for c in sw),
                          "teacher right": sum(calls["teacher"][c["id"]]["call"] == c["owner"] for c in sw),
                          "teacher wrong, student right": sum(calls["teacher"][c["id"]]["call"] != c["owner"] and
                                                              calls[role][c["id"]]["call"] == c["owner"] for c in cs)})
    return {"rows": rows, "teacher_split": split,
            "cases": [{**{k: c[k] for k in ("id", "split", "stratum", "owner")},
                       **{r: calls[r].get(c["id"], {}).get("call") for r in MODELS}} for c in cases]}


def score_boxes():
    """kit_gate.box_record on each locked box (known gaps only), and its teacher split."""
    import kit_gate as K
    data, *_ = _seg()
    K.KEYS = tuple(k for k, _ in MODELS.values())
    K.STUDENTS = ("fs-seg-2b", "fs-seg-4b")
    recs = []
    for box in BOXES:
        col = data.load(box, with_exif=False)
        r = K.box_record(col)
        r["split"] = "held-out" if box in HELD_OUT_BOXES else "trained-on"
        recs.append(r)
    observed = []
    for r in recs:
        for key, m in r["models"].items():
            right = sum(m["gaps"][k][0] == g["truth"] for k, g in enumerate(r["gaps"]))
            docs = K.documents(r)   # pages exact over the documents no unsure gap touches, as seg-kit-gate.md
            pages = sum(d["exact_pages"] for d in docs)
            exact = sum(d["exact_pages"] for d in docs if d["m"][key][0])
            observed.append({"model": key, "box": r["box"], "split": r["split"], "known gaps": len(r["gaps"]),
                             "unsure": len(r["unsure"]), "gap accuracy": right / len(r["gaps"]),
                             "pages exact": exact / pages if pages else None})
    return {"observed": observed, "teacher_split": K.teacher_split(recs)}


def cmd_score(a):
    freeze = check(a.pack)
    runs = import_answers(a.pack, a.results)
    out = {"tag": TAG, "pack": PACK_NAME, "sets": freeze["sets"], "runs": runs,
           "checkpack": score_checkpack(), "boxes": score_boxes()}
    (RESULTS / "seg-kit-gate-sherlock.json").write_text(json.dumps(out, indent=1) + "\n")
    for r in out["checkpack"]["rows"]:
        acc = "-" if r["accuracy"] is None else f"{r['accuracy']:.3f}"
        print(f"checkpack {r['model']:8} {r['split']:8} {r['right']}/{r['answered']} of {r['gaps']}  {acc}")
    for r in out["boxes"]["observed"]:
        print(f"{r['box']:18} {r['model']:15} gap accuracy {r['gap accuracy']:.3f}  pages exact {r['pages exact']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan")
    sub.add_parser("ocr")
    p = sub.add_parser("pack"); p.add_argument("--out", required=True)
    p = sub.add_parser("check"); p.add_argument("--root", required=True)
    p = sub.add_parser("score"); p.add_argument("--pack", required=True); p.add_argument("--results", required=True)
    a = ap.parse_args()
    if a.cmd == "check":
        check(a.root)
    else:
        {"plan": cmd_plan, "ocr": cmd_ocr, "pack": cmd_pack, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    main()
