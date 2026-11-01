#!/usr/bin/env python3
"""W46.ocr-ppocrv6-hands-paid: Gemini on the Qwen arm's frozen 0/8/16-line pack.

No preparation or corpus edits: read the frozen pack and separate local truth.
Every attempt has a write-ahead reservation; interrupted/unknown attempts are
never repeated. One request at a time, no transport or model retries. Output and
the ledger belong in a private artifact directory, never the pack or repository.
Run pilot/full/report under ops/autonomous/heavy-run.py. plan/check are read-only.
"""
from __future__ import annotations

import argparse
import base64
from collections import Counter, defaultdict
import hashlib
import json
import math
import random
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import gateway_gemini as G

TAG = 'W46.ocr-ppocrv6-hands-paid'
COUNTS = (0, 8, 16)
CAP = 2.50     # OWNER_AUTHORIZATIONS.md, 2026-11-01, commit 1565f7d9
RESERVE = .08    # 8,192 output + up to 60k input at the conservative list rates
DEFAULT_STATE = Path.home() / '.local/state/archive-autonomous/artifacts'
DEFAULT_PACK = DEFAULT_STATE / 'hand-icl-20261101'
DEFAULT_TRUTH = DEFAULT_STATE / 'hand-icl-truth-20261101'
LEGACY_OUT = DEFAULT_STATE / 'hand-icl-gateway-sheet-20261101'  # never sent; any later spend still counts
DEFAULT_OUT = DEFAULT_STATE / 'hand-icl-gateway-20261101'
ENCODING = 'separate-line-images-v1'
RESULTS = HERE.parents[1] / 'segbench-results'
COHORTS = {'blackwell-held-out': 12, 'owner-Shils-folder-proxy': 4,
           'owner-transfer': 15, 'public-L1-transfer': 40}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def dump(path, obj):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=1, ensure_ascii=False, allow_nan=False) + '\n')


def inside(root, name):
    p = Path(name)
    if p.is_absolute() or '..' in p.parts or not p.parts:
        raise ValueError('unsafe artifact path')
    p = Path(root) / p
    if not p.resolve().is_relative_to(Path(root).resolve()):
        raise ValueError('artifact symlink escapes root')
    return p


def check(pack, truth_root):
    """Pin the existing pack, all nested conditions and the separate target truth.

    Never print any truth or example text. The comparison uses exactly the Qwen
    arm's frozen inputs; no scored target text enters messages().
    """
    pack, truth_root = Path(pack), Path(truth_root)
    freeze = json.loads((pack / 'freeze.json').read_text())
    if (freeze['protocol'] != 'hand-icl-v1' or freeze['counts'] != list(COUNTS)
            or freeze['max_tokens'] != 8192 or 'jobs.json' not in freeze['files']):
        raise ValueError('unsupported experiment protocol')
    for name, digest in freeze['files'].items():
        if sha(inside(pack, name)) != digest:
            raise ValueError('pack checksum mismatch: ' + name)
    jobs = json.loads((pack / 'jobs.json').read_text())
    refs = json.loads((truth_root / 'index.json').read_text())
    if len(jobs) != freeze['jobs'] or len({j['id'] for j in jobs}) != len(jobs):
        raise ValueError('missing/duplicate jobs')
    pages = defaultdict(dict)
    for j in jobs:
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', j['id']):
            raise ValueError('unsafe request id')
        n = j['examples_n']
        if type(n) is not int or n not in COUNTS or len(j['examples']) != n:
            raise ValueError('wrong example count')
        if n in pages[j['page']]:
            raise ValueError('duplicate page/condition')
        pages[j['page']][n] = j
        for name in [j['image']] + [e['image'] for e in j['examples']]:
            if name not in freeze['files']:
                raise ValueError('unfrozen image')
        if len({e['id'] for e in j['examples']}) != n:
            raise ValueError('duplicate exemplars')
        if any(e['source_sha256'] == j['target_source_sha256'] for e in j['examples']):
            raise ValueError('target page leaked into examples')
    for p, arms in pages.items():
        if set(arms) != set(COUNTS) or arms[8]['examples'] != arms[16]['examples'][:8]:
            raise ValueError('unpaired/non-nested arms')
        for field in ('image', 'target_source_sha256', 'cohort', 'collection'):
            if len({a[field] for a in arms.values()}) != 1:
                raise ValueError('target differs between conditions')
        ref = refs[p]
        if ref['cohort'] != arms[0]['cohort'] or sha(inside(truth_root, ref['path'])) != ref['sha256']:
            raise ValueError('target truth changed: ' + p)
    cohorts = dict(Counter(a[0]['cohort'] for a in pages.values()))
    if cohorts != freeze['cohorts'] or cohorts != COHORTS:
        raise ValueError('unexpected target selection')
    # The frozen owner references must still be the post-sheet truth. The line
    # examples are the earlier paired references; that limitation is disclosed.
    import ocr_ppocrv6_hands as H
    for p in pages:
        if p.startswith('owner-'):
            current = H.owner_truth(p.removeprefix('owner-')).encode()
            if hashlib.sha256(current).hexdigest() != refs[p]['sha256']:
                raise ValueError('owner references predate the corrected hand truth')
    return freeze, jobs, refs


