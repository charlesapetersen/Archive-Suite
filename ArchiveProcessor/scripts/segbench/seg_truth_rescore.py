#!/usr/bin/env python3
"""W46.seg-truth-rescore: fold the owner's segmentation sheet into the truth, and the SC0122 controls' error.

The owner answered W46.seg-truth-sheet on 2026-10-31 (rulings.json in its cache, all 75 gaps). This folds them:

* Stanton (the truth CSV in Test Files, outside git): gaps the owner ruled differently take his label. Under the
  article-within-issue rule 101|102 and 102|103 split, 103|104 and 104|105 stay joined.
* CREST and Lincoln (the committed public manifests): a ruling that differs sets the right page's label and says so
  in its audit; the gaps he could not rule go into the manifest's ``unsure`` list, which public_segmentation.validate
  hands to the Collection, so score_labels leaves them out of every score (score.py, UNSURE GAPS).
* SC0122 (its locked lock.json): the 60 controls are recorded as owner-ruled. The folder is read-only by design
  (seg_boxes.py); fold opens it for the one write and closes it again, and seg_boxes.verify must still pass.

Every fold also writes segbench-results/seg-truth-rulings.json: numbers only (gap, current truth, answer, label).
Re-running fold is a no-op once the truth carries the rulings.

    python3 seg_truth_rescore.py fold      # the four truths above + seg-truth-rulings.json
    python3 seg_truth_rescore.py sc0122    # the agreed-stratum error, weighted (N/n) and unweighted, with intervals
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import math
import os
import shutil
from pathlib import Path

import data

CACHE = Path.home() / "Library/Caches/ArchiveSuiteRehearsal/seg-truth-sheet"
RESULTS = data.HERE.parent.parent / "segbench-results"
MANIFESTS = RESULTS / "public-segmentation"
RULINGS_JSON = RESULTS / "seg-truth-rulings.json"
DATE = "2026-10-31"
LABEL = {"new": "New", "same": "Cont"}
BOXES = {"stanton": "Stanton", "crest": "crest", "lincoln": "lincoln"}


def load_rulings(path: Path = CACHE / "rulings.json") -> list[dict]:
    with open(path, encoding="utf-8") as f:
        return json.load(f)["rulings"]


def changes(rulings: list[dict], section: str) -> tuple[dict[int, str], list[dict]]:
    """(right page -> owner's label where it differs from the current truth, the unsure gaps) for one section."""
    flips, unsure = {}, []
    for r in rulings:
        if r["section"] != section:
            continue
        if r["answer"] in LABEL:
            if LABEL[r["answer"]] != r["current"]:
                flips[r["right"]] = LABEL[r["answer"]]
        elif r["answer"] == "unsure":
            unsure.append({"id": r["id"], "left": r["left"], "right": r["right"]})
        else:
            raise ValueError(f"{r['id']}: answer {r['answer']!r} has no fold rule")
    return flips, unsure


def fold_manifest(manifest: dict, rulings: list[dict], section: str) -> dict:
    """The manifest with the owner's differing rulings as labels and his unsure gaps listed (idempotent)."""
    flips, unsure = changes(rulings, section)
    by_n = {p["n"]: p for p in manifest["pages"]}
    ids = {r["right"]: r["id"] for r in rulings if r["section"] == section}
    for n, lab in flips.items():
        p = by_n[n]
        if p["label"] == lab:
            continue
        p["audit"] = (f"Owner, {DATE} (W46.seg-truth-sheet {ids[n]}): {'a new document' if lab == 'New' else 'the same document'}"
                      f"; the agent's {p['label']} is overruled. Agent's note: {p['audit']}")
        p["label"] = lab
    manifest["unsure"] = unsure
    manifest["owner_rulings"] = {
        "item": "W46.seg-truth-sheet, folded by W46.seg-truth-rescore", "date": DATE,
        "gaps": [{"id": r["id"], "left": r["left"], "right": r["right"], "agent": r["current"], "owner": r["answer"]}
                 for r in rulings if r["section"] == section],
        "unsure_rule": "the gaps the owner could not rule are left out of every score (score.py, UNSURE GAPS)"}
    return manifest


def fold_csv(text: str, rulings: list[dict]) -> str:
    """The Stanton truth CSV text with the owner's differing rulings applied; the rest byte for byte."""
    flips, unsure = changes(rulings, "stanton")
    if unsure:
        raise ValueError("Stanton has no lock.json to carry unsure gaps")
    lines = text.splitlines(keepends=True)
    out = []
    for line in lines:
        row = next(csv.reader(io.StringIO(line)), [])
        if row and row[0].strip().isdigit() and int(row[0]) in flips:
            end = line[len(line.rstrip("\r\n")):]
            line = f"{row[0]},{flips[int(row[0])]}{end}"
        out.append(line)
    return "".join(out)


def fold_lock(lock: dict, rulings: list[dict]) -> dict:
    controls = [r for r in rulings if r["section"] == "sc0122"]
    lock["owner_ruled_controls"] = {
        "item": "W46.seg-truth-sheet, folded by W46.seg-truth-rescore", "date": DATE,
        "note": "agreed (tag and teacher) gaps the owner ruled blind as controls; none changed the truth",
        "gaps": [{"id": r["id"], "left": r["left"], "right": r["right"], "stratum": r["stratum"],
                  "current": r["current"], "owner": r["answer"]} for r in controls]}
    return lock


def wilson(k: float, n: float, z: float = 1.96) -> tuple[float, float]:
    if n <= 0:
        return (0.0, 1.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, c - h), min(1.0, c + h))


