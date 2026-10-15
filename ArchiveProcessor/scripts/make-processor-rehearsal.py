#!/usr/bin/env python3
"""Build the Archive Processor REHEARSAL set (W40.c1): catalogue `Test Files/`, copy one ground-truth box.

`ArchiveProcessor/Test Files/` (gitignored, primary checkout only) holds the owner's test photographs:
loose collections and five collections with a segmentation ground-truth CSV (one row per photo:
Box / Folder / New / Cont). The bulk-OCR journey W40.d1 runs the real app over one of them and scores
the split against its CSV, and the live-capture journey W40.d5 feeds real photos through the emulator.
Neither may run on `Test Files/` itself: the Processor moves finished originals to the Trash.

This script, reading `Test Files/` only:
  1. writes CATALOGUE.tsv: every collection, its image count and size, its truth CSV (if any), the CSV's
     row count and label counts, and anything that does not line up (rows past the last image, blanks);
  2. copies the chosen collection's images and truth CSV with `ditto` (mtimes and xattrs kept) to
     ~/Library/Caches/ArchiveSuiteRehearsal/processor-set/<collection>/, then lists size+mtime+sha256 of
     every source file before and after the copy and proves them identical (Test Files untouched);
  3. writes MANIFEST.txt.

Default collection: "RG 165 — War Department", the smallest ground-truth box (113 photos, every one
labelled; Pixel 9 live capture). See verification/rehearsal.md for why, and for how the set reaches the VM.

Usage:  python3 ArchiveProcessor/scripts/make-processor-rehearsal.py [--collection NAME] [--test-files DIR]
"""
from __future__ import annotations

import argparse
import collections
import csv
import datetime as dt
import hashlib
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE_ROOT = os.path.expanduser("~/Library/Caches/ArchiveSuiteRehearsal")
DEST_ROOT = os.path.join(CACHE_ROOT, "processor-set")
IMG_EXT = {".jpg", ".jpeg", ".png", ".heic", ".tif", ".tiff"}
DEFAULT = "RG 165 — War Department"


