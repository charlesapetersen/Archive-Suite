"""Load the five ground-truth segmentation collections (W36.seg-bench).

The data lives in the gitignored ``Test Files/Ground Truth Segmentation/`` folder of the
PRIMARY checkout (override with ``SEGBENCH_DATA``). It is read only: nothing here writes
under it. Derived artefacts (OCR text, the compiled OCR helper, the model-response cache)
go under ``SEGBENCH_CACHE`` (default ``~/Library/Caches/ArchiveSuiteRehearsal/segbench``),
which is outside git, because the pages and their text are private.

Labels are the CSV's: ``Box``, ``Folder``, ``New``, ``Cont``.
"""
from __future__ import annotations

import csv
import hashlib
import json
import os
import re
import subprocess
import sys
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_DATA = Path("/Users/cp1/Claude/Archive Suite/ArchiveProcessor/Test Files/Ground Truth Segmentation")
DATA_DIR = Path(os.environ.get("SEGBENCH_DATA", DEFAULT_DATA))
CACHE_DIR = Path(os.environ.get(
    "SEGBENCH_CACHE", Path.home() / "Library/Caches/ArchiveSuiteRehearsal/segbench"))
HERE = Path(__file__).resolve().parent

LABELS = ("Box", "Folder", "New", "Cont")
PHOTO_LABELS = ("Box", "Folder")

# Collection key -> directory name. Dev and test are fixed by the plan (Part 2, "Splits").
COLLECTIONS = {
    "Dean": "Dean",
    "Deaver": "Deaver",
    "Herrnstein": "Herrnstein",
    "Stanton": "Stanton",
    "RG165": "RG 165 — War Department",
}
DEV = ("Dean", "Deaver", "Herrnstein")
TEST = ("Stanton", "RG165")

_IMAGE_EXT = {".jpg", ".jpeg"}
_LEADING_NUM = re.compile(r"^\s*(\d+)")


@dataclass
class Page:
    n: int                      # file number, 1-based, as in the CSV
    label: str                  # ground truth: Box / Folder / New / Cont
    path: Path | None           # the image, found by listing the directory
    captured: str | None = None  # EXIF capture time "YYYY:MM:DD HH:MM:SS", or None
    _text: str | None = field(default=None, repr=False)


@dataclass
class Collection:
    name: str
    directory: Path
    pages: list[Page]

    @property
    def labels(self) -> list[str]:
        return [p.label for p in self.pages]

    def text(self, i: int) -> str | None:
        """OCR text of page index i (0-based) from the cache, or None if not yet produced."""
        p = self.pages[i]
        if p._text is None:
            f = ocr_cache_path(self.name, p.n)
            if f.exists():
                p._text = f.read_text(encoding="utf-8")
        return p._text


def _norm(s: str) -> str:
    return unicodedata.normalize("NFC", s).strip()


