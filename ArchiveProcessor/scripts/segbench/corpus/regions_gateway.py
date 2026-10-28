#!/usr/bin/env python3
"""W46.ocr-regions-paid: Gemini 3.7 Flash, gateway only, one durable $3 ledger.

prepare freezes all 96 owner pages + 3 hash-selected pages of each L9/L4/L3/L1.
The primary comparison is whole / PP regions / tiles. Pilot first (one page per
owner annotation group and public stratum), then inspect the projected cost.
Cached whole owner readings are reused only after exact request-hash validation.
No retries; stopped/capped/invalid crops count as empty, unknown charges stop.
Raw inputs/replies stay outside git. Scoring never makes a network request.
"""
from __future__ import annotations
import argparse
from concurrent.futures import ThreadPoolExecutor
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import threading
import time
import uuid

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent)]
import regions as D
import regions_cluster as C
import routes as R
import gateway_gemini as G
import ocr_panel as P

STORE = G.REHEARSAL / 'ocr-regions-gateway'
PACK = G.REHEARSAL / 'sherlock-results/regions-20261021'
CAP = 3.0
ARMS = ('whole', 'pp-doclayoutv3', 'tiles')
PRICE = G.PRICE  # estimate at the prior bench's conservative .75/3.75 USD/M, not a gateway bill
LOCK = threading.Lock()
STOP = threading.Event()


def sha(b):
    return hashlib.sha256(b).hexdigest()


def body_key(body):
    return sha(json.dumps(body, sort_keys=True).encode())


def save(path, obj):
    P.save(path, obj)


def records():
    f = STORE / 'calls.jsonl'
    return [json.loads(s) for s in f.read_text().splitlines()] if f.exists() else []


def effective():
    out = {}
    for r in records():
        out[r['id']] = r
    return list(out.values())


def spent():
    return sum(r['charge'] for r in effective())


def append(r):
    with (STORE / 'calls.jsonl').open('a') as f:
        f.write(json.dumps(r) + '\n'); f.flush(); os.fsync(f.fileno())


def group(p, panel):
    if p['set'] == 'public895':
        return p['stratum']
    kinds = D.kinds_of(panel[p['id']])
    return next((g for g in D.KINDS if g in kinds), 'other')


def choose(pages, panel):
    """Public draw is by stable id hash, independent of text, accuracy, and crop count."""
    owner = [p for p in pages if p['set'] == 'owner99' and p['id'] not in P.AGREEMENT]
    public = []
    for g in C.STRATA:
        pool = sorted((p for p in pages if p['stratum'] == g),
                      key=lambda p: sha(('W46.ocr-regions-paid/' + p['id']).encode()))
        public += pool[:3]
    chosen = owner + public
    if len(owner) != 96 or len(public) != 12:
        raise ValueError('expected 96 owner + 12 public pages')
    pilot = []
    for g in (*D.KINDS, *C.STRATA):
        pool = sorted((p for p in chosen if group(p, panel) == g), key=lambda p: p['id'])
        if not pool:
            raise ValueError('empty pilot group: ' + g)
        pilot.append(pool[0]['id'])
    return chosen, pilot


def prepare():
    if (STORE / 'manifest.json').exists():
        print('already frozen; use inventory'); return
    pages = C.load_pages(PACK)
    panel = {r['page']: r for r in P.rows()}
    chosen, pilot = choose(pages, panel)
    R.MANIFEST = D.MANIFEST
    public = {R.job_id(r): r for r in R.frozen()}
    pm, jobs = G.panel_manifest()
    owner = {j['page']: j for j in jobs}
    boxes = json.loads((PACK / 'regions/pp-doclayoutv3.json').read_text())['pages']
    frozen = []
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    for p in chosen:
        pid = p['id']
        if p['set'] == 'owner99':
            b = (G.PANEL / 'images' / (owner[pid]['id'] + '.jpg')).read_bytes()
            if sha(b) != owner[pid]['sha256']:
                raise ValueError('panel image changed: ' + pid)
            truth = P.TRUTH / 'truth' / (pid + '.txt')
        else:
            source = public[pid]
            with Image.open(source['image']) as im:
                im = im.convert('RGB'); im.thumbnail((2400, 2400), Image.Resampling.LANCZOS)
                out = io.BytesIO(); im.save(out, 'JPEG', quality=90); b = out.getvalue()
            truth = Path(source['truth'])
        if sha(b) != p['sha256']:
            raise ValueError('image differs from region pack: ' + pid)
        dest = STORE / 'images' / (pid + '.jpg')
        dest.parent.mkdir(parents=True, exist_ok=True); dest.write_bytes(b)
        with Image.open(io.BytesIO(b)) as im:
            w, h = im.size
        crops = {'whole': [{'box': [0, 0, 1, 1], 'px': [0, 0, w, h]}]}
        crops.update({a: C.crops_for(a, p, {'pp-doclayoutv3': boxes}, w, h) for a in ARMS[1:]})
        frozen.append({**p, 'image': str(dest), 'truth': str(truth), 'truth_sha256': sha(truth.read_bytes()),
                       'group': group(p, panel), 'kind': panel[pid]['kind'] if pid in panel else None,
                       'annotations': D.kinds_of(panel[pid]) if pid in panel else [], 'crops': crops})
    save(STORE / 'manifest.json', {'item': 'W46.ocr-regions-paid', 'model': G.MODEL, 'prompt': pm['prompt'],
        'max_tokens': G.MAX_TOKENS, 'price_estimate': PRICE, 'cap': CAP, 'pilot': pilot, 'pages': frozen,
        'scope': '96 owner pages and 3 fixed public pages per L9/L4/L3/L1; PP and tiles, no YOLO or cell arm'})
    inventory()


