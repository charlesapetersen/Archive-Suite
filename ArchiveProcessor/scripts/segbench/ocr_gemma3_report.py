#!/usr/bin/env python3
"""W46.ocr-gemma3-12b. The report: Gemma 3 12B 4-bit on the Mac, on the owner's 96 and the 895 public pages.

  python3 ocr_rescore.py --merge gemma3-12b-mlx4                          # its 96 rows into ocr-scorers
  python3 ocr_rescore.py --merge gemma3-12b-mlx4 --merge-set public895    # its 895 rows (both under uv run, as there)
  python3 ocr_gemma3_report.py                                            # segbench-results/ocr-gemma3-12b.{md,json}

Reads saved files only: the bench's per-page scores (ocr-scorers-pages.csv, every route through one scorer), the
readings' timing and memory (ocr_mac_local's meta per page) and the memory guard's whole-process rows. NES strict
counts a failed page (a reading cut off at the token cap, or a reply the panel's parser cannot read) as 0;
answered is over the pages it read. Comparisons are paired on the pages both routes have, with the bench's
bootstrap interval and permutation p (ocr_panel_score.paired).
"""
from __future__ import annotations

import collections
import csv
import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import ocr_mac_local as M        # noqa: E402
import ocr_gemma3_public as G    # noqa: E402
import ocr_panel as P            # noqa: E402
import ocr_panel_score as S      # noqa: E402
import routes as R               # noqa: E402

KEY = G.KEY
RESULTS = HERE.parents[1] / 'segbench-results'
PAGES = RESULTS / 'ocr-scorers-pages.csv'
OUT_MD, OUT_JSON = RESULTS / 'ocr-gemma3-12b.md', RESULTS / 'ocr-gemma3-12b.json'
# The routes it is paired with on each set: Apple Vision (the app's on-computer reader today), the other Mac-local
# readers, the open readers run on a cluster where the Mac has no 895 reading, and the gateway default for scale.
COMPARE = {
    'owner96': [('apple-vision', 'Apple Vision (Mac)'), ('qwen3-vl-8b-mlx4', 'Qwen3-VL 8B 4-bit (Mac)'),
                ('qwen3.5-9b-mlx4', 'Qwen3.5-9B 4-bit (Mac)'), ('lightonocr-3-4b-mlx8', 'LightOnOCR-3 4B 8-bit (Mac)'),
                ('paddleocr-vl1.6-bf16', 'PaddleOCR-VL 1.6 bf16 (Mac)'), ('xiaomi-ocr-0-bf16', 'Xiaomi-OCR-0 bf16 (Mac)'),
                ('gemini3.7-flash-gw', 'Gemini 3.7 Flash (gateway, cloud)')],
    'public895': [('apple-vision', 'Apple Vision (Mac)'), ('qwen3-vl-8b', 'Qwen3-VL 8B bf16 (FarmShare)'),
                  ('lightonocr3-4b', 'LightOnOCR-3 4B bf16 (FarmShare)'), ('paddleocr-vl1.6', 'PaddleOCR-VL 1.6 (Sherlock)'),
                  ('xiaomi-ocr-0', 'Xiaomi-OCR-0 (Sherlock)'), ('gemini3.7-flash-gw', 'Gemini 3.7 Flash (gateway, cloud)')],
}
# Owner, 2026-11-26 walkthrough (option a): collection stopped at the pages already read, since the memory guard
# refused or killed seven resumes while the 9 GB model loaded beside the owner's apps.
PARTIAL_895 = ('The run read in the corpus\'s run order, which interleaves the strata, so the pages read cover every '
               'stratum and all 18 sources; collection stopped there by the owner\'s call (2026-11-26) after the memory '
               'guard refused or killed seven resumes while the 9 GB model loaded. The pairs below are on those pages.')
SET_NAME = {'owner96': "the owner's 96", 'public895': 'the 895 public pages'}


def page_scores():
    """{set: {route: {page: (nes, ok, stratum)}}} from the bench's per-page file."""
    out = collections.defaultdict(lambda: collections.defaultdict(dict))
    with PAGES.open(newline='') as f:
        for r in csv.DictReader(f):
            if r['set'] in COMPARE:
                out[r['set']][r['route']][r['page']] = (float(r['nes']), r['ok'] == 'True', r['stratum'])
    return out