def read_truth(csv_path: Path) -> list[tuple[int, str]]:
    """Rows of (file number, label); whitespace stripped, blank rows skipped, labels validated."""
    rows: list[tuple[int, str]] = []
    with open(csv_path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.reader(fh)
        header = next(reader)
        if [_norm(h) for h in header[:2]] != ["File Number", "Status"]:
            raise ValueError(f"{csv_path}: unexpected header {header!r}")
        for r in reader:
            if not r or all(not _norm(x) for x in r):
                continue
            num, label = _norm(r[0]), _norm(r[1]) if len(r) > 1 else ""
            if label not in LABELS:
                raise ValueError(f"{csv_path}: row {num}: unknown label {label!r}")
            rows.append((int(num), label))
    nums = [n for n, _ in rows]
    if nums != list(range(1, len(nums) + 1)):
        raise ValueError(f"{csv_path}: file numbers are not 1..N in order")
    return rows


def list_images(directory: Path) -> dict[int, Path]:
    """Map file number -> image path by listing the directory (names use an em-dash and a
    no-break space, so building them literally fails; extensions mix .JPG/.jpg/.jpeg)."""
    out: dict[int, Path] = {}
    for entry in os.listdir(directory):
        p = directory / entry
        if p.suffix.lower() not in _IMAGE_EXT or not p.is_file():
            continue
        m = _LEADING_NUM.match(unicodedata.normalize("NFKC", entry))
        if not m:
            continue
        n = int(m.group(1))
        if n in out:
            raise ValueError(f"{directory}: two images numbered {n}")
        out[n] = p
    return out


def exif_capture_time(path: Path) -> str | None:
    """EXIF creation time via ``sips -g creation``; None if sips is missing or reports none."""
    try:
        r = subprocess.run(["/usr/bin/sips", "-g", "creation", str(path)],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    for line in r.stdout.splitlines():
        line = line.strip()
        if line.startswith("creation:"):
            v = line.split(":", 1)[1].strip()
            return v if v and v != "<nil>" else None
    return None


def _exif_cache(name: str) -> Path:
    return CACHE_DIR / "exif" / f"{name}.json"


def load(name: str, with_exif: bool = True) -> Collection:
    if name not in COLLECTIONS:
        raise KeyError(f"unknown collection {name!r}; expected one of {list(COLLECTIONS)}")
    directory = DATA_DIR / COLLECTIONS[name]
    csvs = [p for p in directory.iterdir() if p.suffix.lower() == ".csv"]
    if len(csvs) != 1:
        raise ValueError(f"{directory}: expected one CSV, found {len(csvs)}")
    truth = read_truth(csvs[0])
    images = list_images(directory)
    missing = [n for n, _ in truth if n not in images]
    if missing:
        raise ValueError(f"{name}: no image for file numbers {missing[:10]}")
    pages = [Page(n=n, label=lab, path=images[n]) for n, lab in truth]
    if with_exif:
        cache = _exif_cache(name)
        times = json.loads(cache.read_text()) if cache.exists() else {}
        changed = False
        for p in pages:
            key = str(p.n)
            if key not in times:
                times[key] = exif_capture_time(p.path)
                changed = True
            p.captured = times[key]
        if changed:
            cache.parent.mkdir(parents=True, exist_ok=True)
            cache.write_text(json.dumps(times, indent=0))
    return Collection(name=name, directory=directory, pages=pages)


def load_all(names=None, with_exif: bool = True) -> dict[str, Collection]:
    return {n: load(n, with_exif=with_exif) for n in (names or COLLECTIONS)}


# --- OCR text cache --------------------------------------------------------------------

def ocr_cache_path(name: str, n: int) -> Path:
    return CACHE_DIR / "ocr" / name / f"{n}.txt"


OCR_BIN = CACHE_DIR / "bin" / "segbench-ocr"


def build_ocr_tool() -> Path | None:
    """Compile ocr.swift once (rebuilt if the source is newer). None if swiftc fails."""
    src = HERE / "ocr.swift"
    if OCR_BIN.exists() and OCR_BIN.stat().st_mtime >= src.stat().st_mtime:
        return OCR_BIN
    OCR_BIN.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(["/usr/bin/swiftc", "-O", str(src), "-o", str(OCR_BIN)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(f"swiftc failed; falling back to Gemini snippets:\n{r.stderr}\n")
        return None
    return OCR_BIN


def run_ocr(names=None) -> dict[str, int]:
    """Produce Apple Vision text for every page not yet cached. Returns pages cached per collection."""
    tool = build_ocr_tool()
    if tool is None:
        return {}
    jobs = CACHE_DIR / "ocr" / "jobs.tsv"
    jobs.parent.mkdir(parents=True, exist_ok=True)
    cols = load_all(names, with_exif=False)
    with open(jobs, "w", encoding="utf-8") as fh:
        for c in cols.values():
            for p in c.pages:
                fh.write(f"{p.path}\t{ocr_cache_path(c.name, p.n)}\n")
    subprocess.run([str(tool), str(jobs)], check=False)
    return {c.name: sum(ocr_cache_path(c.name, p.n).exists() for p in c.pages) for c in cols.values()}


_GEMINI_FILES = {"Dean": "Dean_results.json", "Deaver": "Deaver_results.json",
                 "Herrnstein": "Herrnstein_results.json", "Stanton": "Stanton_results.json",
                 "RG165": "RG165_results.json"}


def gemini_snippets(name: str) -> dict[int, str]:
    """Fallback text: the truncated OCR snippets saved by the March 2026 Gemini runs."""
    f = DATA_DIR / "test_results" / _GEMINI_FILES[name]
    if not f.exists():
        return {}
    return {r["file_num"]: r.get("ocr_snippet") or "" for r in json.loads(f.read_text())}


# --- the spring 2026 Gemini runs, from their saved outputs (W36.seg-base) ------------------
#
# segmentation_test.py (baseline), run_improved.py (improved_v1, the prompt the app ships) and
# run_improved_v2.py each saved, per collection, the label Gemini gave every page. All three sent
# the previous page's image and the last 200 characters of its text with each page
# (segmentation_test.py run_test), with gemini-3.1-flash-lite-preview. ``predicted`` is null when
# the call failed or the reply carried no tag; the app treats a missing classification as a
# document start (DocumentSegmenter: ``case .documentStart, .none``), so the bench does too and
# counts the page as the run's own failure.

SPRING_RUNS = {"baseline": "", "v1": "improved_v1", "v2": "improved_v2"}
_SPRING_LABEL = {"box_label": "Box", "folder_label": "Folder",
                 "document_start": "New", "document_continuation": "Cont"}


def spring_path(name: str, run: str) -> Path:
    return DATA_DIR / "test_results" / SPRING_RUNS[run] / _GEMINI_FILES[name]


def read_spring(path: Path, n_pages: int) -> tuple[list[str], list[int]]:
    """(labels, failed file numbers) from one saved spring result file. A failed or unparsed
    page gets ``New`` — what the app does with no classification — never the truth's label."""
    rows = json.loads(Path(path).read_text())
    by_num: dict[int, str | None] = {}
    for r in rows:
        n = int(r["file_num"])
        if n in by_num:
            raise ValueError(f"{path}: file {n} twice")
        p = r.get("predicted")
        if p is not None and p not in _SPRING_LABEL:
            raise ValueError(f"{path}: file {n}: unknown label {p!r}")
        by_num[n] = _SPRING_LABEL.get(p) if p is not None else None
    if sorted(by_num) != list(range(1, n_pages + 1)):
        raise ValueError(f"{path}: file numbers do not cover 1..{n_pages}")
    failed = [n for n in sorted(by_num) if by_num[n] is None]
    return [by_num[n] or "New" for n in range(1, n_pages + 1)], failed


def thumbnail(name: str, page: Page, max_px: int = 768) -> Path | None:
    """A downscaled JPEG of the page (``sips -Z``), made on first use under the cache, outside git."""
    out = CACHE_DIR / "thumbs" / str(max_px) / name / f"{page.n}.jpg"
    if out.exists():
        return out
    out.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(["/usr/bin/sips", "-Z", str(max_px), "-s", "format", "jpeg", str(page.path),
                        "--out", str(out)], capture_output=True, text=True)
    return out if r.returncode == 0 and out.exists() else None


# --- model-response cache (for later paid methods) ---------------------------------------

def response_cache_key(*parts) -> str:
    """Content hash over the request parts (model id, prompt text, image bytes or their hashes...)."""
    h = hashlib.sha256()
    for part in parts:
        b = part if isinstance(part, bytes) else json.dumps(part, sort_keys=True).encode()
        h.update(len(b).to_bytes(8, "big"))
        h.update(b)
    return h.hexdigest()


def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ResponseCache:
    """Every model response stored once by content hash, outside git. A cache hit never calls."""

    def __init__(self, namespace: str):
        self.dir = CACHE_DIR / "responses" / namespace

    def _path(self, key: str) -> Path:
        return self.dir / key[:2] / f"{key}.json"

    def get(self, key: str):
        p = self._path(key)
        return json.loads(p.read_text()) if p.exists() else None

    def put(self, key: str, value) -> None:
        p = self._path(key)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps(value))
        tmp.replace(p)

    def get_or_call(self, key: str, call):
        v = self.get(key)
        if v is None:
            v = call()
            self.put(key, v)
        return v


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "ocr":
        print(run_ocr(sys.argv[2:] or None))
    else:
        for c in load_all().values():
            from collections import Counter
            print(c.name, len(c.pages), dict(Counter(c.labels)),
                  "exif:", sum(p.captured is not None for p in c.pages))
