#!/usr/bin/env python3
"""W46.reader-keeps-lines. Which hands readers keep the page's lines: for every reader with a hand figure in stage
04's table (settings-routes.json, reading rows with `hands16`), the reading's line count against kraken blla's
detected lines on the owner hand pages of the placement truth (place_hands.pages(), the audited ones), from saved
readings. A reader that reflows (joins the page's lines into paragraphs) cannot be placed line by line, so the hand
route sends its pages to the text page (05-placement.md); this gives every reader its `reflows` flag.

  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy python reader_keeps_lines.py

Reads saved files only: the readings are ocr_rescore.owner_sources() named as ocr_hands_rescore names them (the
names the table's hands16 sources carry), PP-OCRv6 over blla lines is ocr_ppocrv6_hands' saved `blla-hands` texts,
and the lines are place_hands' saved blla detections. A reading's lines are place_hands.clean()'s (markup, empty
and rule lines off), the same lines its line-count pick and aligner see. No model, no network, no money.

A reader reflows when its median page keeps under place_hands.REFLOW (0.7) of blla's lines: the share below which
the shipped line-count pick already treats a page as reflowed. Writes segbench-results/reader-keeps-lines.md and
.json (counts only; no text).
"""
from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import place_hands as P          # noqa: E402

RESULTS = HERE.parents[1] / 'segbench-results'
ROUTES = RESULTS / 'settings-routes.json'
OUT = RESULTS / 'reader-keeps-lines'
REFLOW = P.REFLOW
CLOSE = 0.1    # a median this near REFLOW is said to be close
SPLITS = 1.5   # a median page with this many reading lines per blla line breaks lines blla keeps whole (noted, not gated)
LINE_PASS = {'lightonocr3-4b': 21.5, 'gemini3.8-flash': 41.3, 'qwen3.6-27b': 42.9}  # place-hands-lines.md, shipped placer


def hand_readers() -> list[tuple[str, str, str]]:
    """(row id, row name, reading name) for every stage 04 row with a hand figure."""
    st = next(s for s in json.loads(ROUTES.read_text())['stages'] if s['id'] == 'reading')
    return [(r['id'], r['name'], r['figures']['hands16']['source']['route'])
            for r in st['routes'] if 'hands16' in r.get('figures', {})]


def texts() -> dict[str, dict[str, str]]:
    import ocr_hands_rescore as H
    import ocr_ppocrv6_hands as PP
    import ocr_panel
    src = H.readings([r['page'] for r in ocr_panel.rows()])
    src['ppocrv6-kraken-blla'] = PP._texts(PP.RUN / 'zero' / 'blla-hands', PP.owner_pages())
    return src


def blla_lines(t) -> int:
    return len(json.loads((P.CACHE / 'lines' / 'blla' / f'{P.key(t)}.json').read_text())['lines'])


def build() -> dict:
    ps = [t for t in P.pages() if t['group'] == 'owner-hand' and P.keep(t)]
    det = {t['page']: blla_lines(t) for t in ps}
    tru = {t['page']: len(P.reading(t, 'truth')) for t in ps}
    src = texts()
    rows = []
    for rid, name, rname in hand_readers():
        got = src.get(rname)
        if got is None:
            raise SystemExit(f'{rid}: no saved readings under {rname!r}')
        per = {}
        for t in ps:
            txt = (got.get(t['page']) or '').strip()
            if txt:
                n = len(P.clean(txt))
                per[t['page']] = {'lines': n, 'blla': det[t['page']], 'truth': tru[t['page']],
                                  'ratio': round(n / det[t['page']], 3)}
        if not per:
            rows.append({'id': rid, 'name': name, 'reading': rname, 'pages': 0, 'reflows': None})
            continue
        ratios = [v['ratio'] for v in per.values()]
        med = statistics.median(ratios)
        rows.append({'id': rid, 'name': name, 'reading': rname, 'pages': len(per),
                     'lines': sum(v['lines'] for v in per.values()), 'blla': sum(v['blla'] for v in per.values()),
                     'truth': sum(v['truth'] for v in per.values()),
                     'median_ratio': round(med, 3),
                     'median_truth_ratio': round(statistics.median(v['lines'] / v['truth'] for v in per.values()), 3),
                     'pages_under': sum(r < REFLOW for r in ratios),
                     'reflows': med < REFLOW, 'splits': med >= SPLITS,
                     'line_pass': LINE_PASS.get(rname), 'per_page': per})
    rows.sort(key=lambda r: (r.get('median_ratio') is None, r.get('median_ratio') or 0))
    return {'item': 'W46.reader-keeps-lines', 'pages': [t['page'] for t in ps], 'reflow_below': REFLOW,
            'splits_at': SPLITS, 'blla_lines': sum(det.values()), 'truth_lines': sum(tru.values()), 'rows': rows}


