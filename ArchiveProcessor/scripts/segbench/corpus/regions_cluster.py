#!/usr/bin/env python3
"""W46.ocr-regions, the cluster half: one open reader on detector regions and on overlapping tiles.

  regions_cluster.py pages --out ROOT                     # ROOT/pages.jsonl + ROOT/routes.json
  regions_cluster.py detect-yolo --root ROOT [--limit N]  # npo-venv: DocLayout-YOLO regions -> ROOT/regions/
  regions_cluster.py read --root ROOT --route R --arms A [A ...] [--shard i/n] [--limit N] [--concurrency 16]

Pages: L9 (15), L4, L3 and L1 (80 each) of the 895, by the open sweep's `public895.jsonl`, and the owner's 99 by
the truth96 run's `truth99.jsonl` (the three agreement-only letters are kept and marked at scoring, as in the
sweep). The image is the one each route already read as a whole page, checked by its sha256, so the only thing
an arm changes is what part of that image a request carries.

Arms (each a list of crops of the same page image, read one request each, in this order):
  doclayout_yolo  DocLayout-YOLO through newspaper-ocr 0.11 with the library's layout processing (its reading
                  order), as NewsBench's reference rows were made; boxes from `detect-yolo`.
  pp-doclayoutv3  PP-DocLayoutV3 (the mlx-vlm port, conf 0.5) with the model's own reading order, run on the Mac
                  by `regions.py detect-pp` and copied here as ROOT/regions/pp-doclayoutv3.json.
  tiles           no detector: overlapping tiles (`tile_boxes`), down each tile column, then the next column.
Picture regions (DROP) are not read; a region at least 90% inside a larger kept one is not read twice.

The request is the open sweep's for that route: the route's own prompt file (empty = the image alone),
temperature 0, thinking off, streamed, max_tokens 4,096 a crop (a whole page had 8,192). One record a crop,
ROOT/out/<route>/<arm>/<page>/<nnn>.json, written atomically; a crop already there is not sent again, so a
rerun after a wall-limit kill sends only what is left. Transport errors go to <nnn>.error.json and count as
failures in the summary (exit 1). No network beyond localhost, no money. Stitching and scoring: regions.py.
"""
from __future__ import annotations

from pathlib import Path
import argparse
import base64
import concurrent.futures as cf
import hashlib
import http.client
import io
import json
import math
import os
import time
import urllib.error
import urllib.request

FS = '/scratch/users/cp1/fs-ocr'
PUBLIC = f'{FS}/open-sweep-20261019/public895.jsonl'
OWNER = f'{FS}/truth96-20261020/truth99.jsonl'
STRATA = ('L9', 'L4', 'L3', 'L1')
# The four readers' server settings and prompts, exactly as the loop rerun recorded them from the open sweep.
ROUTES_FROM = f'{FS}/loop-rerun-20261021/routes.json'
READERS = ('glm-ocr', 'paddleocr-vl1.5', 'lightonocr3-4b', 'qwen3.6-27b')
ARMS = ('doclayout_yolo', 'pp-doclayoutv3', 'tiles')
DROP = {'figure', 'image', 'picture', 'header_image', 'footer_image'}
MAX_TOKENS = 4096
JPEG_QUALITY = 95
PAD = 0.004          # of the page's width/height on each side of a detector box
MIN_SIDE = 32        # px; a smaller crop is widened around its centre (vision encoders refuse tiny images)
TILE_COL_PX = 2000   # a page wider than this gets more than one tile column
TILE_ASPECT = 0.6    # tile height = this x tile width
TILE_OVERLAP = 0.15  # of the tile height, at least, between neighbouring tiles in a column


