#!/usr/bin/env python3
"""W46.kit-continuation. The segmentation continuation (`seg-2b-lora-k200`): a LoRA continuation of the shipped 2B on
one material's corrected gaps, for the next boxes of that material, past the kit's gate before the app loads it.

  kit_continuation.py pack    DIR [DIR ...] --sources DIR [--sources DIR] [--pool NAME] [--material ID]
                              [--text pdf|none] --out PACK          # on the Mac: the correction windows
  kit_continuation.py heldout DIR [DIR ...] --sources DIR [--pool NAME] [--material ID] [--text pdf|none]
                              --train PACK --out HELDOUT            # on the Mac: the next box, for the gate
  kit_continuation.py rows    --pack PACK --answers RUN/answers.jsonl (--replay DATA | --no-replay) --out DATA
                                                                    # on the cluster: train_seg.py train's data

THE TRIGGER (owner, 2026-11-06, call 7; notes 07 and 12 §7.5). The review records (kit_corrections.py, SPEC/
collection-settings.md §"The review records") must hold at least 200 gaps of one material ruled on by a person
(`checked` or `changed`); `pack` refuses below that. A gap left as proposed (`accepted`) is known: it may sit in a
training window, with the call the person left, but it does not count. The held-out set is the next box of the same
material, reviewed in the app the same way; `heldout` refuses it below the gate's own minimum, 267 known gaps in 10
documents (train_seg.py MIN_KNOWN_GAPS, MIN_DOCUMENTS), and refuses any page the training pack holds. Nothing in the
records says two boxes are one material: that is the user's word, as with `kit_corrections.py --pool`.

THE REQUEST is the one the app sends the shipped 2B (`window-local-seg-2b`, prompt c1, method_local.request): seven
pages, stride three, each page's source image at 1024 px and its OCR text cut at 2,500 characters. The images are
the source files the review records name, found by SHA-256 in the --sources folders (else by a name that is unique
there); the text is the output PDF's text page (`--text pdf`, read with pdftotext: the body after the header's blank
line) or "(no text found)" for every page (`--text none`). Page numbers are the run's. A window holds only recorded
gaps, so a page the records do not name (a box or folder photo, a removed page) splits the run there.

THE ROWS follow W46.seg-adapt-lora (segbench-results/seg-adapt-lora.md, k = 200: Lincoln box 2's errors 17.2 to 4.9
per 100 gaps, measured on one material). The shipped 2B answers the training pack on the cluster (cluster_seg.py
run, IC_SEG_KEY=fs-seg-2b); each window it answered is a row whose target is its own reply with every boundary set
to the person's call, a changed one at confidence 0.95 with the cue "corrected by the reviewer". Three corpus windows
are replayed for each correction window (`--replay`, a train_seg.py data set of no-text windows, as the measured
run replayed the corpus 2B's own training set). Without one (`--no-replay`) the rows are the corrections alone, which
data.json records as not the measured recipe. Then train_seg.py train onto the merged shipped 2B (two epochs,
rank 16, lr 1e-4, --max-len 20480), merge, serve on the held-out pack and the anchor twice each beside the shipped
2B, train_seg.py check, train_seg.py mac (README, "The continuation").

No calls and no money here; nothing is written outside --out.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import kit_corrections as K  # noqa: E402

KEY = "fs-seg-2b"          # the shipped 2B's method key: cluster_seg.py run checks the pack against IC_SEG_KEY
SIDE = 1024                # method_local.MAX_SIDE
REPLAY_RATIO = 3           # seg_adapt_lora.REPLAY_RATIO
SEED = 41
CORRECTED = {"confidence": 0.95, "cue": "corrected by the reviewer"}   # seg_adapt_lora.CORRECTED
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".heic", ".heif"}


# --- the material's runs ------------------------------------------------------------------------------------------

def material_of(mats, wanted):
    """The one material the user means: --material (an id or a name), else the only one there is."""
    if wanted:
        hit = [(mid, m) for mid, m in mats.items() if wanted in (mid, m["name"])]
        if len(hit) != 1:
            raise SystemExit(f"--material {wanted}: {len(hit)} materials match ({', '.join(m['name'] for m in mats.values())})")
        return hit[0]
    if len(mats) != 1:
        raise SystemExit(f"{len(mats)} materials in these folders ({', '.join(sorted(m['name'] for m in mats.values()))}); "
                         f"name one with --material, or give them as one with --pool")
    return next(iter(mats.items()))


def stretches(material):
    """Per review run, its runs of consecutive recorded gaps: [(box, [(gap, record), ...]), ...]. A gap index g lies
    between run pages g+1 and g+2 (1-based). The box name is the run's, safe for a path, and unique."""
    by_run = {}
    for g in material["gaps"].values():
        if isinstance(g.get("gap"), int) and g.get("final") in ("new", "continue"):
            by_run.setdefault((g["folder"], g.get("runID") or ""), {})[g["gap"]] = g
    out, used = [], set()
    for (folder, run), gaps in sorted(by_run.items()):
        stem = re.sub(r"[^A-Za-z0-9]+", "-", f"{Path(folder).name}-{run[:8]}").strip("-") or "run"
        base, i = stem, 2
        while stem in used:
            stem, i = f"{base}-{i}", i + 1
        used.add(stem)
        cur = []
        for k in sorted(gaps):
            if cur and k != cur[-1][0] + 1:
                out.append((stem, cur)); cur = []
            cur.append((k, gaps[k]))
        if cur:
            out.append((stem, cur))
    return out


