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
FARMSHARE = {'qwen3.6-27b-farmshare': P.RESULTS / 'farmshare' / 'truth' / 'qwen3.6-27b-1849739' / 'pages.csv'}
MAC = ('qwen3-vl-8b-mlx4', 'lightonocr-3-4b-mlx8', 'qwen3.5-9b-mlx4')
# The cheap readers whose texts are compared pairwise: free, or $1 or less per 1,000 pages on the bench.
CHEAP = ('apple-vision', *MAC, 'qwen3.5-9b', 'mistral-small-24b', 'gemma4-31b', 'gemma4-26b-a4b', 'qwen3.6-35b-a3b',
         'qwen3.8-flash', 'qwen3.5-35b-a3b', 'qwen3-vl-30b-a3b')
PAGES_CSV = P.RESULTS / 'ocr-pages.csv'
AGREE_CSV = P.RESULTS / 'ocr-pages-agree.csv'
FIELDS = ['route', 'page', 'kind', 'said_kind', 'vision_kind', 'ok', 'nes', 'cost', 'words', 'hyp_words',
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


def load(f):
    return json.loads(f.read_text()) if f.exists() else {}


def reading(route, job):
    """(parsed-or-None, meta) as the route's own report reads it."""
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
    return got.get('parsed'), got.get('meta') or {}


def main():
    inputs = json.loads(BENCH_INPUTS.read_text())
    routes = [*inputs['routes'], *inputs['own_hardware']['routes']]
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
        if route in FARMSHARE:
            with FARMSHARE[route].open(newline='') as f:
                fs = {r['page']: r for r in csv.DictReader(f)}
        for p in pages:
            job = p + '-original'
            parsed, meta = reading(route, job)
            if route in FARMSHARE:
                r = fs[p]
                row = {'ok': r['ok'] == 'True', 'nes': float(r['nes']), 'cost': 0, 'words': r['words'],
                       'hyp_words': r['hyp_words'], 'completion_tokens': r['completion_tokens'], 'said_kind': '',
                       'finish': r['status']}
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
            if route not in FARMSHARE:
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
