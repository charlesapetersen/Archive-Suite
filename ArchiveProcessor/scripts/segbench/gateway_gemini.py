#!/usr/bin/env python3
"""W46.fix-ocr-scorers-paid. Gemini 3.7 Flash through the Stanford AI API gateway, on two sets:

  python3 gateway_gemini.py models          # the gateway's model entry for MODEL (frozen into CACHE)
  python3 gateway_gemini.py chaos           # the 20 CHAOS pages -> chaos/readings/gemini3.7-flash-gw/
  python3 gateway_gemini.py panel           # the owner's 96 (99 settled jobs), the cloud panel's images and prompt
  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy \
      python gateway_gemini.py report       # 3.7 (gateway) against the cached 3.8 (OpenRouter) -> segbench-results/

The 3.7-against-3.8 check: later gateway arms of the W46 review run Gemini 3.7 Flash, because the gateway does not
serve 3.8, while the bench's cached Gemini figures are 3.8 Flash through OpenRouter (W41.ocr-panel-cloud). This
reads the same 99 images with the same prompt, temperature 0 and low reasoning, so a later arm can say how far its
3.7 figure sits from the 3.8 one. The gateway is real money on a Stanford PTA (root CLAUDE.md): CAP bounds this
item's spend, counted from the gateway's token usage at Google's list price for the model (the gateway does not
return a cost), and the ledger is CACHE/calls.jsonl.

The key is the Processor's gateway key (Keychain service com.archiveprocessor.app, account Gateway), read into
memory once, never printed or written. Images, replies and readings stay in the cache (the owner's material).
"""
from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]

API = 'https://aiapi-prod.stanford.edu/v1'
MODEL = 'gemini-3.7-flash'
LABEL = 'gemini3.7-flash-gw'
REHEARSAL = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
CACHE = REHEARSAL / 'gateway-gemini'
PANEL = REHEARSAL / 'ocr-panel-cloud'          # the 3.8 run: manifest, images, responses/gemini3.8-flash
CHAOS = REHEARSAL / 'ocr-scorers/chaos'
RESULTS = HERE.parents[1] / 'segbench-results'
# $ per million tokens (input, output incl. reasoning), used only to count spend against CAP and labelled an
# estimate: the gateway returns no cost and publishes no price. Gemini 3.8 Flash's standard list rate (OpenRouter's
# catalog, 2026-10-15: $0.75 / $3.75; flex is half), taken as a ceiling for the older 3.7.
PRICE = (0.75, 3.75)
CAP = 1.00            # the item's total; under the $3 rule with room to spare
MAX_TOKENS = 8192     # the panel's; 3.7 spends reasoning tokens first, so a small cap returns no text
_key = None


def api_key() -> str:
    """Read once from the Keychain into memory. Never printed or written."""
    global _key
    if _key is None:
        r = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', 'com.archiveprocessor.app',
                            '-a', 'Gateway', '-w'], capture_output=True, text=True)
        if r.returncode != 0 or not r.stdout.strip():
            raise SystemExit('no gateway key in the Keychain (com.archiveprocessor.app / Gateway)')
        _key = r.stdout.strip()
    return _key


def request(path, body=None, timeout=300):
    import requests
    h = {'Authorization': 'Bearer ' + api_key()}
    if body is None:
        return requests.get(API + path, headers=h, timeout=timeout)
    return requests.post(API + path, headers=h, json=body, timeout=timeout)


def ledger():
    f = CACHE / 'calls.jsonl'
    return [json.loads(x) for x in f.read_text().splitlines()] if f.exists() else []


def spent():
    return sum(r.get('cost', 0) for r in ledger())


def cost(usage):
    p = usage.get('prompt_tokens') or 0
    c = usage.get('completion_tokens') or 0
    return (p * PRICE[0] + c * PRICE[1]) / 1e6


def models():
    r = request('/models', timeout=60)
    r.raise_for_status()
    entry = next((m for m in r.json().get('data', []) if m.get('id') == MODEL), None)
    if entry is None:
        raise SystemExit(MODEL + ' is not on the gateway')
    CACHE.mkdir(parents=True, exist_ok=True)
    (CACHE / 'model.json').write_text(json.dumps(entry, indent=1))
    print(json.dumps(entry, indent=1))