def body(pack, freeze, j):
    def image(name):
        return {'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,' +
                base64.b64encode(inside(pack, name).read_bytes()).decode()}}
    content = [{'type': 'text', 'text': freeze['prompt']}]
    for e in j['examples']:
        content += [{'type': 'text', 'text': 'Example line:'}, image(e['image']),
                    {'type': 'text', 'text': 'Corrected reading: ' + e['text']}]
    content += [{'type': 'text', 'text': 'TARGET PAGE — transcribe this only:'}, image(j['image'])]
    return {'model': G.MODEL, 'temperature': 0, 'max_tokens': freeze['max_tokens'],
            'reasoning_effort': 'low', 'cache': {'no-cache': True},
            'messages': [{'role': 'user', 'content': content}]}


def request_hash(b):
    return hashlib.sha256(json.dumps(b, sort_keys=True).encode()).hexdigest()


def known_usage(usage):
    return all(type(usage.get(k)) is int and usage[k] >= 0
               for k in ('prompt_tokens', 'completion_tokens'))


def load_key():
    """Bound the Keychain read; no request/reservation precedes credentials."""
    try:
        r = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s',
                            'com.archiveprocessor.app', '-a', 'Gateway', '-w'],
                           capture_output=True, text=True, timeout=20)
    except subprocess.TimeoutExpired:
        raise ValueError('Gateway Keychain read timed out after 20 seconds; no paid call made') from None
    if r.returncode or not r.stdout.strip():
        raise ValueError('Gateway key unavailable in Keychain; no paid call made')
    G._key = r.stdout.strip()


def validate_receipt(out, pack, truth, freeze):
    rec = json.loads((Path(out) / 'receipt.json').read_text())
    expected = {'pack_freeze_sha256': sha(Path(pack) / 'freeze.json'),
                'truth_index_sha256': sha(Path(truth) / 'index.json'), 'model': G.MODEL,
                'max_tokens': freeze['max_tokens'], 'temperature': 0, 'reasoning_effort': 'low',
                'no_cache': True, 'reservation': RESERVE}
    if any(rec.get(k) != v for k, v in expected.items()):
        raise ValueError('run receipt differs from frozen experiment')
    if rec.get('cap') not in (1.00, CAP) or rec.get('encoding', ENCODING) != ENCODING:
        raise ValueError('unrecognized original receipt cap/encoding')
    return rec


def validate_output(out, pack, truth):
    if any(Path(out).resolve().is_relative_to(Path(p).resolve()) for p in (pack, truth)):
        raise ValueError('output must be separate from frozen inputs')


def journal(out):
    f = Path(out) / 'calls.jsonl'
    return [json.loads(l) for l in f.read_text().splitlines()] if f.exists() else []


def prior_spend(out):
    """Count any alternate-encoding ledger, including custom output resumes."""
    if Path(out).resolve() == LEGACY_OUT.resolve():
        return 0., []
    pending, settled, spent = state(journal(LEGACY_OUT))
    if pending:
        raise ValueError('the alternate-encoding pilot still has an outstanding request')
    return spent, list(settled.values())


