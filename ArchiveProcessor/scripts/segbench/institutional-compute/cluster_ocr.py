#!/usr/bin/env python3
"""W41.farmshare-plan. The W41 OCR panel's prompt against a local vLLM server, for an institutional computing cluster.

  cluster_ocr.py pack  --out /tmp/fs-truthpack            # on the Mac: the 99 frozen truth pages, for scp
  cluster_ocr.py truth --pack DIR --out DIR --label L     # on a GPU node: read, score as the panel does, time it
  cluster_ocr.py news  --newsbench DIR --out DIR --label L
  cluster_ocr.py bulk  --in DIR --out DIR [--shard I/N] [--deadline EPOCH]
  ... --layout   (any of truth/news/bulk) layout-first instead: DocLayout-YOLO + GLM-OCR per region (news_layout.py)

The server is started by job.sbatch (`vllm serve`, OpenAI-compatible, localhost only). Nothing here calls a paid
API or the network beyond that server. The prompt, image cap and max_tokens are imported from ocr_panel.py, so a
cluster score uses the same measurement as the OpenRouter rows, at its recorded precision.

Bulk is resumable: a page whose <image name>.txt exists is skipped, every file is written to a temporary name and
renamed, and every failed read is logged to failed-<shard>.jsonl. A page the server never answered counts as still
to do, and eight such in a row stop the run with exit 75.

The loop guard (W41.farmshare-loop-guard; on in bulk, --guard for truth/news): the reply is streamed and stopped
once it repeats itself (loop_period), a stopped or capped page is read once more with a repetition penalty at the
panel's full cap, and a page that still fails goes to escalate-<shard>.jsonl with its reason (loop, cap, error).
A rerun skips escalated pages unless --retry-escalated. `cluster_ocr.py guard-check DIR...` replays the detector over
saved replies, to show it fires on no answered page.
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
# The 2,000-page bulk run's answered pages: median 408 tokens, 99.9% under 3,556, longest 5,766. Its 13 failures all
# ran to 8,192. A capped page is retried at the panel's 8,192, so a long page this cuts short is not lost.
BULK_MAX_TOKENS = 6144

# A reply is looping when its whitespace-normalised tail is one span of up to LOOP_MAX_PERIOD characters repeated
# LOOP_MIN_REPEATS times, covering LOOP_MIN_CHARS. Replayed with guard-check on 2026-10-15 over the cached panel and
# Mac-local replies (25 models) and the 99 truth texts: none of the 2,803 answered replies (231 of them Qwen3.6 27B's)
# or truths fires at these values or at 800/5, three do at 600/4; 71 of the 72 replies cut off at the cap fire, at a
# median 8.6% of their length. The miss counts upward (1428. 1429. ...): the cap catches that kind.
LOOP_MIN_CHARS, LOOP_MIN_REPEATS, LOOP_MAX_PERIOD = 1200, 6, 1000
LOOP_CHECK_EVERY = 256       # characters of new text between checks
RETRY = {'repetition_penalty': 1.05}  # vLLM sampling extra; temperature stays 0, so the retry is reproducible


def loop_period(text: str):
    """The repeating span's length if the reply ends in a loop, else None."""
    t = ' '.join(text[-(LOOP_MAX_PERIOD * (LOOP_MIN_REPEATS + 1) + 1000):].split())
    for p in range(1, LOOP_MAX_PERIOD + 1):
        s = max(LOOP_MIN_CHARS - p, (LOOP_MIN_REPEATS - 1) * p)
        if s + p > len(t):
            break
        if t[-s:] == t[-s - p:-p]:
            return p
    return None


