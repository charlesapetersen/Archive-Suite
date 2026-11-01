#!/usr/bin/env python3
"""W46.ocr-new-open-boxes: audit cached readings and box geometry; no inference or text exported.

  python ocr_boxes_audit.py [--cache ~/Library/Caches/ArchiveSuiteRehearsal/sherlock-results]

The two completed readers must cover the same frozen image identities, have one job per set, and use
identical settings on both sets. Geometry counts are independent checks, on answered pages only; they
are not placement scores. Raw blocks and their text stay in the cache for W46.place-print.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
import math
from pathlib import Path
import statistics
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'corpus'))
import farmshare_results as F
import ocr_panel as P

KEYS = ('unlimited-ocr', 'nemotron-parse-2')
LIMITS = {'unlimited-999': 999, 'nemotron-canvas-1': 1, 'doctags-500': 500}


def geometry(box):
    """Independent validity failures; never repair or silently clamp emitted coordinates."""
    coords, limit = box.get('box'), LIMITS.get(box.get('units'))
    if limit is None or not isinstance(coords, list) or len(coords) != 4:
        return {'malformed'}
    if any(not isinstance(v, (int, float)) or not math.isfinite(v) for v in coords):
        return {'malformed'}
    x1, y1, x2, y2 = coords
    return {k for k, failed in {'out_of_range': any(v < 0 or v > limit for v in coords),
                               'reversed': x2 < x1 or y2 < y1,
                               'zero_area': x2 == x1 or y2 == y1}.items() if failed}


def audit(root, expected, excluded=frozenset()):
    records = F.read_records(root / 'results/ocr' / root.name)
    if set(records) != set(expected):
        raise ValueError(f'{root.name}: record IDs differ from frozen set')
    jobs = {r.get('job') for r in records.values()}
    if len(jobs) != 1 or not all(jobs):
        raise ValueError(f'{root.name}: multiple or missing job IDs: {jobs}')
    contract = json.loads((root / 'cache-contract.json').read_text())
    status = json.loads((root / 'status.json').read_text())
    if (status['settings'] != contract or status['state'] != 'completed_raw'
            or jobs != {status.get('job')}):
        raise ValueError(f'{root.name}: incomplete run or inconsistent contract')
    for page, r in records.items():
        if r['sha256'] != expected[page] or r['model'] != contract['model']:
            raise ValueError(f'{root.name} {page}: image/model identity differs')
    outcome = lambda r: ('ok' if F.reading(r, 'native') else
                         'cap' if r['status'] == 'cap' or r['finish'] == 'length' else
                         'blank' if r['status'] == 'ok' and r['finish'] == 'stop' else 'error')
    answered = [r for r in records.values() if outcome(r) == 'ok']
    boxes = [b for r in answered for b in r['boxes']]
    invalid = Counter(k for b in boxes for k in geometry(b))
    walls = [r['wall_s'] for r in records.values()]
    wall = status['wall_s'] + json.loads((root / 'pilot-summary.json').read_text())['wall_s']
    return {'job': next(iter(jobs)), 'contract': contract, 'records': len(records),
            'outcomes': dict(Counter(outcome(r) for r in records.values())),
            'scored_outcomes': dict(Counter(outcome(r) for p, r in records.items() if p not in excluded)),
            'load_s': status['load_s'], 'collector_s': wall,
            'median_page_s': statistics.median(walls), 'max_page_s': max(walls),
            'pages_per_hour': round(len(records) * 3600 / wall, 1),
            'all_boxes': sum(len(r['boxes']) for r in records.values()),
            'answered_pages_with_boxes': sum(bool(r['boxes']) for r in answered),
            'answered_boxes': len(boxes), 'invalid_geometry': dict(invalid),
            'invalid_boxes': sum(bool(geometry(b)) for b in boxes),
            'classes': dict(sorted(Counter(b['cls'] for b in boxes).items())),
            'units': sorted({b['units'] for b in boxes})}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--cache', type=Path, default=P.CACHE.parent / 'sherlock-results')
    ap.add_argument('--out', type=Path, default=P.RESULTS / 'bench-corpus/new-open-boxes-audit.json')
    ap.add_argument('--public', type=Path, default=Path.home() /
                    'Claude/Long term storage/FarmShare-open-sweep-20261019/public895.jsonl')
    a = ap.parse_args()
    public = [json.loads(line) for line in a.public.read_text().splitlines() if line.strip()]
    owner = [r for r in P.manifest()['jobs'] if r['scale'] == 'original']
    if len(public) != 895 or len(owner) != 99:
        raise ValueError('expected the frozen 895 and 99 manifests')
    out = {}
    for label, st, jobs in [('public895', '895', public), ('owner99', '96', owner)]:
        expected = {r['id']: r['sha256'] for r in jobs}
        out[label] = {key: audit(a.cache / ('new-open-' + st) / key, expected,
                                P.AGREEMENT if st == '96' else frozenset()) for key in KEYS}
    for key in KEYS:
        if out['public895'][key]['contract'] != out['owner99'][key]['contract']:
            raise ValueError(f'{key}: settings differ between sets')
    a.out.write_text(json.dumps(out, indent=1) + '\n')
    print(f'audited both readers on both frozen sets -> {a.out}')


if __name__ == '__main__':
    main()
