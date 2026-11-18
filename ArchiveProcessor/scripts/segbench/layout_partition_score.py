#!/usr/bin/env python3
"""W46.layout-partition-score, step 3: score the three arms layout_partition_read.py read, paired, on L9.

  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy --with python-Levenshtein \
      python ArchiveProcessor/scripts/segbench/layout_partition_score.py

Each arm's page text is stitched as the app combines a plan (NewspaperPageReader.combine: non-empty readings joined
by a blank line, in the order sent). A partition request that errors makes the app read the whole page instead, so
that page takes the whole arm's text, and its requests and seconds are added (none did if the table says 0). The
partition is also scored without its fill, to separate the fill from the masking (descriptive). Strict NES and the
word counts are ocr_panel_score.score at stratum L9, the order-free figures NewsBench's (ocr_scorers.newsbench), as
W46.ocr-rescore-offline scored the raw-region baseline. Saved readings only: no model, network or money. Writes
score-only files: segbench-results/layout-partition-score.{md,json} and -pages.csv.
"""
from __future__ import annotations

import csv
import json
import re
import statistics as st
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import ocr_panel_score as S          # noqa: E402
import ocr_scorers as O              # noqa: E402
import regions as D                  # noqa: E402
import routes as R                   # noqa: E402
import layout_partition_read as L    # noqa: E402

RES = HERE.parents[1] / 'segbench-results'
OUT = RES / 'layout-partition-score'
FLOOR = 0.0049   # ocr-rerun-noise.md's floor, as layout-pair-newspapers.py
ILLEGIBLE = re.compile(r'\[illegible\]', re.I)
ARMS = ('whole', 'raw', 'partition', 'partition-nofill', 'app')
NAMES = {'whole': 'whole page', 'raw': 'raw regions (measured baseline)', 'partition': 'shipped partition',
         'partition-nofill': 'shipped partition without its fill',
         'app': 'as the app routes it (partition, or whole where the kind gate says so)'}
PAIRS = [('partition', 'raw'), ('partition', 'whole'), ('raw', 'whole'), ('partition-nofill', 'raw'),
         ('partition', 'partition-nofill'), ('app', 'raw')]
MEASURES = [('nes', 'strict NES, in order', True), ('bowf1', 'order-free bag-of-words F1', True),
            ('missed', 'missed words per 100 truth words', False), ('added', 'added words per 100 truth words', False)]


def records(arm: str, pid: str, original, plan) -> list[dict]:
    want = L.jobs(arm, pid, original, plan)
    d = L.WORK / 'reads' / arm / pid
    got = [json.loads((d / f'{i:03d}.json').read_text()) for i, *_ in want if (d / f'{i:03d}.json').exists()]
    if len(got) != len(want):
        raise SystemExit(f'{arm}/{pid}: {len(got)} of {len(want)} requests read')
    return got


def stitch(recs: list[dict]) -> str:
    return '\n\n'.join(r['text'].strip() for r in recs if r['text'].strip())


def page_scores(ref: str, text: str) -> dict:
    sc = S.score(ref, text, 'L9')
    nb = O.newsbench(ILLEGIBLE.sub(' ', ref), ILLEGIBLE.sub(' ', text))
    return {'nes': sc['nes'], 'bowf1': nb['bowF1'], 'gap': nb['gap'], 'words': sc['words'],
            'missed': 100 * sc['missed'] / sc['words'], 'added': 100 * sc['added'] / sc['words']}


def rows() -> list[dict]:
    R.MANIFEST = D.MANIFEST
    truth = {R.job_id(r): r for r in R.frozen()}
    out = []
    for pid, original, plan in L.pages():
        ref = Path(truth[pid]['truth']).read_text()
        got = {arm: records(arm, pid, original, plan) for arm in ('whole', 'raw', 'partition')}
        fill = plan['has_fill'] and got['partition'][-1]['source'] == 'outside-regions.png'
        got['partition-nofill'] = got['partition'][:-1] if fill else got['partition']
        got['app'] = got['partition'] if plan['uses_regions'] else got['whole']
        for arm, recs in got.items():
            errors = sum(1 for r in recs if r['error'])
            planned = arm.startswith('partition') or (arm == 'app' and plan['uses_regions'])
            used = recs + got['whole'] if planned and errors else recs
            text = stitch(got['whole']) if planned and errors else stitch(recs)
            row = {'arm': arm, 'page': pid, 'requests': len(used), 'errors': errors,
                   'caps': sum(1 for r in recs if r['cut'] != '-'), 'seconds': sum(r['seconds'] for r in used),
                   'fallback': bool(planned and errors), **page_scores(ref, text)}
            if arm == 'partition':
                fw = len(got['partition'][-1]['text'].split()) if fill else 0
                row.update(fill=fill, fill_words=fw, words_read=len(text.split()), kind=plan['kind'],
                           kind_confidence=plan['kind_confidence'], uses_regions=plan['uses_regions'],
                           regions=plan['plan_regions'], coverage=plan['coverage'], fill_lines=plan['fill_lines'],
                           vision_lines=plan['vision_lines'], prepare_seconds=plan['prepare_seconds'])
            if arm == 'raw':
                row['regions'] = len(recs)
            out.append(row)
    return out


