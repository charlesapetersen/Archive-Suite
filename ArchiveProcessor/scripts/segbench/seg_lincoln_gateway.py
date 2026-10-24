"""W46.seg-lincoln-cloud-paid: frozen prompts/inputs, gateway only, one $3 item ledger.

  <lab python> seg_lincoln_gateway.py inventory|collect|score PUBLIC_ROOT

Public windows: Gemini 3.7 Flash and GLM 5.3 Flash, g1, 1600px, 7 pages/stride 3.
Whole folders: Gemini, wh1, ONE uninterrupted stream per public box (no truth document cuts).
Claude c2: only holes in the pre-existing plan cache, on CREST and Deaver. The gateway
uses inline images rather than tool reads, and its cache and provenance remain separate.
No subscription calls, personal keys, corpus writes, or automatic retries. A non-parsing
reply remains a recorded failure, never a neutral vote. Scoring cannot make calls.

The gateway publishes no price: costs are estimates at list token rates, reasoning included.
Gemini .75/3.75, GLM .15/.50, Claude 2/10 USD/M, checked against OpenRouter /models
2026-10-24 (not the gateway's bill). A single-process lock covers collection; fsynced
pre-send reservations survive interruption. Unknown usage keeps the reservation and stops.
"""
from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import io
import json
import os
import re
from pathlib import Path
import time
import uuid

import data
from methods import METHODS  # noqa: F401 -- initialize registered modules in their normal order
import gateway_gemini as GW
import method_gemini as G
import method_whole as H
import method_window as W
import method_window_cues as C

STORE = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/seg-lincoln-gateway'
RESULTS = data.HERE.parents[1] / 'segbench-results'
CAP = 3.00
MODELS = {'gemini': 'gemini-3.7-flash', 'glm': 'GLM 5.3 Flash', 'claude-cue': 'claude-sonnet-5-5'}
PRICES = {'gemini': (.75, 3.75), 'glm': (.15, .50), 'claude-cue': (2., 10.)}
PUBLIC_KEYS = ('gateway-gemini', 'gateway-glm', 'gateway-gemini-whole')


def records():
    p = STORE / 'calls.jsonl'
    return [json.loads(l) for l in p.read_text().splitlines()] if p.exists() else []


def spent(rows=None):
    """One effective charge per request, including unsettled reservations from a killed session."""
    charges = {}
    for r in records() if rows is None else rows:
        charges[r['id']] = r['charge']
    return sum(charges.values())


def effective_records():
    latest = {}
    for r in records():
        latest[r['id']] = r
    return list(latest.values())


def append(rec):
    STORE.mkdir(parents=True, exist_ok=True)
    with (STORE / 'calls.jsonl').open('a') as f:
        f.write(json.dumps(rec) + '\n')
        f.flush()
        os.fsync(f.fileno())


def request(route, col, a, b, whole=False):
    missing = [p.n for p in col.pages[a:b] if not data.ocr_cache_path(col.name, p.n).is_file()]
    if missing:
        raise ValueError(f'{col.name}: missing cached Vision text for {missing}; refusing changed inputs')
    prompt, thumbs, nums = (H if whole else G).build_request(col, a, b)
    if route == 'claude-cue':
        prompt += C.cue_block(col, nums, list(range(a, b)))
    # Same semantic answer shape as the existing g1/wh1 schemas. No tools/file-read instructions.
    schema = H.RESPONSE_SCHEMA if whole else G.RESPONSE_SCHEMA
    prompt += '\nReturn only one JSON object matching this schema:\n' + json.dumps(schema)
    parts = []
    for n, t in zip(nums, thumbs):
        image = t.read_bytes()
        if whole:
            # The gateway rejects bodies above 32 MB before inference. Keep the same 1600px
            # pages, order and prompt; wh1 uses a declared fixed JPEG quality of 45 throughout.
            from PIL import Image
            buf = io.BytesIO()
            with Image.open(t) as im:
                im.convert('RGB').save(buf, 'JPEG', quality=45, optimize=True)
            image = buf.getvalue()
        parts += [{'type': 'text', 'text': f'Page {n}:'},
                  {'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,' +
                    base64.b64encode(image).decode()}}]
    parts.append({'type': 'text', 'text': prompt})
    body = {'model': MODELS[route], 'temperature': 0, 'max_tokens': 32768 if whole else 4096,
            'messages': [{'role': 'user', 'content': parts}]}
    if whole:
        body['response_format'] = {'type': 'json_object'}
    if route != 'claude-cue':
        body['reasoning_effort'] = 'low' if route == 'gemini' else 'minimal'
    if len(json.dumps(body).encode()) > 32_000_000:
        raise ValueError('body exceeds the gateway 32 MB limit; no call sent')
    key = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
    return body, key, nums


