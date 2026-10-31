#!/usr/bin/env python3
"""W46.kit-gate: the training kit's held-out gate, measured on the bench's cached answers.

    PY=$(torch-env.sh)
    $PY kit_gate.py gaps owner                       # the five owner boxes -> cache kit-gate/gaps-owner.json
    $PY kit_gate.py gaps public --root DIR           # Lincoln and CREST    -> cache kit-gate/gaps-public.json
    $PY kit_gate.py dates --root DIR                 # the dating students' answers on the 300 (Long term storage)
    $PY kit_gate.py report                           # -> segbench-results/seg-kit-gate.md + .json

NO CALLS, NO MONEY. Every answer is read from its response cache with ``allow_call=False``, as rescore.py reads
them, and the process refuses the network. Numbers only reach the committed files.

THE TEACHER SPLIT (gap audit item 20). Each student's wrong gaps, split into the gaps where the teacher (Qwen3.5 27B,
`seg-teacher.json`) made the same wrong call and the gaps where it was right. A student error the teacher shares is
one the training could not have removed (the teacher's reply was the target); one it does not share is the student's
own. Document gaps only, with the truth's photo labels, as `ensemble.py` scores them.

THE HELD-OUT SET SIZE (H test 6). How many held-out gaps a gate needs before its interval separates a 3-point
difference between two models. Documents of the five owner boxes are resampled with replacement (a document carries
its own gaps, its pages, and whether each model put it exactly), paired, until the draw holds N gaps; 4,000 draws a
size. The figure is the 95% interval's half-width of the paired difference in pages exact and in review load (gaps
flagged at confidence 0.85, per 100 pages). The rerun noise the audit measured (1.4-3.2 points a box, SEG-10) is a
separate floor: a held-out set this size bounds the sampling error, not the model's own run-to-run wobble.

THE DATING SPLIT. The dating students (W41.date-model) were trained on the owner's tags and dated public
documents, not on a teacher's replies, so no teacher error can be shared; the nearest question is whether their
wrong years on the 131 documents whose year is not in the text are the ones Gemini also gets wrong.
"""
from __future__ import annotations

import json
import os
import random
import socket
import sys
from pathlib import Path

import data

RESULTS = data.HERE.parent.parent / "segbench-results"
OUT_MD = RESULTS / "seg-kit-gate.md"
OUT_JSON = RESULTS / "seg-kit-gate.json"
MANIFEST = RESULTS / "seg-kit-manifest-shipped.json"
CACHE = Path(os.environ.get("ARCHIVE_BENCH_CACHE", Path.home() / "Library/Caches/ArchiveSuiteRehearsal")) / "kit-gate"

TEACHER = "fs-qwen3.5-27b"
STUDENTS = ("fs-seg-2b", "fs-seg-4b", "fs-seg-date-2b")
BASE = "fs-qwen3.5-4b"           # the untrained 4B: development boxes only
KEYS = (TEACHER,) + STUDENTS + (BASE,)
LEVEL = 0.85                      # seg-students.md's flag level
SIZES = (100, 300, 1000)
DRAWS = 4000
SEED = 46
TARGET = 3.0                      # points: the difference a gate must separate (H test 6)
PAIRS = (("fs-seg-2b", "fs-seg-4b"), ("fs-seg-2b", TEACHER))
NAMES = {TEACHER: "Qwen3.5 27B, the teacher", "fs-seg-2b": "Qwen3.5 2B, fine-tuned (the shipped build's source)",
         "fs-seg-4b": "Qwen3.5 4B, fine-tuned", "fs-seg-date-2b": "Qwen3.5 2B, joint segmentation and dating",
         BASE: "Qwen3.5 4B, untrained"}
SHORT = {TEACHER: "27B teacher", "fs-seg-2b": "2B", "fs-seg-4b": "4B", "fs-seg-date-2b": "joint 2B", BASE: "base 4B"}


def no_network() -> None:
    def refuse(*a, **k):
        raise RuntimeError("kit_gate.py makes no calls")
    socket.socket.connect = refuse  # type: ignore[assignment]


# --- per-gap records --------------------------------------------------------------------------------

