"""W46.gemini4-hydrogen-96's report: Gemini 4 Hydrogen against the cached Gemini 3.8 Flash and Qwen3.6 27B on the 96.

Run through `ocr_hydrogen96.py report`. Reads saved files only. The readings are each route's own (ocr_pages_export's
`reading`, the bench's per-page table), scored with ocr_panel_score.score on the current truth; intervals are
ocr_panel_score.paired (per-page differences, 95% bootstrap, 10,000 rounds). The hand pages are ocr-hands-rescore's 16,
on the truth after the owner's handwriting sheet. Writes segbench-results/gemini4-hydrogen-96.md, .json and
-groups.csv (scores and counts only; no text).
"""
from __future__ import annotations

import csv
import json
import statistics
import time

import ocr_hydrogen96 as H
import ocr_pages_export as E
import ocr_panel as P
import ocr_panel_score as S
from ocr_card import DRAW_96

LABEL = 'gemini4-hydrogen'
OLD, NONDRAFTER = 'gemini3.8-flash', 'qwen3.6-27b'
TIE = 0.49   # ocr-rerun-noise.md's rule: twice the larger rerun range (Gemini 3.7 Flash, 0.24), or an interval across 0
JAN_PRICE = (1.50, 7.50)   # Gemini 3.8 Flash from 1 Jan 2027, the same as Hydrogen's
OLD_PRICE = (0.75, 3.75)   # 3.8 Flash's introductory price, which its cached cost was billed at


def hydrogen(job):
    got = E.load(H.CACHE / 'low' / (job + '.json'))
    return H.parsed(got), got.get('meta') or {}


def verdict(d):
    if d['lo'] <= 0 <= d['hi'] or abs(100 * d['delta']) < TIE:
        return 'tie'
    return 'ahead' if d['delta'] > 0 else 'behind'