def failure_reason(meta):
    """Why a page failed, for the escalation list: 'loop', 'cap' or 'error'; None if answered or never answered."""
    if meta['status'] in ('ok', 'error'):   # 'error' got no answer: still to do, not a page to escalate
        return None
    if meta['status'] == 'loop':
        return 'loop'
    return 'cap' if meta.get('finish') == 'length' else 'error'


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
    """guard: stream the reply and stop it when it loops, then read a stopped or capped page once more with RETRY
    at retry_max_tokens. Without it a read is the panel's single request, unchanged."""
    def __init__(self, url, model, max_tokens, thinking_off, guard=False, retry_max_tokens=None):
        self.url, self.model, self.max_tokens, self.thinking_off = url.rstrip('/'), model, max_tokens, thinking_off
        self.guard, self.retry_max_tokens = guard, retry_max_tokens or max(max_tokens, P.MAX_TOKENS)

    def read(self, image: bytes, timeout=1800):
        t0 = time.time()
        reply, meta = self.read_once(image, timeout)
        if not self.guard or failure_reason(meta) not in ('loop', 'cap'):
            return reply, meta
        first = {k: meta.get(k) for k in ('status', 'finish', 'completion_tokens', 'wall_s', 'loop_period')}
        reply, meta = self.read_once(image, max(60, timeout - (time.time() - t0)), retry=True)
        meta.update(attempts=2, first=first, retry=dict(RETRY, max_tokens=self.retry_max_tokens),
                    wall_total_s=round(time.time() - t0, 3))
        return reply, meta

    def read_once(self, image: bytes, timeout=1800, retry=False):
        b = {'model': self.model, 'temperature': 0, 'max_tokens': self.retry_max_tokens if retry else self.max_tokens,
             'messages': [{'role': 'user', 'content': [
                 {'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,' + base64.b64encode(image).decode()}},
                 {'type': 'text', 'text': P.PROMPT}]}]}
        if self.thinking_off:  # the panel ran reasoning off; Qwen3.5/3.6 chat templates honour this switch
            b['chat_template_kwargs'] = {'enable_thinking': False}
        if retry:
            b.update(RETRY)
        if self.guard:
            b.update(stream=True, stream_options={'include_usage': True})
        req = urllib.request.Request(self.url + '/v1/chat/completions', json.dumps(b).encode(),
                                     {'Content-Type': 'application/json'})
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw, finish, u, period = self.stream(r, t0, timeout) if self.guard else self.whole(r)
        except urllib.error.HTTPError as e:  # the server answered and refused this page (e.g. 400): the page failed
            return None, {'status': 'rejected', 'error': f'{e.code} {e.read()[:300]!r}', 'wall_s': time.time() - t0}
        except (urllib.error.URLError, TimeoutError, OSError, ValueError, KeyError, IndexError) as e:
            return None, {'status': 'error', 'error': repr(e)[:300], 'wall_s': time.time() - t0}  # no answer: transient
        meta = {'finish': finish, 'prompt_tokens': u.get('prompt_tokens'),
                'completion_tokens': u.get('completion_tokens'), 'wall_s': round(time.time() - t0, 3)}
        if period:
            meta.update(status='loop', loop_period=period, chars=len(raw))
            return {'raw': raw, 'parsed': None}, meta
        # As the panel: a reply cut off at max_tokens is a failure, not a short transcript.
        parsed = T.parse_draft(raw) if meta['finish'] == 'stop' else None
        meta['status'] = 'ok' if parsed else 'unparsed'
        return {'raw': raw, 'parsed': parsed}, meta

    @staticmethod
    def whole(r):
        j = json.loads(r.read())
        c = j['choices'][0]
        return (c.get('message') or {}).get('content') or '', c.get('finish_reason'), j.get('usage') or {}, None

    @staticmethod
    def stream(r, t0, timeout):
        """vLLM's server-sent events. Returns at a loop, which closes the connection, and vLLM aborts the request."""
        parts, n, checked, finish, usage = [], 0, 0, None, {}
        for line in r:
            if not line.startswith(b'data:'):
                continue
            data = line[5:].strip()
            if data == b'[DONE]':
                break
            j = json.loads(data)
            usage = j.get('usage') or usage
            for c in j.get('choices') or []:
                piece = (c.get('delta') or {}).get('content') or ''
                parts.append(piece); n += len(piece)
                finish = c.get('finish_reason') or finish
            if n - checked >= LOOP_CHECK_EVERY:
                checked = n
                text = ''.join(parts); parts[:] = [text]
                period = loop_period(text)
                if period:
                    return text, 'loop', usage, period
            if time.time() - t0 > timeout:
                raise TimeoutError(f'stream ran past {timeout:.0f} s')
        else:
            if finish is None:  # the connection ended without a finish: not an answer
                raise ValueError('stream ended early')
        return ''.join(parts), finish, usage, None


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


