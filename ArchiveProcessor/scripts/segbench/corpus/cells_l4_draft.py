#!/usr/bin/env python3
"""W46.ocr-cells-l4-more: draft per-cell truth for a second forms-L4 bank through the gateway.

  python3 cells_l4_draft.py draw        # 20 L4 pages of the 895, seeded hash order, the 4 already inspected left out
  python3 cells_l4_draft.py propose     # Gemini 3.7 Flash: is there a front-side table, and its column/row grid
  python3 cells_l4_draft.py pick        # 3 heading + 6 entry cells per table page, at random (seed) from the grid
  python3 cells_l4_draft.py read        # Gemini 3.7 Flash and GLM 5.3 Flash each read every picked cell
  python3 cells_l4_draft.py status      # counts, agreement and spend; prints nothing from a page

The only L4 cell truth was the frozen bank's 3 register pages (27 fields, regions-cells-20261025.md), read by a
session from the pixels. Since 2026-10-30 no session reads pages as data, so two gateway readers not under test
draft it (the bank's readers under test are Qwen3.6-27B and the W46.ocr-family-coverage readers) and the owner rules
where they differ, on the sheet `cells_l4_sheet.py` builds. Selection: the pages by a seeded hash of their ids, and
the cells at random from the proposed grid, so neither a tested route nor legibility chooses them. A page the
proposer finds no front-side table on is left out without replacement, as the first bank did.

Each reader sees the cell padded by context with a red rectangle at its box (the measured readers get the bare
crop), and says whether the box holds one cell's whole text. Agreement is the bank scorer's whitespace/case
normalisation; a cell either reader calls badly boxed goes to the owner however the texts compare.

Real money on the Stanford PTA: CAP bounds the item's drafting, counted per call as the larger of the token estimate
and the gateway's own figure (W46.gateway-cost-record); a call is refused unless its worst case fits. The ledger is
STORE/calls.jsonl. Pages, replies and drafts stay in STORE (Smithsonian images may not be published).
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import random
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE.parent)]
import gateway_gemini as G  # noqa: E402

LTS = Path.home() / 'Claude/Long term storage/FarmShare-20261019/ocr'
PAGES = LTS / 'public-expanded.jsonl'          # the 895's 2,400 px copies the cluster reads, with their hashes
STORE = G.REHEARSAL / 'ocr-cells-l4-more'
SEED = 'W46.ocr-cells-l4-more'
N_PAGES = 20
INSPECTED = {'si__NMAAHC-007630087_00447', 'si__NMAAHC-007630088_00156', 'si__NMAAHC-007630088_00337',
             'si__NMAAHC-007630087_00354'}    # the first bank's four seeds (three kept, one paired prose)
HEADINGS, ENTRIES = 3, 6
MODELS = {'gemini': 'gemini-3.7-flash', 'glm': 'GLM 5.3 Flash'}
PRICES = {'gemini': (.75, 3.75), 'glm': (.15, .50)}   # $/M estimates as seg_lincoln_gateway; not a gateway bill
MAX_OUT = {'gemini': 8192, 'glm': 16384}             # GLM spends its first thousands on reasoning
CAP = 2.50
LOCK = threading.Lock()
INFLIGHT = [0.0]   # worst-case dollars of calls sent and not yet in the ledger

PROPOSE = (
    'This is a scanned page from a 19th-century register or form. Decide whether the front side of the page has a '
    'table: entries laid out in columns under column headings (ignore bleed-through from the reverse side). If it '
    'does, describe the grid of its main table. Coordinates are integers from 0 to 1000, as fractions of the image '
    'width (x) and height (y). Do not transcribe any text. Return one JSON object: {"rotation": 0, 90, 180 or 270 '
    '(how many degrees clockwise the image must be turned for its writing to read upright), "table": true or false, '
    '"note": "a short reason", "table_box": {"left": x, "top": y, "right": x, "bottom": y}, "columns": [the x '
    'position of every vertical boundary between columns, left to right, including the left and right edges of the '
    'table], "heading": {"top": y, "bottom": y} (the band that holds the column headings), "rows": [the y position '
    'of every boundary between body rows below the headings, top to bottom, including the top of the first row and '
    'the bottom of the last]}. Leave out table_box, columns, heading and rows when there is no table.')

READ = (
    'The red rectangle marks one field (one cell) of a table on a scanned page. Transcribe exactly what is written '
    'inside the red rectangle. Preserve the visible spelling, punctuation, numbers and abbreviations; do not expand '
    'ditto marks or abbreviations, and do not infer missing values. Ignore writing outside the rectangle and '
    'bleed-through from the reverse side. Return one JSON object: {"text": the transcription ("" if the field is '
    'blank, [illegible] for writing you cannot read), "box": "fits" if the rectangle holds the whole text of one '
    'field, or "cut" if it cuts through writing or holds parts of two fields, "medium": "hand", "print" or "none" '
    '(blank), "type": "free_text" (names, words), "formatted" (dates, numbers, sums of money) or "discrete" (a '
    'mark, tick, yes/no or a code)}')


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def dump(path: Path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + '.part')
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=1) + '\n')
    tmp.replace(path)


def load(path: Path):
    return json.loads(path.read_text())


# --- the draw -----------------------------------------------------------------------------------------------------

def draw():
    rows = [json.loads(x) for x in PAGES.read_text().splitlines() if x.strip()]
    l4 = [r for r in rows if r['stratum'] == 'L4' and r['id'] not in INSPECTED]
    order = sorted(l4, key=lambda r: sha(f'{SEED}|{r["id"]}'.encode()))
    picked = []
    for r in order[:N_PAGES]:
        data = (LTS / 'images' / (r['id'] + '.jpg')).read_bytes()
        if sha(data) != r['sha256']:
            raise SystemExit(f'{r["id"]}: image hash differs from the cluster manifest')
        dest = STORE / 'images' / (r['id'] + '.jpg')
        if not dest.exists():
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
        picked.append({'id': r['id'], 'sha256': r['sha256'], 'source': r['source']})
    out = {'seed': SEED, 'population': len(l4), 'excluded_inspected': sorted(INSPECTED), 'pages': picked}
    if (STORE / 'draw.json').exists() and load(STORE / 'draw.json') != out:
        raise SystemExit('draw.json differs from a fresh draw; refusing to change a drawn set')
    dump(STORE / 'draw.json', out)
    print(len(picked), 'of', len(l4), 'L4 pages ->', STORE / 'draw.json')


def drawn():
    return load(STORE / 'draw.json')['pages']


# --- the gateway ----------------------------------------------------------------------------------------------------

def ledger():
    f = STORE / 'calls.jsonl'
    return [json.loads(x) for x in f.read_text().splitlines()] if f.exists() else []


def spent():
    return sum(G.charge(r) for r in ledger())


def gateway_key():
    """The key with a deadline, as seg_boxes_score.gateway_key: a locked login keychain makes `security` wait on an
    unlock dialog on the owner's screen instead of failing (2026-11-01, and again here 2026-11-17 22:17)."""
    import subprocess
    if G._key is not None:
        return
    try:
        r = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', 'com.archiveprocessor.app',
                            '-a', 'Gateway', '-w'], capture_output=True, text=True, timeout=20)
    except subprocess.TimeoutExpired:
        raise SystemExit('the Keychain did not answer in 20 s (locked?): no gateway call made')
    if r.returncode != 0 or not r.stdout.strip():
        raise SystemExit('no gateway key in the Keychain (com.archiveprocessor.app / Gateway)')
    G._key = r.stdout.strip()


