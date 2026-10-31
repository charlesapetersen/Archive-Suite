"""W41.bench-difficulty. Every OCR route's score on every one of the panel's 96 accuracy pages, as public tables.

  uv run --with rapidfuzz --with 'sacrebleu==2.5.1' python ocr_pages_export.py

Reads the panels' private caches (scores.json and the readings behind them) and FarmShare's committed pages.csv,
and writes, in segbench-results/:

  ocr-pages.csv        one row per route and page: the page's kind (truth), the kind the route said, answered or
                       not, NES, the measured cost, truth and reply word counts, output tokens
  ocr-pages-agree.csv  NES between two cheap readers' texts on the same page, for every pair of the cheap readers
                       (free, or $1 or less per 1,000 pages), the disagreement a cascade could see without truth

and, when vision_kind/run.sh has been run into the cache's vision-kind/ (W41.bench-vision-kind), each page's Vision
OCR page kind in ocr-pages.csv's vision_kind column, and farmshare/bulk/vision-kind.csv for the bulk pages: one row
per page, the kind and the signals it was judged by, under the bulk run's own neutral page names.

No text, file names or corpus paths leave the cache: page ids are the panel's private keys. ArchiveOCRBench's
difficulty.py reads these two files; nothing here needs the network or money.
"""
from __future__ import annotations
import csv
import itertools
import json
from pathlib import Path

import ocr_panel as P
import ocr_panel_score as S

CACHES = P.CACHE.parent
LOCAL, CLOUD = CACHES / 'ocr-panel-local', CACHES / 'ocr-panel-cloud'
BENCH_INPUTS = P.RESULTS.parents[1] / 'ArchiveOCRBench' / 'data' / 'inputs.json'
# W46.ocr-rescore-offline: every FarmShare and Sherlock run on the bench's charts (inputs.json's own_hardware routes
# with a run), from its committed pages.csv, and Gemini 3.7 Flash's gateway reading of the 96 (gateway_gemini.py).
FARMSHARE_TRUTH = P.RESULTS / 'farmshare' / 'truth'
GATEWAY_ROUTE, GATEWAY = 'gemini3.7-flash-gw', CACHES / 'gateway-gemini' / 'panel'
MAC = ('qwen3-vl-8b-mlx4', 'lightonocr-3-4b-mlx8', 'qwen3.5-9b-mlx4', 'xiaomi-ocr-0-bf16', 'paddleocr-vl1.6-bf16',
       'granite-docling-258m-mlx')
# The cheap readers whose texts are compared pairwise: free, or $1 or less per 1,000 pages on the bench.
CHEAP = ('apple-vision', *MAC, 'qwen3.5-9b', 'mistral-small-24b', 'gemma4-31b', 'gemma4-26b-a4b', 'qwen3.6-35b-a3b',
         'qwen3.8-flash', 'qwen3.5-35b-a3b', 'qwen3-vl-30b-a3b')
PAGES_CSV = P.RESULTS / 'ocr-pages.csv'
AGREE_CSV = P.RESULTS / 'ocr-pages-agree.csv'
FIELDS = ['route', 'page', 'kind', 'said_kind', 'vision_kind', 'ok', 'failure', 'nes', 'cost', 'words', 'hyp_words',
          'completion_tokens', 'finish']
# W41.bench-vision-kind: vision_kind/run.sh's output for the panel's originals and the bulk pilot's 2,000 pages.
VISION_KIND = CACHES / 'vision-kind'
BULK_KIND_CSV = P.RESULTS / 'farmshare' / 'bulk' / 'vision-kind.csv'
BULK_KIND_FIELDS = ['page', 'vision_kind', 'paste_up', 'photo', 'camera', 'hand', 'lines', 'wide_w']


def vision_kinds(*names):
    """page -> the row vision-page-kind printed for it, from the named TSVs in the cache; unread pages are left out."""
    out = {}
    for n in names:
        f = VISION_KIND / n
        if f.exists():
            with f.open(newline='') as fh:
                out.update({r['id']: r for r in csv.DictReader(fh, delimiter='\t') if r['vision_kind'] != 'unread'})
    return out


