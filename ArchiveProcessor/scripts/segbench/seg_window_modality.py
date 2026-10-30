#!/usr/bin/env python3
"""W46.seg-window-modality (A-segmentation tests 6 and 7): window size, text-only windows and self-voting, open arms.

Two questions from A04 (Multi-Split) that its clean TABME++ scans cannot answer for our photographs, and one free lift:
  sweep  the trained Qwen3.5 2B (fs-seg-2b) on the three development boxes (551 pages) at window sizes K = 3, 5, 7, 10
         and the whole folder, each with images and text (the bench's request) and with the OCR text alone.
  vote   the 2B, the 4B (fs-seg-4b) and the Qwen3.5 27B teacher (fs-qwen3.5-27b) on Lincoln and the two locked test
         boxes, six runs each: three window offsets (0, 1, 2 pages; the stride is 3) x two prompts (l1, the bench's
         request; w1, method_window's first prompt with the images attached instead of read from files).
The paid Gemini 3.8 Flash half of the sweep is W46.seg-window-modality-paid.

  seg_window_modality.py plan                                   # the arms and request counts (no writes)
  seg_window_modality.py pack  --public-root DIR --out DIR      # the frozen pack for Sherlock (Mac only)
  seg_window_modality.py check --root DIR                       # the pack's hashes (Mac or Sherlock; stdlib only)
  seg_window_modality.py score --public-root DIR --pack DIR --results DIR   # -> segbench-results/seg-window-modality.json

FIXED BEFORE ANY ANSWER (nothing is chosen on the test boxes):
- A K-page window steps (K - 1) // 2 pages and starts that far before the stream, so every gap is judged about twice at
  every K; K = 7 is then exactly method_window.windows, and ``pack`` refuses unless the K = 7 image arm and the vote's
  offset-0 l1 arm are byte for byte the requests the earlier FarmShare rows were scored on.
- The whole-folder unit is method_whole's: a run of two or more document pages between the truth's label photos. The
  development boxes are scored with truth photos anyway, so the unit gives nothing the score does not already assume.
  A gap beside a label photo is in no unit and is new by construction. Its token limit is 150 a page (a 7-page window
  answers in about 400 tokens; the bench's 1,500 stays the floor). A folder with a unit still unparsed after the retry
  is reported as incomplete, not scored: its 0.5 votes would split every page.
- Text-only drops the images and replaces the prompt's one paragraph about them; every other word is the bench's.
- The vote: each run's windows are combined as method_window.combine does; a gap's decision is the majority of the six
  runs' decisions, a 3-3 tie going to their mean P(new). Also reported: the three offsets on l1 alone, the two prompts
  at offset 0 alone, each single run, and the mean of the six single runs.
No money, no calls. Owner images and text go only into the pack, which stays outside git (the repo is public).
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import time

HERE = Path(__file__).resolve().parent
RESULTS = HERE.parents[1] / "segbench-results"
TAG = "W46.seg-window-modality"
PACK_NAME = "seg-window-modality-20261029"
DEV = ("Dean", "Deaver", "Herrnstein")
VOTE_BOXES = ("Lincoln", "Stanton", "RG165")
PUBLIC = ("Lincoln",)
# role: (method_openrouter.FARMSHARE key, the name the Sherlock job serves it under)
MODELS = {"2b": ("fs-seg-2b", "seg-2b"), "4b": ("fs-seg-4b", "seg-4b"),
          "teacher": ("fs-qwen3.5-27b", "Qwen/Qwen3.5-27B-FP8")}
SIZES = (3, 5, 7, 10, "folder")
MODALITIES = ("it", "t")          # images and text; text alone
OFFSETS = (0, 1, 2)
PROMPTS = ("l1", "w1")
FOLDER_TOKENS_PER_PAGE = 150
# Each role's parts, in the order its job sends them: the folder part last, since one request too long for the
# server stops a cluster_seg run.
PARTS = {"2b": ("vote", "sweep", "folder"), "4b": ("vote",), "teacher": ("vote",)}


def sweep_arms(size):
    return [f"{'folder' if size == 'folder' else f'k{size}'}-{m}" for m in MODALITIES]


def vote_arms():
    return [f"o{o}-{p}" for o in OFFSETS for p in PROMPTS]


def _seg():
    sys.path.insert(0, str(HERE))
    import data
    import method_local as L
    import method_openrouter as R
    import method_window as W
    import method_whole as WH
    import seg_context as SC
    return data, L, R, W, WH, SC


# --- units ----------------------------------------------------------------------------------------

def spans(n, k, offset=0):
    """[start, end) windows of k pages stepping (k - 1) // 2, the first starting that far (less ``offset``) before
    the stream: method_window.windows generalised (k = 7, offset 0 is it exactly)."""
    stride = (k - 1) // 2
    out, s = [], -stride + offset
    while True:
        a, b = max(0, s), min(n, s + k)
        if b - a >= 2 and (not out or (a, b) != out[-1]):
            out.append((a, b))
        if s + k >= n + stride:
            break
        s += stride
    return out


def units(col, arm):
    """The [a, b) units an arm sends for a box."""
    _, _, _, _, WH, _ = _seg()
    head = arm.split("-")[0]
    if head == "folder":
        return WH.folders(col)
    if head.startswith("k"):
        return spans(len(col.pages), int(head[1:]))
    return spans(len(col.pages), 7, int(head[1:]))      # a vote arm, o<offset>


# --- requests -------------------------------------------------------------------------------------

def _files(nums):
    _, _, _, W, _, _ = _seg()
    return "\n".join(f"- {W.fname(n)}  (page {n})" for n in nums)


def _swap(prompt, old, new, what):
    if prompt.count(old) != 1:
        raise ValueError(f"{what}: the paragraph to replace is not unique in the prompt")
    return prompt.replace(old, new, 1)


def text_only(prompt, nums):
    old = (f"The\n{len(nums)} images attached are consecutive photographs from that stream, attached in this order:\n\n"
           f"{_files(nums)}\n\nAnswer from the images; do not run commands. The OCR text below is automatic and has "
           "errors; the image wins when they\ndisagree.")
    new = (f"This\nwindow holds {len(nums)} consecutive photographs from that stream, pages {nums[0]} to {nums[-1]}. "
           "The photographs are not shown: answer\nfrom the OCR text below alone. It is automatic and has errors.")
    return _swap(prompt, old, new, f"text-only {nums[0]}-{nums[-1]}")


def attached_w1(prompt, nums):
    old = (f"Their files are in the current directory:\n\n{_files(nums)}\n\nFIRST read every one of these image files "
           "with the Read tool (issue all the Read calls together, in one\nturn). Then answer from the images")
    new = f"They are attached in this order:\n\n{_files(nums)}\n\nAnswer from the images (do not run commands)"
    return _swap(prompt, old, new, f"w1 {nums[0]}-{nums[-1]}")


def request(col, a, b, arm):
    """(prompt, thumbs, nums, images sent, max_tokens) for one unit of an arm."""
    _, L, R, W, _, _ = _seg()
    if arm.endswith("-w1"):
        prompt, thumbs, nums = W.build_request(col, a, b)
        prompt = attached_w1(prompt, nums)
    else:
        prompt, thumbs, nums = L.request(col, a, b)
    images = list(nums)
    if arm.endswith("-t"):
        prompt, images = text_only(prompt, nums), []
    limit = R.MAX_TOKENS
    if arm.startswith("folder"):
        limit = max(R.MAX_TOKENS, FOLDER_TOKENS_PER_PAGE * len(nums))
    return prompt, thumbs, nums, images, limit


def is_base(arm):
    """The arms that must equal the scored FarmShare requests."""
    return arm in ("k7-it", "o0-l1")


def part_arms(part):
    if part == "vote":
        return vote_arms()
    if part == "sweep":
        return [a for k in SIZES if k != "folder" for a in sweep_arms(k)]
    return sweep_arms("folder")


def part_boxes(part):
    return VOTE_BOXES if part == "vote" else DEV


def plan_counts(public_root=None):
    """{(role, part): units} from the boxes' page counts alone (Lincoln needs the public root)."""
    data, *_ , SC = _seg()
    out = {}
    for role, parts in PARTS.items():
        for part in parts:
            if part == "vote" and public_root is None:
                continue
            n = 0
            for box in part_boxes(part):
                col, _ = SC.load(box, public_root)
                n += sum(len(units(col, arm)) for arm in part_arms(part))
            out[(role, part)] = n
    return out