def pair(rr: list[dict], a: str, b: str, m: str, higher: bool) -> dict:
    x = {r['page']: r[m] for r in rr if r['arm'] == a}
    y = {r['page']: r[m] for r in rr if r['arm'] == b}
    pages = sorted(x)
    scale = 1 if m in ('missed', 'added') else 100
    d = S.paired([scale * x[p] for p in pages], [scale * y[p] for p in pages])
    d.update(a=scale * st.mean(x.values()), b=scale * st.mean(y.values()),
             a_wins=sum((x[p] > y[p]) == higher and x[p] != y[p] for p in pages),
             b_wins=sum((x[p] < y[p]) == higher and x[p] != y[p] for p in pages))
    tie = d['lo'] <= 0 <= d['hi'] or abs(d['delta']) < 100 * FLOOR
    d['verdict'] = 'tie' if tie else (a if (d['delta'] > 0) == higher else b)
    return d


def main() -> None:
    rr = rows()
    comps = {m: {f'{a} − {b}': pair(rr, a, b, m, hi) for a, b in PAIRS} for m, _, hi in MEASURES}
    arms = {}
    for arm in ARMS:
        mine = [r for r in rr if r['arm'] == arm]
        arms[arm] = {'pages': len(mine), 'requests': sum(r['requests'] for r in mine),
                     'errors': sum(r['errors'] for r in mine), 'caps': sum(r['caps'] for r in mine),
                     'pages_capped': sum(1 for r in mine if r['caps']), 'fallbacks': sum(r['fallback'] for r in mine),
                     'seconds': sum(r['seconds'] for r in mine), 'empty': sum(1 for r in mine if r['nes'] == 0),
                     **{m: st.mean(r[m] for r in mine) for m in ('nes', 'bowf1', 'gap', 'missed', 'added')}}
    part = [r for r in rr if r['arm'] == 'partition']
    plan = {'pages': len(part), 'uses_regions': sum(r['uses_regions'] for r in part),
            'kinds': sorted({f"{r['kind']} {r['kind_confidence']:.2f}" for r in part}),
            'filled': sum(r['fill'] for r in part), 'regions': sum(r['regions'] for r in part),
            'raw_regions': sum(r['regions'] for r in rr if r['arm'] == 'raw'),
            'vision_lines': sum(r['vision_lines'] for r in part), 'fill_lines': sum(r['fill_lines'] for r in part),
            'fill_word_share': sum(r['fill_words'] for r in part) / max(1, sum(r['words_read'] for r in part)),
            'coverage_mean': st.mean(r['coverage'] for r in part if r['coverage'] is not None),
            'prepare_seconds': sum(r['prepare_seconds'] for r in part)}
    OUT.with_suffix('.json').write_text(json.dumps({'reader': L.REPO, 'revision': L.REVISION, 'prompt': L.PROMPT,
                                                    'max_side': L.MAX_SIDE, 'plan': plan, 'arms': arms,
                                                    'comparisons': comps}, indent=1) + '\n')
    keys = ['arm', 'page', 'nes', 'bowf1', 'gap', 'missed', 'added', 'words', 'requests', 'errors', 'caps', 'seconds',
            'fallback', 'regions', 'fill', 'fill_words', 'coverage', 'fill_lines', 'vision_lines']
    with (RES / 'layout-partition-score-pages.csv').open('w', newline='') as f:
        w = csv.DictWriter(f, keys, extrasaction='ignore')
        w.writeheader()
        for r in rr:
            w.writerow({k: round(v, 4) if isinstance(v, float) else v for k, v in r.items()})
    OUT.with_suffix('.md').write_text(render(plan, arms, comps))