def env_info(layout=False):
    keys = ('SLURM_JOB_ID', 'SLURM_JOB_PARTITION', 'SLURM_JOB_QOS', 'SLURMD_NODENAME', 'CUDA_VISIBLE_DEVICES',
            'IC_MODEL', 'IC_PRESET', 'IC_VLLM_ARGS', 'CLUSTER_NAME')
    from importlib import metadata
    try:
        vllm = metadata.version('vllm')
    except metadata.PackageNotFoundError:
        vllm = None
    out = {**{k: os.environ.get(k) for k in keys}, 'vllm': vllm}
    if layout:
        import news_layout
        out.update(news_layout.versions())
    return out


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
    print(f'{len(jobs)} pages -> {out}  (copy with: scp -r {out} <user>@<cluster-login>:)')


def score_pages(pages, replies):
    import ocr_panel_score as S  # needs rapidfuzz, regex + sacrebleu==2.5.1 (setup.sh installs them)
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
    """The reader and how it wants a page loaded: the panel's Server takes JPEG bytes, the layout pipeline a
    full-resolution image (it crops regions from the original). load(src) takes a path or the frozen bytes."""
    model = a.model or os.environ['IC_MODEL']
    if a.layout:
        import news_layout as NL  # needs setup.sh --layout
        return NL.LayoutReader(NL.build_pipeline(a.url, model)), NL.open_rgb
    return Server(a.url, model, max_tokens, not a.thinking_on, guard=a.guard), None


def cmd_truth(a):
    pack, out = Path(a.pack), Path(a.out) / a.label
    meta = json.loads((pack / 'pack.json').read_text())
    if meta['prompt_sha256'] != hashlib.sha256(P.PROMPT.encode()).hexdigest():
        raise SystemExit('prompt differs from the pack: this checkout is not the one the panel ran')
    with (pack / 'pages.tsv').open() as f:
        strata = {r['page']: r for r in csv.DictReader(f, delimiter='\t')}
    jobs = meta['jobs'][:a.limit or None]
    for j in jobs:
        if hashlib.sha256((pack / 'images' / (j['page'] + '.jpg')).read_bytes()).hexdigest() != j['sha256']:
            raise SystemExit('pack image differs from the frozen panel input: ' + j['page'])
    server, load = server_from(a, P.MAX_TOKENS)
    load = load or (lambda b: b)
    # The frozen bytes go as they are: no re-encoding, so the image is the one OpenRouter's providers got.
    items = [(j['page'], (lambda p=j['page']: load((pack / 'images' / (p + '.jpg')).read_bytes()))) for j in jobs]
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
    summary = {'label': a.label, 'layout': a.layout, 'env': env_info(a.layout),
               'throughput': throughput(replies, wall, a.gpus),
               'accuracy_96': agg(acc), 'agreement_3': agg([r for r in rr if r['page'] in meta['agreement']]),
               'clippings': agg([r for r in acc if (r['clippings'] or 'no') != 'no']), 'all_99': agg(rr)}
    atomic_write(out / 'summary.json', json.dumps(summary, indent=1).encode())
    print(json.dumps(summary, indent=1))


def cmd_news(a):
    nb, out = Path(a.newsbench), Path(a.out) / a.label
    with (nb / 'newsbench.csv').open() as f:
        rows = list(csv.DictReader(f))[:a.limit or None]
    server, load = server_from(a, a.max_tokens or NEWS_MAX_TOKENS)
    load = load or (lambda p: jpeg(p, a.side))
    items = [(Path(r['image_name']).stem, (lambda n=r['image_name']: load(nb / 'images' / n))) for r in rows]
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
    summary = {'label': a.label, 'layout': a.layout, 'side': None if a.layout else a.side, 'env': env_info(a.layout),
               'throughput': throughput(replies, wall, a.gpus),
               'scored_15_panel_normalisation': agg([r for r in rr if not r['exclude']])}
    atomic_write(out / 'summary.json', json.dumps(summary, indent=1).encode())
    print(json.dumps(summary, indent=1))
    print(f'NewsBench score: mkdir -p {nb}/ocr-results/{a.label} && cp {out}/txt/*.txt {nb}/ocr-results/{a.label}/ '
          f'&& (cd {nb} && python score.py)')


