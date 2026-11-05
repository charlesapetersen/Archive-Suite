#!/usr/bin/env python3
"""W46.mixed-route, the cluster half: GLM-OCR and Qwen3.6-27B on the 32 marks-core pages whole, and on each scored
mark's crop from the owner's box and from YOLO11m's matched box.

  mixed_route_cluster.py check --root ROOT [--strict]
  mixed_route_cluster.py read --root ROOT --route glm-ocr|qwen3.6-27b [--shard i/n] [--limit N] [--concurrency 16]

layout_photo_cluster.py's reader, so W46.ocr-regions' request unchanged (the route's prompt, JPEG 95, 4,096 tokens,
temperature 0, one receipt a crop under ROOT/out/<route>/<arm>/<page>/<k>.json, skipped when present), with two
differences: the arms are this pack's (whole, oracle, det25, det05), and a mark crop is never dropped for lying
inside a larger one (one owner box holds three others; each is scored on its own). Each region's label is the
mark's id, so the Mac scorer pairs a receipt with its mark. No network beyond localhost, no money.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import layout_photo_cluster as LP  # noqa: E402
import regions_cluster as C  # noqa: E402

LP.ARMS = ('whole', 'oracle', 'det25', 'det05')


def keep_all(regions):
    """Every region with a real box, in the pack's order: no picture filter and no inside-a-larger-one drop."""
    return [r for r in regions if r['box'][2] > r['box'][0] and r['box'][3] > r['box'][1]]


C.keep_regions = keep_all    # crops_for and cmd_check look it up in their module at call time

if __name__ == '__main__':
    LP.main()
