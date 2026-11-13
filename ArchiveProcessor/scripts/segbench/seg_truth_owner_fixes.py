#!/usr/bin/env python3
"""W46.seg-truth-owner-fixes: fold the owner's 2026-11-13 corrections into the Stanton and RG165 boundary truth.

The owner judged, with three pages either side of each gap, the 12 W46.seg-check-time answers that differed from the
truth (review-20261113/answers.json in that item's cache; notes-20261113-093648.txt):

* ``mine-right`` (8): his timed answer was right and the truth wrong; the right page takes his label (split = New,
  join = Cont) in the box's truth CSV (Test Files, outside git, read by data.load).
* ``truth-right`` (Stanton 56|57) and ``depends`` (Stanton 101|102, a magazine cover then an article: the
  article-within-issue rule of 2026-10-29 splits it, so the truth's New stands): unchanged.
* ``unsure`` (RG165 79|80, 99|100): listed in the box's lock.json ``unsure`` (Collection.unsure), so score.py leaves
  them out of every score (UNSURE GAPS), as for the locked boxes.

Each changed CSV is copied once to the cache before it is written, and every fold writes
segbench-results/seg-truth-owner-fixes.json (numbers only). Re-running fold is a no-op once the truth carries them.

    python3 seg_truth_owner_fixes.py fold                 # the two truths + the record
    python3 seg_truth_owner_fixes.py moved [--before REV]  # every numeric figure in the rescored results that moved
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import shutil
import subprocess
from pathlib import Path

import data

TAG = "W46.seg-truth-owner-fixes"
DATE = "2026-11-13"
CACHE = Path.home() / "Library/Caches/ArchiveSuiteRehearsal/seg-check-time"
REVIEW = CACHE / "review-20261113/answers.json"
RUN = CACHE / "run-20261113-093648.json"
BACKUP = CACHE / "truth-before-owner-fixes"
RESULTS = data.HERE.parent.parent / "segbench-results"
RECORD = RESULTS / "seg-truth-owner-fixes.json"
LABEL = {"split": "New", "join": "Cont"}
# What the owner said in chat (SUITE_TODO), checked against the files so a misread answer cannot fold silently.
EXPECTED = {"Stanton": {27: "Cont", 33: "Cont", 50: "Cont", 125: "Cont", 34: "New", 47: "New", 54: "New"},
            "RG165": {86: "Cont"}}
EXPECTED_UNSURE = {"RG165": [80, 100]}


def rulings() -> list[dict]:
    """One row per reviewed gap: box, left, right, the truth's label, his timed answer, his review call."""
    answers = {a["key"]: a["answer"] for a in json.loads(RUN.read_text())["items"]}
    out = []
    for r in json.loads(REVIEW.read_text()):
        box, gap = r["key"].split()
        left, right = map(int, gap.split("|"))
        out.append({"box": box, "left": left, "right": right, "timed": answers[r["key"]], "call": r["call"],
                    "note": r.get("note", "")})
    return out


def changes(rows: list[dict]) -> tuple[dict[str, dict[int, str]], dict[str, list[dict]]]:
    flips: dict[str, dict[int, str]] = {}
    unsure: dict[str, list[dict]] = {}
    for r in rows:
        if r["call"] == "mine-right":
            flips.setdefault(r["box"], {})[r["right"]] = LABEL[r["timed"]]
        elif r["call"] == "unsure":
            unsure.setdefault(r["box"], []).append({"left": r["left"], "right": r["right"]})
        elif r["call"] not in ("truth-right", "depends"):
            raise ValueError(f"{r['box']} {r['left']}|{r['right']}: call {r['call']!r} has no fold rule")
    if flips != EXPECTED or {b: [u["right"] for u in v] for b, v in unsure.items()} != EXPECTED_UNSURE:
        raise SystemExit(f"the answers do not match the owner's stated corrections: {flips} {unsure}")
    return flips, unsure


def fold_csv(text: str, flips: dict[int, str]) -> str:
    """The truth CSV text with the flips applied; every other byte unchanged."""
    out = []
    for line in text.splitlines(keepends=True):
        row = next(csv.reader(io.StringIO(line)), [])
        if row and row[0].strip().isdigit() and int(row[0]) in flips:
            line = f"{row[0]},{flips[int(row[0])]}{line[len(line.rstrip(chr(13) + chr(10))):]}"
        out.append(line)
    return "".join(out)


