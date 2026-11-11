#!/usr/bin/env python3
"""W46.ocr-pair-matrix: paired intervals for every pair of reading routes the settings solver can compare.

  python3 ocr_pair_matrix.py [--rounds 10000] [--workers 4]

The routes are the reading stage's rows of settings-routes.json that have per-page scores: on the owner's 96 a row
whose id is a route of ocr-pages.csv, on the 895 a row whose `public` figure names a (route, family) of
ocr-scorers-pages.csv. Every pair on the 96 is compared two ways, p081 apart as on the bench page: strict pairs the
95 pages and scores a failure as 0, answered pairs only the pages both routes answered. Every pair on the 895 is
compared the same two ways within each stratum (L1-L9, N1-N6) and on the pages both read in all (`all`). Each
comparison is the mean NES difference a minus b in points and its 95% bootstrap interval, drawn as
ArchiveOCRBench/build.py's `bootstrap` draws it (seed 0, the same rounds), so a pair with Qwen3.6 27B reproduces the
headline's `vs_baseline`.

The tie rule (ocr-rerun-noise.md, "The tie rule"): a gap is a tie when its interval crosses 0, or on the 96 when it is
under the pair's floor, twice the larger rerun range of the two routes. A hosted route (family cloud or plan) is held
to Gemini 3.7 Flash's 0.49; a Mac route is local greedy, 0.00; a cluster route has no rerun and is not one machine's
greedy decoding, so it is held to the hosted 0.49. On the 895 there is no floor: the interval alone decides (R-3).

Reads only the score files; no text, no model. Writes segbench-results/ocr-pair-matrix.json.
"""
from __future__ import annotations

import argparse
import csv
import json
import random
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESULTS = HERE.parent.parent / 'segbench-results'
UNCORRECTABLE = 'p081'  # reported apart on the bench page (ArchiveOCRBench/build.py)
FLOOR = {'cloud': 0.49, 'plan': 0.49, 'cluster': 0.49, 'mac': 0.0}
SOURCE = 'ocr-rerun-noise.md §The tie rule'


def interval(d, rounds, seed=0):
    """ArchiveOCRBench/build.py's bootstrap, in points, unrounded draw order kept so the ends match its figures."""
    rng, n = random.Random(seed), len(d)
    boots = sorted(sum(rng.choices(d, k=n)) / n for _ in range(rounds))
    return [n, round(100 * sum(d) / n, 2), round(100 * boots[int(.025 * rounds)], 2), round(100 * boots[int(.975 * rounds) - 1], 2)]


def table_routes():
    t = json.loads((RESULTS / 'settings-routes.json').read_text())
    rows = next(s for s in t['stages'] if s['id'] == 'reading')['routes']
    out = []
    for r in rows:
        pub = (r['figures'].get('public') or {}).get('source') or {}
        twin = None
        if pub.get('route') and ' (' in pub['route']:
            name, fam = pub['route'].rsplit(' (', 1)
            twin = (name, fam.rstrip(')'))
        out.append({'id': r['id'], 'family': r['family'], 'twin': twin})
    return out


def load_owner():
    by = {}
    with (RESULTS / 'ocr-pages.csv').open(newline='') as f:
        for r in csv.DictReader(f):
            by.setdefault(r['route'], {})[r['page']] = (r['ok'] == 'True', float(r['nes']))
    return by


def load_public():
    by, stratum = {}, {}
    with (RESULTS / 'ocr-scorers-pages.csv').open(newline='') as f:
        for r in csv.DictReader(f):
            if r['set'] == 'public895':
                by.setdefault((r['route'], r['family']), {})[r['page']] = (r['ok'] == 'True', float(r['nes']))
                stratum[r['page']] = r['stratum']
    return by, stratum


