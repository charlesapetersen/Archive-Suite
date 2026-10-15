#!/usr/bin/env python3
"""W41.farmshare-plan. The W41 OCR panel's prompt against a local vLLM server, for FarmShare.

  fs_ocr.py pack  --out /tmp/fs-truthpack            # on the Mac: the 99 frozen truth pages, for scp
  fs_ocr.py truth --pack DIR --out DIR --label L     # on a GPU node: read, score as the panel does, time it
  fs_ocr.py news  --newsbench DIR --out DIR --label L
  fs_ocr.py bulk  --in DIR --out DIR [--shard I/N] [--deadline EPOCH]

The server is started by job.sbatch (`vllm serve`, OpenAI-compatible, localhost only). Nothing here calls a paid
API or the network beyond that server. The prompt, image cap and max_tokens are imported from ocr_panel.py, so a
FarmShare score is the same measurement as the OpenRouter rows, at FarmShare's precision.

Bulk is resumable: a page whose <image name>.txt exists is skipped, every file is written to a temporary name and
renamed, and a page that fails is logged to failed-<shard>.jsonl (not retried in the same run; a rerun retries it).
A page the server never answered counts as still to do, and eight such in a row stop the run with exit 75.
"""
from __future__ import annotations
import argparse
import base64
import concurrent.futures as cf
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import threading
import time
import urllib.error
import urllib.request

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import ocr_panel as P  # noqa: E402  (PROMPT, SIDE, MAX_TOKENS, AGREEMENT; no I/O at import)
import ocr_truth as T  # noqa: E402  (parse_draft)

IMAGES = {'.jpg', '.jpeg', '.png', '.tif', '.tiff', '.webp'}
STRATA = ('page', 'kind', 'table_form', 'handwritten', 'clippings', 'tables')  # no identity columns leave the Mac
NEWS_SIDE = 3584      # broadsheets are 2453-5975 px wide; 2400 loses small type
NEWS_MAX_TOKENS = 16384  # NewsBench gold runs to 5,464 words a page


def atomic_write(path: Path, data: bytes):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f'.tmp{os.getpid()}')
    with tmp.open('wb') as f:
        f.write(data); f.flush(); os.fsync(f.fileno())
    tmp.replace(path)


def jpeg(src: Path, side: int) -> bytes:
    """The panel's preparation: RGB, long side capped (never upscaled), JPEG quality 90."""
    from PIL import Image
    with Image.open(src) as im:
        im = im.convert('RGB')
        im.thumbnail((side, side), Image.Resampling.LANCZOS)
        out = io.BytesIO(); im.save(out, 'JPEG', quality=90)
        return out.getvalue()


class Server:
    def __init__(self, url, model, max_tokens, thinking_off):
        self.url, self.model, self.max_tokens, self.thinking_off = url.rstrip('/'), model, max_tokens, thinking_off

    def read(self, image: bytes, timeout=1800):
        b = {'model': self.model, 'temperature': 0, 'max_tokens': self.max_tokens, 'messages': [{'role': 'user', 'content': [
            {'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,' + base64.b64encode(image).decode()}},
            {'type': 'text', 'text': P.PROMPT}]}]}
        if self.thinking_off:  # the panel ran reasoning off; Qwen3.5/3.6 chat templates honour this switch
            b['chat_template_kwargs'] = {'enable_thinking': False}
        req = urllib.request.Request(self.url + '/v1/chat/completions', json.dumps(b).encode(),
                                     {'Content-Type': 'application/json'})
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                j = json.loads(r.read())
        except urllib.error.HTTPError as e:  # the server answered and refused this page (e.g. 400): the page failed
            return None, {'status': 'rejected', 'error': f'{e.code} {e.read()[:300]!r}', 'wall_s': time.time() - t0}
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as e:  # no answer: transient, not the page
            return None, {'status': 'error', 'error': repr(e)[:300], 'wall_s': time.time() - t0}
        c = j['choices'][0]; u = j.get('usage') or {}
        raw = (c.get('message') or {}).get('content') or ''
        meta = {'finish': c.get('finish_reason'), 'prompt_tokens': u.get('prompt_tokens'),
                'completion_tokens': u.get('completion_tokens'), 'wall_s': round(time.time() - t0, 3)}
        # As the panel: a reply cut off at max_tokens is a failure, not a short transcript.
        parsed = T.parse_draft(raw) if meta['finish'] == 'stop' else None
        meta['status'] = 'ok' if parsed else 'unparsed'
        return {'raw': raw, 'parsed': parsed}, meta


