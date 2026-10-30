#!/usr/bin/env python3
"""W46.fix-marks-set-draft: the ~1,000-page marks pre-flag scan (v2).

Follows the 15-page pilot (marks_pilot.py, left frozen as it ran). Same reader,
same original-JPEG inventory and helpers; the prompt names the pilot's false
flags and asks for the owner's handwriting band. Offline prepare/check/summary;
read talks ONLY to a loopback vLLM server. Candidate discovery, never mark
truth. Sherlock submission is owner-attended.
"""
from __future__ import annotations

import argparse
from collections import Counter
import http.client
import importlib.metadata
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import time
import urllib.request

import marks_pilot as P

HERE = Path(__file__).resolve().parent
PROTOCOL = 'marks-preflag-scan-v2'
PACK = 'marks-scan-20261029'
COLLECTIONS = P.COLLECTIONS
CLASSES = P.CLASSES
HAND_CLASSES = ('annotation', 'marginal_note', 'signature_initials')
AMOUNTS = ('none', 'signature_initials_date', 'under_10_words', '10_29_words', '30_plus_words',
           'handwritten_page')
PER_COLLECTION = 225  # RG165 has 114 and is taken whole; size review in the item note
MODEL = P.MODEL
SERVED = 'marks-scan-qwen3.6-27b'
VLLM_ARGS = P.VLLM_ARGS
MAX_TOKENS = P.MAX_TOKENS
TIMEOUT = P.TIMEOUT
SEED = 'W46.fix-marks-set-draft-scan-20261029'
SUPPORT = ('marks_scan.py', 'marks_pilot.py', 'marks-scan-submit.sh', 'marks-scan-stage-job.sh',
           'marks-scan-job.sh', 'sherlock/sh.env', 'sherlock/bin/py', 'sherlock/bin/vllm')
PROMPT = '''Inspect this archival page photograph for marks. This is only candidate discovery.
A mark is anything added by hand or by a stamp to a typed or printed page: handwriting of any
size (including a signature, initials or a date), a stamp, or a redaction.
These are NOT marks: text or ink showing through from the reverse side of the sheet; a printed
or reproduced signature (in a cartoon, a letterhead or any printed matter); typewriter
underlining, overstrikes or typed corrections; marks on a neighbouring page, an archive slip or
a ruler.
Do not count handwriting that forms the main body of an entirely handwritten page as an
annotation. A mark may overlap printed text.
Return ONLY one JSON object with these exact keys:
"page_kind": "typed_printed", "handwritten" or "nontext";
"marks": an object with exactly these boolean fields: annotation, marginal_note, stamp,
signature_initials, redaction, other;
"handwriting_amount": how much handwriting the page carries, exactly one of "none",
"signature_initials_date" (only a signature, initials or a date), "under_10_words",
"10_29_words", "30_plus_words", "handwritten_page" (the page itself is handwritten);
"overlap_with_print": boolean (any mark overlaps print);
"uncertain": boolean (any part of your judgement is doubtful).
Report presence, not counts. Do not transcribe any text or produce coordinates. No Markdown.'''
FENCE = re.compile(r'\A\s*```(?:json)?[ \t]*\n(.*)\n[ \t]*```\s*\Z', re.S)


def order(rows, c):
    group = [r for r in rows if r['collection'] == c]
    return sorted(group, key=lambda r: P.digest((SEED + ':' + r['id']).encode()))


def choose(rows, skipped=()):
    """Seed order per collection, duplicates (by source bytes) skipped, cap per collection."""
    skipped = set(skipped)
    out = []
    for c in COLLECTIONS:
        out += [r for r in order(rows, c) if r['id'] not in skipped][:PER_COLLECTION]
    return out


