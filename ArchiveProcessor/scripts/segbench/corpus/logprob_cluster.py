#!/usr/bin/env python3
"""W46.ocr-logprob, the cluster half: one route reads a page list again with each generated token's
log-probability kept. Runs inside the job's vLLM session (FS_URL, FS_SERVED, FS_MODEL set by logprob-job.sh);
no network beyond localhost, no money.

  logprob_cluster.py --pages PAGES.jsonl --prompt PROMPT.txt --out DIR [--concurrency 8] [--check]

The request is the open sweep's collector's (`open-sweep-20261019/<model>/ocr/ocr_run.py`) unchanged — the same
image bytes, the route's own prompt file (empty = the image alone), temperature 0, thinking off, 8,192 tokens,
streamed — plus `logprobs: true` (top_logprobs 0: only the chosen token's). vLLM's default logprobs mode is the raw
model output before any processing, so at temperature 0 each value is log P(greedy token).

Each record keeps the open sweep's fields plus `lp` (one float per generated token, 5 decimals) and `tokens` (the
token strings). Caps stay terminal, as in the sweep; transport errors go to <id>.error.json for a rerun. --check
exits non-zero unless every ok record has one log-probability per completion token (the pilot gate).
"""
from pathlib import Path
import argparse
import base64
import concurrent.futures as cf
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request


def body(prompt, jpeg, served, max_tokens=8192):
    content = [{'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,' + base64.b64encode(jpeg).decode()}}]
    if prompt:
        content.append({'type': 'text', 'text': prompt})
    return {'model': served, 'messages': [{'role': 'user', 'content': content}], 'temperature': 0,
            'max_tokens': max_tokens, 'stream': True, 'stream_options': {'include_usage': True},
            'chat_template_kwargs': {'enable_thinking': False}, 'logprobs': True, 'top_logprobs': 0}


def chunk_logprobs(choice):
    """(token, logprob) pairs of one streamed choice delta; [] when the chunk carries none."""
    lp = choice.get('logprobs') or {}
    return [(c.get('token'), c.get('logprob')) for c in (lp.get('content') or [])]


def check(out):
    bad = []
    for p in sorted(out.glob('*.json')):
        if p.name == 'summary.json':
            continue
        r = json.loads(p.read_text())
        n = (r.get('usage') or {}).get('completion_tokens')
        if r['status'] == 'ok' and (not r['lp'] or (n is not None and len(r['lp']) != n)):
            bad.append((r['id'], len(r['lp']), n))
    print('check:', 'ok' if not bad else bad[:5], flush=True)
    return not bad


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--pages', type=Path, required=True)
    ap.add_argument('--prompt', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--concurrency', type=int, default=8)
    ap.add_argument('--check', action='store_true')
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    prompt = a.prompt.read_text()
    rows = [json.loads(x) for x in a.pages.read_text().splitlines() if x.strip()]
    assert len({r['id'] for r in rows}) == len(rows)
    for r in rows:
        assert hashlib.sha256(Path(r['image']).read_bytes()).hexdigest() == r['sha256'], r['id']
    todo = [r for r in rows if not (a.out / (r['id'] + '.json')).exists()]

    def one(r):
        data = Path(r['image']).read_bytes()
        req = urllib.request.Request(os.environ['FS_URL'] + '/v1/chat/completions',
                                     json.dumps(body(prompt, data, os.environ['FS_SERVED'])).encode(),
                                     {'Content-Type': 'application/json'})
        t = time.time(); raw = ''; finish = None; usage = {}; status = 'error'; error = None; lp = []; toks = []
        try:
            with urllib.request.urlopen(req, timeout=900) as resp:
                for line in resp:
                    if time.time() - t > 900:
                        raise TimeoutError('generation exceeded 900 seconds')
                    if not line.startswith(b'data:'):
                        continue
                    s = line[5:].strip()
                    if s == b'[DONE]':
                        break
                    j = json.loads(s); usage = j.get('usage') or usage
                    for c in j.get('choices') or []:
                        raw += (c.get('delta') or {}).get('content') or ''; finish = c.get('finish_reason') or finish
                        for tok, x in chunk_logprobs(c):
                            toks.append(tok); lp.append(None if x is None else round(max(x, -1e4), 5))
            status = 'ok' if finish == 'stop' else 'cap' if finish == 'length' else 'error'
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as e:
            error = str(e)[:500]
        record = {**r, 'label': os.environ['FS_SERVED'], 'model': os.environ['FS_MODEL'], 'raw': raw, 'finish': finish,
                  'status': status, 'error': error, 'usage': usage, 'wall_s': round(time.time() - t, 3),
                  'job': os.environ.get('SLURM_JOB_ID'), 'lp': lp, 'tokens': toks}
        dest = a.out / (r['id'] + ('.error.json' if status == 'error' else '.json'))
        tmp = dest.with_suffix('.part'); tmp.write_text(json.dumps(record, ensure_ascii=False)); tmp.replace(dest)
        return status

    start = time.time(); statuses = []
    with cf.ThreadPoolExecutor(a.concurrency) as ex:
        for n, status in enumerate(ex.map(one, todo), 1):
            statuses.append(status)
            if n % 20 == 0 or n == len(todo):
                print(a.pages.name, n, '/', len(todo), status, flush=True)
    summary = {'pages': a.pages.name, 'expected': len(rows), 'sent': len(todo), 'ok': statuses.count('ok'),
               'caps': statuses.count('cap'), 'errors': statuses.count('error'), 'wall_s': round(time.time() - start, 2),
               'concurrency': a.concurrency, 'model': os.environ['FS_MODEL'], 'job': os.environ.get('SLURM_JOB_ID')}
    (a.out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary), flush=True)
    if a.check and not check(a.out):
        sys.exit(2)


if __name__ == '__main__':
    main()