def write_md(d: dict):
    rows = [r for r in d['rows'] if r['pages']]
    flagged = [r for r in rows if r['reflows']]
    near = [r for r in rows if abs(r['median_ratio'] - d['reflow_below']) < CLOSE
            or (not r['reflows'] and r['pages_under'] >= r['pages'] / 4)]
    L = ['# Which hands readers keep the page\'s lines (W46.reader-keeps-lines)', '',
         'Generated by `scripts/segbench/reader_keeps_lines.py` from saved readings: every reader with a hand figure in '
         'stage 04\'s table (`settings-routes.json`), its reading\'s line count against kraken blla\'s detected lines '
         f'on the {len(d["pages"])} audited owner hand pages of the placement truth ({d["blla_lines"]} blla lines; the '
         f'truth has {d["truth_lines"]}). A reading\'s lines are `place_hands.clean()`\'s, as the hand aligner sees '
         'them. No model ran, nothing left the Mac, no money was spent.', '',
         '## Verdict', '']
    L.append(f'- **{len(flagged)} of {len(rows)} hands readers reflow**: '
             + (', '.join(f'{r["name"]} ({r["median_ratio"]:.2f})' for r in flagged) or 'none')
             + f'. Their median page keeps under {d["reflow_below"]} of blla\'s lines, the share at which the shipped '
               'line-count pick already counts a page as reflowed. The hand route gives their pages the text page '
               '(05-placement.md); the table carries `reflows: true` on their rows.')
    L.append('- **The flag agrees with the line pass score where both exist.** '
             + '; '.join(f'{r["name"]}: median {r["median_ratio"]:.2f} of blla\'s lines, line pass {r["line_pass"]}%'
                         for r in rows if r['line_pass'] is not None)
             + ' (place-hands-lines.md, shipped placer). LightOnOCR-3 is the reflowing reader that score found.')
    if near:
        L.append('- **Close to the line:** '
                 + ', '.join(f'{r["name"]} (median {r["median_ratio"]:.2f}, {r["pages_under"]} of {r["pages"]} pages '
                             f'under; {"reflows" if r["reflows"] else "kept"})' for r in near)
                 + f'. A median within {CLOSE} of the bar, or a quarter or more of the pages under it. On a kept '
                   'reader\'s reflowed page the shipped per-page line-count pick still applies, which is why the flag '
                   'is per reader and the pick per page.')
    sp = [r for r in rows if r['splits']]
    if sp:
        L.append('- **Readers that split lines** (median at least ' f'{d["splits_at"]} reading lines a blla line): '
                 + ', '.join(f'{r["name"]} ({r["median_ratio"]:.2f})' for r in sp)
                 + '. Not a reflow; the span matcher maps several reading lines onto one detected line only one way, '
                   'so these are worth a line pass score before the route trusts their placement.')
    none = [r for r in d['rows'] if not r['pages']]
    if none:
        L.append('- **No saved reading of these pages:** ' + ', '.join(r['name'] for r in none) + '; no flag.')
    L += ['', '## Measurement card', '',
          '- **Truth.** No text truth is scored. The yardstick is kraken blla\'s saved line detection, the detector '
          'the hand route ships, on the placement truth\'s audited owner hand pages; the truth\'s own line count '
          '(drawn lines, the owner\'s hand-line rulings folded in) is shown beside it as a check that blla is not '
          'the reason for a ratio.',
          '- **Selection.** All audited owner hand pages of the placement truth; no reader, detector or ABBYY text '
          'chose them. Readers: every stage 04 row with a hand figure.',
          '- **Comparison.** Every reader\'s saved reading of the same pages (the original-scale panel image, its own '
          'run settings), cleaned the same way. A page a reader left empty is left out of its median, so `pages` '
          'can be under the set.',
          '- **Noise.** A count of saved text, deterministic. The flag sits on a median of up to '
          f'{len(d["pages"])} pages; a reader whose median is within {CLOSE} of {d["reflow_below"]} is close and is '
          'said to be.',
          '- **Scope.** Says whether a reader keeps line breaks, not whether its lines are placed well (that is the '
          'line pass score, place-hands-lines.md, measured for three readings); not Bentham or other collections; '
          'a reader\'s prompt can change its line behaviour, so the flag is for the reading the table scores.',
          '', '## Every reader', '',
          'Ratio: reading lines over blla lines, per page; the median is the flag\'s basis. Under: pages under '
          f'{d["reflow_below"]}.', '',
          '| reader | pages | reading lines | blla lines | truth lines | median ratio | vs truth | pages under | reflows |',
          '|---|---:|---:|---:|---:|---:|---:|---:|---|']
    for r in d['rows']:
        if not r['pages']:
            L.append(f'| {r["name"]} | 0 | | | | | | | — |')
            continue
        L.append(f'| {r["name"]} | {r["pages"]} | {r["lines"]} | {r["blla"]} | {r["truth"]} | {r["median_ratio"]:.2f} '
                 f'| {r["median_truth_ratio"]:.2f} | {r["pages_under"]} | {"**yes**" if r["reflows"] else "no"} |')
    (OUT.with_suffix('.md')).write_text('\n'.join(L) + '\n')


def main():
    d = build()
    OUT.with_suffix('.json').write_text(json.dumps(d, indent=1, ensure_ascii=False) + '\n')
    write_md(d)
    for r in d['rows']:
        print(r['id'], r['pages'], r.get('median_ratio'), r.get('pages_under'), r['reflows'])


if __name__ == '__main__':
    main()
