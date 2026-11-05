"""W46.rotation-routes' report: every route's answers scored on the same turned pages, per set and stratum, with the
cascades built from the same answers (no new calls). Writes segbench-results/rotation-routes.md and .json; the
ArchiveOCRBench page reads the .json. Run by `rotation_routes.py report`."""
from __future__ import annotations

import collections
import json
import math
import platform
import subprocess

import rotation_routes as RR

GROUPS = ('owner96', 'L1', 'L4', 'L7', 'N1', 'N4', 'N5')
GROUP_NAMES = {'owner96': "the owner's 96", 'L1': 'L1 English handwriting', 'L4': 'L4 ledgers and tables',
               'L7': 'L7 charters', 'N1': 'N1 Arabic', 'N4': 'N4 Hebrew', 'N5': 'N5 Chinese print'}
ROUTE_NAMES = {
    'vision': 'Local Vision (RotationDetector, as shipped)',
    'llm1': 'llmSingle: Gemini 3.7 Flash, one comparative call',
    'llm1+v': 'llmSingle as the app runs it (Vision when the call abstains)',
    'llm3': 'llmMajority: Gemini 3.7 Flash, three orderings, most votes',
    'tesseract': 'Tesseract 5 OSD (--psm 0)',
    'paddle': 'PP-LCNet_x1_0_doc_ori (PaddleX)',
    'mlx-qwen3vl-8b-compare': 'Qwen3-VL 8B 4-bit, comparative prompt',
    'mlx-qwen3vl-8b-single': 'Qwen3-VL 8B 4-bit, one-image prompt',
    'mlx-qwen35-2b-compare': 'Qwen3.5 2B 4-bit, comparative prompt',
    'mlx-qwen35-2b-single': 'Qwen3.5 2B 4-bit, one-image prompt',
}
LICENCES = {
    'vision': 'Apple Vision framework (macOS, on device)',
    'tesseract': 'Apache-2.0 (Tesseract 5; osd.traineddata, tessdata)',
    'paddle': 'Apache-2.0 (PaddleX / PP-LCNet_x1_0_doc_ori weights)',
    'mlx-qwen3vl-8b': 'Apache-2.0 (Qwen3-VL-8B-Instruct; mlx-community 4-bit conversion)',
    'mlx-qwen35-2b': 'Apache-2.0 (Qwen3.5-2B; mlx-community 4-bit conversion)',
    'gemini': 'proprietary, Stanford AI API gateway (real money)',
}


VERDICT = 'Pending.'
CARD = 'Pending.'
BENCH_META = '216 pages × 4 turns · W46.rotation-routes'
BENCH_NOTE = 'Pending.'


def wilson(k, n, z=1.96):
    if not n:
        return (None, None)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (round(100 * (c - h), 1), round(100 * (c + h), 1))


def outcome(found, turn):
    w = RR.want(turn)
    if found is None:
        return 'abstain'
    if found == w:
        return 'exact'
    return 'axis' if found % 180 != w % 180 else 'flip'


def load():
    pages = {p['id']: p for p in RR.page_list()}
    keys = [(i, t) for i in pages for t in RR.TURNS]
    a = {}
    for name in ('vision', 'tesseract', 'paddle', 'mlx-qwen3vl-8b-compare', 'mlx-qwen3vl-8b-single',
                 'mlx-qwen35-2b-compare', 'mlx-qwen35-2b-single'):
        d = RR.done(name)
        if d:
            a[name] = d
    o = [RR.done(f'gw-order{i}') for i in range(3)]
    if o[0]:
        a['llm1'] = o[0]
        if 'vision' in a:
            a['llm1+v'] = {k: (r if r['found'] is not None else {**a['vision'][k], 'cost': r['cost']})
                           for k, r in o[0].items() if k in a['vision']}
    ties = {}
    if o[1] and o[2]:
        m = {}
        for k in o[0]:
            if k in o[1] and k in o[2]:
                votes = [x[k]['found'] for x in o if x[k]['found'] is not None]
                cost = sum(x[k]['cost'] for x in o)
                secs = sum(x[k]['seconds'] for x in o)   # the app asks the orderings in turn; wall time adds
                if not votes:
                    m[k] = {'found': None, 'cost': cost, 'seconds': secs}
                    continue
                c = collections.Counter(votes)
                top = max(c.values())
                best = [v for v in votes if c[v] == top]
                # The app takes Dictionary.max, whose pick among tied counts follows hash order (random per launch).
                # Scored here as the first ordering's answer among the tied; ties are counted and reported.
                if len(set(best)) > 1:
                    ties[k] = sorted(set(best))
                m[k] = {'found': best[0], 'cost': cost, 'seconds': secs, 'votes': votes}
        a['llm3'] = m
    return pages, keys, a, ties