def box_record(col) -> dict:
    """Truth and each model's (decision, confidence) per document gap, and the documents that own them."""
    import method_openrouter as R
    import method_window as W
    from score import PHOTO, segment_ids
    labels = col.labels
    ids = segment_ids(labels)
    gaps = [i for i in range(len(labels) - 1) if labels[i] not in PHOTO and labels[i + 1] not in PHOTO]
    rec = {"box": col.name, "pages": len(labels), "labels": labels,
           "gaps": [{"i": i, "truth": "new" if ids[i] != ids[i + 1] else "continue"} for i in gaps], "models": {}}
    for key in KEYS:
        try:
            pred = W.assemble(col, W.combine(col, R.judge(key)), True)
        except RuntimeError as e:
            if "makes no calls" in str(e):
                raise
            continue
        rec["models"][key] = {"labels": pred.labels,
                              "gaps": [[pred.boundaries[g["i"]]["decision"], float(pred.boundaries[g["i"]]["confidence"])]
                                       for g in rec["gaps"]]}
    return rec


def cmd_gaps(which: str, root: str | None) -> None:
    if which == "public":
        data.CACHE_DIR = Path(root) / "cache"
    no_network()
    boxes = []
    if which == "owner":
        for name in data.COLLECTIONS:
            r = box_record(data.load(name))
            r["split"] = "test" if name in data.TEST else "dev"
            boxes.append(r)
    else:
        import public_segmentation as P
        for b in ("lincoln", "crest"):
            col, _ = P.load(b, Path(root))
            r = box_record(col)
            r["split"] = "public"
            boxes.append(r)
    CACHE.mkdir(parents=True, exist_ok=True)
    out = CACHE / f"gaps-{which}.json"
    out.write_text(json.dumps({"boxes": boxes}))
    for r in boxes:
        print(r["box"], r["split"], len(r["gaps"]), "gaps;", ", ".join(r["models"]))
    print("wrote", out)


# --- documents: what a resample draws ---------------------------------------------------------------

def documents(rec: dict) -> list[dict]:
    """The truth's documents (photo pages left out, as score.py leaves them), each with the gaps it owns (the gap
    before each of its pages after the first page of a stream) and, per model, whether it is exact, its wrong gaps
    and its flagged gaps."""
    from score import PHOTO, segment_ids
    labels = rec["labels"]
    tid = segment_ids(labels)
    gap_at = {g["i"]: k for k, g in enumerate(rec["gaps"])}
    docs: dict[int, dict] = {}
    for p, t in enumerate(labels):
        if t in PHOTO:
            continue
        d = docs.setdefault(tid[p], {"pages": [], "gaps": []})
        d["pages"].append(p)
        if p - 1 in gap_at:
            d["gaps"].append(gap_at[p - 1])
    out = []
    for d in docs.values():
        row = {"pages": len(d["pages"]), "gaps": len(d["gaps"]), "m": {}}
        for key, m in rec["models"].items():
            pid = segment_ids(m["labels"])
            pset = frozenset(d["pages"])
            seg = frozenset(q for q in range(len(labels)) if pid[q] == pid[d["pages"][0]])
            wrong = sum(m["gaps"][k][0] != rec["gaps"][k]["truth"] for k in d["gaps"])
            flagged = sum(m["gaps"][k][1] <= LEVEL for k in d["gaps"])
            row["m"][key] = (int(seg == pset), wrong, flagged)
        out.append(row)
    return out


def interval(xs: list[float]) -> tuple[float, float]:
    xs = sorted(xs)
    return xs[int(0.025 * len(xs))], xs[int(0.975 * len(xs)) - 1]