def state(rows):
    pending, settled = {}, {}
    for r in rows:
        key = r['id']
        if r['event'] == 'reserve':
            if key in pending or key in settled:
                raise ValueError('request attempted twice: ' + key)
            pending[key] = r
        elif r['event'] == 'settle':
            if key not in pending or r['request_sha256'] != pending[key]['request_sha256']:
                raise ValueError('outcome has no matching reservation')
            if any(not isinstance(r.get(k), (int, float)) or not math.isfinite(r[k]) or r[k] < 0
                   for k in ('cost', 'gateway_cost') if r.get(k) is not None):
                raise ValueError('invalid charge; reservation remains uncertain')
            settled[key] = r
            del pending[key]
        else:
            raise ValueError('unknown ledger event')
    spent = sum(G.charge(r) for r in settled.values()) + sum(r['reservation'] for r in pending.values())
    return pending, settled, spent


def append(out, rec):
    import os
    with (Path(out) / 'calls.jsonl').open('a') as f:
        f.write(json.dumps(rec, ensure_ascii=False, allow_nan=False) + '\n')
        f.flush()
        os.fsync(f.fileno())


def call(pack, freeze, j, out, request=G.request):
    b = body(pack, freeze, j)
    digest = request_hash(b)
    pending, done, spent = state(journal(out))
    spent += prior_spend(out)[0]
    if pending:
        raise ValueError('uncertain paid attempt; reconcile before any further calls')
    if j['id'] in done:
        if done[j['id']]['request_sha256'] != digest:
            raise ValueError('cached request differs from frozen request')
        return done[j['id']]
    if spent + RESERVE > CAP:
        raise ValueError(f'item cap: ${spent:.4f} charged; next reservation ${RESERVE:.2f}, cap ${CAP:.2f}')
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    rec = {'id': j['id'], 'page': j['page'], 'cohort': j['cohort'], 'examples_n': j['examples_n'],
           'request_sha256': digest, 'time': time.time(), 'encoding': ENCODING}
    append(out, {**rec, 'event': 'reserve', 'reservation': RESERVE})
    start = time.monotonic()
    try:
        r = request('/chat/completions', b, timeout=300)
        try:
            reply = r.json()
        except ValueError:
            reply = {'unparseable_body_sha256': hashlib.sha256(r.content).hexdigest()}
        # Write the response before settling. An interruption leaves a reservation,
        # never an automatic retry. Unknown billing reserves the whole allowance.
        dump(out / 'responses' / (j['id'] + '.json'), reply)
        usage = reply.get('usage') or {}
        choice = (reply.get('choices') or [{}])[0]
        text = (choice.get('message') or {}).get('content')
        ok = (r.status_code == 200 and choice.get('finish_reason') == 'stop'
              and isinstance(text, str) and bool(text.strip()) and not reply.get('error')
              and reply.get('model') == G.MODEL)
        rec.update(event='settle', http=r.status_code, usage=usage, model=reply.get('model'),
                   finish=choice.get('finish_reason'), ok=ok,
                   cost=G.cost(usage) if known_usage(usage) else RESERVE,
                   wall_s=round(time.monotonic() - start, 3),
                   response_sha256=sha(out / 'responses' / (j['id'] + '.json')))
        rec = G.with_gateway_cost(rec, r)
    except Exception as e:
        # No response means unknown charge. Keep the reservation outstanding.
        dump(out / ('uncertain-' + j['id'] + '.json'), {'error_type': type(e).__name__, **rec})
        raise RuntimeError('uncertain paid attempt: ' + j['id'] + ' (' + type(e).__name__ + ')') from None
    append(out, rec)
    print(j['id'], 'ok' if ok else 'failed', rec['wall_s'], f'${G.charge(rec):.5f}', flush=True)
    return rec


def pilot_jobs(jobs):
    pages = []
    for cohort in sorted(COHORTS):
        pages += sorted({j['page'] for j in jobs if j['cohort'] == cohort})[:2]
    return [j for j in jobs if j['page'] in pages]