def normalized(raw, whole):
    # Gemini can wrap an otherwise complete JSON reply even when asked for no fence.
    # Strip only a single surrounding fence; H still requires every gap exactly once.
    text = raw.strip()
    note = {'parser': 'gw2', 'fence': False}
    if whole and (m := re.fullmatch(r'```(?:json)?\s*\n(.*?)\n```', text, re.S)):
        text = m[1]
        note['fence'] = True
    return text, note


def parse(raw, nums, whole):
    text, _ = normalized(raw, whole)
    return H.parse_answer(text, nums) if whole else W.parse_answer(text, nums)


def reservation(route, body):
    # Conservative input allowance: one token per UTF-8 text byte + 8192 per <=1600px
    # image + message overhead, bounded by the models' published 1M context. It is an
    # allowance, not a gateway billing guarantee; rates above are explicitly estimates.
    parts = body['messages'][0]['content']
    text = sum(len(p['text'].encode()) for p in parts if p['type'] == 'text')
    images = sum(p['type'] == 'image_url' for p in parts)
    tokens = min(1_048_576, text + 8192 * images + 2048)
    pi, po = PRICES[route]
    return (tokens * pi + body['max_tokens'] * po) / 1e6


def cached(key):
    p = STORE / 'replies' / f'{key}.json'
    return json.loads(p.read_text()) if p.exists() else None


def reconcile_413():
    """Release only the gateway's explicit pre-inference 32 MB rejection, preserving its audit trail.

    Never release a timeout/5xx/missing usage from an inference response. Called explicitly,
    with the collector lock held; the rejected original request is still not retried.
    """
    for r in records():
        if r['event'] != 'settle' or r.get('http') != 413 or not r['charge']:
            continue
        hit = cached(r['request_sha256'])
        if not hit or hit['response'] != {'error': 'Request size is too large. Max size is 32 MB'}:
            raise RuntimeError('unrecognized 413 response; keep the reservation')
        if any(x['id'] == r['id'] and x['event'] == 'rejected-before-inference' for x in records()):
            continue
        append({**r, 'event': 'rejected-before-inference', 'charge': 0,
                'reason': 'explicit gateway size rejection, no model response, no inference tokens'})


def revalidate():
    """Reparse saved successful HTTP responses after a parser fix; never send another paid call."""
    for rec in effective_records():
        if rec.get('valid') or rec.get('http') != 200 or rec.get('finish') != 'stop':
            continue
        if not all(isinstance(rec.get('usage', {}).get(k), int) for k in ('prompt_tokens', 'completion_tokens')):
            continue  # unknown usage remains reserved and unaccepted
        hit = cached(rec['request_sha256'])
        if not hit:
            continue
        nums = list(range(rec['span'][0], rec['span'][1] + 1))
        parse(hit['raw'], nums, rec['whole'])
        _, note = normalized(hit['raw'], rec['whole'])
        hit['valid'] = True
        hit['normalization'] = note
        dest = STORE / 'replies' / f'{rec["request_sha256"]}.json'
        tmp = dest.with_suffix('.tmp')
        tmp.write_text(json.dumps(hit, ensure_ascii=False))
        tmp.replace(dest)
        append({**rec, 'event': 'revalidated', 'valid': True, 'error': None, 'normalization': note,
                'reason': 'saved HTTP200/stop reply reparsed; whole JSON fence normalization only; '
                          'no values changed, no new inference or charge'})


def judge(route, whole=False):
    def one(col, a, b, allow_call=False):
        body, key, nums = request(route, col, a, b, whole)
        hit = cached(key)
        return parse(hit['raw'], nums, whole) if hit and hit.get('valid') else None
    return one


def claude_cue(col, a, b, allow_call=False):
    old = C.judge('claude-cue')(col, a, b, allow_call=False)
    return old if old is not None else judge('claude-cue')(col, a, b)


