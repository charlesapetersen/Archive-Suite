"""W46.fix-seg-scorers: how often the page kind changes inside one document (K-kinds test 5).

    <lab venv>/bin/python kind_churn.py      # -> segbench-results/kind-churn.md + .json

The classifier is the one the Processor ships (W41.app-page-kind): kind_classifier's logistic regressions on Apple
Vision's signals and image feature print, ``segbench-results/kind-classifier-model.json``, measured per page by
``kind_signals/kind-signals.swift`` (built into the bench cache; reads the page images only). Every document page
of the five owner boxes (914 pages less the label photos) is classified, and the truth's documents say which pages
belong together. Reported: how many documents of two or more pages hold more than one hand (typewritten, printed,
handwritten) or a form page beside a non-form page; where the minority pages fall (first page, last page,
between); and their confidence against the app's 0.8 floor, below which the app keeps the run's model. There is
no per-page kind truth on these boxes, so a change is the classifier's, real or not; what this measures is how
much a document prior below the floor would alter, which is what decides whether it is worth building.
No calls, no money.
"""
from __future__ import annotations

import csv
import json
import subprocess
import sys
from collections import Counter
from pathlib import Path

import numpy as np

import data
from score import PHOTO, segment_ids

HERE = Path(__file__).resolve().parent
RESULTS = HERE.parents[1] / "segbench-results"
MODEL = json.loads((RESULTS / "kind-classifier-model.json").read_text())
FLOOR = 0.8          # ArchiveProcessor/CLAUDE.md, W41.app-page-kind
TOOL = data.CACHE_DIR / "bin" / "kind-signals"
WORK = data.CACHE_DIR / "kind-churn"
SCAL = ["harmonic", "periodic", "conf", "text_px", "lines"]


def num(x) -> float:
    try:
        v = float(x)
    except (TypeError, ValueError):
        return 0.0
    return 0.0 if v != v else v


def measure(cols) -> tuple[dict, dict]:
    src = HERE / "kind_signals/kind-signals.swift"
    if not TOOL.exists() or src.stat().st_mtime > TOOL.stat().st_mtime:
        TOOL.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", "-o", str(TOOL), "-target", "arm64-apple-macos26.0", str(src)], check=True)
    WORK.mkdir(parents=True, exist_ok=True)
    sig_path, fp_path = WORK / "signals.tsv", WORK / "featureprints.tsv"
    want = {f"{c.name}:{p.n}": p.path for c in cols for i, p in enumerate(c.pages) if c.labels[i] not in PHOTO}
    if not sig_path.exists() or not fp_path.exists():
        lst = WORK / "list.tsv"
        lst.write_text("".join(f"{k}\t{v}\n" for k, v in want.items()))
        with open(sig_path, "w") as out:
            subprocess.run([str(TOOL), str(lst), str(fp_path)], stdout=out, check=True)
    sig = {r["id"]: r for r in csv.DictReader(open(sig_path), delimiter="\t")}
    fp = {}
    for line in open(fp_path):
        k, v = line.rstrip("\n").split("\t")
        fp[k] = np.array([float(x) for x in v.split(",")])
    missing = [k for k in want if k not in fp or sig.get(k, {}).get("width") in (None, "unread")]
    if missing:
        raise RuntimeError(f"{len(missing)} pages unmeasured, e.g. {missing[:3]}; delete {WORK} to measure again")
    return sig, fp


def classify(s: dict, fp: np.ndarray) -> tuple[str, float, bool]:
    def softmax(m, x):
        z = (x - np.array(m["mean"])) / np.array(m["sd"])
        sc = z @ np.array(m["W"]) + np.array(m["b"])
        e = np.exp(sc - sc.max())
        return e / e.sum()
    base = np.array([num(s[c]) for c in SCAL])
    ph = softmax(MODEL["hand"], np.concatenate([base, fp]))
    pf = softmax(MODEL["form"], np.concatenate([[num(s["table_share"]), num(s["table_cells"])], base, fp]))
    k = int(ph.argmax())
    return MODEL["hand"]["classes"][k], float(ph[k]), bool(pf[1] > 0.5)


