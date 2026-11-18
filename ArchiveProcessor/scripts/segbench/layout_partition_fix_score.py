#!/usr/bin/env python3
"""W46.layout-partition-fix: score the fixed newspaper partition against the kept whole and raw-region reads, on L9.

  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy --with python-Levenshtein \
      python ArchiveProcessor/scripts/segbench/layout_partition_fix_score.py

Same reader, settings, pages and scoring as layout_partition_score.py, whose functions it uses: the whole and raw arms
are W46.layout-partition-score's saved reads, the partition arm is the fixed plan (layout_partition_plans.sh, then
layout_partition_read.py --arms partition). The partition is also scored without its outside crops (descriptive).
The shipped partition's per-page scores come from the committed layout-partition-score-pages.csv, for the
before/after pair. Saved readings only: no model, network or money. Writes score-only files:
segbench-results/layout-partition-fix.{md,json} and -pages.csv.

Predeclared pass (SUITE_TODO W46.layout-partition-fix): the fixed partition does not trail the raw regions beyond
the interval on strict NES or order-free F1 (the interval's upper end is not below 0), and adds no more words than
they do beyond the interval (the added-words interval's lower end is not above 0).
"""
from __future__ import annotations

import csv
import json
import statistics as st
from pathlib import Path

import layout_partition_score as P

L, S, R, D = P.L, P.S, P.R, P.D
RES = P.RES
OUT = RES / 'layout-partition-fix'
ARMS = ('whole', 'raw', 'partition', 'partition-nooutside', 'shipped')
NAMES = {'whole': 'whole page', 'raw': 'raw regions (measured baseline)', 'partition': 'fixed partition',
         'partition-nooutside': 'fixed partition without its outside crops',
         'shipped': 'shipped partition (W46.layout-partition-score)'}
PAIRS = [('partition', 'raw'), ('partition', 'whole'), ('partition', 'shipped'), ('partition-nooutside', 'raw'),
         ('partition', 'partition-nooutside')]


def outside(rec: dict) -> bool:
    return rec['source'].startswith('outside')


def rows() -> list[dict]:
    R.MANIFEST = D.MANIFEST
    truth = {R.job_id(r): r for r in R.frozen()}
    with (RES / 'layout-partition-score-pages.csv').open() as f:
        shipped = {r['page']: r for r in csv.DictReader(f) if r['arm'] == 'partition'}
    out = []
    for pid, original, plan in L.pages():
        ref = Path(truth[pid]['truth']).read_text()
        got = {arm: P.records(arm, pid, original, plan) for arm in ('whole', 'raw', 'partition')}
        got['partition-nooutside'] = [r for r in got['partition'] if not outside(r)]
        for arm, recs in got.items():
            errors = sum(1 for r in recs if r['error'])
            planned = arm.startswith('partition')
            used = recs + got['whole'] if planned and errors else recs
            text = P.stitch(got['whole']) if planned and errors else P.stitch(recs)
            row = {'arm': arm, 'page': pid, 'requests': len(used), 'errors': errors,
                   'caps': sum(1 for r in recs if r['cut'] != '-'), 'seconds': sum(r['seconds'] for r in used),
                   'fallback': bool(planned and errors), **P.page_scores(ref, text)}
            if arm == 'partition':
                ow = sum(len(r['text'].split()) for r in recs if outside(r))
                row.update(outside_crops=sum(1 for r in recs if outside(r)), outside_words=ow,
                           words_read=len(text.split()), regions=plan['plan_regions'],
                           region_images=plan['region_images'], fill_lines=plan['fill_lines'],
                           split_lines=plan['split_lines'], vision_lines=plan['vision_lines'],
                           prepare_seconds=plan['prepare_seconds'])
            if arm == 'raw':
                row['regions'] = len(recs)
            out.append(row)
        s = shipped[pid]
        out.append({'arm': 'shipped', 'page': pid, 'requests': int(s['requests']), 'errors': int(s['errors']),
                    'caps': int(s['caps']), 'seconds': float(s['seconds']), 'fallback': s['fallback'] == 'True',
                    **{m: float(s[m]) for m in ('nes', 'bowf1', 'gap', 'missed', 'added', 'words')}})
    return out


