#!/usr/bin/env python3
"""W46.seg-context (H-corpus test 5): what collection facts buy the segmentation window prompt.

The same windows with and without a COLLECTION FACTS block, for the trained Qwen3.5 2B (fs-seg-2b) and the Qwen3.5
27B teacher (fs-qwen3.5-27b), on CREST and Lincoln (material the students never saw) and the two locked test boxes.
The base arm is byte for byte the request every earlier FarmShare row was scored on (``pack`` asserts it against the
committed caches), so the block is the only difference. Nothing here is fitted on the test boxes: no threshold, no
prompt choice; each box gets one block, written by ``facts`` from what an app could know about the whole box.

  seg_context.py facts --public-root DIR                   # print each box's block (no writes)
  seg_context.py pack  --public-root DIR --out DIR         # the frozen pack for Sherlock (Mac only)
  seg_context.py check --root DIR                          # the pack's hashes (Mac or Sherlock; stdlib only)
  seg_context.py score --public-root DIR --pack DIR --results DIR   # answers -> segbench-results/seg-context.*

The facts (the all-facts form; Kiessling and Clerice found a single fact alone can cost, so none is sent alone):
  source     the catalogue line and its item count (public boxes), or the box and folder label photos' OCR (owner
             boxes; the app confirms those photos before segmenting)
  era        the span of four-digit years in the box's own OCR text, 10th to 90th percentile, and the commonest decade
  kind mix   how many pages carry little OCR text (handwriting, photographs, blank sides). A text-density stand-in:
             the Vision kind sorter has no per-box output for these boxes
  length     the document-length prior: pages per catalogue item (public), or the owner's development boxes'
             document lengths (owner boxes; what the same owner's earlier boxes would give the app)
No money, no calls. Owner images and text go only into the pack, which stays outside git (the repo is public).
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import sys
import time

HERE = Path(__file__).resolve().parent
RESULTS = HERE.parents[1] / "segbench-results"
TAG = "W46.seg-context"
PUBLIC = ("CREST", "Lincoln")
OWNER = ("Stanton", "RG165")
BOXES = PUBLIC + OWNER
# role: (method_openrouter.FARMSHARE key, the name the Sherlock job serves it under)
MODELS = {"teacher": ("fs-qwen3.5-27b", "Qwen/Qwen3.5-27B-FP8"), "student": ("fs-seg-2b", "seg-2b")}
ARMS = ("base", "block")
LOW_TEXT = 200          # characters of OCR text under which a page counts as carrying little text
LABEL_CHARS = 160       # of each label photo's OCR text
MAX_LABELS = 8          # label photos quoted per box
YEAR = re.compile(r"\b(1[7-9]\d\d|20[0-2]\d)\b")
CATALOGUE = {
    "CREST": "CIA records released through CREST (the CIA Records Search Tool), one microfilmed folder of "
             "declassified agency documents (folder 00170027)",
    "Lincoln": "Library of Congress, Abraham Lincoln Papers, General Correspondence, consecutive catalogue items in "
               "shelf order: manuscript letters and papers",
}
OCR_HEADING = "THE OCR TEXT OF EACH PAGE ("   # method_gemini.PROMPT's heading above the pages' text
HEADER = ("COLLECTION FACTS. What is known about the whole box these pages come from, from its catalogue or label "
          "photos and from a pass over all of its OCR text. They describe the box, not this window: take them as "
          "background, and decide each gap from the pages themselves.")


def _seg():
    """The bench modules, imported late: ``check`` runs on Sherlock with the standard library alone."""
    sys.path.insert(0, str(HERE))
    import data
    import method_local as L
    import method_openrouter as R
    import method_window as W
    import public_segmentation as P
    return data, L, R, W, P


def load(box, public_root):
    """A box as the bench loads it, with ``data.CACHE_DIR`` pointed at that box's cache (public boxes keep theirs
    under the public root, as public_segmentation.py requires)."""
    data, *_, P = _seg()
    if box in PUBLIC:
        data.CACHE_DIR = Path(public_root) / "cache"
        col, manifest = P.load(box.lower(), Path(public_root))
        return col, manifest
    data.CACHE_DIR = Path(os.environ.get("SEGBENCH_CACHE",
                                         Path.home() / "Library/Caches/ArchiveSuiteRehearsal/segbench"))
    return data.load(box, with_exif=False), None


def doc_lengths(labels):
    """Pages per document, label photos left out (they are not part of a document)."""
    out = []
    for lab in labels:
        if lab == "New":
            out.append(1)
        elif lab == "Cont" and out:
            out[-1] += 1
    return out


def _flat(text):
    return " ".join((text or "").split())


def length_line(lengths, where):
    c = Counter(min(n, 6) for n in lengths)
    share = lambda k: round(100 * c[k] / len(lengths))  # noqa: E731
    med = statistics.median(lengths)
    return (f"{where}: {len(lengths)} documents, median {med:g} page{'' if med == 1 else 's'}, mean "
            f"{statistics.mean(lengths):.1f}; {share(1)}% one page, {share(2)}% two, "
            f"{round(100 * sum(c[k] for k in (3, 4, 5)) / len(lengths))}% three to five, {share(6)}% six or more")


def facts(box, col, manifest, dev_lengths):
    """The box's facts, as a dict (for the record) and the block's text."""
    n = len(col.pages)
    texts = [col.text(i) or "" for i in range(n)]
    years = sorted(int(y) for t in texts for y in YEAR.findall(t) if 1700 <= int(y) <= 2026)
    low = sum(len(t.strip()) < LOW_TEXT for t in texts)
    f = {"pages": n, "years_found": len(years), "low_text_pages": low}
    lines = []
    if manifest is not None:
        items = len(manifest["source_documents"])
        f.update(source=CATALOGUE[box], catalogue_items=items)
        lines.append(f"- Source: {CATALOGUE[box]}. The catalogue lists {items} items for these {n} pages.")
    else:
        labels = [(col.pages[i].n, col.pages[i].label, _flat(texts[i])[:LABEL_CHARS])
                  for i in range(n) if col.pages[i].label in ("Box", "Folder")]
        quoted = [x for x in labels if x[2]][:MAX_LABELS]
        f.update(label_photos=len(labels), labels_quoted=[[p, k] for p, k, _ in quoted])
        said = "; ".join(f"{k.lower()} label (page {p}): \"{t}\"" for p, k, t in quoted) or "no label text read"
        lines.append(f"- Source: an archival box photographed page by page, {len(labels)} box and folder label "
                     f"photos among its {n} pages. What their OCR reads: {said}.")
    if len(years) >= 5:
        lo, hi = years[len(years) // 10], years[(9 * len(years)) // 10]
        decade = Counter(y // 10 * 10 for y in years).most_common(1)[0][0]
        f.update(era=[lo, hi], decade=decade)
        lines.append(f"- Era: the years in the box's text run mostly from {lo} to {hi}; the commonest decade is the "
                     f"{decade}s.")
    else:
        f.update(era=None)
        lines.append("- Era: too few years in the box's text to say.")
    lines.append(f"- Pages: {low} of the {n} pages ({round(100 * low / n)}%) carry little machine-readable text "
                 "(handwriting, photographs or blank sides).")
    if manifest is not None:
        per = n / f["catalogue_items"]
        f.update(pages_per_item=round(per, 2))
        lines.append(f"- Document length: the catalogue's items average {per:.1f} pages. An item can hold more than "
                     "one document (a letter and its enclosure, a memo and its routing slip).")
    else:
        f.update(dev_lengths=length_line(dev_lengths, "dev"))
        lines.append("- Document length, from the same owner's earlier boxes: "
                     + length_line(dev_lengths, "x").removeprefix("x: ") + ".")
    block = HEADER + "\n" + "\n".join(lines)
    return f, block


def all_facts(public_root):
    data, *_ = _seg()
    load("Stanton", public_root)  # points data.CACHE_DIR at the owner cache for the development boxes
    dev = [n for b in data.DEV for n in doc_lengths(data.load(b, with_exif=False).labels)]
    out = {}
    for box in BOXES:
        col, manifest = load(box, public_root)
        out[box] = facts(box, col, manifest, dev)
    return out


def request(col, a, b, block=None):
    """The window's request: the bench's own (method_local.request), and in the block arm the same prompt with the
    block set just above the OCR section's heading, so it is not read as page text."""
    _, L, *_ = _seg()
    prompt, thumbs, nums = L.request(col, a, b)
    if block is None:
        return prompt, thumbs, nums
    if prompt.count(OCR_HEADING) != 1:
        raise ValueError(f"{col.name} {nums}: the OCR section's heading is not unique in the prompt")
    return prompt.replace(OCR_HEADING, block + "\n\n" + OCR_HEADING, 1), thumbs, nums


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_new(path, blob):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "xb") as fh:  # never replace a frozen file
        fh.write(blob)