def body(image: bytes, prompt: str):
    return {'model': MODEL, 'temperature': 0, 'max_tokens': MAX_TOKENS, 'reasoning_effort': 'low',
            'messages': [{'role': 'user', 'content': [
                {'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,' + base64.b64encode(image).decode()}},
                {'type': 'text', 'text': prompt}]}]}


def call(set_name, job_id, image: bytes, prompt: str, dest: Path):
    """One reading, cached by destination; the ledger line is written before the reply is used."""
    if dest.exists():
        return json.loads(dest.read_text())
    if spent() + 0.06 > CAP:   # a page's worst case at MAX_TOKENS output is about $0.03
        raise SystemExit(f'cap: ${spent():.4f} spent of ${CAP}')
    b = body(image, prompt)
    t = time.time()
    for attempt in range(3):
        r = request('/chat/completions', b)
        if r.status_code in (429, 500, 502, 503, 504) and attempt < 2:
            time.sleep(10 * (attempt + 1)); continue
        break
    got = r.json() if r.headers.get('content-type', '').startswith('application/json') else {'raw': r.text[:2000]}
    usage = got.get('usage') or {}
    rec = {'set': set_name, 'job': job_id, 'http': r.status_code, 't': t, 'wall_s': round(time.time() - t, 3),
           'model': got.get('model'), 'usage': usage, 'cost': round(cost(usage), 6),
           'request_sha256': hashlib.sha256(json.dumps(b, sort_keys=True).encode()).hexdigest()}
    CACHE.mkdir(parents=True, exist_ok=True)
    with (CACHE / 'calls.jsonl').open('a') as f:
        f.write(json.dumps(rec) + '\n')
    choice = (got.get('choices') or [{}])[0]
    out = {'meta': {**rec, 'finish': choice.get('finish_reason')},
           'raw': (choice.get('message') or {}).get('content') if r.status_code == 200 else None,
           'error': None if r.status_code == 200 else got}
    if r.status_code == 200:
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(json.dumps(out, ensure_ascii=False, indent=1))
    else:
        print(job_id, r.status_code, json.dumps(got)[:300])
    return out


def parsed(reply):
    import ocr_truth as T
    raw = reply.get('raw') if reply else None
    if not raw:
        return None
    return T.parse_draft(raw)


def run(set_name, jobs, prompt, concurrency=4):
    """jobs: [(id, image bytes, dest)]."""
    def one(j):
        return j[0], call(set_name, j[0], j[1], prompt, j[2])
    with ThreadPoolExecutor(concurrency) as ex:
        res = list(ex.map(one, jobs))
    bad = [i for i, r in res if not parsed(r)]
    print(f'{set_name}: {len(res) - len(bad)}/{len(res)} parsed, ${spent():.4f} spent in all; unparsed: {bad}')
    return dict(res)


def panel_manifest():
    m = json.loads((PANEL / 'manifest.json').read_text())
    return m, [j for j in m['jobs'] if j['scale'] == 'original']


def panel():
    m, jobs = panel_manifest()
    todo = []
    for j in jobs:
        image = (PANEL / 'images' / (j['id'] + '.jpg')).read_bytes()
        if hashlib.sha256(image).hexdigest() != j['sha256']:
            raise SystemExit('image changed: ' + j['id'])
        todo.append((j['id'], image, CACHE / 'panel' / (j['id'] + '.json')))
    run('panel', todo, m['prompt'])


def chaos():
    m, _ = panel_manifest()
    rows = [json.loads(x) for x in (CHAOS / 'chaos20.jsonl').read_text().splitlines()]
    todo = []
    for r in rows:
        image = Path(r['image']).read_bytes()
        if hashlib.sha256(image).hexdigest() != r['sha256']:
            raise SystemExit('image changed: ' + r['id'])
        todo.append((r['id'], image, CACHE / 'chaos' / (r['id'] + '.json')))
    res = run('chaos', todo, m['prompt'])
    out = CHAOS / 'readings' / LABEL
    out.mkdir(parents=True, exist_ok=True)
    for i, reply in res.items():
        p = parsed(reply)
        if p:
            (out / (i + '.txt')).write_text(p['text'])