def metas():
    """{set: {page: meta}}: the 96 keyed like the scores (p001), the 895 by job id."""
    own = {}
    for j in M.jobs():
        if j['page'] not in P.AGREEMENT:
            m, _ = M.load_reading(M.out_dir(KEY) / (j['id'] + '.json'))
            if m:
                own[j['page']] = m
    pub = {jid: m for jid, (m, _) in G.readings().items()}
    return {'owner96': own, 'public895': pub}


def reading_file(which, page):
    return (M.out_dir(KEY) / f'{page}-original.json') if which == 'owner96' else (G.OUT / f'{page}.json')


def lenient(which, scores):
    """{page: NES} as an app with this loop stop would read: a looped page scored on what it read before the loop, a
    page whose reply broke the format on its text after `TEXT:`, every other page as scored."""
    if which == 'owner96':
        truth = lambda p: (P.TRUTH / 'truth' / f'{p}.txt').read_text()
    else:
        R.MANIFEST = R.RESULTS / 'manifest.jsonl'
        by = {R.job_id(r): r for r in R.frozen()}
        truth = lambda p: Path(by[p]['truth']).read_text()
    out = {}
    for p, (nes, ok, stratum) in scores.items():
        f = reading_file(which, p)
        got = json.loads(f.read_text()) if f.exists() else {}
        text = None
        if not ok and got.get('before_loop'):
            text = got['before_loop']['text']
        elif not ok and got.get('meta', {}).get('finish') == 'stop':
            text = M.lenient_text(f)
        out[p] = S.score(truth(p), text, stratum)['nes'] if text else nes
    return out


def groups(which):
    """{page: group label}: the 96's page kinds, the 895's strata with their sources and scripts."""
    if which == 'owner96':
        return {r['page']: r['kind'] for r in P.rows() if r['page'] not in P.AGREEMENT}
    R.MANIFEST = R.RESULTS / 'manifest.jsonl'
    fr = R.frozen()
    src = collections.defaultdict(set)
    for r in fr:
        src[r['stratum']].add(f"{r['source']}, {r['script']}")
    return {R.job_id(r): f"{r['stratum']} ({'; '.join(sorted(src[r['stratum']]))})" for r in fr}


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]


def mean(xs):
    return sum(xs) / len(xs) if xs else float('nan')


def f1(x):
    return '–' if x != x else f'{100 * x:.1f}'


def guard(label):
    return [r for r in M.guard_rows() if r[1] == label]