def baseline_keys(box, role, public_root):
    """The cache keys the earlier FarmShare rows were scored under, to prove the base arm unchanged."""
    _, _, R, *_ = _seg()
    key = MODELS[role][0]
    if box in PUBLIC:
        p = Path(public_root) / "packs" / f"{box.lower()}-{key}" / "windows.jsonl"
        return {tuple(w["window"]): w["cache_key"] for w in map(json.loads, p.read_text().splitlines())}
    return None  # owner boxes: checked against the response cache instead (R.cache(key).get)


SUPPORT_CODE = ("cluster_ocr.py", "cluster_seg.py", "train_seg.py")  # from institutional-compute/, beside the bench modules


def cmd_pack(a):
    data, L, R, W, P = _seg()
    out = Path(a.out)
    if out.exists():
        raise SystemExit(f"{out} exists; inspect it instead of overwriting")
    blocks = all_facts(a.public_root)
    windows = {role: [] for role in MODELS}
    boxes = {}
    for box in BOXES:
        col, _ = load(box, a.public_root)
        f, block = blocks[box]
        done = set()
        base_seen = {role: baseline_keys(box, role, a.public_root) for role in MODELS}
        spans = W.windows(len(col.pages))
        for lo, hi in spans:
            for arm in ARMS:
                prompt, thumbs, nums = request(col, lo, hi, block if arm == "block" else None)
                for n, t in zip(nums, thumbs):
                    if n not in done:
                        jpeg = R.image_jpeg(t, L.MAX_SIDE)
                        if box in PUBLIC:  # the bytes the node sends, not only the thumbnails the key hashes
                            for key, _ in MODELS.values():
                                old = Path(a.public_root) / "packs" / f"{box.lower()}-{key}" / "images" / box / f"{n}.jpg"
                                if old.read_bytes() != jpeg:
                                    raise SystemExit(f"{box} page {n}: image bytes differ from the scored {key} pack")
                        write_new(out / "images" / box / f"{n}.jpg", jpeg)
                        done.add(n)
                for role, (key, _) in MODELS.items():
                    k = R.cache_key(key, prompt, thumbs)
                    if arm == "base":
                        known = base_seen[role]
                        if known is not None and known.get(tuple(nums)) != k:
                            raise SystemExit(f"{box} {nums}: base request differs from the scored {key} pack")
                        if known is None and R.cache(key).get(k) is None:
                            raise SystemExit(f"{box} {nums}: base request is not in the {key} cache")
                    windows[role].append({"box": box, "window": nums, "arm": arm, "cache_key": k, "prompt": prompt})
        boxes[box] = {"pages": len(col.pages), "windows": len(spans), "facts": f, "block": block,
                      "block_sha256": hashlib.sha256(block.encode()).hexdigest()}
    for role, (key, served) in MODELS.items():
        d = out / role
        write_new(d / "windows.jsonl", "".join(json.dumps(w) + "\n" for w in windows[role]).encode())
        write_new(d / "pack.json", json.dumps({
            "key": key, "model": R.entry(key)[0], "side": L.MAX_SIDE, "max_tokens": R.MAX_TOKENS,
            "prompt_version": R.PROMPT_VERSION, "boxes": list(BOXES), "pages": sum(b["pages"] for b in boxes.values()),
            "windows": len(windows[role]), "made": time.strftime("%Y-%m-%dT%H:%M:%S")}, indent=1).encode())
        os.symlink("../images", d / "images")  # cluster_seg.py reads <pack>/images/<box>/<n>.jpg
    code = out / "support" / "segbench"
    code.mkdir(parents=True)
    for p in sorted(HERE.glob("*.py")):
        if not p.name.startswith("test_"):
            shutil.copy2(p, code / p.name)
    for name in SUPPORT_CODE:
        shutil.copy2(HERE / "institutional-compute" / name, code / name)
    jobs = out / "support" / "job"
    shutil.copytree(HERE / "sherlock" / "seg-context", jobs)
    shutil.copy2(HERE / "sherlock" / "sh.env", jobs / "sh.env")
    shutil.copytree(HERE / "sherlock" / "bin", jobs / "bin", symlinks=True)
    files = {str(p.relative_to(out)): sha(p) for p in sorted(out.rglob("*"))
             if p.is_file() and not p.is_symlink()}
    freeze = {"tag": TAG, "made": time.strftime("%Y-%m-%dT%H:%M:%S"), "boxes": boxes,
              "models": {r: {"key": k, "served": s} for r, (k, s) in MODELS.items()}, "arms": list(ARMS),
              "files": files}
    write_new(out / "freeze.json", (json.dumps(freeze, indent=1) + "\n").encode())
    print(f"{sum(len(v) for v in windows.values())} requests ({', '.join(f'{r} {len(v)}' for r, v in windows.items())}), "
          f"{len(files)} files -> {out}")


