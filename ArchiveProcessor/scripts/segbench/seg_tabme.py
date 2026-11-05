#!/usr/bin/env python3
"""W46.seg-tabme (A-segmentation test 5, arm a): is the students' 79% the material or the model?

The trained Qwen3.5 2B and 4B students and the Qwen3.5 27B teacher over TABME++'s test split, one stream of its 6,237
unique pages (2,238 complete documents, 6,236 gaps: A04's decision set), against A05 Table 4 (fine-tuned Mistral-7B
page F1 0.987, doc F1 0.967; encoders 0.78-0.83 page F1) and A04 Table 4 (zero-shot text windows, K = 7: Gemini 0.863,
Claude Haiku 0.782, GPT-5.4-mini 0.739, boundary F1 of the cut class). The paid Gemini arms are W46.seg-tabme-paid.

  seg_tabme.py stage --raw DIR --root DIR      # the parquet test split -> page images, OCR text, stream.json (Mac)
  seg_tabme.py plan  --root DIR                # the arms and request counts (no writes)
  seg_tabme.py pack  --root DIR --out DIR      # the frozen pack for Sherlock (Mac only)
  seg_tabme.py check --root DIR                # the pack's hashes (Mac or Sherlock; stdlib only)
  seg_tabme.py score --root DIR --pack DIR --results DIR [--partial]   # -> segbench-results/seg-tabme.json

FIXED BEFORE ANY ANSWER:
- The source is bevaya/TABMEpp at revision REVISION, split test (both parquet shards). The stream is the documents in
  the shards' row order (each document's rows are contiguous there) with each document's pages sorted by pg_id (the
  shards shuffle pages within a document). A04 does not say how it ordered the pages; its 6,236 decisions are this set,
  but which documents sit side by side may differ. ``stage`` refuses unless 6,237 pages and 2,238 documents result.
- Page text is the dataset's own Microsoft OCR (``lines_data`` in order, one line each), the OCR A04 and A05 used, not
  Apple Vision; the page image is the dataset's own JPEG (764 x 1000 grey), which ``image_jpeg`` keeps at 1,000 px.
- Arms: K = 7 windows stepping 3 pages (method_window.windows, as every student and teacher row was scored) with the
  bench's request (method_local.request, prompt o1) for all three models, images and text (``it``) — the students' own
  input; and for the teacher alone the same windows with the OCR text only (``t``, seg_window_modality.text_only),
  the zero-shot text-only K = 7 setting A04 measured. No arm is chosen on the answers.
- Scoring: a window's votes combine as method_window.combine; the set has no label photos, so the truth's (none) are
  used and a page the model calls a box or folder photo is reported, not scored. Figures: boundary F1 (A04's metric),
  pages in an exact document (our headline), A05's page F1 (each page's is-first-page label, page 1 included) and doc
  F1, kappa, PQ, MNDD; the all-new and no-boundary baselines beside them. Boundary F1 is A05's page F1 without the
  forced page 1; A05 scores 5,000 folders of about 30 pages (documents reused across them), so each of its folders
  has a free first page and other neighbours: its figures are a reference, not a paired comparison. A window still
  unparsed after the retry votes 0.5 on its gaps, which the combine rule reads as new (as everywhere on the bench). Intervals: a 2,000-draw bootstrap over the
  2,238 documents (seed 46), paired between arms on the same draws.
No money, no calls. Only public pages go into the pack.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import sys
import time

HERE = Path(__file__).resolve().parent
RESULTS = HERE.parents[1] / "segbench-results"
TAG = "W46.seg-tabme"
PACK_NAME = "seg-tabme-20261105"
BOX = "TABME"
REPO_ID = "bevaya/TABMEpp"
REVISION = "46747c21eae9d2b0d138554aedf4af4980520711"
SHARDS = ("data/test-00000-of-00002.parquet", "data/test-00001-of-00002.parquet")
PAGES, DOCS = 6237, 2238
# role: (method_openrouter.FARMSHARE key, the name the Sherlock job serves it under)
MODELS = {"2b": ("fs-seg-2b", "seg-2b"), "4b": ("fs-seg-4b", "seg-4b"),
          "teacher": ("fs-qwen3.5-27b", "Qwen/Qwen3.5-27B-FP8")}
ARMS = {"2b": ("it",), "4b": ("it",), "teacher": ("it", "t")}   # role -> modalities; one pack folder each
DRAWS, SEED = 2000, 46


def _seg():
    sys.path.insert(0, str(HERE))
    import data
    import method_local as L
    import method_openrouter as R
    import method_window as W
    import seg_window_modality as SWM
    return data, L, R, W, SWM


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_new(path, blob):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "xb") as fh:  # never replace a frozen file
        fh.write(blob)


# --- the stream -----------------------------------------------------------------------------------

def ocr_text(raw):
    """The page's Microsoft OCR as text: its lines in the order given, one a line."""
    return "\n".join(str(x.get("Word", "")).strip() for x in json.loads(raw).get("lines_data", [])
                     if str(x.get("Word", "")).strip())


