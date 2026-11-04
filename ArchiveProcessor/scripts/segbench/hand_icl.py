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


RESULTS = Path(__file__).resolve().parents[2] / 'segbench-results'
REVISION = 'e89b16ebf1988b3d6befa7de50abc2d76f26eb09'


def request_body(root, freeze, job):
    """Byte-identical to run()'s request, so a recorded hash pins the frozen inputs."""
    return json.dumps(dict(model='hand-icl-qwen', messages=messages(root, job), max_tokens=freeze['max_tokens'],
                           temperature=0, stream=False,
                           chat_template_kwargs=dict(enable_thinking=False))).encode()


def collected(root, jobs, freeze):
    """Validate the returned run before any score: every frozen request exactly once, its recorded
    request hash equal to the frozen request, the pinned model/runtime, a completed status. -> rows."""
    root = Path(root)
    status = json.loads((root/'results/status.json').read_text())
    if status.get('state') != 'completed' or status.get('completed') != len(jobs):
        raise ValueError('run did not complete; a stopped pilot is a feasibility result, not a score')
    receipts = sorted((root/'runtime').glob('*.json'))
    if len(receipts) != 1:
        raise ValueError('expected exactly one runtime receipt (the completed allocation)')
    runtime = json.loads(receipts[0].read_text())
    if runtime.get('revision') != freeze['revision'] or freeze['revision'] != REVISION:
        raise ValueError('model snapshot differs from the freeze')
    rows = [json.loads(l) for l in (root/'results/answers.jsonl').read_text().splitlines() if l.strip()]
    by = {}
    for r in rows:
        if r['id'] in by:
            raise ValueError('repeated request in the ledger: ' + r['id'])
        by[r['id']] = r
    expected = {j['id']: j for j in jobs}
    if by.keys() != expected.keys():
        raise ValueError('ledger and frozen request IDs differ')
    for k, r in by.items():
        j = expected[k]
        if (r['page'], r['cohort'], r['examples_n']) != (j['page'], j['cohort'], j['examples_n']):
            raise ValueError('ledger row does not match its frozen job: ' + k)
        if r['request_sha256'] != hashlib.sha256(request_body(root, freeze, j)).hexdigest():
            raise ValueError('recorded request differs from the frozen request: ' + k)
        r['ok'] = r['status'] == 'ok' and r.get('finish') == 'stop' and bool((r.get('text') or '').strip())
    return by, runtime, status


def copied_examples(job, text, min_chars=12):
    """Example readings reproduced verbatim in the target answer (the prompt forbids it). Mechanical."""
    lines = [e['text'].strip() for e in job['examples'] if len(e['text'].strip()) >= min_chars]
    return sum(line in text for line in lines), len(lines)