def tile_boxes(w: int, h: int) -> list[list[float]]:
    """Overlapping tiles as [x0, y0, x1, y1] fractions, down each column then across. A 1700 x 2400 page gets
    one column of three 1700 x 1020 tiles overlapping by 330 px; a page shorter than one tile is one tile."""
    cols = max(1, round(w / TILE_COL_PX))
    tw = w / cols
    th = min(h, tw * TILE_ASPECT)
    rows = 1 if th >= h else math.ceil((h - th * TILE_OVERLAP) / (th * (1 - TILE_OVERLAP)))
    out = []
    for c in range(cols):
        for r in range(rows):
            y0 = 0 if rows == 1 else r * (h - th) / (rows - 1)
            out.append([c * tw / w, y0 / h, (c + 1) * tw / w, (y0 + th) / h])
    return out


def inside(a, b) -> float:
    """Share of box a's area inside box b."""
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0])); iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    area = (a[2] - a[0]) * (a[3] - a[1])
    return ix * iy / area if area > 0 else 1.0


def keep_regions(regions: list[dict]) -> list[dict]:
    """The regions an arm reads, in the detector's order: no pictures, and none mostly inside a larger kept one."""
    cand = [r for r in regions if r['label'] not in DROP and r['box'][2] > r['box'][0] and r['box'][3] > r['box'][1]]
    area = lambda r: (r['box'][2] - r['box'][0]) * (r['box'][3] - r['box'][1])
    kept = []
    for r in sorted(cand, key=area, reverse=True):
        if not any(inside(r['box'], k['box']) >= 0.9 for k in kept):
            kept.append(r)
    ids = {id(r) for r in kept}
    return [r for r in cand if id(r) in ids]


def pixel_box(box, w: int, h: int, pad: float) -> tuple[int, int, int, int]:
    x0, y0, x1, y1 = box[0] - pad, box[1] - pad, box[2] + pad, box[3] + pad
    x0, y0, x1, y1 = max(0, round(x0 * w)), max(0, round(y0 * h)), min(w, round(x1 * w)), min(h, round(y1 * h))
    for lo, hi, size in ((0, 2, w), (1, 3, h)):
        b = [x0, y0, x1, y1]
        if b[hi] - b[lo] < MIN_SIDE:
            c = (b[lo] + b[hi]) / 2
            b[lo] = max(0, round(c - MIN_SIDE / 2)); b[hi] = min(size, b[lo] + MIN_SIDE); b[lo] = max(0, b[hi] - MIN_SIDE)
            x0, y0, x1, y1 = b
    return x0, y0, x1, y1


def crops_for(arm: str, page: dict, regions: dict, w: int, h: int) -> list[dict]:
    if arm == 'tiles':
        return [{'label': 'tile', 'box': b, 'px': pixel_box(b, w, h, 0)} for b in tile_boxes(w, h)]
    got = regions.get(arm, {}).get(page['id'])
    if got is None:
        raise KeyError(f'{arm}: no regions for {page["id"]}')
    return [{'label': r['label'], 'box': r['box'], 'px': pixel_box(r['box'], w, h, PAD)} for r in keep_regions(got)]


def cmd_pages(a):
    rows = [json.loads(x) for x in Path(PUBLIC).read_text().splitlines() if x.strip()]
    pub = [{**r, 'set': 'public895'} for r in rows if r['stratum'] in STRATA]
    own = [{**json.loads(x), 'set': 'owner99'} for x in Path(OWNER).read_text().splitlines() if x.strip()]
    pages = pub + own
    assert len({p['id'] for p in pages}) == len(pages)
    a.out.mkdir(parents=True, exist_ok=True)
    (a.out / 'pages.jsonl').write_text(''.join(json.dumps(p) + '\n' for p in pages))
    src = json.loads(Path(ROUTES_FROM).read_text())
    plan = {k: {f: src[k][f] for f in ('model', 'served', 'prompt', 'vllm_args')} for k in READERS}
    (a.out / 'routes.json').write_text(json.dumps(plan, indent=2) + '\n')
    print(len(pub), 'public +', len(own), 'owner pages ->', a.out / 'pages.jsonl')


def load_pages(root: Path, limit=0) -> list[dict]:
    pages = [json.loads(x) for x in (root / 'pages.jsonl').read_text().splitlines() if x.strip()]
    return pages[:limit] if limit else pages


