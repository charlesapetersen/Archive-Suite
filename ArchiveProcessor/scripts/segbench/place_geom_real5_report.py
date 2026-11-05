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
        f'mildly skewed ({SKEW:g}° ≤ |angle| < {STEEP:g}°)': lambda m: SKEW <= abs(m['angle']) < STEEP,
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


def against_deskew(pages):
    """UVDoc and quad (lab writer) against deskew (lab writer) on the same pages, paired as the main tables are;
    also on the pages where the arm's image removes no truth line and no own-sheet word."""
    by = R.table(pages)
    S, _ = strata(pages)
    base = ('deskew', 'lab')
    rng = random.Random(R.SEED)
    out = []
    for arm in ('uvdoc', 'quad'):
        v = (arm, 'lab')
        sets = [(name, f) for name, f in S.items() if name.split(' (')[0] in
                ('every page', 'Warping folder', 'Skew folder', 'level', 'curled')]
        sets.append(('pages it removes nothing from', lambda m, arm=arm: not by[(arm, 'lab')][m['page']]['lost_lines']
                     and not by[(arm, 'lab')][m['page']]['lost_own']))
        for name, f in sets:
            ids = [p['meta']['page'] for p in pages if f(p['meta'])]
            k, n = R.rate(by, v, ids)
            k0, n0 = R.rate(by, base, ids)
            d = []
            for _ in range(R.DRAWS):
                draw = [rng.choice(ids) for _ in ids]
                a, b = R.rate(by, v, draw), R.rate(by, base, draw)
                if a[1] and b[1]:
                    d.append(a[0] / a[1] - b[0] / b[1])
            d.sort()
            out.append({'arm': arm, 'stratum': name, 'pages': len(ids), 'lines': n, 'rate': k / n if n else None,
                        'deskew': k0 / n0 if n0 else None, 'delta': (k / n - k0 / n0) if n and n0 else None,
                        'ci': (d[int(0.025 * len(d))], d[int(0.975 * len(d)) - 1]) if d else None})
    return out


def tables(s, title):
    L = []
    for name, rows in s['strata'].items():
        L.append(f'\n### {name} ({rows[0]["pages"]} pages, {rows[0]["lines"]} lines)\n')
        L.append('| arm | line pass % | Δ vs today (95% CI) | lines cut by the image |')
        L.append('|---|---:|---|---:|')
        for r in rows:
            L.append(f'| {R.LABEL[(r["arm"], r["writer"])]} | {R.pct(r["rate"])} ({r["passed"]}/{r["lines"]}) | '
                     f'{R.dpct(r)} | {r["cut_lines"]} |')
    return f'\n## {title}\n' + '\n'.join(L)


def write(rows_path: Path, results: Path):
    pages = load(rows_path)
    s = summarise(pages)
    out = {'item': 'W46.place-geom-real5', **s}
    over = rows_path.parent / 'rows-m035.jsonl'
    if over.exists():
        out['overshoot_035'] = summarise(load(over))['strata']
    out['against_deskew'] = vd = against_deskew(pages)
    (results / 'place-geom-real5.json').write_text(json.dumps(out, indent=1) + '\n')
    D = ['\n## Quad and UVDoc against deskew\n',
         'Each with the lab writer, Δ against deskew with the lab writer on the same pages (paired, as above). The last '
         'row of each is the pages where that arm\'s image removes no truth line and no own-sheet word.\n',
         '| arm | pages | n | lines | arm % | deskew % | Δ vs deskew (95% CI) |', '|---|---|---:|---:|---:|---:|---|']
    for r in vd:
        D.append(f'| {r["arm"]} | {r["stratum"]} | {r["pages"]} | {r["lines"]} | {R.pct(r["rate"])} | '
                 f'{R.pct(r["deskew"])} | {R.dpct(r)} |')
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
           '\n' + '\n'.join(D) +
           '\n\n## Words the reading copy removes (every page)\n' + '\n'.join(E) +
           f'\n\n## What was scored\n\n{len(pages)} images ({n_warp} Warping, {len(pages) - n_warp} Skew) of the '
           f'155 pages. {s["truth_lines"]} truth lines (Vision lines that are one OmniDocBench line); '
           f'{s["scored_lines"]} scored. Not scored: {s["skipped"]["short"]} under two words, '
           f'{s["skipped"]["sideways"]} sideways (over 45°), {s["skipped"]["shared"]} sharing a word. UVDoc bend '
           f'median {s["bend_median"]:.1f} px. Find is not tabled: the truth is Vision\'s own words, so every arm finds '
           f'all of them (the JSON keeps the figures).\n<!-- /tables -->')
    path = results / 'place-geom-real5.md'
    body = path.read_text() if path.exists() else '# W46.place-geom-real5\n\n'
    head = body.split('<!-- tables -->')[0] if '<!-- tables -->' in body else body
    tail = body.split('<!-- /tables -->')[1] if '<!-- /tables -->' in body else ''
    path.write_text(head + gen + tail)
    return s