# --- the pack -------------------------------------------------------------------------------------

def baseline_keys(box, key, public_root):
    if box in PUBLIC:
        p = Path(public_root) / "packs" / f"{box.lower()}-{key}" / "windows.jsonl"
        return {tuple(w["window"]): w["cache_key"] for w in map(json.loads, p.read_text().splitlines())}
    return None


def cmd_pack(a):
    data, L, R, W, WH, SC = _seg()
    out = Path(a.out)
    if out.exists():
        raise SystemExit(f"{out} exists; inspect it instead of overwriting")
    recs = defaultdict(dict)       # (role, part) -> cache_key -> record
    boxes, done = {}, set()
    for part in ("vote", "sweep", "folder"):
        for box in part_boxes(part):
            col, _ = SC.load(box, a.public_root)
            n = len(col.pages)
            boxes.setdefault(box, {"pages": n, "units": {}})
            for arm in part_arms(part):
                us = units(col, arm)
                covered = {i for lo, hi in us for i in range(lo, hi - 1)}
                beside = {i for i in range(n - 1) if col.labels[i] in ("Box", "Folder") or
                          col.labels[i + 1] in ("Box", "Folder")}
                if covered | (beside if arm.startswith("folder") else set()) != set(range(n - 1)):
                    raise SystemExit(f"{box} {arm}: a gap no unit judges")
                boxes[box]["units"][arm] = len(us)
                for lo, hi in us:
                    prompt, thumbs, nums, images, limit = request(col, lo, hi, arm)
                    for num, t in zip(nums, thumbs):
                        if (box, num) not in done:
                            jpeg = R.image_jpeg(t, L.MAX_SIDE)
                            if box in PUBLIC:   # the bytes the node sends, not only the thumbnails the key hashes
                                for key, _ in MODELS.values():
                                    old = Path(a.public_root) / "packs" / f"{box.lower()}-{key}" / "images" / box / f"{num}.jpg"
                                    if old.read_bytes() != jpeg:
                                        raise SystemExit(f"{box} page {num}: image bytes differ from the scored {key} pack")
                            SC.write_new(out / "images" / box / f"{num}.jpg", jpeg)
                            done.add((box, num))
                    for role, parts in PARTS.items():
                        if part not in parts:
                            continue
                        key = MODELS[role][0]
                        k = R.cache_key(key, prompt, thumbs if images else [])
                        if is_base(arm):
                            known = baseline_keys(box, key, a.public_root)
                            if known is not None and known.get(tuple(nums)) != k:
                                raise SystemExit(f"{box} {nums}: base request differs from the scored {key} pack")
                            if known is None and R.cache(key).get(k) is None:
                                raise SystemExit(f"{box} {nums}: base request is not in the {key} cache")
                        r = recs[(role, part)].get(k)
                        if r is None:
                            r = recs[(role, part)][k] = {"box": box, "window": nums, "arms": [], "cache_key": k,
                                                         "prompt": prompt, "images": images, "max_tokens": limit}
                        elif r["prompt"] != prompt or r["images"] != images:
                            raise SystemExit(f"{box} {nums}: one cache key for two requests")
                        r["arms"].append(arm)
    packs = {}
    for (role, part), rs in recs.items():
        key, served = MODELS[role]
        d = out / f"{role}-{part}"
        ws = list(rs.values())
        SC.write_new(d / "windows.jsonl", "".join(json.dumps(w) + "\n" for w in ws).encode())
        meta = {"key": key, "model": R.entry(key)[0], "side": L.MAX_SIDE, "max_tokens": R.MAX_TOKENS,
                "prompt_version": R.PROMPT_VERSION, "boxes": list(part_boxes(part)),
                "pages": sum(boxes[b]["pages"] for b in part_boxes(part)), "windows": len(ws),
                "max_images": max(len(w["images"]) for w in ws), "max_request_tokens": max(w["max_tokens"] for w in ws),
                "made": time.strftime("%Y-%m-%dT%H:%M:%S")}
        SC.write_new(d / "pack.json", json.dumps(meta, indent=1).encode())
        os.symlink("../images", d / "images")  # cluster_seg.py reads <pack>/images/<box>/<n>.jpg
        packs[f"{role}-{part}"] = {"role": role, "part": part, "windows": len(ws), "max_images": meta["max_images"]}
    code = out / "support" / "segbench"
    code.mkdir(parents=True)
    for p in sorted(HERE.glob("*.py")):
        if not p.name.startswith("test_"):
            shutil.copy2(p, code / p.name)
    for name in SC.SUPPORT_CODE:
        shutil.copy2(HERE / "institutional-compute" / name, code / name)
    jobs = out / "support" / "job"
    shutil.copytree(HERE / "sherlock" / "seg-window-modality", jobs)
    shutil.copy2(HERE / "sherlock" / "sh.env", jobs / "sh.env")
    shutil.copytree(HERE / "sherlock" / "bin", jobs / "bin", symlinks=True)
    files = {str(p.relative_to(out)): SC.sha(p) for p in sorted(out.rglob("*")) if p.is_file() and not p.is_symlink()}
    freeze = {"tag": TAG, "made": time.strftime("%Y-%m-%dT%H:%M:%S"), "boxes": boxes, "packs": packs,
              "models": {r: {"key": k, "served": s} for r, (k, s) in MODELS.items()}, "files": files}
    SC.write_new(out / "freeze.json", (json.dumps(freeze, indent=1) + "\n").encode())
    print(f"{sum(p['windows'] for p in packs.values())} requests "
          f"({', '.join(f'{k} {v['windows']}' for k, v in packs.items())}), {len(files)} files -> {out}")


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def check(root):
    """Every frozen file present and unchanged; each part's requests unique and its arms' unit counts as frozen."""
    root = Path(root)
    freeze = json.loads((root / "freeze.json").read_text())
    if freeze.get("tag") != TAG:
        raise SystemExit("not a W46.seg-window-modality pack")
    bad = [rel for rel, h in freeze["files"].items() if not (root / rel).is_file() or sha(root / rel) != h]
    if bad:
        raise SystemExit(f"{len(bad)} frozen files missing or changed (first {bad[0]})")
    for name, p in freeze["packs"].items():
        ws = [json.loads(x) for x in (root / name / "windows.jsonl").read_text().splitlines()]
        if len({w["cache_key"] for w in ws}) != len(ws) or len(ws) != p["windows"]:
            raise SystemExit(f"{name}: requests are not unique or not as frozen")
        per = Counter((w["box"], arm) for w in ws for arm in w["arms"])
        for (box, arm), k in per.items():
            if freeze["boxes"][box]["units"][arm] != k:
                raise SystemExit(f"{name}: {box} {arm} has {k} units, frozen {freeze['boxes'][box]['units'][arm]}")
        if not (root / name / "images").is_dir():
            raise SystemExit(f"{name}: images link missing")
    print(f"pack ok: {len(freeze['files'])} files, " +
          ", ".join(f"{k} {v['windows']}" for k, v in freeze["packs"].items()))
    return freeze