def worst(route, body):
    """An upper bound for one call: every byte of the body as a token, and the whole output cap."""
    p_in, p_out = PRICES[route]
    return (len(json.dumps(body)) / 3 * p_in + MAX_OUT[route] * p_out) / 1e6


def call(route, key, image: bytes, prompt: str, dest: Path):
    if dest.exists():
        return load(dest)
    body = {'model': MODELS[route], 'temperature': 0, 'max_tokens': MAX_OUT[route], 'reasoning_effort': 'low',
            'response_format': {'type': 'json_object'},
            'messages': [{'role': 'user', 'content': [
                {'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,' + base64.b64encode(image).decode()}},
                {'type': 'text', 'text': prompt}]}]}
    bound = worst(route, body)
    with LOCK:   # calls still in flight count at their worst case, so parallel threads cannot pass the cap together
        if spent() + INFLIGHT[0] + bound > CAP:
            raise SystemExit(f'cap: ${spent():.4f} spent of ${CAP}')
        INFLIGHT[0] += bound
    try:
        return send(route, key, body, dest)
    finally:
        with LOCK:
            INFLIGHT[0] -= bound


def send(route, key, body, dest):
    gateway_key()
    t = time.time()
    for attempt in range(3):
        r = G.request('/chat/completions', body)
        if r.status_code in (429, 500, 502, 503, 504) and attempt < 2:
            time.sleep(10 * (attempt + 1)); continue
        break
    got = r.json() if r.headers.get('content-type', '').startswith('application/json') else {'raw': r.text[:2000]}
    usage = got.get('usage') or {}
    p_in, p_out = PRICES[route]
    est = ((usage.get('prompt_tokens') or 0) * p_in + (usage.get('completion_tokens') or 0) * p_out) / 1e6
    rec = G.with_gateway_cost({'route': route, 'key': key, 'http': r.status_code, 't': t,
                               'wall_s': round(time.time() - t, 3), 'model': got.get('model'), 'usage': usage,
                               'cost': round(est, 6),
                               'request_sha256': sha(json.dumps(body, sort_keys=True).encode())}, r)
    with LOCK:
        STORE.mkdir(parents=True, exist_ok=True)
        with (STORE / 'calls.jsonl').open('a') as f:
            f.write(json.dumps(rec) + '\n')
    choice = (got.get('choices') or [{}])[0]
    out = {'meta': {**rec, 'finish': choice.get('finish_reason')},
           'raw': (choice.get('message') or {}).get('content') if r.status_code == 200 else None}
    if r.status_code == 200 and out['raw']:
        dump(dest, out)
    else:
        print(key, route, r.status_code, json.dumps(got)[:300])
    return out