def report():
    kinds = {r['page']: r['kind'] for r in P.rows()}
    pages = sorted(p for p in kinds if p not in P.AGREEMENT)
    truth = {p: (P.TRUTH / 'truth' / (p + '.txt')).read_text() for p in pages}
    hands = json.loads((H.RESULTS / 'ocr-hands-rescore.json').read_text())['pages']
    rows, detail = {}, []
    for p in pages:
        job = p + '-original'
        rr = {LABEL: hydrogen(job), OLD: E.reading(OLD, job), NONDRAFTER: E.reading(NONDRAFTER, job)}
        rows[p] = {}
        for route, (parsed, meta) in rr.items():
            s = S.score(truth[p], parsed['text'] if parsed else '')
            rows[p][route] = {'ok': bool(parsed), 'nes': s['nes'],
                              'kind_right': (parsed or {}).get('kind') == kinds[p] if parsed else None}
            if route == LABEL:
                detail.append({**s, 'ok': bool(parsed), 'kind': kinds[p], 'cost': meta.get('cost', 0)})
    routes = (LABEL, OLD, NONDRAFTER)
    mean = lambda xs: sum(xs) / len(xs) if xs else float('nan')

    def summary(route, ps):
        ans = [p for p in ps if rows[p][route]['ok']]
        return {'pages': len(ps), 'answered': len(ans), 'nes_answered': mean([rows[p][route]['nes'] for p in ans]),
                'nes_all': mean([rows[p][route]['nes'] for p in ps]),
                'kind_right': sum(1 for p in ps if rows[p][route]['kind_right'])}

    def pair(a, b, ps, answered=True):
        both = [p for p in ps if not answered or (rows[p][a]['ok'] and rows[p][b]['ok'])]
        d = S.paired([rows[p][a]['nes'] for p in both], [rows[p][b]['nes'] for p in both])
        return {**d, 'verdict': verdict(d)}

    by_kind = {k: {r: summary(r, [p for p in pages if kinds[p] == k]) for r in routes}
               for k in sorted(set(kinds[p] for p in pages))}
    hand = {r: summary(r, hands) for r in routes}
    calls = [c for c in H.ledger() if c['arm'] == 'low' and c['http'] == 200
             and c['job'].split('-')[0] in set(pages)]
    use = lambda k: sum((c['usage'].get(k) or 0) for c in calls)
    tokens = {'prompt': use('promptTokenCount'), 'output': use('candidatesTokenCount'), 'thinking': use('thoughtsTokenCount')}
    cost = sum(c['cost'] for c in calls)
    old_meta = [E.reading(OLD, p + '-original')[1] for p in pages]
    old_cost = sum(m.get('cost', 0) for m in old_meta)
    out = {'model': H.MODEL, 'model_version_returned': sorted({c['model'] for c in calls}),
           'arm': 'low (thinkingLevel low, temperature 0, 8,192 output tokens, default media resolution)',
           'second_arm': ('not run: the low arm spent $%.4f of the $%.2f cap, and the default (dynamic) thinking is '
                          'expected to spend at least as many thinking tokens as low (not measured), so a second arm of '
                          'the same pages would pass the cap' % (H.spent(), H.CAP)),
           'headline95': {r: mean([rows[p][r]['nes'] for p in pages if p != 'p081' and rows[p][r]['ok']])
                          for r in routes},
           'service_tiers': sorted({c['usage'].get('serviceTier') or '' for c in calls}),
           'all96': {r: summary(r, pages) for r in routes}, 'by_kind': by_kind, 'hands16': hand,
           'paired': {'hydrogen_minus_38': pair(LABEL, OLD, pages), 'hydrogen_minus_qwen': pair(LABEL, NONDRAFTER, pages),
                      'hands_hydrogen_minus_38': pair(LABEL, OLD, hands, answered=False)},
           'tokens': tokens, 'calls': len(calls),
           'cost_96': cost, 'per_1000': 1000 * cost / len(pages),
           'old_per_1000_intro': 1000 * old_cost / len(pages), 'old_per_1000_jan2027': 2000 * old_cost / len(pages),
           'wall_s_median': statistics.median(c['wall_s'] for c in calls),
           'old_wall_s_median': statistics.median(m['wall_s'] for m in old_meta if m.get('wall_s')),
           'item_spent': H.spent(), 'price': H.PRICE, 'read_on': time.strftime('%Y-%m-%d'),
           'pages_detail': rows}
    (H.RESULTS / 'gemini4-hydrogen-96.json').write_text(json.dumps(out, indent=1))
    with (H.RESULTS / 'gemini4-hydrogen-96-groups.csv').open('w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['route', 'attribute', 'value', 'n', 'ok', 'nes', 'chrf', 'miss', 'add', 'words'])
        for k in sorted({d['kind'] for d in detail}):
            g = S.aggregate([d for d in detail if d['kind'] == k])
            w.writerow([LABEL, 'kind', k, g['n'], g['ok'], g['nes'], g['chrf'], g['miss'], g['add'], g['words']])
    (H.RESULTS / 'gemini4-hydrogen-96.md').write_text(markdown(out, S.aggregate(detail), len(pages)))
    print(markdown(out, S.aggregate(detail), len(pages)))


def markdown(o, a, n):
    pct = lambda x: f'{100 * x:.2f}'
    d38, dq, dh = o['paired']['hydrogen_minus_38'], o['paired']['hydrogen_minus_qwen'], o['paired']['hands_hydrogen_minus_38']
    iv = lambda d: (f"{100 * d['delta']:+.2f} NES points on {d['n']} pages (95% bootstrap {100 * d['lo']:+.2f} to "
                    f"{100 * d['hi']:+.2f}; permutation p {d['p']:.3f}): **{d['verdict']}**")
    names = {LABEL: 'Gemini 4 Hydrogen (drafter\'s relative)', OLD: 'Gemini 3.8 Flash (the truth\'s drafter)',
             NONDRAFTER: 'Qwen3.6 27B (non-drafter)'}
    t = o['tokens']
    ahead = d38['verdict'] == 'ahead'
    L = ["# Gemini 4 Hydrogen on the owner's 96 (W46.gemini4-hydrogen-96)", '',
         f"Gemini 4 Hydrogen (`{o['model']}`, returned as {', '.join(o['model_version_returned'])}), read on "
         f"{o['read_on']} through AI Studio's `generateContent` on the personal key (paid tier: every call's "
         f"`serviceTier` was {', '.join(o['service_tiers'])}), with the cloud panel's Gemini 3.8 Flash settings: the same "
         "99 frozen 2,400 px JPEGs, the same prompt, temperature 0, thinking level low, 8,192 output tokens, the API's "
         "default media resolution (`scripts/segbench/ocr_hydrogen96.py`). Gemini 3.8 Flash and Qwen3.6 27B are their "
         "cached cloud-panel readings (W41.ocr-panel-cloud). NES is `ocr_panel_score.score`; the 96 are the 99 settled "
         "jobs less the three agreement letters.", '',
         '## Verdict', '',
         ('Hydrogen resolves ahead of Gemini 3.8 Flash on the 96, so the app\'s default reader may change; that is filed '
          'as its own item.' if ahead else
          f"Hydrogen does not resolve ahead of Gemini 3.8 Flash on the 96 (a {d38['verdict']} under the rerun tie rule, "
          f"{TIE} points or an interval across 0), so the app's default reader stays Gemini 3.8 Flash. From 1 Jan 2027 "
          "the two cost the same per token, so only the reading would separate them."), '',
         f"Per page Hydrogen costs more than the same price suggests: at low thinking it spent "
         f"{o['tokens']['thinking'] / o['calls']:.0f} thinking tokens a page, billed as output, where 3.8 Flash's cached "
         f"calls billed little (10 of its 99 report thinking, 11,206 tokens in all, in the usage fields; the dollar "
         f"figures below count them), so it is ${o['per_1000']:.2f} per 1,000 pages against 3.8's "
         f"${o['old_per_1000_jan2027']:.2f} at the January price (${o['old_per_1000_intro']:.2f} today). It answered "
         f"every page (3.8 Flash refused two printed pages) and named the page kind right more often. The bench's "
         f"headline sets p081 apart (no correctable truth): there 3.8 Flash is 96.47, Hydrogen "
         f"{100 * o['headline95'][LABEL]:.2f} and Qwen3.6 27B {100 * o['headline95'][NONDRAFTER]:.2f}.", '',
         '| | ' + ' | '.join(names[r] for r in (LABEL, OLD, NONDRAFTER)) + ' |', '|---|---:|---:|---:|']
    g = o['all96']
    L += ['| pages answered | ' + ' | '.join(f"{g[r]['answered']}/{g[r]['pages']}" for r in names) + ' |',
          '| NES on the pages answered | ' + ' | '.join(pct(g[r]['nes_answered']) for r in names) + ' |',
          '| NES, all 96 (failure = 0) | ' + ' | '.join(pct(g[r]['nes_all']) for r in names) + ' |',
          '| kind right | ' + ' | '.join(str(g[r]['kind_right']) for r in names) + ' |',
          f"| hand pages, NES (owner-checked 16, failure = 0) | "
          + ' | '.join(pct(o['hands16'][r]['nes_all']) for r in names) + ' |',
          f"| $ per 1,000 pages | ${o['per_1000']:.2f} (billed tokens at list ${o['price'][0]}/${o['price'][1]}) | "
          f"${o['old_per_1000_intro']:.2f} billed at ${OLD_PRICE[0]}/${OLD_PRICE[1]}; "
          f"${o['old_per_1000_jan2027']:.2f} at ${JAN_PRICE[0]}/${JAN_PRICE[1]} from 1 Jan 2027 | (cloud panel) |",
          f"| median seconds a page | {o['wall_s_median']:.1f} | {o['old_wall_s_median']:.1f} | |", '',
          f"- Hydrogen less 3.8 Flash, pages both answered: {iv(d38)}.",
          f"- Hydrogen less Qwen3.6 27B, pages both answered: {iv(dq)}.",
          f"- Hydrogen less 3.8 Flash on the 16 hand pages (failure = 0): {iv(dh)}.", '',
          '| kind | pages | ' + ' | '.join(f'{names[r].split(" (")[0]} NES answered' for r in names) + ' |',
          '|---|---:|---:|---:|---:|']
    for k, v in o['by_kind'].items():
        L.append(f"| {k} | {v[LABEL]['pages']} | " + ' | '.join(
            f"{pct(v[r]['nes_answered'])} ({v[r]['answered']})" for r in names) + ' |')
    L += ['', f"Hydrogen used {t['prompt']:,} input, {t['output']:,} answer and {t['thinking']:,} thinking tokens on "
          f"the 96 ({t['thinking'] / o['calls']:.0f} thinking a page); the 96 cost ${o['cost_96']:.4f}, and the item "
          f"${o['item_spent']:.4f} in all (the 99 jobs and the one-page probe that is the first of them). "
          f"Second arm: {o['second_arm']}.", '',
          '## Original pages (96, excluding the agreement-only letters)', '',
          '| route | completed / attempted / 96 | NES % | chrF2 % | words missed % | words added % | kind right % | cost / page |',
          '|---|---:|---:|---:|---:|---:|---:|---:|',
          f"| {LABEL} · AI Studio, personal key | {a['ok']}/{n}/{n} | {100 * a['nes']:.2f} | {100 * a['chrf']:.2f} | "
          f"{100 * a['miss']:.2f} | {100 * a['add']:.2f} | {round(100 * g[LABEL]['kind_right'] / n)} | "
          f"${o['cost_96'] / n:.5f} (billed tokens at list) |", '',
          '## Measurement card', '',
          '- **Truth.** The adjudicated 96 (`ocr_panel.TRUTH`, with the 2026-10-29 corrections and the owner\'s '
          'handwriting sheet of 2026-10-31). Its drafter is Gemini 3.8 Flash; Hydrogen is a later Gemini, so its row is '
          'a drafter\'s relative and may share the drafter\'s readings where the owner did not check. Qwen3.6 27B is '
          'the non-drafter beside it. The owner checked the 16 hand pages blind (`ocr-hands-rescore.md`).',
          '- **Selection.** The frozen 96; no page chosen by a route or by ABBYY text. ' + DRAW_96,
          '- **Comparison.** The same images, prompt, temperature, thinking level and output cap as 3.8 Flash\'s cloud '
          'panel row; 3.8 went through OpenRouter to Google AI Studio, Hydrogen straight to AI Studio. Only the owner\'s '
          'set was read: the item\'s scope is the 96, and its $2 cap leaves no room for the 895, so the public half is '
          'not run (the "both sets" rule\'s missing half; nothing is filed, since no route waits on it).',
          f"- **Noise.** n = 96, paired page bootstrap; the rerun floor is W46.ocr-rerun-noise's (Gemini 3.7 Flash moved "
          f"0.24 points across identical runs), so a gap under {TIE} points or an interval across 0 is a tie.",
          '- **Scope.** One arm, low thinking; Hydrogen\'s default thinking was not read. Prices are list prices as of '
          'November 2026; the key reports no cost, so the cost is the billed tokens at list.', '']
    return '\n'.join(L)
