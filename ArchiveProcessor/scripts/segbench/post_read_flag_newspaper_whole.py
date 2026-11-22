#!/usr/bin/env python3
"""W49.proc-read-flag-newspaper-whole: a partner for the read-poorly flag on a newspaper scan read whole.

  python3 ops/autonomous/heavy-run.py run -- python3 ArchiveProcessor/scripts/segbench/post_read_flag_newspaper_whole.py vision
  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy --with python-Levenshtein \
      python ArchiveProcessor/scripts/segbench/post_read_flag_newspaper_whole.py report
  python3 ArchiveProcessor/scripts/segbench/post_read_flag_newspaper_whole.py self-test

THE QUESTION. W49.proc-read-flag-newspaper found that Apple Vision reads a whole newspaper scan at 21.8 strict NES, so
the app's four mapped thresholds flag 25 of 32 good whole-page answers in a replay against Vision's whole-page
text in order. Since W47.wh-whole-page-large Qwen3.6 27B reads every newspaper whole, so that
is its normal path. Which Vision partner keeps the flag on a whole reading, and at what cut?

THE PARTNERS. Vision reads pieces of the same image, and the pieces' lines are joined; the whole reading's order is
not the pieces', so the comparisons that matter are order-free (NewsBench's bag-of-words F1, which counts repeats):
  pp, yolo     the PP-DocLayoutV3 crops (the app's detector, PaddleOCR-VL's raw order) or DocLayout-YOLO's, as read
               for W49.proc-read-flag-newspaper (cached; no new Vision read).
  tiles NxN    the page cut into an N x N grid of equal tiles, no overlap (a word on a cut can be split or lost on
               both sides); needs no layout model, so it also covers a page the detector failed on.
Each partner gives two risks (higher = more likely poor): `<partner> bow` = 1 - bag-of-words F1, and `<partner> nes` =
1 - NES in the partner's order (for contrast: order counts against the reading). The baseline is today's check,
`whole nes` (1 - NES against Vision's whole page). Failed requests contribute no disagreement warnings.

THE LABEL. Poor under 70 strict NES against the truth, as the fit (post_read_flag.POOR); also the order-free label,
poor under 70 bag-of-words F1 (content lost rather than order). A false alarm is a flag on a reading at or above 70;
the ceiling is 5% of those (post_read_flag.CEILING).

THE READINGS. The 168 whole-page readings of the 15 scored L9 scans that W49.proc-read-flag-newspaper scored (its
`readings()`: 10 NewsBench systems, the bench's PaddleOCR-VL 1.6 on this Mac, Gemini 3.7 Flash's 3 gateway pages).
Qwen3.6 27B's own whole readings are not on this Mac (FarmShare's run kept only scores), so the reader whose path
this is is not among them.

THE FITS. Pooled over answered readings: in-sample, cross-validated by page (5-fold, 20 seeds, a page in one fold), and
leave one system out. Writes score-only files: segbench-results/post-read-flag-newspaper-whole.{md,json}.
"""
from __future__ import annotations

import argparse
import json
import statistics as st
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import post_read_flag as F                # noqa: E402  (stdlib only at import)
import post_read_flag_newspaper as N      # noqa: E402

WORK = N.WORK / 'whole'
RESULTS = N.RESULTS
OUT_MD = RESULTS / 'post-read-flag-newspaper-whole.md'
OUT_JSON = RESULTS / 'post-read-flag-newspaper-whole.json'
GRIDS = (2, 3, 4)
PARTNERS = ('pp', 'yolo') + tuple(f'tiles {g}x{g}' for g in GRIDS)
SIGNALS = ('whole nes', 'whole bow') + tuple(f'{p} {m}' for p in PARTNERS for m in ('bow', 'nes'))
# The partner and cut recommended for the app: Vision on a 3 x 3 grid, order-free. Its fitted cut (0.163) sits just
# under the largest good reading's risk (0.173); 0.20 leaves that margin and still catches every content-poor reading.
# Chosen after looking at the cut grid, so its in-sample figures are not a held-out estimate.
RECOMMENDED = ('tiles 3x3 bow', 0.20)


