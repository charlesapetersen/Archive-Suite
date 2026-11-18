#!/usr/bin/env python3
"""W46.layout-newspapers: newspaper region coverage, from numeric caches only.

  python3 ArchiveProcessor/scripts/segbench/layout_coverage_fallback.py

No detector, OCR, image decode, transcription scoring or network. The L9 page ids,
Vision line rectangles and PP-DocLayoutV3 rectangles are the existing layout-photo
and layout-order caches. Text fields are ignored and never written to the results.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import statistics
from pathlib import Path

HERE = Path(__file__).resolve().parent
CACHE = Path(os.environ.get("ARCHIVE_BENCH_CACHE", Path.home() / "Library/Caches/ArchiveSuiteRehearsal"))
OUTPUT = HERE.parents[1] / "segbench-results/layout-coverage-fallback"
PAD = 0.004
MIN_SIDE = 32
FLOOR = 0.95
THRESHOLDS = (0.80, 0.85, 0.90, 0.95, 0.98)
EPSILON = 1e-9


def rectangle(box):
    """A finite, nonempty top-left [x0,y0,x1,y1] rectangle, clamped to the page."""
    if not isinstance(box, list) or len(box) != 4:
        raise ValueError("a cached rectangle has the wrong shape")
    if not all(isinstance(x, (int, float)) and math.isfinite(x) for x in box):
        raise ValueError("a cached rectangle is not finite")
    b = [max(0.0, min(1.0, float(x))) for x in box]
    return b if area(b) > 0 else None


def area(box):
    return max(0.0, box[2] - box[0]) * max(0.0, box[3] - box[1])


def intersection(a, b):
    return [max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])]


def union_area(boxes):
    """Exact rectangle-union area by x slabs and merged y intervals; no raster."""
    boxes = [b for b in boxes if area(b) > 0]
    xs = sorted({x for b in boxes for x in (b[0], b[2])})
    total = 0.0
    for left, right in zip(xs, xs[1:]):
        intervals = sorted((b[1], b[3]) for b in boxes if b[0] < right and b[2] > left)
        length, end = 0.0, -math.inf
        for lo, hi in intervals:
            length += max(0.0, hi - max(lo, end))
            end = max(end, hi)
        total += (right - left) * length
    return total


def crop_box(box, width, height):
    """regions_cluster.pixel_box: .004 pad, pixel rounding, 32px minimum, clamp.

    The cached layout-photo regions already converted the raw PP detector's
    [y0,x0,y1,x1] / 1000 output into top-left [x0,y0,x1,y1] page fractions
    (regions.boxes_pp); there is no second y flip here. Vision's cached boxes
    likewise already have a top-left origin (layout_order.swift).
    """
    px = [max(0, round((box[0] - PAD) * width)), max(0, round((box[1] - PAD) * height)),
          min(width, round((box[2] + PAD) * width)), min(height, round((box[3] + PAD) * height))]
    for lo, hi, size in ((0, 2, width), (1, 3, height)):
        if px[hi] - px[lo] < MIN_SIDE:
            centre = (px[lo] + px[hi]) / 2
            px[lo] = max(0, round(centre - MIN_SIDE / 2))
            px[hi] = min(size, px[lo] + MIN_SIDE)
            px[lo] = max(0, px[hi] - MIN_SIDE)
    return [px[0] / width, px[1] / height, px[2] / width, px[3] / height]


def measures(lines, crops):
    denominator = union_area(lines)
    if denominator <= 0:
        raise ValueError("a cached page has no usable Vision line area")
    covered = union_area([intersection(line, crop) for line in lines for crop in crops])
    shares = [min(1.0, max(0.0, union_area([intersection(line, crop) for crop in crops]) / area(line)))
              for line in lines]
    return {"coverage": min(1.0, max(0.0, covered / denominator)),
            "vision_line_union_area": denominator,
            "covered_vision_line_union_area": covered,
            "lines": len(lines),
            "fully_covered_lines": sum(x >= 1 - EPSILON for x in shares),
            "partially_covered_lines": sum(EPSILON < x < 1 - EPSILON for x in shares),
            "uncovered_lines": sum(x <= EPSILON for x in shares),
            "lines_under_80pct": sum(x < .8 for x in shares)}


def partition_measures(lines, crops, width, height):
    """The app's native-order partition and whole-line boundary guard, geometry only.

    A crop whose pixels have all appeared earlier is omitted (the app allows half
    a pixel of numerical slack). Earlier crop rectangles own overlapping pixels.
    A line split by its first crop is erased in all region reads and restored in
    the fill, together with every transitively overlapping Vision line. This
    measures the guard's decisions, not the accuracy of reading the partition.
    """
    kept = []
    for crop in crops:
        covered = union_area([intersection(crop, previous) for previous in kept])
        if covered < area(crop) - .5 / (width * height):
            kept.append(crop)
    seed = set()
    for i, line in enumerate(lines):
        first = next((crop for crop in kept if area(intersection(line, crop)) > 1e-12), None)
        if first is not None and area(intersection(line, first)) < area(line) - 1e-12:
            seed.add(i)
    # Connected components of positively intersecting line rectangles. The app
    # restores the complete component so moving a line cannot reintroduce pixels
    # belonging to a line another region still reads.
    selected = set(seed)
    pending = list(seed)
    while pending:
        current = pending.pop()
        for i, line in enumerate(lines):
            if i not in selected and area(intersection(line, lines[current])) > 0:
                selected.add(i)
                pending.append(i)
    coverage = measures(lines, kept)["coverage"] if lines else None
    low = coverage is not None and coverage < FLOOR
    return {"retained_regions": len(kept), "redundant_regions_omitted": len(crops) - len(kept),
            "coverage": coverage, "vision_unavailable": not lines,
            "initial_boundary_lines": len(seed), "boundary_lines_including_transitive": len(selected),
            "transitively_added_lines": len(selected - seed),
            "low_coverage_fill": low, "boundary_fill": bool(selected),
            "requires_fill": low or bool(selected) or not lines}


def stats(values):
    return {"minimum": min(values), "median": statistics.median(values),
            "mean": statistics.mean(values), "maximum": max(values)}


def analyse(cache):
    membership = cache / "layout-photo/pages.jsonl"
    region_path = cache / "layout-photo/regions/pp.json"
    vision_dir = cache / "layout-order/vision"
    # Nothing except membership/id is used from this manifest; image files are never opened.
    ids = [r["id"] for r in (json.loads(s) for s in membership.read_text().splitlines() if s.strip())
           if r.get("stratum") == "L9"]
    if len(ids) != 15 or len(set(ids)) != 15:
        raise ValueError("expected all 15 distinct frozen L9 page ids")
    regions = json.loads(region_path.read_text())["pages"]
    pages = []
    for pid in sorted(ids):
        vision = json.loads((vision_dir / f"{pid}.json").read_text())
        width, height = int(vision["width"]), int(vision["height"])
        if min(width, height) <= 0:
            raise ValueError(f"{pid}: invalid cached dimensions")
        # Discard text fields immediately; these measurements use only rectangles.
        lines = [b for row in vision["lines"] if (b := rectangle(row["box"])) is not None]
        detected = regions[pid]
        if (detected["w"], detected["h"]) != (width, height):
            raise ValueError(f"{pid}: detector and Vision caches have different dimensions")
        # Native order is semantically significant when the first crop owns any
        # overlap; Python's stable sort matches the app's input-offset tie break.
        ordered = sorted(detected["regions"], key=lambda row: row["order"])
        raw = [b for row in ordered if (b := rectangle(row["box"])) is not None]
        crops = [crop_box(b, width, height) for b in raw]
        pages.append({"page": pid, "width": width, "height": height,
                      "regions": len(crops), "detector_rectangles": measures(lines, raw),
                      "actual_crops": measures(lines, crops),
                      "app_partition": partition_measures(lines, crops, width, height)})
    summary = {}
    for variant in ("detector_rectangles", "actual_crops"):
        summary[variant] = {"coverage": stats([p[variant]["coverage"] for p in pages]),
                            "fully_covered_lines": sum(p[variant]["fully_covered_lines"] for p in pages),
                            "partially_covered_lines": sum(p[variant]["partially_covered_lines"] for p in pages),
                            "uncovered_lines": sum(p[variant]["uncovered_lines"] for p in pages),
                            "fill_counts": [{"threshold": t,
                                             "pages": sum(p[variant]["coverage"] < t for p in pages)}
                                            for t in THRESHOLDS]}
    app = [p["app_partition"] for p in pages]
    summary["app_partition"] = {
        "low_coverage_fill_pages": sum(p["low_coverage_fill"] for p in app),
        "boundary_fill_pages": sum(p["boundary_fill"] for p in app),
        "boundary_only_fill_pages": sum(p["boundary_fill"] and not p["low_coverage_fill"] for p in app),
        "both_boundary_and_low_coverage_pages": sum(p["boundary_fill"] and p["low_coverage_fill"] for p in app),
        "vision_unavailable_pages": sum(p["vision_unavailable"] for p in app),
        "requires_fill_pages": sum(p["requires_fill"] for p in app),
        "initial_boundary_lines": sum(p["initial_boundary_lines"] for p in app),
        "boundary_lines_including_transitive": sum(p["boundary_lines_including_transitive"] for p in app),
        "transitively_added_lines": sum(p["transitively_added_lines"] for p in app),
        "redundant_regions_omitted": sum(p["redundant_regions_omitted"] for p in app),
        "retained_region_counts": stats([p["retained_regions"] for p in app]),
    }
    return {"item": "W46.layout-newspapers", "pages": pages,
            "method": {"metric": "area(union(Vision line boxes) intersect union(crop boxes)) / area(union(Vision line boxes))",
                       "origin": "top-left", "boxes": "normalised [x0,y0,x1,y1]",
                       "picture_regions": "all labels kept; app partition omits only crops entirely covered by earlier crops",
                       "crop_padding": PAD, "crop_min_side_pixels": MIN_SIDE,
                       "crop_rounding": "nearest integer, ties to even, as regions_cluster.pixel_box",
                       "vision_lines": sum(p["actual_crops"]["lines"] for p in pages),
                       "threshold": FLOOR,
                       "threshold_status": "conservative engineering floor; OCR accuracy and optimal threshold untested",
                       "partition": "native order; first intersecting crop owns pixels; split lines and all transitively intersecting Vision lines move intact to fill",
                       "fill_conditions": "coverage below .95 OR boundary lines present OR Vision unavailable",
                       "partial_line_warning": "the app's whole-line guard addresses known Vision boxes split across crops; geometry alone does not establish OCR accuracy or protect writing Vision did not find",
                       "prior_694pct": "dark pixels below 128 at 1000px long side, 2% margin excluded, picture labels dropped; not Vision line-box coverage",
                       "sources": ["layout-photo/pages.jsonl", "layout-photo/regions/pp.json",
                                   "layout-order/vision/newsbench__*.json"],
                       "no_new_reading": "no model, image decode, transcription scoring, network or paid call"},
            "region_counts": stats([p["regions"] for p in pages]), "summary": summary}


def markdown(result):
    methods, summary = result["method"], result["summary"]
    lines = ["# W46.layout-newspapers — newspaper coverage and the fill floor", "",
             "Generated by `scripts/segbench/layout_coverage_fallback.py` from existing numerical caches. "
             "No model, image decode, transcription scoring, network or paid call.", "",
             "The **95% floor is a conservative engineering policy**, not a measured accuracy optimum. "
             "It asks for a whole-page fill when the detector crops cover under 95% of the union of Vision's "
             "line boxes. The app also fills whenever a Vision line crosses its first crop's boundary, "
             "or Vision is unavailable. These are geometry checks, not measurements of ink or OCR accuracy.", "",
             "## Inputs and method", "",
             f"All 15 L9 newspaper scans and their {methods['vision_lines']:,} cached Vision line boxes. "
             "PP-DocLayoutV3: its existing 1,024px / confidence 0.5 detection, all labels kept, "
             "pictures included. The coverage sweep includes every rectangle. The app partition keeps "
             "native detector order and omits only crops whose pixels are already covered by earlier crops.", "",
             "The detector's raw `[y0,x0,y1,x1] / 1000` output was already converted by `regions.boxes_pp` "
             "into the cache's top-left `[x0,y0,x1,y1]` fractions. Vision's cached rectangles also have a "
             "top-left origin. The script does not flip either again.", "",
             "Actual crops use `regions_cluster.pixel_box`: 0.004 page padding on each edge, rounded to "
             "pixels (nearest, ties to even), minimum 32px per side, clamped to the page. The numerator is "
             "the area of the intersection of the union of those crop rectangles with the union of the "
             "Vision line rectangles; the denominator is the Vision union's area. Exact rectangle union "
             "avoids counting overlapping lines or regions twice.", "",
             "| Geometry | Minimum | Median | Mean | Maximum |", "|---|---:|---:|---:|---:|"]
    names = {"detector_rectangles": "Detector rectangles", "actual_crops": "Actual padded pixel crops"}
    for variant, name in names.items():
        s = summary[variant]["coverage"]
        lines.append(f"| {name} | " + " | ".join(f"{s[k]:.2%}" for k in ("minimum", "median", "mean", "maximum")) + " |")
    rc = result["region_counts"]
    lines += ["", f"Regions per page: min {rc['minimum']}, median {rc['median']:g}, "
              f"mean {rc['mean']:.1f}, max {rc['maximum']}.", "", "## Threshold sensitivity", "",
              "This table isolates the coverage condition: strictly below the floor. A page at or above "
              "the floor still fills if the boundary guard applies (below).", "",
              "| Floor | Detector-rectangle pages below | Actual-crop pages below |", "|---|---:|---:|"]
    for unpadded, padded in zip(summary["detector_rectangles"]["fill_counts"], summary["actual_crops"]["fill_counts"], strict=True):
        lines.append(f"| {unpadded['threshold']:.0%} | {unpadded['pages']}/15 | {padded['pages']}/15 |")
    s = summary["actual_crops"]
    lines += ["", "## App partition and boundary guard", "",
              f"Under the actual crop union, {s['fully_covered_lines']:,} Vision boxes are fully covered, "
              f"{s['partially_covered_lines']:,} are partially covered and {s['uncovered_lines']:,} have no "
              "covered area. Partial union coverage is any share strictly between 0 and 1 "
              "(1e-9 numerical tolerance). It does not catch a line split between two crops whose union "
              "covers the complete line, so the app uses the stronger first-owner rule.", "",
              "In native detector order, the first crop intersecting a line owns its pixels. If that crop "
              "does not contain the complete line, the entire line moves to the whole-page fill: it is "
              "whitened in every region and restored in the fill. Every transitively intersecting Vision "
              "line moves with it, avoiding duplication where line rectangles overlap. Earlier crop "
              "rectangles are whitened in later regions. A crop already entirely covered by earlier crops "
              "is omitted (half a pixel of area tolerance, as the app). No text deduplication is used.", ""]
    p = summary["app_partition"]
    lines += ["| Fill condition, app partition | Pages |", "|---|---:|",
              f"| Coverage below 95% | {p['low_coverage_fill_pages']}/15 |",
              f"| Boundary guard | {p['boundary_fill_pages']}/15 |",
              f"| Both coverage and boundary guard | {p['both_boundary_and_low_coverage_pages']}/15 |",
              f"| Additional pages from boundary guard alone | {p['boundary_only_fill_pages']}/15 |",
              f"| Vision unavailable | {p['vision_unavailable_pages']}/15 |",
              f"| Any fill condition | {p['requires_fill_pages']}/15 |", "",
              f"The first-owner check marks {p['initial_boundary_lines']:,} lines initially; transitive "
              f"overlap adds {p['transitively_added_lines']:,}, moving "
              f"{p['boundary_lines_including_transitive']:,} complete line boxes to fill in all. "
              f"The app omits {p['redundant_regions_omitted']} redundant region rectangles. "
              "These counts simulate the app's partition on cached geometry only. They do not show "
              "that a masked fill improves OCR. The guard cannot account for writing Vision missed.", "",
              "## Limits and provenance", "",
              "The older 69.4% figure (`layout-photo-hands.json`) is a different measure: dark pixels below "
              "128 at 1,000px long side, excluding a 2% border, with picture labels and nested boxes dropped. "
              "Its 6/15 pages below 80% are not a result for Vision coverage or for pictures kept.", "",
              "No OCR-quality comparison, photographed newspaper measurement, or optimal threshold search "
              "was performed. This is a geometry-only check on the same 15 scans (at most 12 items, almost "
              "all one collection); it supports transparent threshold behavior and a sensitivity analysis. "
              "It does not show the accuracy or cost of an added fill reading.", "",
              "Inputs beneath `~/Library/Caches/ArchiveSuiteRehearsal` (or `--cache`):", "",
              "- `layout-photo/pages.jsonl`: L9 membership and page ids only.",
              "- `layout-photo/regions/pp.json`: detector rectangles and page dimensions.",
              "- `layout-order/vision/newsbench__*.json`: line rectangles and page dimensions; text ignored.", "",
              "The companion JSON contains numeric per-page measures and counts, no transcriptions or pixels.", ""]
    from seg_card import card
    lines += card("None. The reference for coverage is Apple Vision's own line boxes, not a hand-drawn truth of where "
                  "the writing is, so writing Vision missed is invisible here and a line box may hold no ink.",
                  "All 15 L9 newspaper scans, the bench's fixed set (at most 12 items, almost all one collection); "
                  "nothing chosen by the detector or by Vision.",
                  "The detector's raw rectangles against the app's padded pixel crops and its partition, on the same "
                  "cached detection (PP-DocLayoutV3, 1,024px, confidence 0.5) and the same Vision lines.",
                  "One cached detection, deterministic geometry: no rerun floor and no interval. With 15 pages, one "
                  "page is 6.7 points of any share above.",
                  "Geometry only: how much of Vision's line area the crops cover and which pages the fill rules would "
                  "send to a whole-page reading. It does not measure OCR accuracy, the cost of the fill reading, "
                  "photographed newspapers or the best floor; the partition's OCR evidence is separate "
                  "(W46.layout-partition-score, W46.layout-partition-fix).")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=CACHE)
    parser.add_argument("--output", type=Path, default=OUTPUT,
                        help="output basename, without .json/.md")
    args = parser.parse_args()
    result = analyse(args.cache)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.with_suffix(".json").write_text(json.dumps(result, indent=2) + "\n")
    args.output.with_suffix(".md").write_text(markdown(result))
    print(f"15 pages, {result['method']['vision_lines']} lines -> {args.output}.{{json,md}}")


if __name__ == "__main__":
    main()
