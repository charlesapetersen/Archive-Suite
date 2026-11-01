#!/usr/bin/env python3
"""W46.ocr-ppocrv6-hands-qwen: 0/8/16 corrected line-image examples.

prepare is Mac-only and reads existing images/paired truth mechanically. No agent
reads the pages. Target truth stays in a separate Mac folder, never in the pack.
run contacts only a loopback model inside a bounded Slurm allocation. Same-hand
Blackwell holdout, Shils folder-proxy and cross-hand transfer stay separate.
"""
from __future__ import annotations

import argparse
import base64
from collections import Counter
import hashlib
import json
from pathlib import Path
import random
import shutil
import time
import urllib.request

SEED = 'W46.ocr-ppocrv6-hands-qwen-20261101'
MODEL = 'Qwen/Qwen3.6-27B-FP8'
COUNTS = (0, 8, 16)
MAX_TOKENS = 8192
PROMPT = ('Transcribe only the target archival page, faithfully and in reading order. '
          'Keep line breaks. Do not describe the page, correct spelling or add commentary. '
          'Example crops, when provided, come from other pages; their corrected readings '
          'are examples only and must not be copied into the target transcription.')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def dump(path, obj):
    Path(path).write_text(json.dumps(obj, indent=1, ensure_ascii=False) + '\n')


def sample_lines(pool, target_hash, n=16):
    """Nested sets; no example from a target page, even under another name."""
    pool = [p for p in pool if p['source_sha256'] != target_hash]
    pool = sorted(pool, key=lambda p: hashlib.sha256((SEED + p['id']).encode()).hexdigest())
    # Round-robin source pages before taking another line from a page.
    by = {}
    for p in pool:
        by.setdefault(p['source_sha256'], []).append(p)
    selected = []
    while by and len(selected) < n:
        for key in list(by):
            selected.append(by[key].pop(0))
            if not by[key]: del by[key]
            if len(selected) == n: break
    if len(selected) < n:
        raise ValueError('insufficient held-out corrected lines')
    return selected