def prepare(out, pairs, originals, roots):
    from PIL import Image, ImageOps
    out = P.safe_output(out)
    originals = originals.resolve()
    if originals.is_relative_to(out) or out.is_relative_to(originals):
        raise ValueError('source and output overlap')
    rows = P.inventory(pairs, originals, roots)
    out.mkdir()  # fail on an existing draft; never overwrite corrected work
    P.write_new(out / 'inventory.json', P.encoded(dict(seed=SEED, roots=roots, pages=rows,
                                                      originals=str(originals),
                                                      pairs_sha256=P.file_hash(pairs))))
    pages, skipped, seen = [], [], {}
    for c in COLLECTIONS:
        taken = 0
        for r in order(rows, c):
            if taken == PER_COLLECTION:
                break
            src = P.relative(originals, r['source_rel'])
            source_sha = P.file_hash(src)
            if source_sha in seen:  # the same photograph under two names: read it once
                skipped.append(dict(id=r['id'], same_as=seen[source_sha], source_sha256=source_sha))
                continue
            seen[source_sha] = r['id']
            dest = out / 'images' / (r['id'] + '.jpg')
            dest.parent.mkdir(exist_ok=True)
            with Image.open(src) as im:
                img = ImageOps.exif_transpose(im).convert('RGB')
                size = list(img.size)
                img.thumbnail((2400, 2400), Image.Resampling.LANCZOS)
                img.save(dest, format='JPEG', quality=95)
                sent_size = list(img.size)
            if P.file_hash(src) != source_sha:
                raise ValueError('original changed during preparation')
            pages.append(dict(id=r['id'], collection=c, image='images/' + dest.name,
                              source_sha256=source_sha, original_size=size, sent_size=sent_size))
            taken += 1
    for name in SUPPORT:
        dest = out / 'support' / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(HERE / name, dest)
    P.write_new(out / 'scan.json', P.encoded(dict(pages=pages, skipped=skipped, prompt=PROMPT)))
    files = ['inventory.json', 'scan.json'] + [p['image'] for p in pages] + ['support/' + n for n in SUPPORT]
    frozen = dict(protocol=PROTOCOL, model=MODEL, served=SERVED, vllm_args=VLLM_ARGS,
                  max_tokens=MAX_TOKENS, timeout=TIMEOUT,
                  files={name: P.file_hash(out / name) for name in files})
    P.write_new(out / 'freeze.json', P.encoded(frozen))
    check(out)
    return dict(inventory=len(rows), scan=len(pages), skipped_duplicates=len(skipped),
                collections=dict(Counter(p['collection'] for p in pages)),
                freeze_sha256=P.file_hash(out / 'freeze.json'))


def check(root):
    frozen, scan = P.load(root / 'freeze.json'), P.load(root / 'scan.json')
    expected = dict(protocol=PROTOCOL, model=MODEL, served=SERVED, vllm_args=VLLM_ARGS,
                    max_tokens=MAX_TOKENS, timeout=TIMEOUT)
    if any(frozen.get(k) != v for k, v in expected.items()) or scan['prompt'] != PROMPT:
        raise ValueError('changed scan protocol/model/settings')
    pages, skipped = scan['pages'], scan['skipped']
    pool = P.load(root / 'inventory.json')['pages']
    by_id = {p['id']: p for p in pages}
    if len({p['id'] for p in pool}) != len(pool) or len(by_id) != len(pages):
        raise ValueError('duplicate page IDs')
    # A skip is only legitimate when it repeats the source bytes of a page that is read.
    for s in skipped:
        kept = by_id.get(s['same_as'])
        if kept is None or kept['source_sha256'] != s['source_sha256'] or s['id'] in by_id:
            raise ValueError('unexplained skipped page')
    chosen = choose(pool, [s['id'] for s in skipped])
    if ([p['id'] for p in pages] != [p['id'] for p in chosen]
            or len({p['source_sha256'] for p in pages}) != len(pages)):
        raise ValueError('duplicate/missing/changed selection')
    for p, source in zip(pages, chosen):
        if (p['collection'] != source['collection'] or not re.fullmatch(r'[0-9a-f]{64}', p['source_sha256'])
                or p['image'] != 'images/' + p['id'] + '.jpg'):
            raise ValueError('page provenance mismatch')
    names = {'inventory.json', 'scan.json'} | {p['image'] for p in pages} | {'support/' + n for n in SUPPORT}
    if set(frozen['files']) != names:
        raise ValueError('missing/extra frozen files')
    for name, sha in frozen['files'].items():
        if P.file_hash(P.relative(root, name)) != sha:
            raise ValueError(f'changed frozen file: {name}')
    for name in SUPPORT:
        if P.file_hash(HERE / name) != frozen['files']['support/' + name]:
            raise ValueError('running code differs from frozen support')
    return frozen, scan