def report(root, truth_root):
    """Score the collected Qwen run with the Gemini arm's pinned check and paired analysis.
    Reads truth and replies programmatically only; prints no page text."""
    import statistics
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import hand_icl_gateway as GW
    import ocr_panel_score as S
    root, truth_root = Path(root), Path(truth_root)
    freeze, jobs, refs = GW.check(root, truth_root)
    rows, runtime, status = collected(root, jobs, freeze)
    texts = {k: r.get('text') or '' for k, r in rows.items()}
    truths = {p: GW.inside(truth_root, r['path']).read_text() for p, r in refs.items()}
    result = GW.analyze(jobs, rows, truths, texts, S.score)
    import ocr_hands_rescore as HS
    rulings = json.loads((HS.HANDS / 'rulings.json').read_text())
    unresolved = set(HS.unresolved(rulings['rulings']))
    hand16 = set(json.loads((RESULTS / 'ocr-hands-rescore.json').read_text())['pages'])
    clear = [j for j in jobs if j['page'].startswith('owner-')
             and j['page'].removeprefix('owner-') in hand16 - unresolved]
    if clear:
        result['owner_clear'] = GW.analyze(clear, rows, truths, texts, S.score)
        result['owner_clear_pages'] = len({j['page'] for j in clear})
    copies = Counter()
    for j in jobs:
        if j['examples_n']:
            hit, of = copied_examples(j, texts[j['id']])
            copies[j['examples_n'], 'hit'] += hit; copies[j['examples_n'], 'of'] += of
            copies[j['examples_n'], 'pages'] += bool(hit)
    usage = [r['usage'] for r in rows.values()]
    walls = [r['wall_s'] for r in rows.values()]
    result.update(item='W46.ocr-ppocrv6-hands-qwen', model=MODEL, revision=freeze['revision'], runtime=runtime,
                  settings=dict(temperature=0, thinking=False, max_tokens=freeze['max_tokens']),
                  cohorts=freeze['cohorts'], status=status,
                  failed=sorted(k for k, r in rows.items() if not r['ok']),
                  finish=dict(Counter(r.get('finish') for r in rows.values())),
                  completion_tokens_max=max(u['completion_tokens'] for u in usage),
                  prompt_tokens_max=max(u['prompt_tokens'] for u in usage),
                  wall_s=dict(median=statistics.median(walls), max=max(walls), total=sum(walls)),
                  wall_by_n={n: statistics.median(r['wall_s'] for r in rows.values() if r['examples_n'] == n)
                             for n in COUNTS},
                  prompt_by_n={n: statistics.median(r['usage']['prompt_tokens'] for r in rows.values()
                                                    if r['examples_n'] == n) for n in COUNTS},
                  identical_to_zero={n: sum(texts[j['id']] == texts[j['page'] + '-n0'] for j in jobs
                                            if j['examples_n'] == n) for n in (8, 16)},
                  copied={n: dict(lines=copies[n, 'hit'], of=copies[n, 'of'], pages=copies[n, 'pages'])
                          for n in (8, 16)},
                  pilot=json.loads((root/'results/pilot.json').read_text()),
                  ledger_sha256=sha(root/'results/answers.jsonl'),
                  pack_freeze_sha256=sha(root/'freeze.json'), truth_index_sha256=sha(truth_root/'index.json'),
                  scoring_runner_sha256=sha(__file__))
    primary = [c for c in result['comparisons'] if c['cohort'] == 'blackwell-held-out']
    result['verdict'] = ('On the one documented Blackwell diary hand (12 held-out pages): ' + '; '.join(
        f"{c['examples_n']} lines {c['both_answered']['delta']:+.2f} NES (95% page interval "
        f"{c['both_answered']['lo']:+.2f} to {c['both_answered']['hi']:+.2f})" for c in primary) +
        '. Page-conditional on this hand; not an OCR default for a new hand. Intervals are pointwise, '
        'unadjusted across the two example counts.')
    dump(RESULTS / 'ocr-ppocrv6-hands-qwen.json', result)
    write_report(result)
    return result