def parse(raw):
    if not raw:
        return None
    raw = raw.strip()
    m = re.fullmatch(r'```(?:json)?\s*(.*?)\s*```', raw, re.S)
    if m:
        raw = m.group(1)
    try:
        v = json.loads(raw)
    except ValueError:
        return None
    return v if isinstance(v, dict) else None


def pool(jobs, workers=4):
    gateway_key()   # before any thread, so a locked keychain stops the run, not each call
    with ThreadPoolExecutor(workers) as ex:
        return list(ex.map(lambda j: j(), jobs))


# --- the grid -------------------------------------------------------------------------------------------------------

def propose():
    jobs = []
    for p in drawn():
        image = (STORE / 'images' / (p['id'] + '.jpg')).read_bytes()
        jobs.append(lambda p=p, image=image: call('gemini', p['id'], image, PROPOSE,
                                                  STORE / 'propose' / (p['id'] + '.json')))
    pool(jobs)
    status()


def grid(pid):
    """The proposal as page fractions, or None (no table, or an unusable grid) with the reason."""
    f = STORE / 'propose' / (pid + '.json')
    v = parse(load(f)['raw']) if f.exists() else None
    if v is None:
        return None, 'no parsable proposal'
    if v.get('table') is not True:
        return None, 'no front-side table: ' + str(v.get('note', ''))[:200]
    try:
        tb = v['table_box']; box = [tb['left'] / 1000, tb['top'] / 1000, tb['right'] / 1000, tb['bottom'] / 1000]
        cols = sorted(c / 1000 for c in v['columns']); rows = sorted(y / 1000 for y in v['rows'])
        head = [v['heading']['top'] / 1000, v['heading']['bottom'] / 1000]
    except (KeyError, TypeError):
        return None, 'grid fields missing'
    clamp = lambda x: min(max(x, 0.0), 1.0)
    box = [clamp(x) for x in box]
    cols = [x for x in (clamp(c) for c in cols) if box[0] <= x <= box[2]]
    rows = [y for y in (clamp(r) for r in rows) if head[1] - 0.005 <= y <= box[3]]
    if not (box[0] < box[2] and box[1] < box[3] and len(cols) >= 2 and len(rows) >= 2 and head[0] < head[1]):
        return None, 'degenerate grid'
    return {'table_box': box, 'columns': cols, 'heading': head, 'rows': rows}, None


def rotation(pid):
    """The proposer's turn for the page (degrees clockwise to upright), or None."""
    f = STORE / 'propose' / (pid + '.json')
    v = parse(load(f)['raw']) if f.exists() else None
    r = (v or {}).get('rotation')
    return r if r in (0, 90, 180, 270) else None