def summarise(scores, meta, which):
    g = scores.get(KEY, {})
    n_pages = {'owner96': 96, 'public895': 895}[which]
    fails = collections.Counter()
    for m in meta.values():
        if m.get('status') != 'ok':
            fails[{'length': 'token cap', 'loop': 'loop stop'}.get(m.get('finish'), 'reply format')] += 1
    rows = list(g.values())
    s = {'pages': n_pages, 'read': len(meta), 'ok': sum(ok for _, ok, _ in rows), 'failures': dict(fails),
         'strict': mean([v for v, _, _ in rows]), 'answered': mean([v for v, ok, _ in rows if ok]),
         'lenient': mean(list(lenient(which, g).values()))}
    wall = [m['wall_s'] for m in meta.values()]
    if wall:
        s['speed'] = {'wall_median': statistics.median(wall), 'wall_p90': pct(wall, .9), 'wall_max': max(wall),
                      'wall_total_h': sum(wall) / 3600,
                      'first_token_median': statistics.median(m['first_token_s'] for m in meta.values()),
                      'gen_tps_median': statistics.median(m['gen_tps'] for m in meta.values()),
                      'prompt_tokens_median': statistics.median(m['prompt_tokens'] for m in meta.values()),
                      'completion_median': statistics.median(m['completion_tokens'] for m in meta.values()),
                      'completion_p90': pct([m['completion_tokens'] for m in meta.values()], .9),
                      'mlx_peak_median': statistics.median(m['mlx_peak_gb'] for m in meta.values()),
                      'mlx_peak_max': max(m['mlx_peak_gb'] for m in meta.values()),
                      'load_s_median': statistics.median(m['load_s'] for m in meta.values()),
                      'runtime': next(iter(meta.values()))['runtime']}
    comps = []
    for route, name in COMPARE[which]:
        other = scores.get(route, {})
        both = sorted(set(g) & set(other))
        if not both:
            continue
        d = S.paired([g[p][0] for p in both], [other[p][0] for p in both])
        comps.append({'route': route, 'name': name, 'n': len(both), 'gemma': mean([g[p][0] for p in both]),
                      'other': mean([other[p][0] for p in both]), 'other_ok': sum(other[p][1] for p in both),
                      'gemma_ok': sum(g[p][1] for p in both), **{k: d[k] for k in ('delta', 'lo', 'hi', 'p')}})
    s['compare'] = comps
    lab = groups(which)
    by = collections.defaultdict(list)
    for p in g:
        by[lab.get(p, '?')].append(p)
    s['groups'] = []
    for k in sorted(by):
        pp = by[k]
        row = {'group': k, 'n': len(pp), 'ok': sum(g[p][1] for p in pp), 'gemma': mean([g[p][0] for p in pp])}
        for route, _ in COMPARE[which]:
            other = scores.get(route, {})
            both = [p for p in pp if p in other]
            if both and len(both) == len(pp):
                row[route] = mean([other[p][0] for p in both])
        s['groups'].append(row)
    return s


def speed_lines(sp, label):
    gr = guard(label)
    L = ['| measure | median | 90th percentile | max |', '|---|---:|---:|---:|',
         f"| seconds a page (prompt + generation) | {sp['wall_median']:.1f} | {sp['wall_p90']:.1f} | {sp['wall_max']:.1f} |",
         f"| seconds to first token (image encoding + prefill) | {sp['first_token_median']:.1f} | – | – |",
         f"| generation tokens/s | {sp['gen_tps_median']:.1f} | – | – |",
         f"| input tokens (image + prompt) | {sp['prompt_tokens_median']:.0f} | – | – |",
         f"| output tokens | {sp['completion_median']:.0f} | {sp['completion_p90']:.0f} | – |",
         f"| MLX peak memory, GB | {sp['mlx_peak_median']:.2f} | – | {sp['mlx_peak_max']:.2f} |", '']
    if gr:
        L += ['Memory guard whole-process rows for these runs (date, exit, seconds, peak RSS MB, peak physical footprint '
              'MB, swap growth MB, worst pressure level):', '']
        L += [f"- {' · '.join(r[i] for i in (0, 2, 3, 4, 5, 6, 7))}" for r in gr] + ['']
    return L


