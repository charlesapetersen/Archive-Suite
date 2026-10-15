#!/usr/local/bin/python3
"""W41.ocr-panel-local. Frozen prompt/routes, resumable paid reads, scratch-only outputs.

  ocr_panel.py prepare              # freeze images (2400px ceiling), 99 originals + 40 ladder variants
  ocr_panel.py collect --probe      # three fixed pages per model, then stop and estimate
  ocr_panel.py collect              # remaining calls, total item cap $2 (all attempts count)
  ocr_panel.py vision               # existing Vision helper, under heavy-run.py
  ocr_panel.py report               # aggregate results only, safe for the public repo

Source truth is read-only. Raw page text/usage/catalog live outside git in PANEL_CACHE.
A write-ahead reservation survives interruption: an uncertain call is never silently retried.
Only explicit HTTP errors (no generation) release a reservation. No automatic paid retries.
"""
from __future__ import annotations
import argparse
import base64
import collections
import concurrent.futures as cf
import csv
import fcntl
import hashlib
import io
import json
import math
import os
from pathlib import Path
import subprocess
import time
import threading

import ocr_truth as T

CACHE = Path(os.environ.get('OCR_PANEL_CACHE', Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/ocr-panel-local'))
TRUTH = T.CACHE
RESULTS = Path(__file__).resolve().parents[2] / 'segbench-results'
API = 'https://openrouter.ai/api/v1'
CAP = 2.0
SIDE = 2400
MAX_TOKENS = 8192
AGREEMENT = {'p086', 'p094', 'p096'}
PROBE = {'p010', 'p062', 'p086'}  # clipping, typescript/bullets, difficult handwriting; fixed before calls
# id, endpoint slug, precision, reasoning (None means non-reasoning instruct), total parameters (B)
MODELS = {
 'qwen3.5-9b': ('qwen/qwen3.5-9b', 'deepinfra/bf16', 'bf16', 'off', 9),
 'qwen3.5-27b': ('qwen/qwen3.5-27b', 'siliconflow/fp8', 'fp8', 'off', 27),
 'qwen3.5-35b-a3b': ('qwen/qwen3.5-35b-a3b', 'deepinfra/fp8', 'fp8', 'off', 35),
 'qwen3.6-27b': ('qwen/qwen3.6-27b', 'chutes/fp8', 'fp8', 'off', 27),
 'qwen3.6-35b-a3b': ('qwen/qwen3.6-35b-a3b', 'deepinfra/fp8', 'fp8', 'off', 35),
 'gemma4-26b-a4b': ('google/gemma-4-26b-a4b-it', 'dekallm/bf16', 'bf16', 'off', 26),
 'gemma4-31b': ('google/gemma-4-31b-it', 'crusoe/bf16', 'bf16', 'off', 31),
 'qwen3-vl-8b': ('qwen/qwen3-vl-8b-instruct', 'parasail/bf16', 'bf16', None, 8),
 'qwen3-vl-30b-a3b': ('qwen/qwen3-vl-30b-a3b-instruct', 'deepinfra/fp8', 'fp8', None, 30),
 'mistral-small-24b': ('mistralai/mistral-small-3.2-24b-instruct', 'deepinfra/fp8', 'fp8', None, 24),
 'gemini3.1-flash-lite': ('google/gemini-3.1-flash-lite', 'google-ai-studio', None, 'minimal', None),
}
# Draft PROMPT deliberately unchanged. Replace only the owner's ruled lines.
PROMPT = T.PROMPT.replace('Transcribe all of its text exactly.',
 'Transcribe everything on this sheet of paper, including headers, footers, citations, stamps and copyright lines that a database or archive added to the page.').replace(
 '- A word you cannot read, or one hidden or cut off: write [illegible]. Leave out empty checkboxes and other symbols that are not text.',
 '- A word you cannot read, or one hidden or cut off: write [illegible].\n- Write each bullet point as "*". Leave out empty checkboxes and other symbols that are not text.').replace(
 "- Leave out text from a neighbouring page that shows at the edge of the photograph, and anything that is not on the document itself (an archive's copyright slip, a ruler, a label on the table).",
 '- Leave out only text on a different sheet that shows in the photograph: a page underneath or beside this one, or a folder behind it.').replace(
 "the writing of the page's main text; mixed when no one kind covers most of it",
 "the writing of the page's main text. A handwritten or typed letter on printed letterhead is handwritten or typewritten, not mixed. Text from a computer printer or word processor is typewritten; printed means typeset, as in books, journals, newspapers and printed forms. Mixed when no one kind covers most of it")


def digest(value):
    return hashlib.sha256(value).hexdigest()


def save(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + '.tmp')
    with tmp.open('w') as f:
        f.write(json.dumps(obj, ensure_ascii=False, indent=2)); f.flush(); os.fsync(f.fileno())
    tmp.replace(path)


def rows():
    with (TRUTH / 'pages.tsv').open() as f:
        rr = list(csv.DictReader(f, delimiter='\t'))
    rr = [r for r in rr if r['status'] == 'done' and r['page'] != 'p038']
    if len(rr) != 99 or any(not (TRUTH / 'truth' / (r['page'] + '.txt')).exists() for r in rr):
        raise SystemExit('expected 99 settled pages and their truth files')
    return rr


def prepare():
    CACHE.mkdir(parents=True, exist_ok=True)
    with (CACHE / 'run.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        _prepare()


def _prepare():
    from PIL import Image
    jobs, images = [], {}
    ladder = set(json.loads((TRUTH / 'ladder.json').read_text()))
    for r in rows():
        page = r['page']
        for scale in ('original', 'half', 'quarter') if page in ladder else ('original',):
            src = TRUTH / ('pages' if scale == 'original' else 'ladder') / (page + ('' if scale == 'original' else '-' + scale) + '.jpg')
            with Image.open(src) as im:
                im = im.convert('RGB')
                im.thumbnail((SIDE, SIDE), Image.Resampling.LANCZOS)
                out = io.BytesIO(); im.save(out, 'JPEG', quality=90)
                b = out.getvalue()
                job = {'page': page, 'scale': scale, 'id': page + '-' + scale,
                       'sha256': digest(b), 'width': im.width, 'height': im.height}
            dest = CACHE / 'images' / (job['id'] + '.jpg')
            images[dest] = b
            jobs.append(job)
    manifest = {'jobs': jobs, 'prompt': PROMPT, 'models': MODELS, 'max_tokens': MAX_TOKENS,
                'truth_sha256': digest(b''.join((TRUTH / 'truth' / (r['page'] + '.txt')).read_bytes() for r in rows())),
                'pages_sha256': digest((TRUTH / 'pages.tsv').read_bytes())}
    frozen = CACHE / 'manifest.json'
    if frozen.exists() and json.loads(frozen.read_text()) != json.loads(json.dumps(manifest)):
        raise SystemExit('manifest changed: keep the existing run separate; do not mix prompts/images/truth')
    for dest, b in images.items():
        if dest.exists() and dest.read_bytes() != b:
            raise SystemExit('existing frozen image changed: ' + str(dest))
    for dest, b in images.items():
        if not dest.exists():
            dest.parent.mkdir(parents=True, exist_ok=True); dest.write_bytes(b)
    save(frozen, manifest)
    print(f'{len(jobs)} inputs, {len(rows())} pages; prompt {digest(PROMPT.encode())[:12]}')


def manifest():
    m = json.loads((CACHE / 'manifest.json').read_text())
    if m['prompt'] != PROMPT or m['models'] != json.loads(json.dumps(MODELS)) or m['max_tokens'] != MAX_TOKENS:
        raise SystemExit('run configuration changed')
    if m['pages_sha256'] != digest((TRUTH / 'pages.tsv').read_bytes()) or m['truth_sha256'] != digest(
            b''.join((TRUTH / 'truth' / (r['page'] + '.txt')).read_bytes() for r in rows())):
        raise SystemExit('truth changed during panel')
    return m


def records():
    p = CACHE / 'calls.jsonl'
    return [json.loads(l) for l in p.read_text().splitlines()] if p.exists() else []


def append(obj):
    with (CACHE / 'calls.jsonl').open('a') as f:
        f.write(json.dumps(obj) + '\n'); f.flush(); os.fsync(f.fileno())


def spent():
    return sum(r.get('cost', 0) for r in records())


def endpoint(key):
    """Freeze the public endpoint catalog before any paid call to this model."""
    import requests
    dest = CACHE / 'catalog' / (key + '.json')
    if not dest.exists():
        r = requests.get(API + '/models/' + MODELS[key][0] + '/endpoints', timeout=60)
        r.raise_for_status(); save(dest, r.json())
    es = json.loads(dest.read_text())['data']['endpoints']
    e = next((e for e in es if e['tag'] == MODELS[key][1]), None)
    if e is None or e.get('quantization', 'unknown') != (MODELS[key][2] or 'unknown'):
        raise SystemExit('pinned provider/precision unavailable: ' + key)
    return e


def body(key, job, prices):
    model, provider, precision, effort, _ = MODELS[key]
    image = (CACHE / 'images' / (job['id'] + '.jpg')).read_bytes()
    if digest(image) != job['sha256']:
        raise SystemExit('image changed: ' + job['id'])
    p = {'order': [provider], 'allow_fallbacks': False,
         'max_price': {'prompt': float(prices['prompt']) * 1e6, 'completion': float(prices['completion']) * 1e6}}
    if precision:
        p['quantizations'] = [precision]
    b = {'model': model, 'provider': p, 'temperature': 0, 'max_tokens': MAX_TOKENS,
         'usage': {'include': True}, 'messages': [{'role': 'user', 'content': [
         {'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,' + base64.b64encode(image).decode()}},
         {'type': 'text', 'text': PROMPT}]}]}
    if effort:
        b['reasoning'] = {'enabled': False} if effort == 'off' else {'effort': effort, 'exclude': True}
    return b


def collect(probe=False, only=None):
    import requests
    import method_openrouter as OR
    m = manifest()
    with (CACHE / 'run.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if list((CACHE / 'pending').glob('*.json')):
            raise SystemExit('uncertain paid call: reconcile pending reservation before continuing')
        keys = [only] if only else list(MODELS)
        endpoints = {k: endpoint(k) for k in keys}
        key_secret = OR.api_key()
        mutex, stop = threading.Lock(), threading.Event()
        unavailable = set()

        def one(key, job):
            if stop.is_set() or key in unavailable:
                return
            dest = CACHE / 'responses' / key / (job['id'] + '.json')
            if dest.exists():
                return
            e = endpoints[key]; prices = e['pricing']
            # Entire endpoint context bounds input even when its image tokenizer is unpublished.
            reserve = int(e['context_length']) * float(prices['prompt']) + MAX_TOKENS * float(prices['completion'])
            if not math.isfinite(reserve) or reserve <= 0:
                raise RuntimeError('invalid price reservation: ' + key)
            b = body(key, job, prices)
            pending = CACHE / 'pending' / (key + '-' + job['id'] + '.json')
            rec = {'key': key, 'job': job['id'], 'page': job['page'], 'scale': job['scale'],
                   'provider_slug': MODELS[key][1], 'precision': MODELS[key][2] or 'unpublished',
                   'model': MODELS[key][0], 'request_sha256': digest(json.dumps(b, sort_keys=True).encode()),
                   'reserve': reserve, 't': time.time()}
            with mutex:
                if stop.is_set() or key in unavailable:
                    return
                held = sum(json.loads(p.read_text())['reserve'] for p in (CACHE / 'pending').glob('*.json'))
                if spent() + held + reserve > CAP:
                    stop.set()
                    raise RuntimeError(f'cap: ${spent():.6f} spent + ${held + reserve:.6f} reserved, cap ${CAP:.2f}')
                save(pending, rec)
            start = time.time()
            try:
                r = requests.post(API + '/chat/completions', json=b, timeout=300,
                      headers={'Authorization': 'Bearer ' + key_secret, 'Content-Type': 'application/json'})
                if r.status_code != 200:
                    with mutex:
                        if 400 <= r.status_code < 500:
                            append({**rec, 'cost': 0, 'status': 'http-rejected', 'http': r.status_code})
                            pending.unlink()
                            unavailable.add(key)  # one rejected route must not prevent the others being tested
                            print(f'{key}: HTTP {r.status_code}; route deferred, no generated response', flush=True)
                            if r.status_code in (401, 402):
                                raise RuntimeError('authentication/credit failure')
                            return
                    raise RuntimeError(f'{key}: uncertain HTTP {r.status_code}; reservation retained')
                j = r.json(); save(dest.with_suffix('.raw.json'), j)
                u = j.get('usage') or {}; c = (j.get('choices') or [{}])[0]
                cost = u.get('cost')
                if not isinstance(cost, (float, int)) or not math.isfinite(cost) or cost < 0 or 'error' in j:
                    raise RuntimeError('uncertain cost/body error; raw response and reservation retained')
                got = T.parse_draft((c.get('message') or {}).get('content') or '')
                ok = bool(got) and c.get('finish_reason') == 'stop'
                meta = {**rec, 'cost': cost, 'status': 'ok' if ok else 'failed', 'provider': j.get('provider'),
                        'generation_id': j.get('id'), 'returned_model': j.get('model'),
                        'prompt_tokens': u.get('prompt_tokens'), 'completion_tokens': u.get('completion_tokens'),
                        'reasoning_tokens': (u.get('completion_tokens_details') or {}).get('reasoning_tokens'),
                        'finish': c.get('finish_reason'), 'wall_s': round(time.time() - start, 3)}
                with mutex:
                    append(meta)
                    save(dest, {'meta': meta, 'parsed': got if ok else None})
                    pending.unlink()
                    if cost > reserve or spent() > CAP:
                        raise RuntimeError('provider exceeded price/context reservation; stop')
                    print(f"{key} {job['id']} {meta['status']} ${cost:.5f} total ${spent():.5f}", flush=True)
            except requests.RequestException:
                stop.set()
                raise RuntimeError('uncertain network outcome; reservation preserved: ' + str(pending)) from None
            except Exception:
                stop.set()
                raise

        todo = [(k, j) for j in m['jobs'] for k in keys
                if not probe or (j['page'] in PROBE and j['scale'] == 'original')]
        with cf.ThreadPoolExecutor(max_workers=int(os.environ.get('OCR_PANEL_CONCURRENCY', 4))) as ex:
            futures = [ex.submit(one, k, j) for k, j in todo]
            # Settle in-flight reservations even after a failure; already-authorized calls may finish; queued calls are not authorized after stop.
            errors = []
            for f in futures:
                try:
                    f.result()
                except Exception as err:
                    errors.append(str(err))
            if errors:
                raise SystemExit('; '.join(dict.fromkeys(errors)))
    estimate()


def estimate():
    rr = records()
    print(f'ITEM SPENT ${spent():.6f}')
    total = 0
    for key in MODELS:
        calls = [r for r in rr if r['key'] == key and r['status'] in ('ok', 'failed')]
        if not calls:
            continue
        avg = sum(r['cost'] for r in calls) / len(calls)
        total += avg * len(manifest()['jobs'])
        print(f'{key}: n={len(calls)}, ${avg:.6f}/input; projected 139 inputs ${avg * 139:.3f}')
    print(f'projection all paid routes ${total:.3f} (sample estimate, not a spend authorization)')


def vision():
    m = manifest(); paths = []
    for j in m['jobs']:
        paths.append(str(CACHE / 'images' / (j['id'] + '.jpg')) + '\t' + str(CACHE / 'vision' / (j['id'] + '.txt')))
    jobs = CACHE / 'vision-jobs.tsv'; jobs.write_text('\n'.join(paths) + '\n')
    subprocess.run([str(T.OCR_BIN), str(jobs)], check=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('command', choices=['prepare', 'collect', 'estimate', 'vision'])
    ap.add_argument('--probe', action='store_true')
    ap.add_argument('--only', choices=list(MODELS))
    a = ap.parse_args()
    {'prepare': prepare, 'collect': lambda: collect(a.probe, a.only), 'estimate': estimate, 'vision': vision}[a.command]()

if __name__ == '__main__':
    main()
