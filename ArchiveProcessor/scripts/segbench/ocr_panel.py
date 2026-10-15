#!/usr/local/bin/python3
"""W41.ocr-panel-local. Frozen prompt/routes, resumable paid reads, scratch-only outputs.

  ocr_panel.py prepare              # freeze images (2400px ceiling), 99 originals + 40 ladder variants
  ocr_panel.py collect --probe      # three fixed pages per model, then stop and estimate
  ocr_panel.py collect              # remaining calls, total item cap $2 (all attempts count)
  ocr_panel.py vision               # existing Vision helper, under heavy-run.py
  ocr_panel.py reconcile            # bound uncertain charges by the key's UTC-day billing
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


def insured_empty_error(j):
    """OpenRouter's zero-completion insurance covers explicit empty provider errors.

    https://openrouter.ai/blog/announcements/never-pay-for-empty-ai-responses-again/
    Unknown/malformed replies and network timeouts still retain their full reservations.
    A reported cost always takes precedence over this policy inference.
    """
    return (isinstance(j, dict) and (j.get('error') or {}).get('code') in (502, 503)
            and not j.get('choices') and (j.get('usage') or {}).get('cost') is None
            and (j.get('usage') or {}).get('completion_tokens') in (None, 0)
            and ((j.get('usage') or {}).get('completion_tokens_details') or {}).get('reasoning_tokens') in (None, 0))


def unbilled_error_reply(j):
    """A 200 reply whose every choice ended in 'error' with no content, and no usage at all.

    Its generation lookup has returned 404 every time (p003, p005, p080-quarter), so nothing can price it.
    Such a call is charged its whole reservation as a ceiling and cached as failed; it does not stop the run.
    """
    ch = j.get('choices') if isinstance(j, dict) else None
    return (isinstance(ch, list) and bool(ch) and 'usage' not in j and not j.get('error')
            and all(isinstance(c, dict) and c.get('finish_reason') == 'error'
                    and not (c.get('message') or {}).get('content') for c in ch))


def rejected_error_reply(j):
    """A saved 4xx error body (a 429 from a shared upstream pool) with no choices and no usage at all.

    The runner records such a reply as http-rejected at no cost and leaves the job for a later pass; a session
    killed between saving the body and recording it leaves the same reply behind a pending reservation.
    """
    e = j.get('error') if isinstance(j, dict) else None
    code = e.get('code') if isinstance(e, dict) else None
    return (isinstance(code, int) and 400 <= code < 500 and not j.get('choices') and 'usage' not in j)


def ceiling_failure(rec, j):
    return {**rec, 'cost': rec['reserve'], 'cost_upper_bound': True, 'status': 'failed', 'finish': 'error',
            'provider': j.get('provider'), 'generation_id': j.get('id'), 'returned_model': j.get('model'),
            'http': 200, 'cost_policy_zero': False}


def reservation(endpoint):
    """Whole-context bound; the cloud pilot supplies documented image bounds separately."""
    return (int(endpoint['context_length']) * float(endpoint['pricing']['prompt'])
            + MAX_TOKENS * float(endpoint['pricing']['completion']))


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
            reserve = reservation(e)
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
                try:
                    j = r.json()
                except ValueError:
                    save(dest.with_suffix('.raw.json'), {'http': r.status_code, 'body': r.text})
                    raise RuntimeError('unparseable reply; reservation and raw body retained')
                save(dest.with_suffix('.raw.json'), j)
                insured = insured_empty_error(j)
                reported_cost = (j.get('usage') or {}).get('cost')
                completion_evidence = bool(j.get('choices') or (j.get('usage') or {}).get('completion_tokens'))
                if r.status_code != 200 and not insured and reported_cost is None:
                    with mutex:
                        if 400 <= r.status_code < 500 and not completion_evidence:
                            append({**rec, 'cost': 0, 'status': 'http-rejected', 'http': r.status_code})
                            pending.unlink()
                            unavailable.add(key)
                            print(f'{key}: HTTP {r.status_code}; route deferred, no generated response', flush=True)
                            if r.status_code in (401, 402):
                                raise RuntimeError('authentication/credit failure')
                            return
                    raise RuntimeError(f'{key}: uncertain HTTP {r.status_code}; reservation retained')
                if r.status_code == 200 and unbilled_error_reply(j):
                    with mutex:
                        meta = ceiling_failure(rec, j)
                        append(meta)
                        save(dest, {'meta': meta, 'parsed': None})
                        pending.unlink()
                        print(f"{key} {job['id']} failed, unbilled error reply; ceiling ${reserve:.5f} "
                              f"total ${spent():.5f}", flush=True)
                    return
                u = j.get('usage') or {}; c = (j.get('choices') or [{}])[0]
                cost = 0 if insured else u.get('cost')
                if not isinstance(cost, (float, int)) or not math.isfinite(cost) or cost < 0:
                    raise RuntimeError('uncertain cost/body error; raw response and reservation retained')
                got = T.parse_draft((c.get('message') or {}).get('content') or '')
                ok = bool(got) and c.get('finish_reason') == 'stop' and not j.get('error') and r.status_code == 200
                meta = {**rec, 'cost': cost, 'status': 'ok' if ok else 'failed', 'provider': j.get('provider'),
                        'generation_id': j.get('id'), 'returned_model': j.get('model'),
                        'prompt_tokens': u.get('prompt_tokens'), 'completion_tokens': u.get('completion_tokens'),
                        'reasoning_tokens': (u.get('completion_tokens_details') or {}).get('reasoning_tokens'),
                        'finish': c.get('finish_reason'), 'wall_s': round(time.time() - start, 3),
                        'cost_policy_zero': insured, 'http': r.status_code,
                        'error_code': (j.get('error') or {}).get('code')}
                with mutex:
                    append(meta)
                    save(dest, {'meta': meta, 'parsed': got if ok else None})
                    pending.unlink()
                    if (cost > reserve or spent() > CAP
                            or (e.get('_input_bound') and u.get('prompt_tokens', 0) > e['_input_bound'])):
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
        # Schedule largest reservations first, so cheap calls can use the final budget headroom.
        todo.sort(key=lambda kj: -reservation(endpoints[kj[0]]))
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


SETTLE_S = 600


def key_usage_daily():
    import requests
    import method_openrouter as OR
    r = requests.get(API + '/key', headers={'Authorization': 'Bearer ' + OR.api_key()}, timeout=60)
    r.raise_for_status()
    return r.json()['data']['usage_daily']


def reconcile(usage=None, now=None, after=None):
    """Bound every uncertain charge by the key's own billing for the current UTC day.

    The key's usage_daily covers the whole ledger only when every call is in this UTC day; anything else on
    the key only raises it, so usage_daily minus the measured charges bounds ALL uncertain calls together.
    Each uncertain call is then charged that whole bound (n times a joint ceiling). Interrupted pending
    reservations become cached failures, never retried.
    """
    with (CACHE / 'run.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        now = time.time() if now is None else now
        pend = sorted((CACHE / 'pending').glob('*.json'))
        for p in list(pend):
            h = json.loads(p.read_text())
            raw = CACHE / 'responses' / h['key'] / (h['job'] + '.raw.json')
            j = json.loads(raw.read_text()) if raw.exists() else None
            if j is not None and unbilled_error_reply(j):
                # The runner's own rule for this reply, applied after an older runner stopped on it.
                meta = ceiling_failure(h, j)
                append(meta)
                save(CACHE / 'responses' / h['key'] / (h['job'] + '.json'), {'meta': meta, 'parsed': None})
                p.unlink(); pend.remove(p)
                print(f"{h['key']} {h['job']}: unbilled error reply cached at its ${h['reserve']:.5f} ceiling")
            elif j is not None and rejected_error_reply(j):
                # The runner's rule for a 4xx with no generation: no charge, and the job stays open for a retry.
                append({**h, 'cost': 0, 'status': 'http-rejected', 'http': j['error']['code']})
                p.unlink(); pend.remove(p)
                print(f"{h['key']} {h['job']}: HTTP {j['error']['code']} reply released at no cost")
        rr = records()  # after the conversions above, so the ledger rewrite below keeps them
        held = [json.loads(p.read_text()) for p in pend]
        n = sum(bool(r.get('cost_upper_bound')) for r in rr) + len(held)
        if not n:
            print('nothing uncertain'); return
        if any((CACHE / 'responses' / h['key'] / (h['job'] + '.raw.json')).exists() for h in held):
            raise SystemExit('a pending call saved a reply; reconcile it from that body, not the key total')
        midnight = (now // 86400) * 86400  # epoch days are UTC days
        ts = [r['t'] for r in rr + held]
        if min(ts) < midnight:
            raise SystemExit('ledger spans UTC days; usage_daily cannot bound it')
        if now - max(ts) < SETTLE_S:
            raise SystemExit(f'newest call is under {SETTLE_S}s old; billing may not have settled')
        fetched = usage is None
        usage = key_usage_daily() if fetched else usage
        # usage_daily resets at UTC midnight: a fetch that lands in the next day bounds nothing.
        if after is None:
            after = time.time() if fetched else now
        if after >= midnight + 86400:
            raise SystemExit('UTC day ended before the key usage was read; run reconcile again')
        if not isinstance(usage, (int, float)) or not math.isfinite(usage):
            raise SystemExit('unusable key usage')
        measured = sum(r.get('cost', 0) for r in rr if not r.get('cost_upper_bound'))
        bound = usage - measured
        if bound < -1e-6:
            raise SystemExit(f'key usage ${usage:.6f} is below measured charges ${measured:.6f}; refusing')
        bound = math.ceil(max(bound, 0) * 1e6 + 1) / 1e6
        if n * bound >= sum(r['cost'] for r in rr if r.get('cost_upper_bound')) + sum(h['reserve'] for h in held):
            print('key bound is no tighter than the reservations; unchanged'); return
        stamp = time.strftime('%Y%m%dT%H%M%S', time.gmtime(now))
        basis = {'cost_basis': 'key-usage-daily', 'key_usage_daily': usage, 'reconciled_t': now}
        save(CACHE / 'reconciliation' / ('key-usage-' + stamp + '.json'),
             {'usage_daily': usage, 'measured': measured, 'bound_each': bound, 'uncertain': n,
              'prior_ledger': rr, 'pending': held})
        out = []
        for r in rr:
            if r.get('cost_upper_bound'):
                r = {**r, **basis, 'reserve_ceiling': r.get('reserve_ceiling', r['cost']), 'cost': bound}
                dest = CACHE / 'responses' / r['key'] / (r['job'] + '.json')
                if dest.exists():
                    save(dest, {**json.loads(dest.read_text()), 'meta': r})
            out.append(r)
        for h in held:
            r = {**h, **basis, 'cost': bound, 'cost_upper_bound': True, 'reserve_ceiling': h['reserve'],
                 'status': 'failed', 'finish': 'interrupted'}
            save(CACHE / 'responses' / r['key'] / (r['job'] + '.json'), {'meta': r, 'parsed': None})
            out.append(r)
        tmp = CACHE / 'calls.jsonl.tmp'
        with tmp.open('w') as f:
            f.write(''.join(json.dumps(r) + '\n' for r in out)); f.flush(); os.fsync(f.fileno())
        tmp.replace(CACHE / 'calls.jsonl')
        for p in pend:
            p.unlink()
        print(f'{n} uncertain calls bounded at ${bound:.6f} each (key ${usage:.6f} - measured ${measured:.6f})')


def vision():
    m = manifest(); paths = []
    for j in m['jobs']:
        paths.append(str(CACHE / 'images' / (j['id'] + '.jpg')) + '\t' + str(CACHE / 'vision' / (j['id'] + '.txt')))
    jobs = CACHE / 'vision-jobs.tsv'; jobs.write_text('\n'.join(paths) + '\n')
    subprocess.run([str(T.OCR_BIN), str(jobs)], check=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('command', choices=['prepare', 'collect', 'estimate', 'vision', 'reconcile'])
    ap.add_argument('--probe', action='store_true')
    ap.add_argument('--only', choices=list(MODELS))
    a = ap.parse_args()
    {'prepare': prepare, 'collect': lambda: collect(a.probe, a.only), 'estimate': estimate, 'vision': vision, 'reconcile': reconcile}[a.command]()

if __name__ == '__main__':
    main()