def cmd_detect_yolo(a):
    """DocLayout-YOLO + newspaper-ocr's layout processing, as the library's Pipeline runs them before reading."""
    from PIL import Image
    from newspaper_ocr.detectors import DETECTORS
    from newspaper_ocr.layout_processor import LayoutProcessor
    from importlib.metadata import version
    det = DETECTORS.get('doclayout_yolo')(model_dir=None, skip_lines=True)
    proc = LayoutProcessor()
    dest = a.root / 'regions' / 'doclayout_yolo.json'
    store = json.loads(dest.read_text()) if dest.exists() else {
        'detector': f'DocLayout-YOLO via newspaper-ocr {version("newspaper-ocr")}, library layout processing',
        'pages': {}}
    t0 = time.time(); todo = [p for p in load_pages(a.root, a.limit) if p['id'] not in store['pages']]
    for n, p in enumerate(todo, 1):
        data = Path(p['image']).read_bytes()
        assert hashlib.sha256(data).hexdigest() == p['sha256'], p['id']
        im = Image.open(io.BytesIO(data)).convert('RGB'); w, h = im.size
        layout = proc.process(det.detect(im))
        store['pages'][p['id']] = [{'label': r.label, 'order': i, 'score': round(float(r.confidence), 3),
                                    'box': [r.bbox.x0 / w, r.bbox.y0 / h, r.bbox.x1 / w, r.bbox.y1 / h]}
                                   for i, r in enumerate(layout.regions)]
        if n % 25 == 0 or n == len(todo):
            dest.parent.mkdir(parents=True, exist_ok=True)
            tmp = dest.with_suffix('.part'); tmp.write_text(json.dumps(store)); tmp.replace(dest)
            print(f'{n}/{len(todo)} pages, {(time.time() - t0) / n:.2f} s a page', flush=True)
    missing = [p['id'] for p in load_pages(a.root, a.limit) if p['id'] not in store['pages']]
    if missing:
        raise SystemExit(f'{len(missing)} pages without regions')


def jpeg_crop(data: bytes, px) -> tuple[bytes, list[int]]:
    from PIL import Image
    im = Image.open(io.BytesIO(data)).convert('RGB').crop(px)
    buf = io.BytesIO(); im.save(buf, 'JPEG', quality=JPEG_QUALITY)
    return buf.getvalue(), list(im.size)


def body(prompt: str, jpeg: bytes, served: str) -> dict:
    content = [{'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,' + base64.b64encode(jpeg).decode()}}]
    if prompt:
        content.append({'type': 'text', 'text': prompt})
    return {'model': served, 'messages': [{'role': 'user', 'content': content}], 'temperature': 0,
            'max_tokens': MAX_TOKENS, 'stream': True, 'stream_options': {'include_usage': True},
            'chat_template_kwargs': {'enable_thinking': False}}


def post(url: str, b: dict, timeout=600):
    req = urllib.request.Request(url + '/v1/chat/completions', json.dumps(b).encode(), {'Content-Type': 'application/json'})
    t = time.time(); raw = ''; finish = None; usage = {}
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for line in resp:
            if time.time() - t > timeout:
                raise TimeoutError(f'generation exceeded {timeout} seconds')
            if not line.startswith(b'data:'):
                continue
            s = line[5:].strip()
            if s == b'[DONE]':
                break
            j = json.loads(s); usage = j.get('usage') or usage
            for c in j.get('choices') or []:
                raw += (c.get('delta') or {}).get('content') or ''; finish = c.get('finish_reason') or finish
    return raw, finish, usage


def atomic(dest: Path, obj):
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix('.part'); tmp.write_text(json.dumps(obj, ensure_ascii=False)); tmp.replace(dest)