def bootstrap(docs: list[dict], a: str, b: str, n_gaps: int, rng: random.Random) -> dict:
    """Paired document bootstrap to n_gaps gaps: the 95% interval of b minus a in pages exact, gap accuracy and
    flags per 100 pages."""
    pool = [d for d in docs if a in d["m"] and b in d["m"]]
    diffs = {"pages exact": [], "gap accuracy": [], "flagged per 100 pages": []}
    for _ in range(DRAWS):
        g = pages = 0
        ex = {a: 0, b: 0}; wr = {a: 0, b: 0}; fl = {a: 0, b: 0}
        while g < n_gaps:
            d = pool[rng.randrange(len(pool))]
            g += d["gaps"]; pages += d["pages"]
            for k in (a, b):
                e, w, f = d["m"][k]
                ex[k] += e * d["pages"]; wr[k] += w; fl[k] += f
        diffs["pages exact"].append(100 * (ex[b] - ex[a]) / pages)
        diffs["gap accuracy"].append(100 * (wr[a] - wr[b]) / g)
        diffs["flagged per 100 pages"].append(100 * (fl[b] - fl[a]) / pages)
    out = {}
    for k, xs in diffs.items():
        lo, hi = interval(xs)
        out[k] = {"lo": round(lo, 2), "hi": round(hi, 2), "half": round((hi - lo) / 2, 2)}
    return out


def needed(half_at: dict[int, float]) -> int:
    """The smallest held-out size whose half-width is at most TARGET, from the measured sizes by 1/sqrt(n)."""
    n, h = max(half_at.items())
    return int(round(n * (h / TARGET) ** 2))


# --- the teacher split ------------------------------------------------------------------------------

def teacher_split(boxes: list[dict]) -> dict:
    out = {}
    for rec in boxes:
        if TEACHER not in rec["models"]:
            continue
        t = rec["models"][TEACHER]["gaps"]
        for s in STUDENTS:
            if s not in rec["models"]:
                continue
            m = rec["models"][s]["gaps"]
            row = {"gaps": len(rec["gaps"]), "student wrong": 0, "teacher wrong the same way": 0,
                   "teacher right": 0, "teacher wrong, student right": 0}
            for k, g in enumerate(rec["gaps"]):
                sw, tw = m[k][0] != g["truth"], t[k][0] != g["truth"]
                row["student wrong"] += sw
                row["teacher wrong the same way"] += sw and tw
                row["teacher right"] += sw and not tw
                row["teacher wrong, student right"] += tw and not sw
            out.setdefault(s, {})[rec["box"]] = {"split": rec["split"], **row}
    return out


# --- the dating split -------------------------------------------------------------------------------

DATE_LABELS = ("fs-date-2b-nothink", "fs-date-4b-nothink", "fs-seg-date-2b-nothink", "mlx-date-2b-8bit-nothink")


def cmd_dates(root: str) -> None:
    """Each dating student's year on the 131, beside Gemini's (the app's default tagger), from the answer caches:
    Gemini's in the bench cache, the students' in the Long term storage copy of the FarmShare run."""
    no_network()
    import date_tagging as D
    docs = [json.loads(l) for l in open(os.path.join(D.CACHE, "sample.jsonl"), encoding="utf-8")]
    gem_cache = D.CACHE

    def year(path):
        if not os.path.exists(path):
            return None, False
        y, _, _, _ = D.app_parse(json.load(open(path)))
        return (int(y) if y and len(str(y)) == 4 and str(y).isdigit() else None), True

    rows = []
    for d in docs:
        if d["class"] == "decade" or d["year_in_text"] or not d["truth"].get("year"):
            continue
        D.CACHE = gem_cache
        gy, ok = year(D.answer_path(d["prompt"]))
        r = {"truth": d["truth"]["year"], "gemini": gy if ok else "missing"}
        D.CACHE = root
        for lab in DATE_LABELS:
            y, ok = year(D.answer_path(d["prompt"], lab))
            r[lab] = y if ok else "missing"
        rows.append(r)
    D.CACHE = gem_cache
    out = {"documents": len(rows), "gemini right": sum(r["gemini"] == r["truth"] for r in rows), "students": {}}
    for lab in DATE_LABELS:
        have = [r for r in rows if r[lab] != "missing" and r["gemini"] != "missing"]
        wrong = [r for r in have if r[lab] != r["truth"]]
        out["students"][lab] = {
            "answered": len(have), "right": len(have) - len(wrong), "wrong": len(wrong),
            "gemini wrong too": sum(r["gemini"] != r["truth"] for r in wrong),
            "gemini the same wrong year": sum(r["gemini"] == r[lab] for r in wrong),
            "gemini right": sum(r["gemini"] == r["truth"] for r in wrong),
            "student right, gemini wrong": sum(r[lab] == r["truth"] and r["gemini"] != r["truth"] for r in have)}
    CACHE.mkdir(parents=True, exist_ok=True)
    (CACHE / "dates.json").write_text(json.dumps(out, indent=1))
    print(json.dumps(out, indent=1))


