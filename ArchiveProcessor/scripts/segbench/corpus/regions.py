#!/usr/bin/env python3
"""W46.ocr-regions — whole page against detector regions against tiles, four open readers (the Mac half).

  <lab venv>/bin/python regions.py prepare --out DIR    # DIR/regions/pp-doclayoutv3.json
  regions.py report --runs DIR --out DIR                # stitch each arm's crops and score them (later session)

`prepare` runs PP-DocLayoutV3 (the mlx-vlm port `layout.py` uses, conf 0.5, its own reading order) on this Mac
over the run's pages, L9, L4, L3 and L1 of the 895 (the frozen originals) and the owner's 99 (the panel's frozen
originals), and writes the boxes as page fractions keyed by the cluster's page id, so the cluster job can cut the
same boxes from the 2,400 px copy each route read whole. DocLayout-YOLO runs on the cluster (newspaper-ocr's
detector is not installed here). The cluster half, the arms and the request: `regions_cluster.py`; submission:
`regions-submit.sh`. No money; no page text or pixels leave the Mac in this step beyond the region boxes.
"""
from pathlib import Path
import argparse
import json
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import os                                # noqa: E402
import routes as R                       # noqa: E402
import regions_cluster as C              # noqa: E402

LTS = Path(os.environ.get('LTS', Path.home() / 'Claude/Long term storage'))
MANIFEST = LTS / 'FarmShare-20261019/recovery/manifest-895.jsonl'   # as loop_rerun.py (no scorer import here)
DETECTOR = 'PP-DocLayoutV3 (mlx-vlm port), conf 0.5, 1024 px, model reading order'


def mac_pages():
    """(cluster id, set, stratum, image path on this Mac) for every page of the run."""
    R.MANIFEST = MANIFEST
    out = [(R.job_id(r), 'public895', r['stratum'], Path(r['image'])) for r in R.frozen() if r['stratum'] in C.STRATA]
    import ocr_panel as P
    m = json.loads((P.CACHE / 'manifest.json').read_text())
    out += [(j['page'], 'owner99', None, P.CACHE / 'images' / (j['id'] + '.jpg'))
            for j in m['jobs'] if j['scale'] == 'original']
    return out


def boxes_pp(found: list[dict]) -> list[dict]:
    """PP-DocLayoutV3's viewer schema ([y0, x0, y1, x1] in 0-1000, 1-based order) as the cluster's records."""
    rows = [{'label': r['label'], 'order': r['reading_order'], 'score': round(float(r['score']), 3),
             'box': [max(0.0, r['bbox'][1] / 1000), max(0.0, r['bbox'][0] / 1000),
                     min(1.0, r['bbox'][3] / 1000), min(1.0, r['bbox'][2] / 1000)]} for r in found]
    return sorted(rows, key=lambda r: r['order'])


OVERLAP_LINES = 12   # a tile's last lines that the next tile's first lines may repeat (15% of a band is ~4 lines)
SAME_LINE = 0.8      # difflib ratio at which two normalised lines are the same line read twice


def norm_line(s: str) -> str:
    return ' '.join(s.lower().split())


def drop_repeated_head(prev: list[str], cur: list[str]) -> list[str]:
    """cur without its leading lines that repeat one of prev's last OVERLAP_LINES lines; stops at the first line
    that is new. A line the band edge cut through stays in prev as read (scored as written, not repaired)."""
    import difflib
    tail = [norm_line(x) for x in prev[-OVERLAP_LINES:] if x.strip()]
    k = 0
    while k < len(cur) and k < OVERLAP_LINES:
        line = norm_line(cur[k])
        if line and not any(difflib.SequenceMatcher(None, line, t).ratio() >= SAME_LINE for t in tail):
            break
        k += 1
    return cur[k:]


def stitch(arm: str, crops: list[dict]) -> str:
    """One page's text from its crops' readings ({'index', 'box', 'text'}), in the order they were sent. Regions
    are joined as paragraphs; tiles in the same column lose the lines their overlap repeats."""
    crops = sorted(crops, key=lambda c: c['index'])
    if arm != 'tiles':
        return '\n\n'.join(c['text'].strip() for c in crops if c['text'].strip())
    out, prev = [], None
    for c in crops:
        lines = c['text'].strip().splitlines()
        if prev is not None and prev['box'][0] == c['box'][0]:
            lines = drop_repeated_head(prev['text'].splitlines(), lines)
        if lines:
            out.append('\n'.join(lines))
        prev = c
    return '\n'.join(out)


def cmd_prepare(a):
    from PIL import Image
    import layout
    Image.MAX_IMAGE_PIXELS = None
    a.out.mkdir(parents=True, exist_ok=True)
    dest = a.out / 'regions' / 'pp-doclayoutv3.json'
    store = json.loads(dest.read_text()) if dest.exists() else {'detector': DETECTOR, 'pages': {}}
    pages = mac_pages()
    todo = [p for p in pages if p[0] not in store['pages']]
    model = layout.load_model() if todo else None
    t0 = time.time()
    for n, (pid, _set, _stratum, path) in enumerate(todo, 1):
        im = Image.open(path)
        im.draft('RGB', (1024, 1024))
        store['pages'][pid] = boxes_pp(model.detect(im.convert('RGB')))
        if n % 50 == 0 or n == len(todo):
            dest.parent.mkdir(parents=True, exist_ok=True)
            tmp = dest.with_suffix('.part'); tmp.write_text(json.dumps(store)); tmp.replace(dest)
            print(f'{n}/{len(todo)} pages, {(time.time() - t0) / n:.2f} s a page', flush=True)
    print(len(pages), 'pages with regions ->', dest)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('prepare'); p.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    {'prepare': cmd_prepare}[a.cmd](a)


if __name__ == '__main__':
    main()