def cmd_read(a):
    from PIL import Image
    routes = json.loads((a.root / 'routes.json').read_text())
    spec = routes[a.route]
    prompt = Path(spec['prompt']).read_text()
    regions = {}
    for arm in a.arms:
        if arm != 'tiles':
            regions[arm] = json.loads((a.root / 'regions' / f'{arm}.json').read_text())['pages']
    i, n = (int(x) for x in a.shard.split('/'))
    pages = [p for k, p in enumerate(load_pages(a.root, a.limit)) if k % n == i]
    items = []
    for p in pages:
        data = Path(p['image']).read_bytes()
        assert hashlib.sha256(data).hexdigest() == p['sha256'], p['id']
        w, h = Image.open(io.BytesIO(data)).size
        for arm in a.arms:
            for k, c in enumerate(crops_for(arm, p, regions, w, h)):
                dest = a.root / 'out' / a.route / arm / p['id'] / f'{k:03d}.json'
                if not dest.exists():
                    items.append((p, arm, k, c, dest))
    url, served = os.environ['FS_URL'], os.environ['FS_SERVED']

    def one(item):
        p, arm, k, c, dest = item
        jpeg, size = jpeg_crop(Path(p['image']).read_bytes(), c['px'])
        t = time.time(); status, error, raw, finish, usage = 'error', None, '', None, {}
        try:
            raw, finish, usage = post(url, body(prompt, jpeg, served))
            status = 'ok' if finish == 'stop' else 'cap' if finish == 'length' else 'error'
        except (urllib.error.URLError, http.client.HTTPException, TimeoutError, OSError, ValueError) as e:
            error = str(e)[:500]
        rec = {'page': p['id'], 'set': p['set'], 'stratum': p.get('stratum'), 'arm': arm, 'index': k,
               'label': c['label'], 'box': c['box'], 'px': list(c['px']), 'sent_size': size,
               'sent_sha256': hashlib.sha256(jpeg).hexdigest(), 'route': a.route, 'model': os.environ.get('FS_MODEL'),
               'prompt_sha256': hashlib.sha256(prompt.encode()).hexdigest(), 'max_tokens': MAX_TOKENS,
               'raw': raw, 'finish': finish, 'status': status, 'error': error, 'usage': usage,
               'wall_s': round(time.time() - t, 3), 'job': os.environ.get('SLURM_JOB_ID')}
        atomic(dest.with_suffix('.error.json') if status == 'error' else dest, rec)
        return status

    start = time.time(); statuses = []
    with cf.ThreadPoolExecutor(a.concurrency) as ex:
        for m, s in enumerate(ex.map(one, items), 1):
            statuses.append(s)
            if m % 200 == 0 or m == len(items):
                print(a.route, m, '/', len(items), s, flush=True)
    summary = {'route': a.route, 'arms': a.arms, 'shard': a.shard, 'pages': len(pages), 'sent': len(items),
               'ok': statuses.count('ok'), 'caps': statuses.count('cap'), 'errors': statuses.count('error'),
               'wall_s': round(time.time() - start, 2), 'concurrency': a.concurrency,
               'model': os.environ.get('FS_MODEL'), 'job': os.environ.get('SLURM_JOB_ID')}
    tag = a.shard.replace('/', 'of')
    atomic(a.root / 'out' / a.route / f'summary-{tag}-{os.environ.get("SLURM_JOB_ID", "local")}.json', summary)
    print(json.dumps(summary), flush=True)
    if summary['errors']:
        raise SystemExit(1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('pages'); s.add_argument('--out', type=Path, required=True)
    s = sub.add_parser('detect-yolo'); s.add_argument('--root', type=Path, required=True)
    s.add_argument('--limit', type=int, default=0)
    s = sub.add_parser('read'); s.add_argument('--root', type=Path, required=True); s.add_argument('--route', required=True)
    s.add_argument('--arms', nargs='+', choices=ARMS, default=list(ARMS)); s.add_argument('--shard', default='0/1')
    s.add_argument('--limit', type=int, default=0); s.add_argument('--concurrency', type=int, default=16)
    a = ap.parse_args()
    {'pages': cmd_pages, 'detect-yolo': cmd_detect_yolo, 'read': cmd_read}[a.cmd](a)


if __name__ == '__main__':
    main()