def sc0122(rulings: list[dict], strata: dict[str, list[int]]) -> dict:
    """SC0122's agreed-stratum error, unweighted over the controls and weighted by N/n to all agreed gaps, each with
    its n and a 95% Wilson interval (the weighted one on Kish's effective n)."""
    want = {"New": "new", "Cont": "same"}
    rows = [r for r in rulings if r["section"] == "sc0122" and r["answer"] in ("new", "same", "label")]
    w = [strata[r["stratum"]][0] / strata[r["stratum"]][1] for r in rows]
    err = [want.get(r["current"]) != r["answer"] for r in rows]
    k = sum(err)
    sw, sw2 = sum(w), sum(x * x for x in w)
    kw = sum(x for x, e in zip(w, err) if e)
    n_eff = sw * sw / sw2 if sw2 else 0.0
    return {"controls": len(rows), "errors": k, "unweighted": k / len(rows), "unweighted_wilson": wilson(k, len(rows)),
            "agreed_gaps": round(sw), "weighted": kw / sw, "weighted_errors_of_agreed": kw,
            "kish_n": n_eff, "weighted_wilson": wilson(kw / sw * n_eff, n_eff)}


def _strata() -> dict:
    with open(CACHE / "key.json", encoding="utf-8") as f:
        return json.load(f)["strata"]


def _write_locked(path: Path, text: str) -> None:
    """Write one file inside a read-only locked box and lock it again (seg_boxes.py's modes)."""
    folder = path.parent
    os.chmod(folder, 0o700)
    try:
        tmp = folder / (path.name + ".tmp")
        tmp.write_text(text, encoding="utf-8")
        os.chmod(tmp, 0o444)
        os.replace(tmp, path)
    finally:
        os.chmod(folder, 0o500)


def cmd_fold(_a) -> None:
    rulings = load_rulings()
    for section in ("crest", "lincoln"):
        path = MANIFESTS / f"{section}.json"
        m = fold_manifest(json.loads(path.read_text(encoding="utf-8")), rulings, section)
        path.write_text(json.dumps(m, indent=2) + "\n", encoding="utf-8")
    col_dir = data.DATA_DIR / data.COLLECTIONS["Stanton"]
    (csv_path,) = [p for p in col_dir.iterdir() if p.suffix.lower() == ".csv"]
    before = csv_path.read_text(encoding="utf-8-sig")
    after = fold_csv(before, rulings)
    if after != before:
        backup = CACHE / "stanton-truth-before-fold.csv"
        if not backup.exists():
            shutil.copy2(csv_path, backup)
        csv_path.write_text(after, encoding="utf-8")
    lock_path = data.DATA_DIR / data.LOCKED["SC0122"] / "lock.json"
    lock = fold_lock(json.loads(lock_path.read_text(encoding="utf-8")), rulings)
    _write_locked(lock_path, json.dumps(lock, indent=1, ensure_ascii=False))
    import seg_boxes as SB
    bad = SB.verify_box(str(data.DATA_DIR), data.LOCKED["SC0122"])
    if bad:
        raise SystemExit(f"SC0122 lock no longer verifies: {bad[:3]}")
    record = {"item": "W46.seg-truth-rescore", "answers": "W46.seg-truth-sheet answers-20261031.csv",
              "rulings": [{k: r.get(k) for k in ("id", "section", "left", "right", "current", "stratum", "answer")}
                          for r in rulings],
              "sc0122": sc0122(rulings, _strata())}
    RULINGS_JSON.write_text(json.dumps(record, indent=1) + "\n", encoding="utf-8")
    print(f"folded: Stanton {changes(rulings, 'stanton')[0]}, CREST {changes(rulings, 'crest')[0]}, "
          f"Lincoln {changes(rulings, 'lincoln')[0]}; unsure "
          f"{[u['id'] for s in ('crest', 'lincoln') for u in changes(rulings, s)[1]]}; SC0122 lock {lock_path.name}")


def cmd_sc0122(_a) -> None:
    print(json.dumps(sc0122(load_rulings(), _strata()), indent=1))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("fold").set_defaults(fn=cmd_fold)
    sub.add_parser("sc0122").set_defaults(fn=cmd_sc0122)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