def prepare(root, truth_root, revision, public_n=40):
    import ocr_ppocrv6_hands as H
    from PIL import Image
    root, truth_root = Path(root), Path(truth_root)
    if root.exists() or truth_root.exists():
        raise ValueError('pack/truth folder exists; verify it, never overwrite a freeze')
    if len(revision) != 40 or any(c not in '0123456789abcdef' for c in revision):
        raise ValueError('model revision must be a full snapshot hash')
    root.mkdir(parents=True); truth_root.mkdir(parents=True)
    for d in ('images', 'examples', 'support'): (root/d).mkdir()
    pools = {}
    for hand in ('blackwell', 'owner'):
        pool = []
        pages = H.hand_pages(hand)
        for p in pages:
            if hand == 'blackwell' and p['role'] != 'train': continue
            paired = H.pair_lines(hand, p['page'])
            source = Path(paired['image'])
            source_hash = sha(source)
            with Image.open(source) as image:
                if image.size != (paired['width'], paired['height']):
                    raise ValueError('paired image dimensions changed')
                for i, line in enumerate(paired['lines']):
                    pts = line['boundary']
                    xs, ys = [v[0] for v in pts], [v[1] for v in pts]
                    box = (max(0, int(min(xs))-3), max(0, int(min(ys))-3),
                           min(image.width, int(max(xs))+4), min(image.height, int(max(ys))+4))
                    if box[0] >= box[2] or box[1] >= box[3]:
                        raise ValueError('empty example crop')
                    eid = f'{hand}-{p["page"]}-{i}'
                    dest = root/'examples'/(eid+'.jpg')
                    image.crop(box).convert('RGB').save(dest, 'JPEG', quality=95)
                    pool.append(dict(id=eid, image=str(dest.relative_to(root)), text=line['text'],
                                     source_page=p['page'], source_sha256=source_hash,
                                     alignment_cer=line.get('cer')))
            if sha(source) != source_hash:
                raise ValueError('example source image changed during preparation')
        pools[hand] = pool
    l1 = [r for r in H.public_rows() if r['stratum'] == 'L1']
    random.Random(SEED).shuffle(l1)
    if len(l1) < public_n: raise ValueError('not enough fixed L1 pages')
    targets = []
    for r in l1[:public_n]:
        targets.append(dict(id='public-'+r['source']+'-'+r['page_id'], image=r['image'], truth=r['truth'],
                            cohort='public-L1-transfer', hand='blackwell', collection=r['collection']))
    kinds = H.owner_kinds()
    for pid in H.owner_pages():
        if kinds[pid] != 'handwritten': continue
        target_truth = truth_root/(pid+'.txt')
        target_truth.write_text(H.owner_truth(pid))
        targets.append(dict(id='owner-'+pid, image=str(H.owner_image(pid)), truth=str(target_truth),
                            cohort='owner-Shils-folder-proxy' if pid in H.OWNER_HAND else 'owner-transfer',
                            hand='owner' if pid in H.OWNER_HAND else 'blackwell', collection='owner'))
    # Independent same-volume holdout for the actual same-hand question. Never
    # use any of these target pages as examples; the pool uses training pages only.
    for p in H.hand_pages('blackwell'):
        if p['role'] != 'test': continue
        targets.append(dict(id='blackwell-'+p['page'], image=p['image'], truth=p['truth'],
                            cohort='blackwell-held-out', hand='blackwell', collection=H.VOLUME))
    jobs, local_truth = [], {}
    for t in targets:
        src = Path(t['image']); digest = sha(src)
        dest = root/'images'/(t['id']+'.jpg')
        # Use the panel's preparation for all targets, including public holdout.
        with Image.open(src) as im:
            im = im.convert('RGB'); im.thumbnail((2400, 2400), Image.Resampling.LANCZOS)
            im.save(dest, 'JPEG', quality=90)
        if sha(src) != digest:
            raise ValueError('target image changed during preparation')
        selected = sample_lines(pools[t['hand']], digest)
        truth = Path(t['truth']); truth_copy = truth_root/(t['id']+'.txt')
        shutil.copyfile(truth, truth_copy)
        local_truth[t['id']] = dict(path=truth_copy.name, sha256=sha(truth_copy), cohort=t['cohort'])
        for n in COUNTS:
            jobs.append(dict(id=t['id']+f'-n{n}', page=t['id'], cohort=t['cohort'], examples_n=n,
                             image=str(dest.relative_to(root)), target_source_sha256=digest,
                             collection=t['collection'],
                             examples=selected[:n]))
    dump(truth_root/'index.json', local_truth)
    dump(root/'jobs.json', jobs)
    source = Path(__file__)
    shutil.copyfile(source, root/'support/hand_icl.py')
    sh = source.parent/'sherlock'
    shutil.copytree(sh/'hand-icl', root/'support/job')
    shutil.copyfile(sh/'sh.env', root/'support/job/sh.env')
    shutil.copytree(sh/'bin', root/'support/job/bin')
    freeze = dict(protocol='hand-icl-v1', seed=SEED, model=MODEL, revision=revision,
                  counts=list(COUNTS), max_tokens=MAX_TOKENS, prompt=PROMPT,
                  cohorts=dict(Counter(t['cohort'] for t in targets)), jobs=len(jobs),
                  scope='Same-volume Blackwell is same-hand evidence. Shils assumes one hand by folder. '
                        'Other owner/public pages test cross-hand transfer, not author-specific adaptation. '
                        'Owner references remain partially model-drafted (OCR-1). Example alignment is model-filtered.',
                  files={str(p.relative_to(root)): sha(p) for p in sorted(root.rglob('*')) if p.is_file()})
    dump(root/'freeze.json', freeze)
    return freeze


def check(root):
    root = Path(root); f = json.loads((root/'freeze.json').read_text())
    for name, digest in f['files'].items():
        p = Path(name)
        if p.is_absolute() or '..' in p.parts or sha(root/p) != digest:
            raise ValueError('pack checksum/path mismatch: '+name)
    jobs = json.loads((root/'jobs.json').read_text())
    if len(jobs) != f['jobs'] or len({j['id'] for j in jobs}) != len(jobs):
        raise ValueError('missing or duplicate request IDs')
    pages = {}
    for j in jobs:
        if j['examples_n'] not in COUNTS or len(j['examples']) != j['examples_n']:
            raise ValueError('wrong example count')
        if any(e['source_sha256'] == j['target_source_sha256'] for e in j['examples']):
            raise ValueError('example leaks a target page')
        for name in [j['image']] + [e['image'] for e in j['examples']]:
            if name not in f['files']: raise ValueError('unfrozen image')
        pages.setdefault(j['page'], {})[j['examples_n']] = [e['id'] for e in j['examples']]
    for conditions in pages.values():
        if set(conditions) != set(COUNTS) or conditions[8] != conditions[16][:8]:
            raise ValueError('unpaired or non-nested conditions')
    return f, jobs


