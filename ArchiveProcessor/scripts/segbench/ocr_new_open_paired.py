#!/usr/bin/env python3
"""W46.ocr-new-open: paired intervals for the new open readers against the incumbents, on both sets.

  python3 ocr_new_open_paired.py [--pages ../../segbench-results/ocr-scorers-pages.csv]

The measurement audit's OCR-2 (execution-plans/processing-review/11-measurement-audit.md): each new route against
Qwen3.6 27B and LightOnOCR-3 4B, on the owner's 96 and the 895, two ways. Strict pairs every page and scores a
failure as 0. Answered pairs only the pages both routes answered. Each comparison has its mean NES difference, a
95% bootstrap interval and a paired permutation p (ocr_panel_score.paired), with each route's failure count beside
it. Every failure here is the model's (a reply that ran to the token cap or came back empty). The Sherlock runs
logged no request errors, so no failure is a provider's. Reads ocr_rescore.py's per-page scores; no text, no model.
Writes segbench-results/new-open-paired.json.
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import ocr_panel_score as S

HERE = Path(__file__).resolve().parent
RESULTS = HERE.parent.parent / 'segbench-results'
NEW = ['xiaomi-ocr-0', 'paddleocr-vl1.6', 'qwen3.8-27b', 'xiaomi-ocr-0-bf16', 'paddleocr-vl1.6-bf16']
# The incumbent per set: the reading the bench shows for that route on that set.
INCUMBENTS = {'owner96': {'qwen3.6-27b': 'local panel', 'lightonocr3-4b': 'FarmShare native'},
              'public895': {'qwen3.6-27b': 'FarmShare panel', 'lightonocr3-4b': 'FarmShare native'}}


def load(path):
    out = {}
    with path.open(newline='') as f:
        for r in csv.DictReader(f):
            out.setdefault((r['set'], r['route'], r['family']), {})[r['page']] = (r['ok'] == 'True', float(r['nes']))
    return out


def compare(a, b):
    pages = sorted(set(a) & set(b))
    strict = S.paired([a[p][1] for p in pages], [b[p][1] for p in pages])
    both = [p for p in pages if a[p][0] and b[p][0]]
    answered = S.paired([a[p][1] for p in both], [b[p][1] for p in both])
    r = lambda d: {k: round(v, 4) if isinstance(v, float) else v for k, v in d.items()}
    return {'pages': len(pages), 'failed': sum(not a[p][0] for p in pages), 'failed_other': sum(not b[p][0] for p in pages),
            'strict': r(strict), 'answered': r(answered)}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--pages', type=Path, default=RESULTS / 'ocr-scorers-pages.csv')
    ap.add_argument('--out', type=Path, default=RESULTS / 'new-open-paired.json')
    a = ap.parse_args()
    rows = load(a.pages)
    out = []
    for (st, route, family), pages in sorted(rows.items()):
        if route not in NEW:
            continue
        for inc, inc_family in INCUMBENTS[st].items():
            other = rows.get((st, inc, inc_family))
            if other is None:
                raise SystemExit(f'no {inc} ({inc_family}) on {st} in {a.pages}')
            c = compare(pages, other)
            out.append({'set': st, 'route': route, 'family': family, 'against': inc, **c})
            s, w = c['strict'], c['answered']
            print(f"{st:9} {route:22} - {inc:15} strict {100*s['delta']:+6.2f} ({100*s['lo']:+.2f} to {100*s['hi']:+.2f}) "
                  f"answered {100*w['delta']:+6.2f} ({100*w['lo']:+.2f} to {100*w['hi']:+.2f}) n={w['n']} "
                  f"failed {c['failed']}/{c['failed_other']}")
    a.out.write_text(json.dumps({'source': str(a.pages.name), 'rows': out}, indent=1) + '\n')


if __name__ == '__main__':
    main()