def check(root):
    """Every frozen file present and unchanged, and the two packs' windows paired base/block over the same spans."""
    root = Path(root)
    freeze = json.loads((root / "freeze.json").read_text())
    if freeze.get("tag") != TAG:
        raise SystemExit("not a W46.seg-context pack")
    bad = [rel for rel, h in freeze["files"].items() if not (root / rel).is_file() or sha(root / rel) != h]
    if bad:
        raise SystemExit(f"{len(bad)} frozen files missing or changed (first {bad[0]})")
    for role in freeze["models"]:
        ws = [json.loads(x) for x in (root / role / "windows.jsonl").read_text().splitlines()]
        pairs = Counter((w["box"], tuple(w["window"])) for w in ws)
        arms = Counter(w["arm"] for w in ws)
        if set(pairs.values()) != {2} or arms["base"] != arms["block"] or len({w["cache_key"] for w in ws}) != len(ws):
            raise SystemExit(f"{role}: windows are not one base and one block request per span")
        if sum(b["windows"] for b in freeze["boxes"].values()) != arms["base"]:
            raise SystemExit(f"{role}: window count differs from the freeze")
        if not (root / role / "images").is_dir():
            raise SystemExit(f"{role}: images link missing")
    print(f"pack ok: {len(freeze['files'])} files, {arms['base']} spans x {len(freeze['arms'])} arms x "
          f"{len(freeze['models'])} models")
    return freeze