DEAD_SERVER = 8  # this many 'error' replies in a row: the server is gone, stop instead of failing every page


def run_all(server, items, concurrency, deadline=None, on_done=None):
    """items: (id, image-bytes-thunk). Returns {id: (reply, meta)} and the wall time from first send to last reply.
    An image that cannot be opened is that page's failure ('unreadable'); it never stops the run."""
    out, lock, stop, streak = {}, threading.Lock(), threading.Event(), [0]

    def work(item):
        if stop.is_set() or (deadline and time.time() > deadline):
            stop.set(); return
        key, load = item
        try:
            image = load()
        except Exception as e:  # corrupt file, unsupported format, Pillow's decompression-bomb limit
            reply, meta = None, {'status': 'unreadable', 'error': repr(e)[:300]}
        else:
            # An in-flight read may run past the deadline by at most 10 min (job.sbatch leaves 15).
            timeout = 1800 if not deadline else max(60, min(1800, deadline - time.time() + 600))
            reply, meta = server.read(image, timeout)
        with lock:
            out[key] = (reply, meta)
            streak[0] = streak[0] + 1 if meta['status'] == 'error' else 0
            if streak[0] >= DEAD_SERVER:
                stop.set()
        if on_done:
            on_done(key, reply, meta)

    t0 = time.time()
    with cf.ThreadPoolExecutor(concurrency) as ex:
        list(ex.map(work, items))
    return out, time.time() - t0


def throughput(results, wall, gpus):
    ok = [m for _, m in results.values() if m['status'] == 'ok']
    return {'pages': len(results), 'ok': len(ok), 'wall_s': round(wall, 1), 'gpus': gpus,
            'pages_per_hour_per_gpu': round(len(results) / wall * 3600 / gpus, 1) if wall else None,
            'mean_prompt_tokens': sum(m['prompt_tokens'] or 0 for m in ok) / len(ok) if ok else None,
            'mean_completion_tokens': sum(m['completion_tokens'] or 0 for m in ok) / len(ok) if ok else None}


def env_info():
    keys = ('SLURM_JOB_ID', 'SLURM_JOB_PARTITION', 'SLURM_JOB_QOS', 'SLURMD_NODENAME', 'CUDA_VISIBLE_DEVICES',
            'FS_MODEL', 'FS_PRESET', 'FS_VLLM_ARGS')
    from importlib import metadata
    try:
        vllm = metadata.version('vllm')
    except metadata.PackageNotFoundError:
        vllm = None
    return {**{k: os.environ.get(k) for k in keys}, 'vllm': vllm}


def cmd_pack(a):
    """Mac side. Copies the frozen originals the panel sent (byte-identical) + truth + non-identity strata."""
    cache, truth = P.CACHE, P.TRUTH
    m = json.loads((cache / 'manifest.json').read_text())
    out = Path(a.out)
    if out.exists():
        raise SystemExit(f'{out} exists; pick a new path')
    rows = {r['page']: r for r in P.rows()}
    jobs = [j for j in m['jobs'] if j['scale'] == 'original']
    for j in jobs:
        b = (cache / 'images' / (j['id'] + '.jpg')).read_bytes()
        if hashlib.sha256(b).hexdigest() != j['sha256']:
            raise SystemExit('frozen image changed: ' + j['id'])
        atomic_write(out / 'images' / (j['page'] + '.jpg'), b)
        atomic_write(out / 'truth' / (j['page'] + '.txt'), (truth / 'truth' / (j['page'] + '.txt')).read_bytes())
    with (out / 'pages.tsv').open('w', newline='') as f:
        w = csv.writer(f, delimiter='\t'); w.writerow(STRATA)
        for j in jobs:
            w.writerow([rows[j['page']][k] for k in STRATA])
    (out / 'pack.json').write_text(json.dumps({'prompt_sha256': hashlib.sha256(P.PROMPT.encode()).hexdigest(),
        'jobs': jobs, 'agreement': sorted(P.AGREEMENT), 'made': time.strftime('%Y-%m-%dT%H:%M:%S')}, indent=1))
    print(f'{len(jobs)} pages -> {out}  (copy with: scp -r {out} <sunet>@login.farmshare.stanford.edu:)')