def tiles(w, h, g):
    """The N x N grid's pixel boxes (x0, y0, x1, y1), row by row; the last row and column take the remainder."""
    xs = [round(w * i / g) for i in range(g + 1)]
    ys = [round(h * i / g) for i in range(g + 1)]
    return [(xs[c], ys[r], xs[c + 1], ys[r + 1]) for r in range(g) for c in range(g)]


def tile_path(g, page, i):
    return WORK / 'tiles' / f'{g}x{g}' / page / f'{i:03d}.png'


def tile_lines_path(g, page, i):
    return WORK / 'lines' / f'{g}x{g}' / page / f'{i:03d}.json'


def vision():
    import vision_guard
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    rows = []
    for p in N.l9_pages():
        img = N.FROZEN / 'L9' / f'{p}.jpg'
        opened = None
        for g in GRIDS:
            w, h = Image.open(img).size
            for i, box in enumerate(tiles(w, h, g)):
                dest, lines = tile_path(g, p, i), tile_lines_path(g, p, i)
                if not lines.exists():
                    if not dest.exists():
                        opened = opened or Image.open(img).convert('RGB')
                        dest.parent.mkdir(parents=True, exist_ok=True)
                        opened.crop(box).save(dest)
                    lines.parent.mkdir(parents=True, exist_ok=True)
                    rows.append((dest, lines))
    print(f'{len(rows)} tiles for Vision', flush=True)
    for k in range(0, len(rows), N.BATCH):
        jobs = WORK / 'lines-jobs.tsv'
        jobs.write_text(''.join(f'{a}\t{b}\n' for a, b in rows[k:k + N.BATCH]))
        vision_guard.run(N.BIN, jobs, 'lines')
        print(f'batch {k // N.BATCH + 1}: {min(k + N.BATCH, len(rows))} of {len(rows)}', flush=True)


def partner_texts(page):
    """{partner: Vision's text of the page's pieces, joined in the partner's order}."""
    out = {}
    for geom in ('pp', 'yolo'):
        out[geom] = '\n\n'.join('\n'.join(c) for c in N.crop_vision(geom, page) if c)
    for g in GRIDS:
        parts = []
        for i in range(g * g):
            parts.append('\n'.join(l['text'] for l in N.vision_lines(tile_lines_path(g, page, i))))
        out[f'tiles {g}x{g}'] = '\n\n'.join(t for t in parts if t.strip())
    return out


def score_all():
    import ocr_panel_score as S
    import ocr_scorers as O
    import re
    ill = re.compile(r'\[illegible\]', re.I)
    reads = [r for r in N.readings(l9_only=True) if r['set'] == 'L9' and r['route'] == 'whole']
    ptext = {p: partner_texts(p) for p in {r['page'] for r in reads}}
    rows = []
    for r in reads:
        nes = S.score(r['truth'], r['text'], r['stratum'])['nes'] if r['ok'] else 0.
        bow_truth = O.newsbench(ill.sub(' ', r['truth']), ill.sub(' ', r['text']))['bowF1'] if r['ok'] else 0.
        texts = {'whole': '\n'.join(l['text'] for l in r['lines']), **ptext[r['page']]}
        risk = {}
        for p, v in texts.items():
            for m in ('bow', 'nes'):
                if not r['ok']:
                    x = F.FAILED
                elif not v.strip():
                    x = 1.
                elif m == 'bow':
                    x = 1 - O.newsbench(v, r['text'])['bowF1']
                else:
                    x = 1 - S.score(v, r['text'])['nes']
                risk[f'{p} {m}'] = x
        rows.append({k: r[k] for k in ('system', 'model', 'page')} |
                    {'ok': r['ok'], 'nes': nes, 'bowf1': bow_truth, 'poor': nes < F.POOR,
                     'poor_orderfree': bow_truth < F.POOR, 'risk': risk})
    return rows