def prediction(raw):
    """(object, fenced, consistent). A fence is removed and recorded, never hidden."""
    m = FENCE.match(raw)
    obj = P.loads(m.group(1) if m else raw)
    keys = {'page_kind', 'marks', 'handwriting_amount', 'overlap_with_print', 'uncertain'}
    if not isinstance(obj, dict) or set(obj) != keys:
        raise ValueError('wrong prediction keys')
    if obj['page_kind'] not in ('typed_printed', 'handwritten', 'nontext'):
        raise ValueError('invalid page kind')
    if obj['handwriting_amount'] not in AMOUNTS:
        raise ValueError('invalid handwriting amount')
    if not isinstance(obj['marks'], dict) or set(obj['marks']) != set(CLASSES):
        raise ValueError('wrong mark keys')
    if any(type(v) is not bool for v in [*obj['marks'].values(), obj['overlap_with_print'], obj['uncertain']]):
        raise ValueError('mark flags must be JSON booleans')
    if obj['overlap_with_print'] and not any(obj['marks'].values()):
        raise ValueError('overlap asserted without a mark')
    hand = any(obj['marks'][k] for k in HAND_CLASSES)
    amount = obj['handwriting_amount']
    # Kept, not refused: an inconsistent reply is a weaker candidate signal.
    consistent = ((amount == 'handwritten_page') == (obj['page_kind'] == 'handwritten')
                  and (amount != 'none' or not hand)
                  and (amount in ('none', 'handwritten_page') or hand))
    return obj, bool(m), consistent


def request(root, p, served=SERVED):
    req = P.request(root, p, served)
    req['messages'][0]['content'][1]['text'] = PROMPT
    return req


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
                protocol=PROTOCOL, freeze_sha256=P.file_hash(root / 'freeze.json'),
                request_sha256=P.digest(P.encoded(request(root, p, runtime['served']))))


STATUSES = ('ok', 'cap', 'parse', 'error', 'interrupted')


def receipt_check(root, p, rec):
    expected = identity(root, p, rec['runtime'])
    if any(rec.get(k) != v for k, v in expected.items()):
        raise ValueError('stale/mismatched receipt')
    if rec['status'] not in STATUSES:
        raise ValueError('invalid receipt outcome')
    if rec['status'] != 'interrupted' and (not isinstance(rec.get('wall_s'), (int, float)) or rec['wall_s'] < 0):
        raise ValueError('missing receipt timing')
    if rec['status'] == 'ok':
        choice = rec['response']['choices'][0]
        obj, fenced, consistent = prediction(choice['message']['content'])
        if (choice['finish_reason'] != 'stop' or obj != rec['prediction'] or fenced != rec['fenced']
                or consistent != rec['consistent']):
            raise ValueError('receipt result disagrees with saved response')


def read(root, url, runtime, deadline=None):
    """Read every page without a receipt. Stops starting requests after `deadline` seconds."""
    _, scan = check(root)
    url = P.server_url(url)
    runtime_check(runtime)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), P.NoRedirect())
    started = time.monotonic()
    for p in scan['pages']:
        dest = root / 'out' / (p['id'] + '.json')
        intent = root / 'intents' / (p['id'] + '.json')
        meta = identity(root, p, runtime)
        if dest.exists():
            old = P.load(dest)
            receipt_check(root, p, old)
            if any(old['runtime'].get(k) != v for k, v in runtime.items() if k not in ('job', 'served')):
                raise ValueError('resume would mix model runtimes')
            if P.load(intent) != identity(root, p, old['runtime']):
                raise ValueError('intent disagrees with receipt')
            continue  # errors/caps are outcomes, never silently retried
        if intent.exists():
            # A request was sent and its job died before the reply was saved. Record
            # that as the outcome under the intent's own runtime; it is never replayed.
            old_intent = P.load(intent)
            if old_intent != identity(root, p, old_intent['runtime']):
                raise ValueError('stale intent')
            P.write_new(dest, P.encoded(dict(**old_intent, status='interrupted')))
            print(p['id'], 'interrupted', flush=True)
            continue
        if deadline is not None and time.monotonic() - started > deadline:
            print('deadline reached; remaining pages left unread for a later job', flush=True)
            return
        P.write_new(intent, P.encoded(meta))
        rec = dict(**meta, status='error')
        start = time.monotonic()
        try:
            req = urllib.request.Request(url + '/v1/chat/completions',
                                         data=P.encoded(request(root, p, runtime['served'])),
                                         headers={'Content-Type': 'application/json'})
            with opener.open(req, timeout=TIMEOUT) as response:
                raw = response.read(2_000_001)
                if len(raw) > 2_000_000:
                    raise ValueError('response exceeds 2 MB')
            rec['response_text'] = raw.decode()
            rec['status'] = 'parse'
            response = P.loads(raw.decode())
            rec['response'] = response
            choice = response['choices'][0]
            rec['status'] = 'cap' if choice['finish_reason'] == 'length' else 'error'
            if choice['finish_reason'] == 'stop':
                rec['status'] = 'parse'
                rec['prediction'], rec['fenced'], rec['consistent'] = prediction(choice['message']['content'])
                rec['status'] = 'ok'
        except (OSError, ValueError, KeyError, IndexError, TypeError, http.client.HTTPException) as e:
            rec['error'] = str(e)[:500]
        rec['wall_s'] = round(time.monotonic() - start, 4)
        P.write_new(dest, P.encoded(rec))
        print(p['id'], rec['status'], flush=True)