# --- the report -------------------------------------------------------------------------------------

def pct(a, b):
    return f"{100 * a / b:.1f}%" if b else "–"


def cmd_report() -> None:
    owner = json.loads((CACHE / "gaps-owner.json").read_text())["boxes"]
    public = json.loads((CACHE / "gaps-public.json").read_text())["boxes"]
    dates = json.loads((CACHE / "dates.json").read_text()) if (CACHE / "dates.json").exists() else None
    split = teacher_split(owner + public)
    docs = [d for rec in owner for d in documents(rec)]
    rng = random.Random(SEED)
    boot = {}
    for a, b in PAIRS:
        per = {n: bootstrap(docs, a, b, n, rng) for n in SIZES}
        boot[f"{b} - {a}"] = {"sizes": {str(n): v for n, v in per.items()},
                              "needed": {k: needed({n: per[n][k]["half"] for n in SIZES}) for k in per[SIZES[0]]}}
    observed = {}
    for rec in owner + public:
        for key, m in rec["models"].items():
            ex = sum(d["m"][key][0] * d["pages"] for d in documents(rec) if key in d["m"])
            dp = sum(d["pages"] for d in documents(rec))
            wrong = sum(m["gaps"][k][0] != g["truth"] for k, g in enumerate(rec["gaps"]))
            observed.setdefault(key, {})[rec["box"]] = {"pages exact": round(100 * ex / dp, 1),
                                                        "gap accuracy": round(100 * (1 - wrong / len(rec["gaps"])), 1),
                                                        "gaps": len(rec["gaps"]), "doc pages": dp}
    OUT_JSON.write_text(json.dumps({"teacher_split": split, "bootstrap": boot, "observed": observed,
                                    "dates": dates, "level": LEVEL, "draws": DRAWS, "seed": SEED,
                                    "documents_in_pool": len(docs), "gaps_in_pool": sum(d["gaps"] for d in docs)},
                                   indent=1) + "\n")
    OUT_MD.write_text(render(split, boot, observed, dates, docs))
    print("wrote", OUT_MD, OUT_JSON)


