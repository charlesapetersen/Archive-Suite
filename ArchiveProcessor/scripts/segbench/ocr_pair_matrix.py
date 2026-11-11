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

The tie rule. On the 96 a gap is a tie only when it is under the pair's floor, twice the larger rerun range of the two
routes (the owner, 2026-11-11, W46.pairs-redecide-owner-ok: "floor only", as 12-settings-design §3.3 reads; the
paired interval is shown beside the figure but makes no tie). A hosted route (family cloud or plan) is held to Gemini
3.7 Flash's 0.49; a Mac route is local greedy, 0.00; a cluster route has no rerun and is not one machine's greedy
decoding, so it is held to the hosted 0.49. On the 895 there is no floor: the interval alone decides (R-3). Each
entry keeps both tests, `under_floor` and `interval_holds_0`, and `tie` is the one its set uses.

W46.pair-matrix-cover added the groups the solver ranks on. On the 96, beside `all`: each kind of ocr-pages.csv
(typewritten 50 pages, printed 27 with p081 apart, handwritten 16), strict and answered, and `hands16`, the 16 hand
pages on the truth after the owner's hand sheet (ocr-hands-pages.csv, written by ocr_hands_rescore.py), strict only
(that file scores an empty reading as 0 and keeps no answered flag). Each kind takes twice its own rerun range
(ocr-rerun-noise.md, Gemini 3.7 Flash per kind: typewritten 0.21, printed 0.12, handwritten 0.30), a Mac pair 0.00.
On the 895, beside the strata, `L1-L3`, the three handwritten strata pooled.

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
# per group on the 96, the hosted floor (a Mac pair stays 0.00): twice Gemini 3.7 Flash's rerun range of the kind
KIND_FLOOR = {'all': 0.49, 'typewritten': 0.42, 'printed': 0.24, 'handwritten': 0.60, 'hands16': 0.60}
KINDS = ('typewritten', 'printed', 'handwritten')
HANDS_GROUP = 'hands16'
POOLED = {'L1-L3': ('L1', 'L2', 'L3')}
SOURCE = 'ocr-rerun-noise.md §The tie rule'


def interval(d, rounds, seed=0):
    """ArchiveOCRBench/build.py's bootstrap, in points, unrounded draw order kept so the ends match its figures."""
    rng, n = random.Random(seed), len(d)
    boots = sorted(sum(rng.choices(d, k=n)) / n for _ in range(rounds))
    return [n, round(100 * sum(d) / n, 2), round(100 * boots[int(.025 * rounds)], 2), round(100 * boots[int(.975 * rounds) - 1], 2)]


def table_routes(t=None):
    t = t or json.loads((RESULTS / 'settings-routes.json').read_text())
    rows = next(s for s in t['stages'] if s['id'] == 'reading')['routes']
    out = []
    for r in rows:
        pub = (r['figures'].get('public') or {}).get('source') or {}
        twin = None
        if pub.get('route') and ' (' in pub['route']:
            name, fam = pub['route'].rsplit(' (', 1)
            twin = (name, fam.rstrip(')'))
        hs = (r['figures'].get('hands16') or {}).get('source') or {}
        hand = hs['route'] if hs.get('file', '').endswith('ocr-hands-rescore.json') else None
        out.append({'id': r['id'], 'family': r['family'], 'twin': twin, 'hand': hand})
    return out


def load_owner():
    by, kind = {}, {}
    with (RESULTS / 'ocr-pages.csv').open(newline='') as f:
        for r in csv.DictReader(f):
            by.setdefault(r['route'], {})[r['page']] = (r['ok'] == 'True', float(r['nes']))
            kind[r['page']] = r['kind']
    return by, kind


def load_hands():
    """ocr-hands-pages.csv: route (the rescore's name) -> page -> (True, nes); no answered flag, so strict only."""
    by = {}
    with (RESULTS / 'ocr-hands-pages.csv').open(newline='') as f:
        for r in csv.DictReader(f):
            by.setdefault(r['route'], {})[r['page']] = (True, float(r['nes']) / 100)
    return by


def coverage(routes=None):
    """The reading rows that have per-page scores, per set: what the matrix must pair (settings_routes.py --check)."""
    routes = routes or table_routes()
    owner, _ = load_owner()
    public, _ = load_public()
    hands = load_hands()
    return {'owner96': [r['id'] for r in routes if r['id'] in owner],
            'public895': [r['id'] for r in routes if r['twin'] in public],
            HANDS_GROUP: [r['id'] for r in routes if r['hand'] in hands]}


def load_public():
    by, stratum = {}, {}
    with (RESULTS / 'ocr-scorers-pages.csv').open(newline='') as f:
        for r in csv.DictReader(f):
            if r['set'] == 'public895':
                by.setdefault((r['route'], r['family']), {})[r['page']] = (r['ok'] == 'True', float(r['nes']))
                stratum[r['page']] = r['stratum']
    return by, stratum