def write_report(r):
    def num(v):
        return '—' if v is None else f'{v:.2f}'
    def ci(v):
        return '—' if not v['n'] else f"{v['delta']:+.2f} ({v['lo']:+.2f} to {v['hi']:+.2f}; n={v['n']})"
    rt = r['runtime']
    L = ['# Qwen3.6-27B given corrected handwriting lines (W46.ocr-ppocrv6-hands-qwen)', '',
         'Qwen3.6-27B (FP8) on vLLM on one Sherlock H100, given 0, 8 or 16 corrected line images of a hand, each '
         'crop a separate image followed by its corrected reading, then the target page. Scores are NES points. '
         'Only the Blackwell holdout tests a documented same hand; the Shils folder is a hand proxy; the owner-'
         'transfer and public L1 cohorts get Blackwell examples and test transfer across hands, not adaptation.', '',
         '**Verdict.** ' + r['verdict'], '',
         '**For the training kit:** putting a hand\'s corrected lines in Qwen3.6-27B\'s prompt is not an adaptation '
         'route on this evidence. No cohort at 8 or 16 lines moved by more than its interval allows, the documented '
         'hand\'s point estimates are below zero, and most answers changed only slightly. A kit user who wants a '
         'reader adapted to a hand needs training (W46.ocr-ppocrv6-hands) or another model; this run says nothing '
         'about Gemini, whose arm (W46.ocr-ppocrv6-hands-paid) is its own report, `ocr-ppocrv6-hands-paid.md`.', '',
         f"**Support:** {sum(g['answered'] for g in r['groups'])} of {sum(g['n'] for g in r['groups'])} fixed "
         f"conditions answered; every reply ended normally (finish {r['finish']}); the longest reply was "
         f"{r['completion_tokens_max']} tokens against the 8,192 cap, so no reply was cut off. "
         f"Failed conditions: {len(r['failed'])}.", '',
         '## Measurement card', '',
         '- **Truth:** public By the People transcriptions (CC0) for the Blackwell holdout and L1 pages. Owner targets '
         'use the post-sheet truth (W46.ocr-hands-rescore): model-drafted, 114 hand places owner-checked, 10 unresolved, '
         'so owner figures are agreement with that reference (OCR-1), not rankings. Example lines are the existing '
         'PP-OCRv6-aligned corrected lines, filtered by alignment error against the base recognizer (not a random line '
         'draw); the owner example lines predate the sheet corrections. No Claude subagent drew or read any line or page.',
         '- **Selection:** the frozen pack (`hand_icl.py prepare`, seed `W46.ocr-ppocrv6-hands-qwen-20261101`): 40 seeded L1 '
         'pages, all 19 owner handwritten pages, the 12 test-role Blackwell pages of the training volume. The owner '
         'cohorts hold the 16 scored hand pages and the three agreement-only letters (p086, p094, p096, in '
         'owner-transfer), whose truth is the drafters\' agreement, never adjudicated and not on the hand sheet. Blackwell '
         'examples come only from its 24 training pages; Shils examples from the other three Shils pages; source-image '
         'hashes reject aliases. No page was chosen by a tested route or by ABBYY text.',
         '- **Comparison:** identical 2400 px / quality-90 target JPEGs across conditions, eight examples the prefix of '
         'sixteen, one prompt, temperature 0, no thinking, 8,192-token cap, 32,768-token context, at most 17 images, '
         f"one sequence, fp8 KV cache, eager. Snapshot `{r['revision']}`, vLLM {rt['vllm']}, transformers "
         f"{rt['transformers']}. Every recorded request hash was recomputed from the frozen pack and matched. "
         'The Gemini arm (W46.ocr-ppocrv6-hands-paid) uses the same pack and is reported apart '
         '(`ocr-ppocrv6-hands-paid.md`); no model comparison is drawn here.',
         '- **Noise:** 10,000-round paired page bootstrap within each cohort; public L1 also bootstraps by collection. '
         'One diary and four Shils pages cannot estimate variation across hands. No repeat run was made, so no '
         'prompt-specific rerun floor exists; the inherited hosted handwritten floor (0.60 points) is a reference, not '
         'this route\'s floor. A gap whose interval spans zero is a tie.',
         '- **Scope:** zero-training prompting on these pages and examples only. Not an app default, not a fine-tune '
         'comparison on the same pages, no claim about a new hand, another collection, the 96 or the 895. These '
         'subsets do not enter the whole-96 or whole-895 charts.', '',
         '## Paired conditions', '',
         '| cohort | examples | answered / n | NES | missed words % | added words % |', '|---|---:|---:|---:|---:|---:|']
    for g in r['groups']:
        L.append(f"| {g['cohort']} | {g['examples_n']} | {g['answered']} / {g['n']} | {num(g['nes_strict'])} | "
                 f"{num(g['words_missed_pct'])} | {num(g['words_added_pct'])} |")
    L += ['', '| cohort | examples | Δ vs zero (95% page CI) | collection-clustered (95% CI) |', '|---|---:|---|---|']
    for c in r['comparisons']:
        cl = ci(c['collection_clustered']) if c['cohort'] == 'public-L1-transfer' else 'one hand/folder: not estimated'
        L.append(f"| {c['cohort']} | {c['examples_n']} | {ci(c['both_answered'])} | {cl} |")
    if r.get('owner_clear'):
        L += ['', f"Owner sensitivity, the {r['owner_clear_pages']} pages of the original 16 with no unresolved sheet "
              'place (descriptive; still a model-drafted reference):', '',
              '| cohort | examples | Δ vs zero (95% page CI) |', '|---|---:|---|']
        L += [f"| {c['cohort']} | {c['examples_n']} | {ci(c['both_answered'])} |" for c in r['owner_clear']['comparisons']]
    cp = r['copied']
    L += ['', '## Copying, speed and cost', '',
          f"Example readings (12+ characters) found verbatim in the target answer: {cp[8]['lines']} of {cp[8]['of']} "
          f"at 8 lines ({cp[8]['pages']} answers), {cp[16]['lines']} of {cp[16]['of']} at 16 ({cp[16]['pages']} answers). "
          'The prompt forbids copying; a verbatim hit can also be a phrase genuinely repeated on the target page. '
          'The examples reached the model: median prompt ' +
          ' / '.join(f"{r['prompt_by_n'][n]:.0f}" for n in COUNTS) + ' tokens at 0/8/16 examples. The answer was '
          f"character-identical to the zero-example answer on {r['identical_to_zero'][8]} of 71 pages at 8 lines and "
          f"{r['identical_to_zero'][16]} at 16.", '',
          f"Median request {r['wall_s']['median']:.1f} s (0/8/16 examples: " +
          ' / '.join(f"{r['wall_by_n'][n]:.1f}" for n in COUNTS) + f" s), longest {r['wall_s']['max']:.1f} s, "
          f"{r['wall_s']['total'] / 60:.0f} min of requests in total on one {rt['gpu']}; largest prompt "
          f"{r['prompt_tokens_max']} tokens. The 24-request pilot projected {r['pilot']['projected_seconds'] / 60:.0f} "
          'min; the allocation ran 46 min including startup (Slurm 50741268). The first attempt (50696432) failed '
          'in 10 s before the model started (node-local scratch not bound into the container); no request was '
          'repeated. Sherlock allocation only; no money spent.', '',
          f"Frozen pack SHA-256 `{r['pack_freeze_sha256']}`; truth index `{r['truth_index_sha256']}`; ledger "
          f"`{r['ledger_sha256']}`. Private pack and results `~/.local/state/archive-autonomous/artifacts/"
          'hand-icl-20261101`, target truth `hand-icl-truth-20261101`.', '',
          'Reproduce: `python3 ops/autonomous/heavy-run.py run -- uv run --with rapidfuzz '
          "--with 'sacrebleu==2.5.1' --with regex python ArchiveProcessor/scripts/segbench/hand_icl.py report`."]
    (RESULTS / 'ocr-ppocrv6-hands-qwen.md').write_text('\n'.join(L) + '\n')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    sub=p.add_subparsers(dest='cmd', required=True)
    a=sub.add_parser('prepare'); a.add_argument('--root',type=Path,required=True)
    a.add_argument('--truth-root',type=Path,required=True); a.add_argument('--revision',required=True)
    a=sub.add_parser('check'); a.add_argument('--root',type=Path,required=True)
    a=sub.add_parser('run'); a.add_argument('--root',type=Path,required=True); a.add_argument('--url',required=True)
    a.add_argument('--budget-seconds',type=int,default=3600)
    state = Path.home()/'.local/state/archive-autonomous/artifacts'
    a=sub.add_parser('report'); a.add_argument('--root',type=Path,default=state/'hand-icl-20261101')
    a.add_argument('--truth-root',type=Path,default=state/'hand-icl-truth-20261101')
    a=p.parse_args()
    if a.cmd=='report':
        r=report(a.root,a.truth_root); print(r['verdict']); return
    if a.cmd=='prepare':
        f=prepare(a.root,a.truth_root,a.revision); print(json.dumps({k:f[k] for k in ('jobs','cohorts','revision')},indent=1))
    elif a.cmd=='check':
        f,jobs=check(a.root); print('verified',len(jobs),'requests',f['cohorts'])
    else: raise SystemExit(run(a.root,a.url,a.budget_seconds))


if __name__=='__main__': main()