def render(split, boot, observed, dates, docs) -> str:
    L = ["# W46.kit-gate — the kit's held-out gate and the teacher audit", "",
         "Generated by `ArchiveProcessor/scripts/segbench/kit_gate.py` from the bench's cached window answers (FarmShare "
         "runs of the teacher and students, `seg-teacher.md`, `seg-students.md`). No calls, no money. Document gaps "
         "only, with the truth's photo labels, as `ensemble.py` scores them.", "",
         "## The teacher split", "",
         "Each student's wrong gaps, split by what the teacher (Qwen3.5 27B, whose replies were the training target) "
         "did on the same gap. A shared error is one training on the teacher could not remove; the rest are the "
         "student's own.", "",
         "| student | box | split | gaps | student wrong | teacher wrong the same way | teacher right | teacher wrong, student right |",
         "|---|---|---|---:|---:|---:|---:|---:|"]
    for s, per in split.items():
        tot = {k: 0 for k in ("gaps", "student wrong", "teacher wrong the same way", "teacher right",
                              "teacher wrong, student right")}
        groups = {}
        for box, r in per.items():
            L.append(f"| {NAMES[s]} | {box} | {r['split']} | {r['gaps']} | {r['student wrong']} | "
                     f"{r['teacher wrong the same way']} | {r['teacher right']} | {r['teacher wrong, student right']} |")
            g = groups.setdefault(r["split"], dict.fromkeys(tot, 0))
            for k in tot:
                g[k] += r[k]
        for sp in ("dev", "test", "public"):
            if sp in groups:
                g = groups[sp]
                L.append(f"| {NAMES[s]} | **{sp} pooled** | {sp} | {g['gaps']} | {g['student wrong']} | "
                         f"{g['teacher wrong the same way']} ({pct(g['teacher wrong the same way'], g['student wrong'])}) | "
                         f"{g['teacher right']} | {g['teacher wrong, student right']} |")
    test = {s: {k: sum(r[k] for r in per.values() if r["split"] == "test") for k in
                ("student wrong", "teacher wrong the same way", "teacher right")} for s, per in split.items()}
    pub = {s: {k: sum(r[k] for r in per.values() if r["split"] == "public") for k in
               ("student wrong", "teacher wrong the same way", "teacher right")} for s, per in split.items()}
    s2, s4 = test.get("fs-seg-2b"), test.get("fs-seg-4b")
    L += ["", "### Reading", ""]
    if s2 and s4:
        L.append(f"- **On the test boxes, {pct(s2['teacher wrong the same way'], s2['student wrong'])} of the 2B's errors "
                 f"and {pct(s4['teacher wrong the same way'], s4['student wrong'])} of the 4B's are the teacher's.** The 2B shares "
                 f"{s2['teacher wrong the same way']} of its {s2['student wrong']} wrong gaps with the teacher, the 4B "
                 f"{s4['teacher wrong the same way']} of {s4['student wrong']}. Those cannot be trained away with this "
                 "teacher: a better teacher, or owner-ruled labels, is what would move them. The rest are errors the "
                 "students add on top, which more or better-matched training could reach.")
    p2, p4 = pub.get("fs-seg-2b"), pub.get("fs-seg-4b")
    if p2 and p4:
        L.append(f"- **On the public boxes, material none of them trained on, the split is "
                 f"{p2['teacher wrong the same way']} of {p2['student wrong']} (2B) and {p4['teacher wrong the same way']} "
                 f"of {p4['student wrong']} (4B).** Lincoln and CREST differ from the owner's corpus in kind, so how "
                 "much of the students' loss there comes from the teacher says how far a second-family teacher could "
                 "help a user whose material is unlike the owner's.")
    L += ["- **Not yet on the owner's 80-gap checkpack or Sasha.** No route has answers on the windows those gaps sit "
          "in (the checkpack's gaps are 71 in training collections and 9 held out; Sasha was locked on 2026-10-30), so "
          "the students' accuracy on owner-ruled held-out gaps, and the split there, wait for the teacher-and-students "
          "job W46.seg-boxes-score prepares for Sherlock (this item's teacher arm is shared with it, as the audit asks).",
          "", "## The held-out set size", "",
          f"Paired document bootstrap over the five owner boxes ({len(docs)} documents, "
          f"{sum(d['gaps'] for d in docs)} gaps): documents drawn with replacement until the draw holds N gaps, "
          f"{DRAWS:,} draws a size, seed {SEED}. Half-width of the 95% interval of the difference, in points; "
          f"'needed' is the size whose half-width reaches {TARGET:.0f} points, extrapolated from the 1,000-gap figure "
          "by 1/√N. Review load is gaps flagged at confidence ≤ 0.85 per 100 pages.", "",
          "| difference | measure | 100 gaps | 300 gaps | 1,000 gaps | needed for ±3 points | observed at 1,000 (interval) |",
          "|---|---|---:|---:|---:|---:|---|"]
    for pair, v in boot.items():
        b, a = pair.split(" - ")
        for k in ("pages exact", "gap accuracy", "flagged per 100 pages"):
            s = v["sizes"]
            L.append(f"| {SHORT[b]} minus {SHORT[a]} | {k} | ±{s['100'][k]['half']} | ±{s['300'][k]['half']} | "
                     f"±{s['1000'][k]['half']} | {v['needed'][k]:,} | {s['1000'][k]['lo']} to {s['1000'][k]['hi']} |")
    pe2 = boot[f"fs-seg-4b - fs-seg-2b"]
    L += ["", "### Reading", "",
          f"- **A 3-point gate on pages exact needs about {pe2['needed']['pages exact']:,} held-out gaps** of owner-like "
          f"material; at 300 gaps the interval is ±{pe2['sizes']['300']['pages exact']['half']} points and at 100 "
          f"±{pe2['sizes']['100']['pages exact']['half']}. Gap accuracy needs fewer "
          f"(about {pe2['needed']['gap accuracy']:,}), because a gap is a smaller unit than a document's pages.",
          "- **The rerun floor is on top of this.** The audit measured 1.4-3.2 points a box between identical reruns "
          "(SEG-10). The gate's interval covers sampling the held-out set; a model's own wobble at temperature 0 under "
          "vLLM is a second error of about the same size, so a 3-point difference is only separated when both are "
          "inside it: the gate should score two runs, or demand the difference clear the larger floor.",
          "- **These are owner gaps, and the kit's user has tags.** The interval is sampling only; a gate scored "
          "against a user's tags inherits their noise (5.3% among agreed labels, `label-clean.md`), which shifts "
          "both models' scores alike in a paired difference but caps any absolute claim.",
          "", "## Observed, from the same records", "",
          "| model | box | gaps | gap accuracy | pages exact |", "|---|---|---:|---:|---:|"]
    for key, per in observed.items():
        for box, r in per.items():
            L.append(f"| {NAMES[key]} | {box} | {r['gaps']} | {r['gap accuracy']}% | {r['pages exact']}% |")
    if dates:
        L += ["", "## The dating split (the 131 documents whose year is not in the text)", "",
              "The dating students were trained on the owner's tags and dated public documents, not on a teacher's "
              "replies, so no error can be inherited from a teacher. The nearest question: are their wrong years the "
              f"ones Gemini (the app's default tagger, {dates['gemini right']} of {dates['documents']} right) also "
              "gets wrong?", "",
              "| student | answered | right | wrong | Gemini also wrong | the same wrong year | Gemini right | student right, Gemini wrong |",
              "|---|---:|---:|---:|---:|---:|---:|---:|"]
        for lab, r in dates["students"].items():
            L.append(f"| {lab.removesuffix('-nothink')} | {r['answered']} | {r['right']} | {r['wrong']} | "
                     f"{r['gemini wrong too']} | {r['gemini the same wrong year']} | {r['gemini right']} | "
                     f"{r['student right, gemini wrong']} |")
    man = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else None
    L += ["", "## The gate: `train_seg.py check` and the manifest", "",
          "`train_seg.py check` (institutional-compute) is the kit's held-out gate. It reads `cluster_seg.py` answers "
          "only, scores each run's per-gap calls on the held-out collections against their tags (and against the "
          "owner's rulings when a file of them is given) with a folder bootstrap, and on a locked public anchor box "
          "(pages exact, gap accuracy, the review load to 98%) with a document bootstrap, each paired against the "
          "shipped model. It writes H §6.3's manifest: kit version, prompt id, base build, weights, adapter and "
          "training-data hashes, the scores with intervals, the Mac figures and the gate's verdict, and exits 1 when "
          "the gate fails. The proposed rule: an anchor score, a held-out score, and a held-out interval against the "
          "shipped model whose low end is above -3 points. Whether that is the acceptance rule is Phase 4's call "
          "(gap audit item 20).", "",
          "The app reads the manifest as `archive-seg-manifest.json` beside the weights. `LocalSegmenter.refusal` runs "
          "the shipped build as its own, and refuses any other Model setting that is not a folder on the Mac holding a "
          "manifest of kit `seg-kit-1`, prompt c1, with an anchor pages-exact score: it is returned before a run "
          "starts (`WindowStageTransport.current`), as an unknown voter is refused today. Six checks in "
          "`SegmentationEngineTestDriver` cover it."]
    if man:
        an = man["anchor"]
        L += ["", f"The shipped build's own manifest is `seg-kit-manifest-shipped.json`: weights "
              f"`{man['weights_sha256'][:12]}…` (the 8-bit MLX build), anchor {an['box']} {an['pages_exact']}% of pages "
              f"exact ({an['pages_exact_interval'][0]} to {an['pages_exact_interval'][1]}), gap accuracy "
              f"{an['gap_accuracy']}%, review load to 98% {an['review_load_per_100_pages']} gaps per 100 pages. Its "
              "anchor answers are the full-precision FarmShare run, and its held-out run is not on this Mac, so its "
              "held-out block is empty and its own gate says so; the app requires only the anchor and the prompt."]
    L += ["", "## The kit end to end, dry (2026-10-31)", "",
          "Each step run as far as it can go without a cluster (no engine session contacts Sherlock) and without "
          "training on this Mac (W46.kit-mac-lora measures that):", "",
          "| step | how it was run | result |", "|---|---|---|",
          "| training set | `train_seg.py data`, offline test on a synthetic pack (`test_institutional_compute.Check`) | "
          "only whole agreed training windows train, held-out never; start-trust keeps more |",
          "| train and merge | the README's `slurm_args` recipe against the example profile, printed not submitted | "
          "one sbatch line for `train.sbatch` (train, then merge) |",
          "| held-out and anchor answers | `submit.sh seg seg-student --pack … --dry-run` (example profile) | one "
          "sbatch line serving the merged student under its name; the packs come from `corpus_pairs.py subpack "
          "--split holdout` and `public_segmentation.py pack` |",
          "| the gate | `train_seg.py check` on the cached FarmShare runs (Lincoln; the joint 2B's held-out run) | "
          "reproduces the bench's figures (4B 46.7%, 2B 34.9% on Lincoln); joint 2B 80.4% of 7,277 held-out tag gaps |",
          "| the app | `LocalSegmenter.refusal` on the written manifests | the shipped manifest passes; no manifest, no "
          "anchor score or another prompt is refused |", "",
          "What the dry run found missing from the kit:", "",
          "- **No step builds the Mac model.** The 8-bit MLX build was made by the Vision OCR lab's `convert-mlx.py` by "
          "hand (`seg-students.md` §On the Mac); the kit stops at a merged model on the cluster. A user needs a "
          "`train_seg.py` or kit step that converts and quantises it, then hashes what the app will load.",
          "- **The manifest has to be copied beside the Mac build by hand**, and its weights hash is of whatever folder "
          "`--weights` named: hashed on the cluster's merged model, it does not match the Mac build.",
          "- **Mac figures are not measured by the kit.** H §6.3 asks for the kit's own warm-up run; `check` takes them "
          "from a file (`--mac`), and nothing writes that file yet.",
          "- **The local copy of the shipped build has no manifest** (`~/.local/share/visionocr-ocrlab/mlx/`): a Model "
          "setting naming that folder is now refused until `seg-kit-manifest-shipped.json` is copied there as "
          "`archive-seg-manifest.json`. The default setting (the published repository) is unaffected.",
          "- The plan-route arm (a `claude -p` voter in the kit) is held for the gateway (CLAUDE.md, \"Plan routes "
          "wait for the gateway\"), so the coding-agent leg was not run through `claude -p`. The five-hour "
          "window went from 26% to 39% over this session, which shares it with anything else running; the kit's own "
          "steps were seconds of CPU."]
    L += ["", "## Measurement card", "",
          "- **Truth.** The owner's ruled boxes (Dean, Deaver, Herrnstein; test boxes Stanton and RG165) and the "
          "audited public truths of Lincoln and CREST; dating: the owner's year tags. Stanton still carries the "
          "full-magazine rule the owner re-ruled on 2026-10-29 (SEG-7), so its figures will move when it is re-ruled.",
          "- **Selection.** Whole boxes, chosen before these models existed; the dating 131 by whether the year is in "
          "the ABBYY text, which is how they were chosen in W41.date-model (ABBYY is not an input here).",
          "- **Comparison.** Every model on the same windows and the same request (`method_local.request`, the "
          "images at 1,024 px, temperature 0, thinking off), each on one L40S under vLLM 0.31, read from "
          "`method_openrouter.py`'s caches; the untrained 4B was run on the development boxes only.",
          f"- **Noise.** The bootstrap's intervals above; the rerun floor (1.4-3.2 points a box) is not in them. "
          "Shared-error counts are single runs.",
          "- **Scope.** The owner's material and two public boxes. The checkpack and Sasha arms, which measure "
          "accuracy on owner-ruled held-out gaps, wait for the Sherlock job (above).", ""]
    return "\n".join(L)


def main(argv) -> int:
    if argv[:2] == ["gaps", "owner"]:
        cmd_gaps("owner", None)
    elif argv[:2] == ["gaps", "public"] and len(argv) == 4 and argv[2] == "--root":
        cmd_gaps("public", argv[3])
    elif argv[:1] == ["dates"] and len(argv) == 3 and argv[1] == "--root":
        cmd_dates(argv[2])
    elif argv[:1] == ["report"]:
        cmd_report()
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