def cmd_fold(_a) -> None:
    rows = rulings()
    flips, unsure = changes(rows)
    before = {}
    for box in ("Stanton", "RG165"):
        folder = data.DATA_DIR / data.COLLECTIONS[box]
        (csv_path,) = [p for p in folder.iterdir() if p.suffix.lower() == ".csv"]
        raw = csv_path.read_bytes()
        bom = raw.startswith(b"\xef\xbb\xbf")
        text = raw.decode("utf-8-sig")
        keep = BACKUP / f"{box}-{csv_path.name}"
        after = fold_csv(text, flips.get(box, {}))
        if after != text and not keep.exists():
            BACKUP.mkdir(exist_ok=True)
            shutil.copy2(csv_path, keep)
        # The labels before the fold: the copy once it exists, so a re-run records the same thing.
        before[box] = dict(data.read_truth(keep if keep.exists() else csv_path))
        if after != text:
            csv_path.write_bytes((b"\xef\xbb\xbf" if bom else b"") + after.encode("utf-8"))
        lock = folder / "lock.json"
        if box in unsure:
            rec = json.loads(lock.read_text(encoding="utf-8")) if lock.exists() else {}
            rec["unsure"] = unsure[box]
            rec["owner_rulings"] = {
                "item": f"W46.seg-check-time's review, folded by {TAG}", "date": DATE,
                "gaps": [{k: r[k] for k in ("left", "right", "timed", "call")} for r in rows if r["box"] == box],
                "unsure_rule": "the gaps the owner could not rule are left out of every score (score.py, UNSURE GAPS)"}
            lock.write_text(json.dumps(rec, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    for box in ("Stanton", "RG165"):
        col = data.load(box, with_exif=False)
        got = {p.n: p.label for p in col.pages}
        for n, lab in flips.get(box, {}).items():
            assert got[n] == lab, (box, n, got[n])
        moved = {n for n in got if got[n] != before[box][n]}
        assert moved <= set(flips.get(box, {})), (box, moved)
        assert sorted(col.unsure) == sorted(u["right"] for u in unsure.get(box, [])), (box, col.unsure)
    record = {"item": TAG, "date": DATE, "source": "W46.seg-check-time review-20261113/answers.json",
              "rulings": [{**{k: r[k] for k in ("box", "left", "right", "timed", "call")},
                           "truth_before": before[r["box"]][r["right"]],
                           "truth_after": flips.get(r["box"], {}).get(r["right"], before[r["box"]][r["right"]]),
                           "unsure": r["call"] == "unsure"} for r in rows]}
    RECORD.write_text(json.dumps(record, indent=1) + "\n", encoding="utf-8")
    print(f"folded {flips}; unsure {unsure}")


# --- what moved: every numeric leaf of a result before the fold against the working tree -------------------------

def _leaves(x, path=""):
    if isinstance(x, dict):
        for k, v in x.items():
            yield from _leaves(v, f"{path}.{k}" if path else str(k))
    elif isinstance(x, list):
        for i, v in enumerate(x):
            yield from _leaves(v, f"{path}[{i}]")
    elif isinstance(x, (int, float)) and not isinstance(x, bool):
        yield path, x


def moved(before: dict, after: dict) -> list[tuple[str, float, float]]:
    b = dict(_leaves(before))
    return [(p, b[p], v) for p, v in _leaves(after) if p in b and b[p] != v]


def cmd_moved(a) -> None:
    for rel in a.files:
        try:
            old = json.loads(subprocess.run(["git", "show", f"{a.before}:ArchiveProcessor/segbench-results/{rel}"],
                                            cwd=RESULTS, capture_output=True, text=True, check=True).stdout)
        except subprocess.CalledProcessError:
            print(f"## {rel}: not in {a.before}")
            continue
        m = moved(old, json.loads((RESULTS / rel).read_text()))
        print(f"## {rel}: {len(m)} figures moved")
        for p, x, y in m[: a.limit]:
            print(f"  {p}: {x} -> {y}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("fold").set_defaults(fn=cmd_fold)
    m = sub.add_parser("moved")
    m.add_argument("files", nargs="+")
    m.add_argument("--before", default="origin/main")
    m.add_argument("--limit", type=int, default=60)
    m.set_defaults(fn=cmd_moved)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