def render(plan: dict, arms: dict, comps: dict) -> str:
    f1 = lambda x: f'{x:.1f}'
    iv = lambda d: f'{d["delta"]:+.1f} [{d["lo"]:+.1f}, {d["hi"]:+.1f}]'
    lines = ['# W46.layout-partition-score — the shipped newspaper partition, read and scored on L9', '',
             'One small open reader, the app\'s shipped Mac PaddleOCR-VL 1.6 4-bit, on three arms of the 15 L9 scans:',
             'the whole page, the measured raw-region baseline and the app\'s own partition (its regions, then the',
             'masked whole-page fill). Generated by `scripts/segbench/layout_partition_score.py`; the protocol and stops',
             'were written before any reading (execution-plans/items/W46.layout-partition-score.md as of commit 7f5eff67,',
             'checkpoint 1; the note was folded into the DONE entry when the item shipped). $0.', '',
             *findings(plan, arms, comps),
             '## The partition the app made', '',
             f'- Kind gate: {plan["uses_regions"]} of {plan["pages"]} pages routed to regions (classifier: '
             f'{", ".join(plan["kinds"])}). The partition arm reads every page through the plan regardless, so the '
             'comparison is of the partition itself.',
             f'- {plan["regions"]:,} region images against {plan["raw_regions"]:,} raw-baseline crops; a fill on '
             f'{plan["filled"]} of {plan["pages"]} pages; {plan["fill_lines"]:,} of {plan["vision_lines"]:,} Vision lines '
             f'moved to the fill; mean line-box coverage {100 * plan["coverage_mean"]:.2f}%.',
             f'- The fill carried {100 * plan["fill_word_share"]:.1f}% of the words the partition read.',
             f'- Preparation (kind, Vision, detector, images) took {plan["prepare_seconds"]:.0f} s over the 15 pages.', '',
             '## Arms', '',
             '| arm | strict NES | order-free F1 | missed /100 | added /100 | requests | capped pages | errors | empty pages | reading s |',
             '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|']
    for arm, a in arms.items():
        lines.append(f'| {NAMES[arm]} | {f1(100 * a["nes"])} | {f1(100 * a["bowf1"])} | '
                     f'{f1(a["missed"])} | {f1(a["added"])} | {a["requests"]:,} | {a["pages_capped"]} | {a["errors"]} | '
                     f'{a["empty"]} | {a["seconds"]:,.0f} |')
    lines += ['', 'The no-fill row is the partition\'s own requests less the fill: its seconds and requests are a',
              'subset of the partition\'s, not a route the app runs. Seconds are reading only (model loaded once);',
              'preparation is above. Missed and added are word counts against the truth\'s (added: words the truth',
              'does not hold, so repetition, invention and duplication alike). A capped page has a request that ran',
              'to its token cap. NewsBench\'s order gap is left out: with more added words than truth words its CER',
              'term passes 1 and the gap stops measuring order.', '', '## Paired differences', '',
              'Δ is the first arm minus the second, the paired mean over the 15 pages, with its 95% page-bootstrap',
              'interval and a two-sided paired permutation p; an interval crossing 0, or a gap under the 0.49-point floor,',
              'is a tie. For missed and added words lower is better, so the verdict names the arm with fewer.', '']
    for m, title, _ in MEASURES:
        lines += [f'### {title}', '', '| pair | first | second | Δ | p | wins first / second | verdict |',
                  '|---|---:|---:|---:|---:|---:|---|']
        for k, d in comps[m].items():
            lines.append(f'| {k} | {f1(d["a"])} | {f1(d["b"])} | {iv(d)} | {d["p"]:.3f} | {d["a_wins"]} / '
                         f'{d["b_wins"]} | {d["verdict"]} |')
        lines.append('')
    return '\n'.join(lines) + '\n' + CARD