def order(rows):
    """[(doc_id, pg_id, row index)] in stream order: documents as the shards give them, pages by pg_id."""
    docs, seen = {}, []
    for i, (d, p) in enumerate(rows):
        if d not in docs:
            docs[d] = []
            seen.append(d)
        elif seen[-1] != d:
            raise SystemExit(f"document {d} is not contiguous in the shards")
        docs[d].append((p, i))
    out = []
    for d in seen:
        pgs = sorted(docs[d])
        if [p for p, _ in pgs] != list(range(pgs[0][0], pgs[0][0] + len(pgs))):
            raise SystemExit(f"document {d}: pages {[p for p, _ in pgs]} are not one run")
        out += [(d, p, i) for p, i in pgs]
    return out


def cmd_stage(a):
    import pyarrow.parquet as pq
    raw, root = Path(a.raw), Path(a.root)
    if root.exists():
        raise SystemExit(f"{root} exists; inspect it instead of overwriting")
    tables = [pq.read_table(raw / s) for s in SHARDS]
    rows = [(d, p) for t in tables for d, p in zip(t["doc_id"].to_pylist(), t["pg_id"].to_pylist())]
    seq = order(rows)
    if len(seq) != PAGES or len({d for d, _, _ in seq}) != DOCS:
        raise SystemExit(f"{len(seq)} pages in {len({d for d, _, _ in seq})} documents, expected {PAGES} in {DOCS}")
    flat = [r for t in tables for r in t.select(["img", "ocr"]).to_pylist()]
    pages = []
    for n, (d, p, i) in enumerate(seq, 1):
        img, text = flat[i]["img"], ocr_text(flat[i]["ocr"])
        write_new(root / "pages" / f"{n}.jpg", img)
        # The bench's thumbnail cache, filled with the original so sips never resamples it (data.thumbnail).
        thumb = root / "cache" / "thumbs" / "1600" / BOX / f"{n}.jpg"
        thumb.parent.mkdir(parents=True, exist_ok=True)
        os.link(root / "pages" / f"{n}.jpg", thumb)
        write_new(root / "cache" / "ocr" / BOX / f"{n}.txt", text.encode())
        new = n == 1 or seq[n - 2][0] != d
        pages.append({"n": n, "doc_id": d, "pg_id": p, "label": "New" if new else "Cont",
                      "sha256": hashlib.sha256(img).hexdigest(), "chars": len(text)})
    stream = {"tag": TAG, "repo": REPO_ID, "revision": REVISION, "shards": {s: sha(raw / s) for s in SHARDS},
              "pages": pages}
    write_new(root / "stream.json", (json.dumps(stream, indent=0) + "\n").encode())
    print(json.dumps(summary(stream), indent=1))


def summary(stream):
    """The facts about the stream that go into git (the pages themselves stay out)."""
    ps = stream["pages"]
    key = "".join(f"{p['doc_id']}\t{p['pg_id']}\t{p['label']}\t{p['sha256']}\n" for p in ps).encode()
    lengths = Counter()
    for p in ps:
        lengths[p["doc_id"]] += 1
    return {"repo": stream["repo"], "revision": stream["revision"], "shards": stream["shards"], "pages": len(ps),
            "documents": len(lengths), "gaps": len(ps) - 1, "boundaries": len(lengths) - 1,
            "single_page_documents": sum(v == 1 for v in lengths.values()),
            "blank_ocr_pages": sum(p["chars"] == 0 for p in ps), "stream_sha256": hashlib.sha256(key).hexdigest()}


def load(root):
    """The stream as a bench Collection, with data.CACHE_DIR pointed at its own cache."""
    data, *_ = _seg()
    root = Path(root)
    data.CACHE_DIR = root / "cache"
    stream = json.loads((root / "stream.json").read_text())
    col = data.Collection(BOX, root, [data.Page(p["n"], p["label"], root / "pages" / f"{p['n']}.jpg")
                                      for p in stream["pages"]])
    return col, stream


# --- the pack -------------------------------------------------------------------------------------