def manifest():
    m = json.loads((STORE / 'manifest.json').read_text())
    if (m['model'], m['max_tokens'], tuple(m['price_estimate']), m['cap']) != (G.MODEL, G.MAX_TOKENS, PRICE, CAP):
        raise ValueError('frozen settings changed')
    return m


def tasks(m, pilot=False, sets=None, arms=ARMS):
    """sets/arms narrow a collection to a complete slice (e.g. the 96's tiles) when the cap fits no more."""
    return [(p, a, i, c) for p in m['pages'] if (not pilot or p['id'] in m['pilot']) and (not sets or p['set'] in sets)
            for a in arms for i, c in enumerate(p['crops'][a])]


def request(m, job):
    p, arm, i, c = job
    b = Path(p['image']).read_bytes()
    if sha(b) != p['sha256']:
        raise ValueError('frozen image changed: ' + p['id'])
    if arm != 'whole':
        b, _ = C.jpeg_crop(b, c['px'])
    body = G.body(b, m['prompt'])
    return body, body_key(body)


def cached(m, job, body, key):
    p, arm, i, _ = job
    if arm == 'whole' and p['set'] == 'owner99':
        f = G.CACHE / 'panel' / (p['id'] + '-original.json')
        hit = json.loads(f.read_text())
        meta = hit['meta']
        if (meta['request_sha256'] != key or meta['model'] != G.MODEL or meta['finish'] != 'stop'
                or meta['http'] != 200 or not G.parsed(hit)):
            raise ValueError('whole cache is not the same request: ' + p['id'])
        return {'raw': hit['raw'], 'usage': meta['usage'], 'valid': True, 'reused': True,
                'wall_s': meta['wall_s'], 'cost_estimate': G.cost(meta['usage']), 'key': key}
    dest = STORE / 'replies' / (key + '.json')
    if dest.exists():
        hit = json.loads(dest.read_text())
        if hit['key'] != key or hit['request_sha256'] != body_key(body):
            raise ValueError('reply identity changed')
        return hit
    return None


def reservation(body):
    # One text token per UTF-8 byte, 8192 image tokens (prior 2400px whole <=1064),
    # 2048 overhead, and the entire output cap including reasoning. Stop on overrun.
    text = sum(len(p['text'].encode()) for p in body['messages'][0]['content'] if p['type'] == 'text')
    return ((text + 8192 + 2048) * PRICE[0] + body['max_tokens'] * PRICE[1]) / 1e6