def cmd_bulk(a):
    src, out = Path(a.inp).resolve(), Path(a.out).resolve()
    if out == src or src in out.parents or out in src.parents:
        raise SystemExit('--out must be outside --in (the input directory is never written)')
    cluster = getattr(a, 'cluster', None) or os.environ.get('CLUSTER_NAME', '')
    if not cluster.strip() or any(ord(c) < 32 for c in cluster):
        raise SystemExit('bulk requires --cluster NAME or CLUSTER_NAME from the cluster profile')
    cluster = cluster.strip()
    files = sorted(p for p in src.rglob('*') if p.suffix.lower() in IMAGES and p.is_file())
    i, n = (int(x) for x in a.shard.split('/'))
    if n < 1 or not 0 <= i < n:
        raise SystemExit('--shard must be I/N with 0 <= I < N')
    # By a hash of the path, not by position: a file added mid-run cannot shift others out of every shard.
    mine = [p for p in files if int(hashlib.sha1(p.relative_to(src).as_posix().encode()).hexdigest(), 16) % n == i]
    mine = mine[:a.limit or None]   # a wave pilot (IC_LIMIT): the shard's first pages, by path
    # The image's own name plus .txt (a.jpg -> a.jpg.txt), so a.jpg and a.tif never share an output.
    target = lambda p: out / (p.relative_to(src).as_posix() + '.txt')  # noqa: E731
    escalated = set() if a.retry_escalated else {json.loads(x)['image'] for f in sorted(out.glob('escalate-*.jsonl'))
                                                  for x in f.read_text().splitlines() if x.strip() and all(json.loads(x).get(k) == v for k, v in
                                                      {'cluster': cluster, 'model': a.model or os.environ.get('IC_MODEL'),
                                                       'preset': os.environ.get('IC_PRESET'),
                                                       'vllm_args': os.environ.get('IC_VLLM_ARGS')}.items())}
    # Never reuse a transcript under a different cluster label or input digest. Refuse rather than overwrite
    # a previous run: a new cluster/model/precision needs a separate output directory.
    for p in mine:
        if target(p).exists():
            try:
                meta = json.loads((out / '_meta' / (p.relative_to(src).as_posix() + '.json')).read_text())
                valid = (meta.get('cluster') == cluster
                         and meta.get('sha256') == hashlib.sha256(p.read_bytes()).hexdigest()
                         and meta.get('model') == (a.model or os.environ.get('IC_MODEL'))
                         and meta.get('preset') == os.environ.get('IC_PRESET')
                         and meta.get('vllm_args') == os.environ.get('IC_VLLM_ARGS'))
            except (OSError, ValueError):
                valid = False
            if not valid:
                raise SystemExit('existing text has incompatible cluster/input/model provenance; use a new --out directory')
    todo = [p for p in mine if not target(p).exists() and p.relative_to(src).as_posix() not in escalated]
    print(f'{len(files)} images, shard {i}/{n}: {len(mine)}, {len(mine) - len(todo)} already done or escalated, '
          f'{len(todo)} to read', flush=True)
    server, load = server_from(a, a.max_tokens or (BULK_MAX_TOKENS if a.guard and not a.layout else P.MAX_TOKENS))
    load = load or (lambda p: jpeg(p, a.side or P.SIDE))
    log_lock = threading.Lock()
    done = [0]
    # What the Processor's import (W41.app-farmshare-import) records with each page's text: who read it, at which
    # precision (the preset's checkpoint and vLLM arguments), in which Slurm job.
    run = {'cluster': cluster, 'model': a.model or os.environ['IC_MODEL'], 'preset': os.environ.get('IC_PRESET'),
           'vllm_args': os.environ.get('IC_VLLM_ARGS'), 'job': os.environ.get('SLURM_JOB_ID')}

    def on_done(key, reply, meta):
        side = out / '_meta' / (key + '.json')
        # The input file's own bytes, so the import matches a page by content and never by a name two images share.
        # A file gone or unreadable since it was read gets no hash (the import then skips it); it never stops the run.
        digest = None
        if reply and reply['parsed']:
            try:
                digest = hashlib.sha256((src / key).read_bytes()).hexdigest()
            except OSError:
                pass
        with log_lock:
            done[0] += 1
            if reply and reply['parsed']:
                atomic_write(out / (key + '.txt'), reply['parsed']['text'].encode())
                atomic_write(side, json.dumps({'kind': reply['parsed']['kind'], 'table': reply['parsed']['table'],
                                               **meta, 'sha256': digest, **run}).encode())
            else:
                with (out / f'failed-{i}.jsonl').open('a') as f:
                    # IC_KEEP_RAW=1 keeps the whole reply (it stays on FarmShare scratch): for replaying a stop rule
                    # over real runaways (W41.app-local-models' guards, 2026-10-16). Otherwise 500 characters.
                    keep = None if os.environ.get('IC_KEEP_RAW') == '1' else 500
                    f.write(json.dumps({'image': key, **run, **meta, 'raw': (reply or {}).get('raw', '')[:keep]}) + '\n')
                reason = failure_reason(meta)
                if reason:  # the form W41.app-farmshare-import / W41.app-ocr-cascade read: no transcript text
                    with (out / f'escalate-{i}.jsonl').open('a') as f:
                        f.write(json.dumps({'image': key, **run, 'reason': reason, 'status': meta['status'],
                                            'finish': meta.get('finish'), 'attempts': meta.get('attempts', 1),
                                            'model': a.model or os.environ['IC_MODEL'], 'error': meta.get('error'),
                                            't': round(time.time())}) + '\n')
            if done[0] % 100 == 0:
                print(f'{done[0]}/{len(todo)}', flush=True)

    out.mkdir(parents=True, exist_ok=True)
    items = [(p.relative_to(src).as_posix(), (lambda p=p: load(p))) for p in todo]
    replies, wall = run_all(server, items, a.concurrency, a.deadline, on_done)
    t = throughput(replies, wall, a.gpus)
    # A page the server never answered ('error': a crash, a timeout) is still to do; resubmitting retries it.
    t['left'] = len(todo) - sum(1 for _, m in replies.values() if m['status'] != 'error')
    with (out / 'throughput.jsonl').open('a') as f:
        f.write(json.dumps({'shard': a.shard, 'layout': a.layout, 'env': env_info(a.layout), **t, 't': time.time()}) + '\n')
    print(json.dumps(t))
    sys.exit(0 if t['left'] == 0 else 75)  # 75 (EX_TEMPFAIL): deadline or dead server, resubmit to continue