def main() -> None:
    rr = rows()
    comps = {m: {f'{a} − {b}': P.pair(rr, a, b, m, hi) for a, b in PAIRS} for m, _, hi in P.MEASURES}
    arms = {}
    for arm in ARMS:
        mine = [r for r in rr if r['arm'] == arm]
        arms[arm] = {'pages': len(mine), 'requests': sum(r['requests'] for r in mine),
                     'errors': sum(r['errors'] for r in mine), 'pages_capped': sum(1 for r in mine if r['caps']),
                     'fallbacks': sum(r['fallback'] for r in mine), 'seconds': sum(r['seconds'] for r in mine),
                     'empty': sum(1 for r in mine if r['nes'] == 0),
                     **{m: st.mean(r[m] for r in mine) for m in ('nes', 'bowf1', 'gap', 'missed', 'added')}}
    part = [r for r in rr if r['arm'] == 'partition']
    plan = {'pages': len(part), 'regions': sum(r['regions'] for r in part),
            'region_images': sum(r['region_images'] for r in part),
            'raw_regions': sum(r['regions'] for r in rr if r['arm'] == 'raw'),
            'outside_crops': sum(r['outside_crops'] for r in part),
            'outside_pages': sum(1 for r in part if r['outside_crops']),
            'vision_lines': sum(r['vision_lines'] for r in part), 'fill_lines': sum(r['fill_lines'] for r in part),
            'split_lines': sum(r['split_lines'] for r in part),
            'outside_word_share': sum(r['outside_words'] for r in part) / max(1, sum(r['words_read'] for r in part)),
            'prepare_seconds': sum(r['prepare_seconds'] for r in part)}
    s, o, a = comps['nes']['partition − raw'], comps['bowf1']['partition − raw'], comps['added']['partition − raw']
    verdict = {'strict_not_behind': s['hi'] >= 0 or abs(s['delta']) < 100 * P.FLOOR,
               'orderfree_not_behind': o['hi'] >= 0 or abs(o['delta']) < 100 * P.FLOOR,
               'added_not_more': a['lo'] <= 0 or abs(a['delta']) < 100 * P.FLOOR}
    verdict['pass'] = all(verdict.values())
    OUT.with_suffix('.json').write_text(json.dumps({'reader': L.REPO, 'revision': L.REVISION, 'prompt': L.PROMPT,
                                                    'max_side': L.MAX_SIDE, 'plan': plan, 'arms': arms,
                                                    'comparisons': comps, 'verdict': verdict}, indent=1) + '\n')
    keys = ['arm', 'page', 'nes', 'bowf1', 'gap', 'missed', 'added', 'words', 'requests', 'errors', 'caps', 'seconds',
            'fallback', 'regions', 'region_images', 'outside_crops', 'outside_words', 'fill_lines', 'split_lines',
            'vision_lines']
    with (RES / 'layout-partition-fix-pages.csv').open('w', newline='') as f:
        w = csv.DictWriter(f, keys, extrasaction='ignore')
        w.writeheader()
        for r in rr:
            w.writerow({k: round(v, 4) if isinstance(v, float) else v for k, v in r.items()})
    print(json.dumps({'verdict': verdict, **{k: {m: round(v[m], 4) for m in ('nes', 'bowf1', 'missed', 'added')}
                                             for k, v in arms.items()}}, indent=1))
    OUT.with_suffix('.md').write_text(render(plan, arms, comps, verdict))


def render(plan: dict, arms: dict, comps: dict, verdict: dict) -> str:
    f1 = lambda x: f'{x:.1f}'
    iv = lambda d: f'{d["delta"]:+.1f} [{d["lo"]:+.1f}, {d["hi"]:+.1f}]'
    lines = ['# W46.layout-partition-fix — the fixed newspaper partition, read and scored on L9', '',
             'The app\'s shipped Mac PaddleOCR-VL 1.6 4-bit on the 15 L9 scans: the fixed partition (each Vision line',
             'read once, whole, by the region holding most of it; lines outside every region read as small crops of',
             'their own; a region masking leaves blank not read) against W46.layout-partition-score\'s whole-page and',
             'raw-region reads, same reader and settings. Generated by `scripts/segbench/layout_partition_fix_score.py`.',
             '$0.', '', *FINDINGS, '',
             f'Predeclared pass: {"**met**" if verdict["pass"] else "**not met**"} (strict not behind the raw regions'
             f' beyond the interval: {verdict["strict_not_behind"]}; order-free: {verdict["orderfree_not_behind"]};'
             f' added words not more: {verdict["added_not_more"]}).', '',
             '## The partition the app made', '',
             f'- {plan["region_images"]:,} region images read of {plan["regions"]:,} regions kept (the rest masked'
             f' blank), against {plan["raw_regions"]:,} raw-baseline crops.',
             f'- {plan["split_lines"]:,} of {plan["vision_lines"]:,} Vision lines cross a region edge and are read whole'
             f' by the region holding most of them; {plan["fill_lines"]:,} touch no region, read as'
             f' {plan["outside_crops"]:,} outside crops on {plan["outside_pages"]} pages, carrying'
             f' {100 * plan["outside_word_share"]:.1f}% of the words read.',
             f'- Preparation (Vision, detector, images; not the kind gate) took {plan["prepare_seconds"]:.0f} s over the'
             ' 15 pages.', '',
             '## Arms', '',
             '| arm | strict NES | order-free F1 | missed /100 | added /100 | requests | capped pages | errors | reading s |',
             '|---|---:|---:|---:|---:|---:|---:|---:|---:|']
    for arm, a in arms.items():
        lines.append(f'| {NAMES[arm]} | {f1(100 * a["nes"])} | {f1(100 * a["bowf1"])} | {f1(a["missed"])} | '
                     f'{f1(a["added"])} | {a["requests"]:,} | {a["pages_capped"]} | {a["errors"]} | {a["seconds"]:,.0f} |')
    lines += ['', 'The no-outside row is the partition\'s own requests less its outside crops, not a route the app',
              'runs. Seconds are reading only (model loaded once). Missed and added are word counts against the truth\'s.',
              '', '## Paired differences', '',
              'Δ is the first arm minus the second, the paired mean over the 15 pages, with its 95% page-bootstrap',
              'interval and a two-sided paired permutation p; an interval crossing 0, or a gap under the 0.49-point floor,',
              'is a tie. For missed and added words lower is better, so the verdict names the arm with fewer.', '']
    for m, title, _ in P.MEASURES:
        lines += [f'### {title}', '', '| pair | first | second | Δ | p | wins first / second | verdict |',
                  '|---|---:|---:|---:|---:|---:|---|']
        for k, d in comps[m].items():
            lines.append(f'| {k} | {f1(d["a"])} | {f1(d["b"])} | {iv(d)} | {d["p"]:.3f} | {d["a_wins"]} / '
                         f'{d["b_wins"]} | {d["verdict"]} |')
        lines.append('')
    return '\n'.join(lines) + '\n' + CARD


