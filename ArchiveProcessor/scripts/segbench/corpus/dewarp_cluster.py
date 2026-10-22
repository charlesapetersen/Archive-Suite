#!/usr/bin/env python3
"""W46.enh-dewarp, the cluster half: three open readers on every image the dewarp test made, sent as they are.

  dewarp_cluster.py read --root ROOT --route R [--shard i/n] [--limit N] [--concurrency 16]   # vLLM routes
  dewarp_cluster.py ppocr --root ROOT [--shard i/n] [--limit N]                              # PP-OCRv6

ROOT holds pages.jsonl (one row an image: id "<arm>/<page>", image, sha256; staged by enh_dewarp.py stage),
routes.json (Qwen3.6-27B and LightOnOCR-3 4B with the server settings and prompts the regions run recorded from the
open sweep) and this file with regions_cluster.py beside it. The image bytes are sent unchanged, so an arm differs
from raw only in its pixels; the raw arm is the panel's frozen image, the one each route already read in truth96,
read again here so every comparison is inside one run. The request is the open sweep's whole-page one: the route's
prompt, temperature 0, thinking off, streamed, 8,192 tokens. PP-OCRv6 is truth96's: its pinned detector and
recogniser snapshots and pipeline settings, from that run's prepared.json and recovery/ppocrv6_run.py, read only.
One record an image, ROOT/out/<route>/<arm>/<page>.json, written atomically; an image already there is not read
again, so a rerun after a wall-limit kill reads only what is left. No network beyond localhost, no money.
"""
from __future__ import annotations

from pathlib import Path
import argparse
import concurrent.futures as cf
import hashlib
import http.client
import importlib.util
import json
import os
import sys
import time
import traceback
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parent))
import regions_cluster as R  # noqa: E402  (body, post, atomic, load_pages)

MAX_TOKENS = 8192
TRUTH96 = Path('/scratch/users/cp1/fs-ocr/truth96-20261020')
PPOCR_KEY = 'ppocrv6-medium-native'


def shard(pages, spec):
    i, n = (int(x) for x in spec.split('/'))
    return [p for k, p in enumerate(pages) if k % n == i]


def dest(root, route, page):
    arm, pid = page['id'].split('/')
    return root / 'out' / route / arm / f'{pid}.json'


def cmd_read(a):
    spec = json.loads((a.root / 'routes.json').read_text())[a.route]
    prompt = Path(spec['prompt']).read_text()
    todo = [p for p in shard(R.load_pages(a.root, a.limit), a.shard) if not dest(a.root, a.route, p).exists()]
    url, served = os.environ['FS_URL'], os.environ['FS_SERVED']

    def one(p):
        data = Path(p['image']).read_bytes()
        assert hashlib.sha256(data).hexdigest() == p['sha256'], p['id']
        b = R.body(prompt, data, served)
        b['max_tokens'] = MAX_TOKENS
        t = time.time(); status, error, raw, finish, usage = 'error', None, '', None, {}
        try:
            raw, finish, usage = R.post(url, b)
            status = 'ok' if finish == 'stop' else 'cap' if finish == 'length' else 'error'
        except (urllib.error.URLError, http.client.HTTPException, TimeoutError, OSError, ValueError) as e:
            error = str(e)[:500]
        rec = {'id': p['id'], 'route': a.route, 'model': os.environ.get('FS_MODEL'), 'sha256': p['sha256'],
               'prompt_sha256': hashlib.sha256(prompt.encode()).hexdigest(), 'max_tokens': MAX_TOKENS,
               'raw': raw, 'finish': finish, 'status': status, 'error': error, 'usage': usage,
               'wall_s': round(time.time() - t, 3), 'job': os.environ.get('SLURM_JOB_ID')}
        d = dest(a.root, a.route, p)
        R.atomic(d.with_suffix('.error.json') if status == 'error' else d, rec)
        return status

    summarise(a, todo, one, a.concurrency)


def cmd_ppocr(a):
    prepared = json.loads((TRUTH96 / PPOCR_KEY / 'prepared.json').read_text())
    if prepared['state'] != 'ready':
        raise SystemExit('truth96 PP-OCRv6 preparation is not ready')
    for model in prepared['models'].values():
        for name, digest in model['files'].items():
            with (Path(model['snapshot']) / name).open('rb') as f:
                if hashlib.file_digest(f, 'sha256').hexdigest() != digest:
                    raise SystemExit('PP-OCRv6 model bytes changed')
    spec = importlib.util.spec_from_file_location('ppocrv6_run', TRUTH96 / 'recovery' / 'ppocrv6_run.py')
    run = importlib.util.module_from_spec(spec); spec.loader.exec_module(run)
    ocr = run.pipeline(prepared, 'gpu:0')
    todo = [p for p in shard(R.load_pages(a.root, a.limit), a.shard) if not dest(a.root, 'ppocrv6', p).exists()]

    def one(p):
        assert run.sha(p['image']) == p['sha256'], p['id']
        t = time.monotonic()
        rec = {'id': p['id'], 'route': 'ppocrv6', 'model': PPOCR_KEY, 'sha256': p['sha256'], 'finish': None,
               'job': os.environ.get('SLURM_JOB_ID')}
        try:
            native, text = run.native_result(ocr, p['image'])
            rec.update(raw=text, status='ok' if text.strip() else 'blank', error=None,
                       polys=native['res']['rec_polys'], scores=native['res']['rec_scores'])
        except Exception as exc:  # one page's failure is recorded, not retried
            traceback.print_exc()
            rec.update(raw='', status='error', error=str(exc)[:500])
        rec['wall_s'] = round(time.monotonic() - t, 3)
        d = dest(a.root, 'ppocrv6', p)
        R.atomic(d.with_suffix('.error.json') if rec['status'] == 'error' else d, rec)
        return rec['status']

    summarise(a, todo, one, 1)


def summarise(a, todo, one, concurrency):
    route = getattr(a, 'route', 'ppocrv6')
    start = time.time(); statuses = []
    with cf.ThreadPoolExecutor(concurrency) as ex:
        for m, s in enumerate(ex.map(one, todo), 1):
            statuses.append(s)
            if m % 50 == 0 or m == len(todo):
                print(route, m, '/', len(todo), s, flush=True)
    summary = {'route': route, 'shard': a.shard, 'sent': len(todo), 'ok': statuses.count('ok'),
               'caps': statuses.count('cap'), 'blank': statuses.count('blank'), 'errors': statuses.count('error'),
               'wall_s': round(time.time() - start, 2), 'job': os.environ.get('SLURM_JOB_ID')}
    tag = a.shard.replace('/', 'of')
    R.atomic(a.root / 'out' / route / f'summary-{tag}-{os.environ.get("SLURM_JOB_ID", "local")}.json', summary)
    print(json.dumps(summary), flush=True)
    if summary['errors']:
        raise SystemExit(1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('read'); s.add_argument('--route', required=True); s.add_argument('--concurrency', type=int, default=16)
    s2 = sub.add_parser('ppocr')
    for x in (s, s2):
        x.add_argument('--root', type=Path, required=True); x.add_argument('--shard', default='0/1')
        x.add_argument('--limit', type=int, default=0)
    a = ap.parse_args()
    {'read': cmd_read, 'ppocr': cmd_ppocr}[a.cmd](a)


if __name__ == '__main__':
    main()
