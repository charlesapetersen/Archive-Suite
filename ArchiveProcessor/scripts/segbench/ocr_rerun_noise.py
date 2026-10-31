#!/usr/bin/env python3
"""W46.ocr-rerun-noise. How far an OCR route's score on the owner's 96 moves when the same pages are read again.

  python3 ocr_rerun_noise.py gemini --run 1          # Gemini 3.7 Flash, Stanford gateway, a second full reading
  python3 ocr_rerun_noise.py gemini --run 2          # ... and a third
  heavy-run / run-guarded.sh --label mac-local --need-gb 8 -- <lab venv>/bin/python ocr_rerun_noise.py mlx --run 1
  heavy-run / run-guarded.sh ...                       ocr_rerun_noise.py mlx --run 2   # Qwen3-VL 8B 4-bit, MLX
  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy \
      python ocr_rerun_noise.py report                # -> segbench-results/ocr-rerun-noise.{md,json}

Every panel read each page once, yet routes are chosen at 1-2 point gaps (measurement audit OCR-3,
execution-plans/processing-review/11-measurement-audit.md). Each route here is read three times with nothing
changed: run 0 is the reading already in the cache (W46.fix-ocr-scorers-paid's gateway run; W41.mac-local-measure's
MLX run), runs 1 and 2 are new. The Gemini reruns go through gateway_gemini.call, so the request is the 3.7-vs-3.8
check's to the byte (same images, prompt, temperature 0, low reasoning, max_tokens and retry rule); only the cache
directory, and with it the spend ledger and its cap, are this item's. The MLX reruns go through
ocr_mac_local.collect with only its output directory moved. All runs are scored against today's truth, so a truth
fix since run 0 moves every run alike.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]

import gateway_gemini as G  # noqa: E402

NOISE = G.REHEARSAL / 'ocr-rerun-noise'
RUNS = (1, 2)
CAP = 1.50   # this item's gateway total (two readings of the 99 at about $0.39 each); under the $7 rule
ROUTES = {
    'gemini': {'name': 'Gemini 3.7 Flash (Stanford gateway, temperature 0, low reasoning)',
               'run0': G.CACHE / 'panel', 'dir': lambda n: NOISE / 'gemini' / f'run{n}'},
    'mlx': {'name': 'Qwen3-VL 8B 4-bit (mlx-vlm on this Mac, temperature 0)',
            'run0': None, 'dir': lambda n: NOISE / 'mlx' / f'run{n}'},
}


def gemini(n):
    G.CACHE = NOISE / 'gemini'     # the ledger (calls.jsonl) and so the cap are this item's own
    G.CAP = CAP
    # The gateway (LiteLLM) answers a byte-identical request from its response cache: the first run 2 came back in
    # 1.3 s a page with run 1's exact tokens on all 99 (kept as run2-gateway-cached). This body field skips that
    # cache; the request Google sees is unchanged. Run 1 was read before it was known and was live throughout.
    body = G.body
    G.body = lambda image, prompt: {**body(image, prompt), 'cache': {'no-cache': True}}
    m, jobs = G.panel_manifest()
    todo = []
    for j in jobs:
        image = (G.PANEL / 'images' / (j['id'] + '.jpg')).read_bytes()
        if G.hashlib.sha256(image).hexdigest() != j['sha256']:
            raise SystemExit('image changed: ' + j['id'])
        todo.append((j['id'], image, ROUTES['gemini']['dir'](n) / (j['id'] + '.json')))
    G.run(f'rerun{n}', todo, m['prompt'])


def mlx(n):
    import ocr_mac_local as M
    M.OUT = ROUTES['mlx']['dir'](n)
    M.collect()


def readings(route, n):
    """{job id: text or None} for one run of one route."""
    import ocr_mac_local as M
    if route == 'gemini':
        d = ROUTES['gemini']['run0'] if n == 0 else ROUTES['gemini']['dir'](n)
        out = {}
        for j in G.panel_manifest()[1]:
            f = d / (j['id'] + '.json')
            p = G.parsed(json.loads(f.read_text())) if f.exists() else None
            out[j['id']] = p['text'] if p else None
        return out
    d = M.OUT if n == 0 else ROUTES['mlx']['dir'](n)
    out = {}
    for j in M.jobs():
        _, p = M.load_reading(d / (j['id'] + '.json'))
        out[j['id']] = p['text'] if p else None
    return out


def report():
    import ocr_panel as P
    import ocr_panel_score as S
    import ocr_mac_local as M
    kind = {r['page']: r['kind'] for r in P.rows()}
    mean = lambda xs: sum(xs) / len(xs) if xs else float('nan')
    out = {'item': 'W46.ocr-rerun-noise', 'routes': {}}
    for route, spec in ROUTES.items():
        jobs = {j['id']: j['page'] for j in (G.panel_manifest()[1] if route == 'gemini' else M.jobs())}
        jobs = {i: p for i, p in jobs.items() if p not in P.AGREEMENT}
        runs = {}
        for n in (0, *RUNS):
            texts = readings(route, n)
            runs[n] = {jobs[i]: {'ok': texts.get(i) is not None,
                                 'text': texts.get(i),
                                 'nes': S.score((P.TRUTH / 'truth' / (jobs[i] + '.txt')).read_text(), texts.get(i) or '')['nes']}
                       for i in jobs}
        have = [n for n in runs if sum(r['ok'] for r in runs[n].values())]
        pages = sorted(jobs.values())

        def summary(sel):
            per = {}
            for n in have:
                rr = [runs[n][p] for p in sel]
                per[n] = {'read': sum(r['ok'] for r in rr), 'strict': mean([r['nes'] for r in rr]),
                          'answered': mean([r['nes'] for r in rr if r['ok']])}
            sp = {}
            for m in ('strict', 'answered'):
                v = [per[n][m] for n in have]
                sp[m] = {'range': max(v) - min(v), 'sd': statistics.stdev(v) if len(v) > 1 else 0.0}
            return {'pages': len(sel), 'runs': per, 'spread': sp}

        res = {'name': spec['name'], 'runs_scored': have, 'all': summary(pages),
               'by_kind': {k: summary([p for p in pages if kind[p] == k]) for k in sorted({kind[p] for p in pages})}}
        pairs = {}
        for a in have:
            for b in have:
                if a < b:
                    both = [p for p in pages if runs[a][p]['ok'] and runs[b][p]['ok']]
                    pairs[f'{b}-{a}'] = {
                        'strict': S.paired([runs[b][p]['nes'] for p in pages], [runs[a][p]['nes'] for p in pages]),
                        'answered': S.paired([runs[b][p]['nes'] for p in both], [runs[a][p]['nes'] for p in both]),
                        'identical_text': sum(1 for p in pages if runs[a][p]['text'] == runs[b][p]['text']),
                        'mean_abs_page': mean([abs(runs[b][p]['nes'] - runs[a][p]['nes']) for p in both]),
                        'max_abs_page': max([abs(runs[b][p]['nes'] - runs[a][p]['nes']) for p in both], default=0.0),
                        'flipped_failure': sum(1 for p in pages if runs[a][p]['ok'] != runs[b][p]['ok'])}
        res['pairs'] = pairs
        res['tie_threshold'] = 2 * max(res['all']['spread']['strict']['range'], res['all']['spread']['answered']['range'])
        res['pages_detail'] = {p: {n: (round(runs[n][p]['nes'], 5) if runs[n][p]['ok'] else None) for n in have}
                               for p in pages}
        out['routes'][route] = res
    calls = [json.loads(x) for x in (NOISE / 'gemini/calls.jsonl').read_text().splitlines()] \
        if (NOISE / 'gemini/calls.jsonl').exists() else []
    out['gateway_cost_estimate'] = sum(c.get('cost', 0) for c in calls)
    out['gateway_calls'] = len(calls)
    (G.RESULTS / 'ocr-rerun-noise.json').write_text(json.dumps(out, indent=1))
    write_md(out)


def write_md(out):
    pt = lambda x: f'{100 * x:.2f}'
    L = ['# OCR rerun noise on the owner\'s 96 (W46.ocr-rerun-noise)', '',
         'Each route read the same 96 scored pages (the 99 settled jobs less the three agreement-only letters) three '
         'times with nothing changed: the same images, prompt, temperature 0 and settings. Run 0 is the reading already '
         'in the bench (Gemini: W46.fix-ocr-scorers-paid on 2026-10-23; Qwen: W41.mac-local-measure), runs 1 and 2 were '
         'read for this item on 2026-10-30. NES is the panel\'s score (`ocr_panel_score.score`) against today\'s truth. '
         '**Strict** counts a failed page as 0; **answered** averages the pages that run answered. Reproduce: '
         '`ArchiveProcessor/scripts/segbench/ocr_rerun_noise.py`.', '']
    for route, r in out['routes'].items():
        a = r['all']
        L += [f"## {r['name']}", '', '| run | pages read | NES strict | NES answered |', '|---|---:|---:|---:|']
        for n, v in a['runs'].items():
            L.append(f"| {n} | {v['read']}/{a['pages']} | {pt(v['strict'])} | {pt(v['answered'])} |")
        L += ['', f"Run-to-run spread of the 96-page mean: strict range {pt(a['spread']['strict']['range'])} points "
              f"(SD {pt(a['spread']['strict']['sd'])}), answered range {pt(a['spread']['answered']['range'])} points "
              f"(SD {pt(a['spread']['answered']['sd'])}).", '',
              '| runs | identical page texts | failure flips | mean / max page move (answered) | paired Δ strict (95% CI) | paired Δ answered (95% CI) |',
              '|---|---:|---:|---:|---:|---:|']
        for k, v in r['pairs'].items():
            s, w = v['strict'], v['answered']
            L.append(f"| {k} | {v['identical_text']}/{a['pages']} | {v['flipped_failure']} | "
                     f"{pt(v['mean_abs_page'])} / {pt(v['max_abs_page'])} | "
                     f"{100 * s['delta']:+.2f} ({100 * s['lo']:+.2f} to {100 * s['hi']:+.2f}) | "
                     f"{100 * w['delta']:+.2f} ({100 * w['lo']:+.2f} to {100 * w['hi']:+.2f}, n {w['n']}) |")
        L += ['', '| kind | pages | strict mean per run | strict range | answered range |', '|---|---:|---|---:|---:|']
        for k, v in r['by_kind'].items():
            L.append(f"| {k} | {v['pages']} | {' / '.join(pt(x['strict']) for x in v['runs'].values())} | "
                     f"{pt(v['spread']['strict']['range'])} | {pt(v['spread']['answered']['range'])} |")
        L.append('')
    rng = {k: r['tie_threshold'] / 2 for k, r in out['routes'].items()}
    L +=['## The tie rule', '',
          'A gap between two routes on the 96 is a **tie** when it is under twice the larger rerun range of the routes '
          'compared (strict or answered, whichever is quoted), or when its paired 95% interval crosses 0. Both tests '
          'apply: the rerun range catches the route\'s own instability, the paired interval catches page-sampling '
          'noise, which a deterministic route still has. Twice the range measured here: '
          + ', '.join(f"{out['routes'][k]['name'].split(' (')[0]} {2 * 100 * v:.2f} points" for k, v in rng.items())
          + '. A route with no rerun of its own takes the larger of these (a hosted model is held to Gemini\'s, a '
          'local greedy one to Qwen\'s) until it is measured. Per kind, the kind\'s own range applies; a kind of a '
          'dozen pages moves far more than the whole.', '',
          f"Gateway spend: {out['gateway_calls']} calls, about ${out['gateway_cost_estimate']:.2f} at Gemini 3.8 Flash's "
          'list rate (an estimate; the gateway does report its own figure in an `x-litellm-response-cost` header, '
          'which `gateway_gemini.py` does not yet record), Stanford PTA. The MLX runs cost nothing.', '',
          '**The gateway caches.** It is LiteLLM, and it answers a byte-identical request from a response cache: the '
          'first run 2 came back in a median 1.3 s a page (run 1: 8.0 s) with run 1\'s exact text and tokens on all 99, '
          'a copy, not a reading. It is kept aside (`run2-gateway-cached`) and run 2 was read again with the body field '
          '`"cache": {"no-cache": true}`, which skips it (median 7.1 s; the request Google sees is unchanged). Run 1 was '
          'read before this was known; it was live throughout (no call under 2.7 s, its 22 texts that match run 0 took '
          '3-15 s). Any gateway arm that repeats a request, a retry included, should send that field.', '',
          '## Measurement card', '',
          '- **Truth:** the 96\'s adjudicated truth, the panel\'s (`ocr_truth`), read today for every run. The figure is '
          'the difference between runs of one route against one fixed truth, so a bias in the truth toward a drafter '
          'moves every run of that route alike and cancels; it does not cancel in a gap between two routes, which is '
          'what `ocr-truth-bias.md` addresses.',
          '- **Selection:** none: all 96 scored pages, every run.',
          '- **Comparison:** the same images, prompt, temperature, reasoning and token cap within each route. Only the '
          'gateway cache field differs (run 2), and it never reaches the model. Run 0 of Gemini was read on 2026-10-23, '
          'runs 1 and 2 on 2026-10-30, so 1-0 and 2-0 can include a provider change in that week; 2-1 is the same-day '
          'pair. The public 895 were not reread (the item measures the 96, where routes are chosen).',
          '- **Noise:** this is the noise figure. Three runs make the range a rough estimate in its own right (a fourth '
          'run would likely widen it), and the per-kind ranges rest on 2-50 pages; the 2 mixed pages are anecdote.',
          '- **Scope:** two routes. Other hosted models, other temperatures and other local runtimes are not measured; '
          'the rule above lends them these figures until they are. It says nothing about the 895.', '']
    (G.RESULTS / 'ocr-rerun-noise.md').write_text('\n'.join(L))
    print('\n'.join(L))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['gemini', 'mlx', 'report'])
    ap.add_argument('--run', type=int, choices=RUNS)
    a = ap.parse_args()
    if a.command in ('gemini', 'mlx') and not a.run:
        ap.error('--run 1 or 2')
    {'gemini': lambda: gemini(a.run), 'mlx': lambda: mlx(a.run), 'report': report}[a.command]()


if __name__ == '__main__':
    main()