def run(a):
    validate_output(a.out, a.pack, a.truth)
    f, jobs, _ = check(a.pack, a.truth)
    a.out.mkdir(parents=True, exist_ok=True)
    receipt = {'item': TAG, 'pack_freeze_sha256': sha(a.pack / 'freeze.json'),
               'truth_index_sha256': sha(a.truth / 'index.json'), 'model': G.MODEL,
               'max_tokens': f['max_tokens'], 'temperature': 0, 'reasoning_effort': 'low',
               'no_cache': True, 'cap': CAP, 'reservation': RESERVE, 'encoding': ENCODING,
               'runner_sha256': sha(__file__), 'code_commit': subprocess.check_output(
                   ['git', '-C', str(HERE), 'rev-parse', 'HEAD'], text=True).strip()}
    if (a.out / 'receipt.json').exists():
        validate_receipt(a.out, a.pack, a.truth, f)
    else:
        dump(a.out / 'receipt.json', receipt)
    authority = HERE.parents[2] / 'OWNER_AUTHORIZATIONS.md'
    grant = authority.read_text().split('## 2026-11-01 — ready paid processing-review runs (owner session)', 1)[1]
    if '**W46.ocr-ppocrv6-hands-paid:**' not in grant or '**$2.50 working item cap**' not in grant:
        raise ValueError('the revised owner working cap is not recorded')
    dump(a.out / 'working-cap.json', {'cap': CAP, 'authorization_commit': '1565f7d9',
         'authorization_sha256': sha(authority), 'original_receipt_sha256': sha(a.out / 'receipt.json')})
    # A key failure happens before any reservation; no key is printed or persisted.
    load_key()
    pilot = pilot_jobs(jobs)
    tasks = pilot if a.cmd == 'pilot' else pilot + [j for j in jobs if j not in pilot]
    if a.cmd == 'repeat':
        tasks = [{**j, 'id': j['id'] + '-repeat'} for j in pilot if j['examples_n'] == 0]
    for j in tasks:
        if a.cmd == 'run' and j not in pilot:
            pending, done, spent = state(journal(a.out))
            pilots = [done[k['id']] for k in pilot]
            projection = (sum(G.charge(r) for r in pilots) / len(pilots) * (len(jobs) + 8)
                          + prior_spend(a.out)[0] + RESERVE)
            if pending or any(not r['ok'] for r in pilots) or projection > CAP:
                raise ValueError('pilot failed or projects beyond the item cap; inspect before proceeding')
        call(a.pack, f, j, a.out)
    pending, done, spent = state(journal(a.out))
    pilots = [done[j['id']] for j in pilot if j['id'] in done]
    projection = (sum(G.charge(r) for r in pilots) / len(pilots) * (len(jobs) + 8)
                  + prior_spend(a.out)[0] + RESERVE) if pilots else None
    spent += prior_spend(a.out)[0]
    summary = {'settled': len(done), 'pending': len(pending), 'charged': spent,
               'failed': sum(not r['ok'] for r in done.values()),
               'pilot_requests': len(pilots), 'projected_221_calls_usd': projection}
    dump(a.out / 'status.json', summary)
    print(json.dumps(summary))


def interval(values, clusters=None, rounds=10000):
    """Conditional page bootstrap, or collection bootstrap retaining all pages.

    One diary/one folder cannot estimate across-hand uncertainty. These bounds
    describe pages of the observed hand only. Public transfer also gets a
    collection-clustered interval, retaining unequal cluster sizes.
    """
    if not values:
        return {'n': 0, 'delta': None, 'lo': None, 'hi': None}
    rng = random.Random(46)
    groups = defaultdict(list)
    for i, v in enumerate(values):
        groups[clusters[i] if clusters else i].append(v)
    groups = list(groups.values())
    boots = []
    for _ in range(rounds):
        draw = [v for g in rng.choices(groups, k=len(groups)) for v in g]
        boots.append(statistics.mean(draw))
    boots.sort()
    return {'n': len(values), 'clusters': len(groups), 'delta': statistics.mean(values),
            'lo': boots[int(.025 * rounds)], 'hi': boots[int(.975 * rounds) - 1]}


