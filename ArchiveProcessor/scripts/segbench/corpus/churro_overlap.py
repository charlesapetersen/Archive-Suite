#!/usr/bin/env python3
"""W46.ocr-churro-overlap (OCR-15): page-level image-hash overlap between CHURRO-DS test and the 895 public set.

Downloads the three public `stanford-oval/churro-dataset` test parquet shards one at a time into a
temporary directory, computes byte SHA-256, decoded-pixel SHA-256, 64-bit full dHash, 256-bit interior
dHash (5% margin crop) and 64x64 interior grayscale Pearson correlation for every page, compares against
all 895 frozen public bench pages on disk, deletes each shard immediately after processing, and writes
committed JSON + Markdown reports.
"""
import argparse
import hashlib
import io
import json
import math
import re
import subprocess
import tempfile
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
RESULTS = REPO / "ArchiveProcessor" / "segbench-results" / "bench-corpus"
MANIFEST = RESULTS / "manifest.jsonl"
MANIFEST_440 = RESULTS / "manifest-reference-440.jsonl"
PAGES_CACHE = Path.home() / "Library" / "Caches" / "ArchiveSuiteRehearsal" / "bench-corpus" / "pages"
OUT_JSON = RESULTS / "churro-overlap.json"
OUT_MD = RESULTS / "churro-overlap.md"
HF_PARQUET_API = "https://huggingface.co/api/datasets/stanford-oval/churro-dataset/parquet"
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".webp"}
MATCH_PRIORITY = {"exact_bytes": 0, "exact_pixels": 1, "perceptual": 2}

# Known corpus-level mapping between our 895 bench sources and CHURRO-DS dataset_id values
# (used only for an independent filename-overlap audit, never to restrict image hashing).
SOURCE_TO_CHURRO_DATASETS = {
    "bentham": {"icdar2015"},
    "biblia": {"biblia"},
    "castilian": {"castilian"},
    "devanagari": {"devanagari"},
    "eparchos": {"eparchos"},
    "iforal": {"iforal"},
    "koenigsfelden": {"charters"},
    "muharaf": {"muharaf"},
    "ocrd": {"ocrd"},
    "read2017": {"icdar2017", "reid2017"},
    "tapus": {"tapus"},
    "voc": {"voc"},
}


def _dhash(gray_im, cols, rows):
    pix = gray_im.resize((cols + 1, rows), Image.Resampling.LANCZOS).tobytes()
    h = 0
    stride = cols + 1
    for r in range(rows):
        off = r * stride
        for c in range(cols):
            h = (h << 1) | (1 if pix[off + c] > pix[off + c + 1] else 0)
    return h


def image_fingerprints(raw_bytes):
    """Return exact byte/pixel hashes, 64-bit full dHash, 256-bit interior dHash, and 64x64 interior vector."""
    byte_sha = hashlib.sha256(raw_bytes).hexdigest()
    with Image.open(io.BytesIO(raw_bytes)) as im:
        im.load()
        w, h = im.size
        rgb = im.convert("RGB")
        pixel_sha = hashlib.sha256(rgb.tobytes()).hexdigest()
        gray = rgb.convert("L")
        dhash64 = _dhash(gray, 8, 8)
        # Crop 5% border on each side so dark scan frames never inflate similarity across unrelated pages.
        dx, dy = max(0, int(round(w * 0.05))), max(0, int(round(h * 0.05)))
        interior = gray.crop((dx, dy, max(dx + 1, w - dx), max(dy + 1, h - dy)))
        dhash256 = _dhash(interior, 16, 16)
        vec64 = list(interior.resize((64, 64), Image.Resampling.LANCZOS).tobytes())
    return {
        "byte_sha256": byte_sha,
        "pixel_sha256": pixel_sha,
        "dhash64": dhash64,
        "dhash256": dhash256,
        "vec64": vec64,
        "size": [w, h],
    }


def hamming(a, b):
    return (a ^ b).bit_count()