def vision_quality():
    """Each partner's own NES and bag-of-words F1 against the truth, mean over the 15 scans and the worst page."""
    import ocr_panel_score as S
    import ocr_scorers as O
    per = {}
    for p in N.l9_pages():
        t = (N.FROZEN / 'L9' / f'{p}.txt').read_text()
        texts = {'whole': '\n'.join(l['text'] for l in N.vision_lines(N.WORK / 'lines' / 'l9' / f'{p}.json')),
                 **partner_texts(p)}
        for k, v in texts.items():
            per.setdefault(k, []).append((S.score(t, v, 'L9')['nes'], O.newsbench(t, v)['bowF1']))
    return {k: {'nes': st.mean(a for a, _ in v), 'nes_min': min(a for a, _ in v),
                'bowf1': st.mean(b for _, b in v), 'bowf1_min': min(b for _, b in v)} for k, v in per.items()}


def analyse(attempts):
    rows = [r for r in attempts if r['ok']]
    res = {'counts': N.reading_counts(attempts),
           'pooled': {lab: {s: N.evaluate(rows, s, lab) for s in SIGNALS} for lab in ('poor', 'poor_orderfree')},
           'app_baseline': N.app_baseline(attempts, 'whole', 'whole nes'), 'app_cuts': {}, 'systems': {}}
    for model, (name, cut) in N.APP_CUTS.items():
        sub = [r for r in rows if r['model'] == model]
        if sub:
            res['app_cuts'][name] = {'cut': cut, **{s: N.evaluate(sub, s, cut=cut) for s in SIGNALS}}
    for s in sorted({r['system'] for r in attempts}):
        sub = [r for r in rows if r['system'] == s]
        res['systems'][s] = {**N.reading_counts([r for r in attempts if r['system'] == s]),
                             'auc': {g: F.auc([r['risk'][g] for r in sub], [r['poor'] for r in sub]) for g in SIGNALS},
                             'median_risk_good': {g: N.med([r['risk'][g] for r in sub if not r['poor']]) for g in SIGNALS}}
    if RECOMMENDED is not None:
        sig, cut = RECOMMENDED
        res['recommended'] = {'signal': sig, 'cut': cut,
                              **{lab: N.evaluate(rows, sig, lab, cut=cut) for lab in ('poor', 'poor_orderfree')},
                              'by system': {s: F.counts([r['risk'][sig] for r in rows if r['system'] == s],
                                                        [r['poor'] for r in rows if r['system'] == s],
                                                        [r['nes'] for r in rows if r['system'] == s], cut)
                                            for s in sorted({r['system'] for r in rows})}}
    res['grid'] = {s: [{'cut': c / 100, **F.rates(F.counts([r['risk'][s] for r in rows], [r['poor'] for r in rows],
                                                             [r['nes'] for r in rows], c / 100))}
                       for c in range(5, 96, 1)] for s in SIGNALS}
    return res


def report():
    rows = score_all()
    res = {'vision': vision_quality(), **analyse(rows)}
    OUT_JSON.write_text(json.dumps({'rows': rows, **res}, indent=1, default=str).replace('Infinity', 'null') + '\n')
    OUT_MD.write_text(render(res))
    print(f'wrote {OUT_MD} and {OUT_JSON}')