def default_test_files() -> str:
    """`Test Files/` lives only in the primary checkout (gitignored), so a worktree looks there."""
    here = os.path.normpath(os.path.join(HERE, "..", "Test Files"))
    if os.path.isdir(here):
        return here
    common = subprocess.run(["git", "-C", HERE, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True).stdout.strip()
    return os.path.join(os.path.dirname(common), "ArchiveProcessor", "Test Files")


def images(d: str):
    return sorted(n for n in os.listdir(d) if os.path.splitext(n)[1].lower() in IMG_EXT and not n.startswith("."))


def truth_csv(d: str):
    c = sorted(n for n in os.listdir(d) if n.lower().endswith(".csv"))
    return os.path.join(d, c[0]) if c else None


def read_truth(path: str):
    with open(path, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.reader(f))
    return rows[0], rows[1:]


def collections_in(tf: str):
    """Every folder holding images, one level down or (for Ground Truth Segmentation) two."""
    out = []
    for top in sorted(os.listdir(tf)):
        p = os.path.join(tf, top)
        if not os.path.isdir(p) or top.startswith("."):
            continue
        subs = [s for s in sorted(os.listdir(p)) if os.path.isdir(os.path.join(p, s))
                and not s.startswith((".", "_")) and images(os.path.join(p, s))]
        if subs and not images(p):
            out += [(f"{top}/{s}", os.path.join(p, s)) for s in subs]
        else:
            out.append((top, p))
    return out


def catalogue(tf: str):
    rows = []
    for name, p in collections_in(tf):
        imgs = images(p)
        size = sum(os.path.getsize(os.path.join(p, n)) for n in imgs)
        other = [n for n in os.listdir(p) if not n.startswith(".") and n not in imgs
                 and os.path.isfile(os.path.join(p, n)) and not n.lower().endswith(".csv")]
        c = truth_csv(p)
        csv_name = labels = notes = ""
        nrows = ""
        if c:
            header, body = read_truth(c)
            csv_name = os.path.basename(c)
            filled = [r for r in body if len(r) > 1 and r[1].strip()]
            nrows = str(len(filled))
            labels = " ".join(f"{k}={v}" for k, v in sorted(collections.Counter(r[1].strip() for r in filled).items()))
            issues = []
            if len(body) != len(filled):
                issues.append(f"{len(body) - len(filled)} rows with no label")
            if header[:2] != ["File Number", "Status"]:
                issues.append(f"header {header[:2]} (not a Box/Folder/New/Cont segmentation truth)")
            elif len(filled) != len(imgs):
                issues.append(f"{len(filled)} labelled rows for {len(imgs)} images")
            notes = "; ".join(issues)
        if other:
            notes = "; ".join(x for x in [notes, f"{len(other)} non-image files ({other[0]}…)"] if x)
        rows.append((name, str(len(imgs)), f"{size / 1048576:.0f} MiB", csv_name, nrows, labels, notes))
    return rows


def listing(d: str, names):
    out = []
    for n in names:
        p = os.path.join(d, n)
        st = os.stat(p)
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        out.append(f"{n}\t{st.st_size}\t{int(st.st_mtime)}\t{h.hexdigest()}")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--collection", default=DEFAULT, help="a leaf folder name under Test Files")
    ap.add_argument("--test-files", default=None)
    a = ap.parse_args()
    tf = os.path.realpath(a.test_files or default_test_files())
    if not os.path.isdir(tf):
        sys.exit(f"make-processor-rehearsal: Test Files not found: {tf}")

    os.makedirs(DEST_ROOT, exist_ok=True)
    cat = catalogue(tf)
    with open(os.path.join(DEST_ROOT, "CATALOGUE.tsv"), "w", encoding="utf-8") as f:
        f.write("collection\timages\tsize\ttruth csv\tlabelled rows\tlabels\tnotes\n")
        for r in cat:
            f.write("\t".join(r) + "\n")

    matches = [p for name, p in collections_in(tf) if os.path.basename(p) == a.collection]
    if len(matches) != 1:
        sys.exit(f"make-processor-rehearsal: collection {a.collection!r} matched {len(matches)} folders")
    src = matches[0]
    c = truth_csv(src)
    names = images(src) + ([os.path.basename(c)] if c else [])
    dest = os.path.join(DEST_ROOT, a.collection)
    real = os.path.realpath(os.path.dirname(dest))
    if real != os.path.realpath(DEST_ROOT) or os.path.realpath(src).startswith(os.path.realpath(DEST_ROOT)):
        sys.exit(f"make-processor-rehearsal: REFUSING — unexpected destination {dest}")

    before = listing(src, names)
    if os.path.exists(dest):
        shutil.rmtree(dest)
    os.makedirs(dest)
    for n in names:
        subprocess.run(["/usr/bin/ditto", os.path.join(src, n), os.path.join(dest, n)], check=True)
    after = listing(src, names)
    copy = listing(dest, names)
    untouched = before == after
    faithful = [l.split("\t")[3] for l in before] == [l.split("\t")[3] for l in copy]
    for fname, rows in (("before.tsv", before), ("after.tsv", after), ("copy.tsv", copy)):
        with open(os.path.join(dest, "..", f"{a.collection}.{fname}"), "w", encoding="utf-8") as f:
            f.write("name\tsize\tmtime\tsha256\n" + "\n".join(rows) + "\n")

    header, body = read_truth(c) if c else ([], [])
    labels = collections.Counter(r[1].strip() for r in body if len(r) > 1 and r[1].strip())
    now = dt.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
    lines = [
        "Archive Suite rehearsal set: Archive Processor ground-truth box (W40.c1)",
        "",
        f"What: a copy of Test Files/{os.path.relpath(src, tf)}: {len(names) - (1 if c else 0)} photographs and"
        f" its segmentation truth ({os.path.basename(c) if c else 'none'}),",
        "      for the bulk-OCR journey W40.d1 (score the split into documents against the CSV) and as real",
        "      images for the live-capture journey W40.d5. It is a COPY: the Processor trashes finished",
        "      originals, which is why no journey may point it at Test Files.",
        f"Set:  {dest}",
        f"Truth labels: {' '.join(f'{k}={v}' for k, v in sorted(labels.items()))}"
        "  (Box = box-label photo, Folder = folder-label photo,",
        "      New = first page of a document, Cont = a continuation page; File Number = the photo's number).",
        "      Stanton and RG 165 are the segmentation bench's TEST collections (execution-plans/segmentation/",
        "      00-plan.md): a journey may score the shipped method on it, but nothing may be tuned on it.",
        "",
        f"Made: {now} by ArchiveProcessor/scripts/make-processor-rehearsal.py --collection {a.collection!r}",
        f"Source: {src}",
        f"Source untouched: {'YES' if untouched else 'NO — see before.tsv / after.tsv'}"
        f" (size, mtime and sha256 of all {len(names)} files listed before and after the copy)",
        f"Copy faithful: {'YES' if faithful else 'NO — see copy.tsv'} (sha256 of every copied file matches)",
        "",
        "CATALOGUE.tsv beside this file lists every collection in Test Files.",
    ]
    with open(os.path.join(DEST_ROOT, "MANIFEST.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(dest)
    if not (untouched and faithful):
        sys.exit(1)


if __name__ == "__main__":
    main()