# --- scoring --------------------------------------------------------------------------------------

def combine_units(col, us, judge, photo_gaps_new=False):
    """method_window.combine over the given units. With ``photo_gaps_new`` (the folder arm) a gap no unit judged is
    new with certainty, which ``pack`` has checked is only ever a gap beside a label photo."""
    n = len(col.pages)
    votes_new = [[] for _ in range(n - 1)]
    cues = [[] for _ in range(n - 1)]
    kinds = [[] for _ in range(n)]
    index = {p.n: i for i, p in enumerate(col.pages)}
    for a, b in us:
        j = judge(col, a, b)
        if j is None:
            raise RuntimeError(f"{col.name}: unit {col.pages[a].n}-{col.pages[b - 1].n} has no answer")
        for num, kind in j["pages"].items():
            kinds[index[num]].append(kind)
        for x, bd in j["boundaries"].items():
            i = index[x]
            votes_new[i].append(bd["confidence"] if bd["decision"] == "new" else 1 - bd["confidence"])
            cues[i].append(f"{bd['decision']}:{bd['cue']}")
    gaps = []
    for i in range(n - 1):
        ps = votes_new[i]
        if not ps:
            if not photo_gaps_new:
                raise RuntimeError(f"{col.name}: gap {i} judged by no unit")
            ps, cues[i] = [1.0], ["new:beside a label photo"]
        p = sum(ps) / len(ps)
        gaps.append({"p_new": p, "decision": "new" if p >= 0.5 else "continue", "confidence": max(p, 1 - p),
                     "n_judged": len(ps), "agree": len({x >= 0.5 for x in ps}) == 1, "cue": " | ".join(cues[i])[:300]})
    return {"gaps": gaps, "photo": _photos(kinds), "kind_votes": kinds}


