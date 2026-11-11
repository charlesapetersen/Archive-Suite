#!/usr/bin/env python3
"""W46.layout-pair-newspapers — PP-DocLayoutV3 against DocLayout-YOLO, paired, on the L9 newspaper scans.

No inference: both detectors were read by the same four open readers on the same 15 L9 pages in W46.ocr-regions
(regions-20261021, strict NES in reading order) and rescored order-free (bag-of-words F1) in
W46.ocr-rescore-offline (regions-orderfree-20261030). DocLayout-YOLO there is the newspaper-ocr route
(`yolo_newsocr` in layout-photo). This pairs the two detectors page by page, per reader and over the readers'
per-page mean, with ocr_panel_score.paired's interval and permutation p.

  python3 scripts/segbench/layout_pair_newspapers.py   # writes segbench-results/layout-pair-newspapers.{md,json}
"""
from __future__ import annotations

import csv
import json
import random
import statistics as st
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
RES = ROOT / 'segbench-results'
STRICT = RES / 'bench-corpus' / 'regions-20261021-pages.csv'
ORDERFREE = RES / 'bench-corpus' / 'regions-orderfree-20261030-pages.csv'
READERS = [('glm-ocr', 'GLM-OCR'), ('paddleocr-vl1.5', 'PaddleOCR-VL 1.5'),
           ('lightonocr3-4b', 'LightOnOCR-3 4B'), ('qwen3.6-27b', 'Qwen3.6-27B')]
PP, YOLO = 'pp-doclayoutv3', 'doclayout_yolo'
FLOOR = 0.0049  # ocr-rerun-noise.md's hosted floor; cluster routes take it (ocr-pair-matrix card)


def paired(a, b, rounds=10000, seed=0):
    """ocr_panel_score.paired, copied line for line so this stays stdlib-only (that module needs `regex`)."""
    d = [x - y for x, y in zip(a, b, strict=True)]
    rng = random.Random(seed); n = len(d); delta = sum(d) / n
    extreme = sum(abs(sum(x if rng.random() < .5 else -x for x in d)) >= abs(sum(d)) - 1e-12 for _ in range(rounds))
    boots = sorted(sum(rng.choice(d) for _ in range(n)) / n for _ in range(rounds))
    return {'n': n, 'delta': delta, 'p': (extreme + 1) / (rounds + 1),
            'lo': boots[int(.025 * rounds)], 'hi': boots[int(.975 * rounds) - 1]}


def load(path: Path, field: str, source: str | None = None) -> dict:
    """(route, arm) -> page -> score, on L9."""
    out: dict = {}
    for r in csv.DictReader(path.open()):
        if 'L9' not in r['groups'].split(';') or (source and r.get('source') != source):
            continue
        out.setdefault((r['route'], r['arm']), {})[r['page']] = float(r[field])
    return out


def pair(a: dict, b: dict) -> dict:
    pages = sorted(set(a) & set(b))
    d = paired([a[p] for p in pages], [b[p] for p in pages])
    d.update(pp=st.mean(a[p] for p in pages), yolo=st.mean(b[p] for p in pages),
             pp_wins=sum(a[p] > b[p] for p in pages), yolo_wins=sum(a[p] < b[p] for p in pages))
    d['verdict'] = ('tie' if d['lo'] <= 0 <= d['hi'] or abs(d['delta']) < FLOOR
                    else 'PP-DocLayoutV3' if d['delta'] > 0 else 'DocLayout-YOLO')
    return d


def mean_over_readers(scores: dict, arm: str) -> dict:
    pages = set.intersection(*(set(scores[(r, arm)]) for r, _ in READERS))
    return {p: st.mean(scores[(r, arm)][p] for r, _ in READERS) for p in pages}


def main() -> None:
    measures = {'strict NES, in order': load(STRICT, 'nes'),
                'order-free bag-of-words F1': load(ORDERFREE, 'bowf1', 'open readers')}
    out = {}
    for m, sc in measures.items():
        out[m] = {name: pair(sc[(r, PP)], sc[(r, YOLO)]) for r, name in READERS}
        out[m]['mean of the four readers'] = pair(mean_over_readers(sc, PP), mean_over_readers(sc, YOLO))
    (RES / 'layout-pair-newspapers.json').write_text(json.dumps(out, indent=1) + '\n')
    (RES / 'layout-pair-newspapers.md').write_text(render(out))