def pearson_r(v1, v2):
    n = len(v1)
    m1 = sum(v1) / n
    m2 = sum(v2) / n
    num = sum((a - m1) * (b - m2) for a, b in zip(v1, v2))
    d1 = math.sqrt(sum((a - m1) ** 2 for a in v1))
    d2 = math.sqrt(sum((b - m2) ** 2 for b in v2))
    if d1 == 0 or d2 == 0:
        return 0.0
    return num / (d1 * d2)


def classify_match(ch_fp, bench_fp):
    """Classify match kind between a CHURRO-DS page and a bench-corpus page, or None if not a candidate."""
    if ch_fp["byte_sha256"] == bench_fp["byte_sha256"]:
        return "exact_bytes", 0, 0, 1.0
    if ch_fp["pixel_sha256"] == bench_fp["pixel_sha256"]:
        return "exact_pixels", 0, 0, 1.0
    dh64 = hamming(ch_fp["dhash64"], bench_fp["dhash64"])
    dh256 = hamming(ch_fp["dhash256"], bench_fp["dhash256"])
    if dh64 <= 8 or dh256 <= 44:
        r = pearson_r(ch_fp["vec64"], bench_fp["vec64"])
        # Confirmed same-page perceptual match: tight 64-bit and 256-bit interior dHash + near-identical interior pixels.
        if dh64 <= 4 and dh256 <= 24 and r >= 0.985:
            return "perceptual", dh64, dh256, round(r, 4)
        if dh64 <= 6 or dh256 <= 36 or r >= 0.95:
            return "borderline", dh64, dh256, round(r, 4)
    return None


def norm_stem(text):
    stem = Path(str(text)).stem
    return re.sub(r"[^a-z0-9]+", "_", stem.lower()).strip("_")


def index_bench_pages(manifest_path=MANIFEST, manifest_440_path=MANIFEST_440, pages_root=PAGES_CACHE):
    manifest = [json.loads(line) for line in manifest_path.read_text().splitlines() if line.strip()]
    ref440 = {
        (m["source"], m["page_id"])
        for m in (json.loads(line) for line in manifest_440_path.read_text().splitlines() if line.strip())
    }
    sha_to_path = {}
    for p in pages_root.rglob("*"):
        if p.is_file() and p.suffix.lower() in IMAGE_EXTS:
            h = hashlib.sha256(p.read_bytes()).hexdigest()
            sha_to_path[h] = p

    records = []
    missing = []
    for m in manifest:
        p = sha_to_path.get(m["image_sha256"])
        if p is None:
            missing.append((m["stratum"], m["source"], m["page_id"]))
            continue
        fp = image_fingerprints(p.read_bytes())
        records.append({
            "stratum": m["stratum"],
            "source": m["source"],
            "page_id": m["page_id"],
            "norm_id": norm_stem(m["page_id"]),
            "norm_full": re.sub(r"[^a-z0-9]+", "_", m["page_id"].lower()).strip("_"),
            "in_440": (m["source"], m["page_id"]) in ref440,
            "fp": fp,
        })
    if missing:
        raise RuntimeError(f"missing {len(missing)} bench-corpus page images on disk, e.g. {missing[:3]}")
    return records


def fetch_test_shard_urls():
    raw = subprocess.check_output(["curl", "-fsSL", HF_PARQUET_API], text=True)
    data = json.loads(raw)
    urls = data["default"]["test"]
    if not urls:
        raise RuntimeError("no test shards returned by HuggingFace parquet API")
    return urls


def extract_row_image_bytes(img_cell):
    if isinstance(img_cell, dict):
        b = img_cell.get("bytes")
        if b is not None:
            return bytes(b)
    if isinstance(img_cell, (bytes, bytearray)):
        return bytes(img_cell)
    raise ValueError(f"unsupported image cell type: {type(img_cell)}")