def source_index(dirs):
    """SHA-256 -> path and file name -> [paths] for every image under the --sources folders (links not followed)."""
    by_sha, by_name = {}, {}
    for d in dirs:
        for top, subdirs, files in os.walk(Path(d).resolve(), followlinks=False):
            subdirs[:] = [s for s in subdirs if not s.startswith(".")]
            for f in files:
                p = Path(top) / f
                if p.suffix.lower() in IMAGE_EXTS and not p.is_symlink():
                    h = hashlib.sha256(p.read_bytes()).hexdigest()
                    by_sha.setdefault(h, p)
                    by_name.setdefault(f, []).append(p)
    return by_sha, by_name


def find_source(page, index):
    by_sha, by_name = index
    if page.get("sha256") and page["sha256"] in by_sha:
        return by_sha[page["sha256"]]
    named = by_name.get(page.get("name"), [])
    if not page.get("sha256") and len(named) == 1:
        return named[0]
    return None


def pdf_text(folder, output):
    """The OCR text on the output PDF's text page: everything after the header's blank line, "" for the app's
    "No text returned by model." page. None when the PDF is not found."""
    if not output:
        return None
    p = Path(folder) / output
    if not p.is_file():
        hits = [Path(t) / output for t, _, fs in os.walk(folder, followlinks=False) if output in fs]
        if len(hits) != 1:
            return None
        p = hits[0]
    tool = shutil.which("pdftotext") or "/opt/homebrew/bin/pdftotext"
    r = subprocess.run([tool, "-f", "2", "-l", "2", "-enc", "UTF-8", str(p), "-"], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    head, _, body = r.stdout.replace("\f", "").partition("\n\n")
    if not head.startswith("Extracted text."):
        return None
    body = body.strip()
    return "" if body.startswith("No text returned by model.") else body


def page_text(t):
    """method_window.page_text: trimmed, "(no text found)" when empty, cut at MAX_TEXT characters."""
    import method_window as W
    t = (t or "").strip()
    if not t:
        return "(no text found)"
    return t if len(t) <= W.MAX_TEXT else t[:W.MAX_TEXT] + " [...]"


def render(nums, texts):
    """The c1 request's text, as method_window_cues.build_request renders it for the codex template."""
    import method_window as W
    import method_window_cues as C
    files = "\n".join(f"- {W.fname(n)}  (page {n})" for n in nums)
    block = "\n".join(f"--- page {n} ---\n{page_text(t)}" for n, t in zip(nums, texts))
    gaps = ", ".join(f"[{x}, {x + 1}]" for x in nums[:-1])
    return C.prompt_template("codex").format(k=len(nums), files=files, texts=block, gaps=gaps, max_text=W.MAX_TEXT,
                                             pages=", ".join(str(n) for n in nums))


def window_spans(n):
    import method_window as W
    return W.windows(n)


def build(a, out, want_gaps):
    """Write a cluster_seg.py pack of the material's windows into `out`, and return (pack meta, per-gap truth, pages
    by sha). `want_gaps(material)` refuses (SystemExit) when the material does not meet its floor."""
    import method_openrouter as R
    mats = K.gather(a.dirs, a.pool)
    if not mats:
        raise SystemExit("no review records in these folders (kit_corrections.py count says what is there)")
    mid, material = material_of(mats, a.material)
    want_gaps(material)
    out = Path(out)
    if out.exists():
        raise SystemExit(f"{out} exists; pick a new path")
    index = source_index(a.sources)
    tmp = out.with_name(out.name + ".tmp")
    if tmp.exists():
        shutil.rmtree(tmp)
    windows, truth, shas, missing, no_text = [], [], set(), [], 0
    for box, run in stretches(material):
        # pages of the stretch: the left page of its first gap, then each gap's right page
        nums = [run[0][0] + 1] + [g + 2 for g, _ in run]
        recs = [run[0][1]["left"]] + [rec["right"] for _, rec in run]
        folder = run[0][1]["folder"]
        srcs = [find_source(p, index) for p in recs]
        if any(s is None for s in srcs):
            # a page with no source splits the stretch: each side keeps what it can
            missing += [p.get("name") for p, s in zip(recs, srcs) if s is None]
        texts = []
        for p in recs:
            t = pdf_text(folder, p.get("output")) if a.text == "pdf" else ""
            if t is None:
                no_text += 1
                t = ""
            texts.append(t)
        for i, (g, rec) in enumerate(run):
            if srcs[i] is not None and srcs[i + 1] is not None:
                truth.append({"folder_id": box, "n": nums[i], "final": rec["final"], "ruling": rec.get("ruling"),
                              "proposed": rec.get("proposed"), "material": mid})
        # windows over each part of the stretch whose pages all have a source
        part = []
        for i in range(len(nums) + 1):
            if i < len(nums) and srcs[i] is not None:
                part.append(i); continue
            for lo, hi in window_spans(len(part)) if len(part) >= 2 else []:
                idx = part[lo:hi]
                wn = [nums[j] for j in idx]
                thumbs = []
                for j in idx:
                    dst = tmp / "images" / box / f"{nums[j]}.jpg"
                    if not dst.exists():
                        dst.parent.mkdir(parents=True, exist_ok=True)
                        dst.write_bytes(R.image_jpeg(srcs[j], SIDE))
                        shas.add(recs[j].get("sha256") or hashlib.sha256(srcs[j].read_bytes()).hexdigest())
                    thumbs.append(dst)
                prompt = render(wn, [texts[j] for j in idx])
                windows.append({"box": box, "window": wn, "cache_key": R.cache_key(KEY, prompt, thumbs),
                                "prompt": prompt})
            part = []
    if not windows:
        raise SystemExit("no window could be built: no recorded page was found in --sources")
    tmp.mkdir(parents=True, exist_ok=True)
    (tmp / "windows.jsonl").write_text("".join(json.dumps(w, ensure_ascii=False) + "\n" for w in windows))
    meta = {"item": "W46.kit-continuation", "key": KEY, "model": R.entry(KEY)[0], "side": SIDE,
            "max_tokens": R.MAX_TOKENS, "prompt_version": R.PROMPT_VERSION, "prompt_id": "c1",
            "material": mid, "material_name": material["name"], "folders": sorted(material["folders"]),
            "boxes": sorted({w["box"] for w in windows}), "pages": len(shas), "windows": len(windows),
            "text": a.text, "pages_without_text": no_text if a.text == "pdf" else None,
            "pages_without_source": sorted(set(missing)), "page_sha256": sorted(shas),
            "made": time.strftime("%Y-%m-%dT%H:%M:%S")}
    return tmp, meta, truth


def counts(truth):
    ruled = sum(t["ruling"] in ("checked", "changed") for t in truth)
    return ruled, len(truth)


def finish(tmp, out, meta, extra):
    for name, body in extra.items():
        (tmp / name).write_text(body)
    (tmp / "pack.json").write_text(json.dumps(meta, indent=1) + "\n")
    tmp.rename(out)


def cmd_pack(a):
    def floor(material):
        ruled = sum(g.get("ruling") in ("checked", "changed") for g in material["gaps"].values())
        if ruled < K.GAPS_FLOOR:
            raise SystemExit(f"{material['name']}: {ruled} gaps ruled on by a person; the continuation needs "
                             f"{K.GAPS_FLOOR} of one material ({K.GAPS_FLOOR - ruled} more to go). Gaps left as proposed "
                             f"do not count.")
    tmp, meta, truth = build(a, a.out, floor)
    ruled, known = counts(truth)
    if ruled < K.GAPS_FLOOR:   # some ruled gaps lost their pages: the floor is on what trains, not what was recorded
        shutil.rmtree(tmp)
        raise SystemExit(f"only {ruled} of the ruled gaps have both pages in --sources; the continuation needs "
                         f"{K.GAPS_FLOOR}. Missing: {', '.join(meta['pages_without_source'][:5])}")
    meta.update(role="train", ruled_gaps=ruled, known_gaps=known)
    finish(tmp, Path(a.out), meta, {"truth.jsonl": "".join(json.dumps(t) + "\n" for t in truth)})
    print(json.dumps({k: meta[k] for k in ("material_name", "windows", "pages", "ruled_gaps", "known_gaps", "text",
                                           "pages_without_text", "pages_without_source")}, indent=1))
    print(f"-> {a.out}. Next: the shipped 2B answers it on the cluster (README, \"The continuation\"). The gate will "
          f"need the next box of this material: at least 267 known gaps in 10 documents (kit_continuation.py heldout).")


def cmd_heldout(a):
    sys.path.insert(0, str(HERE))
    import train_seg as T
    try:
        train = json.loads((Path(a.train) / "pack.json").read_text())
    except (OSError, ValueError):
        train = None
    if not isinstance(train, dict) or train.get("role") != "train":
        raise SystemExit(f"--train {a.train} is not a training pack (kit_continuation.py pack)")
    tmp, meta, truth = build(a, a.out, lambda m: None)
    overlap = set(meta["page_sha256"]) & set(train["page_sha256"])
    labels = [{"folder_id": t["folder_id"], "n": t["n"], "split": "holdout",
               "tag": "new" if t["final"] == "new" else "cont"} for t in truth]
    docs = sum(len(v) for v in T.heldout_groups(labels, {}, {}, None)[0].values())
    reasons = []
    if overlap:
        reasons.append(f"{len(overlap)} of its pages are in the training pack {a.train}: the held-out box must be one "
                       f"the continuation never saw")
    if len(truth) < T.MIN_KNOWN_GAPS:
        reasons.append(f"{len(truth)} known gaps; the gate needs at least {T.MIN_KNOWN_GAPS} (train_seg.py check "
                       f"refuses fewer): review more of the next box, or a further box of the same material")
    if docs < T.MIN_DOCUMENTS:
        reasons.append(f"{docs} documents; the gate needs at least {T.MIN_DOCUMENTS}: a material of a few long "
                       f"documents needs more than one next box")
    if reasons:
        shutil.rmtree(tmp)
        raise SystemExit(f"{meta['material_name']}: not a held-out box for the gate yet:\n- " + "\n- ".join(reasons))
    ruled = [t for t in truth if t["ruling"] in ("checked", "changed")]
    meta.update(role="heldout", known_gaps=len(truth), ruled_gaps=len(ruled), documents=docs, train_pack=train["made"],
                train_material=train["material"],
                note="labels.jsonl is every recorded gap at the call the person left (as `tag`); ruled.csv the gaps "
                     "a person checked or changed. A gap accepted through the skim was the proposing approach's "
                     "call: when that was the shipped 2B, the comparison leans toward the shipped model, which only "
                     "makes the gate harder for the continuation to pass.")
    finish(tmp, Path(a.out), meta, {
        "labels.jsonl": "".join(json.dumps(x) + "\n" for x in labels),
        "ruled.csv": "".join(f"{t['folder_id']},{t['n']},{'new' if t['final'] == 'new' else 'same'}\n" for t in ruled)})
    if meta["material"] != train["material"]:
        print(f"note: the held-out box is recorded as {meta['material_name']}, the training pack as "
              f"{train['material_name']}; the gate is only meaningful if they are one material", file=sys.stderr)
    print(json.dumps({k: meta[k] for k in ("material_name", "windows", "known_gaps", "ruled_gaps", "documents")}, indent=1))
    print(f"-> {a.out}: score it with train_seg.py check --labels {a.out}/labels.jsonl --ruled {a.out}/ruled.csv")


# --- on the cluster: the training rows ----------------------------------------------------------------------------

def corrected(reply, nums, calls):
    """(target, flips): the 2B's reply with every boundary set to the person's call; None when it cannot be."""
    from seg_adapt_lora import reply_text
    try:
        obj = json.loads(reply)
    except ValueError:
        return None
    if not isinstance(obj, dict) or not isinstance(obj.get("pages"), list) or not isinstance(obj.get("boundaries"), list):
        return None
    want = {(x, x + 1) for x in nums[:-1]}
    seen, flips = set(), 0
    for bd in obj["boundaries"]:
        pair = tuple(bd.get("between") or ()) if isinstance(bd, dict) else ()
        if pair not in want or pair in seen or bd.get("decision") not in ("new", "continue"):
            return None
        seen.add(pair)
        if bd["decision"] != calls[pair[0]]:
            bd.update(decision=calls[pair[0]], **CORRECTED)
            flips += 1
    if seen != want:
        return None
    return reply_text(obj), flips


def cmd_rows(a):
    pack, out = Path(a.pack).resolve(), Path(a.out)
    meta = json.loads((pack / "pack.json").read_text())
    if meta.get("role") != "train":
        raise SystemExit(f"{pack} is not a training pack (kit_continuation.py pack)")
    calls = {}
    for line in (pack / "truth.jsonl").read_text().splitlines():
        t = json.loads(line)
        calls.setdefault(t["folder_id"], {})[t["n"]] = t["final"]
    wins = {w["cache_key"]: w for w in map(json.loads, (pack / "windows.jsonl").read_text().splitlines())}
    rows, why, flips = [], {"not answered": 0, "reply not usable": 0}, 0
    seen = set()
    for line in Path(a.answers).read_text().splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        w = wins.get(r.get("cache_key"))
        if w is None or r["cache_key"] in seen:
            continue
        seen.add(r["cache_key"])
        got = corrected(r.get("result", ""), w["window"], calls[w["box"]]) if r.get("status") == "ok" else None
        if got is None:
            why["reply not usable" if r.get("status") == "ok" else "not answered"] += 1
            continue
        rows.append({"box": w["box"], "window": w["window"], "prompt": w["prompt"], "target": got[0],
                     "text": meta["text"], "flips": got[1]})
        flips += got[1]
    why["not answered"] += len(wins) - len(seen)
    if not rows:
        raise SystemExit("no window of the pack has a usable answer from the shipped 2B")
    replay, src, images = [], None, {}
    if a.replay:
        src = Path(a.replay).resolve()
        rmeta = json.loads((src / "data.json").read_text())
        corpus = [json.loads(x) for x in (src / "train.jsonl").read_text().splitlines()]
        # image windows trained without page text only: the owner's rule of 2026-10-30 bars ABBYY text from new rows
        corpus = [r for r in corpus if "box" in r and r.get("text") == "none" and "ABBYY" not in r["prompt"]]
        if not corpus:
            raise SystemExit(f"{src}: no no-text image windows to replay")
        random.Random(SEED).shuffle(corpus)
        replay = corpus[:REPLAY_RATIO * len(rows)]
        rimages = Path(rmeta["images"])
        for box in {r["box"] for r in replay}:
            images[box] = rimages / box
    for box in {r["box"] for r in rows}:
        if box in images:
            raise SystemExit(f"box name {box} is both a correction run and a replay box")
        images[box] = pack / "images" / box
    all_rows = rows + replay
    random.Random(SEED).shuffle(all_rows)
    for box, target in sorted(images.items()):
        lost = [n for r in all_rows if r["box"] == box for n in r["window"] if not (target / f"{n}.jpg").is_file()]
        if lost:
            raise SystemExit(f"{box}: {len(lost)} page images missing under {target} (first {lost[0]})")
    if out.exists():
        raise SystemExit(f"{out} exists")
    tmp = out.with_name(out.name + ".tmp")
    if tmp.exists():
        shutil.rmtree(tmp)
    (tmp / "images").mkdir(parents=True)
    for box, target in sorted(images.items()):
        os.symlink(target, tmp / "images" / box)
    body = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in all_rows)
    (tmp / "train.jsonl").write_text(body)
    summary = {"item": "W46.kit-continuation", "rule": "corrections+replay" if replay else "corrections only",
               "measured_recipe": bool(replay), "material": meta["material"], "material_name": meta["material_name"],
               "corrections": len(rows), "flipped_decisions": flips, "replay": len(replay),
               "replay_from": str(src) if src else None, "dropped": why, "windows": len(all_rows),
               "images": str(out.resolve() / "images"), "pack_made": meta["made"],
               "train_sha256": hashlib.sha256(body.encode()).hexdigest()}
    if not replay:
        summary["note"] = ("no replay: W46.seg-adapt-lora replayed three corpus windows for each correction window; "
                           "these rows are not the measured recipe")
    (tmp / "data.json").write_text(json.dumps(summary, indent=1) + "\n")
    tmp.rename(out)
    print(json.dumps(summary, indent=1))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("pack", "heldout"):
        p = sub.add_parser(name)
        p.add_argument("dirs", nargs="+", help="collection output folders holding review records, or folders above them")
        p.add_argument("--sources", action="append", required=True, help="a folder holding the source images (repeatable)")
        p.add_argument("--pool", help="the folders given are one material, under this name (kit_corrections.py --pool)")
        p.add_argument("--material", help="the material's id or name, when the folders hold several")
        p.add_argument("--text", choices=("pdf", "none"), default="pdf")
        p.add_argument("--out", required=True)
        if name == "heldout":
            p.add_argument("--train", required=True, help="the training pack, whose pages the held-out box may not hold")
    p = sub.add_parser("rows")
    p.add_argument("--pack", required=True); p.add_argument("--answers", required=True); p.add_argument("--out", required=True)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--replay", help="a train_seg.py data set (train.jsonl, data.json) whose no-text windows are replayed")
    g.add_argument("--no-replay", action="store_true")
    a = ap.parse_args(argv)
    return {"pack": cmd_pack, "heldout": cmd_heldout, "rows": cmd_rows}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
