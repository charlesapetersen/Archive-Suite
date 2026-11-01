"""W46.place-geom's report: segbench-results/place-geom.md and .json from place_geom.py's rows (counts and page ids).

Intervals are paired over pages: 2,000 bootstrap draws of the pages, each arm's pass rate (lines passed over lines
scored, summed over the drawn pages) less raw-lab's on the same draw; 95% percentile interval. A difference whose
interval holds 0 is a tie.
"""
from __future__ import annotations

import csv
import json
import random
from pathlib import Path

HERE = Path(__file__).resolve().parent
VARIANTS = [('raw', 'lab'), ('deskew', 'lab'), ('quad', 'lab'), ('uvdoc', 'lab'),
            ('raw', 'level'), ('raw', 'slope'), ('deskew', 'slope'), ('quad', 'slope'), ('uvdoc', 'slope')]
BASE = ('raw', 'lab')
LABEL = {('raw', 'lab'): 'raw, lab writer (today)', ('deskew', 'lab'): 'deskew, lab writer',
         ('quad', 'lab'): 'quad, lab writer', ('uvdoc', 'lab'): 'UVDoc, lab writer',
         ('raw', 'level'): 'raw, level runs (control)', ('raw', 'slope'): 'raw, sloped runs',
         ('deskew', 'slope'): 'deskew, sloped runs', ('quad', 'slope'): 'quad, sloped runs',
         ('uvdoc', 'slope'): 'UVDoc, sloped runs'}
SKEW, SPREAD = 1.0, 1.0           # degrees: |page angle|, and the perspective fit's angle range across the page
DRAWS, SEED = 2000, 20261101


def load(rows_path: Path):
    pages = [json.loads(x) for x in rows_path.read_text().splitlines() if x.strip()]
    bend, source = {}, {}
    with (HERE.parents[1] / 'segbench-results/enh-dewarp-pages.csv').open() as f:
        for r in csv.DictReader(f):
            if r['arm'] == 'raw':
                bend[r['page']] = float(r['uvdoc_bend']) if r['uvdoc_bend'] else None
                source[r['page']] = r['source']
    for p in pages:
        m = p['meta']
        m['bend'], m['source'] = bend.get(m['page']), source.get(m['page'])
    return pages