def match_records(churro_iter, bench_records):
    """Compare an iterable of (row_meta, fp) CHURRO-DS pages against bench_records."""
    by_byte = {r["fp"]["byte_sha256"]: r for r in bench_records}
    by_pixel = {r["fp"]["pixel_sha256"]: r for r in bench_records}
    confirmed = []
    borderline = []
    filename_only_hits = []
    churro_datasets = Counter()
    churro_total = 0

    for meta, ch_fp in churro_iter:
        churro_total += 1
        ds_id = str(meta.get("dataset_id") or meta.get("source") or meta.get("corpus") or "unknown")
        fname = str(meta.get("file_name") or "")
        ch_norm = norm_stem(fname)
        churro_datasets[ds_id] += 1

        matched_bench_keys = set()
        exact_hit = by_byte.get(ch_fp["byte_sha256"]) or by_pixel.get(ch_fp["pixel_sha256"])
        if exact_hit is not None:
            kind = "exact_bytes" if exact_hit["fp"]["byte_sha256"] == ch_fp["byte_sha256"] else "exact_pixels"
            matched_bench_keys.add((exact_hit["stratum"], exact_hit["source"], exact_hit["page_id"]))
            confirmed.append({
                "match_kind": kind,
                "dhash64_dist": 0,
                "dhash256_dist": 0,
                "interior_r": 1.0,
                "churro_index": meta["index"],
                "churro_dataset_id": ds_id,
                "churro_file_name": fname,
                "churro_size": ch_fp["size"],
                "bench_stratum": exact_hit["stratum"],
                "bench_source": exact_hit["source"],
                "bench_page_id": exact_hit["page_id"],
                "bench_in_440": exact_hit["in_440"],
                "bench_size": exact_hit["fp"]["size"],
            })
            continue

        best = None
        for br in bench_records:
            res = classify_match(ch_fp, br["fp"])
            if res is not None:
                kind, dh64, dh256, r_val = res
                cand = (kind != "perceptual", dh256, dh64, -r_val, kind, dh64, dh256, r_val, br)
                if best is None or cand[:4] < best[:4]:
                    best = cand
            # Independent filename audit on known shared corpora to catch any cropped/rotated false negatives.
            if ds_id in SOURCE_TO_CHURRO_DATASETS.get(br["source"], ()) and ch_norm and len(ch_norm) >= 4:
                if ch_norm == br["norm_id"] or ch_norm == br["norm_full"]:
                    dh64 = hamming(ch_fp["dhash64"], br["fp"]["dhash64"])
                    dh256 = hamming(ch_fp["dhash256"], br["fp"]["dhash256"])
                    r_val = round(pearson_r(ch_fp["vec64"], br["fp"]["vec64"]), 4)
                    filename_only_hits.append({
                        "churro_index": meta["index"],
                        "churro_dataset_id": ds_id,
                        "churro_file_name": fname,
                        "bench_stratum": br["stratum"],
                        "bench_source": br["source"],
                        "bench_page_id": br["page_id"],
                        "dhash64_dist": dh64,
                        "dhash256_dist": dh256,
                        "interior_r": r_val,
                    })

        if best is not None:
            _, _, _, _, kind, dh64, dh256, r_val, br = best
            entry = {
                "match_kind": kind,
                "dhash64_dist": dh64,
                "dhash256_dist": dh256,
                "interior_r": r_val,
                "churro_index": meta["index"],
                "churro_dataset_id": ds_id,
                "churro_file_name": fname,
                "churro_size": ch_fp["size"],
                "bench_stratum": br["stratum"],
                "bench_source": br["source"],
                "bench_page_id": br["page_id"],
                "bench_in_440": br["in_440"],
                "bench_size": br["fp"]["size"],
            }
            if kind == "perceptual":
                matched_bench_keys.add((br["stratum"], br["source"], br["page_id"]))
                confirmed.append(entry)
            else:
                borderline.append(entry)

    # Keep only filename-audit hits that were NOT already confirmed by image hashing.
    confirmed_pairs = {(m["churro_index"], m["bench_source"], m["bench_page_id"]) for m in confirmed}
    unmatched_filename_hits = [
        h for h in filename_only_hits
        if (h["churro_index"], h["bench_source"], h["bench_page_id"]) not in confirmed_pairs
    ]
    return churro_total, churro_datasets, confirmed, borderline, unmatched_filename_hits