def findings(plan: dict, arms: dict, comps: dict) -> list[str]:
    s, o = comps['nes'], comps['bowf1']
    iv = lambda d: f'{d["delta"]:+.1f} [{d["lo"]:+.1f}, {d["hi"]:+.1f}]'
    n = lambda arm, m='nes': f'{100 * arms[arm][m]:.1f}'
    p, r, nf = arms['partition'], arms['raw'], arms['partition-nofill']
    return ['## What this says', '',
            f'- **The shipped partition loses almost all of the region gain on L9.** For this reader it scores'
            f' {n("partition")} strict NES against {n("raw")} for the raw regions, {iv(s["partition − raw"])}, behind on'
            f' all 15 pages; order-free {n("partition", "bowf1")} against {n("raw", "bowf1")},'
            f' {iv(o["partition − raw"])}. Routed as the app routes it (one page whole by the kind gate) it is'
            f' {iv(s["app − raw"])}.',
            f'- **It ties the whole page in order** ({n("partition")} against {n("whole")}, {iv(s["partition − whole"])}),'
            f' and leads it only order-free ({iv(o["partition − whole"])}); the raw regions lead the whole page by'
            f' {iv(s["raw − whole"])}.',
            f'- **Why: the fill is most of the page.** The boundary guard and its transitive overlap moved'
            f' {plan["fill_lines"]:,} of {plan["vision_lines"]:,} Vision lines'
            f' ({100 * plan["fill_lines"] / plan["vision_lines"]:.0f}%) out of the regions into the masked whole-page'
            f' fill, on all 15 pages, and the fill carried {100 * plan["fill_word_share"]:.0f}% of the words read. The'
            f' fill is read at whole-page size, so it fails as the whole page fails: it ran to its token cap on every'
            f' page. Many masked crops are left almost blank, and the reader invents text on them: without the fill the'
            f' partition still adds {nf["added"]:.0f} words per 100 against the raw regions\' {r["added"]:.0f}.',
            f'- **Content, not order.** The partition\'s strict and order-free figures are both near 20; it misses'
            f' {p["missed"]:.0f} of every 100 truth words against {r["missed"]:.0f} for the raw regions, and adds'
            f' {p["added"]:.0f}.',
            f'- **Cost.** {p["requests"]:,} requests and {p["seconds"]:,.0f} s of reading against {r["requests"]:,} and'
            f' {r["seconds"]:,.0f} s for the raw regions and {arms["whole"]["seconds"]:,.0f} s for the whole page, plus'
            f' {plan["prepare_seconds"]:.0f} s of preparation (kind, Vision, detector) for the partition.',
            '- **The owner\'s choices stand.** The detector, its order and regions for every reader are untouched; what',
            '  fails is the fill policy added with them in W46.layout-newspapers. The raw-region arm is the policy stage',
            '  03 measured, and it reads well here too. The fix is filed as W46.layout-partition-fix.', '']


CARD = """## Measurement card

- **Truth.** L9's published transcriptions (the newspaper benchmark's own text), independent of every arm and of
  the reader. The owner checked nothing specific to this item.
- **Selection.** The 15 frozen L9 pages of the 895 (sha256-checked), the bench's frozen draw, not chosen by any
  arm's or reader's output. No ABBYY text was used.
- **Comparison.**
  - Same inputs and settings: every arm reads the same frozen original with the same reader, prompt, temperature,
    2,048 px ceiling and token caps (8,192 a whole-page-sized image, 4,096 a crop), predeclared in the item note
    before any reading. The partition images are the app's own (`NewspaperPagePlan.prepare` in the Debug Processor,
    real detector, the app's Vision lines); the raw-region crops are cut from the same detection with the same
    padding. The raw arm differs only by the measured baseline's rules: pictures dropped, a region 90% inside a
    larger one dropped, no masking, no fill.
  - Fresh controls: the Sherlock replies of W46.ocr-regions were not reused (another runtime, quantisation and image
    size). This reader's raw regions here (84.6 strict) sit near PaddleOCR-VL 1.5's 89.7 on the same detector's
    regions there (layout-pair-newspapers.md), so the baseline reproduces.
  - Both OCR sets: the owner's 96 has no newspaper page by its labels, so there is nothing to pair there; whether
    the kind gate routes any of the 96 to the newspaper stage was not checked here.
- **Noise.** n = 15 pages, paired; one temperature-0 reading per arm. The pages hold at most 12 items, almost all one
  Library of Congress collection, so the page bootstrap is optimistic, but the 64-point gap is many times any
  interval here and the 0.49-point rerun floor, and no page goes the other way.
- **Scope.**
  - One small reader with published weights, the app's shipped Mac PaddleOCR-VL 1.6 4-bit, standing in for a page
    reader: the loop is `read-model.py`'s and the 2,048 px ceiling the Processor's, but each hosted provider encodes
    its own image. Larger readers are not measured. That the fill reads like a whole page for any reader is an
    inference from the geometry (83% of lines in a whole-page-sized image), not a measurement; for a reader whose
    whole page ties its regions the loss would be small.
  - Scans only; photographed newspapers are unmeasured, as before.
  - The detector ran from the lab's PP-DocLayoutV3 MLX copy, whose 857 tensors W46.layout-newspapers found equal to
    the app's pinned snapshot; its config file is the pinned one.
"""


if __name__ == '__main__':
    main()