def score(pages, ans, keys):
    rows = collections.Counter()
    secs, cost = [], []
    for k in keys:
        r = ans.get(k)
        if r is None:
            continue
        rows[outcome(r['found'], k[1])] += 1
        rows['n'] += 1
        secs.append(r.get('seconds') or 0)
        cost.append(r.get('cost') or 0)
    n = rows['n']
    lo, hi = wilson(rows['exact'], n)
    return {'n': n, 'exact': rows['exact'], 'axis': rows['axis'], 'flip': rows['flip'], 'abstain': rows['abstain'],
            'pct': round(100 * rows['exact'] / n, 1) if n else None, 'lo': lo, 'hi': hi,
            'seconds': round(sum(secs) / n, 3) if n else None,
            'usd_per_page': round(sum(cost) / n, 5) if n else None}


def cascades(a):
    """Routes built from answers already in hand: the first route answers, later ones only where it abstains (or,
    for the agreement rule, where the two first routes disagree). Cost and seconds count only the calls made."""
    out = {}

    def chain(name, steps, agree=None):
        if not all(s in a for s in steps) or (agree and not all(s in a for s in agree)):
            return
        m = {}
        for k in a[steps[0]]:
            if not all(k in a[s] for s in steps) or (agree and not all(k in a[s] for s in agree)):
                continue
            cost = secs = 0.0
            found = None
            if agree:
                x, y = (a[s][k] for s in agree)
                secs += (x.get('seconds') or 0) + (y.get('seconds') or 0)
                if x['found'] is not None and x['found'] == y['found']:
                    m[k] = {'found': x['found'], 'cost': 0.0, 'seconds': secs, 'escalated': False}
                    continue
            esc = False
            for i, s in enumerate(steps):
                r = a[s][k]
                cost += r.get('cost') or 0
                secs += r.get('seconds') or 0
                if i:
                    esc = True
                if r['found'] is not None:
                    found = r['found']
                    break
            m[k] = {'found': found, 'cost': cost, 'seconds': secs, 'escalated': esc or bool(agree)}
        out[name] = m

    chain('vision>llm1', ['vision', 'llm1'])
    chain('vision>qwen3vl-compare', ['vision', 'mlx-qwen3vl-8b-compare'])
    chain('vision>paddle', ['vision', 'paddle'])
    chain('vision=paddle>llm1', ['llm1', 'vision'], agree=['vision', 'paddle'])
    chain('vision=paddle>llm3', ['llm3', 'vision'], agree=['vision', 'paddle'])
    chain('vision=qwen3vl>llm1', ['llm1', 'vision'], agree=['vision', 'mlx-qwen3vl-8b-compare'])
    return out


CASCADE_NAMES = {
    'vision>llm1': 'Vision; llmSingle where Vision abstains',
    'vision>qwen3vl-compare': 'Vision; Qwen3-VL 8B comparative where Vision abstains ($0)',
    'vision>paddle': 'Vision; PP-LCNet where Vision abstains ($0)',
    'vision=paddle>llm1': 'Vision and PP-LCNet agree, else llmSingle (Vision if it abstains)',
    'vision=paddle>llm3': 'Vision and PP-LCNet agree, else llmMajority (Vision if it abstains)',
    'vision=qwen3vl>llm1': 'Vision and Qwen3-VL comparative agree, else llmSingle (Vision if it abstains)',
}


def paired(a, x, y, keys):
    """Exact-or-not on the turns both routes answered or abstained on: x right & y wrong, x wrong & y right."""
    b = c = 0
    for k in keys:
        if k in a[x] and k in a[y]:
            ex = a[x][k]['found'] == RR.want(k[1])
            ey = a[y][k]['found'] == RR.want(k[1])
            b += ex and not ey
            c += ey and not ex
    return b, c


def offset(ans, pid):
    """The one non-zero offset a route gives at all four turns of a page (each answer = right answer + offset), else None."""
    got = [ans.get((pid, t)) for t in RR.TURNS]
    if any(g is None or g['found'] is None for g in got):
        return None
    ds = {(g['found'] - RR.want(t)) % 360 for g, t in zip(got, RR.TURNS)}
    return ds.pop() if len(ds) == 1 and 0 not in ds else None