# What a provider's own error text says, for a page whose finish reason is just "error" (the raw response beside it)
REFUSED = ('RECITATION', 'DataInspectionFailed', 'inappropriate content')   # Gemini's reprinted text; Alibaba's filter
LOOPED = ('repeating the same chunk',)                                         # the provider cut a loop off


def failure(ok, finish, completion_tokens, meta=None) -> str:
    """Why a page has no reading (the measurement audit's OCR-2). transport: the provider or the connection lost the
    request, so the model never finished an answer (a 5xx, an interrupted stream, no finish reason, or an error the
    provider's text does not put on the model). The model's own: cap (it ran to the token cap, or the provider cut
    off a loop), refusal (a content filter: Gemini's RECITATION on reprinted text, Alibaba's output inspection) and
    empty (it stopped but left nothing usable). An "error" finish is classified from the provider's error text,
    which must be on disk."""
    if ok:
        return ''
    if finish in ('length', 'cap'):
        return 'cap'
    if finish == 'content_filter':
        return 'refusal'
    if finish in ('stop', 'unparsable', 'unparsed'):
        return 'empty'
    if finish == 'error':
        text = (meta or {}).get('error_text')
        if text is None:
            raise SystemExit(f'an "error" finish with no provider error text on disk ({completion_tokens} tokens)')
        if any(k in text for k in REFUSED):
            return 'refusal'
        if any(k in text for k in LOOPED):
            return 'cap'
        return 'transport'
    if finish in ('provider-error', 'interrupted', '', None, 'None') or (meta or {}).get('error_code'):
        return 'transport'
    raise SystemExit(f'unclassified failure: finish {finish!r}, {completion_tokens} tokens')


def farmshare_failure(r: dict, summary: dict) -> str:
    """A cluster run's failed page: its outcome (cap, unparsable) or status (cap, unparsed). A run that recorded
    neither (CHURRO's first run) counted only caps as failures, as its summary's note says."""
    why = next((r.get(k) for k in ('outcome', 'status') if r.get(k) not in (None, '', 'ok')), None)
    if why is None and 'caps count as failures' in summary.get('env', {}).get('note', ''):
        why = 'cap'
    return failure(r['ok'] == 'True', why or 'unrecorded', None)


def load(f):
    return json.loads(f.read_text()) if f.exists() else {}


def reading(route, job):
    """(parsed-or-None, meta) as the route's own report reads it."""
    if route == GATEWAY_ROUTE:
        import gateway_gemini as G
        got = load(GATEWAY / (job + '.json'))
        return G.parsed(got), got.get('meta') or {}
    if route == 'apple-vision':
        f = LOCAL / 'vision' / (job + '.txt')
        return ({'text': f.read_text(), 'kind': None} if f.exists() else None), {}
    if route in MAC:
        got = load(LOCAL / 'local' / route / (job + '.json'))
    elif route == 'mistral-ocr-4-1':
        text = load(CLOUD / 'mistral' / (job + '.json')).get('text') or ''
        return ({'text': text, 'kind': None} if text else None), {}
    elif route == 'claude-sonnet5.5':
        got = load(CLOUD / 'sub' / route / (job + '.json'))
    else:
        got = load(LOCAL / 'responses' / route / (job + '.json')) or load(CLOUD / 'responses' / route / (job + '.json'))
        raw = [d / 'responses' / route / (job + '.raw.json') for d in (LOCAL, CLOUD)]
        raw = next((f for f in raw if f.exists()), None)
        if raw is not None and not got.get('parsed'):   # the provider's error text, for failure()
            return None, {**(got.get('meta') or {}), 'error_text': raw.read_text()}
    return got.get('parsed'), got.get('meta') or {}


