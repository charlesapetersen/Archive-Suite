"""Score a segmentation method on the bench and write the result (W36.seg-bench).

    python run.py all-new                    # development set (Dean, Deaver, Herrnstein)
    python run.py no-boundaries --collections Dean
    python run.py <method> --final           # also the test set (Stanton, RG165): once per finalist
    python run.py --list

Writes ArchiveProcessor/segbench-results/<method>-<split>.tsv (one row per collection plus a
pooled row) and <method>-<split>.md, then regenerates SUMMARY.md from every TSV there. These
hold numbers only — never page images or text — so they are committed.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import sys
from pathlib import Path

import data
from methods import METHODS
from score import check_prediction, derived, guard, risk_coverage, score_labels

RESULTS = data.HERE.parent.parent / "segbench-results"
PROVENANCE = ("The spring 2026 prompts (improved_v1, shipped) were developed while looking at all five "
              "collections, so no collection is fully unseen by the shipped prompt.")

HEADLINE_COLS = [("pages_in_exact_doc", "pages in exact doc", "%"),
                 ("docs_exact", "docs exact", "%"),
                 ("false_splits", "false splits", "n"),
                 ("false_merges", "false merges", "n"),
                 ("boundary_f1", "boundary F1", "f"),
                 ("pk", "Pk", "f"),
                 ("windowdiff", "WindowDiff", "f"),
                 ("folders_perfect", "folders perfect", "%"),
                 ("edits_per_100_pages", "edits/100 pages", "f1"),
                 ("photo_accuracy", "photo accuracy", "%")]


def fmt(v, kind):
    if v is None:
        return "—"
    if kind == "%":
        return f"{100 * v:.1f}%"
    if kind == "f":
        return f"{v:.3f}"
    if kind == "f1":
        return f"{v:.1f}"
    return str(v)


def run(method_name: str, names: list[str], final: bool) -> list[dict]:
    method = METHODS[method_name]
    guard(method, names, final)
    rows, total = [], None
    for name in names:
        col = data.load(name)
        pred = method.predict(col)
        check_prediction(pred)
        c = score_labels(col.labels, pred.labels, name)
        row = derived(c)
        rc = risk_coverage(col.labels, pred)
        row["has_confidence"] = rc is not None
        rows.append(row)
        total = c if total is None else total + c
    if len(names) > 1:
        pooled = derived(total)
        pooled["collections"] = "POOLED " + pooled["collections"]
        pooled["has_confidence"] = rows[0]["has_confidence"]
        rows.append(pooled)
    return rows


def split_name(names):
    s = set(names)
    if s == set(data.DEV):
        return "dev"
    if s == set(data.TEST):
        return "test"
    if s == set(data.DEV) | set(data.TEST):
        return "all"
    return "-".join(names)


def write(method_name: str, names: list[str], rows: list[dict]) -> Path:
    method = METHODS[method_name]
    RESULTS.mkdir(parents=True, exist_ok=True)
    stem = f"{method_name}-{split_name(names)}"
    keys = list(rows[0].keys())
    with open(RESULTS / f"{stem}.tsv", "w", newline="") as fh:
        w = csv.writer(fh, delimiter="\t", lineterminator="\n")
        w.writerow(keys)
        for r in rows:
            w.writerow(["" if r[k] is None else (f"{r[k]:.6f}" if isinstance(r[k], float) else r[k])
                        for k in keys])
    test_used = [n for n in names if n in data.TEST]
    lines = [f"# {method_name} on {split_name(names)}", "",
             f"Run {dt.date.today().isoformat()}. Method: {method.description}.",
             f"Measured on: {', '.join(names)}. Tuned on: "
             f"{method.tuned_on or ('nothing (no free parameters)' if not method.tuning else 'still tuning (development set only)')}."
             + (f" Test collections scored: {', '.join(test_used)}." if test_used else ""),
             ("Box/folder photo labels were taken from the truth (oracle), so photo accuracy is 100% by "
              "construction and the document figures isolate boundary finding." if method.oracle_photos else ""),
             PROVENANCE, "",
             "| collection | pages | docs | " + " | ".join(h for _, h, _ in HEADLINE_COLS) + " |",
             "|---|---:|---:|" + "---:|" * len(HEADLINE_COLS)]
    for r in rows:
        lines.append(f"| {r['collections']} | {r['pages']} | {r['docs']} | "
                     + " | ".join(fmt(r[k], kind) for k, _, kind in HEADLINE_COLS) + " |")
    notes = method.notes()
    if notes:
        lines += [""] + notes
    lines += ["", "Definitions: ArchiveProcessor/scripts/segbench/score.py (module docstring). Pooled rows sum "
              "the counts, so they are page- or item-weighted."]
    (RESULTS / f"{stem}.md").write_text("\n".join(l for l in lines if l is not None) + "\n")
    write_summary()
    return RESULTS / f"{stem}.md"


def write_summary() -> None:
    lines = ["# Segmentation bench — headline per run", "",
             "One line per method and split (the pooled row, or the only collection). Pages in an exact document "
             "is the headline. Detail in each <method>-<split>.md; regenerated by run.py.", "",
             PROVENANCE, "",
             "Photos: \"truth\" means the method was given the box/folder photo labels from the ground truth, so "
             "its figures isolate boundary finding; \"own\" means it labelled the photos itself and its photo "
             "errors count. Held out: whether the development numbers were measured on collections the method "
             "was not tuned on.", "",
             "| method | split | pages | pages in exact doc | docs exact | false splits | false merges | boundary F1 | edits/100 pages | photos | held out |",
             "|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|"]
    for f in sorted(RESULTS.glob("*.tsv")):
        with open(f, newline="") as fh:
            rows = list(csv.DictReader(fh, delimiter="\t"))
        r = rows[-1]
        num = lambda k: float(r[k]) if r[k] != "" else None
        method, _, split = f.stem.rpartition("-")
        m = METHODS.get(method)
        lines.append(f"| {method} | {split} | {r['pages']} | {fmt(num('pages_in_exact_doc'), '%')} | "
                     f"{fmt(num('docs_exact'), '%')} | {r['false_splits']} | {r['false_merges']} | "
                     f"{fmt(num('boundary_f1'), 'f')} | {fmt(num('edits_per_100_pages'), 'f1')} | "
                     f"{('truth' if m.oracle_photos else 'own') if m else '?'} | {(m.held_out if m else '') or '?'} |")
    # Sections a method's own report adds (e.g. features-lr.summary-section.md), appended verbatim.
    for extra in sorted(RESULTS.glob("*.summary-section.md")):
        lines.append(extra.read_text().rstrip())
    (RESULTS / "SUMMARY.md").write_text("\n".join(lines) + "\n")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("method", nargs="?")
    ap.add_argument("--collections", nargs="+", default=None,
                    help=f"default: the development set {list(data.DEV)}; --final adds the test set")
    ap.add_argument("--final", action="store_true",
                    help="permit the held-out test collections (once per finalist, never for a tuning method)")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args(argv)
    if a.list or not a.method:
        for m in METHODS.values():
            print(f"{m.name:20} tuning={m.tuning!s:5} {m.description}")
        return 0
    if a.method not in METHODS:
        ap.error(f"unknown method {a.method!r}")
    names = a.collections or (list(data.DEV) + (list(data.TEST) if a.final else []))
    rows = run(a.method, names, a.final)
    path = write(a.method, names, rows)
    print(path.read_text())
    return 0


if __name__ == "__main__":
    sys.exit(main())