def main():
    scores, meta = page_scores(), metas()
    out = {w: summarise(scores[w], meta[w], w) for w in COMPARE}
    out['build'] = {'repo': 'mlx-community/gemma-3-12b-it-4bit', 'revision': '86cc6a8dedbc456dd0e4af01a9d09f396f77e558',
                    'prompt': 'the OCR panel prompt (ocr_panel.PROMPT)', 'max_tokens': P.MAX_TOKENS, 'temperature': 0,
                    'image': f'{P.SIDE} px JPEG q90, resized by the model processor', 'machine': 'Apple M3 Pro, 18 GB'}
    OUT_JSON.write_text(json.dumps(out, indent=1))
    o, u = out['owner96'], out['public895']
    L = ['# W46.ocr-gemma3-12b — Gemma 3 12B 4-bit for whole pages on our Mac', '',
         "The Processor's box and folder label reader (`mlx-community/gemma-3-12b-it-4bit` at revision `86cc6a8d`, the "
         "build `ManagedGemmaWorker.py` pins, through mlx-vlm), asked to transcribe whole pages with the OCR panel's "
         f"prompt, {P.MAX_TOKENS:,} output tokens and temperature 0: the same request Qwen3-VL 8B and Qwen3.5-9B answered "
         "on this Mac. The inputs are the bench's frozen 2,400 px JPEGs on both sets. Every score is the bench's own "
         "(`ocr-scorers-pages.csv`, `ocr_rescore.py`), so the figures sit beside every other route. No money.", '',
         'Reproduce: `ocr_mac_local.py collect --model gemma3-12b-mlx4` (the 96) and `ocr_gemma3_public.py prepare` then '
         '`collect` (the 895), each under `heavy-run.py run -- run-guarded.sh`; then `ocr_rescore.py --merge '
         'gemma3-12b-mlx4` with and without `--merge-set public895`, and `ocr_gemma3_report.py`. Raw text stays in the '
         'private cache.', '',
         '## Accuracy and completion', '',
         '| set | pages | read | completed | failed: loop stop | failed: token cap | failed: reply format | NES strict % | '
         'NES answered % | NES lenient % |', '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|']
    for w, s in (('owner96', o), ('public895', u)):
        f = s['failures']
        L.append(f"| {SET_NAME[w]} | {s['pages']} | {s['read']} | {s['ok']} | {f.get('loop stop', 0)} | {f.get('token cap', 0)} | "
                 f"{f.get('reply format', 0)} | {f1(s['strict'])} | {f1(s['answered'])} | {f1(s['lenient'])} |")
    L += ['', '**Loop stop.** A greedy reading that falls into a loop runs to the 8,192-token cap, about nine minutes a '
          'page here, which made the full run impractical (the pilot\'s third page did exactly that). So a reading stops '
          'once its last 1,024 tokens repeat, token for token, a cycle of at most 256 tokens '
          '(`ocr_mac_local.loop_period`), and counts as failed, as it would at the cap. Over the 907 finished readings '
          'of the other Mac-local readers (granite-docling apart) the rule never fires, so it does not end a reading '
          'that would have finished. **Lenient** scores a looped page on what it read before the loop and a '
          'format-broken reply on its text after `TEXT:`, which is what an app with this stop would keep; '
          '**strict** counts both as 0, as every other route on the bench is counted.']
    for w, s in (('owner96', o), ('public895', u)):
        if s['read'] < s['pages']:
            L += ['', f"**Partial sample on {SET_NAME[w]}: {s['read']} of {s['pages']} pages read.** Figures cover those "
                  'only. ' + (PARTIAL_895 if w == 'public895' else '')]
    for w, s in (('owner96', o), ('public895', u)):
        L += ['', f"## Paired with other routes on {SET_NAME[w]}", '',
              'Gemma less the other route, NES points on the pages both have; failures count 0 on both sides.', '',
              '| route | pages | completed (other) | other NES % | Gemma NES % | Gemma − other | 95% interval | p |',
              '|---|---:|---:|---:|---:|---:|---:|---:|']
        for c in s['compare']:
            L.append(f"| {c['name']} | {c['n']} | {c['other_ok']} | {f1(c['other'])} | {f1(c['gemma'])} | "
                     f"{100 * c['delta']:+.2f} | {100 * c['lo']:+.2f} to {100 * c['hi']:+.2f} | {c['p']:.3f} |")
        cols = [(r, n) for r, n in COMPARE[w] if any(r in g for g in s['groups'])]
        L += ['', f"By {'page kind' if w == 'owner96' else 'stratum'} (NES %, strict; a route shown only where it has "
              'every page of the group):', '',
              '| group | n | Gemma completed | Gemma | ' + ' | '.join(n.split(' (')[0] for _, n in cols) + ' |',
              '|---|---:|---:|---:|' + '---:|' * len(cols)]
        for g in s['groups']:
            L.append(f"| {g['group']} | {g['n']} | {g['ok']} | {f1(g['gemma'])} | "
                     + ' | '.join(f1(g[r]) if r in g else '–' for r, _ in cols) + ' |')
    for w, s, label in (('owner96', o, 'mac-local-gemma3-12b-mlx4'), ('public895', u, 'mac-local-gemma3-public')):
        if 'speed' in s:
            sp = s['speed']
            L += ['', f"## Speed and memory on {SET_NAME[w]}", '',
                  f"{s['read']} pages, one at a time, on an Apple M3 Pro with 18 GB ({sp['runtime']}; "
                  f"{sp['load_s_median']:.0f} s median model load). Total reading time {sp['wall_total_h']:.1f} h.", '']
            L += speed_lines(sp, label)
    L += assessment(o, u)
    from ocr_card import card, TRUTH_96, NOISE_96, DRAW_96
    L += ['', *card(
        TRUTH_96 + ' The 895: each public dataset\'s own ground truth, frozen with the set (W43.corpus-build); not '
        'drafted by any scored route, not checked by the owner.',
        f"All 96 accuracy pages and {u['read']} of the 895 frozen public pages, one reading each; none chosen by a "
        "route's reading or by ABBYY text. The public pages are the first read in the corpus's run order, which "
        "interleaves the strata, so every stratum and source is present but at uneven shares of its full count; the "
        "rest were not read (owner, 2026-11-26), so the public figures are a partial sample, not the 895. " + DRAW_96,
        'The same request on both sets: the pinned build, the panel prompt, 8,192 tokens, temperature 0, the loop stop '
        'above and the same '
        '2,400 px JPEGs every route on the bench read (the 455 public images remade by the same encoder). Every route '
        'is scored by the one scorer; failures count 0 on both sides of a pair. Apple Vision has 320 of the 895 '
        '(its Latin strata), so its pairs there are on those. Speed and memory are one M3 Pro with 18 GB, one page '
        'at a time, with the owner\'s usual apps open.',
        f"n = 96 and {u['read']} (of 895), paired per page with a bootstrap interval. Greedy local decoding is deterministic on one "
        "machine (`ocr-rerun-noise.md`). " + NOISE_96 + ' Speed and memory are one run of each page.',
        'One model at one quantisation and one prompt, on this Mac. Gemma 3\'s vision encoder sees each page at its '
        'fixed 896 px square, whatever the input size, so this measures that build as the Processor ships it, not '
        'Gemma 3 with tiled input. It does not settle a route for labels, which `ct-gemma-route-fields.md` measured.')]
    OUT_MD.write_text('\n'.join(L).rstrip('\n') + '\n')
    print(f"report: 96 {o['read']} read, {f1(o['strict'])} strict; 895 {u['read']} read, {f1(u['strict'])} strict")


