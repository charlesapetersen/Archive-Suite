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
RETRY_UNKNOWN = False  # set only by an explicit --retry-unknown, after the unknown lines were inspected


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


REFUSED = (429, 502, 503)   # rate limit, front-end/proxy refusal, service unavailable: no model is reached


def front_end_error(r):
    """A 429/502/503 whose body is an HTML error page, not JSON: the gateway's front end answered and no model ran
    (2026-10-28: /models itself returned the same 502 page during the outage). Charged $0. A transport failure
    with no status, a 500/504 (upstream work may have run) or any other body stays unknown at its full allowance."""
    return (r.get('http') in REFUSED and r.get('error') == 'JSONDecodeError'
            and '<html' in (r.get('body') or '').lower())


def gateway_refusal(status, got):
    """A 429/502/503 JSON error with no choices and no usage, e.g. 2026-10-28's 503 'authentication database is
    temporarily unreachable': refused before any model ran. $0, and never cached as a reading of the crop."""
    return (status in REFUSED and isinstance(got, dict) and isinstance(got.get('error'), dict)
            and not got.get('choices') and not got.get('usage'))


def reclassify():
    """Append $0 'rejected' lines for recorded unknowns that front_end_error identifies, and for settled replies
    that gateway_refusal identifies (whose reply file is renamed *.refused.json so it is not scored as a reading
    and the request may be sent again with --retry-unknown). Never edits a ledger line."""
    n = 0
    for r in effective():
        if r['event'] == 'unknown' and front_end_error(r):
            append({**r, 'event': 'rejected', 'charge': 0.0}); n += 1
        elif r['event'] == 'settle' and not r.get('known'):
            f = STORE / 'replies' / (r['request_sha256'] + '.json')
            hit = json.loads(f.read_text()) if f.exists() else None
            if hit and gateway_refusal(r.get('http'), hit['response']):
                f.rename(f.with_suffix('.refused.json'))
                append({**r, 'event': 'rejected', 'charge': 0.0, 'body': json.dumps(hit['response'])[:500]}); n += 1
    print(f'{n} gateway refusals reclassified at $0; item ${spent():.4f}')


def call(m, job):
    body, key = request(m, job)
    with LOCK:
        if STOP.is_set():
            raise RuntimeError('collection stopped after an uncertain request')
        hit = cached(m, job, body, key)
        if hit is not None:
            return hit
        tried = [r for r in effective() if r['request_sha256'] == key]
        # A $0 refusal (nothing served) may be sent again; an unknown only with the explicit flag.
        if tried and not all(r['event'] == 'rejected' or (RETRY_UNKNOWN and r['event'] == 'unknown') for r in tried):
            raise RuntimeError('already attempted without a cached reply; no automatic retry')
        # A deliberate retry of an unknown request keeps the earlier full allowance charged: never optimistic.
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
        if not isinstance(got, dict):
            raise TypeError('reply is not a JSON object')
    except Exception as e:
        with LOCK:
            STOP.set()
            u = {**rec, 'event': 'unknown', 'error': type(e).__name__,
                 'http': getattr(response, 'status_code', None), 'body': (getattr(response, 'text', '') or '')[:500]}
            append(u)
            if front_end_error(u):
                append({**u, 'event': 'rejected', 'charge': 0.0})
                raise RuntimeError(f"gateway front end refused ({u['http']}); nothing served, stopped") from e
        raise RuntimeError('unknown usage: full reservation retained; inspect before any retry') from e
    if gateway_refusal(response.status_code, got):
        with LOCK:
            STOP.set()
            append({**rec, 'event': 'rejected', 'charge': 0.0, 'http': response.status_code,
                    'body': json.dumps(got)[:500]})
        raise RuntimeError(f'gateway refused ({response.status_code}); nothing served, stopped')
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
    rows = effective()
    settled = {r['request_sha256'] for r in rows if r['event'] == 'settle'}
    if spent() > CAP or any(r['event'] == 'reserve'
                           or (r['event'] == 'unknown' and r['request_sha256'] not in settled and not RETRY_UNKNOWN)
                           or (r['event'] == 'settle' and not r.get('known'))
                           or r['charge'] > r['allowance'] for r in rows):
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


ROUTE = 'gemini-3.7-flash-gw'
OUT = G.RESULTS / 'bench-corpus'
NAME = 'regions-gateway-20261028'


