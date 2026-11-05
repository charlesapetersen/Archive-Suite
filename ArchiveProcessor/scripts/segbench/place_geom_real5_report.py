"""W46.place-geom-real5's report: segbench-results/place-geom-real5.{md,json} from place_geom_real5.py's rows.

The tables, intervals and labels are W46.place-geom's (place_geom_report: paired bootstrap over pages, 2,000 draws,
95% percentile interval, a gap whose interval holds 0 is a tie); the strata are Real5's folders and the same measured
geometry. Only the tables between the markers are rewritten; the prose around them is the report's own.
"""
from __future__ import annotations

import json
import random
from pathlib import Path

import place_geom_report as R

SKEW, STEEP, SPREAD = 1.0, 3.0, 1.0


def load(rows_path: Path):
    return [json.loads(x) for x in rows_path.read_text().splitlines() if x.strip()]


def strata(pages):
    bends = sorted(p['meta']['bend'] for p in pages)
    med = bends[len(bends) // 2] if bends else 0
    return {
        'every page': lambda m: True,
        'Warping folder': lambda m: m['cond'] == 'warp',
        'Skew folder': lambda m: m['cond'] == 'skew',
        f'skewed (|angle| ≥ {SKEW:g}°)': lambda m: abs(m['angle']) >= SKEW,
        f'steeply skewed (|angle| ≥ {STEEP:g}°)': lambda m: abs(m['angle']) >= STEEP,
        f'level (|angle| < {SKEW:g}°)': lambda m: abs(m['angle']) < SKEW,
        f'perspective (angle range ≥ {SPREAD:g}°)': lambda m: (m['spread'] or 0) >= SPREAD,
        f'curled (UVDoc bend ≥ median {med:.1f} px)': lambda m: m['bend'] >= med,
    }, med


def summarise(pages):
    by = R.table(pages)
    S, med = strata(pages)
    rng = random.Random(R.SEED)
    res = {'strata': {}, 'bend_median': med}
    for name, f in S.items():
        ids = [p['meta']['page'] for p in pages if f(p['meta'])]
        rows = []
        for v in R.VARIANTS:
            k, n = R.rate(by, v, ids)
            k0, n0 = R.rate(by, R.BASE, ids)
            rr = [by[v][i] for i in ids]
            rows.append({'arm': v[0], 'writer': v[1], 'pages': len(ids), 'lines': n, 'passed': k,
                         'rate': k / n if n else None,
                         'delta': (k / n - k0 / n0) if n and n0 and v != R.BASE else None,
                         'ci': R.paired(by, v, ids, rng),
                         'cut_lines': sum(r['lost_lines'] for r in rr),
                         'find': sum(r['found'] for r in rr) / max(1, sum(r['find_words'] for r in rr)),
                         'placed': sum(r['placed'] for r in rr) / max(1, sum(r['find_words'] for r in rr)),
                         'lost_own': sum(r['lost_own'] for r in rr),
                         'lost_neighbour': sum(r['lost_neighbour'] for r in rr),
                         'cut_words': sum(r['cut_words'] for r in rr),
                         'pages_cut': sum(1 for r in rr if r['lost_lines'] or r['lost_own'] or r['lost_neighbour'])})
        res['strata'][name] = rows
    res['skipped'] = {k: sum(p['meta']['skipped'][k] for p in pages) for k in ('unread', 'shared', 'short', 'sideways')}
    res['truth_lines'] = sum(p['meta']['truth_lines'] for p in pages)
    res['scored_lines'] = sum(p['meta']['scored_lines'] for p in pages)
    res['pages'] = [{k: p['meta'][k] for k in ('page', 'cond', 'kind', 'angle', 'spread', 'bend', 'quad_found',
                                               'truth_lines', 'scored_lines')} for p in pages]
    res['per_page'] = {f'{a}-{w}': {i: [r['passed'], r['lines']] for i, r in by[(a, w)].items()}
                       for a, w in R.VARIANTS}
    return res


def tables(s, title):
    L = []
    for name, rows in s['strata'].items():
        L.append(f'\n### {name} ({rows[0]["pages"]} pages, {rows[0]["lines"]} lines)\n')
        L.append('| arm | line pass % | Δ vs today (95% CI) | lines cut by the image | Find % |')
        L.append('|---|---:|---|---:|---:|')
        for r in rows:
            L.append(f'| {R.LABEL[(r["arm"], r["writer"])]} | {R.pct(r["rate"])} ({r["passed"]}/{r["lines"]}) | '
                     f'{R.dpct(r)} | {r["cut_lines"]} | {R.pct(r["find"])} |')
    return f'\n## {title}\n' + '\n'.join(L)


def write(rows_path: Path, results: Path):
    pages = load(rows_path)
    s = summarise(pages)
    out = {'item': 'W46.place-geom-real5', **s}
    over = rows_path.parent / 'rows-m035.jsonl'
    if over.exists():
        out['overshoot_035'] = summarise(load(over))['strata']
    (results / 'place-geom-real5.json').write_text(json.dumps(out, indent=1) + '\n')
    every = s['strata']['every page']
    E = ['\n| arm | pages cut | Vision words lost, own sheet | lost, neighbour text | words partly cut |',
         '|---|---:|---:|---:|---:|']
    for r in every:
        if r['writer'] == 'lab':
            E.append(f'| {r["arm"]} | {r["pages_cut"]} | {r["lost_own"]} | {r["lost_neighbour"]} | {r["cut_words"]} |')
    n_warp = sum(p['meta']['cond'] == 'warp' for p in pages)
    gen = ('<!-- tables -->'
           + tables(s, 'Line pass rate, drags on the words\' edges') +
           (tables({'strata': out['overshoot_035']}, 'The same drags overshooting by 0.35 of the word\'s height')
            if 'overshoot_035' in out else '') +
           '\n\n## Words the reading copy removes (every page)\n' + '\n'.join(E) +
           f'\n\n## What was scored\n\n{len(pages)} images ({n_warp} Warping, {len(pages) - n_warp} Skew) of the '
           f'155 pages. {s["truth_lines"]} truth lines (Vision lines that are one OmniDocBench line); '
           f'{s["scored_lines"]} scored. Not scored: {s["skipped"]["short"]} under two words, '
           f'{s["skipped"]["sideways"]} sideways (over 45°), {s["skipped"]["shared"]} sharing a word. UVDoc bend '
           f'median {s["bend_median"]:.1f} px.\n<!-- /tables -->')
    path = results / 'place-geom-real5.md'
    body = path.read_text() if path.exists() else '# W46.place-geom-real5\n\n'
    head = body.split('<!-- tables -->')[0] if '<!-- tables -->' in body else body
    tail = body.split('<!-- /tables -->')[1] if '<!-- /tables -->' in body else ''
    path.write_text(head + gen + tail)
    return s