def messages(root, job):
    root = Path(root)
    def image(name):
        return dict(type='image_url', image_url=dict(url='data:image/jpeg;base64,'+
                    base64.b64encode((root/name).read_bytes()).decode()))
    content = [dict(type='text', text=PROMPT)]
    for e in job['examples']:
        content += [dict(type='text', text='Example line:'), image(e['image']),
                    dict(type='text', text='Corrected reading: '+e['text'])]
    content += [dict(type='text', text='TARGET PAGE — transcribe this only:'), image(job['image'])]
    return [dict(role='user', content=content)]


def run(root, url, budget_seconds=3600):
    if not url.startswith('http://127.0.0.1:'):
        raise ValueError('only the allocation-local model endpoint is allowed')
    root = Path(root); freeze, jobs = check(root)
    out = root/'results'; out.mkdir(exist_ok=True)
    ledger = out/'answers.jsonl'
    prior = [json.loads(l) for l in ledger.read_text().splitlines()] if ledger.exists() else []
    if prior: raise ValueError('answers exist; inspect before a resumed job, never silently repeat')
    pilot_pages = []
    for cohort in sorted(freeze['cohorts']):
        pilot_pages += sorted({j['page'] for j in jobs if j['cohort'] == cohort})[:2]
    pilot = [j for j in jobs if j['page'] in pilot_pages]
    rest = [j for j in jobs if j['page'] not in pilot_pages]
    start, records = time.monotonic(), []
    for stage, tasks in [('pilot', pilot), ('full', rest)]:
        if stage == 'full':
            elapsed = time.monotonic()-start
            projection = elapsed/len(pilot)*len(jobs)
            dump(out/'pilot.json', dict(requests=len(pilot), seconds=elapsed, projected_seconds=projection))
            if any(r['status'] != 'ok' for r in records) or projection > budget_seconds:
                dump(out/'status.json', dict(state='pilot_stopped', completed=len(records),
                                             projected_seconds=projection))
                return 2
        for j in tasks:
            if time.monotonic()-start > budget_seconds:
                dump(out/'status.json', dict(state='budget_stopped', completed=len(records)))
                return 2
            body = dict(model='hand-icl-qwen', messages=messages(root, j), max_tokens=freeze['max_tokens'],
                        temperature=0, stream=False, chat_template_kwargs=dict(enable_thinking=False))
            raw = json.dumps(body).encode(); t = time.monotonic()
            record = dict(id=j['id'], page=j['page'], cohort=j['cohort'], examples_n=j['examples_n'],
                          request_sha256=hashlib.sha256(raw).hexdigest(), stage=stage)
            try:
                request = urllib.request.Request(url+'/v1/chat/completions', data=raw,
                                                 headers={'Content-Type':'application/json'})
                remaining = max(1, budget_seconds-(time.monotonic()-start))
                with urllib.request.urlopen(request, timeout=min(180,remaining)) as response: reply=json.load(response)
                choice = reply['choices'][0]; text = choice['message'].get('content') or ''
                record.update(text=text, finish=choice.get('finish_reason'), usage=reply.get('usage'),
                              status='ok' if text.strip() and choice.get('finish_reason') == 'stop' else 'cap_or_empty')
            except Exception as e:
                record.update(status='error', error=type(e).__name__+': '+str(e)[:500], text='')
            record['wall_s'] = round(time.monotonic()-t, 3)
            with ledger.open('a') as f:
                f.write(json.dumps(record, ensure_ascii=False)+'\n'); f.flush()
            records.append(record)
            print(j['id'],record['status'],record['wall_s'],flush=True)
    dump(out/'status.json', dict(state='completed', completed=len(records),
                                seconds=time.monotonic()-start, counts=dict(Counter(r['status'] for r in records))))
    return 0


def main():
    p=argparse.ArgumentParser(description=__doc__)
    sub=p.add_subparsers(dest='cmd', required=True)
    a=sub.add_parser('prepare'); a.add_argument('--root',type=Path,required=True)
    a.add_argument('--truth-root',type=Path,required=True); a.add_argument('--revision',required=True)
    a=sub.add_parser('check'); a.add_argument('--root',type=Path,required=True)
    a=sub.add_parser('run'); a.add_argument('--root',type=Path,required=True); a.add_argument('--url',required=True)
    a.add_argument('--budget-seconds',type=int,default=3600)
    a=p.parse_args()
    if a.cmd=='prepare':
        f=prepare(a.root,a.truth_root,a.revision); print(json.dumps({k:f[k] for k in ('jobs','cohorts','revision')},indent=1))
    elif a.cmd=='check':
        f,jobs=check(a.root); print('verified',len(jobs),'requests',f['cohorts'])
    else: raise SystemExit(run(a.root,a.url,a.budget_seconds))


if __name__=='__main__': main()