def stream_churro_test_shards(shard_urls):
    import pyarrow.parquet as pq

    idx = 0
    with tempfile.TemporaryDirectory(prefix="churro-test-shard-") as tmp:
        tmp_dir = Path(tmp)
        for shard_i, url in enumerate(shard_urls):
            shard_path = tmp_dir / f"test-{shard_i}.parquet"
            print(f"[churro-overlap] downloading shard {shard_i + 1}/{len(shard_urls)}: {url}", flush=True)
            subprocess.run(["curl", "-fsSL", "-o", str(shard_path), url], check=True)
            try:
                pf = pq.ParquetFile(shard_path)
                cols = set(pf.schema_arrow.names)
                img_col = "image" if "image" in cols else ("bytes" if "bytes" in cols else None)
                if img_col is None:
                    raise RuntimeError(f"no 'image'/'bytes' column in {shard_path.name}; cols={sorted(cols)}")
                meta_cols = [c for c in ("dataset_id", "example_id", "path", "file_name", "source", "corpus", "document_type", "main_language", "main_script") if c in cols]
                read_cols = [img_col, *meta_cols]
                for batch in pf.iter_batches(batch_size=64, columns=read_cols):
                    py = batch.to_pydict()
                    n = len(py[img_col])
                    for j in range(n):
                        cell = py[img_col][j]
                        raw = extract_row_image_bytes(cell)
                        fp = image_fingerprints(raw)
                        meta = {"index": idx}
                        for c in meta_cols:
                            meta[c] = py[c][j]
                        if not meta.get("file_name"):
                            img_path = cell.get("path") if isinstance(cell, dict) else ""
                            meta["file_name"] = img_path or meta.get("path") or meta.get("example_id") or ""
                        yield meta, fp
                        idx += 1
            finally:
                shard_path.unlink(missing_ok=True)
                print(f"[churro-overlap] processed and deleted shard {shard_i + 1}/{len(shard_urls)} (total rows so far: {idx})", flush=True)


def summarise(churro_total, churro_datasets, confirmed, borderline, unmatched_filename_hits, bench_records, shard_urls):
    # Keep the highest-priority match per unique bench page (exact_bytes > exact_pixels > perceptual).
    unique_bench = {}
    for m in sorted(confirmed, key=lambda x: (MATCH_PRIORITY[x["match_kind"]], x["dhash256_dist"], -x["interior_r"])):
        k = (m["bench_stratum"], m["bench_source"], m["bench_page_id"])
        if k not in unique_bench:
            unique_bench[k] = m

    by_stratum = defaultdict(lambda: {"bench_pages": 0, "overlap_pages": 0, "exact_bytes": 0, "exact_pixels": 0, "perceptual": 0})
    by_source = defaultdict(lambda: {"bench_pages": 0, "overlap_pages": 0, "strata": set()})
    for br in bench_records:
        by_stratum[br["stratum"]]["bench_pages"] += 1
        by_source[br["source"]]["bench_pages"] += 1
        by_source[br["source"]]["strata"].add(br["stratum"])
    for m in unique_bench.values():
        st = m["bench_stratum"]
        by_stratum[st]["overlap_pages"] += 1
        by_stratum[st][m["match_kind"]] += 1
        by_source[m["bench_source"]]["overlap_pages"] += 1

    overlap_440 = sum(1 for m in unique_bench.values() if m["bench_in_440"])
    overlap_455 = sum(1 for m in unique_bench.values() if not m["bench_in_440"])
    kind_counts = Counter(m["match_kind"] for m in unique_bench.values())

    return {
        "generated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "dataset": "stanford-oval/churro-dataset",
        "split": "test",
        "shard_urls": shard_urls,
        "churro_test_pages": churro_total,
        "bench_pages": len(bench_records),
        "bench_440_pages": sum(1 for r in bench_records if r["in_440"]),
        "bench_455_pages": sum(1 for r in bench_records if not r["in_440"]),
        "overlap_unique_bench_pages": len(unique_bench),
        "overlap_in_440": overlap_440,
        "overlap_in_455": overlap_455,
        "overlap_by_match_kind": {
            "exact_bytes": kind_counts.get("exact_bytes", 0),
            "exact_pixels": kind_counts.get("exact_pixels", 0),
            "perceptual": kind_counts.get("perceptual", 0),
        },
        "borderline_candidates": len(borderline),
        "unmatched_same_corpus_filename_hits": unmatched_filename_hits,
        "thresholds": {
            "perceptual": "dhash64 <= 4 and dhash256_interior <= 24 and interior_r >= 0.985 (5% border crop)",
            "borderline": "dhash64 <= 6 or dhash256_interior <= 36 or interior_r >= 0.95, below confirmed threshold",
        },
        "by_stratum": {k: dict(v) for k, v in sorted(by_stratum.items())},
        "by_source": {k: {**v, "strata": sorted(v["strata"])} for k, v in sorted(by_source.items())},
        "churro_test_datasets": dict(sorted(churro_datasets.items(), key=lambda kv: (-kv[1], kv[0]))),
        "matches": sorted(unique_bench.values(), key=lambda m: (m["bench_stratum"], m["bench_source"], m["bench_page_id"])),
        "borderline_top20": sorted(borderline, key=lambda m: (m["dhash256_dist"], -m["interior_r"]))[:20],
    }