def analyze(jobs, rows, truths, outputs, score):
    """Pure scoring core; failures remain separate and count zero in sensitivity.

    Inputs are programmatically read by report(), never by coding agents.
    """
    detail = []
    for j in jobs:
        r = rows.get(j['id'])
        text = outputs.get(j['id'], '') if r and r['ok'] else ''
        metrics = score(truths[j['page']], text, 'S0' if j['page'].startswith('owner-') else 'L1')
        detail.append({'page': j['page'], 'cohort': j['cohort'], 'collection': j['collection'],
                       'examples_n': j['examples_n'], 'attempted': r is not None,
                       'ok': bool(r and r['ok']), 'nes': 100 * metrics['nes'] if r and r['ok'] else 0.,
                       'missed': metrics['missed'], 'added': metrics['added'], 'words': metrics['words']})
    groups, comparisons = [], []
    for cohort in sorted({j['cohort'] for j in jobs}):
        group = [r for r in detail if r['cohort'] == cohort]
        for n in COUNTS:
            rr = [r for r in group if r['examples_n'] == n]
            ok = [r for r in rr if r['ok']]
            words = sum(r['words'] for r in rr)
            groups.append({'cohort': cohort, 'examples_n': n, 'n': len(rr), 'answered': len(ok),
                           'attempted': sum(r['attempted'] for r in rr),
                           'nes_strict': statistics.mean(r['nes'] for r in rr),
                           'nes_answered': statistics.mean(r['nes'] for r in ok) if ok else None,
                           'words_missed_pct': 100 * sum(r['missed'] for r in rr) / words,
                           'words_added_pct': 100 * sum(r['added'] for r in rr) / words})
        by = {(r['page'], r['examples_n']): r for r in group}
        pages = sorted({r['page'] for r in group})
        for n in (8, 16):
            both = [p for p in pages if by[p, 0]['ok'] and by[p, n]['ok']]
            diff = [by[p, n]['nes'] - by[p, 0]['nes'] for p in both]
            strict = [by[p, n]['nes'] - by[p, 0]['nes'] for p in pages]
            comparisons.append({'cohort': cohort, 'examples_n': n,
                                'both_answered': interval(diff), 'strict': interval(strict),
                                'collection_clustered': interval(diff, [by[p, n]['collection'] for p in both])})
    return {'groups': groups, 'comparisons': comparisons, 'pages': detail}


def report(a):
    import ocr_panel_score as S
    freeze, jobs, refs = check(a.pack, a.truth)
    receipt = validate_receipt(a.out, a.pack, a.truth, freeze)
    pending, rows, spent = state(journal(a.out))
    expected = {j['id']: j for j in jobs}
    expected.update({j['id'] + '-repeat': {**j, 'id': j['id'] + '-repeat'}
                     for j in pilot_jobs(jobs) if j['examples_n'] == 0})
    texts = {}
    for key, r in rows.items():
        if key not in expected or r['request_sha256'] != request_hash(body(a.pack, freeze, expected[key])):
            raise ValueError('recorded request does not match the frozen experiment')
        path = a.out / 'responses' / (key + '.json')
        if sha(path) != r['response_sha256']:
            raise ValueError('response checksum changed')
        reply = json.loads(path.read_text())
        texts[key] = ((reply.get('choices') or [{}])[0].get('message') or {}).get('content') or ''
    truths = {p: inside(a.truth, r['path']).read_text() for p, r in refs.items()}
    result = analyze(jobs, rows, truths, texts, S.score)
    noise = []
    for j in pilot_jobs(jobs):
        if j['examples_n'] != 0:
            continue
        repeat = j['id'] + '-repeat'
        if repeat in rows and rows[repeat]['ok'] and rows.get(j['id'], {}).get('ok'):
            stratum = 'S0' if j['page'].startswith('owner-') else 'L1'
            delta = 100 * (S.score(truths[j['page']], texts[repeat], stratum)['nes'] -
                           S.score(truths[j['page']], texts[j['id']], stratum)['nes'])
            noise.append({'cohort': j['cohort'], 'delta': delta})
    result.update(item=TAG, model=G.MODEL, settings={'temperature': 0, 'reasoning_effort': 'low',
                  'max_tokens': freeze['max_tokens'], 'cache': {'no-cache': True}},
                  cohorts=freeze['cohorts'], cost=G.billed([*rows.values(), *prior_spend(a.out)[1]]),
                  charged=spent + prior_spend(a.out)[0], prior_pilot=G.billed(prior_spend(a.out)[1]),
                  encoding=ENCODING,
                  pending=len(pending), complete=not pending and all(j['id'] in rows for j in jobs), repeats=noise,
                  returned_models=dict(Counter(r['model'] for r in rows.values())), receipt=receipt,
                  pack_freeze_sha256=sha(a.pack / 'freeze.json'),
                  truth_index_sha256=sha(a.truth / 'index.json'))
    # Owner sensitivity: the nine of the original 16 hand pages with no unresolved
    # place. This doesn't turn the remaining model-drafted reference into gold.
    import ocr_hands_rescore as HS
    rulings = json.loads((HS.HANDS / 'rulings.json').read_text())
    unresolved = HS.unresolved(rulings['rulings'])
    hand16 = set(json.loads((RESULTS / 'ocr-hands-rescore.json').read_text())['pages'])
    clear = [j for j in jobs if j['page'].startswith('owner-')
             and j['page'].removeprefix('owner-') in hand16 - set(unresolved)]
    if clear:
        result['owner_clear'] = analyze(clear, rows, truths, texts, S.score)
    dump(RESULTS / 'ocr-ppocrv6-hands-paid.json', result)
    write_report(result)
    print(json.dumps({k: result[k] for k in ('complete', 'charged', 'cost', 'cohorts')}))