def read_answers(path):
    out = []
    for line in Path(path).read_text().splitlines():
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            pass  # a line a killed job left half-written
    return out


def judges(pack, results, role):
    """One judge per arm, answering from the run's answers.jsonl through the pack's own cache keys."""
    _, L, R, W, _ = _seg()
    ws = {w["cache_key"]: w for w in map(json.loads, (Path(pack) / role / "windows.jsonl").read_text().splitlines())}
    got = {}
    for r in read_answers(Path(results) / role / "answers.jsonl"):
        w = ws.get(r["cache_key"])
        if w is None:
            raise SystemExit(f"{role}: an answer for a request this pack never made ({r['window']})")
        got[(w["arm"], w["box"], tuple(w["window"]))] = r
    out = {}
    for arm in ARMS:
        def judge(col, a, b, allow_call=False, arm=arm):
            nums = [col.pages[i].n for i in range(a, b)]
            r = got.get((arm, col.name, tuple(nums)))
            if r is None:
                return None
            if r["status"] != "ok":
                return L.neutral(nums)  # a window still unparsed after the retry votes 0.5, as everywhere
            return W.parse_answer(r["result"], nums)
        out[arm] = judge
    failed = Counter(k[0] for k, r in got.items() if r["status"] != "ok")
    return out, failed, len(got)


def decisions(answer, nums):
    """One window answer's gap decisions, {gap: decision}; None for an answer that does not parse."""
    _, _, _, W, _ = _seg()
    if isinstance(answer, dict):
        answer = answer.get("result")
    if not isinstance(answer, str):
        return None
    try:
        return {g: b["decision"] for g, b in W.parse_answer(answer, nums)["boundaries"].items()}
    except Exception:
        return None


