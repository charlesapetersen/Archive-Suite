#!/usr/bin/env python3
"""Score saved expanded OCR without new inference; retain the original440 report unchanged.

  farmshare_expanded_report.py --manifest M895 --base M440 --run DIR --out DIR
      the three Qwen panel models under DIR/<model> (W43.farmshare-ocr-more)
  farmshare_expanded_report.py --manifest M895 --base M440 --out DIR --name open-sweep-20261019 \
      --route glm-ocr=PATH:native --route qwen3-vl-8b=PATH:panel ...
      any saved-output folders (W43.open-sweep-more and after). MODE panel parses the panel prompt's
      KIND/TABLE/TEXT reply; native scores the model's own reply as written (normal() only, as Mistral OCR's
      Markdown is scored). Caps, errors and missing pages score as failures (empty reading).
"""
from pathlib import Path
import argparse
import collections
import json

import routes as R
import farmshare_results as F
import ocr_panel_score as S

SECOND = ('nes_mapped', 'nes_no_marks', 'nes_no_space')


def parse_route(spec):
    label, _, rest = spec.partition('=')
    path, _, mode = rest.rpartition(':')
    if not path or mode not in ('panel', 'native'):
        path, mode = rest, 'panel'
    if not label or not path:
        raise SystemExit(f'--route LABEL=DIR[:panel|native], got {spec!r}')
    return label, Path(path), mode


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--manifest', type=Path, required=True)
    ap.add_argument('--base', type=Path, required=True)
    ap.add_argument('--run', type=Path)
    ap.add_argument('--route', action='append', default=[], metavar='LABEL=DIR[:MODE]')
    ap.add_argument('--name', default='farmshare-expanded')
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    specs = [parse_route(s) for s in a.route]
    if not specs:
        if a.run is None:
            raise SystemExit('give --run or at least one --route')
        specs = [(m, a.run / m, 'panel') for m in ('qwen3.6-27b', 'qwen3.5-27b', 'qwen3.6-35b-a3b')]
    R.MANIFEST = a.manifest
    truth = R.frozen()
    old = {R.job_id(r) for r in R.C.read_jsonl(a.base)}
    want = {R.job_id(r) for r in truth}
    if not old <= want or len(want) != len(truth):
        raise ValueError('Removed or duplicate reference page')
    full_label, old_label, added_label = f'full{len(want)}', f'original{len(old)}', f'added{len(want)-len(old)}'
    pages, groups, coverage = [], collections.defaultdict(list), {}
    for model, folder, mode in specs:
        records = F.read_records(folder)
        if not set(records) <= want:
            raise ValueError(f'{model}: readings for pages outside the frozen manifest')
        status = collections.Counter(r.get('status') for r in records.values())
        coverage[model] = {'mode': mode, 'records': len(records), 'missing': len(want - set(records)),
                           'status': dict(sorted(status.items()))}
        for r in truth:
            jid = R.job_id(r)
            text = F.reading(records.get(jid), mode)
            row = {'route': model, 'mode': mode, 'page': jid, 'stratum': r['stratum'], 'source': r['source'],
                   'subset': old_label if jid in old else added_label,
                   'ok': bool(text), **S.score(Path(r['truth']).read_text(), text, r['stratum'])}
            pages.append(row)
            for split in (full_label, row['subset']):
                groups[(model, split, r['stratum'])].append(row)
                groups[(model, split, 'all')].append(row)
    rows = []
    for (model, split, stratum), rr in sorted(groups.items()):
        agg = S.aggregate(rr)
        for e in SECOND:  # a stratum's second score, only where every page has one (routes.py's rule)
            xs = [r[e] for r in rr if e in r]
            agg[e] = sum(xs) / len(xs) if xs and len(xs) == len(rr) else None
        rows.append({'route': model, 'mode': coverage[model]['mode'], 'subset': split, 'stratum': stratum, **agg})
    a.out.mkdir(parents=True, exist_ok=True)
    S.write_csv(a.out / f'{a.name}.csv', rows,
                ['route', 'mode', 'subset', 'stratum', 'n', 'ok', 'failed', 'nes', 'nes_answered', *SECOND, 'chrf',
                 'miss', 'add', 'words'])
    S.write_csv(a.out / f'{a.name}-pages.csv',  # six places is far below a page score's noise; keeps the file small
                [{k: round(v, 6) if isinstance(v, float) else v for k, v in r.items()} for r in pages],
                ['route', 'page', 'subset', 'stratum', 'source', 'ok', 'nes', 'nes_mapped', 'nes_no_marks', 'chrf',
                 'words', 'missed', 'added'])
    summary = [r for r in rows if r['stratum'] == 'all']
    (a.out / f'{a.name}.json').write_text(json.dumps({'models': summary, 'coverage': coverage,
      'manifest_sha256': R.C.sha256(a.manifest), 'base_sha256': R.C.sha256(a.base),
      'note': 'Different page mix: the expanded total is not directly comparable to hosted references on the original pages only. No original report overwritten; no new inference.'}, indent=2)+'\n')
    print(json.dumps(summary), flush=True)


if __name__ == '__main__':
    main()