def call(route, col, a, b, whole=False):
    body, key, nums = request(route, col, a, b, whole)
    hit = cached(key)
    if hit is not None:
        if not hit.get('valid'):
            raise RuntimeError(f'{col.name} {nums[0]}-{nums[-1]}: recorded failure; inspect before retry')
        return
    if any(r.get('request_sha256') == key and r['event'] == 'reserve' for r in records()):
        raise RuntimeError('request was already sent without a cached reply; inspect ledger before retry')
    reserve = reservation(route, body)
    if spent() + reserve > CAP:
        raise RuntimeError(f'cap: ${spent():.4f} + ${reserve:.4f} allowance exceeds ${CAP:.2f}')
    rec = {'id': uuid.uuid4().hex, 'event': 'reserve', 'charge': reserve, 'route': route,
           'model': MODELS[route], 'box': col.name, 'span': [nums[0], nums[-1]], 'whole': whole,
           'request_sha256': key, 't': time.time()}
    append(rec)                    # before sending, so a killed process still counts its possible spend
    r = GW.request('/chat/completions', body, timeout=900 if whole else 300)
    got = r.json()                 # an invalid/unknown reply leaves the reservation intact
    usage = got.get('usage') or {}
    pi, po = PRICES[route]
    known = all(isinstance(usage.get(k), int) and usage[k] >= 0 for k in ('prompt_tokens', 'completion_tokens'))
    charge = (usage['prompt_tokens'] * pi + usage['completion_tokens'] * po) / 1e6 if known else reserve
    choice = (got.get('choices') or [{}])[0]
    raw = (choice.get('message') or {}).get('content') or ''
    valid, error = False, None
    try:
        if r.status_code != 200 or choice.get('finish_reason') != 'stop' or not known:
            raise ValueError(f'HTTP {r.status_code}, finish {choice.get("finish_reason")}, known usage {known}')
        parse(raw, nums, whole)
        valid = True
    except (ValueError, KeyError, TypeError, W.ParseError) as e:
        error = str(e)
    dest = STORE / 'replies' / f'{key}.json'
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix('.tmp')
    tmp.write_text(json.dumps({'valid': valid, 'raw': raw, 'response': got, 'request': rec}, ensure_ascii=False))
    tmp.replace(dest)
    append({**rec, 'event': 'settle', 'charge': charge, 'usage': usage, 'valid': valid,
            'error': error, 'http': r.status_code, 'finish': choice.get('finish_reason'),
            'normalization': normalized(raw, whole)[1] if valid else None,
            'returned_model': got.get('model'), 'wall_s': round(time.time() - rec['t'], 3)})
    print(f'{route:10} {col.name:8} {nums[0]}-{nums[-1]} valid={valid}, item ${spent():.4f}', flush=True)
    if not valid or charge > reserve or spent() > CAP:
        raise RuntimeError(error or 'usage exceeded allowance: stop and inspect')


def public_columns(root):
    import public_segmentation as P
    data.CACHE_DIR = root / 'cache'
    return [P.load(n, root)[0] for n in ('lincoln', 'crest')]