def stored_sideways(pages, a):
    """Public pages the dataset may store turned: Gemini (llmSingle) and at least one local route of another family
    each give the same non-zero offset at all four turns. A sensitivity only: the pages stay in every headline figure,
    since dropping them is a choice made by tested routes."""
    out = {}
    for pid, p in pages.items():
        if p['set'] != 'public' or 'llm1' not in a:
            continue
        g = offset(a['llm1'], pid)
        if g is None:
            continue
        agree = [r for r in ('vision', 'paddle', 'tesseract') if r in a and offset(a[r], pid) == g]
        if agree:
            out[pid] = {'offset': g, 'routes': ['llm1'] + agree}
    return out


def report():
    pages, keys, a, ties = load()
    sideways = stored_sideways(pages, a)
    routes = dict(a)
    casc = cascades(a)
    routes.update(casc)
    names = {**ROUTE_NAMES, **CASCADE_NAMES}
    by_group = {g: [k for k in keys if pages[k[0]]['stratum'] == g] for g in GROUPS}
    public = [k for k in keys if pages[k[0]]['set'] == 'public']
    table = {}
    for r, ans in routes.items():
        table[r] = {'all': score(pages, ans, keys), 'public': score(pages, ans, public),
                    **{g: score(pages, ans, by_group[g]) for g in GROUPS}}
        if r in casc:
            esc = [v for v in ans.values() if v.get('escalated')]
            table[r]['escalated'] = len(esc)
    peaks = {}
    for r in a:
        if r.startswith('mlx-'):
            peaks[r] = max(v.get('peak_gb') or 0 for v in a[r].values())
    gw = RR.gw()
    led = [x for x in gw.ledger()]
    spend = gw.billed(led)
    misses = collections.defaultdict(list)
    for r in ('vision', 'llm1', 'llm3', 'paddle', 'tesseract'):
        if r in a:
            for k, v in sorted(a[r].items()):
                o = outcome(v['found'], k[1])
                if o != 'exact':
                    misses[r].append(f"{k[0]}@{k[1]}:{o}")
    pairs = {}
    for x, y in (('llm1', 'vision'), ('llm3', 'llm1'), ('paddle', 'vision'), ('mlx-qwen3vl-8b-compare', 'vision'),
                 ('vision=paddle>llm1', 'vision'), ('vision=paddle>llm1', 'llm1')):
        if x in routes and y in routes:
            for g, ks in (('owner96', by_group['owner96']), ('public', public)):
                pairs[f'{x} vs {y} · {g}'] = paired(routes, x, y, ks)
    kept = [k for k in public if k[0] not in sideways]
    for r in table:
        table[r]['public_upright'] = score(pages, routes[r], kept)
    data = {'stored_sideways': sideways, 'item': 'W46.rotation-routes', 'pages': {g: len(by_group[g]) // 4 for g in GROUPS},
            'turns_per_page': 4, 'routes': {r: {'name': names.get(r, r), **table[r]} for r in table},
            'majority_ties': {f'{k[0]}@{k[1]}': v for k, v in sorted(ties.items())},
            'mlx_peak_gb': peaks, 'gateway_spend': spend, 'licences': LICENCES,
            'tesseract': RR.tesseract_version(), 'machine': f"{platform.machine()} {platform.mac_ver()[0]}",
            'misses': {r: v for r, v in misses.items()}, 'paired': {k: list(v) for k, v in pairs.items()}}
    data['bench_meta'] = BENCH_META
    data['bench_note'] = BENCH_NOTE
    (RR.RESULTS / 'rotation-routes.json').write_text(json.dumps(data, indent=1) + '\n')
    (RR.RESULTS / 'rotation-routes.md').write_text(md(data, VERDICT, CARD))
    print(json.dumps({r: (table[r]['all'], table[r]['owner96']['pct'], table[r]['public']['pct']) for r in table}, indent=0))


def cell(s):
    if not s or not s['n']:
        return '—'
    return f"{s['exact']}/{s['n']} ({s['pct']:.1f}%)"


def md(data, verdict, card):
    R = data['routes']
    order = [r for r in ('vision', 'llm1', 'llm1+v', 'llm3', 'paddle', 'tesseract', 'mlx-qwen3vl-8b-compare',
                         'mlx-qwen3vl-8b-single', 'mlx-qwen35-2b-compare', 'mlx-qwen35-2b-single') if r in R]
    casc = [r for r in CASCADE_NAMES if r in R]
    out = ['# Which rotation route to recommend (W46.rotation-routes)', '',
           'Generated by `scripts/segbench/rotation_routes.py report` from the saved answers. Every route answers the '
           'same turns: each upright page turned 0, 90, 180 and 270 degrees clockwise; a route is right when it gives '
           'the clockwise correction that makes the page upright. **Wrong axis** = off by 90 (sideways left on the '
           'page), **flip** = off by 180 (upside down), **abstain** = no answer (the app then leaves the page as it is, '
           'or, for an LLM mode, falls back to Vision).', '', '## Verdict', '', verdict, '',
           '## Every route, all turns', '',
           '| Route | Turns | Exact (95% interval) | Wrong axis | Flip | Abstain | Seconds a page | $ a page |',
           '|---|---|---|---|---|---|---|---|']
    for r in order + casc:
        s = R[r]['all']
        out.append(f"| {R[r]['name']} | {s['n']} | {s['pct']:.1f}% ({s['lo']}–{s['hi']}) | {s['axis']} | {s['flip']} | "
                   f"{s['abstain']} | {s['seconds']:.2f} | {s['usd_per_page']:.4f} |")
    out += ['', 'Seconds are wall time a turned page on this Mac (' + data['machine'] + '); a gateway call\'s seconds '
            'are its round trip, and llmMajority\'s add its three calls as the app asks them in turn. The local models '
            'and llmMajority ran on subsets (Scope, below), so their "all turns" row is their own subset.', '',
            '## By stratum', '', '| Route | ' + ' | '.join(GROUP_NAMES[g] for g in GROUPS) + ' |',
            '|---|' + '---|' * len(GROUPS)]
    for r in order + casc:
        out.append(f"| {R[r]['name']} | " + ' | '.join(cell(R[r][g]) for g in GROUPS) + ' |')
    out += ['', '## Errors by stratum: wrong axis / flip / abstain', '', '| Route | ' + ' | '.join(GROUPS) + ' |',
            '|---|' + '---|' * len(GROUPS)]
    for r in order:
        out.append(f"| {R[r]['name']} | " + ' | '.join(
            (f"{R[r][g]['axis']}/{R[r][g]['flip']}/{R[r][g]['abstain']}" if R[r][g]['n'] else '—') for g in GROUPS) + ' |')
    sw = data['stored_sideways']
    out += ['', '## Pages the public set may store turned', '',
            f"{len(sw)} public pages get the same non-zero correction at all four turns from Gemini and from at least one "
            "local route of another family, so the dataset's own orientation of them is probably not upright: "
            + (', '.join(f"{k} (+{v['offset']}°: {', '.join(v['routes'])})" for k, v in sw.items()) or 'none') + '. '
            'They stay in every figure above. Without them, on the public strata:', '',
            '| Route | Public, as stored | Public, without these pages |', '|---|---|---|']
    for r in order + casc:
        out.append(f"| {R[r]['name']} | {cell(R[r]['public'])} | {cell(R[r]['public_upright'])} |")
    out += ['', '## Cascades, scored from the same answers', '',
            '| Cascade | Turns | Exact | Escalated | $ a page |', '|---|---|---|---|---|']
    for r in casc:
        s = R[r]['all']
        out.append(f"| {R[r]['name']} | {s['n']} | {s['pct']:.1f}% ({s['lo']}–{s['hi']}) | {R[r].get('escalated', 0)} | {s['usd_per_page']:.4f} |")
    out += ['', '## Paired: turns where one route is right and the other wrong', '', '| Pair · set | first right only | second right only |',
            '|---|---|---|']
    for k, (b, c) in data['paired'].items():
        x, rest = k.split(' vs ')
        y, g = rest.split(' · ')
        out.append(f"| {R[x]['name']} vs {R[y]['name']} · {g} | {b} | {c} |")
    out += ['', '## The misses', '']
    for r, v in data['misses'].items():
        out.append(f"- **{R[r]['name']}** ({len(v)}): " + (', '.join(v[:60]) + (' …' if len(v) > 60 else '') if v else 'none'))
    if data['majority_ties']:
        out.append(f"- **llmMajority ties** ({len(data['majority_ties'])}): three different answers, scored as the first "
                   "ordering's; the app's pick among tied counts follows Swift's Dictionary hash order, which changes "
                   "each launch: " + ', '.join(f'{k} {v}' for k, v in data['majority_ties'].items()))
    sp = data['gateway_spend']
    out += ['', '## Money, time and memory', '',
            f"- Gateway: {sp['calls']} calls, ${sp['charged']:.2f} charged against the cap (estimate ${sp['estimate']:.2f}; "
            f"the gateway's own figure ${sp['gateway'] or 0:.2f} on {sp['gateway_calls']} calls). The ledger is "
            "`rotation-routes/calls.jsonl` in the bench cache.",
            '- Local models\' peak memory (mlx, GB): ' + ', '.join(f"{R[r]['name']} {v}" for r, v in data['mlx_peak_gb'].items()) + '.',
            '- Licences: ' + '; '.join(f'{k}: {v}' for k, v in data['licences'].items()) + '.', '',
            '## Measurement card', '', card, '']
    return '\n'.join(out)