def job(args):
    """One pair in one group: [strict, answered], each [n, delta, lo, hi] or None when no page is shared (answered
    is None too when the group keeps no answered flag)."""
    a, b, pages, rounds, answered = args
    shared = sorted(set(a) & set(b) & pages)
    both = [p for p in shared if a[p][0] and b[p][0]] if answered else []
    return [interval([a[p][1] - b[p][1] for p in s], rounds) if s else None for s in (shared, both)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--rounds', type=int, default=10000)
    ap.add_argument('--workers', type=int, default=4)
    ap.add_argument('--out', type=Path, default=RESULTS / 'ocr-pair-matrix.json')
    ap.add_argument('--report', action='store_true', help='print the result note\'s tables')
    a = ap.parse_args()
    routes = table_routes()
    owner, kind = load_owner()
    public, stratum = load_public()
    hands = load_hands()
    fam = {r['id']: r['family'] for r in routes}

    o_ids = [r['id'] for r in routes if r['id'] in owner]
    for i in o_ids:
        if len(owner[i]) != 96 or UNCORRECTABLE not in owner[i]:
            raise SystemExit(f'{i}: ocr-pages.csv holds {len(owner[i])} of the 96 pages')
    p_ids = [r for r in routes if r['twin'] in public]
    h_rows = [r for r in routes if r['hand'] in hands]
    o_pages = {p for p in owner[o_ids[0]] if p != UNCORRECTABLE}
    o_groups = {'all': o_pages, **{k: {p for p in o_pages if kind[p] == k} for k in KINDS}}
    h_pages = set(next(iter(hands.values())))
    if h_pages != o_groups['handwritten'] or any(set(v) != h_pages for v in hands.values()):
        raise SystemExit('ocr-hands-pages.csv: not the 96\'s 16 handwritten pages for every route')
    groups = {'all': set(stratum)}
    for p, s in stratum.items():
        groups.setdefault(s, set()).add(p)
    for g, parts in POOLED.items():
        groups[g] = set().union(*(groups[s] for s in parts))

    jobs, keys = [], []
    for g, pages in o_groups.items():
        for x in range(len(o_ids)):
            for y in range(x + 1, len(o_ids)):
                keys.append(('owner96', g, o_ids[x], o_ids[y]))
                jobs.append((owner[o_ids[x]], owner[o_ids[y]], pages, a.rounds, True))
    for x in range(len(h_rows)):
        for y in range(x + 1, len(h_rows)):
            keys.append(('owner96', HANDS_GROUP, h_rows[x]['id'], h_rows[y]['id']))
            jobs.append((hands[h_rows[x]['hand']], hands[h_rows[y]['hand']], h_pages, a.rounds, False))
    for g in sorted(groups):
        for x in range(len(p_ids)):
            for y in range(x + 1, len(p_ids)):
                pa, pb = public[p_ids[x]['twin']], public[p_ids[y]['twin']]
                if not set(pa) & set(pb) & groups[g]:
                    continue
                keys.append(('public895', g, p_ids[x]['id'], p_ids[y]['id']))
                jobs.append((pa, pb, groups[g], a.rounds, True))
    with ProcessPoolExecutor(a.workers) as ex:
        res = list(ex.map(job, jobs, chunksize=8))

    pairs = []
    for (st, g, ra, rb), (strict, answered) in zip(keys, res):
        hosted = fam[ra] != 'mac' or fam[rb] != 'mac'
        floor = KIND_FLOOR[g] if st == 'owner96' and hosted else 0.0
        e = {'set': st, 'group': g, 'a': ra, 'b': rb, 'floor': floor}
        for mode, v in (('strict', strict), ('answered', answered)):
            if v is None:
                e[mode] = None
                continue
            n, d, lo, hi = v
            under, holds0 = abs(d) < floor, lo <= 0 <= hi
            e[mode] = {'n': n, 'delta': d, 'lo': lo, 'hi': hi, 'tie': under if st == 'owner96' else holds0,
                       'under_floor': under, 'interval_holds_0': holds0}
        pairs.append(e)
    out = {'item': 'W46.ocr-pair-matrix', 'script': 'ArchiveProcessor/scripts/segbench/ocr_pair_matrix.py',
           'sources': ['ArchiveProcessor/segbench-results/settings-routes.json (reading routes)',
                       'ArchiveProcessor/segbench-results/ocr-pages.csv (the 96)',
                       'ArchiveProcessor/segbench-results/ocr-scorers-pages.csv (the 895)'],
           'method': {'metric': 'NES points, a minus b', 'interval': f'95% paired bootstrap, {a.rounds} rounds, seed 0 per pair '
                      '(ArchiveOCRBench/build.py bootstrap)', 'strict': 'every shared page, a failure as 0',
                      'answered': 'pages both routes answered', 'owner96_pages': 'the 95, p081 apart',
                      'tie': 'on the 96 |delta| under the floor (owner, 2026-11-11: floor only); on the 895 the interval '
                             'holds 0 (no floor, R-3)', 'floors': FLOOR,
                      'kind_floors': KIND_FLOOR, 'tie_source': SOURCE,
                      'groups': {'owner96': list(o_groups) + [HANDS_GROUP], 'public895': sorted(groups, key=group_order)},
                      'hands16': 'ocr-hands-pages.csv, the 16 hand pages on the corrected truth; strict only'},
           'routes': {'owner96': o_ids, 'public895': [r['id'] for r in p_ids], HANDS_GROUP: [r['id'] for r in h_rows]},
           'public_twin': {r['id']: f"{r['twin'][0]} ({r['twin'][1]})" for r in p_ids},
           'hands_twin': {r['id']: r['hand'] for r in h_rows},
           'pairs': pairs}
    body = json.dumps({k: v for k, v in out.items() if k != 'pairs'}, indent=1)[:-2]
    a.out.write_text(body + ',\n "pairs": [\n' + ',\n'.join(json.dumps(e) for e in pairs) + '\n ]\n}\n')
    print(f"{len(o_ids)} routes on the 96 ({len(h_rows)} with hands16), {len(p_ids)} on the 895; "
          f"{len(pairs)} pair-groups -> {a.out}")
    if a.report:
        report(out, owner, kind, hands)


def group_order(g):
    return (g == 'all', g in POOLED, g)


def report(out, owner, kind, hands):
    """Markdown for the result note: per route on the 96, the routes it cannot be told from; per kind and on the pooled
    hand strata, each route against the group's leader; per stratum, the ties."""
    pairs = out['pairs']
    for mode in ('answered', 'strict'):
        mean = {}
        for i in out['routes']['owner96']:
            pp = [v for p, v in owner[i].items() if p != UNCORRECTABLE]
            use = [v[1] for v in pp if v[0]] if mode == 'answered' else [v[1] for v in pp]
            mean[i] = 100 * sum(use) / len(use)
        tie = {i: [] for i in mean}
        for e in pairs:
            if e['set'] == 'owner96' and e['group'] == 'all' and e[mode]['tie']:
                tie[e['a']].append(e['b']); tie[e['b']].append(e['a'])
        print(f'\n### The 96, {mode}\n\n| route | NES {mode} | ties with |\n|---|---|---|')
        for i in sorted(mean, key=lambda k: -mean[k]):
            print(f"| {i} | {mean[i]:.2f} | {', '.join(sorted(tie[i], key=lambda k: -mean[k])) or 'none'} |")
    hand_of = out['hands_twin']
    for g in KINDS + (HANDS_GROUP,):
        if g == HANDS_GROUP:
            mean = {i: 100 * sum(v[1] for v in hands[hand_of[i]].values()) / 16 for i in out['routes'][HANDS_GROUP]}
        else:
            mean = {}
            for i in out['routes']['owner96']:
                v = [x[1] for p, x in owner[i].items() if p != UNCORRECTABLE and kind[p] == g]
                mean[i] = 100 * sum(v) / len(v)
        leader_table(f'The 96, {g}, strict (floor {KIND_FLOOR[g]:.2f} hosted, 0.00 Mac pairs)', mean,
                     [e for e in pairs if e['set'] == 'owner96' and e['group'] == g])
    print('\n### The 895, per stratum\n\n| group | pairs (strict) | ties strict | ties answered |\n|---|---|---|---|')
    groups = sorted({e['group'] for e in pairs if e['set'] == 'public895'}, key=group_order)
    for g in groups:
        es = [e for e in pairs if e['set'] == 'public895' and e['group'] == g]
        ts = sum(e['strict']['tie'] for e in es)
        ta = sum(bool(e['answered'] and e['answered']['tie']) for e in es)
        print(f'| {g} | {len(es)} | {ts} | {ta} |')
    public, stratum = load_public()
    twin = {i: tuple(t.rsplit(' (', 1)) for i, t in out['public_twin'].items()}
    for g, parts in POOLED.items():
        mean = {}
        for i, (name, fam) in twin.items():
            v = [x[1] for p, x in public[(name, fam.rstrip(')'))].items() if stratum[p] in parts]
            if v:
                mean[i] = 100 * sum(v) / len(v)
        leader_table(f'The 895, {g} pooled, strict (no floor)', mean,
                     [e for e in pairs if e['set'] == 'public895' and e['group'] == g])


def leader_table(title, mean, es):
    """Each route of one group against the group's leader: the pair's strict delta, interval, n and tie."""
    lead = max(mean, key=mean.get)
    by = {}
    for e in es:
        if lead in (e['a'], e['b']) and e['strict']:
            x = e['strict']
            sign = 1 if e['a'] == lead else -1
            other = e['b'] if e['a'] == lead else e['a']
            lo, hi = (x['lo'], x['hi']) if sign == 1 else (-x['hi'], -x['lo'])
            by[other] = (f"{sign * x['delta']:+.2f} [{lo:+.2f}, {hi:+.2f}] (n {x['n']}) | {'tie' if x['tie'] else 'trails'} | "
                         f"{'yes' if x['interval_holds_0'] else 'no'}")
    print(f'\n### {title}\n\n| route | NES strict | leader minus route [95%] | tie | interval holds 0 |\n|---|---|---|---|---|')
    for i in sorted(mean, key=lambda k: -mean[k]):
        print(f"| {i} | {mean[i]:.2f} | {'leader | | ' if i == lead else by.get(i, 'no shared page | | ')} |")

if __name__ == '__main__':
    main()