def score_pages(pages, replies):
    import ocr_panel_score as S  # needs rapidfuzz + sacrebleu==2.5.1 (setup.sh installs them)
    rr = []
    for page, truth, strata in pages:
        reply, meta = replies.get(page, (None, {'status': 'missing'}))
        text = reply['parsed']['text'] if reply and reply['parsed'] else ''
        rr.append({'page': page, 'ok': bool(text), **S.score(truth, text), **strata,
                   'prompt_tokens': meta.get('prompt_tokens'), 'completion_tokens': meta.get('completion_tokens'),
                   'wall_s': meta.get('wall_s'), 'status': meta['status']})
    return rr, S.aggregate


def write_rows(path, rr):
    with path.open('w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(rr[0])); w.writeheader(); w.writerows(rr)


def server_from(a, max_tokens):
    return Server(a.url, a.model or os.environ['FS_MODEL'], max_tokens, not a.thinking_on)


def cmd_truth(a):
    pack, out = Path(a.pack), Path(a.out) / a.label
    meta = json.loads((pack / 'pack.json').read_text())
    if meta['prompt_sha256'] != hashlib.sha256(P.PROMPT.encode()).hexdigest():
        raise SystemExit('prompt differs from the pack: this checkout is not the one the panel ran')
    with (pack / 'pages.tsv').open() as f:
        strata = {r['page']: r for r in csv.DictReader(f, delimiter='\t')}
    jobs = meta['jobs']
    for j in jobs:
        if hashlib.sha256((pack / 'images' / (j['page'] + '.jpg')).read_bytes()).hexdigest() != j['sha256']:
            raise SystemExit('pack image differs from the frozen panel input: ' + j['page'])
    server = server_from(a, P.MAX_TOKENS)
    # The frozen bytes go as they are: no re-encoding, so the image is the one OpenRouter's providers got.
    items = [(j['page'], (lambda p=j['page']: (pack / 'images' / (p + '.jpg')).read_bytes())) for j in jobs]
    if a.warmup:
        run_all(server, items[:2], 2)
    replies, wall = run_all(server, items, a.concurrency)
    out.mkdir(parents=True, exist_ok=True)
    for page, (reply, m) in replies.items():
        atomic_write(out / 'replies' / (page + '.json'), json.dumps({'reply': reply, 'meta': m}).encode())
    pages = [(j['page'], (pack / 'truth' / (j['page'] + '.txt')).read_text(),
              {k: v for k, v in strata[j['page']].items() if k != 'page'}) for j in jobs]
    rr, agg = score_pages(pages, replies)
    write_rows(out / 'pages.csv', rr)
    acc = [r for r in rr if r['page'] not in meta['agreement']]
    summary = {'label': a.label, 'env': env_info(), 'throughput': throughput(replies, wall, a.gpus),
               'accuracy_96': agg(acc), 'agreement_3': agg([r for r in rr if r['page'] in meta['agreement']]),
               'clippings': agg([r for r in acc if (r['clippings'] or 'no') != 'no']), 'all_99': agg(rr)}
    atomic_write(out / 'summary.json', json.dumps(summary, indent=1).encode())
    print(json.dumps(summary, indent=1))


def cmd_news(a):
    nb, out = Path(a.newsbench), Path(a.out) / a.label
    with (nb / 'newsbench.csv').open() as f:
        rows = list(csv.DictReader(f))
    server = server_from(a, a.max_tokens or NEWS_MAX_TOKENS)
    items = [(Path(r['image_name']).stem, (lambda n=r['image_name']: jpeg(nb / 'images' / n, a.side))) for r in rows]
    replies, wall = run_all(server, items, a.concurrency)
    # NewsBench's own score.py discovers ocr-results/<label>/<id>.txt; write there too so its numbers are comparable
    # with the Vision OCR lab's OCR-NEWSBENCH table.
    for stem, (reply, m) in replies.items():
        text = reply['parsed']['text'] if reply and reply['parsed'] else ''
        atomic_write(out / 'txt' / (stem + '.txt'), text.encode())
        atomic_write(out / 'replies' / (stem + '.json'), json.dumps({'reply': reply, 'meta': m}).encode())
    pages = [(Path(r['image_name']).stem, (nb / 'txt' / (Path(r['image_name']).stem + '.txt')).read_text(),
              {'tier': r['tier'], 'exclude': r['exclude']}) for r in rows]
    rr, agg = score_pages(pages, replies)
    write_rows(out / 'pages.csv', rr)
    summary = {'label': a.label, 'side': a.side, 'env': env_info(), 'throughput': throughput(replies, wall, a.gpus),
               'scored_15_panel_normalisation': agg([r for r in rr if not r['exclude']])}
    atomic_write(out / 'summary.json', json.dumps(summary, indent=1).encode())
    print(json.dumps(summary, indent=1))
    print(f'NewsBench score: mkdir -p {nb}/ocr-results/{a.label} && cp {out}/txt/*.txt {nb}/ocr-results/{a.label}/ '
          f'&& (cd {nb} && python score.py)')


def cmd_bulk(a):
    src, out = Path(a.inp).resolve(), Path(a.out).resolve()
    if out == src or src in out.parents or out in src.parents:
        raise SystemExit('--out must be outside --in (the input directory is never written)')
    files = sorted(p for p in src.rglob('*') if p.suffix.lower() in IMAGES and p.is_file())
    i, n = (int(x) for x in a.shard.split('/'))
    # By a hash of the path, not by position: a file added mid-run cannot shift others out of every shard.
    mine = [p for p in files if int(hashlib.sha1(p.relative_to(src).as_posix().encode()).hexdigest(), 16) % n == i]
    # The image's own name plus .txt (a.jpg -> a.jpg.txt), so a.jpg and a.tif never share an output.
    target = lambda p: out / (p.relative_to(src).as_posix() + '.txt')  # noqa: E731
    todo = [p for p in mine if not target(p).exists()]
    print(f'{len(files)} images, shard {i}/{n}: {len(mine)}, {len(mine) - len(todo)} already done, {len(todo)} to read',
          flush=True)
    server = server_from(a, a.max_tokens or P.MAX_TOKENS)
    log_lock = threading.Lock()
    done = [0]

    def on_done(key, reply, meta):
        side = out / '_meta' / (key + '.json')
        with log_lock:
            done[0] += 1
            if reply and reply['parsed']:
                atomic_write(out / (key + '.txt'), reply['parsed']['text'].encode())
                atomic_write(side, json.dumps({'kind': reply['parsed']['kind'], 'table': reply['parsed']['table'],
                                               **meta}).encode())
            else:
                with (out / f'failed-{i}.jsonl').open('a') as f:
                    f.write(json.dumps({'image': key, **meta, 'raw': (reply or {}).get('raw', '')[:500]}) + '\n')
            if done[0] % 100 == 0:
                print(f'{done[0]}/{len(todo)}', flush=True)

    out.mkdir(parents=True, exist_ok=True)
    items = [(p.relative_to(src).as_posix(), (lambda p=p: jpeg(p, a.side or P.SIDE))) for p in todo]
    replies, wall = run_all(server, items, a.concurrency, a.deadline, on_done)
    t = throughput(replies, wall, a.gpus)
    # A page the server never answered ('error': a crash, a timeout) is still to do; resubmitting retries it.
    t['left'] = len(todo) - sum(1 for _, m in replies.values() if m['status'] != 'error')
    with (out / 'throughput.jsonl').open('a') as f:
        f.write(json.dumps({'shard': a.shard, 'env': env_info(), **t, 't': time.time()}) + '\n')
    print(json.dumps(t))
    sys.exit(0 if t['left'] == 0 else 75)  # 75 (EX_TEMPFAIL): deadline or dead server, resubmit to continue


def main():
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('pack'); p.add_argument('--out', required=True)
    for name in ('truth', 'news', 'bulk'):
        p = sub.add_parser(name)
        p.add_argument('--url', default=os.environ.get('FS_URL', 'http://127.0.0.1:8000'))
        p.add_argument('--model', help='served model name (default $FS_MODEL)')
        p.add_argument('--concurrency', type=int, default=int(os.environ.get('FS_CONCURRENCY', 32)))
        p.add_argument('--gpus', type=int, default=int(os.environ.get('FS_GPUS', 1)), help='for pages/hour/GPU')
        p.add_argument('--thinking-on', action='store_true', help='leave the chat template thinking switch alone')
        p.add_argument('--max-tokens', type=int)
        p.add_argument('--out', required=True)
        if name == 'truth':
            p.add_argument('--pack', required=True); p.add_argument('--label', required=True)
            p.add_argument('--warmup', action='store_true', help='two untimed reads first (CUDA graphs, caches)')
        elif name == 'news':
            p.add_argument('--newsbench', required=True); p.add_argument('--label', required=True)
            p.add_argument('--side', type=int, default=NEWS_SIDE)
        else:
            p.add_argument('--in', dest='inp', required=True)
            p.add_argument('--shard', default='0/1'); p.add_argument('--deadline', type=float)
            p.add_argument('--side', type=int)
    a = ap.parse_args()
    {'pack': cmd_pack, 'truth': cmd_truth, 'news': cmd_news, 'bulk': cmd_bulk}[a.cmd](a)


if __name__ == '__main__':
    main()