def call(m, job):
    body, key = request(m, job)
    with LOCK:
        if STOP.is_set():
            raise RuntimeError('collection stopped after an uncertain request')
        hit = cached(m, job, body, key)
        if hit is not None:
            return hit
        if any(r['request_sha256'] == key for r in effective()):
            raise RuntimeError('already attempted without a cached reply; no automatic retry')
        reserve = reservation(body)
        if spent() + reserve > CAP:
            raise RuntimeError(f'cap: ${spent():.4f} + ${reserve:.4f} > ${CAP}')
        p, arm, i, _ = job
        rec = {'id': uuid.uuid4().hex, 'event': 'reserve', 'charge': reserve, 'request_sha256': key,
               'allowance': reserve, 'page': p['id'], 'arm': arm, 'index': i, 't': time.time()}
        append(rec)
    response = None
    try:
        response = G.request('/chat/completions', body)
        got = response.json()
    except Exception as e:
        with LOCK:
            STOP.set()
            append({**rec, 'event': 'unknown', 'error': type(e).__name__})
        raise RuntimeError('unknown usage: full reservation retained; inspect before any retry') from e
    u = got.get('usage') or {}
    known = all(type(u.get(k)) is int and u[k] >= 0 for k in ('prompt_tokens', 'completion_tokens'))
    cost = G.cost(u) if known else reserve
    choice = (got.get('choices') or [{}])[0]
    raw = (choice.get('message') or {}).get('content')
    parsed = G.parsed({'raw': raw}) if isinstance(raw, str) else None
    valid = (response.status_code == 200 and got.get('model') == G.MODEL
             and choice.get('finish_reason') == 'stop' and bool(parsed) and known)
    hit = {'key': key, 'request_sha256': key, 'raw': raw, 'response': got, 'usage': u, 'valid': valid,
           'reused': False, 'wall_s': round(time.time() - rec['t'], 3), 'cost_estimate': cost}
    with LOCK:
        save(STORE / 'replies' / (key + '.json'), hit)
        append({**rec, 'event': 'settle', 'charge': cost, 'usage': u, 'valid': valid,
                'http': response.status_code, 'finish': choice.get('finish_reason'), 'known': known})
        if not known or cost > reserve or spent() > CAP:
            STOP.set()
            raise RuntimeError('unknown usage or allowance overrun; stop and inspect')
    return hit


def inventory():
    m = manifest()
    for pilot in (True, False):
        jobs = tasks(m, pilot)
        counts = {a: sum(j[1] == a for j in jobs) for a in ARMS}
        print('pilot' if pilot else 'full', counts, 'whole owner baseline reused')
    print(f'item charged/reserved: ${spent():.6f} / ${CAP:.2f}')
    rows = effective()
    if rows:
        counts = {}
        for p in m['pages']:
            mine = [r for r in rows if r['page'] == p['id']]
            expected = sum(len(p['crops'][a]) for a in ARMS if a != 'whole' or p['set'] != 'owner99')
            if len(mine) == expected and all(r['event'] == 'settle' and r.get('known') for r in mine):
                counts.setdefault(p['group'], []).append(sum(r['charge'] for r in mine))
        if counts:
            estimate = sum(sum(counts[p['group']]) / len(counts[p['group']]) for p in m['pages'] if p['group'] in counts)
            print('completed-page cost projection (unmeasured groups excluded):', round(estimate, 4),
                  {k: len(v) for k, v in counts.items()})


def collect(pilot=False, sets=None, arms=ARMS):
    m = manifest()
    if spent() > CAP or any(r['event'] != 'settle' or not r.get('known')
                           or r['charge'] > r['allowance'] for r in effective()):
        raise RuntimeError('unsettled/unknown earlier request; inspect ledger, do not resend')
    verify()
    G.api_key()
    jobs = tasks(m, pilot, sets, arms)
    with ThreadPoolExecutor(max_workers=4) as ex:
        futures = [ex.submit(call, m, job) for job in jobs]
        try:
            for n, f in enumerate(futures, 1):
                f.result()
                if n % 50 == 0:
                    print(f'{n}/{len(jobs)} receipts; item ${spent():.4f}', flush=True)
        except BaseException:
            for f in futures:
                f.cancel()
            raise
    inventory()


def verify():
    """Offline preflight: exact whole baseline, crop inputs, and frozen truth."""
    m = manifest()
    for p in m['pages']:
        if sha(Path(p['truth']).read_bytes()) != p['truth_sha256']:
            raise ValueError('frozen truth changed: ' + p['id'])
    for job in tasks(m):
        body, key = request(m, job)
        cached(m, job, body, key)
    print('offline input/cache checks passed:', len(m['pages']), 'pages', flush=True)


def main():
    global STORE
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('cmd', choices=['prepare', 'verify', 'inventory', 'pilot', 'collect'])
    ap.add_argument('--store', type=Path, default=STORE)
    ap.add_argument('--set', action='append', choices=['owner99', 'public895'], help='collect only these sets')
    ap.add_argument('--arm', action='append', choices=ARMS, help='collect only these arms')
    a = ap.parse_args(); STORE = a.store
    STORE.mkdir(parents=True, exist_ok=True)
    with (STORE / 'collector.lock').open('a') as f:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        {'prepare': prepare, 'verify': verify, 'inventory': inventory,
         'pilot': lambda: collect(True), 'collect': lambda: collect(False, a.set, tuple(a.arm or ARMS))}[a.cmd]()


if __name__ == '__main__':
    main()
