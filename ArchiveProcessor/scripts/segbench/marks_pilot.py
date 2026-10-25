#!/usr/bin/env python3
"""W46.fix-marks-set-draft: freeze a small original-JPEG pre-flag pilot.

Offline prepare/check/summary; read talks ONLY to a loopback vLLM server.
This is candidate discovery, never mark truth, box drafting or owner review.
The broader inventory is not scheduled. Sherlock submission is owner-attended.
"""
from __future__ import annotations

import argparse
import base64
from collections import Counter
import csv
import hashlib
import http.client
import importlib.metadata
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import tempfile
import time
import urllib.request
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
PROTOCOL = 'marks-preflag-pilot-v1'
COLLECTIONS = ('Dean', 'Deaver', 'Herrnstein', 'Stanton', 'RG165')
CLASSES = ('annotation', 'marginal_note', 'stamp', 'signature_initials', 'redaction', 'other')
PER_COLLECTION = 3
MODEL = 'Qwen/Qwen3.6-27B-FP8'
SERVED = 'marks-qwen3.6-27b'
VLLM_ARGS = ['--max-model-len', '8192', '--gpu-memory-utilization', '0.88',
             '--max-num-seqs', '1', '--enforce-eager']
MAX_TOKENS = 1024
TIMEOUT = 90
SEED = 'W46.fix-marks-set-draft-20261025'
SUPPORT = ('marks_pilot.py', 'marks-pilot-submit.sh', 'marks-pilot-stage-job.sh',
           'marks-pilot-job.sh', 'sherlock/sh.env', 'sherlock/bin/py', 'sherlock/bin/vllm')
PROMPT = '''Inspect this archival page photograph for marks. This is only candidate discovery.
Handwriting of any size on typed or printed text counts, including a signature, initials or a date.
Do not count handwriting that forms the main body of an entirely handwritten page as an annotation.
Ignore marks on a neighbouring page, an archive slip or a ruler. A mark may overlap printed text.
Return ONLY one JSON object with these exact keys:
"page_kind": "typed_printed", "handwritten" or "nontext";
"marks": an object with exactly these boolean fields: annotation, marginal_note, stamp,
signature_initials, redaction, other;
"overlap_with_print": boolean (any mark overlaps print);
"uncertain": boolean (any part of your judgement is doubtful).
Report presence, not counts. Do not transcribe any text or produce coordinates. No Markdown.'''