# Written after the scores were read (the tables below are generated from the reads).
FINDINGS = [
    '## What this says', '',
    '- **The fix restores the region gain.** The fixed partition scores 78.7 strict NES against 20.2 for the shipped',
    '  one, +58.5 [+49.4, +66.1], ahead on all 15 pages, and ties the raw regions it was built to match: strict -5.9',
    '  [-15.8, +1.6], order-free 91.2 against 91.5, -0.3 [-9.2, +7.5], missed words 5.7 against 5.8 per 100, added',
    '  22.7 against 17.7, +5.0 [-21.2, +37.0]. The predeclared pass is met on all three.',
    '- **Why it works.** 930 of 9,635 Vision lines (10%) cross a region edge; each is now read whole by the region',
    '  holding most of it instead of moving, with its neighbours, into a whole-page fill (8,037 lines before). Only',
    '  244 lines touch no region; they are read as 80 small crops carrying 2.3% of the words. 17 of 980 regions were',
    '  masked blank and not read. No page needed a whole-page image, and reading took 791 s against 1,643.',
    '- **The outside crops find words and cost a little order.** Without them the partition misses 7.0 words per 100',
    '  against 5.7 with them (-1.3 [-2.0, -0.7]), but strict NES is 1.4 points higher (80.1): text read after every',
    '  region is out of place. Order-free they tie. Kept, since a missed word is lost while a misplaced one is not.',
    '- **The strict gap that remains is one page.** On mss3413201819-6 the partition scores 26.8 against 91.0 for the',
    '  raw regions: one wide region crop (1,665 x 255 px) and one small outside',
    '  crop sent the reader into a repetition loop to its 4,096-token cap, adding 188 words per 100. Raw regions have',
    '  such pages too (two pages capped; 111 and 126 added words per 100 on its two worst). The bench loop has no repetition guard for',
    '  any arm; the app\'s Mac route stops a repeating stream and re-reads once with a repetition penalty, which this',
    '  bench does not exercise. On the other 14 pages the partition is within a few points of the raw regions.',
    '- **The owner\'s choices stand.** The detector, its native order, pictures kept and regions for every reader are',
    '  unchanged; only what each crop holds changed.',
]

CARD = """## Measurement card

- **Truth.** L9's published transcriptions, independent of every arm and of the reader. The owner checked nothing
  specific to this item.
- **Selection.** The 15 frozen L9 pages of the 895 (sha256-checked), the bench's frozen draw, not chosen by any
  arm's or reader's output. No ABBYY text was used.
- **Comparison.** Same reader, prompt, temperature 0, 2,048 px ceiling and token caps (8,192 a whole-page-sized
  image, 4,096 a crop) as W46.layout-partition-score, whose whole and raw reads are reused unchanged from the bench
  cache. The partition images are the app's own (`NewspaperPagePlan.prepare` in the Debug Processor, real detector,
  the app's Vision lines). The shipped-partition row is that item's committed per-page scores. Both OCR sets: the
  owner's 96 has no newspaper page by its labels, so there is nothing to pair there.
- **Noise.** n = 15 pages, paired; one temperature-0 reading per arm; the pages come from few items, almost all one
  Library of Congress collection, so the page bootstrap is optimistic.
- **Scope.** One small reader standing in for a page reader; larger readers are not measured. Scans only. Ink
  outside every region that Vision does not see as a line is no longer read (the old whole-page fill read it);
  that loss is inside the missed-words figure here. The detector ran from the lab's PP-DocLayoutV3 MLX copy, whose
  857 tensors equal the app's pinned snapshot.
"""


if __name__ == '__main__':
    main()
