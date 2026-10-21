#!/usr/bin/env python3
"""W46.ocr-loops, the cluster half: read one route's capped pages again under one arm. Runs inside the job's
vLLM session (FS_URL, FS_SERVED, FS_MODEL set by serve.sh); no network beyond localhost, no money.

  loop_rerun_cluster.py --caps CAPS.jsonl --prompt PROMPT.txt --arm ngram|half --out DIR [--concurrency 8]

The request is the open sweep's collector's (`open-sweep-20261019/<model>/ocr/ocr_run.py`) unchanged: the same
image bytes, the route's own prompt file (empty = the image alone), temperature 0, thinking off, 8,192 tokens,
streamed. One thing differs per arm:

  ngram  `vllm_xargs` {ngram_size 4, window_size 8192}: vLLM's NGramPerReqLogitsProcessor (the server must be
         started with --logits-processors vllm.model_executor.models.deepseek_ocr:NGramPerReqLogitsProcessor).
         A window as long as the reply makes it Hugging Face's no_repeat_ngram_size=4: no 4-token sequence of the
         reply may occur twice.
  half   the same JPEG decoded and re-encoded at half its long edge (2400 -> 1200 px, Lanczos, JPEG 90); the
         processor is loaded but not asked for, so decoding is the plain greedy one.

Each page's record keeps the open sweep's fields plus `arm`, `arm_settings` and `sent_px`/`sent_sha256` (the bytes
actually sent). Caps stay terminal, as in the sweep; transport errors go to <id>.error.json for a rerun.
"""
from pathlib import Path
import argparse
import base64
import concurrent.futures as cf
import hashlib
import io
import json
import os
import time
import urllib.error
import urllib.request

NGRAM = {'ngram_size': 4, 'window_size': 8192}
HALF_JPEG_QUALITY = 90


def half(data):
    from PIL import Image
    im = Image.open(io.BytesIO(data))
    im.load()
    w, h = im.size
    im = im.convert('RGB').resize((max(1, round(w / 2)), max(1, round(h / 2))), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, 'JPEG', quality=HALF_JPEG_QUALITY)
    return buf.getvalue(), im.size


def body(arm, prompt, jpeg, served, max_tokens=8192):
    content = [{'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,' + base64.b64encode(jpeg).decode()}}]
    if prompt:
        content.append({'type': 'text', 'text': prompt})
    b = {'model': served, 'messages': [{'role': 'user', 'content': content}], 'temperature': 0,
         'max_tokens': max_tokens, 'stream': True, 'stream_options': {'include_usage': True},
         'chat_template_kwargs': {'enable_thinking': False}}
    if arm == 'ngram':
        b['vllm_xargs'] = dict(NGRAM)
    return b


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--caps', type=Path, required=True)
    ap.add_argument('--prompt', type=Path, required=True)
    ap.add_argument('--arm', choices=['ngram', 'half'], required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--concurrency', type=int, default=8)
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    prompt = a.prompt.read_text()
    rows = [json.loads(x) for x in a.caps.read_text().splitlines() if x.strip()]
    assert len({r['id'] for r in rows}) == len(rows)
    for r in rows:
        assert hashlib.sha256(Path(r['image']).read_bytes()).hexdigest() == r['sha256'], r['id']
    todo = [r for r in rows if not (a.out / (r['id'] + '.json')).exists()]
    settings = dict(NGRAM) if a.arm == 'ngram' else {'scale': 0.5, 'jpeg_quality': HALF_JPEG_QUALITY}

    def one(r):
        data = Path(r['image']).read_bytes()
        px = None
        if a.arm == 'half':
            data, px = half(data)
        req = urllib.request.Request(os.environ['FS_URL'] + '/v1/chat/completions',
                                     json.dumps(body(a.arm, prompt, data, os.environ['FS_SERVED'])).encode(),
                                     {'Content-Type': 'application/json'})
        t = time.time(); raw = ''; finish = None; usage = {}; status = 'error'; error = None
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
            status = 'ok' if finish == 'stop' else 'cap' if finish == 'length' else 'error'
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as e:
            error = str(e)[:500]
        record = {**r, 'label': os.environ['FS_SERVED'], 'model': os.environ['FS_MODEL'], 'arm': a.arm,
                  'arm_settings': settings, 'sent_px': px, 'sent_sha256': hashlib.sha256(data).hexdigest(),
                  'raw': raw, 'finish': finish, 'status': status, 'error': error, 'usage': usage,
                  'wall_s': round(time.time() - t, 3), 'job': os.environ.get('SLURM_JOB_ID')}
        dest = a.out / (r['id'] + ('.error.json' if status == 'error' else '.json'))
        tmp = dest.with_suffix('.part'); tmp.write_text(json.dumps(record, ensure_ascii=False)); tmp.replace(dest)
        return status

    start = time.time(); statuses = []
    with cf.ThreadPoolExecutor(a.concurrency) as ex:
        for n, status in enumerate(ex.map(one, todo), 1):
            statuses.append(status)
            if n % 20 == 0 or n == len(todo):
                print(a.arm, n, '/', len(todo), status, flush=True)
    summary = {'arm': a.arm, 'settings': settings, 'expected': len(rows), 'sent': len(todo),
               'ok': statuses.count('ok'), 'caps': statuses.count('cap'), 'errors': statuses.count('error'),
               'wall_s': round(time.time() - start, 2), 'concurrency': a.concurrency, 'model': os.environ['FS_MODEL'],
               'job': os.environ.get('SLURM_JOB_ID')}
    (a.out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary), flush=True)
    if summary['errors']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