def write_report(r):
    def num(v):
        return '—' if v is None else f'{v:.2f}'
    def ci(v):
        return '—' if not v['n'] else f"{v['delta']:+.2f} ({v['lo']:+.2f} to {v['hi']:+.2f}; n={v['n']})"
    L = ['# Gemini given corrected handwriting lines (W46.ocr-ppocrv6-hands-paid)', '',
         'Gemini 3.7 Flash through the Stanford gateway, using the Qwen arm’s frozen 0/8/16 image/text '
         'example pack, with each crop a separate image. Scores are NES points. Only the Blackwell holdout tests a documented same hand; '
         'the Shils folder is a hand proxy, and the other cohorts test transfer with unverified hand identity. '
         'The 40 L1 pages include three Blackwell diary pages (other volumes) and two Blackwell '
         'correspondence pages; they are not all known different hands.', '',
         '## Measurement card', '',
         '- **Truth:** public By the People transcriptions (CC0). Owner targets use the post-sheet truth '
         '(W46.ocr-hands-rescore); Gemini 3.8/Claude drafted it and 114 hand places were checked, '
         'with 10 unresolved. Owner figures are reference agreement, not independent model rankings. '
         'The 19 typed controls found no error, with an exact 95% passage-error upper bound of 17.6%. '
         'Examples are the existing PP-OCRv6-aligned corrected lines: model-filtered, not a random line draw. '
         'Owner exemplar lines predate the sheet corrections and may retain reference errors.',
         '- **Selection:** fixed Qwen pack: 40 seeded L1 pages, all 19 owner hand pages, 12 held-out '
         'Blackwell diary pages. Blackwell examples come only from its 24 training pages. Shils leaves '
         'the target page out; source-image hashes reject aliases. No target truth enters the prompt. '
         'Owner targets include the 16 scored hand pages and three agreement-only letters (p086, p094, p096), '
         'which remain unvalidated. L2 is not an adaptation cohort because no verified same-hand example pool was prepared.',
         '- **Comparison:** identical 2400 px/quality-90 target JPEGs across 0/8/16 examples; quality-95 '
         'line crops, eight examples the prefix of sixteen; same target prompt as the Qwen pack. '
         'Each example is a separate crop paired with its corrected line text; no target or example crop is scaled locally. Temperature 0, '
         'low reasoning, 8192-token output cap, gateway cache disabled. Single attempts; capped, empty '
         'or transport failures are separate and score zero only in strict sensitivity. Qwen uses the same '
         'example images with no thinking; this is not a controlled model-only comparison. These subsets enter their own panel, '
         'not whole-96 or whole-895 charts.',
         '- **Noise:** 10,000-round paired page bootstrap, both-answered headline and failure=0 sensitivity. '
         'Public transfer additionally bootstraps collection clusters. A single diary and four Shils pages '
         'cannot estimate variation across hands. The inherited hosted floor is 0.60 points '
         '(twice the measured handwritten-kind rerun range; the 96-wide floor is 0.49); public and prompt-specific '
         'noise is not established. Eight preselected zero-example repeats check stability only. '
         'An interval spanning zero or a gap inside the floor is a tie.',
         '- **Scope:** zero-training adaptation on these pages and examples only; no app default, fine-tune '
         'or new-hand population claim. Cross-hand transfer cannot answer same-hand adaptation. '
         'No corpus modified; no target transcription supplied to a model.', '',
         '## Paired conditions', '',
         '| cohort | examples | answered / attempted / fixed n | NES answered | NES strict | missed words % | added words % |',
         '|---|---:|---:|---:|---:|---:|---:|']
    for g in r['groups']:
        L.append(f"| {g['cohort']} | {g['examples_n']} | {g['answered']} / {g['attempted']} / {g['n']} | "
                 f"{num(g['nes_answered'])} | {num(g['nes_strict'])} | {num(g['words_missed_pct'])} | {num(g['words_added_pct'])} |")
    L += ['', '| cohort | examples | Δ vs zero, both answered (95% CI) | Δ strict (95% CI) | collection-clustered (95% CI) |',
          '|---|---:|---|---|---|']
    for c in r['comparisons']:
        cluster = ci(c['collection_clustered']) if c['cohort'] == 'public-L1-transfer' else 'across-hand interval not estimated'
        L.append(f"| {c['cohort']} | {c['examples_n']} | {ci(c['both_answered'])} | {ci(c['strict'])} | {cluster} |")
    L += ['', '## Stability and owner sensitivity', '',
          f"Zero-example repeats: {len(r['repeats'])}; " + '; '.join(
              f"{cohort}: mean move {statistics.mean(x['delta'] for x in r['repeats'] if x['cohort'] == cohort):+.2f}"
              for cohort in sorted({x['cohort'] for x in r['repeats']})) + '.',
          'These are two pages per cohort, too few to estimate a reliable rerun floor.']
    if r.get('owner_clear'):
        L += ['', 'Owner pages without unresolved sheet places (the nine clear pages of the original 16), '
              'kept apart by cohort; the four-page Shils inference remains descriptive:', '',
              '| cohort | examples | Δ vs zero, both answered (95% CI) |', '|---|---:|---|']
        for c in r['owner_clear']['comparisons']:
            L.append(f"| {c['cohort']} | {c['examples_n']} | {ci(c['both_answered'])} |")
    L += ['', '## Cost and provenance', '',
          f"Charged against the owner-revised $2.50 working item cap: ${r['charged']:.5f}. List-rate estimate ${r['cost']['estimate']:.5f} "
          f"at ${G.PRICE[0]}/${G.PRICE[1]} per million input/output tokens (including reasoning); gateway’s own "
          f"figure ${r['cost']['gateway'] or 0:.5f} on {r['cost']['gateway_calls']} of {r['cost']['calls']} attempts. "
          'The cap counts the larger for each request; any unknown request keeps its full reservation. '
          'No retries. The initial 24-request pilot cost $0.1950195 and projected $1.7958 for 221 calls. '
          'The owner revised the working cap from the initial agent-set $1 estimate to $2.50 '
          '(OWNER_AUTHORIZATIONS.md, 1565f7d9); all pilot answers were preserved, not re-called. '
          'A sheet alternative was prepared but made no paid call and is not an accuracy arm. '
          'Stanford PTA, not subscription usage.', '',
          f"Frozen pack SHA-256 `{r['pack_freeze_sha256']}`; truth-index SHA-256 `{r['truth_index_sha256']}`. "
          'Private input pack `~/.local/state/archive-autonomous/artifacts/hand-icl-20261101`, target truth '
          '`hand-icl-truth-20261101`, responses/ledger/receipt `hand-icl-gateway-20261101`. '
          'The receipt records the runner hash and code commit; each ledger outcome pins request and response '
          'hashes, usage, finish reason, returned model and time. Shared inputs are read-only. '
          'No rendered or model scratch created; only paid replies and audit receipts retained.', '',
          'Reproduce: `python3 ops/autonomous/heavy-run.py run -- uv run --offline --with rapidfuzz '
          "--with 'sacrebleu==2.5.1' --with regex python ArchiveProcessor/scripts/segbench/hand_icl_gateway.py report`."]
    (RESULTS / 'ocr-ppocrv6-hands-paid.md').write_text('\n'.join(L) + '\n')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('cmd', choices=['check', 'pilot', 'run', 'repeat', 'report'])
    p.add_argument('--pack', type=Path, default=DEFAULT_PACK)
    p.add_argument('--truth', type=Path, default=DEFAULT_TRUTH)
    p.add_argument('--out', type=Path, default=DEFAULT_OUT)
    a = p.parse_args()
    if a.cmd == 'check':
        f, j, _ = check(a.pack, a.truth)
        print(json.dumps({'jobs': len(j), 'cohorts': f['cohorts'], 'pack_sha256': sha(a.pack / 'freeze.json')}))
    elif a.cmd == 'report':
        report(a)
    else:
        import fcntl
        validate_output(a.out, a.pack, a.truth)
        a.out.mkdir(parents=True, exist_ok=True)
        with (a.out / '.run.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            run(a)


if __name__ == '__main__':
    main()