def report():
    import ocr_panel as P
    import ocr_panel_score as S
    m, jobs = panel_manifest()
    by_page = {r['page']: r for r in P.rows()}
    rows, detail = [], []
    for j in jobs:
        page = j['page']
        truth = (P.TRUTH / 'truth' / (page + '.txt')).read_text()
        old = json.loads((PANEL / 'responses/gemini3.8-flash' / (j['id'] + '.json')).read_text())
        f = CACHE / 'panel' / (j['id'] + '.json')
        new = parsed(json.loads(f.read_text())) if f.exists() else None
        o = old.get('parsed')
        full = S.score(truth, new['text'] if new else '')
        detail.append({**full, 'ok': bool(new), 'kind': by_page[page]['kind'], 'agreement': page in P.AGREEMENT})
        rows.append({'page': page, 'agreement': page in P.AGREEMENT, 'kind': by_page[page]['kind'],
                     'ok38': bool(o), 'ok37': bool(new),
                     'nes38': S.score(truth, o['text'])['nes'] if o else 0.0,
                     'nes37': S.score(truth, new['text'])['nes'] if new else 0.0,
                     'kind38': o['kind'] == by_page[page]['kind'] if o else None,
                     'kind37': new['kind'] == by_page[page]['kind'] if new else None})
    scored = [r for r in rows if not r['agreement']]
    both = [r for r in scored if r['ok38'] and r['ok37']]
    mean = lambda xs: sum(xs) / len(xs) if xs else float('nan')
    diff = S.paired([r['nes37'] for r in both], [r['nes38'] for r in both])
    agreement = {j['id'] for j in jobs if j['page'] in P.AGREEMENT}
    calls = [c for c in ledger() if c['set'] == 'panel' and c['http'] == 200 and c['job'] not in agreement]
    usage = {k: sum((c['usage'].get(k) or 0) for c in calls) for k in ('prompt_tokens', 'completion_tokens')}
    reasoning = sum(((c['usage'].get('completion_tokens_details') or {}).get('reasoning_tokens') or 0) for c in calls)
    old_cost = sum(json.loads((PANEL / 'responses/gemini3.8-flash' / (j['id'] + '.json')).read_text())['meta'].get('cost', 0)
                   for j in jobs if not j['page'] in P.AGREEMENT)
    kinds = sorted({r['kind'] for r in scored})
    by_kind = {k: {'pages': sum(1 for r in both if r['kind'] == k),
                   'nes38': mean([r['nes38'] for r in both if r['kind'] == k]),
                   'nes37': mean([r['nes37'] for r in both if r['kind'] == k])} for k in kinds}
    out = {'model_new': MODEL + ' via the Stanford gateway', 'model_old': 'google/gemini-3.8-flash via OpenRouter',
           'pages': len(scored), 'read38': sum(r['ok38'] for r in scored), 'read37': sum(r['ok37'] for r in scored),
           'nes38_all': mean([r['nes38'] for r in scored]), 'nes37_all': mean([r['nes37'] for r in scored]),
           'both': len(both), 'nes38_both': mean([r['nes38'] for r in both]), 'nes37_both': mean([r['nes37'] for r in both]),
           'paired_37_minus_38': diff,
           'kind_correct38': sum(1 for r in scored if r['kind38']), 'kind_correct37': sum(1 for r in scored if r['kind37']),
           'by_kind': by_kind,
           'cost37_list_estimate': sum(c['cost'] for c in calls), 'cost38_openrouter': old_cost,
           'usage37': {**usage, 'reasoning_tokens': reasoning},
           'wall37_s_median': sorted(c['wall_s'] for c in calls)[len(calls) // 2] if calls else None,
           'price_assumed': PRICE, 'pages_detail': rows}
    (RESULTS / 'gemini37-vs-38.json').write_text(json.dumps(out, indent=1))
    pct = lambda x: f'{100 * x:.1f}'
    L = ['# Gemini 3.7 Flash (Stanford gateway) against Gemini 3.8 Flash (OpenRouter) on the owner\'s 96 (W46.fix-ocr-scorers-paid)', '',
         'The same 96 scored pages (99 settled jobs less the three agreement pages), the same images (2,400 px, the cloud '
         'panel\'s), the same prompt, temperature 0 and low reasoning. 3.8 is the cached W41.ocr-panel-cloud reading; 3.7 '
         'was read on ' + time.strftime('%Y-%m-%d') + ' through the gateway (`scripts/segbench/gateway_gemini.py`). NES is the '
         'panel\'s score (`ocr_panel_score.score`), a failed page counting 0. Later gateway arms that run 3.7 should read '
         'their figures against 3.8\'s with the difference below in mind.', '',
         '| | Gemini 3.8 Flash | Gemini 3.7 Flash |', '|---|---:|---:|',
         f"| pages read | {out['read38']}/{out['pages']} | {out['read37']}/{out['pages']} |",
         f"| NES, all 96 (failure = 0) | {pct(out['nes38_all'])} | {pct(out['nes37_all'])} |",
         f"| NES, the {out['both']} both read | {pct(out['nes38_both'])} | {pct(out['nes37_both'])} |",
         f"| kind right | {out['kind_correct38']} | {out['kind_correct37']} |",
         f"| cost of the 96 | ${old_cost:.3f} (OpenRouter, billed) | ${out['cost37_list_estimate']:.3f} (estimate, at 3.8's list ${PRICE[0]}/${PRICE[1]} per M) |",
         '', f"Paired difference, 3.7 less 3.8, on the {out['both']} pages both read: "
         f"{100 * diff['delta']:+.2f} NES points (95% bootstrap {100 * diff['lo']:+.2f} to {100 * diff['hi']:+.2f}; "
         f"permutation p {diff['p']:.3f}).", '',
         '| kind | pages | 3.8 NES | 3.7 NES |', '|---|---:|---:|---:|']
    for k, v in by_kind.items():
        L.append(f"| {k} | {v['pages']} | {pct(v['nes38'])} | {pct(v['nes37'])} |")
    L += ['', f"3.7 used {usage['prompt_tokens']:,} input and {usage['completion_tokens']:,} output tokens "
          f"({reasoning:,} of them reasoning) on the 96; median {out['wall37_s_median']} s a page."]
    # The cloud panel's two formats, so ArchiveOCRBench draws 3.7 on the 96's charts beside the panel's routes.
    detail = [d for d in detail if not d['agreement']]
    a = S.aggregate(detail)
    per_page = out['cost37_list_estimate'] / len(scored)
    L += ['', '## Original pages (96, excluding the agreement-only letters)', '',
          '| route | completed / attempted / 96 | NES % | chrF2 % | words missed % | words added % | kind right % | cost / page |',
          '|---|---:|---:|---:|---:|---:|---:|---:|',
          f"| {LABEL} · Stanford AI API gateway | {a['ok']}/{len(scored)}/{len(scored)} | {100 * a['nes']:.2f} | "
          f"{100 * a['chrf']:.2f} | {100 * a['miss']:.2f} | {100 * a['add']:.2f} | "
          f"{round(100 * out['kind_correct37'] / len(scored))} | ${per_page:.5f} (estimate) |"]
    with (RESULTS / 'gemini37-vs-38-groups.csv').open('w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['route', 'attribute', 'value', 'n', 'ok', 'nes', 'chrf', 'miss', 'add', 'words'])
        for k in sorted({d['kind'] for d in detail}):
            g = S.aggregate([d for d in detail if d['kind'] == k])
            w.writerow([LABEL, 'kind', k, g['n'], g['ok'], g['nes'], g['chrf'], g['miss'], g['add'], g['words']])
    (RESULTS / 'gemini37-vs-38.md').write_text('\n'.join(L) + '\n')
    print('\n'.join(L))


def probe():
    """One page, to check the request shape and the usage fields before a run."""
    m, jobs = panel_manifest()
    j = jobs[0]
    reply = call('probe', j['id'], (PANEL / 'images' / (j['id'] + '.jpg')).read_bytes(), m['prompt'],
                 CACHE / 'probe' / (j['id'] + '.json'))
    print(json.dumps(reply['meta'], indent=1)); print((reply.get('raw') or '')[:300])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['models', 'probe', 'chaos', 'panel', 'report'])
    {'models': models, 'probe': probe, 'chaos': chaos, 'panel': panel, 'report': report}[ap.parse_args().command]()


if __name__ == '__main__':
    main()