FINDINGS = '''
Generated by `scripts/segbench/post_read_flag_newspaper_whole.py report` (the method is its docstring); every figure
is in `post-read-flag-newspaper-whole.json`. No money and no reader run: the readings are the ones
`post_read_flag_newspaper.py` scored; Apple Vision read 435 tiles of the 15 scans on this Mac (macOS 27.2, the guarded
runner) and its PP-DocLayoutV3 and DocLayout-YOLO crop readings are W49.proc-read-flag-newspaper's.

## What this says

- **Comparing words found in pieces improves the ranking.** Vision's pieces score 89 to 93 bag-of-words F1 against
  the truth, compared with 44.5 whole. The tables below compare each candidate on answers only. The whole-page
  Vision signal pooled across readers is a ranking comparison. The app baseline uses four distinct reader thresholds.
- **Candidate: Vision on a 3 x 3 grid, counting shared words, at 0.20.** This catches 104 of 109 answered strict-poor
  readings and all 92 answered content-poor readings, with 0 of 53 strict-good answers flagged (Wilson 0–7%).
  The six failed requests contribute no warnings. The largest strict-good risk is 0.173. Both the partner and the
  threshold were selected on these scans. Cross-validation below refits the threshold in each fold and does not
  validate the selected 0.20 cutoff on fresh scans. Tiles took about 2 s a page here (27 tiles from 3 scans in 6.3 s).
- **The five missed answers kept most words.** They have 85 to 97% bag-of-words F1 against the truth but put the
  columns in a different order. An order-free comparison cannot detect that. The content-only label also counts
  some strict-poor answers as good, so its false-alarm denominator differs.
- **The app's designated whole-page reader still needs a matched check.** These scans have only FarmShare's truth
  scores for Qwen3.6 27B. Its 0.967 truth score and Gemini 3.7 Flash's three tile comparisons use different
  readers or setups. The app follow-up needs matched Qwen3.6 27B replies on the deployed image path.
- **What the app would do.** For a newspaper page read whole, cut the image into 3 x 3 equal tiles, read each with
  Vision, join the lines, compare with the reading by NewsBench's bag-of-words F1 and flag at a risk of 0.20 or more
  (W49.proc-read-flag-newspaper-whole-app).
'''
CARD = '''
## Measurement card

- **Truth.** The 15 scored L9 scans' Library of Congress By the People volunteer transcriptions (NewsBench; 4 pages
  with partial gold left out, as the bench does). Not checked by the owner. No reader scored here drafted it.
- **Selection.** L9 is NewsBench's scored set as frozen in the bench corpus, chosen before these readers and this
  flag; the readings are every whole-page LLM or VLM reading W49.proc-read-flag-newspaper scored, none dropped for its
  result. The grids (2, 3, 4) were fixed before scoring.
- **Comparison.** Every signal is computed on the same readings, the same scorer and Vision runs under the same
  settings (segbench-dewarp lines, the app's VisionClient). Tiles are cut from the frozen L9 originals; Gemini 3.7
  Flash's 3 pages were read from the gateway's copies of the same scans.
- **Noise.** 168 readings, but 15 pages, 14 from one collection (`mss34132`), and only 53 strict-good answers, so 0 of 53 is
  0–7% (Wilson). The interval ignores page clustering. Cross-validation keeps a page's readings in one fold; leave-one-system-out tests a reader outside the fit. Vision's readings are settled by the guard's two
  agreeing reads; the readers were not rerun.
- **Scope.** Scanned newspapers only (no photographed newspaper has truth, W46.newspaper-photo-truth; the owner's
  newspapers are photographs). Not measured: Qwen3.6 27B's own readings, the cut on the app's images (the app may
  downscale the page before it reads it), and an order-poor reading, which an order-free check cannot see.
'''