def render_markdown(report):
    lines = [
        "# CHURRO-DS test overlap with the 895 public set (`W46.ocr-churro-overlap`)",
        "",
        f"Measured {report['generated_utc'][:10]} against `stanford-oval/churro-dataset` (`test` split, "
        f"{report['churro_test_pages']:,} pages across {len(report['shard_urls'])} Parquet shards) and all "
        f"{report['bench_pages']} frozen public bench pages (`manifest.jsonl`).",
        "",
        "## Headline",
        "",
        f"- **Confirmed page-level overlap with CHURRO-DS test:** **{report['overlap_unique_bench_pages']} of {report['bench_pages']}** "
        f"public pages ({report['overlap_in_440']} of {report['bench_440_pages']} in the original 440 reference set; "
        f"{report['overlap_in_455']} of {report['bench_455_pages']} in the 455 added pages).",
        f"- **Match breakdown:** {report['overlap_by_match_kind']['exact_bytes']} exact byte SHA-256, "
        f"{report['overlap_by_match_kind']['exact_pixels']} exact decoded-pixel SHA-256, "
        f"{report['overlap_by_match_kind']['perceptual']} perceptual hash matches (`{report['thresholds']['perceptual']}`).",
        f"- **Same-corpus filename audit (unmatched by hash):** {len(report['unmatched_same_corpus_filename_hits'])} "
        "(checks that no cropped or rotated duplicate from a shared corpus was missed by pixel hashing).",
        f"- **Borderline candidates below threshold:** {report['borderline_candidates']}.",
        "- **Why both CHURRO-3B and Gemini carry this note (OCR-15):** CHURRO-DS's truths were cleaned with Gemini 2.5 Pro "
        "and CHURRO-3B was trained on CHURRO-DS's train split drawn from the same source corpora (with random page splits, "
        "not corpus-disjoint splits). Page-level overlap with CHURRO-DS `test` measures direct image collisions with the "
        "published benchmark test split; corpus-level overlap with CHURRO-3B's training split remains broader (including "
        "READ 2017 in L6, Bentham/ICDAR2015 in L2, Devanagari in N6, BiblIA in N4, EPARCHOS in N3, Muharaf in N1 and "
        "Tapus in L3 alongside Königsfelden, iForal, Castilian, VOC and OCR-D).",
        "",
        "## Overlap by stratum",
        "",
        "| Stratum | Bench pages | CHURRO-DS test overlap | Exact bytes | Exact pixels | Perceptual |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for st, row in report["by_stratum"].items():
        lines.append(
            f"| {st} | {row['bench_pages']} | {row['overlap_pages']} | "
            f"{row['exact_bytes']} | {row['exact_pixels']} | {row['perceptual']} |"
        )
    lines += [
        "",
        "## Overlap by bench source",
        "",
        "| Source | Strata | Bench pages | CHURRO-DS test overlap |",
        "|---|---|---:|---:|",
    ]
    for src, row in report["by_source"].items():
        lines.append(f"| {src} | {', '.join(row['strata'])} | {row['bench_pages']} | {row['overlap_pages']} |")
    if report["matches"]:
        lines += [
            "",
            "## Matched pages",
            "",
            "| Stratum | Bench source | Bench page | In 440 | Match kind | dHash64 | dHash256 | Interior r | CHURRO dataset_id | CHURRO file_name |",
            "|---|---|---|---|---|---:|---:|---:|---|---|",
        ]
        for m in report["matches"]:
            lines.append(
                f"| {m['bench_stratum']} | {m['bench_source']} | `{m['bench_page_id']}` | "
                f"{'yes' if m['bench_in_440'] else 'no'} | {m['match_kind']} | {m['dhash64_dist']} | "
                f"{m['dhash256_dist']} | {m['interior_r']:.4f} | `{m['churro_dataset_id']}` | `{m['churro_file_name']}` |"
            )
    if report["borderline_top20"]:
        lines += [
            "",
            "## Closest borderline candidates (not counted as matches)",
            "",
            "| Stratum | Bench source | Bench page | dHash64 | dHash256 | Interior r | CHURRO dataset_id | CHURRO file_name |",
            "|---|---|---|---:|---:|---:|---|---|",
        ]
        for m in report["borderline_top20"][:10]:
            lines.append(
                f"| {m['bench_stratum']} | {m['bench_source']} | `{m['bench_page_id']}` | "
                f"{m['dhash64_dist']} | {m['dhash256_dist']} | {m['interior_r']:.4f} | `{m['churro_dataset_id']}` | `{m['churro_file_name']}` |"
            )
    lines += [
        "",
        "## Measurement card",
        "",
        "- **Truth:** Deterministic image hashing (byte SHA-256, decoded RGB pixel SHA-256, 64-bit full dHash, "
        "256-bit interior dHash and 64x64 interior grayscale Pearson correlation with a 5% border crop), plus an "
        "independent same-corpus filename audit. No model calls, no human adjudication required.",
        "- **Selection:** Exhaustive comparison of all 1,170 rows of `stanford-oval/churro-dataset` (`test` split) "
        "against all 895 frozen pages of `bench-corpus/manifest.jsonl` (matched 895/895 by `image_sha256`).",
        "- **Comparison:** Every page compared directly in pixel space regardless of file format or resize.",
        "- **Noise:** Deterministic (zero sampling variance). Perceptual threshold (`dhash64 <= 4, dhash256 <= 24, "
        "interior_r >= 0.985`) is audited by logging the closest borderline candidates and checking same-corpus filenames.",
        "- **Scope:** Measures overlap with CHURRO-DS `test` only (not CHURRO-DS `train` or `dev`, which has 101 "
        "shards). Zero overlap with `test` does not rule out source-corpus training overlap with CHURRO-DS `train`, "
        "which is reported separately in `specialists.md`.",
        "",
    ]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out-json", type=Path, default=OUT_JSON)
    ap.add_argument("--out-md", type=Path, default=OUT_MD)
    args = ap.parse_args()

    print("[churro-overlap] indexing 895 bench-corpus pages...", flush=True)
    bench_records = index_bench_pages()
    print(f"[churro-overlap] indexed {len(bench_records)} bench pages", flush=True)
    shard_urls = fetch_test_shard_urls()
    churro_total, churro_datasets, confirmed, borderline, unmatched_fn = match_records(
        stream_churro_test_shards(shard_urls), bench_records
    )
    report = summarise(churro_total, churro_datasets, confirmed, borderline, unmatched_fn, bench_records, shard_urls)
    args.out_json.write_text(json.dumps(report, indent=2) + "\n")
    args.out_md.write_text(render_markdown(report))
    print(
        f"[churro-overlap] DONE: {report['churro_test_pages']} CHURRO-DS test pages vs {report['bench_pages']} bench pages -> "
        f"{report['overlap_unique_bench_pages']} confirmed overlaps ({report['overlap_in_440']} in 440, {report['overlap_in_455']} in 455), "
        f"unmatched_filename_hits={len(unmatched_fn)}, borderline={report['borderline_candidates']}",
        flush=True,
    )


if __name__ == "__main__":
    main()