def render(out: dict) -> str:
    f = lambda x: f'{100 * x:.1f}'
    iv = lambda d: f'{100 * d["delta"]:+.1f} [{100 * d["lo"]:+.1f}, {100 * d["hi"]:+.1f}]'
    lines = ['# W46.layout-pair-newspapers — PP-DocLayoutV3 against DocLayout-YOLO, paired, on L9', '',
             'Δ is PP-DocLayoutV3 minus DocLayout-YOLO (the newspaper-ocr route), the paired mean over the 15 L9',
             'pages in points, with its 95% bootstrap interval and a two-sided paired permutation p. Wins count the',
             'pages on which each detector scored higher. $0: no model, network or cluster; the readings are',
             "W46.ocr-regions' (regions-20261021).", '']
    s, o = out['strict NES, in order']['mean of the four readers'], out['order-free bag-of-words F1']['mean of the four readers']
    won = [n for n, d in out['strict NES, in order'].items() if d['verdict'] == 'DocLayout-YOLO' and n != 'mean of the four readers']
    lines += ['## What this says', '',
              f'- **On scanned newspapers DocLayout-YOLO beats PP-DocLayoutV3, paired.** Over the four readers PP-DocLayoutV3',
              f'  is {iv(s)} strict NES behind ({f(s["pp"])} against {f(s["yolo"])}), beyond the interval for {len(won)} of 4',
              f'  readers ({", ".join(won)}); PaddleOCR-VL 1.5 is a tie. The unpaired 86.2 against 91.1 of',
              '  layout-photo-tables.md (GLM-OCR) is a real gap once paired.',
              f'- **The gap is content, not only order.** Order-free it narrows to {iv(o)} and stays below 0 for every',
              '  reader: PP-DocLayoutV3 regions miss or garble words that DocLayout-YOLO\'s regions keep.',
              '- **This does not by itself change the app\'s detector.** The stage rule (03-layout.md section 6) switches',
              '  only if the other detector also clears PP-DocLayoutV3 on photographed newspapers after the quad; no',
              '  photographed newspaper set with truth exists. On photographed modern print (Real5, quad first, GLM-OCR,',
              '  unpaired, the same detector with the app sort) DocLayout-YOLO trails PP-DocLayoutV3 on Skew and Warping',
              '  (78.2 against 89.1, 78.7 against 85.9), and on the owner\'s 96 photographs it is 70.9 against 84.9',
              '  (layout-photo-tables.md). The owner\'s pages are photographs, so PP-DocLayoutV3 stays the newspaper',
              '  detector; the scan-only loss of about 5 points is stated with it, and W46.layout-photo-newspapers',
              '  (behind W46.nice-to-have) is what would test the photographed half.', '',
              '## Results', '']
    for m, rows in out.items():
        lines += [f'### {m}', '', '| reader | PP-DocLayoutV3 | DocLayout-YOLO | Δ PP − YOLO | p | wins PP / YOLO | verdict |',
                  '|---|---:|---:|---:|---:|---:|---|']
        lines += [f'| {name} | {f(d["pp"])} | {f(d["yolo"])} | {iv(d)} | {d["p"]:.3f} | {d["pp_wins"]} / '
                  f'{d["yolo_wins"]} | {d["verdict"]} |' for name, d in rows.items()]
        lines.append('')
    return '\n'.join(lines) + '\n' + CARD


CARD = """## Measurement card

- **Truth.** L9's published transcriptions (the newspaper benchmark's own text), independent of every route here.
  The owner checked nothing specific to this item.
- **Selection.** The 15 frozen L9 pages of the 895 that W46.ocr-regions read; chosen by the bench's frozen draw,
  not by any detector's or reader's output. No ABBYY text was used.
- **Comparison.**
  - Same inputs: each reader read both detectors' crops of the same 2,400 px copies with the same prompt and
    settings in the one 2026-10-21 Sherlock pack; only the detector differs. Each arm is stitched in its own
    detector's order (DocLayout-YOLO through newspaper-ocr's column sort, PP-DocLayoutV3 in its own order).
  - Strict NES scores the stitched order; the order-free figure (bag-of-words F1, W46.ocr-rescore-offline)
    removes order, so a gap that survives it is content, not ordering.
  - Both OCR sets: the owner's 96 has no newspaper page, so this pair has nothing to say there. The detectors'
    figures on the 96 are in layout-photo-tables.md and regions-20261021.md (PP-DocLayoutV3 above DocLayout-YOLO).
- **Noise.**
  - n = 15 pages, paired; one reading at temperature 0 per arm. A paired interval that crosses 0 is a tie, as is a
    gap under the 0.49-point rerun floor (ocr-rerun-noise.md, taken by cluster routes as in ocr-pair-matrix.md).
  - 15 pages is under the 20-page line below which a group is descriptive in the parent reports; the intervals
    here are wide for that reason.
- **Scope.**
  - Scans only. No photographed newspaper set with truth exists (the owner corpus has none labelled), so the
    quad-then-detector route on photographed newspapers stays unmeasured; that is W46.layout-photo-newspapers.
  - Detector thresholds are the shipped or maker defaults, not tuned.
  - Four open readers on the cluster; the gateway arm (Gemini 3.7 Flash) read only PP-DocLayoutV3 on 3 L9 pages,
    so it cannot be paired.
"""

if __name__ == '__main__':
    main()