def request(col, a, b, modality):
    _, L, R, _, SWM = _seg()
    prompt, thumbs, nums = L.request(col, a, b)
    images = list(nums)
    if modality == "t":
        prompt, images = SWM.text_only(prompt, nums), []
    return prompt, thumbs, nums, images


def packs():
    return [(role, m) for role, ms in ARMS.items() for m in ms]


def cmd_plan(a):
    _, _, _, W, _ = _seg()
    col, _ = load(a.root)
    n = len(W.windows(len(col.pages)))
    for role, m in packs():
        print(f"{role:8} {m:3} {n} windows")
    print(f"{n * len(packs())} requests")


def cmd_pack(a):
    data, L, R, W, SWM = _seg()
    out = Path(a.out)
    if out.exists():
        raise SystemExit(f"{out} exists; inspect it instead of overwriting")
    col, stream = load(a.root)
    for i, p in enumerate(col.pages):   # the staged pages and text are those stream.json froze
        if sha(p.path) != stream["pages"][i]["sha256"] or not data.ocr_cache_path(BOX, p.n).exists():
            raise SystemExit(f"page {p.n}: image changed or text missing")
    spans = W.windows(len(col.pages))
    if {i for lo, hi in spans for i in range(lo, hi - 1)} != set(range(len(col.pages) - 1)):
        raise SystemExit("a gap no window judges")
    done, frozen = set(), {}
    for role, m in packs():
        key = MODELS[role][0]
        ws, seen = [], set()
        for lo, hi in spans:
            prompt, thumbs, nums, images = request(col, lo, hi, m)
            for num, t in zip(nums, thumbs):
                if num not in done:
                    write_new(out / "images" / BOX / f"{num}.jpg", R.image_jpeg(t, L.MAX_SIDE))
                    done.add(num)
            k = R.cache_key(key, prompt, thumbs if images else [])
            if k in seen:
                raise SystemExit(f"{role}-{m} {nums}: one cache key twice")
            seen.add(k)
            ws.append({"box": BOX, "window": nums, "arms": [m], "cache_key": k, "prompt": prompt, "images": images,
                       "max_tokens": R.MAX_TOKENS})
        d = out / f"{role}-{m}"
        write_new(d / "windows.jsonl", "".join(json.dumps(w) + "\n" for w in ws).encode())
        meta = {"key": key, "model": R.entry(key)[0], "side": L.MAX_SIDE, "max_tokens": R.MAX_TOKENS,
                "prompt_version": R.PROMPT_VERSION, "boxes": [BOX], "pages": len(col.pages), "windows": len(ws),
                "modality": m, "max_images": max(len(w["images"]) for w in ws), "public": True,
                "max_prompt_chars": max(len(w["prompt"]) for w in ws),
                "made": time.strftime("%Y-%m-%dT%H:%M:%S")}
        write_new(d / "pack.json", json.dumps(meta, indent=1).encode())
        os.symlink("../images", d / "images")  # cluster_seg.py reads <pack>/images/<box>/<n>.jpg
        frozen[f"{role}-{m}"] = {"role": role, "modality": m, "windows": len(ws), "max_images": meta["max_images"],
                                 "max_prompt_chars": meta["max_prompt_chars"]}
    write_new(out / "stream.json", (Path(a.root) / "stream.json").read_bytes())
    code = out / "support" / "segbench"
    code.mkdir(parents=True)
    for p in sorted(HERE.glob("*.py")):
        if not p.name.startswith("test_"):
            shutil.copy2(p, code / p.name)
    for name in ("cluster_ocr.py", "cluster_seg.py", "train_seg.py"):
        shutil.copy2(HERE / "institutional-compute" / name, code / name)
    jobs = out / "support" / "job"
    shutil.copytree(HERE / "sherlock" / "seg-tabme", jobs)
    shutil.copy2(HERE / "sherlock" / "sh.env", jobs / "sh.env")
    shutil.copytree(HERE / "sherlock" / "bin", jobs / "bin", symlinks=True)
    files = {str(p.relative_to(out)): sha(p) for p in sorted(out.rglob("*")) if p.is_file() and not p.is_symlink()}
    freeze = {"tag": TAG, "made": time.strftime("%Y-%m-%dT%H:%M:%S"), "stream": summary(stream), "windows": len(spans),
              "packs": frozen, "models": {r: {"key": k, "served": s} for r, (k, s) in MODELS.items()}, "files": files}
    write_new(out / "freeze.json", (json.dumps(freeze, indent=1) + "\n").encode())
    print(f"{sum(p['windows'] for p in frozen.values())} requests "
          f"({', '.join(f'{k} {v['windows']}' for k, v in frozen.items())}), {len(files)} files -> {out}")