def _photos(kinds):
    photo = []
    for ks in kinds:
        cnt = {k: ks.count(k) for k in ("box", "folder", "document")}
        best = max(("box", "folder"), key=lambda k: cnt[k])
        photo.append(("Box" if best == "box" else "Folder") if cnt[best] > cnt["document"] else None)
    return photo


def vote(combs):
    """The fixed rule: per gap the majority of the runs' decisions, a tie going to their mean P(new)."""
    gaps = []
    for gs in zip(*(c["gaps"] for c in combs)):
        new = sum(g["decision"] == "new" for g in gs)
        p = sum(g["p_new"] for g in gs) / len(gs)
        dec = "new" if 2 * new > len(gs) or (2 * new == len(gs) and p >= 0.5) else "continue"
        share = (new if dec == "new" else len(gs) - new) / len(gs)
        gaps.append({"p_new": p, "decision": dec, "confidence": share, "n_judged": len(gs), "agree": share == 1,
                     "cue": f"{new} of {len(gs)} runs new"})
    kinds = [sum(ks, []) for ks in zip(*(c["kind_votes"] for c in combs))]
    return {"gaps": gaps, "photo": _photos(kinds), "kind_votes": kinds}


def judges(pack, results, name):
    """judge(arm) for one part, answering from runs/<name>/answers.jsonl through the pack's own cache keys."""
    _, L, R, W, _, SC = _seg()
    ws = {w["cache_key"]: w for w in map(json.loads, (Path(pack) / name / "windows.jsonl").read_text().splitlines())}
    got, failed = {}, Counter()      # failed: (arm, box) -> units still unparsed after the retry
    path = Path(results) / name / "answers.jsonl"
    for r in (SC.read_answers(path) if path.exists() else []):
        w = ws.get(r["cache_key"])
        if w is None:
            raise SystemExit(f"{name}: an answer for a request this pack never made ({r['window']})")
        for arm in w["arms"]:
            got[(arm, w["box"], tuple(w["window"]))] = r
            failed[(arm, w["box"])] += r["status"] != "ok"

    def judge_for(arm):
        def judge(col, a, b):
            nums = [col.pages[i].n for i in range(a, b)]
            r = got.get((arm, col.name, tuple(nums)))
            if r is None:
                return None
            if r["status"] != "ok":
                return L.neutral(nums)  # a unit still unparsed after the retry votes 0.5, as everywhere
            return W.parse_answer(r["result"], nums)
        return judge
    return judge_for, failed, len({r["cache_key"] for r in got.values()})