def jobs(root):
    cols = public_columns(root)
    use_cache(root / 'cache')
    result = []
    # Claude holes first; their modest cost is included before the large Gemini whole-stream calls.
    for col in cols:
        for a, b in W.windows(len(col.pages)):
            if C.judge('claude-cue')(col, a, b, allow_call=False) is None:
                result.append(('claude-cue', col, a, b, False))
    use_cache(Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/segbench')
    col = data.load('Deaver', with_exif=False)
    for a, b in W.windows(len(col.pages)):
        if C.judge('claude-cue')(col, a, b, allow_call=False) is None:
            result.append(('claude-cue', col, a, b, False))
    for col in cols:
        for a, b in H.units(col, 'whole'):
            result.append(('gemini', col, a, b, True))
        for route in ('gemini', 'glm'):
            result += [(route, col, a, b, False) for a, b in W.windows(len(col.pages))]
    return result


def use_cache(path):
    data.CACHE_DIR = path
    C.CACHES = {r: data.ResponseCache(f'window-cues-{r}') for r in C.ROUTES}


def job_request(job):
    route, col, a, b, whole = job
    # Collection.text also reads the right OCR cache for each job.
    use_cache(col.directory / 'cache' if col.name in ('Lincoln', 'CREST') else
              Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/segbench')
    return request(route, col, a, b, whole)


def predictors():
    return {'gateway-gemini': lambda col: W.assemble(col, W.combine(col, judge('gemini')), False),
            'gateway-glm': lambda col: W.assemble(col, W.combine(col, judge('glm')), False),
            'gateway-gemini-whole': lambda col: H.assemble(col, H.predict_gaps(col, 'whole', judge('gemini', True)))}


def score(root):
    import rescore
    import seg_lincoln_cloud as S
    import public_segmentation as P
    rescore.no_network()
    out = {'price_note': __doc__.split('The gateway publishes')[1].strip(), 'cost_estimate': spent(),
           'calls': effective_records(), 'boxes': {}}
    staged = []
    for col in public_columns(root):
        use_cache(root / 'cache')
        srcs = {**predictors(), 'window-cues-claude-cue': lambda c: W.assemble(c, W.combine(c, claude_cue), False)}
        rows = S.score_sources(col, srcs, rescore.CATALOGUE_COUNT[col.name])
        if rows['missing']:
            raise ValueError(f'{col.name}: incomplete sources {rows["missing"]}; no scores written')
        out['boxes'][col.name] = rows
        # Reuse the normal public output format and its frozen truth guard, without baseline refitting.
        path = P.MANIFESTS / f'{col.name.lower()}-scores.json'
        previous = json.loads(path.read_text())
        manifest = json.loads((P.MANIFESTS / f'{col.name.lower()}.json').read_text())
        digest = hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()
        if previous['truth_sha256'] != digest or previous['pages'] != len(col.pages):
            raise ValueError('existing public scores disagree with the frozen truth')
        for name, row in rows['sources'].items():
            previous['models'][name] = {'counts': {**row['counts'], 'collections': []}, 'metrics': row['metrics']}
        staged.append((path, previous))
    for path, previous in staged:
        path.write_text(json.dumps(previous, indent=2) + '\n')
    (RESULTS / 'seg-lincoln-gateway.json').write_text(json.dumps(out, indent=1) + '\n')
    lines = ['# Lincoln and CREST through the gateway (W46.seg-lincoln-cloud-paid)', '',
             'Gemini 3.7 Flash (not 3.8), GLM 5.3 Flash, low/minimal reasoning, temperature 0; '
             '1600px images plus cached Vision text. Frozen g1 windows (7 pages, stride 3), wh1 whole streams. '
             'Windows use the model photo labels; whole streams take the known absence of label photos. '
             'Whole images are JPEG quality 45 to fit the gateway 32 MB body limit; windows retain the '
             'original benchmark thumbnails. No page is resized or dropped. No prompt fitted to these answers.', '',
             'Claude c2 combines earlier plan windows with gateway holes, same Sonnet 5.5 and stated cues, '
             'but inline-image delivery replaces tool reads. It is a mixed-transport result.', '',
             f'Item cost estimate ${spent():.4f}, at list token prices; gateway billing is unavailable. '
             'Includes every attempted call and unsettled reservation. Rates: Gemini $0.75/$3.75, '
             'GLM $0.15/$0.50, Claude $2/$10 per million input/output tokens (reasoning included), '
             'OpenRouter model catalog checked 2026-10-24. No batch discount claimed.', '']
    lines += ['The initial uncompressed Lincoln request was rejected before inference (HTTP 413, '
              '32 MB body limit, zero token cost); its reservation was released with an append-only '
              'ledger correction. Both whole-stream calls use JPEG quality 45, so their comparison '
              'with windows also changes JPEG encoding and cannot isolate context length alone.', '',
              '| box | route | whole | attempts | valid | input tokens | output tokens | cost estimate | mean seconds |',
              '|---|---|---|---:|---:|---:|---:|---:|---:|']
    for box, route, whole in sorted({(r['box'], r['route'], r['whole']) for r in out['calls']}):
        cs = [r for r in out['calls'] if (r['box'], r['route'], r['whole']) == (box, route, whole)]
        tin = sum(r.get('usage', {}).get('prompt_tokens', 0) for r in cs)
        tout = sum(r.get('usage', {}).get('completion_tokens', 0) for r in cs)
        lines.append(f'| {box} | {route} | {whole} | {len(cs)} | {sum(bool(r.get("valid")) for r in cs)} | '
                     f'{tin} | {tout} | ${sum(r["charge"] for r in cs):.4f} | '
                     f'{sum(r.get("wall_s", 0) for r in cs) / len(cs):.1f} |')
    lines.append('')
    for box, rows in out['boxes'].items():
        lines += S.public_table(box, rows)
    (RESULTS / 'seg-lincoln-gateway.md').write_text('\n'.join(lines) + '\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('command', choices=('inventory', 'collect', 'score', 'reconcile-413', 'revalidate'))
    ap.add_argument('root', type=Path)
    ap.add_argument('--limit', type=int)
    ap.add_argument('--windows-only', action='store_true', help='Defer whole streams while measuring window cost')
    args = ap.parse_args()
    if args.command in ('reconcile-413', 'revalidate'):
        STORE.mkdir(parents=True, exist_ok=True)
        with (STORE / 'collect.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            (reconcile_413 if args.command == 'reconcile-413' else revalidate)()
        return
    if args.command == 'score':
        score(args.root)
        return
    use_cache(args.root / 'cache')
    todo = jobs(args.root)
    pending = []
    for job in todo:
        if args.windows_only and job[4]:
            continue
        body, key, nums = job_request(job)
        hit = cached(key)
        if hit is None or not hit.get('valid'):
            pending.append(job)
    print(f'{len(todo)} jobs, {len(pending)} uncached, item spent ${spent():.4f}', flush=True)
    if args.command == 'inventory':
        for j in pending:
            print(j[0], j[1].name, j[2:])
        return
    STORE.mkdir(parents=True, exist_ok=True)
    with (STORE / 'collect.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for job in pending[:args.limit]:
            job_request(job)
            call(*job)


if __name__ == '__main__':
    main()