def check(root):
    """Every frozen file present and unchanged; each pack's requests unique and as many as frozen."""
    root = Path(root)
    freeze = json.loads((root / "freeze.json").read_text())
    if freeze.get("tag") != TAG:
        raise SystemExit("not a W46.seg-tabme pack")
    bad = [rel for rel, h in freeze["files"].items() if not (root / rel).is_file() or sha(root / rel) != h]
    if bad:
        raise SystemExit(f"{len(bad)} frozen files missing or changed (first {bad[0]})")
    for name, p in freeze["packs"].items():
        ws = [json.loads(x) for x in (root / name / "windows.jsonl").read_text().splitlines()]
        if len({w["cache_key"] for w in ws}) != len(ws) or len(ws) != p["windows"] or p["windows"] != freeze["windows"]:
            raise SystemExit(f"{name}: requests are not unique or not as frozen")
        if not (root / name / "images").is_dir():
            raise SystemExit(f"{name}: images link missing")
    print(f"pack ok: {len(freeze['files'])} files, " +
          ", ".join(f"{k} {v['windows']}" for k, v in freeze["packs"].items()))
    return freeze


# --- scoring --------------------------------------------------------------------------------------

def answers(pack, results, name):
    """{window tuple: answer} for one pack folder, through the pack's own cache keys; and how many failed."""
    import seg_context as SC
    ws = {w["cache_key"]: w for w in map(json.loads, (Path(pack) / name / "windows.jsonl").read_text().splitlines())}
    got = {}
    path = Path(results) / name / "answers.jsonl"
    for r in (SC.read_answers(path) if path.exists() else []):
        w = ws.get(r["cache_key"])
        if w is None:
            raise SystemExit(f"{name}: an answer for a request this pack never made ({r.get('window')})")
        got[tuple(w["window"])] = r
    return got, sum(r["status"] != "ok" for r in got.values())


def judge_from(got):
    _, L, _, W, _ = _seg()

    def judge(col, a, b):
        nums = [col.pages[i].n for i in range(a, b)]
        r = got.get(tuple(nums))
        if r is None:
            return None
        if r["status"] != "ok":
            return L.neutral(nums)  # a window still unparsed after the retry votes 0.5, as everywhere
        try:
            return W.parse_answer(r["result"], nums)
        except W.ParseError:
            return L.neutral(nums)
    return judge


def per_doc(truth, pred):
    """Per truth document: pages, exact, and the boundary counts of its internal gaps and the gap before it — the
    additive units the bootstrap resamples. Page-level (A05) and document-level counts ride along."""
    starts = [i for i, t in enumerate(truth) if t == "New"]
    ends = starts[1:] + [len(truth)]
    pstarts = {i for i, t in enumerate(pred) if t == "New"}
    pdocs = set()
    for s, e in zip(sorted(pstarts), sorted(pstarts)[1:] + [len(pred)]):
        pdocs.add((s, e))
    out = []
    for s, e in zip(starts, ends):
        tp = fs = fm = 0
        for i in range(max(s, 1), e):          # the gap before page i
            t, p = truth[i] == "New", i in pstarts
            tp += t and p
            fs += p and not t
            fm += t and not p
        out.append({"pages": e - s, "exact": (s, e) in pdocs, "tp": tp, "fs": fs, "fm": fm,
                    "pred_firsts": sum(i in pstarts for i in range(s, e))})
    return out


def metrics(rows):
    pages = sum(r["pages"] for r in rows)
    tp, fs, fm = (sum(r[k] for r in rows) for k in ("tp", "fs", "fm"))
    docs, exact, firsts = len(rows), sum(r["exact"] for r in rows), sum(r["pred_firsts"] for r in rows)
    f1 = 2 * tp / (2 * tp + fs + fm) if tp + fs + fm else 1.0
    # A05's page F1: every page labelled first-of-document or not, page 1 counted (always right: forced).
    ptp = tp + 1
    page_f1 = 2 * ptp / (2 * ptp + fs + fm)
    doc_p, doc_r = exact / firsts if firsts else 0.0, exact / docs
    doc_f1 = 2 * doc_p * doc_r / (doc_p + doc_r) if doc_p + doc_r else 0.0
    return {"pages": pages, "documents": docs, "boundary_f1": f1, "pages_exact": sum(r["pages"] for r in rows
            if r["exact"]) / pages, "page_f1": page_f1, "doc_f1": doc_f1, "false_splits": fs, "false_merges": fm}