def summary(root):
    _, scan = check(root)
    expected = {p['id'] + '.json' for p in scan['pages']}
    receipts = {p.name for p in (root / 'out').glob('*.json')}
    intents = {p.name for p in (root / 'intents').glob('*.json')}
    if not receipts <= expected or not intents <= expected or receipts != intents:
        raise ValueError('extra receipts, or a receipt without its intent')
    records = []
    for p in scan['pages']:
        if p['id'] + '.json' not in receipts:
            continue
        rec = P.load(root / 'out' / (p['id'] + '.json'))
        receipt_check(root, p, rec)
        if P.load(root / 'intents' / (p['id'] + '.json')) != identity(root, p, rec['runtime']):
            raise ValueError('intent disagrees with receipt')
        records.append(rec)
    if len({P.encoded({k: v for k, v in r['runtime'].items() if k not in ('job', 'served')})
            for r in records}) > 1:
        raise ValueError('model runtime changed within scan')
    ok = [r for r in records if r['status'] == 'ok']
    timed = [r['wall_s'] for r in records if 'wall_s' in r]
    by = {}
    for c in COLLECTIONS:
        rows = [r for r in ok if r['collection'] == c]
        by[c] = dict(ok=len(rows), flagged=sum(any(r['prediction']['marks'].values()) for r in rows),
                     amount=dict(Counter(r['prediction']['handwriting_amount'] for r in rows)))
    return dict(protocol=PROTOCOL, pages=len(scan['pages']), read=len(records),
                complete=len(records) == len(scan['pages']),
                status=dict(Counter(r['status'] for r in records)),
                fenced=sum(r['fenced'] for r in ok), inconsistent=sum(not r['consistent'] for r in ok),
                uncertain=sum(r['prediction']['uncertain'] for r in ok),
                by_collection=by,
                request_seconds=round(sum(timed), 4),
                median_seconds=statistics.median(timed) if timed else None,
                note='Candidate flags only; no mark truth, precision or recall. The 150-page set is '
                     'drafted and audited from these, then the owner checks its core.')


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
            p.add_argument('--deadline', type=float)
        if cmd == 'runtime':
            p.add_argument('--revision', required=True); p.add_argument('--out', required=True, type=Path)
    a = ap.parse_args()
    if a.cmd == 'prepare':
        print(json.dumps(prepare(a.root, a.pairs, a.originals, P.load(a.source_roots))))
    elif a.cmd == 'check':
        _, scan = check(a.root)
        print(f"scan freeze verified: {len(scan['pages'])} original-JPEG pages, five collections")
    elif a.cmd == 'read':
        P.safe_output(a.root); read(a.root, a.url, P.load(a.runtime), a.deadline)
    elif a.cmd == 'summary':
        print(json.dumps(summary(a.root), indent=2))
    else:
        check(a.root)
        P.safe_output(a.out)
        runtime = dict(model=MODEL, vllm_args=VLLM_ARGS, revision=a.revision,
                       job=os.environ.get('SLURM_JOB_ID', ''),
                       served=SERVED + '-' + os.environ.get('SLURM_JOB_ID', ''),
                       vllm_version=importlib.metadata.version('vllm'),
                       transformers_version=importlib.metadata.version('transformers'))
        runtime_check(runtime); P.write_new(a.out, P.encoded(runtime))


if __name__ == '__main__':
    main()