def strata(pages):
    bends = sorted(p['meta']['bend'] for p in pages if p['meta']['bend'] is not None)
    med = bends[len(bends) // 2] if bends else 0
    S = {
        'every page': lambda m: True,
        'typed': lambda m: m['group'] == 'owner-typed',
        'hand': lambda m: m['group'] == 'owner-hand',
        f'skewed (|angle| ≥ {SKEW:g}°)': lambda m: abs(m['angle']) >= SKEW,
        f'level (|angle| < {SKEW:g}°)': lambda m: abs(m['angle']) < SKEW,
        f'perspective (angle range ≥ {SPREAD:g}°)': lambda m: (m['spread'] or 0) >= SPREAD,
        f'curled (UVDoc bend ≥ median {med:.1f} px)': lambda m: m['bend'] is not None and m['bend'] >= med,
        'originals': lambda m: m['source'] == 'original',
        'PDF images': lambda m: m['source'] != 'original',
    }
    return S, med


def table(pages):
    by = {}
    for p in pages:
        for r in p['rows']:
            by.setdefault((r['arm'], r['writer']), {})[r['page']] = r
    return by


def rate(by, v, ids):
    n = sum(by[v][i]['lines'] for i in ids)
    k = sum(by[v][i]['passed'] for i in ids)
    return k, n


def paired(by, v, ids, rng):
    if v == BASE or not ids:
        return None
    out = []
    for _ in range(DRAWS):
        d = [rng.choice(ids) for _ in ids]
        k, n = rate(by, v, d)
        k0, n0 = rate(by, BASE, d)
        if n and n0:
            out.append(k / n - k0 / n0)
    out.sort()
    return out[int(0.025 * len(out))], out[int(0.975 * len(out)) - 1]


def summarise(pages):
    by = table(pages)
    S, med = strata(pages)
    rng = random.Random(SEED)
    res = {'strata': {}, 'bend_median': med}
    for name, f in S.items():
        ids = [p['meta']['page'] for p in pages if f(p['meta'])]
        rows = []
        for v in VARIANTS:
            k, n = rate(by, v, ids)
            ci = paired(by, v, ids, rng)
            k0, n0 = rate(by, BASE, ids)
            rr = [by[v][i] for i in ids]
            rows.append({'arm': v[0], 'writer': v[1], 'pages': len(ids), 'lines': n, 'passed': k,
                         'rate': k / n if n else None,
                         'delta': (k / n - k0 / n0) if n and n0 and v != BASE else None, 'ci': ci,
                         'cut_lines': sum(r['lost_lines'] for r in rr),
                         'broken': sum(r['broken'] for r in rr),
                         'find': sum(r['found'] for r in rr) / max(1, sum(r['find_words'] for r in rr)),
                         'placed': sum(r['placed'] for r in rr) / max(1, sum(r['find_words'] for r in rr)),
                         'find_words': sum(r['find_words'] for r in rr),
                         'lost_own': sum(r['lost_own'] for r in rr), 'lost_neighbour': sum(r['lost_neighbour'] for r in rr),
                         'cut_words': sum(r['cut_words'] for r in rr),
                         'pages_cut': sum(1 for r in rr if r['lost_lines'] or r['lost_own'] or r['lost_neighbour'])})
        res['strata'][name] = rows
    res['fold'] = {k: sum(p['meta']['fold'][k] for p in pages) for k in ('merged', 'split', 'left_out')}
    res['skipped'] = {k: sum(p['meta']['skipped'][k] for p in pages) for k in ('unread', 'shared', 'short', 'sideways')}
    res['truth_lines'] = sum(p['meta']['truth_lines'] for p in pages)
    res['scored_lines'] = sum(p['meta']['scored_lines'] for p in pages)
    res['pages'] = [{k: p['meta'][k] for k in ('page', 'group', 'kind', 'angle', 'spread', 'bend', 'source',
                                               'scored_lines')} for p in pages]
    res['per_page'] = {f'{a}-{w}': {i: [r['passed'], r['lines']] for i, r in by[(a, w)].items()} for a, w in VARIANTS}
    return res


def pct(x):
    return '—' if x is None else f'{100 * x:.1f}'


def dpct(r):
    if r['delta'] is None:
        return '—'
    lo, hi = r['ci']
    return f'{100 * r["delta"]:+.1f} ({100 * lo:+.1f} to {100 * hi:+.1f})'


def write(rows_path: Path, results: Path, prose: str = ''):
    pages = load(rows_path)
    s = summarise(pages)
    cache = rows_path.parent
    st = {k: json.loads((cache / f'selftest-{k}.json').read_text()) for k in ('level', 'sloped')
          if (cache / f'selftest-{k}.json').exists()}
    s['selftest'] = st
    (results / 'place-geom.json').write_text(json.dumps({'item': 'W46.place-geom', **s}, indent=1) + '\n')
    L = []
    for name, rows in s['strata'].items():
        L.append(f'\n### {name} ({rows[0]["pages"]} pages, {rows[0]["lines"]} lines)\n')
        L.append('| arm | line pass % | Δ vs today (95% CI) | lines cut by the image | Find % | Find placed % |')
        L.append('|---|---:|---|---:|---:|---:|')
        for r in rows:
            L.append(f'| {LABEL[(r["arm"], r["writer"])]} | {pct(r["rate"])} ({r["passed"]}/{r["lines"]}) | '
                     f'{dpct(r)} | {r["cut_lines"]} | {pct(r["find"])} | {pct(r["placed"])} |')
    every = s['strata']['every page']
    E = ['\n| arm | pages cut | truth words lost, own sheet | lost, neighbour text | words partly cut |',
         '|---|---:|---:|---:|---:|']
    for r in every:
        if r['writer'] == 'lab':
            E.append(f'| {r["arm"]} | {r["pages_cut"]} | {r["lost_own"]} | {r["lost_neighbour"]} | {r["cut_words"]} |')
    selftest = ''
    for k, v in st.items():
        a, b = v.get('0.0 all', {}), v.get('0.02 all', {})
        selftest += (f'- {k} oracle runs: {pct(a.get("rate"))}% of {a.get("n")} lines pass in place; '
                     f'{pct(b.get("rate"))}% with the layer moved down 0.02 of the page.\n')
    body = (results / 'place-geom.md').read_text() if (results / 'place-geom.md').exists() else ''
    head = body.split('<!-- tables -->')[0] if '<!-- tables -->' in body else prose
    tail = body.split('<!-- /tables -->')[1] if '<!-- /tables -->' in body else ''
    gen = ('<!-- tables -->\n## Line pass rate, by page geometry\n'
           '\nA line passes when a PDFKit drag from its first truth word\'s ink to its last\'s returns exactly the '
           'Vision words on it, in order, with no line break. Δ is against today\'s layer on the same pages, paired '
           'over pages (bootstrap, 2,000 draws). A line the arm\'s image cuts fails on that arm.\n'
           + '\n'.join(L) +
           '\n\n## Words the reading copy removes (every page)\n' + '\n'.join(E) +
           f'\n\nOwn sheet: inside Apple\'s quad, or on a Vision line the arm keeps part of. Partly cut: the word\'s '
           f'centre is kept and part of its ink box is not.\n\n## The scorer\'s self-test\n\n{selftest}'
           f'\n## What was scored\n\n{len(pages)} placement-truth pages in the 96 with a saved W46.enh-dewarp '
           f'lattice. {s["truth_lines"]} truth lines after the owner\'s rulings (merged {s["fold"]["merged"]}, '
           f'split {s["fold"]["split"]}, left out {s["fold"]["left_out"]}); {s["scored_lines"]} scored. Not '
           f'scored: {s["skipped"]["short"]} with under two scored words, {s["skipped"]["unread"]} with a word '
           f'Vision did not read, {s["skipped"]["shared"]} sharing a Vision word with another line, '
           f'{s["skipped"]["sideways"]} sideways (over 45°).\n<!-- /tables -->')
    (results / 'place-geom.md').write_text(head + gen + tail)
    return s
