"""W46.seg-lincoln-cloud-paid: frozen prompts/inputs, gateway only, one $3 item ledger.

  <lab python> seg_lincoln_gateway.py inventory|collect|score PUBLIC_ROOT

Public windows: Gemini 3.7 Flash and GLM 5.3 Flash, g1, 1600px, 7 pages/stride 3.
Whole folders: Gemini, wh1, ONE uninterrupted stream per public box (no truth document cuts).
Claude c2: only holes in the pre-existing plan cache, on CREST and Deaver. The gateway
uses inline images rather than tool reads, and its cache and provenance remain separate.
No subscription calls, personal keys, corpus writes, or automatic retries. Failed replies
are never neutral votes. One exact-hash audited whole reply has only two missing array
brackets restored, without changing any values; raw bytes and the repair remain recorded.
Scoring cannot make calls.

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
# Audited saved Lincoln reply: exactly two omitted '[' delimiters; no value is supplied/changed.
# Scope the normalization to these exact bytes, never to an unseen model response.
AUDITED_WHOLE_SHA = '39c6a2d43022cc70b97e4b414bd3bc516f16c55fbe7839f64b7be28ef9a3bb72'
AUDITED_PAIRS = [[82, 83], [122, 123]]


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
    # Pilot whole output used ~41 tokens/gap, with no reasoning tokens reported. Freeze
    # 64/gap, at least 8192, before the JSON-mode whole calls; no need for 32768 on CREST.
    # GLM exhausted both 8192 and 16384 on reasoning-only replies. Keep completed
    # low replies, but give unfinished windows one final fixed 32768 ceiling.
    output_cap = max(8192, 64 * (len(nums) - 1)) if whole else 32768 if route == 'glm' else 4096
    body = {'model': MODELS[route], 'temperature': 0, 'max_tokens': output_cap,
            'messages': [{'role': 'user', 'content': parts}]}
    if route != 'claude-cue':
        body['response_format'] = {'type': 'json_object'}
        # GLM-5.3's native documented minimum is low, not minimal (docs.z.ai, 2026-10-24).
        body['reasoning_effort'] = 'low'
    if len(json.dumps(body).encode()) > 32_000_000:
        raise ValueError('body exceeds the gateway 32 MB limit; no call sent')
    key = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
    return body, key, nums


def normalized(raw, whole):
    # Gemini can wrap an otherwise complete JSON reply even when asked for no fence.
    # Strip only a single surrounding fence; H still requires every gap exactly once.
    text = raw.strip()
    note = {'parser': 'gw3', 'fence': False, 'audited_array_open': []}
    if whole and (m := re.fullmatch(r'```(?:json)?\s*\n(.*?)\n```', text, re.S)):
        text = m[1]
        note['fence'] = True
    if whole and hashlib.sha256(raw.encode()).hexdigest() == AUDITED_WHOLE_SHA:
        pattern = r'"between":\s*(\d+),\s*(\d+)\]'
        pairs = [list(map(int, m)) for m in re.findall(pattern, text)]
        if pairs != AUDITED_PAIRS:
            raise W.ParseError('audited syntax offsets changed')
        text = re.sub(pattern, r'"between": [\1, \2]', text)
        note['audited_array_open'] = pairs
    return text, note


def parse(raw, nums, whole):
    text, _ = normalized(raw, whole)
    return H.parse_answer(text, nums) if whole else W.parse_answer(text, nums)


def reservation(route, body, input_bound=None):
    # Input allowance: one token per UTF-8 text byte + image allowance + message overhead,
    # bounded by the published 1M context. Gemini's pilot (including all 261 whole images)
    # bills 1066-1098/image at 1600px (whole ~1084): allow 2048/image (>1.86x).
    # Other models keep 8192.
    # This is a conservative estimate, not a gateway billing guarantee. Every call also
    # reserves the full output-token cap and stops if actual usage exceeds its allowance.
    parts = body['messages'][0]['content']
    text = sum(len(p['text'].encode()) for p in parts if p['type'] == 'text')
    images = sum(p['type'] == 'image_url' for p in parts)
    image_allowance = 2048 if route == 'gemini' else 8192
    tokens = min(1_048_576, text + image_allowance * images + 2048)
    if input_bound is not None:
        tokens = min(tokens, input_bound)
    pi, po = PRICES[route]
    return (tokens * pi + body['max_tokens'] * po) / 1e6


def covering_window_bound(col):
    """Whole-input allowance from measured Gemini windows covering every page.

    These repeat full g1 instructions and overlap images/text; wh1 removes label-photo
    instructions. Both use the same OCR truncation and 1600px images. Summing the covering
    requests overcounted the measured Lincoln pilot (460333 vs 335266 tokens).
    This is an empirical allowance, not a tokenizer guarantee; add 10% margin and
    reserve the full output cap. Actual usage above the allowance stops collection.
    Only use this after complete successful cached windows, on a long (>14-page) stream.
    """
    if len(col.pages) <= 2 * W.WINDOW:
        return None
    covered, tokens, refs = 0, 0, []
    windows = W.windows(len(col.pages))
    while covered < len(col.pages):
        a, b = max((w for w in windows if w[0] <= covered < w[1]), key=lambda w: w[1])
        body, key, _ = request('gemini', col, a, b)
        hit = cache_hit(body, key)
        if not hit or not hit.get('valid'):
            return None
        n = hit.get('response', {}).get('usage', {}).get('prompt_tokens')
        if not isinstance(n, int) or n <= 0:
            return None
        tokens += n
        refs.append(hit['request']['id'])
        covered = b
    return {'tokens': (tokens * 11 + 9) // 10, 'measured_covering_tokens': tokens,
            'margin': 1.1, 'covering_request_ids': refs}


def cached(key):
    p = STORE / 'replies' / f'{key}.json'
    return json.loads(p.read_text()) if p.exists() else None


def cache_hit(body, key):
    hit = cached(key)
    if hit is None and body.get('model') == MODELS['glm'] and body.get('max_tokens') == 32768:
        # A completed stop answer at the old cap has the identical input/settings.
        # Never reuse the earlier minimal-effort pilot or a truncated low reply.
        for cap in (16384, 8192):
            old_body = {**body, 'max_tokens': cap}
            old_key = hashlib.sha256(json.dumps(old_body, sort_keys=True).encode()).hexdigest()
            old = cached(old_key)
            if old and old.get('valid'):
                hit = old
                break
    if hit is None and body.get('response_format') == {'type': 'json_object'}:
        # The earlier unconstrained-output pilot has identical model, images and prompt.
        # Keep its valid responses; failed replies remain charged and are never silently used.
        old_body = {k: v for k, v in body.items() if k != 'response_format'}
        candidates = [old_body]
        if body['max_tokens'] > 8192:  # whole pilot used the larger cap, with otherwise identical input/settings
            candidates.append({**old_body, 'max_tokens': 32768})
        for candidate in candidates:
            old_key = hashlib.sha256(json.dumps(candidate, sort_keys=True).encode()).hexdigest()
            old = cached(old_key)
            if old and old.get('valid'):
                hit = old
                break
    return hit


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
        if not rec.get('whole') or rec.get('valid') or rec.get('http') != 200 or rec.get('finish') != 'stop':
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
                'reason': 'saved HTTP200/stop reply reparsed; audited two-array delimiter normalization; '
                          'no values changed, no new inference or charge'})


def retry_unsettled_once():
    """Explicit single retry after a transport failure; keep the entire original allowance charged."""
    rows = records()
    for rec in effective_records():
        if rec['event'] not in ('reserve', 'unknown'):
            continue
        key = rec['request_sha256']
        if cached(key) is not None:
            continue
        attempts = sum(r['event'] == 'reserve' and r.get('request_sha256') == key for r in rows)
        if attempts != 1:
            raise RuntimeError('already retried this unknown request once; no further retry')
        timeout = 900 if rec['whole'] else 300
        if time.time() - rec['t'] < timeout + 5:
            raise RuntimeError('request timeout has not elapsed; do not overlap inference')
        append({**rec, 'event': 'retry-approved',
                'reason': 'one explicit retry after transport ended without usage; original allowance retained'})


def judge(route, whole=False):
    def one(col, a, b, allow_call=False):
        body, key, nums = request(route, col, a, b, whole)
        hit = cache_hit(body, key)
        return parse(hit['raw'], nums, whole) if hit and hit.get('valid') else None
    return one


def retry_incomplete(key):
    """Explicit one-time retry of a billed, stopped GLM reply missing required gaps.

    Archive the failed bytes before freeing the exact cache key. Its full charge stays
    in the ledger; call() still reserves the next attempt and enforces the item cap.
    This does not repair a decision, retry a cap/transport error, or permit a third send.
    """
    rows = records()
    attempts = [r for r in rows if r.get('request_sha256') == key and r['event'] == 'reserve']
    recs = [r for r in effective_records() if r.get('request_sha256') == key]
    if len(attempts) != 1 or len(recs) != 1:
        raise RuntimeError('incomplete retry requires exactly one prior send')
    rec = recs[0]
    if not (rec['event'] == 'settle' and rec.get('http') == 200 and rec.get('finish') == 'stop'
            and rec.get('route') == 'glm' and not rec.get('whole') and not rec.get('valid')
            and str(rec.get('error', '')).startswith('boundaries for ')
            and all(isinstance(rec.get('usage', {}).get(k), int) and rec['usage'][k] >= 0
                    for k in ('prompt_tokens', 'completion_tokens'))):
        raise RuntimeError('only a billed, stopped GLM reply missing gaps qualifies')
    src = STORE / 'replies' / f'{key}.json'
    archive = STORE / 'failed-replies' / f'{rec["id"]}.json'
    hit = json.loads((src if src.exists() else archive).read_text())
    if hit.get('valid') or hit['request']['id'] != rec['id']:
        raise RuntimeError('failed reply provenance disagrees with ledger')
    archive.parent.mkdir(parents=True, exist_ok=True)
    if src.exists():
        if archive.exists():
            raise RuntimeError('archive already exists; inspect without replacing it')
        src.rename(archive)
    append({**rec, 'event': 'retry-approved', 'failure_archive': str(archive.relative_to(STORE)),
            'reason': 'one explicit same-settings retry of missing gaps; failed raw and charge retained'})


def claude_cue(col, a, b, allow_call=False):
    old = C.judge('claude-cue')(col, a, b, allow_call=False)
    return old if old is not None else judge('claude-cue')(col, a, b)


def call(route, col, a, b, whole=False):
    body, key, nums = request(route, col, a, b, whole)
    hit = cache_hit(body, key)
    if hit is not None:
        if not hit.get('valid'):
            raise RuntimeError(f'{col.name} {nums[0]}-{nums[-1]}: recorded failure; inspect before retry')
        return
    rows = records()
    attempts = sum(r.get('request_sha256') == key and r['event'] == 'reserve' for r in rows)
    retry = attempts == 1 and any(r.get('request_sha256') == key and r['event'] == 'retry-approved'
                                  for r in effective_records())
    if attempts and not retry:
        raise RuntimeError('request was already sent without a cached reply; inspect ledger before retry')
    bound = covering_window_bound(col) if whole and route == 'gemini' else None
    reserve = reservation(route, body, bound['tokens'] if bound else None)
    if spent() + reserve > CAP:
        raise RuntimeError(f'cap: ${spent():.4f} + ${reserve:.4f} allowance exceeds ${CAP:.2f}')
    rec = {'id': uuid.uuid4().hex, 'event': 'reserve', 'charge': reserve, 'route': route,
           'model': MODELS[route], 'box': col.name, 'span': [nums[0], nums[-1]], 'whole': whole,
           'settings': {'max_tokens': body['max_tokens'], 'reasoning_effort': body.get('reasoning_effort'),
                        'response_format': body.get('response_format'), 'whole_jpeg_quality': 45 if whole else None},
           'input_bound': bound,
           'request_sha256': key, 't': time.time()}
    append(rec)                    # before sending, so a killed process still counts its possible spend
    r = None
    try:
        r = GW.request('/chat/completions', body, timeout=900 if whole else 300)
        got = r.json()
    except Exception as e:
        append({**rec, 'event': 'unknown', 'http': r.status_code if r is not None else None,
                'error': type(e).__name__, 'wall_s': round(time.time() - rec['t'], 3)})
        raise RuntimeError('transport ended without decodable usage; full allowance retained') from e
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


def used_request_ids(root, claude_only):
    ids = set()
    for job in jobs(root):
        if claude_only and job[0] != 'claude-cue':
            continue
        body, key, _ = job_request(job)
        hit = cache_hit(body, key)
        if hit and hit.get('valid'):
            ids.add(hit['request']['id'])
    return ids


def score(root, claude_only=False):
    import rescore
    import seg_lincoln_cloud as S
    import public_segmentation as P
    rescore.no_network()
    used = used_request_ids(root, claude_only)
    out = {'price_note': __doc__.split('The gateway publishes')[1].strip(), 'cost_estimate': spent(),
           'partial': claude_only,
           'calls': [{**r, 'used': r['id'] in used} for r in effective_records()
                     if not claude_only or r['route'] == 'claude-cue'], 'boxes': {}}
    staged = []
    for col in public_columns(root):
        use_cache(root / 'cache')
        srcs = {**({} if claude_only else predictors()),
                'window-cues-claude-cue': lambda c: W.assemble(c, W.combine(c, claude_cue), False)}
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
             'PARTIAL CHECKPOINT: Claude cue arm only; Gemini/GLM collection continues.' if claude_only else
             'All assigned arms collected; earlier failed attempts remain in the price/attempt totals.', '',
             'Gemini 3.7 Flash (not 3.8), GLM 5.3 Flash, low reasoning, temperature 0; '
             '1600px images plus cached Vision text. Frozen g1 windows (7 pages, stride 3), wh1 whole streams. '
             'Windows use the model photo labels; whole streams take the known absence of label photos. '
             'Whole images are JPEG quality 45 to fit the gateway 32 MB body limit; windows retain the '
             'original benchmark thumbnails. No page is resized or dropped. No prompt fitted to these answers.', '',
             'GLM uses the documented native minimum, `reasoning_effort=low`, with a final 32768-token cap '
             '(completed low/8192 and low/16384 replies are reused; all caps include reasoning). '
             'Reasoning-only failures at 8192 and 16384 remain charged and unscored. '
             'Earlier `minimal` probes (including a reasoning-only capped reply) are included in item cost, '
             'but none enters the low-setting predictions. Source: '
             '[Z.ai thinking parameters](https://docs.z.ai/guides/capabilities/thinking), checked 2026-10-24. '
             'Gemini whole JSON-mode caps are 64 tokens/gap, minimum 8192, based on the pilot\'s ~41/gap; '
             'the saved Lincoln pilot had a 32768 cap.', '',
             'Claude c2 combines earlier plan windows with gateway holes, same Sonnet 5.5 and stated cues, '
             'but inline-image delivery replaces tool reads. It is a mixed-transport result.', '',
             f'Item cost estimate ${spent():.4f}, at list token prices; gateway billing is unavailable. '
             'Includes every attempted call and unsettled reservation. Rates: Gemini $0.75/$3.75, '
             'GLM $0.15/$0.50, Claude $2/$10 per million input/output tokens (reasoning included), '
             'OpenRouter model catalog checked 2026-10-24. No batch discount claimed.', '']
    lines += ['The initial uncompressed Lincoln request was rejected before inference (HTTP 413, '
              '32 MB body limit, zero token cost); its reservation was released with an append-only '
              'ledger correction. Both whole-stream calls use JPEG quality 45, so their comparison '
              'with windows also changes JPEG encoding and photo assumptions, and cannot isolate context length alone. '
              'Lincoln\'s saved whole reply required exactly two opening array brackets restored at gaps 82/83 and '
              '122/123. This repair is restricted to its SHA-256, keeps all 260 stated decisions/confidences '
              'unchanged, and passes the complete strict gap validator; it was not a raw-valid JSON reply.', '',
              '| box | route | whole | attempts | usable replies | used replies | input tokens | output tokens | cost estimate | mean seconds |',
              '|---|---|---|---:|---:|---:|---:|---:|---:|---:|']
    for box, route, whole in sorted({(r['box'], r['route'], r['whole']) for r in out['calls']}):
        cs = [r for r in out['calls'] if (r['box'], r['route'], r['whole']) == (box, route, whole)]
        tin = sum(r.get('usage', {}).get('prompt_tokens', 0) for r in cs)
        tout = sum(r.get('usage', {}).get('completion_tokens', 0) for r in cs)
        lines.append(f'| {box} | {route} | {whole} | {len(cs)} | {sum(bool(r.get("valid")) for r in cs)} | '
                     f'{sum(r["used"] for r in cs)} | {tin} | {tout} | ${sum(r["charge"] for r in cs):.4f} | '
                     f'{sum(r["wall_s"] for r in cs if "wall_s" in r) / max(1, sum("wall_s" in r for r in cs)):.1f} |')
    lines.append('')
    if not claude_only:
        L, C = (out['boxes'][b]['sources'] for b in ('Lincoln', 'CREST'))
        exact = lambda rows, key: 100 * rows[key]['metrics']['pages_in_exact_doc']
        lines += ['## Findings', '',
                  f"On Lincoln, Gemini windows put {exact(L, 'gateway-gemini'):.1f}% of pages in the exact "
                  f"document and the repaired whole reply {exact(L, 'gateway-gemini-whole'):.1f}%; "
                  f"GLM windows {exact(L, 'gateway-glm'):.1f}%. The existing open models were at "
                  '34.9–46.7%, while Claude c1 and c2 were 90.0%. The large open-model drop is not '
                  'a ceiling imposed by the material. Small differences among cloud results on one '
                  'agent-audited box do not establish a general ranking.', '',
                  f"On CREST, Gemini windows score {exact(C, 'gateway-gemini'):.1f}% and the whole reply "
                  f"{exact(C, 'gateway-gemini-whole'):.1f}%; GLM windows {exact(C, 'gateway-glm'):.1f}%. "
                  'The existing trained 4B is 98.4%, teacher 95.3%, and Claude c1/c2 84.4%. '
                  'The whole-stream arm scores higher here, but changed JPEG encoding and photo assumptions '
                  'mean this run does not isolate context length.', '',
                  'The table below reports least-confidence-first checking against the truth. '
                  'High boundary agreement or PQ does not mean those confidence values rank the few '
                  'errors well; check the review load separately. The finding-aid count is a measured '
                  'variant, not a setting selected on these public answers.', '',
                  'The final 11 Claude c2 gateway holes leave CREST at 84.4% and Deaver at 97.9%. '
                  'The cue cuts CREST checking from 3.9 to 2.3 per 100 pages, but raises Deaver from '
                  '10.7 to 14.8, with unchanged error counts. See seg-lincoln-cloud.md for all owner '
                  'boxes and the original plan comparisons.', '']
    for box, rows in out['boxes'].items():
        lines += S.public_table(box, rows)
    (RESULTS / 'seg-lincoln-gateway.md').write_text('\n'.join(lines) + '\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('command', choices=('inventory', 'collect', 'score', 'reconcile-413', 'revalidate', 'retry-unsettled', 'retry-incomplete'))
    ap.add_argument('root', type=Path)
    ap.add_argument('--limit', type=int)
    ap.add_argument('--request-sha', help='Exact failed request for retry-incomplete')
    ap.add_argument('--windows-only', action='store_true', help='Defer whole streams while measuring window cost')
    ap.add_argument('--route', choices=MODELS, help='Collect/inventory only this route')
    ap.add_argument('--box', choices=('Lincoln', 'CREST', 'Deaver'), help='Collect/inventory only this box')
    ap.add_argument('--claude-only', action='store_true', help='Score the completed cue arm as a partial checkpoint')
    args = ap.parse_args()
    if args.command == 'retry-incomplete' and not args.request_sha:
        ap.error('retry-incomplete requires --request-sha')
    if args.command in ('reconcile-413', 'revalidate', 'retry-unsettled', 'retry-incomplete'):
        STORE.mkdir(parents=True, exist_ok=True)
        with (STORE / 'collect.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            {'reconcile-413': reconcile_413, 'revalidate': revalidate,
             'retry-unsettled': retry_unsettled_once,
             'retry-incomplete': lambda: retry_incomplete(args.request_sha)}[args.command]()
        return
    if args.command == 'score':
        score(args.root, args.claude_only)
        return
    use_cache(args.root / 'cache')
    todo = jobs(args.root)
    pending = []
    for job in todo:
        if (args.route and job[0] != args.route) or (args.box and job[1].name != args.box):
            continue
        if args.windows_only and job[4]:
            continue
        body, key, nums = job_request(job)
        hit = cache_hit(body, key)
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