def main():
    inputs = json.loads(BENCH_INPUTS.read_text())
    routes = [*inputs['routes'], *inputs['own_hardware']['routes']]
    farmshare = {rid: FARMSHARE_TRUTH / spec['run'] / 'pages.csv' for rid, spec in inputs['own_hardware']['routes'].items()
                 if spec['where'] == 'farmshare'}
    truth_kind = {r['page']: r['kind'] for r in P.rows()}
    pages = sorted(p for p in truth_kind if p not in P.AGREEMENT)
    truth = {p: (P.TRUTH / 'truth' / (p + '.txt')).read_text() for p in pages}
    panel = {}
    for cache in (LOCAL, CLOUD):
        for r in json.loads((cache / 'scores.json').read_text()):
            if r['scale'] == 'original':
                panel[(r['key'], r['page'])] = r

    vk = vision_kinds('panel.tsv')
    rows, texts = [], {}
    for route in routes:
        if route in farmshare:
            with farmshare[route].open(newline='') as f:
                fs = {r['page']: r for r in csv.DictReader(f)}
            summary = load(farmshare[route].with_name('summary.json'))
        for p in pages:
            job = p + '-original'
            parsed, meta = reading(route, job)
            if route in farmshare:
                r = fs[p]
                # finish is the decoder's where the run kept one, else the harness's status (ok, cap, unparsed)
                row = {'ok': r['ok'] == 'True', 'nes': float(r['nes']), 'cost': 0, 'words': r['words'],
                       'hyp_words': r.get('hyp_words', ''), 'completion_tokens': r.get('completion_tokens', ''),
                       'said_kind': '', 'finish': r.get('finish') or r.get('status') or ''}
                row['failure'] = farmshare_failure(r, summary)
            elif route == GATEWAY_ROUTE:
                s = S.score(truth[p], parsed['text'] if parsed else '')
                row = {**s, 'ok': bool(parsed), 'cost': meta.get('cost', 0),
                       'completion_tokens': (meta.get('usage') or {}).get('completion_tokens'),
                       'finish': meta.get('finish', '')}
            elif route in MAC:
                s = S.score(truth[p], parsed['text'] if parsed else '')
                row = {**s, 'ok': bool(parsed), 'cost': 0, 'completion_tokens': meta.get('completion_tokens'),
                       'finish': meta.get('finish', '')}
            else:
                r = panel[(route, p)]
                row = {k: r[k] for k in ('ok', 'nes', 'cost', 'words', 'hyp_words', 'completion_tokens')}
                row['finish'] = meta.get('finish_reason') or meta.get('finish') or ''
                if bool(parsed) != bool(row['ok']):
                    raise SystemExit(f'{route} {p}: scores.json and the reading disagree on whether it answered')
            if route not in farmshare:
                row['failure'] = failure(row['ok'], row['finish'], row['completion_tokens'], meta)
                row['said_kind'] = (parsed or {}).get('kind') or ''
            rows.append({'route': route, 'page': p, 'kind': truth_kind[p],
                         'vision_kind': vk.get(p, {}).get('vision_kind', ''), **row,
                         'nes': round(float(row['nes']), 6)})
            if route in CHEAP and parsed:
                texts[(route, p)] = parsed['text']
    S.write_csv(PAGES_CSV, rows, FIELDS)

    agree = []
    for a, b in itertools.combinations(CHEAP, 2):
        for p in pages:
            if (a, p) in texts and (b, p) in texts:
                agree.append({'a': a, 'b': b, 'page': p, 'nes': round(S.score(texts[(a, p)], texts[(b, p)])['nes'], 4)})
    S.write_csv(AGREE_CSV, agree, ['a', 'b', 'page', 'nes'])
    bulk = vision_kinds(*(f'bulk-{i}.tsv' for i in range(4)))
    if bulk:
        S.write_csv(BULK_KIND_CSV, [{'page': p, **{k: bulk[p][k] for k in BULK_KIND_FIELDS[1:]}} for p in sorted(bulk)],
                    BULK_KIND_FIELDS)
    print(f'{PAGES_CSV.name}: {len(rows)} rows ({len(routes)} routes x {len(pages)} pages, '
          f'{sum(p in vk for p in pages)} with a Vision kind); {AGREE_CSV.name}: {len(agree)} pairs of readings; '
          f'{BULK_KIND_CSV.name}: {len(bulk)} bulk pages')


if __name__ == '__main__':
    main()