def job(args):
    """One pair in one group: [strict, answered], each [n, delta, lo, hi] or None when no page is shared."""
    a, b, pages, rounds = args
    shared = sorted(set(a) & set(b) & pages)
    both = [p for p in shared if a[p][0] and b[p][0]]
    return [interval([a[p][1] - b[p][1] for p in s], rounds) if s else None for s in (shared, both)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--rounds', type=int, default=10000)
    ap.add_argument('--workers', type=int, default=4)
    ap.add_argument('--out', type=Path, default=RESULTS / 'ocr-pair-matrix.json')
    ap.add_argument('--report', action='store_true', help='print the result note\'s tables')
    a = ap.parse_args()
    routes = table_routes()
    owner = load_owner()
    public, stratum = load_public()
    fam = {r['id']: r['family'] for r in routes}

    o_ids = [r['id'] for r in routes if r['id'] in owner]
    for i in o_ids:
        if len(owner[i]) != 96 or UNCORRECTABLE not in owner[i]:
            raise SystemExit(f'{i}: ocr-pages.csv holds {len(owner[i])} of the 96 pages')
    p_ids = [r for r in routes if r['twin'] in public]
    o_pages = {p for p in owner[o_ids[0]] if p != UNCORRECTABLE}
    groups = {'all': set(stratum)}
    for p, s in stratum.items():
        groups.setdefault(s, set()).add(p)

    jobs, keys = [], []
    for x in range(len(o_ids)):
        for y in range(x + 1, len(o_ids)):
            keys.append(('owner96', 'all', o_ids[x], o_ids[y]))
            jobs.append((owner[o_ids[x]], owner[o_ids[y]], o_pages, a.rounds))
    for g in sorted(groups):
        for x in range(len(p_ids)):
            for y in range(x + 1, len(p_ids)):
                pa, pb = public[p_ids[x]['twin']], public[p_ids[y]['twin']]
                if not set(pa) & set(pb) & groups[g]:
                    continue
                keys.append(('public895', g, p_ids[x]['id'], p_ids[y]['id']))
                jobs.append((pa, pb, groups[g], a.rounds))
    with ProcessPoolExecutor(a.workers) as ex:
        res = list(ex.map(job, jobs, chunksize=8))

    pairs = []
    for (st, g, ra, rb), (strict, answered) in zip(keys, res):
        floor = max(FLOOR[fam[ra]], FLOOR[fam[rb]]) if st == 'owner96' else 0.0
        e = {'set': st, 'group': g, 'a': ra, 'b': rb, 'floor': floor}
        for mode, v in (('strict', strict), ('answered', answered)):
            if v is None:
                e[mode] = None
                continue
            n, d, lo, hi = v
            e[mode] = {'n': n, 'delta': d, 'lo': lo, 'hi': hi, 'tie': bool(lo <= 0 <= hi or abs(d) < floor)}
        pairs.append(e)
    out = {'item': 'W46.ocr-pair-matrix', 'script': 'ArchiveProcessor/scripts/segbench/ocr_pair_matrix.py',
           'sources': ['ArchiveProcessor/segbench-results/settings-routes.json (reading routes)',
                       'ArchiveProcessor/segbench-results/ocr-pages.csv (the 96)',
                       'ArchiveProcessor/segbench-results/ocr-scorers-pages.csv (the 895)'],
           'method': {'metric': 'NES points, a minus b', 'interval': f'95% paired bootstrap, {a.rounds} rounds, seed 0 per pair '
                      '(ArchiveOCRBench/build.py bootstrap)', 'strict': 'every shared page, a failure as 0',
                      'answered': 'pages both routes answered', 'owner96_pages': 'the 95, p081 apart',
                      'tie': 'interval holds 0, or on the 96 |delta| under the floor', 'floors': FLOOR, 'tie_source': SOURCE},
           'routes': {'owner96': o_ids, 'public895': [r['id'] for r in p_ids]},
           'public_twin': {r['id']: f"{r['twin'][0]} ({r['twin'][1]})" for r in p_ids},
           'pairs': pairs}
    body = json.dumps({k: v for k, v in out.items() if k != 'pairs'}, indent=1)[:-2]
    a.out.write_text(body + ',\n "pairs": [\n' + ',\n'.join(json.dumps(e) for e in pairs) + '\n ]\n}\n')
    print(f"{len(o_ids)} routes on the 96, {len(p_ids)} on the 895; {len(pairs)} pair-groups -> {a.out}")
    if a.report:
        report(out, owner, public, p_ids)


def report(out, owner, public, p_ids):
    """Markdown for the result note: per route on the 96, the routes it cannot be told from; per stratum, the ties."""
    pairs = out['pairs']
    for mode in ('answered', 'strict'):
        mean = {}
        for i in out['routes']['owner96']:
            pp = [v for p, v in owner[i].items() if p != UNCORRECTABLE]
            use = [v[1] for v in pp if v[0]] if mode == 'answered' else [v[1] for v in pp]
            mean[i] = 100 * sum(use) / len(use)
        tie = {i: [] for i in mean}
        for e in pairs:
            if e['set'] == 'owner96' and e[mode]['tie']:
                tie[e['a']].append(e['b']); tie[e['b']].append(e['a'])
        print(f'\n### The 96, {mode}\n\n| route | NES {mode} | ties with |\n|---|---|---|')
        for i in sorted(mean, key=lambda k: -mean[k]):
            print(f"| {i} | {mean[i]:.2f} | {', '.join(sorted(tie[i], key=lambda k: -mean[k])) or 'none'} |")
    print('\n### The 895, per stratum\n\n| group | pairs (strict) | ties strict | ties answered |\n|---|---|---|---|')
    groups = sorted({e['group'] for e in pairs if e['set'] == 'public895'}, key=lambda g: (g == 'all', g))
    for g in groups:
        es = [e for e in pairs if e['set'] == 'public895' and e['group'] == g]
        ts = sum(e['strict']['tie'] for e in es)
        ta = sum(bool(e['answered'] and e['answered']['tie']) for e in es)
        print(f'| {g} | {len(es)} | {ts} | {ta} |')


if __name__ == '__main__':
    main()