def score_row(col, comb, truth_photos):
    from dataclasses import asdict
    from score import score_labels, derived
    _, _, _, W, _, _ = _seg()
    c = score_labels(col.labels, W.assemble(col, comb, truth_photos).labels)
    m = derived(c)
    return {"counts": asdict(c), "pages_exact": m["pages_in_exact_doc"], "boundary_f1": m["boundary_f1"],
            "false_splits": c.false_splits, "false_merges": c.false_merges}


POOLS = {"development": DEV, "test": ("Stanton", "RG165")}


def pooled(rows):
    """Each model and arm over a pool's boxes, from the summed counts; a cell missing any box is left out, and the
    mean of single runs is the mean of the pooled single runs."""
    by = defaultdict(dict)
    for r in rows:
        if "counts" in r:
            by[(r["model"], r["arm"])][r["box"]] = r
    out = []
    for (model, arm), boxes in by.items():
        for pool, names in POOLS.items():
            if not all(b in boxes for b in names):
                continue
            c = Counter()
            for b in names:
                c.update({k: boxes[b]["counts"][k] for k in ("doc_pages", "pages_exact", "tp", "false_splits",
                                                            "false_merges")})
            out.append({"model": model, "pool": pool, "arm": arm, "pages": c["doc_pages"],
                        "pages_exact": c["pages_exact"] / c["doc_pages"],
                        "boundary_f1": 2 * c["tp"] / (2 * c["tp"] + c["false_splits"] + c["false_merges"]),
                        "false_splits": c["false_splits"], "false_merges": c["false_merges"],
                        "failed_units": sum(boxes[b].get("failed_units", 0) for b in names)})
    for model in sorted({r["model"] for r in out}):
        for pool in POOLS:
            singles = [r for r in out if r["model"] == model and r["pool"] == pool and r["arm"] in vote_arms()]
            if len(singles) == len(vote_arms()):
                out.append({"model": model, "pool": pool, "arm": "mean-of-singles", "runs": len(singles),
                            "pages_exact": sum(r["pages_exact"] for r in singles) / len(singles),
                            "boundary_f1": sum(r["boundary_f1"] for r in singles) / len(singles)})
    return sorted(out, key=lambda r: (r["model"], r["pool"], r["arm"]))