def flips(pack, results, role, public_root):
    """Per box, how many gap votes the block changes, beside how many a plain rerun changes: the base arm's
    answer against the earlier FarmShare answer to the byte-identical request (a different vLLM build, GPU and
    perhaps weights). The rerun count is the noise floor a block effect has to clear."""
    data, _, R, _, _ = _seg()
    key = MODELS[role][0]
    ws = {w["cache_key"]: w for w in map(json.loads, (Path(pack) / role / "windows.jsonl").read_text().splitlines())}
    now = {}
    for r in read_answers(Path(results) / role / "answers.jsonl"):
        w = ws[r["cache_key"]]
        now[(w["box"], tuple(w["window"]), w["arm"])] = r
    earlier_public = data.ResponseCache(f"window-or-{key}")
    earlier_public.dir = Path(public_root) / "cache" / "responses" / f"window-or-{key}"
    out = {}
    for (box, win, arm), r in sorted(now.items()):
        if arm != "base" or (box, win, "block") not in now:
            continue
        nums = list(win)
        base = decisions(r, nums)
        block = decisions(now[(box, win, "block")], nums)
        earlier = decisions((earlier_public if box in PUBLIC else R.cache(key)).get(r["cache_key"]), nums)
        t = out.setdefault(box, {"votes": 0, "block_flips": 0, "rerun_votes": 0, "rerun_flips": 0, "unparsed": 0})
        if base is None or block is None:
            t["unparsed"] += 1
            continue
        t["votes"] += len(base)
        t["block_flips"] += sum(base[g] != block.get(g) for g in base)
        if earlier is not None:
            t["rerun_votes"] += len(base)
            t["rerun_flips"] += sum(base[g] != earlier.get(g) for g in base)
    return out


def cmd_score(a):
    from dataclasses import asdict
    from score import score_labels, derived
    data, L, R, W, P = _seg()
    freeze = check(a.pack)
    rows, missing, stability = [], [], {}
    for role in MODELS:
        stability[role] = flips(a.pack, a.results, role, a.public_root)
        js, failed, n = judges(a.pack, a.results, role)
        for box in BOXES:
            col, _ = load(box, a.public_root)
            for arm in ARMS:
                try:
                    pred = W.assemble(col, W.combine(col, js[arm]), box in OWNER)
                except RuntimeError as e:
                    missing.append(f"{role} {arm} {e}")
                    continue
                c = score_labels(col.labels, pred.labels)
                m = derived(c)
                rows.append({"model": role, "key": MODELS[role][0], "box": box, "arm": arm, "counts": asdict(c),
                             "pages_exact": m["pages_in_exact_doc"], "boundary_f1": m["boundary_f1"],
                             "false_splits": c.false_splits, "false_merges": c.false_merges})
        rows.append({"model": role, "failed_windows": dict(failed), "answers": n})
    if missing and not a.partial:
        raise SystemExit(f"{len(missing)} model-arm-box cells incomplete (first: {missing[0]}); --partial to score "
                         "what came back")
    out = {"tag": TAG, "boxes": {b: {k: v for k, v in freeze["boxes"][b].items() if k != "block"} for b in BOXES},
           "rows": rows, "vote_flips": stability, "incomplete": missing}
    (RESULTS / "seg-context.json").write_text(json.dumps(out, indent=1) + "\n")
    print(json.dumps([r for r in rows if "arm" in r], indent=1))


def cmd_facts(a):
    for box, (f, block) in all_facts(a.public_root).items():
        print(f"== {box}  {json.dumps(f)}\n{block}\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("facts"); p.add_argument("--public-root", required=True)
    p = sub.add_parser("pack"); p.add_argument("--public-root", required=True); p.add_argument("--out", required=True)
    p = sub.add_parser("check"); p.add_argument("--root", required=True)
    p = sub.add_parser("score"); p.add_argument("--public-root", required=True); p.add_argument("--pack", required=True)
    p.add_argument("--results", required=True); p.add_argument("--partial", action="store_true")
    a = ap.parse_args()
    if a.cmd == "check":
        check(a.root)
    else:
        {"facts": cmd_facts, "pack": cmd_pack, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    main()