def receipt(m, job, ledger):
    """A crop's reading, re-checked from the stored response and its settled ledger line, not the stored flag.
    A missing receipt is an error (no silent partial export); an invalid or capped reply is a failed crop."""
    p, arm, i, _ = job
    body, key = request(m, job)
    if arm == 'whole' and p['set'] == 'owner99':
        hit = cached(m, job, body, key)   # raises unless the exact earlier request, HTTP 200, stop, parsed
        return {'text': G.parsed(hit)['text'], 'valid': True, 'usage': hit['usage'], 'cost': hit['cost_estimate'], 'new': 0.0}
    f = STORE / 'replies' / (key + '.json')
    if not f.exists():
        raise ValueError(f'missing receipt: {p["id"]}/{arm}/{i}')
    hit = json.loads(f.read_text())
    led = ledger.get(key)
    if hit['key'] != key or hit['request_sha256'] != body_key(body) or led is None or led['event'] != 'settle':
        raise ValueError(f'receipt identity or ledger differs: {p["id"]}/{arm}/{i}')
    got, u = hit['response'], hit['usage']
    choice = (got.get('choices') or [{}])[0]
    known = all(type(u.get(k)) is int and u[k] >= 0 for k in ('prompt_tokens', 'completion_tokens'))
    parsed = G.parsed({'raw': hit['raw']}) if isinstance(hit['raw'], str) else None
    valid = (led['http'] == 200 and got.get('model') == G.MODEL and choice.get('finish_reason') == 'stop'
             and bool(parsed) and known)
    if valid != hit['valid'] or not known or abs(led['charge'] - G.cost(u)) > 1e-9:
        raise ValueError(f'receipt does not re-validate: {p["id"]}/{arm}/{i}')
    return {'text': parsed['text'] if valid else '', 'valid': valid, 'usage': u, 'cost': led['charge'], 'new': led['charge']}


def present(m, p, arm, ledger):
    """Every receipt of one page's arm is on disk and settled (the reused whole readings of the 96 always are)."""
    if arm == 'whole' and p['set'] == 'owner99':
        return True
    return all((STORE / 'replies' / (request(m, (p, arm, i, c))[1] + '.json')).exists()
               and request(m, (p, arm, i, c))[1] in ledger for i, c in enumerate(p['crops'][arm]))