def encoded(obj):
    return (json.dumps(obj, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + '\n').encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def unique_pairs(pairs):
    out = {}
    for k, v in pairs:
        if k in out:
            raise ValueError(f'duplicate JSON key: {k}')
        out[k] = v
    return out


def loads(text):
    return json.loads(text, object_pairs_hook=unique_pairs,
                      parse_constant=lambda x: (_ for _ in ()).throw(ValueError(f'nonfinite: {x}')))


def load(path):
    return loads(path.read_text())


def relative(root, name):
    p = Path(name)
    if p.is_absolute() or '..' in p.parts or not p.parts:
        raise ValueError('expected safe relative path')
    result = root / p
    if not result.resolve().is_relative_to(root.resolve()):
        raise ValueError('path escapes root')
    return result


def write_new(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('xb') as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())


def safe_output(path):
    path = path.resolve()
    allowed = [Path('/tmp').resolve(), Path(tempfile.gettempdir()).resolve(),
               Path.home() / '.local/state/archive-autonomous/artifacts',
               Path.home() / 'Library/Caches/ArchiveSuiteRehearsal']
    if re.fullmatch(r'[0-9]+', os.environ.get('SLURM_JOB_ID', '')) and os.environ.get('SCRATCH'):
        allowed.append(Path(os.environ['SCRATCH']) / 'fs-ocr')
    if not any(path.is_relative_to(p.resolve()) and path != p.resolve() for p in allowed):
        raise ValueError('output must be a new scratch/cache/state-artifacts subdirectory')
    return path


def inventory(pairs, originals, roots):
    if set(roots) != set(COLLECTIONS):
        raise ValueError('source roots must name exactly the five collections')
    prefixes = {c: relative(originals, roots[c]) for c in COLLECTIONS}
    # Source roots must be disjoint. Broad substring searches confuse HBS Dean
    # with Harvard Dean, and Deaver also has original1.* backup variants.
    for c, p in prefixes.items():
        for other, q in prefixes.items():
            if c != other and (p == q or p.is_relative_to(q)):
                raise ValueError('overlapping collection roots')
    selected = {}
    with pairs.open(newline='') as f:
        for row in csv.DictReader(f, delimiter='\t'):
            name = row['jpeg']
            if not name:
                continue
            p = relative(originals, name)
            c = next((c for c, prefix in prefixes.items() if p.is_relative_to(prefix)), None)
            if c is None:
                continue
            if p.suffix.lower() not in ('.jpg', '.jpeg') or re.match(r'original\d+\.', p.name, re.I):
                raise ValueError('noncanonical JPEG in paired inventory')
            if row.get('tied', '[]') not in ('', '[]') or row['method'] == 'none':
                raise ValueError('unresolved source pair')
            st = p.stat()
            if not p.is_file() or st.st_size == 0:
                raise ValueError('missing/empty original')
            selected[name] = dict(id=c + '-' + digest(name.encode())[:16], collection=c,
                                  source_rel=name, source_size=st.st_size, source_mtime_ns=st.st_mtime_ns)
    rows = sorted(selected.values(), key=lambda r: (r['collection'], r['source_rel']))
    if len({r['id'] for r in rows}) != len(rows):
        raise ValueError('page ID collision')
    if any(sum(r['collection'] == c for r in rows) < PER_COLLECTION for c in COLLECTIONS):
        raise ValueError('not enough original pages in every collection')
    return rows


def choose_pilot(rows):
    out = []
    for c in COLLECTIONS:
        group = [r for r in rows if r['collection'] == c]
        out += sorted(group, key=lambda r: digest((SEED + ':' + r['id']).encode()))[:PER_COLLECTION]
    return out


def prepare(out, pairs, originals, roots):
    from PIL import Image, ImageOps
    out = safe_output(out)
    originals = originals.resolve()
    if originals.is_relative_to(out) or out.is_relative_to(originals):
        raise ValueError('source and output overlap')
    rows = inventory(pairs, originals, roots)
    out.mkdir()  # fail on an existing draft; never overwrite corrected work
    write_new(out / 'inventory.json', encoded(dict(seed=SEED, roots=roots, pages=rows,
                                                  originals=str(originals), pairs_sha256=file_hash(pairs))))
    pages = []
    seen = set()
    for r in choose_pilot(rows):
        src = relative(originals, r['source_rel'])
        source_sha = file_hash(src)
        if source_sha in seen:
            raise ValueError('duplicate image content in pilot; inspect source pool before replacing it')
        seen.add(source_sha)
        dest = out / 'images' / (r['id'] + '.jpg')
        dest.parent.mkdir(exist_ok=True)
        with Image.open(src) as im:
            img = ImageOps.exif_transpose(im).convert('RGB')
            size = list(img.size)
            img.thumbnail((2400, 2400), Image.Resampling.LANCZOS)
            img.save(dest, format='JPEG', quality=95)
            sent_size = list(img.size)
        # Verify no Google Drive/source change happened while encoding.
        if file_hash(src) != source_sha:
            raise ValueError('original changed during preparation')
        pages.append(dict(id=r['id'], collection=r['collection'], image='images/' + dest.name,
                          source_sha256=source_sha, original_size=size, sent_size=sent_size))
    for name in SUPPORT:
        dest = out / 'support' / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(HERE / name, dest)
    write_new(out / 'pilot.json', encoded(dict(pages=pages, prompt=PROMPT)))
    files = ['inventory.json', 'pilot.json'] + [p['image'] for p in pages] + ['support/' + n for n in SUPPORT]
    frozen = dict(protocol=PROTOCOL, model=MODEL, served=SERVED, vllm_args=VLLM_ARGS,
                  max_tokens=MAX_TOKENS, timeout=TIMEOUT,
                  files={name: file_hash(out / name) for name in files})
    write_new(out / 'freeze.json', encoded(frozen))
    check(out)
    return dict(inventory=len(rows), collections=dict(Counter(r['collection'] for r in rows)),
                pilot=len(pages), freeze_sha256=file_hash(out / 'freeze.json'))


def check(root):
    frozen, pilot = load(root / 'freeze.json'), load(root / 'pilot.json')
    expected = dict(protocol=PROTOCOL, model=MODEL, served=SERVED, vllm_args=VLLM_ARGS,
                    max_tokens=MAX_TOKENS, timeout=TIMEOUT)
    if any(frozen.get(k) != v for k, v in expected.items()) or pilot['prompt'] != PROMPT:
        raise ValueError('changed pilot protocol/model/settings')
    pages = pilot['pages']
    pool = load(root / 'inventory.json')['pages']
    chosen = choose_pilot(pool)
    if ([p['id'] for p in pages] != [p['id'] for p in chosen]
            or len(pages) != PER_COLLECTION * len(COLLECTIONS)
            or len({p['id'] for p in pool}) != len(pool)
            or len({p['source_sha256'] for p in pages}) != len(pages)):
        raise ValueError('duplicate/missing/changed selection')
    for p, source in zip(pages, chosen):
        if (p['collection'] != source['collection'] or not re.fullmatch(r'[0-9a-f]{64}', p['source_sha256'])
                or p['image'] != 'images/' + p['id'] + '.jpg'):
            raise ValueError('page provenance mismatch')
    names = {'inventory.json', 'pilot.json'} | {p['image'] for p in pages} | {'support/' + n for n in SUPPORT}
    if set(frozen['files']) != names:
        raise ValueError('missing/extra frozen files')
    for name, sha in frozen['files'].items():
        if file_hash(relative(root, name)) != sha:
            raise ValueError(f'changed frozen file: {name}')
    for name in SUPPORT:
        if file_hash(HERE / name) != frozen['files']['support/' + name]:
            raise ValueError('running code differs from frozen support')
    return frozen, pilot


def prediction(raw):
    obj = loads(raw)
    if not isinstance(obj, dict) or set(obj) != {'page_kind', 'marks', 'overlap_with_print', 'uncertain'}:
        raise ValueError('wrong prediction keys')
    if obj['page_kind'] not in ('typed_printed', 'handwritten', 'nontext'):
        raise ValueError('invalid page kind')
    if not isinstance(obj['marks'], dict) or set(obj['marks']) != set(CLASSES):
        raise ValueError('wrong mark keys')
    if any(type(v) is not bool for v in [*obj['marks'].values(), obj['overlap_with_print'], obj['uncertain']]):
        raise ValueError('mark flags must be JSON booleans')
    if obj['overlap_with_print'] and not any(obj['marks'].values()):
        raise ValueError('overlap asserted without a mark')
    return obj


def server_url(value):
    u = urlsplit(value)
    if (u.scheme != 'http' or u.hostname not in ('127.0.0.1', 'localhost', '::1')
            or u.username or u.password or u.path or u.query or u.fragment or not u.port):
        raise ValueError('only loopback HTTP with explicit port is allowed')
    return value


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('loopback server redirected; request stopped')


def request(root, p, served=SERVED):
    return dict(model=served, temperature=0, max_tokens=MAX_TOKENS,
                chat_template_kwargs=dict(enable_thinking=False), messages=[dict(role='user', content=[
                    dict(type='image_url', image_url=dict(url='data:image/jpeg;base64,' +
                         base64.b64encode((root / p['image']).read_bytes()).decode())),
                    dict(type='text', text=PROMPT)])])


def runtime_check(runtime):
    if (runtime.get('model') != MODEL or runtime.get('vllm_args') != VLLM_ARGS
            or not re.fullmatch(r'[0-9a-f]{40}', runtime.get('revision', ''))
            or not re.fullmatch(r'[0-9]+', runtime.get('job', ''))
            or runtime.get('served') != SERVED + '-' + runtime.get('job', '')
            or any(not runtime.get(k) for k in ('vllm_version', 'transformers_version'))):
        raise ValueError('missing/wrong model runtime provenance')


def identity(root, p, runtime):
    runtime_check(runtime)
    return dict(page=p['id'], collection=p['collection'], runtime=runtime,
                protocol=PROTOCOL, freeze_sha256=file_hash(root / 'freeze.json'),
                request_sha256=digest(encoded(request(root, p, runtime['served']))))


def receipt_check(root, p, rec):
    expected = identity(root, p, rec['runtime'])
    if any(rec.get(k) != v for k, v in expected.items()):
        raise ValueError('stale/mismatched receipt')
    if rec['status'] not in ('ok', 'cap', 'parse', 'error'):
        raise ValueError('invalid receipt outcome')
    if not isinstance(rec.get('wall_s'), (int, float)) or rec['wall_s'] < 0:
        raise ValueError('missing receipt timing')
    if rec['status'] == 'ok':
        response = rec['response']; choice = response['choices'][0]
        if choice['finish_reason'] != 'stop' or prediction(choice['message']['content']) != rec['prediction']:
            raise ValueError('receipt result disagrees with saved response')


def read(root, url, runtime):
    _, pilot = check(root)
    url = server_url(url)
    runtime_check(runtime)
    # Ignore ambient HTTP proxies; archival images never leave loopback here.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    for p in pilot['pages']:
        dest = root / 'out' / (p['id'] + '.json')
        intent = root / 'intents' / (p['id'] + '.json')
        meta = identity(root, p, runtime)
        if dest.exists():
            old = load(dest)
            receipt_check(root, p, old)
            if any(old['runtime'].get(k) != v for k, v in runtime.items() if k not in ('job', 'served')):
                raise ValueError('resume would mix model runtimes')
            if load(intent) != identity(root, p, old['runtime']):
                raise ValueError('intent disagrees with receipt')
            continue  # errors/caps are outcomes, never silently retried
        write_new(intent, encoded(meta))  # interrupted call stays ambiguous; no auto-replay
        rec = dict(**meta, status='error')
        start = time.monotonic()
        try:
            req = urllib.request.Request(url + '/v1/chat/completions', data=encoded(request(root, p, runtime['served'])),
                                         headers={'Content-Type': 'application/json'})
            with opener.open(req, timeout=TIMEOUT) as response:
                raw = response.read(2_000_001)
                if len(raw) > 2_000_000:
                    raise ValueError('response exceeds 2 MB')
            rec['response_text'] = raw.decode()
            rec['status'] = 'parse'
            response = loads(raw.decode())
            rec['response'] = response
            choice = response['choices'][0]
            rec['status'] = 'cap' if choice['finish_reason'] == 'length' else 'error'
            if choice['finish_reason'] == 'stop':
                rec['status'] = 'parse'
                rec['prediction'] = prediction(choice['message']['content'])
                rec['status'] = 'ok'
        except (OSError, ValueError, KeyError, IndexError, TypeError, http.client.HTTPException) as e:
            rec['error'] = str(e)[:500]
        rec['wall_s'] = round(time.monotonic() - start, 4)
        write_new(dest, encoded(rec))
        print(p['id'], rec['status'], flush=True)


def summary(root):
    _, pilot = check(root)
    expected = {p['id'] + '.json' for p in pilot['pages']}
    if {p.name for p in (root / 'out').glob('*.json')} != expected:
        raise ValueError('missing/extra receipts; pilot incomplete')
    if {p.name for p in (root / 'intents').glob('*.json')} != expected:
        raise ValueError('missing/extra request intents')
    records = []
    for p in pilot['pages']:
        rec = load(root / 'out' / (p['id'] + '.json'))
        receipt_check(root, p, rec)
        if load(root / 'intents' / (p['id'] + '.json')) != identity(root, p, rec['runtime']):
            raise ValueError('intent disagrees with receipt')
        records.append(rec)
    if len({encoded({k: v for k, v in r['runtime'].items() if k not in ('job', 'served')}) for r in records}) != 1:
        raise ValueError('model runtime changed within pilot')
    return dict(protocol=PROTOCOL, pages=len(records), status=dict(Counter(r['status'] for r in records)),
                preflagged=sum(any(r['prediction']['marks'].values()) for r in records if r['status'] == 'ok'),
                request_seconds=sum(r['wall_s'] for r in records),
                median_seconds=statistics.median(r['wall_s'] for r in records),
                note='Capability/timing only; no mark truth, precision, recall or automatic full sweep. '
                     'Use Slurm elapsed GPU-hours including startup before reviewing expansion.')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest='cmd', required=True)
    for cmd in ('prepare', 'check', 'runtime', 'read', 'summary'):
        p = sub.add_parser(cmd); p.add_argument('--root', required=True, type=Path)
        if cmd == 'prepare':
            p.add_argument('--pairs', required=True, type=Path)
            p.add_argument('--originals', required=True, type=Path)
            p.add_argument('--source-roots', required=True, type=Path)
        if cmd == 'read':
            p.add_argument('--url', required=True); p.add_argument('--runtime', required=True, type=Path)
        if cmd == 'runtime':
            p.add_argument('--revision', required=True); p.add_argument('--out', required=True, type=Path)
    a = ap.parse_args()
    if a.cmd == 'prepare':
        print(json.dumps(prepare(a.root, a.pairs, a.originals, load(a.source_roots))))
    elif a.cmd == 'check':
        check(a.root); print('pilot freeze verified: 15 original-JPEG pages, five collections')
    elif a.cmd == 'read':
        safe_output(a.root); read(a.root, a.url, load(a.runtime))
    elif a.cmd == 'summary':
        print(json.dumps(summary(a.root), indent=2))
    else:
        check(a.root)
        safe_output(a.out)
        runtime = dict(model=MODEL, vllm_args=VLLM_ARGS, revision=a.revision,
                       job=os.environ.get('SLURM_JOB_ID', ''),
                       served=SERVED + '-' + os.environ.get('SLURM_JOB_ID', ''),
                       vllm_version=importlib.metadata.version('vllm'),
                       transformers_version=importlib.metadata.version('transformers'))
        runtime_check(runtime); write_new(a.out, encoded(runtime))


if __name__ == '__main__':
    main()