def analyse() -> dict:
    cols = [data.load(n, with_exif=False) for n in data.COLLECTIONS]
    sig, fp = measure(cols)
    pages, docs = 0, []
    for c in cols:
        ids = segment_ids(c.labels)
        groups: dict[int, list[int]] = {}
        for i, s in enumerate(ids):
            if c.labels[i] not in PHOTO:
                groups.setdefault(s, []).append(i)
        for idx in groups.values():
            rows = [classify(sig[f"{c.name}:{c.pages[i].n}"], fp[f"{c.name}:{c.pages[i].n}"]) for i in idx]
            pages += len(rows)
            docs.append({"box": c.name, "rows": rows})
    multi = [d for d in docs if len(d["rows"]) >= 2]
    out = {"pages": pages, "documents": len(docs), "multi_page_documents": len(multi),
           "multi_page_pages": sum(len(d["rows"]) for d in multi)}
    all_conf = [r[1] for d in docs for r in d["rows"]]
    out["pages_below_floor"] = sum(c < FLOOR for c in all_conf)
    out["hand_counts"] = dict(Counter(r[0] for d in docs for r in d["rows"]))
    out["form_pages"] = sum(r[2] for d in docs for r in d["rows"])
    hand_churn = [d for d in multi if len({r[0] for r in d["rows"]}) > 1]
    form_churn = [d for d in multi if len({r[2] for r in d["rows"]}) > 1]
    out["hand_churn_documents"] = len(hand_churn)
    out["form_churn_documents"] = len(form_churn)
    out["hand_churn_by_box"] = {c.name: [sum(1 for d in hand_churn if d["box"] == c.name),
                                         sum(1 for d in multi if d["box"] == c.name)] for c in cols}
    # Minority pages: a page whose hand differs from its document's majority (ties: the first page's hand).
    where, conf_min, flips_below = Counter(), [], 0
    for d in multi:
        hands = [r[0] for r in d["rows"]]
        cnt = Counter(hands)
        top = max(cnt.values())
        major = hands[0] if cnt[hands[0]] == top else max(cnt, key=cnt.get)
        for j, (h, cf, _) in enumerate(d["rows"]):
            if h == major:
                continue
            where["first page" if j == 0 else "last page" if j == len(hands) - 1 else "between"] += 1
            conf_min.append(cf)
            flips_below += cf < FLOOR
    out["minority_pages"] = len(conf_min)
    out["minority_where"] = dict(where)
    out["minority_below_floor"] = flips_below
    out["minority_conf_median"] = float(np.median(conf_min)) if conf_min else None
    out["all_conf_median"] = float(np.median(all_conf))
    pairs = Counter()
    for d in hand_churn:
        hs = sorted({r[0] for r in d["rows"]})
        pairs[" + ".join(hs)] += 1
    out["churn_pairs"] = dict(pairs)
    return out


def render(r: dict) -> str:
    pct = lambda a, b: f"{100 * a / b:.1f}%" if b else "—"
    L = ["# Kind churn inside documents — W46.fix-seg-scorers (K-kinds test 5)", "",
         "Made by `scripts/segbench/kind_churn.py` (method in its docstring): the shipped page-kind classifier "
         "(`kind-classifier-model.json`) on every document page of the five owner boxes, grouped by the truth's "
         "documents. No per-page kind truth exists here, so every change counted is the classifier's.", "",
         f"- {r['pages']} document pages in {r['documents']} documents; {r['multi_page_documents']} documents have two "
         f"or more pages ({r['multi_page_pages']} pages).",
         f"- Hands called: " + ", ".join(f"{k} {v}" for k, v in sorted(r["hand_counts"].items())) +
         f"; form or table on {r['form_pages']} pages.",
         f"- **{r['hand_churn_documents']} of {r['multi_page_documents']} multi-page documents "
         f"({pct(r['hand_churn_documents'], r['multi_page_documents'])}) hold more than one hand**; "
         f"{r['form_churn_documents']} ({pct(r['form_churn_documents'], r['multi_page_documents'])}) mix form and "
         "non-form pages.",
         "- By box (documents with a hand change / multi-page documents): " +
         ", ".join(f"{k} {a}/{b}" for k, (a, b) in r["hand_churn_by_box"].items()) + ".",
         "- The hands that meet: " + ", ".join(f"{k} {v}" for k, v in sorted(r["churn_pairs"].items(), key=lambda kv: -kv[1])) + ".",
         f"- {r['minority_pages']} pages differ from their document's majority hand: " +
         ", ".join(f"{k} {v}" for k, v in sorted(r["minority_where"].items())) + ".",
         f"- Their median confidence is {r['minority_conf_median']:.3f} against {r['all_conf_median']:.3f} for all "
         f"pages; **{r['minority_below_floor']} of the {r['minority_pages']} are below the app's {FLOOR} floor**, "
         f"against {r['pages_below_floor']} of all {r['pages']} pages ({pct(r['pages_below_floor'], r['pages'])}).",
         "", "A document prior used only below the floor could change at most the minority pages below it; those "
         "above it would need the prior to overrule a confident call, which the K note's design does not propose.", ""]
    return "\n".join(L)


def main() -> int:
    r = analyse()
    (RESULTS / "kind-churn.json").write_text(json.dumps(r, indent=1) + "\n")
    (RESULTS / "kind-churn.md").write_text(render(r))
    print(render(r))
    return 0


if __name__ == "__main__":
    sys.exit(main())