def bootstrap(arms, draws=DRAWS, seed=SEED):
    """95% intervals over documents for each arm, and paired differences against the first arm of each pair."""
    rng = random.Random(seed)
    names = list(arms)
    n = len(next(iter(arms.values())))
    fields = ("boundary_f1", "pages_exact", "page_f1", "doc_f1")
    samples = {k: {f: [] for f in fields} for k in names}
    for _ in range(draws):
        idx = [rng.randrange(n) for _ in range(n)]
        for k in names:
            m = metrics([arms[k][i] for i in idx])
            for f in samples[k]:
                samples[k][f].append(m[f])

    def ci(xs):
        xs = sorted(xs)
        return [xs[int(0.025 * len(xs))], xs[int(0.975 * len(xs)) - 1]]
    out = {k: {f: ci(v) for f, v in s.items()} for k, s in samples.items()}
    pairs = {}
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            pairs[f"{b} - {a}"] = {f: ci([y - x for x, y in zip(samples[a][f], samples[b][f])])
                                   for f in fields}
    return out, pairs


def cmd_score(a):
    from dataclasses import asdict
    from score import score_labels, derived
    _, _, _, W, SWM = _seg()
    freeze = check(a.pack)
    col, stream = load(a.root)
    if summary(stream)["stream_sha256"] != freeze["stream"]["stream_sha256"]:
        raise SystemExit("the staged stream is not the one the pack froze")
    truth = [p.label for p in col.pages]
    spans = W.windows(len(truth))
    arms, rows, missing, runs = {}, [], [], []
    base = {"all-new": ["New"] * len(truth), "no-boundaries": ["New"] + ["Cont"] * (len(truth) - 1)}
    for name, labels in base.items():
        arms[name] = per_doc(truth, labels)
    for name, p in freeze["packs"].items():
        got, failed = answers(a.pack, a.results, name)
        runs.append({"pack": name, "answers": len(got), "failed": failed})
        try:
            comb = SWM.combine_units(col, spans, judge_from(got))
        except RuntimeError as e:
            missing.append(f"{name}: {e} ({len(got)} of {p['windows']} answered)")
            continue
        pred = W.assemble(col, comb, True).labels
        c = score_labels(col.labels, pred)
        d = derived(c)
        arms[name] = per_doc(truth, pred)
        rows.append({"arm": name, "role": p["role"], "modality": p["modality"], "failed_windows": failed,
                     "photo_calls": sum(x is not None for x in comb["photo"]),
                     **metrics(arms[name]), "kappa": d["kappa"], "pq": d["pq"], "mndd": d["mndd"],
                     "pk": d["pk"], "windowdiff": d["windowdiff"], "counts": asdict(c)})
    if missing and not a.partial:
        raise SystemExit(f"{len(missing)} arms incomplete (first: {missing[0]}); --partial to score what came back")
    for name in base:
        rows.append({"arm": name, "role": "baseline", **metrics(arms[name])})
    intervals, paired = bootstrap(arms)
    out = {"tag": TAG, "stream": freeze["stream"], "windows": len(spans), "rows": rows, "intervals": intervals,
           "paired": paired, "runs": runs, "incomplete": missing, "bootstrap": {"draws": DRAWS, "seed": SEED,
                                                                                "unit": "truth document"}}
    dest = Path(a.out) if a.out else RESULTS / "seg-tabme.json"
    dest.write_text(json.dumps(out, indent=1) + "\n")
    for r in rows:
        print(f"{r['arm']:14} boundary F1 {r['boundary_f1']:.3f}  pages exact {r['pages_exact']:.3f}  "
              f"page F1 {r['page_f1']:.3f}  doc F1 {r['doc_f1']:.3f}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("stage"); p.add_argument("--raw", required=True); p.add_argument("--root", required=True)
    p = sub.add_parser("plan"); p.add_argument("--root", required=True)
    p = sub.add_parser("pack"); p.add_argument("--root", required=True); p.add_argument("--out", required=True)
    p = sub.add_parser("check"); p.add_argument("--root", required=True)
    p = sub.add_parser("score"); p.add_argument("--root", required=True); p.add_argument("--pack", required=True)
    p.add_argument("--results", required=True); p.add_argument("--partial", action="store_true")
    p.add_argument("--out", help="where the JSON goes (default segbench-results/seg-tabme.json)")
    a = ap.parse_args()
    if a.cmd == "check":
        check(a.root)
    else:
        {"stage": cmd_stage, "plan": cmd_plan, "pack": cmd_pack, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    main()