def render(res):
    c = res['counts']
    L = ['# W49.proc-read-flag-newspaper-whole: the read-poorly flag on a newspaper scan read whole', '',
         f"{c['answered']}/{c['readings']} whole-page attempts answered across {c['systems']} systems on 15 L9 scans. "
         f"{c['failed']} requests failed. Among answers, {c['poor']} were strict poor (under 70 NES), "
         f"{c['poor_orderfree']} were content poor and mean NES was {100 * c['mean_nes']:.1f}.", '', FINDINGS.strip(), '', '## Vision on its pieces of the 15 scans', '',
         '| partner | strict NES (worst) | bag-of-words F1 (worst) |', '|---|---:|---:|']
    for k, v in res['vision'].items():
        L.append(f"| {k} | {100 * v['nes']:.1f} ({100 * v['nes_min']:.1f}) | "
                 f"{100 * v['bowf1']:.1f} ({100 * v['bowf1_min']:.1f}) |")
    for lab, title in (('poor', 'poor = under 70 strict NES'), ('poor_orderfree', 'poor = under 70 bag-of-words F1')):
        L += ['', f'## Pooled, {title}', '',
              '| signal | AUC | cut | in-sample caught | in-sample false alarms | cross-validated by page | left-out system |',
              '|---|---:|---:|---|---|---|---|']
        for s, e in res['pooled'][lab].items():
            cv, lo = e['crossval'], e['leave_system_out']
            L.append(f"| {s} | {N._f(e['auc'])} | {N._f(e['cut'])} | {N._cell(e['in_sample'])} | "
                     f"{N._cell(e['in_sample'], False)} | {N._p(cv['hit_rate'])} at {N._p(cv['fa_rate'])} | "
                     f"{N._p(lo['hit_rate'])} at {N._p(lo['fa_rate'])} |")
    rec = res['recommended']
    L += ['', f"## The recommended partner, {rec['signal']}, at {rec['cut']:.2f}", '',
          '| label | caught | false alarms |', '|---|---|---|',
          f"| strict label | {N._cell(rec['poor']['in_sample'])} | {N._cell(rec['poor']['in_sample'], False)} |",
          f"| order-free label | {N._cell(rec['poor_orderfree']['in_sample'])} | "
          f"{N._cell(rec['poor_orderfree']['in_sample'], False)} |", '',
          '| system | poor | caught | false alarms |', '|---|---:|---:|---:|']
    for s, k in rec['by system'].items():
        L.append(f"| {s} | {k['poor']} | {k['hits']} | {k['false_alarms']} |")
    L += ['', '### The cut grid, strict label', '', '| cut | ' + ' | '.join(PARTNERS) + ' |',
          '|---:|' + '---|' * len(PARTNERS)]
    for i, row in enumerate(res['grid'][f'{PARTNERS[0]} bow']):
        if not 0.10 <= row['cut'] <= 0.40 or round(100 * row['cut']) % 2:
            continue
        L.append(f"| {row['cut']:.2f} | " + ' | '.join(
            f"{res['grid'][f'{p} bow'][i]['hits']}/{res['grid'][f'{p} bow'][i]['poor']}, "
            f"{res['grid'][f'{p} bow'][i]['false_alarms']}/{res['grid'][f'{p} bow'][i]['good']}" for p in PARTNERS) + ' |')
    L += ['', '## Which readings the app baseline can flag', '', *N.render_baseline(res['app_baseline']), '',
          '## Replaying the same mapped thresholds on candidate signals', '',
          '| reader, cut | ' + ' | '.join(SIGNALS) + ' |', '|---|' + '---|' * len(SIGNALS)]
    for name, e in res['app_cuts'].items():
        L.append(f"| {name}, {e['cut']:.4f} | " + ' | '.join(
            f"{e[s]['in_sample']['hits']}/{e[s]['in_sample']['poor']}, "
            f"{e[s]['in_sample']['false_alarms']}/{e[s]['in_sample']['good']}" for s in SIGNALS) + ' |')
    L += ['', 'Cells: poor caught / poor, false alarms / good.', '', '## Each system', '',
          'AUC and the median risk of its good readings, by signal.', '',
          '| system | answered | failed | poor | mean NES | ' + ' | '.join(SIGNALS) + ' |', '|---|---:|---:|---:|---:|' + '---|' * len(SIGNALS)]
    for s, e in res['systems'].items():
        L.append(f"| {s} | {e['answered']} | {e['failed']} | {e['poor']} | {N._f(None if e['mean_nes'] is None else 100 * e['mean_nes'], 1)} | " + ' | '.join(
            f"{N._f(e['auc'][g], 2)}, {N._f(e['median_risk_good'][g], 2)}" for g in SIGNALS) + ' |')
    L += ['', CARD.strip()]
    return '\n'.join(L) + '\n'


def self_test():
    assert tiles(10, 7, 2) == [(0, 0, 5, 4), (5, 0, 10, 4), (0, 4, 5, 7), (5, 4, 10, 7)]
    t = tiles(5297, 3528, 3)
    assert len(t) == 9 and t[-1][2:] == (5297, 3528)
    # the tiles cover the image exactly once
    assert sum((x1 - x0) * (y1 - y0) for x0, y0, x1, y1 in tiles(5297, 3528, 4)) == 5297 * 3528
    print('self-test ok')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=('vision', 'report', 'self-test'))
    a = ap.parse_args()
    {'vision': vision, 'report': report, 'self-test': self_test}[a.cmd]()


if __name__ == '__main__':
    main()
