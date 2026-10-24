#!/usr/bin/env python3
"""Public boxes, separate from the owner's locked collections. Images stay outside git.

Use --root for the local source cache. Committed manifests freeze every supplied source page,
its image hash, audit and label before OCR/model collection. No paid collection command exists.
  public_segmentation.py --root DIR --box crest verify|ocr|score
  public_segmentation.py --root DIR --box crest pack --key fs-seg-2b --out DIR
  public_segmentation.py --root DIR --box crest score --out-dir STAGED_NUMBERS
  public_segmentation.py --root DIR --box crest score --key window-cues-claude   # plan-route cache, no calls
Cluster answers use institutional-compute/cluster_seg.py run/import unchanged. For import, set
SEGBENCH_CACHE=<root>/cache explicitly, so the owner's benchmark cache/logs are not replaced.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

import data

HERE = Path(__file__).resolve().parent
MANIFESTS = HERE.parents[1] / "segbench-results/public-segmentation"


def validate(manifest, root):
    """Refuse missing/reordered source pages, unaudited labels and changed/local-escaping images."""
    root = Path(root).resolve()
    pages, docs = manifest["pages"], manifest["source_documents"]
    if not pages or [p["n"] for p in pages] != list(range(1, len(pages) + 1)):
        raise ValueError("stream must be numbered 1..N")
    if len({d["id"] for d in docs}) != len(docs):
        raise ValueError("duplicate source document")
    expected = [(d["id"], n) for d in docs for n in range(1, d["pages"] + 1)]
    if [(p["id"], p["page"]) for p in pages] != expected:
        raise ValueError("source pages missing, duplicated or reordered")
    if pages[0]["label"] != "New":
        raise ValueError("the first supplied page must begin the stream")
    seen = set()
    for p in pages:
        if p["label"] not in ("New", "Cont") or p.get("reviewed") is not True or not p.get("audit"):
            raise ValueError(f"page {p['n']} lacks a valid audited label")
        rel = Path(p["image"])
        image = (root / rel).resolve()
        if rel.is_absolute() or not image.is_relative_to(root) or image in seen:
            raise ValueError("image must be unique and remain within the public cache")
        seen.add(image)
        if hashlib.sha256(image.read_bytes()).hexdigest() != p["sha256"]:
            raise ValueError(f"image changed: {p['n']}")
    return data.Collection(manifest["box"], root, [
        data.Page(p["n"], p["label"], root / p["image"]) for p in pages])


def load(box, root):
    path = MANIFESTS / f"{box}.json"
    repo = HERE.parents[2]
    rel = path.relative_to(repo)
    frozen = subprocess.run(["git", "show", f"HEAD:{rel}"], cwd=repo, capture_output=True, check=True).stdout
    if frozen != path.read_bytes():
        raise ValueError("commit the unchanged public manifest before any collection")
    manifest = json.loads(frozen)
    return validate(manifest, root), manifest


def ocr(col):
    tool = data.build_ocr_tool()
    if tool is None:
        raise RuntimeError("Apple Vision helper could not be built; no fallback text substituted")
    jobs = data.CACHE_DIR / f"ocr-{col.name}.tsv"
    jobs.parent.mkdir(parents=True, exist_ok=True)
    jobs.write_text("".join(f"{p.path}\t{data.ocr_cache_path(col.name, p.n)}\n" for p in col.pages))
    subprocess.run([str(tool), str(jobs)], check=True)


def pack(col, manifest, key, out):
    import method_openrouter as R
    import method_local as L
    import method_window as W
    sys.path.insert(0, str(HERE / "institutional-compute"))
    from cluster_ocr import atomic_write
    if key not in R.FARMSHARE:
        raise ValueError("public pack requires a registered free cluster model")
    out = Path(out)
    if out.exists():
        raise ValueError("pack output exists; inspect it instead of overwriting")
    if any(not data.ocr_cache_path(col.name, p.n).exists() for p in col.pages):
        raise ValueError("OCR every page first; do not silently omit page text")
    windows, done = [], set()
    for lo, hi in W.windows(len(col.pages)):
        prompt, thumbs, nums = L.request(col, lo, hi)
        for n, thumb in zip(nums, thumbs):
            if n not in done:
                atomic_write(out / "images" / col.name / f"{n}.jpg", R.image_jpeg(thumb, R.side_of(key)))
                done.add(n)
        windows.append({"box": col.name, "window": nums, "prompt": prompt,
                        "cache_key": R.cache_key(key, prompt, thumbs)})
    atomic_write(out / "windows.jsonl", "".join(json.dumps(w) + "\n" for w in windows).encode())
    meta = {"key": key, "model": R.entry(key)[0], "side": R.side_of(key), "max_tokens": R.MAX_TOKENS,
            "prompt_version": R.PROMPT_VERSION, "boxes": [col.name], "pages": len(done),
            "windows": len(windows), "made": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "public": True, "truth_sha256": hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()}
    atomic_write(out / "pack.json", (json.dumps(meta, indent=2) + "\n").encode())
    print(json.dumps(meta, indent=2))


def score(col, manifest, key, output_dir=None):
    from dataclasses import asdict
    from methods import AllNew, NoBoundaries, RuleCuesSketch
    from score import score_labels, derived, check_prediction
    methods = [AllNew(), NoBoundaries()]
    if all(data.ocr_cache_path(col.name, p.n).exists() for p in col.pages):
        methods.append(RuleCuesSketch())
    predictions = {m.name: m.predict(col) for m in methods}
    fitted = MANIFESTS / "rule-cues-frozen.json"
    if fitted.exists():
        import method_openrouter as R
        import rules
        from methods import from_labels
        fit = R.committed(fitted)
        if any(not data.ocr_cache_path(col.name, p.n).exists() for p in col.pages):
            raise ValueError("fitted rules require complete public OCR")
        params = rules.Params(**{**fit["params"], "rules": tuple(fit["params"]["rules"])})
        features = rules._features(col, params.top_lines, params.end_lines, params.blank_chars)
        labels, _ = rules.predict_labels(features, params)
        predictions["rule-cues"] = from_labels(labels, cue="fitted on owner development boxes only")
    if key:
        import method_window as W
        if key.startswith("window-cues-"):
            # W46.seg-lincoln-cloud: the plan routes (claude -p, codex exec), read from their own caches only.
            import method_window_cues as WC
            route = key.removeprefix("window-cues-")
            if route not in WC.ROUTES:
                raise ValueError(f"unknown window-cues route {route}")
            if route == "claude-cue":
                from seg_lincoln_gateway import claude_cue
                judge = claude_cue  # cached plan answers plus the explicitly separate gateway holes
            else:
                judge = WC.judge(route)
            predictions[key] = W.assemble(col, W.combine(col, judge), False)  # combine never calls
        elif key.startswith("gateway-"):
            import seg_lincoln_gateway as GW
            predictions[key] = GW.predictors()[key](col)  # strict, cache-only
        else:
            import method_openrouter as R
            predictions[key] = W.assemble(col, W.combine(col, R.judge(key)), False)
    result = {"box": col.name, "public": True, "pages": len(col.pages),
              "documents": Counter(col.labels)["New"], "models": {},
              "truth_sha256": hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()}
    for name, pred in predictions.items():
        check_prediction(pred)
        counts = score_labels(col.labels, pred.labels)
        result["models"][name] = {"counts": asdict(counts), "metrics": derived(counts)}
    destination = Path(output_dir) if output_dir is not None else MANIFESTS
    destination.mkdir(parents=True, exist_ok=True)
    path = destination / f"{col.name.lower()}-scores.json"
    if path.exists():
        previous = json.loads(path.read_text())
        if previous.get("truth_sha256") != result["truth_sha256"]:
            raise ValueError("previous scores use different truth; preserve and resolve them explicitly")
        previous["models"].update(result["models"])
        result = previous
    path.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--box", choices=("crest", "lincoln"), required=True)
    sub = ap.add_subparsers(dest="command", required=True)
    for cmd in ("verify", "ocr", "score", "pack"):
        p = sub.add_parser(cmd)
        if cmd in ("score", "pack"):
            p.add_argument("--key", required=cmd == "pack")
        if cmd == "pack":
            p.add_argument("--out", type=Path, required=True)
        if cmd == "score":
            p.add_argument("--out-dir", type=Path, help="Stage numeric outputs outside git for later review")
    a = ap.parse_args()
    data.CACHE_DIR = a.root / "cache"
    col, manifest = load(a.box, a.root)
    if a.command == "verify":
        print(f"{col.name}: {len(col.pages)} supplied source pages verified, all reviewed")
    elif a.command == "ocr":
        ocr(col)
    elif a.command == "pack":
        pack(col, manifest, a.key, a.out)
    elif a.command == "score":
        score(col, manifest, a.key, a.out_dir)


if __name__ == "__main__":
    main()