def assessment(o, u):
    """The plain-words verdict on the app's on-computer page OCR, from the figures above."""
    vis = {w: next((c for c in s['compare'] if c['route'] == 'apple-vision'), None) for w, s in (('owner96', o), ('public895', u))}
    best = max((c for c in o['compare'] if c['route'] not in ('apple-vision', 'gemini3.7-flash-gw')),
               key=lambda c: c['other'], default=None)
    L = ['', "## Is it a candidate for the app's on-computer page OCR?", '']
    for w in ('owner96', 'public895'):
        c = vis[w]
        if c:
            tie = c['lo'] <= 0 <= c['hi']
            L.append(f"- Against Apple Vision on {SET_NAME[w]} ({c['n']} pages): Gemma {f1(c['gemma'])} against "
                     f"{f1(c['other'])}, {100 * c['delta']:+.2f} points ({'a tie' if tie else 'better' if c['delta'] > 0 else 'worse'}).")
    if best:
        L.append(f"- Against the best Mac-local reader on the 96, {best['name']}: Gemma {f1(best['gemma'])} against "
                 f"{f1(best['other'])}, {100 * best['delta']:+.2f} points.")
    if 'speed' in o:
        L.append(f"- Speed: a median {o['speed']['wall_median']:.0f} s a page on the 96, so 102k pages would be about "
                 f"{102000 * o['speed']['wall_median'] / 86400:.0f} days of continuous reading; Apple Vision reads a page "
                 "in about a second.")
    L.append(f"- Verdict: not a candidate. It loses to Apple Vision by a wide margin on both sets, fails "
             f"{o['pages'] - o['ok']} of the 96 and {u['read'] - u['ok']} of {u['read']} public pages (mostly loops), "
             "and is slower; the public figures are a partial sample, but a gap this size would not close on the rest.")
    return L


if __name__ == '__main__':
    main()