def score():
    """Network-free: the 96 owner pages (all three arms) and the public pilot pages, a labelled subset."""
    import ocr_panel_score as S
    import ocr_scorers as O
    m = manifest()
    verify()
    ledger = {r['request_sha256']: r for r in effective() if r['event'] == 'settle'}
    panel = {r['page']: r for r in P.rows()}
    pages = [p for p in m['pages'] if p['set'] == 'owner99' or p['id'] in m['pilot']]
    owner = [p for p in pages if p['set'] == 'owner99']
    # An arm is on the 96 only when every owner page has every receipt; otherwise only its pilot pages are scored.
    full = [a for a in ARMS if all(present(m, p, a, ledger) for p in owner)]
    if 'whole' not in full:
        raise ValueError('whole-page readings of the 96 are incomplete')
    page_rows, table_markup = [], []
    for p in pages:
        ref = Path(p['truth']).read_text()
        pilot = p['id'] in m['pilot']
        for arm in ARMS:
            if p['set'] == 'owner99':
                groups = (['the 96', *D.kinds_of(panel[p['id']]), 'kind:' + panel[p['id']]['kind']] if arm in full else [])
                groups += ['owner pilot'] if pilot else []
            else:
                groups = [p['stratum']]
            if not groups:
                continue
            got = [{'index': i, 'box': c['box'], **receipt(m, (p, arm, i, c), ledger)} for i, c in enumerate(p['crops'][arm])]
            good = [g for g in got if g['text']]
            text = D.stitch(arm, good) if good else ''
            sc = S.score(ref, text, p['stratum']) if p['set'] == 'public895' else S.score(ref, text)
            if 'tables' in groups:
                table_markup.append({'route': ROUTE, 'arm': arm, 'page': p['id'], 'strict': sc['nes'],
                                     'markup_stripped': S.score(ref, O.strip_markup(text))['nes'],
                                     'has_markup': O.has_markup(text)})
            order = O.reading_order_edit(ref, text) if text else None
            page_rows.append({'set': p['set'], 'groups': ';'.join(groups), 'route': ROUTE, 'arm': arm, 'page': p['id'],
                              'ok': bool(text), **sc, 'order_edit': (order or {}).get('edit'),
                              'crops': len(got) if arm != 'whole' else '', 'crops_failed': sum(not g['valid'] for g in got) if arm != 'whole' else '',
                              'prompt_tokens': sum(g['usage']['prompt_tokens'] for g in got),
                              'completion_tokens': sum(g['usage']['completion_tokens'] for g in got),
                              'cost': round(sum(g['cost'] for g in got), 6), 'new_cost': round(sum(g['new'] for g in got), 6)})
    rows = []
    for arm in ARMS:
        mine = [r for r in page_rows if r['arm'] == arm]
        for g in sorted({g for r in mine for g in r['groups'].split(';')}):
            rr = [r for r in mine if g in r['groups'].split(';')]
            ids = {r['page'] for r in rr}
            same = [r for r in page_rows if r['arm'] == 'whole' and r['page'] in ids]
            if len(same) != len(rr):
                raise ValueError(f'{arm}/{g}: whole-page pairs missing')
            row = {'group': g, 'route': ROUTE, 'arm': arm, **D.score_rows(rr, S),
                   'whole_nes_same': round(S.aggregate(same)['nes'], 4), 'cost': round(sum(r['cost'] for r in rr), 6)}
            if arm != 'whole':
                d = S.paired([r['nes'] for r in sorted(rr, key=lambda r: r['page'])],
                             [r['nes'] for r in sorted(same, key=lambda r: r['page'])])
                row['paired'] = {k: round(v, 4) for k, v in d.items()}
            rows.append(row)
    OUT.mkdir(parents=True, exist_ok=True)
    S.write_csv(OUT / f'{NAME}-pages.csv', [{k: round(v, 6) if isinstance(v, float) else v for k, v in r.items()}
                                            for r in page_rows],
                ['set', 'groups', 'route', 'arm', 'page', 'ok', 'nes', 'chrf', 'words', 'missed', 'added', 'order_edit',
                 'crops', 'crops_failed', 'prompt_tokens', 'completion_tokens', 'cost', 'new_cost'])
    item = sum(r['charge'] for r in effective())
    out = {'report': f'bench-corpus/{NAME}.md', 'route': ROUTE, 'model': G.MODEL, 'arms': list(ARMS), 'rows': rows,
           'table_markup': [{'route': ROUTE, 'arm': arm, 'n': len(t),
                             **{k: round(sum(r[k] for r in t) / len(t), 6) for k in ('strict', 'markup_stripped')},
                             'markup_pages': sum(r['has_markup'] for r in t)}
                            for arm in ARMS for t in [[r for r in table_markup if r['arm'] == arm]] if t],
           'owner_pages': 96, 'arms_on_the_96': full,
           'owner_pilot_pages': sorted(p['id'] for p in owner if p['id'] in m['pilot']), 'public_pilot_pages': sorted(p['id'] for p in pages if p['set'] == 'public895'),
           'price_estimate_usd_per_m': list(PRICE), 'item_spend_estimate': round(item, 4),
           'calls_new': sum(r['event'] == 'settle' for r in effective())}
    (OUT / f'{NAME}.json').write_text(json.dumps(out, indent=2) + '\n')
    (OUT / f'{NAME}.md').write_text(report_md(out))
    print(report_md(out))


