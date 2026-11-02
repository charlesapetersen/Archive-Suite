#!/usr/bin/env python3
"""W46.kit-gate-sherlock: the students and the teacher on owner-ruled gaps no cache holds answers for.

Two sets, each answered by the Qwen3.5 27B teacher (fs-qwen3.5-27b) and the fine-tuned 2B and 4B (fs-seg-2b, fs-seg-4b)
in one Sherlock submission:
  checkpack  the windows that cover the owner's 80 checkpack gaps (corpus_pairs.py checkpack; answers in
             segbench-results/label-clean-owner-answers.csv): 71 in collections the students trained on, 9 held out.
  boxes      the three locked boxes, whole: Sasha (the one locked box no student trained on), the Illustrated Review
             and SC0122 (both wholly in the students' training split: trained-on). The last two are W46.seg-boxes-score's
             teacher-and-4B arm, so that item shares this job rather than running the teacher twice.

  kit_gate_sherlock.py refresh               # offline provenance/owner-score refresh of saved scores
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
import math
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
    # The checkpack was drawn by stratum (corpus_pairs.check_stratum: the tag against the teacher's ABBYY-run label),
    # not in proportion to the population, so the strata are reported apart as well as pooled.
    strata = []
    for st in sorted({c["stratum"] for c in cases}):
        cs = [c for c in cases if c["owner"] != "unsure" and c["stratum"] == st]
        strata.append({"stratum": st, "gaps": len(cs), "tag_right": sum(c["tag"] == c["owner"] for c in cs),
                       **{role: sum(calls[role].get(c["id"], {}).get("call") == c["owner"] for c in cs)
                          for role in MODELS}})
    paired = [paired_row(f"{a} vs {b}", sp, [(calls[a][c["id"]]["call"] == c["owner"],
                                               calls[b][c["id"]]["call"] == c["owner"])
                                              for c in cases if c["owner"] != "unsure" and sp in ("all", c["split"])
                                              and c["id"] in calls[a] and c["id"] in calls[b]])
              for a, b in (("2b", "teacher"), ("4b", "teacher"), ("2b", "4b")) for sp in ("holdout", "all")]
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
    return {"rows": rows, "strata": strata, "teacher_split": split, "paired": paired,
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
            calls = [(m["gaps"][k][0], g["truth"]) for k, g in enumerate(r["gaps"])]
            observed.append({"model": key, "box": r["box"], "split": r["split"], "known gaps": len(r["gaps"]),
                             "unsure": len(r["unsure"]), "gap accuracy": right / len(r["gaps"]),
                             "pages exact": exact / pages if pages else None,
                             "false splits": sum(c == "new" and t == "continue" for c, t in calls),
                             "false merges": sum(c == "continue" and t == "new" for c, t in calls)})
    names = {k: role for role, (k, _) in MODELS.items()}
    paired = [paired_row(f"{names[a]} vs {names[b]}", r["box"],
                         [(r["models"][a]["gaps"][k][0] == g["truth"], r["models"][b]["gaps"][k][0] == g["truth"])
                          for k, g in enumerate(r["gaps"])])
              for r in recs for a, b in (("fs-seg-2b", "fs-qwen3.5-27b"), ("fs-seg-4b", "fs-qwen3.5-27b"),
                                         ("fs-seg-2b", "fs-seg-4b"))]
    return qualify_boxes({"observed": observed, "teacher_split": K.teacher_split(recs), "paired": paired})


# This is the completed local arm, not the unfinished gateway/offset experiment.
OWNER_SOURCE = "seg-boxes-score-local.json"
OWNER_ROUTES = {"fs-qwen3.5-27b": "teacher", "fs-seg-2b": "fs-2b", "fs-seg-4b": "fs-4b"}
SC_TRUTH = "tag/teacher-drafted; owner ruled disputes and sampled agreed controls"
SC_LIMIT = "diagnostic against drafted truth; document exactness is conditional on that draft"


def qualify_boxes(boxes, source=None):
    """Reuse and validate the committed owner estimator; never read images or run a model.

    Match the source's all-known route rows to this kit run before carrying over its owner-supported
    estimates. Keep every original numeric diagnostic, with explicit truth/scope metadata.
    """
    source = RESULTS / OWNER_SOURCE if source is None else Path(source)
    raw = source.read_bytes()
    local = json.loads(raw)
    if local["tag"] != "W46.seg-boxes-score":
        raise ValueError("SC0122 owner source has the wrong tag")
    owner = local["sc0122_owner"]
    if (owner["asked_known"], owner["controls"], owner["agreed_doc_gaps"]) != (30, 60, 158):
        raise ValueError("SC0122 owner source has changed support; review before reuse")
    strata = list(owner["strata"].values())
    if (owner["uncovered_strata"] or len(strata) != 4 or any(not 0 < n <= N for N, n in strata)
            or sum(N for N, n in strata) != 158 or sum(n for N, n in strata) != 60):
        raise ValueError("SC0122 owner source has missing or inconsistent strata")
    models = {}
    for kit, route in OWNER_ROUTES.items():
        row = next(r for r in boxes["observed"] if r["box"] == "SC0122" and r["model"] == kit)
        original = next(r for r in local["observed"] if r["box"] == "SC0122" and r["route"] == route)
        for field in ("known gaps", "unsure", "gap accuracy", "pages exact", "false splits", "false merges"):
            if row[field] != original[field]:
                raise ValueError(f"SC0122 {kit}: owner source mismatches kit {field}")
        m = owner["models"][route]
        if not (0 <= m["asked_right"] <= 30 and 0 <= m["controls_right"] <= 60
                and 0 <= m["agreed_weighted_accuracy"] <= 1
                and math.isclose(m["owner_weighted_accuracy"],
                                 (m["asked_right"] + 158 * m["agreed_weighted_accuracy"]) / 188,
                                 rel_tol=0, abs_tol=1e-12)):
            raise ValueError(f"SC0122 {kit}: inconsistent owner estimate")
        models[kit] = dict(m)
    for r in boxes["observed"]:
        r["truth"] = SC_TRUTH if r["box"] == "SC0122" else "locked owner truth"
        r["interpretation"] = SC_LIMIT if r["box"] == "SC0122" else "known gaps; unsure-touching documents excluded"
    for r in boxes["paired"]:
        r["interpretation"] = SC_LIMIT if r["scope"] == "SC0122" else "paired known-gap comparison"
    for per in boxes["teacher_split"].values():
        for box, r in per.items():
            r["interpretation"] = SC_LIMIT if box == "SC0122" else "descriptive co-occurrence"
    boxes["sc0122_owner"] = {**{k: v for k, v in owner.items() if k != "models"}, "models": models,
                              "source": source.name, "source_sha256": hashlib.sha256(raw).hexdigest(),
                              "estimator": "seg_boxes_score.py::sc0122_owner",
                              "truth": "owner-ruled disputes and agreed controls; agreed strata weighted N/n",
                              "scope": "trained-on; 90 known owner-ruled gaps support an estimate over 188 document gaps; "
                                       "no owner-supported document-exact estimate or independent held-out accuracy"}
    return boxes


def cmd_refresh(_a):
    """Offline consuming refresh of saved scores, without pack import or duplicate inference."""
    path = RESULTS / "seg-kit-gate-sherlock.json"
    out = json.loads(path.read_text())
    out["boxes"] = qualify_boxes(out["boxes"])
    path.write_text(json.dumps(out, indent=1) + "\n")
    (RESULTS / "seg-kit-gate-sherlock.md").write_text(render(out))


def paired_row(pair, scope, rights):
    """Gap-accuracy difference of a over b on the same gaps, with the discordant gaps and an exact two-sided sign
    test on them (McNemar's exact form): [(a right, b right)]."""
    from math import comb
    only_a = sum(x and not y for x, y in rights)
    only_b = sum(y and not x for x, y in rights)
    n = only_a + only_b
    p = min(1.0, 2 * sum(comb(n, i) for i in range(min(only_a, only_b) + 1)) / 2 ** n) if n else 1.0
    return {"pair": pair, "scope": scope, "gaps": len(rights), "only first right": only_a, "only second right": only_b,
            "difference points": 100 * (only_a - only_b) / len(rights) if rights else None, "sign test p": p}


LABEL = {"teacher": "Qwen3.5 27B teacher", "2b": "fine-tuned Qwen3.5 2B (the shipped build's source)",
         "4b": "fine-tuned Qwen3.5 4B", "fs-qwen3.5-27b": "Qwen3.5 27B teacher",
         "fs-seg-2b": "fine-tuned Qwen3.5 2B (the shipped build's source)", "fs-seg-4b": "fine-tuned Qwen3.5 4B"}
SPLIT = {"holdout": "held out (9)", "train": "training collections (65)", "all": "all (74)"}
STRATUM = {"A": "A: tag start the teacher agreed with", "B": "B: tag start the teacher leaned against",
           "C": "C: tag continuation start-trust made a start", "D": "D: agreed continuation"}


def render(out):
    """seg-kit-gate-sherlock.md, from the scored record alone."""
    cp, bx, runs = out["checkpack"], out["boxes"], out["runs"]
    pct = lambda v: "-" if v is None else f"{100 * v:.1f}%"
    L = ["# W46.kit-gate-sherlock — the students and the teacher on locked boxes and owner checks", "",
         "Generated by `ArchiveProcessor/scripts/segbench/kit_gate_sherlock.py score` from one Sherlock submission "
         f"(pack `{out['pack']}`, batch 20261031-210431): the Qwen3.5 27B teacher and the fine-tuned 2B and 4B on the "
         f"same {out['sets']['checkpack']['windows'] + out['sets']['boxes']['windows']} windows each, the bench's "
         "request (7-page windows at stride 3, images at 1,024 px, temperature 0, thinking off), vLLM 0.31 on one "
         "GPU. Apple Vision text on every window, not ABBYY (owner, 2026-10-30). No money.", "",
         "Answers: " + ", ".join(f"{LABEL[k]} {v['answers']} ({v['failed']} failed, {v['missing']} missing)"
                                 for k, v in runs.items()) +
         ". A failed window counts as the bench's neutral answer, as everywhere in the bench.", "",
         "## The owner's checkpack (80 gaps, 6 unsure out)", "",
         "A gap's call is the mean P(new) over every window that holds both its pages. Nine gaps sit in collections "
         "no student trained on; 65 in collections they did, where their training target was the teacher's reply on "
         "ABBYY text, so these windows (Vision text) are not their training input either. The tag column is the "
         "corpus's own label, the one label cleaning started from.", "",
         "| model | gaps | right | accuracy | false splits | false merges | tag right |", "|---|---|---:|---:|---:|---:|---:|"]
    for r in cp["rows"]:
        L.append(f"| {LABEL[r['model']]} | {SPLIT[r['split']]} | {r['right']}/{r['answered']} | {pct(r['accuracy'])} "
                 f"| {r['false_splits']} | {r['false_merges']} | {r['tag_right']} |")
    L += ["", "By the stratum the gap was drawn from (the checkpack drew about equal numbers from each, so the pooled "
          "rows are not a population rate):", "",
          "| stratum | gaps | tag right | teacher | 2B | 4B |", "|---|---:|---:|---:|---:|---:|"]
    for s in cp["strata"]:
        L.append(f"| {STRATUM.get(s['stratum'], s['stratum'])} | {s['gaps']} | {s['tag_right']} | {s['teacher']} "
                 f"| {s['2b']} | {s['4b']} |")
    L += ["", "## The three locked boxes", "",
          "Known gaps only (unsure out); pages exact over the documents no unsure gap touches, as `seg-kit-gate.md`. "
          "Sasha is the one owner box no student trained on; the Illustrated Review and SC0122 are wholly in their "
          "training split (owner, 2026-10-29). SC0122's all-known rows are diagnostics against tag/teacher-drafted truth, "
          "including unchecked agreement. Their document-exact figures are conditional on that draft, not "
          "owner-supported document accuracy. Use the owner-supported gap estimator below.", "",
          "| model | box | split | known gaps | gap accuracy | false splits | false merges | pages exact |",
          "|---|---|---|---:|---:|---:|---:|---:|"]
    for r in bx["observed"]:
        L.append(f"| {LABEL[r['model']]} | {r['box']} | {r['split']}{' (draft diagnostic)' if r['box'] == 'SC0122' else ''} | {r['known gaps']} | {pct(r['gap accuracy'])} "
                 f"| {r['false splits']} | {r['false merges']} | {pct(r['pages exact'])} |")
    sc = bx["sc0122_owner"]
    L += ["", "## SC0122: owner-supported weighted gap estimate (trained-on)", "",
          f"Reused without inference from `{sc['source']}` (`{sc['estimator']}`; SHA-256 `{sc['source_sha256']}`). "
          "The owner ruled 37 disputed gaps and 60 agreed controls; 30 disputes remain known document-to-document "
          "gaps after excluding unsure and non-document support. The 60 controls represent 158 known agreed document gaps, weighted N/n "
          "within each of four covered strata. Thus 90 known owner rulings support the estimate over 188 gaps; "
          "this is not 188 independent owner rulings. No owner-supported document-exact estimate follows from "
          "these sampled gap controls. These are stratified-sample point estimates; the paired tests below do not "
          "include control-subsampling uncertainty. Students trained on this box; this is not held-out accuracy.", "",
          "| model | known disputes right / 30 | controls right / 60 | agreed weighted | owner-supported weighted |",
          "|---|---:|---:|---:|---:|"]
    for key, m in sc["models"].items():
        L.append(f"| {LABEL[key]} | {m['asked_right']} | {m['controls_right']} | "
                 f"{pct(m['agreed_weighted_accuracy'])} | {pct(m['owner_weighted_accuracy'])} |")
    L += ["", "Stratum support (population N / owner controls n): " +
          "; ".join(f"{s}: {N}/{n}" for s, (N, n) in sc["strata"].items()) + ".", "",
          "## Paired differences", "",
          "Same gaps, same windows. Discordant gaps are those only one model of the pair gets right; p is the exact "
          "two-sided sign test on them. Sampling only: the rerun floor (1.4-3.2 points a box, `seg-kit-gate.md`) is "
          "not in it, and gaps within one box are not independent, so a small p on one box is one box's finding. "
          "SC0122 paired rows are draft-agreement diagnostics, not independent accuracy tests.", "",
          "| pair | scope | gaps | only first right | only second right | difference | p |",
          "|---|---|---:|---:|---:|---:|---:|"]
    for r in cp["paired"] + bx["paired"]:
        scope = SPLIT.get(r["scope"], r["scope"]) + (" (draft diagnostic)" if r["scope"] == "SC0122" else "")
        if r["scope"] in SPLIT:
            scope = "checkpack, " + scope
        L.append(f"| {r['pair']} | {scope} | {r['gaps']} | {r['only first right']} | {r['only second right']} "
                 f"| {r['difference points']:+.1f} points | {r['sign test p']:.3g} |")
    L += ["", "## The teacher split", "",
          "Each student's wrong gaps by what the teacher did on the same gap; descriptive co-occurrence in single "
          "runs, as in `seg-kit-gate.md`. SC0122 is descriptive agreement with drafted truth only.", "",
          "| student | set | gaps | student wrong | teacher wrong the same way | teacher right | teacher wrong, student right |",
          "|---|---|---:|---:|---:|---:|---:|"]
    for r in cp["teacher_split"]:
        L.append(f"| {LABEL[r['student']]} | checkpack, {SPLIT[r['split']]} | {r['gaps']} | {r['student wrong']} | "
                 f"{r['teacher wrong the same way']} | {r['teacher right']} | {r['teacher wrong, student right']} |")
    for key, per in bx["teacher_split"].items():
        for box, r in per.items():
            L.append(f"| {LABEL[key]} | {box} ({r['split']}) | {r['gaps']} | {r['student wrong']} | "
                     f"{r['teacher wrong the same way']} | {r['teacher right']} | {r['teacher wrong, student right']} |")
    L += ["", READING, "", CARD, ""]
    return "\n".join(L)


# Written after reading the scored record (2026-11-01); a rescore that moves a figure must revisit these.
READING = """## Reading

- **On Sasha, the one owner box no model trained on, the shipped 2B beats its teacher by a wide margin: 89.1% of
  175 known gaps against 67.4%** (44 gaps only the 2B gets right, 6 only the teacher; p far below 0.001), and the 4B
  sits between (80.0%; 27 to 5 against the teacher, 8 to 24 against the 2B). All 57 of the teacher's errors there
  are false splits (pages exact 15.5%, against the 2B's 46.6%). So on this box the students are not bounded by the
  teacher's errors, though most of their own errors (13 of the 2B's 19, 30 of the 4B's 35) are gaps the teacher also
  gets wrong. One box: it shows the teacher can be beaten on held-out owner material, not by how much on another.
- **On the Illustrated Review, trained-on, the teacher leads (78.1% against 73.3% and 71.9%; 4B against teacher 3
  to 12, p 0.035)**, every model is weak, and the students' errors are mostly false merges (30 and 29); on SC0122,
  trained-on, 98.9-99.5% is agreement with partly teacher-drafted truth, not independent accuracy. The reused
  owner-supported weighted gap estimates are 98.1% (2B) and 99.5% (teacher and 4B), within the rerun floor;
  sampled gap controls do not justify an owner-supported document-exact claim.
- **On the owner's checkpack the 2B is right on 67 of 74 gaps, the 4B 64, the teacher 62.** On the 9 held-out gaps
  the students get 8 and the teacher 7. Paired, 2B against teacher is 6 gaps to 1 (p 0.125): a lead, not a
  finding at n 74, and the 9 held-out gaps settle nothing on their own. Eleven of the teacher's 12 errors are false
  splits, 6 of the 12 in stratum C, drawn where the teacher's label overturned the tag (Selection). Against the corpus tag
  (53 of 74 right) the gain is all in stratum C: the 2B 19 of 21 where the tag has 6.
- **The 4B is not better than the 2B on held-out owner material**: worse on Sasha (80.0% against 89.1%) and level
  or worse on the checkpack. The development and test boxes' +0.87-point 4B lead (`seg-kit-gate.md`) does not carry
  to Sasha.
- **Input shift.** The students were trained on windows carrying ABBYY's text and are measured here on Apple
  Vision's, the app's input. These are the first student figures on the app's input on owner-ruled gaps."""

CARD = """## Measurement card

- **Truth.** The owner's answers on the 80-gap checkpack (`label-clean-owner-answers.csv`; his 6 unsure out), and the
  three locked boxes' truths (Sasha owner-ruled from label tags, locked 2026-10-30; the Illustrated Review and SC0122
  locked 2026-10-29/30), unsure gaps out of every count. SC0122 was drafted from tags plus the scored Qwen3.5 27B
  teacher: the owner ruled 37 disputes and 60 agreed controls, not the remaining agreed gaps. Its 188-gap rows,
  paired tests, teacher split and document-exact figures are draft diagnostics. The separate owner-supported
  estimator uses 30 known disputes and 60 controls weighted to 158 agreed document gaps, with all four strata
  covered. It estimates gap accuracy only, on trained-on material. Checkpack truth is owner-ruled, but its
  candidate gaps came from the teacher's label-clean run (Selection).
- **Selection.** The three boxes whole. The checkpack was drawn by stratum from the corpus label set, and the strata
  are defined by the teacher's own ABBYY-run label against the tag (`corpus_pairs.check_stratum`): selected partly by
  a tested route and by ABBYY text. That over-represents gaps the teacher disagreed with (strata B, C), which biases
  the teacher's checkpack accuracy down against the students'; the strata are reported apart for that reason, and the
  boxes carry the comparison.
- **Comparison.** One pack: the three models on the same windows, prompt, images and Vision text, under the same
  server settings. Both OCR sets do not apply: this is segmentation, scored on gaps.
- **Noise.** Single runs at temperature 0. Paired sign tests above are sampling only; the rerun floor (1.4-3.2
  points a box) is not in them, so a gap inside it is a tie (SC0122, the checkpack's held-out 9). Sasha's 21.7-point
  lead is far outside both.
- **Scope.** Owner material only, one held-out owner box. It does not say how the students do on other kinds of
  material, what owner-ruled training labels would gain, or how a second-family teacher compares."""


def cmd_score(a):
    freeze = check(a.pack)
    runs = import_answers(a.pack, a.results)
    out = {"tag": TAG, "pack": PACK_NAME, "sets": freeze["sets"], "runs": runs,
           "checkpack": score_checkpack(), "boxes": score_boxes()}
    (RESULTS / "seg-kit-gate-sherlock.json").write_text(json.dumps(out, indent=1) + "\n")
    (RESULTS / "seg-kit-gate-sherlock.md").write_text(render(out))
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
    sub.add_parser("refresh", help="reuse committed local owner scores; no inference or pack import")
    p = sub.add_parser("pack"); p.add_argument("--out", required=True)
    p = sub.add_parser("check"); p.add_argument("--root", required=True)
    p = sub.add_parser("score"); p.add_argument("--pack", required=True); p.add_argument("--results", required=True)
    a = ap.parse_args()
    if a.cmd == "check":
        check(a.root)
    else:
        {"plan": cmd_plan, "ocr": cmd_ocr, "pack": cmd_pack, "score": cmd_score, "refresh": cmd_refresh}[a.cmd](a)


if __name__ == "__main__":
    main()