def saved_replies(d: Path):
    """(name, finish, text) for every reply under d: this kit's replies/*.json, the panel's *.raw.json (OpenRouter
    bodies) and the Mac-local runs' *.raw.json (text, with the finish in the sibling .json)."""
    for f in sorted(d.rglob('*.json')):
        if f.name.endswith('.raw.json'):
            j = json.loads(f.read_text())
            if 'choices' in j:
                c = j['choices'][0]
                yield f, c.get('finish_reason'), (c.get('message') or {}).get('content') or ''
            elif 'text' in j:
                side = f.with_name(f.name[:-len('.raw.json')] + '.json')
                fin = json.loads(side.read_text())['meta'].get('finish') if side.exists() else None
                yield f, fin, j['text']
        elif f.parent.name == 'replies':
            j = json.loads(f.read_text())
            yield f, (j.get('meta') or {}).get('finish'), (j.get('reply') or {}).get('raw') or ''


def cmd_guard_check(a):
    """Replay the loop detector, as the stream would see it, over saved replies: a fire on an answered reply would
    have stopped a page that today scores; a fire on a capped one is a page the guard frees early. Prints counts and
    names, never text."""
    answered = capped = 0; fired, caught, missed = [], [], []
    for d in a.dirs:
        for f, finish, text in saved_replies(Path(d)):
            at = next((k for k in range(LOOP_CHECK_EVERY, len(text) + LOOP_CHECK_EVERY, LOOP_CHECK_EVERY)
                       if loop_period(text[:k])), None)
            if finish == 'stop':
                answered += 1
                if at:
                    fired.append(str(f))
            elif finish == 'length':
                capped += 1
                (caught if at else missed).append((str(f), at and round(min(at, len(text)) / max(len(text), 1), 3)))
    used = sorted(x for _, x in caught)
    print(json.dumps({'answered': answered, 'answered_fired': len(fired), 'capped': capped, 'capped_caught': len(caught),
                      'median_share_read_before_stop': used[len(used) // 2] if used else None,
                      'fired_on_answered': fired, 'missed': [m for m, _ in missed]}, indent=1))
    sys.exit(1 if fired else 0)


def main():
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('pack'); p.add_argument('--out', required=True)
    for name in ('truth', 'news', 'bulk'):
        p = sub.add_parser(name)
        p.add_argument('--url', default=os.environ.get('IC_URL', 'http://127.0.0.1:8000'))
        p.add_argument('--model', help='served model name (default $IC_MODEL)')
        p.add_argument('--concurrency', type=int, help='pages in flight (default $IC_CONCURRENCY, else 32; 4 '
                       'with --layout, whose regions are what fill the server: news_layout.REGION_WORKERS)')
        p.add_argument('--gpus', type=int, default=int(os.environ.get('IC_GPUS', 1)), help='for pages/hour/GPU')
        p.add_argument('--thinking-on', action='store_true', help='leave the chat template thinking switch alone')
        p.add_argument('--max-tokens', type=int, help=f'reply cap (bulk: {BULK_MAX_TOKENS} with the guard, else '
                       f'{P.MAX_TOKENS}; news: {NEWS_MAX_TOKENS}; truth: {P.MAX_TOKENS})')
        p.add_argument('--guard', action=argparse.BooleanOptionalAction, default=None,
                       help='stop a looping reply, retry a stopped or capped page once (default: on in bulk only)')
        p.add_argument('--layout', action='store_true', default=os.environ.get('IC_LAYOUT') == '1',
                       help='layout-first: DocLayout-YOLO + GLM-OCR per region (default from $IC_LAYOUT=1)')
        p.add_argument('--out', required=True)
        p.add_argument('--limit', type=int, default=int(os.environ.get('IC_LIMIT') or 0),
                       help='only the first N items (a wave pilot; default $IC_LIMIT, 0 = all)')
        if name == 'truth':
            p.add_argument('--pack', required=True); p.add_argument('--label', required=True)
            p.add_argument('--warmup', action='store_true', help='two untimed reads first (CUDA graphs, caches)')
        elif name == 'news':
            p.add_argument('--newsbench', required=True); p.add_argument('--label', required=True)
            p.add_argument('--side', type=int, default=NEWS_SIDE)
        else:
            p.add_argument('--cluster', default=os.environ.get('CLUSTER_NAME'), help='display name from profile')
            p.add_argument('--in', dest='inp', required=True)
            p.add_argument('--shard', default='0/1'); p.add_argument('--deadline', type=float)
            p.add_argument('--side', type=int)
            p.add_argument('--retry-escalated', action='store_true', help='read pages in escalate-*.jsonl again')
    p = sub.add_parser('guard-check'); p.add_argument('dirs', nargs='+')
    a = ap.parse_args()
    if a.cmd not in ('pack', 'guard-check') and a.guard is None:
        a.guard = a.cmd == 'bulk' and not a.layout
    if a.cmd not in ('pack', 'guard-check') and a.concurrency is None:
        a.concurrency = int(os.environ.get('IC_CONCURRENCY') or (4 if a.layout else 32))
    {'pack': cmd_pack, 'truth': cmd_truth, 'news': cmd_news, 'bulk': cmd_bulk, 'guard-check': cmd_guard_check}[a.cmd](a)


if __name__ == '__main__':
    main()
