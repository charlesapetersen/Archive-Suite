#!/usr/bin/env python3
"""W46.layout-photo, the cluster half: GLM-OCR on each detector's regions, W46.ocr-regions' request unchanged.

  layout_photo_cluster.py check --root ROOT                 # every image's sha256, every arm's pages, crop counts
  layout_photo_cluster.py read --root ROOT --route glm-ocr [--shard i/n] [--limit N] [--concurrency 16]

ROOT holds pages.jsonl, routes.json, regions/<arm>.json (made on the Mac by layout_photo.py pack) and, for the
Real5 pages, images/. A page is read in the arms whose regions file names it, and only those: the 96, L9 and L4
in yolo_appsort, heron and vision_doc (their whole-page and PP-DocLayoutV3 readings are W46.ocr-regions'); the
Real5 photographs in those three, pp-doclayoutv3 and whole (one crop, the page); the quad and UVDoc copies in
whole, yolo_appsort and pp-doclayoutv3. Everything else is `regions_cluster.cmd_read`: the same crop padding,
JPEG 95, 4,096 tokens a crop, temperature 0, one receipt a crop under ROOT/out/<route>/<arm>/<page>/, skipped when
present, so a rerun after a wall-limit kill sends only what is left. No network beyond localhost, no money.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import regions_cluster as C  # noqa: E402

ARMS = ('whole', 'yolo_appsort', 'pp-doclayoutv3', 'heron', 'vision_doc')
_crops_for = C.crops_for


def crops_for(arm, page, regions, w, h):
    """An arm that does not name the page sends nothing for it; one that names it with no kept region sends
    nothing either, and the scorer tells the two apart from the regions file."""
    if page['id'] not in regions.get(arm, {}):
        return []
    return _crops_for(arm, page, regions, w, h)


def arms(root: Path) -> list[str]:
    return [a for a in ARMS if (root / 'regions' / f'{a}.json').exists()]


def cmd_check(a):
    pages = C.load_pages(a.root)
    ids = {p['id'] for p in pages}
    regions = {arm: json.loads((a.root / 'regions' / f'{arm}.json').read_text())['pages'] for arm in arms(a.root)}
    bad = []
    for arm, got in regions.items():
        extra = set(got) - ids
        if extra:
            bad.append(f'{arm}: {len(extra)} pages not in pages.jsonl')
    absent = 0
    for p in pages:
        f = Path(p['image'])
        if not f.exists():
            absent += 1
            continue
        if hashlib.sha256(f.read_bytes()).hexdigest() != p['sha256']:
            bad.append(f'{p["id"]}: image checksum differs')
        if not any(p['id'] in got for got in regions.values()):
            bad.append(f'{p["id"]}: in no arm')
    crops = {arm: sum(len(C.keep_regions(r)) for r in got.values()) for arm, got in regions.items()}
    print(json.dumps({'pages': len(pages), 'images_absent_here': absent, 'arms': {k: len(v) for k, v in regions.items()},
                      'crops': crops, 'crops_total': sum(crops.values())}))
    if a.strict and absent:
        bad.append(f'{absent} images absent')
    if bad:
        raise SystemExit('\n'.join(bad[:20]))


def cmd_read(a):
    C.crops_for = crops_for          # cmd_read looks it up in its module at call time
    try:
        C.cmd_read(argparse.Namespace(root=a.root, route=a.route, arms=arms(a.root), shard=a.shard, limit=a.limit,
                                      concurrency=a.concurrency))
    finally:
        C.crops_for = _crops_for


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('check'); s.add_argument('--root', type=Path, required=True)
    s.add_argument('--strict', action='store_true', help='every image must be present (on the cluster)')
    s = sub.add_parser('read'); s.add_argument('--root', type=Path, required=True); s.add_argument('--route', required=True)
    s.add_argument('--shard', default='0/1'); s.add_argument('--limit', type=int, default=0)
    s.add_argument('--concurrency', type=int, default=16)
    a = ap.parse_args()
    {'check': cmd_check, 'read': cmd_read}[a.cmd](a)


if __name__ == '__main__':
    main()