def report_md(out):
    by = {(r['group'], r['arm']): r for r in out['rows']}
    arm = {'whole': 'whole page', 'pp-doclayoutv3': 'PP-DocLayoutV3 regions', 'tiles': 'overlapping tiles'}
    L = ['# Gemini 3.7 Flash on the whole page, PP-DocLayoutV3 regions and overlapping tiles (W46.ocr-regions-paid)', '',
         'Stanford AI API gateway, temperature 0, low reasoning, 8,192 output tokens, the panel prompt, the same frozen '
         '2,400 px images and crop geometry as W46.ocr-regions (`corpus/regions_gateway.py`). NES is the panel scorer; '
         'a page or crop that returned nothing counts as empty. Whole-page readings of the 96 are the earlier gateway '
         'item\'s, reused after exact request-hash checks. Prices are estimates at '
         f"${out['price_estimate_usd_per_m'][0]}/${out['price_estimate_usd_per_m'][1]} per million tokens; the gateway "
         f"returns no bill. This item's settled new calls: {out['calls_new']}, about ${out['item_spend_estimate']:.2f}.", '',
         '## The 96 owner pages', '',
         '| group | arm | NES % | answered | Δ whole (points, 95% CI) | failed / crops | cost / 1,000 pages |',
         '|---|---|---:|---:|---:|---:|---:|']
    groups = ['the 96', 'kind:typewritten', 'kind:printed', 'kind:handwritten', *D.KINDS]
    for g in groups:
        for a in ARMS:
            r = by.get((g, a))
            if not r:
                continue
            d = r.get('paired')
            delta = '—' if not d else f"{100 * d['delta']:+.1f} ({100 * d['lo']:+.1f} to {100 * d['hi']:+.1f})"
            L.append(f"| {g} ({r['n']}) | {arm[a]} | {100 * r['nes']:.1f} | {r['ok']}/{r['n']} | {delta} | "
                     f"{'—' if a == 'whole' else str(r['crops_failed']) + '/' + str(r['crops'])} | "
                     f"${1000 * r['cost'] / r['n']:.2f} |")
    missing = [arm[a] for a in ARMS if a not in out['arms_on_the_96']]
    if missing:
        L += ['', f"Not read on the 96: {', '.join(missing)} — the item's $3 cap did not fit it (residual W46.ocr-regions-paid-pp).",
              '', f"## Owner pilot pages ({len(out['owner_pilot_pages'])}, one an annotation group — every arm, a labelled sample)", '',
              '| arm | NES % | Δ whole (points) | failed / crops |', '|---|---:|---:|---:|']
        for a in ARMS:
            r = by.get(('owner pilot', a))
            if r:
                delta = '—' if a == 'whole' else f"{100 * (r['nes'] - r['whole_nes_same']):+.1f}"
                crops = '—' if a == 'whole' else f"{r['crops_failed']}/{r['crops']}"
                L.append(f"| {arm[a]} | {100 * r['nes']:.1f} | {delta} | {crops} |")
    L += ['', f"## Public pilot pages ({len(out['public_pilot_pages'])}, one a stratum — a labelled sample, not a set result)",
          '', 'The other eight frozen public pages were not read: the full scope projected above the $3 item cap.', '',
          '| stratum | arm | NES % | failed / crops | order edit |', '|---|---|---:|---:|---:|']
    for g in ('L9', 'L4', 'L3', 'L1'):
        for a in ARMS:
            r = by.get((g, a))
            if r:
                L.append(f"| {g} | {arm[a]} | {100 * r['nes']:.1f} | "
                         f"{'—' if a == 'whole' else str(r['crops_failed']) + '/' + str(r['crops'])} | "
                         f"{r['order_edit'] if r['order_edit'] != '' else '—'} |")
    t = {r['arm']: r for r in out['table_markup']}
    if t:
        L += ['', '## Table pages: strict NES against NES with markup stripped (diagnostic)', '',
              '| arm | pages | strict | markup stripped | pages with markup |', '|---|---:|---:|---:|---:|']
        L += [f"| {arm[a]} | {r['n']} | {100 * r['strict']:.1f} | {100 * r['markup_stripped']:.1f} | {r['markup_pages']} |"
              for a, r in t.items()]
    return '\n'.join(L) + '\n'


def main():
    global STORE, RETRY_UNKNOWN
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('cmd', choices=['prepare', 'verify', 'inventory', 'pilot', 'collect', 'score', 'reclassify'])
    ap.add_argument('--store', type=Path, default=STORE)
    ap.add_argument('--set', action='append', choices=['owner99', 'public895'], help='collect only these sets')
    ap.add_argument('--arm', action='append', choices=ARMS, help='collect only these arms')
    ap.add_argument('--retry-unknown', action='store_true',
                    help='resend requests whose only attempts are unknown; their allowances stay charged')
    a = ap.parse_args(); STORE = a.store
    RETRY_UNKNOWN = a.retry_unknown
    STORE.mkdir(parents=True, exist_ok=True)
    with (STORE / 'collector.lock').open('a') as f:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        {'prepare': prepare, 'verify': verify, 'inventory': inventory,
         'pilot': lambda: collect(True), 'collect': lambda: collect(False, a.set, tuple(a.arm or ARMS)), 'score': score, 'reclassify': reclassify}[a.cmd]()


if __name__ == '__main__':
    main()
