#!/usr/bin/env python3
"""W49.proc-read-flag-newspaper-whole: a partner for the read-poorly flag on a newspaper scan read whole.

  python3 ops/autonomous/heavy-run.py run -- python3 ArchiveProcessor/scripts/segbench/post_read_flag_newspaper_whole.py vision
  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy --with python-Levenshtein \
      python ArchiveProcessor/scripts/segbench/post_read_flag_newspaper_whole.py report
  python3 ArchiveProcessor/scripts/segbench/post_read_flag_newspaper_whole.py self-test

THE QUESTION. W49.proc-read-flag-newspaper found that Apple Vision reads a whole newspaper scan at 21.8 strict NES, so
the app's whole-page check (a reading against Vision's whole-page text, in order) flags 46 of 53 good whole readings
of the L9 scans at the readers' cuts. Since W47.wh-whole-page-large Qwen3.6 27B reads every newspaper whole, so that
is its normal path. Which Vision partner keeps the flag on a whole reading, and at what cut?

THE PARTNERS. Vision reads pieces of the same image, and the pieces' lines are joined; the whole reading's order is
not the pieces', so the comparisons that matter are order-free (NewsBench's bag-of-words F1, which counts repeats):
  pp, yolo     the PP-DocLayoutV3 crops (the app's detector, PaddleOCR-VL's raw order) or DocLayout-YOLO's, as read
               for W49.proc-read-flag-newspaper (cached; no new Vision read).
  tiles NxN    the page cut into an N x N grid of equal tiles, no overlap (a word on a cut can be split or lost on
               both sides); needs no layout model, so it also covers a page the detector failed on.
Each partner gives two risks (higher = more likely poor): `<partner> bow` = 1 - bag-of-words F1, and `<partner> nes` =
1 - NES in the partner's order (for contrast: order counts against the reading). The baseline is today's check,
`whole nes` (1 - NES against Vision's whole page). A failed reading is always flagged, as in the fit.

THE LABEL. Poor under 70 strict NES against the truth, as the fit (post_read_flag.POOR); also the order-free label,
poor under 70 bag-of-words F1 (content lost rather than order). A false alarm is a flag on a reading at or above 70;
the ceiling is 5% of those (post_read_flag.CEILING).

THE READINGS. The 168 whole-page readings of the 15 scored L9 scans that W49.proc-read-flag-newspaper scored (its
`readings()`: 10 NewsBench systems, the bench's PaddleOCR-VL 1.6 on this Mac, Gemini 3.7 Flash's 3 gateway pages).
Qwen3.6 27B's own whole readings are not on this Mac (FarmShare's run kept only scores), so the reader whose path
this is is not among them.

THE FITS. Pooled over the readings: in-sample, cross-validated by page (5-fold, 20 seeds, a page in one fold), and
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
    reads = [r for r in N.readings() if r['set'] == 'L9' and r['route'] == 'whole']
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


def evaluate(rows, sig, label='poor', cut=None):
    risk = [r['risk'][sig] for r in rows]
    poor = [r[label] for r in rows]
    nes = [r['nes'] for r in rows]
    fitted = F.fit_cut(risk, poor) if cut is None else cut
    out = {'n': len(rows), 'auc': F.auc(risk, poor), 'cut': fitted,
           'in_sample': F.rates(F.counts(risk, poor, nes, fitted))}
    if cut is None:
        out['crossval'] = F.rates(F.crossval(risk, poor, nes, groups=[r['page'] for r in rows]))
        tot = {}
        for s in sorted({r['system'] for r in rows}):
            tr = [r for r in rows if r['system'] != s]
            te = [r for r in rows if r['system'] == s]
            c = F.fit_cut([r['risk'][sig] for r in tr], [r[label] for r in tr])
            tot = F.add(tot, F.counts([r['risk'][sig] for r in te], [r[label] for r in te], [r['nes'] for r in te], c))
        out['leave_system_out'] = F.rates(tot)
    return out


def med(xs):
    xs = [x for x in xs if x != F.FAILED]
    return st.median(xs) if xs else None


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


def analyse(rows):
    res = {'counts': {'readings': len(rows), 'systems': len({r['system'] for r in rows}),
                      'poor': sum(r['poor'] for r in rows), 'poor_orderfree': sum(r['poor_orderfree'] for r in rows),
                      'failed': sum(not r['ok'] for r in rows), 'mean_nes': st.mean(r['nes'] for r in rows)},
           'pooled': {lab: {s: evaluate(rows, s, lab) for s in SIGNALS} for lab in ('poor', 'poor_orderfree')},
           'app_cuts': {}, 'systems': {}}
    for model, (name, cut) in N.APP_CUTS.items():
        sub = [r for r in rows if r['model'] == model]
        if sub:
            res['app_cuts'][name] = {'cut': cut, **{s: evaluate(sub, s, cut=cut) for s in SIGNALS}}
    for s in sorted({r['system'] for r in rows}):
        sub = [r for r in rows if r['system'] == s]
        res['systems'][s] = {'n': len(sub), 'poor': sum(r['poor'] for r in sub), 'failed': sum(not r['ok'] for r in sub),
                             'mean_nes': st.mean(r['nes'] for r in sub),
                             'auc': {g: F.auc([r['risk'][g] for r in sub], [r['poor'] for r in sub]) for g in SIGNALS},
                             'median_risk_good': {g: med([r['risk'][g] for r in sub if not r['poor'] and r['ok']])
                                                  for g in SIGNALS}}
    if RECOMMENDED is not None:
        sig, cut = RECOMMENDED
        res['recommended'] = {'signal': sig, 'cut': cut,
                              **{lab: evaluate(rows, sig, lab, cut=cut) for lab in ('poor', 'poor_orderfree')},
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
    OUT_JSON.write_text(json.dumps({'rows': rows, **res}, indent=1, default=str) + '\n')
    OUT_MD.write_text(render(res))
    print(f'wrote {OUT_MD} and {OUT_JSON}')


FINDINGS = '''
Generated by `scripts/segbench/post_read_flag_newspaper_whole.py report` (the method is its docstring); every figure
is in `post-read-flag-newspaper-whole.json`. No money and no reader run: the readings are the ones
`post_read_flag_newspaper.py` scored; Apple Vision read 435 tiles of the 15 scans on this Mac (macOS 27.2, the guarded
runner) and its PP-DocLayoutV3 and DocLayout-YOLO crop readings are W49.proc-read-flag-newspaper's.

## What this says

- **A partner holds the ceiling.** Vision reading the page in pieces finds the words its whole-page reading misses
  (bag-of-words F1 89 to 93 against the truth, against 44.5 whole), and compared order-free with a whole reading it
  separates poor readings from good ones almost completely: AUC 0.98 to 0.99 for every partner, 1.00 for the readings
  that lost content. Today's check on the same readings has AUC 0.69. Every partner's fitted cut holds 5% in-sample
  (2 of 53 good readings), cross-validated by page (4 to 6%) and for a held-out system (4 to 6%), catching 96 to 97%
  of the poor readings.
- **Recommended: Vision on a 3 x 3 grid of tiles, order-free, flagged at 0.20.** It flags none of the 53 good readings
  (0-7%), catches 110 of the 115 poor ones (the 6 failed included) and all 98 that lost content. The largest risk of a
  good reading is 0.173, so 0.20 leaves a margin; it was chosen from the grid, so its figures are in-sample (the fitted
  cut, 0.163, is the held-out estimate: 97% caught at 4% by page and by system). Tiles need no layout model, so they
  also cover the pages the app reads whole because the detector is missing or failed, and they read in about 2 s a
  page here (27 tiles of 3 scans in 6.3 s, one process). The 2 x 2 and 4 x 4 grids and the detector's crops do about
  as well; 3 x 3 and 4 x 4 catch the most poor readings with no false alarm (111 of 115 at their best cut), and 3 x 3
  needs 9 Vision reads rather than 16.
- **The five it misses are poor in order only.** Each keeps 85 to 97% of the truth's words (bag-of-words F1) but has
  the columns in another order than the truth, which no order-free comparison can see; in order the tiles' text is
  itself out of the truth's order (strict NES 33), so the in-order comparison with tiles is weaker (AUC 0.85 to 0.87).
- **The readers' own cuts do not apply.** On the tile comparison the app's whole-page cuts (about 0.70) flag no good
  reading and miss most poor ones; a newspaper read whole needs this one cut for every reader, as the region route
  does (0.45 there, on another comparison).
- **Not measured: Qwen3.6 27B itself.** Its whole readings of these scans exist only as FarmShare's scores, so the
  reader whose normal path this is is not in the fit. Its 0.967 NewsBench score puts its readings with Gemini 3.7
  Flash's (median tile risk 0.06 for Gemini's 3 pages), far under the cut.
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
- **Noise.** 168 readings, but 15 pages, 14 from one collection (`mss34132`), and only 53 good readings, so 0 of 53 is
  0-7% (Wilson) and the 5% ceiling cannot be shown tighter than that here; 60 of the 115 poor readings come from the
  four systems poor on every page, which any comparison catches. Cross-validation keeps a page's readings in
  one fold; leave-one-system-out tests a reader outside the fit. Vision's readings are settled by the guard's two
  agreeing reads; the readers were not rerun.
- **Scope.** Scanned newspapers only (no photographed newspaper has truth, W46.newspaper-photo-truth; the owner's
  newspapers are photographs). Not measured: Qwen3.6 27B's own readings, the cut on the app's images (the app may
  downscale the page before it reads it), and an order-poor reading, which an order-free check cannot see.
'''


def render(res):
    c = res['counts']
    L = ['# W49.proc-read-flag-newspaper-whole: the read-poorly flag on a newspaper scan read whole', '',
         f"{c['readings']} whole-page readings of the 15 L9 scans ({c['systems']} systems), {c['poor']} poor "
         f"(under 70 strict NES), {c['poor_orderfree']} poor order-free, {c['failed']} failed, mean NES "
         f"{100 * c['mean_nes']:.1f}.", '', FINDINGS.strip(), '', '## Vision on its pieces of the 15 scans', '',
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
    L += ['', "## The app's whole-page cuts on each signal", '',
          '| reader, cut | ' + ' | '.join(SIGNALS) + ' |', '|---|' + '---|' * len(SIGNALS)]
    for name, e in res['app_cuts'].items():
        L.append(f"| {name}, {e['cut']:.3f} | " + ' | '.join(
            f"{e[s]['in_sample']['hits']}/{e[s]['in_sample']['poor']}, "
            f"{e[s]['in_sample']['false_alarms']}/{e[s]['in_sample']['good']}" for s in SIGNALS) + ' |')
    L += ['', 'Cells: poor caught / poor, false alarms / good.', '', '## Each system', '',
          'AUC and the median risk of its good readings, by signal.', '',
          '| system | poor | mean NES | ' + ' | '.join(SIGNALS) + ' |', '|---|---:|---:|' + '---|' * len(SIGNALS)]
    for s, e in res['systems'].items():
        L.append(f"| {s} | {e['poor']} | {100 * e['mean_nes']:.1f} | " + ' | '.join(
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