def cmd_score(a):
    _, _, _, _, _, SC = _seg()
    freeze = check(a.pack)
    rows, missing, runs = [], [], []
    for name, p in freeze["packs"].items():
        role, part = p["role"], p["part"]
        judge_for, failed, n = judges(a.pack, a.results, name)
        runs.append({"pack": name, "answers": n, "failed_units": {f"{k[0]} {k[1]}": v for k, v in failed.items() if v}})
        for box in part_boxes(part):
            col, _ = SC.load(box, a.public_root)
            truth_photos = box not in PUBLIC
            combs = {}
            for arm in part_arms(part):
                bad = failed[(arm, box)]
                if bad and arm.startswith("folder"):
                    # A failed folder votes 0.5 on every gap and so splits every page: not a score (review, 2026-10-29)
                    missing.append(f"{name} {arm} {box}: {bad} folder units failed")
                    continue
                try:
                    combs[arm] = combine_units(col, units(col, arm), judge_for(arm), arm.startswith("folder"))
                except RuntimeError as e:
                    missing.append(f"{name} {arm} {e}")
                    continue
                rows.append({"model": role, "part": part, "box": box, "arm": arm, "failed_units": bad,
                             **score_row(col, combs[arm], truth_photos)})
            if part != "vote":
                continue
            singles = [r for r in rows if r["model"] == role and r["part"] == "vote" and r["box"] == box]
            if len(singles) == len(vote_arms()):
                rows.append({"model": role, "part": part, "box": box, "arm": "mean-of-singles",
                             "pages_exact": sum(r["pages_exact"] for r in singles) / len(singles),
                             "boundary_f1": sum(r["boundary_f1"] for r in singles) / len(singles), "runs": len(singles)})
            for label, arms in (("vote6", vote_arms()), ("vote-offsets-l1", [f"o{o}-l1" for o in OFFSETS]),
                                ("vote-prompts-o0", [f"o0-{q}" for q in PROMPTS])):
                if all(x in combs for x in arms):
                    rows.append({"model": role, "part": part, "box": box, "arm": label,
                                 **score_row(col, vote([combs[x] for x in arms]), truth_photos)})
    if missing and not a.partial:
        raise SystemExit(f"{len(missing)} cells incomplete (first: {missing[0]}); --partial to score what came back")
    out = {"tag": TAG, "boxes": freeze["boxes"], "rows": rows, "pooled": pooled(rows), "runs": runs,
           "incomplete": missing}
    (RESULTS / "seg-window-modality.json").write_text(json.dumps(out, indent=1) + "\n")
    for r in rows:
        print(f"{r['model']:8} {r['box']:11} {r['arm']:16} pages exact {r['pages_exact']:.3f}  F1 {r['boundary_f1']:.3f}"
              + (f"  ({r['failed_units']} failed units)" if r.get("failed_units") else ""))


def cmd_plan(a):
    for (role, part), n in plan_counts(a.public_root).items():
        print(f"{role:8} {part:7} {n} units")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan"); p.add_argument("--public-root")
    p = sub.add_parser("pack"); p.add_argument("--public-root", required=True); p.add_argument("--out", required=True)
    p = sub.add_parser("check"); p.add_argument("--root", required=True)
    p = sub.add_parser("score"); p.add_argument("--public-root", required=True); p.add_argument("--pack", required=True)
    p.add_argument("--results", required=True); p.add_argument("--partial", action="store_true")
    a = ap.parse_args()
    if a.cmd == "check":
        check(a.root)
    else:
        {"plan": cmd_plan, "pack": cmd_pack, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    main()