def pick():
    pages, left_out = [], {}
    for p in drawn():
        g, why = grid(p['id'])
        if g is None:
            left_out[p['id']] = why
            continue
        rng = random.Random(sha(f'{SEED}|cells|{p["id"]}'.encode()))
        cols, rows, (h0, h1) = g['columns'], g['rows'], g['heading']
        nc, nr = len(cols) - 1, len(rows) - 1
        cells = []
        for c in sorted(rng.sample(range(nc), min(HEADINGS, nc))):
            cells.append({'role': 'heading', 'col': c, 'row': None, 'box': [cols[c], h0, cols[c + 1], h1]})
        pairs = [(r, c) for r in range(nr) for c in range(nc)]
        for r, c in sorted(rng.sample(pairs, min(ENTRIES, len(pairs)))):
            cells.append({'role': 'entry', 'col': c, 'row': r, 'box': [cols[c], rows[r], cols[c + 1], rows[r + 1]]})
        tb = g['table_box']
        for i, c in enumerate(cells):
            c['id'] = f'c{i + 1:02d}'
            # The freeze needs each cell inside its table box; the grid's edges can stray past it by a hair.
            tb = [min(tb[0], c['box'][0]), min(tb[1], c['box'][1]), max(tb[2], c['box'][2]), max(tb[3], c['box'][3])]
        pages.append({'id': p['id'], 'sha256': p['sha256'], 'table_box': tb, 'grid': g, 'cells': cells})
    dump(STORE / 'picked.json', {'seed': SEED, 'headings': HEADINGS, 'entries': ENTRIES, 'pages': pages,
                                 'left_out': left_out})
    print(len(pages), 'table pages,', sum(len(p['cells']) for p in pages), 'cells;', len(left_out), 'left out')


# --- the readings ---------------------------------------------------------------------------------------------------

def context_crop(image: bytes, box):
    """The cell padded by context, its box outlined in red just outside the ink, as a JPEG."""
    from PIL import Image, ImageDraw
    im = Image.open(io.BytesIO(image)).convert('RGB')
    W, H = im.size
    x0, y0, x1, y1 = box[0] * W, box[1] * H, box[2] * W, box[3] * H
    px, py = max(0.6 * (x1 - x0), 60), max(1.0 * (y1 - y0), 40)
    cx0, cy0, cx1, cy1 = (int(max(0, x0 - px)), int(max(0, y0 - py)), int(min(W, x1 + px)), int(min(H, y1 + py)))
    crop = im.crop((cx0, cy0, cx1, cy1))
    ImageDraw.Draw(crop).rectangle([x0 - cx0 - 3, y0 - cy0 - 3, x1 - cx0 + 3, y1 - cy0 + 3], outline=(230, 0, 0), width=3)
    buf = io.BytesIO(); crop.save(buf, 'JPEG', quality=92)
    return buf.getvalue()


def read():
    jobs = []
    for p in load(STORE / 'picked.json')['pages']:
        image = (STORE / 'images' / (p['id'] + '.jpg')).read_bytes()
        for c in p['cells']:
            crop = context_crop(image, c['box'])
            for route in MODELS:
                dest = STORE / 'read' / route / p['id'] / (c['id'] + '.json')
                jobs.append(lambda route=route, key=f'{p["id"]}/{c["id"]}', crop=crop, dest=dest:
                            call(route, key, crop, READ, dest))
    pool(jobs, 6)
    status()


def norm(s):
    return ' '.join(s.split()).casefold() if isinstance(s, str) else None


def readings(pid, cid):
    out = {}
    for route in MODELS:
        f = STORE / 'read' / route / pid / (cid + '.json')
        v = parse(load(f)['raw']) if f.exists() else None
        out[route] = v if v is not None and isinstance(v.get('text'), str) else None
    return out


def cell_state(pid, cid):
    """agreed (both read the same text in a box both say fits), disputed, or missing."""
    r = readings(pid, cid)
    if any(v is None for v in r.values()):
        return 'missing', r
    if all(v.get('box') == 'fits' for v in r.values()) and len({norm(v['text']) for v in r.values()}) == 1:
        return 'agreed', r
    return 'disputed', r


def status():
    rows = ledger()
    print(f'spent ${spent():.4f} of ${CAP} over {len(rows)} calls; {G.billed_note(rows)}')
    if (STORE / 'picked.json').exists():
        counts = {}
        for p in load(STORE / 'picked.json')['pages']:
            for c in p['cells']:
                s, _ = cell_state(p['id'], c['id'])
                counts[s] = counts.get(s, 0) + 1
        print('cells:', counts)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=('draw', 'propose', 'pick', 'read', 'status'))
    a = ap.parse_args()
    {'draw': draw, 'propose': propose, 'pick': pick, 'read': read, 'status': status}[a.cmd]()


if __name__ == '__main__':
    main()
