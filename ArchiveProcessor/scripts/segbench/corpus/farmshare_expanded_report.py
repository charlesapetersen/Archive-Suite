#!/usr/bin/env python3
"""Score saved expanded OCR without new inference; retain the original440 report unchanged."""
from pathlib import Path
import argparse
import collections
import json

import routes as R
import farmshare_results as F
import ocr_panel_score as S


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--manifest', type=Path, required=True)
    ap.add_argument('--base', type=Path, required=True)
    ap.add_argument('--run', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    R.MANIFEST = a.manifest
    truth = R.frozen()
    old = {R.job_id(r) for r in R.C.read_jsonl(a.base)}
    want = {R.job_id(r) for r in truth}
    if not old <= want or len(want) != len(truth):
        raise ValueError('Removed or duplicate reference page')
    full_label, old_label, added_label = f'full{len(want)}', f'original{len(old)}', f'added{len(want)-len(old)}'
    pages, groups = [], collections.defaultdict(list)
    for model in ('qwen3.6-27b', 'qwen3.5-27b', 'qwen3.6-35b-a3b'):
        records = F.read_records(a.run / model)
        if set(records) != want:
            raise ValueError(f'{model}: expected every frozen page exactly once')
        for r in truth:
            jid = R.job_id(r)
            text = F.reading(records[jid], 'panel')
            row = {'route': model, 'page': jid, 'stratum': r['stratum'], 'source': r['source'],
                   'subset': old_label if jid in old else added_label,
                   'ok': bool(text), **S.score(Path(r['truth']).read_text(), text, r['stratum'])}
            pages.append(row)
            for split in (full_label, row['subset']):
                groups[(model, split, r['stratum'])].append(row)
                groups[(model, split, 'all')].append(row)
    rows = [{'route': model, 'subset': split, 'stratum': stratum, **S.aggregate(rr)}
            for (model, split, stratum), rr in sorted(groups.items())]
    a.out.mkdir(parents=True, exist_ok=True)
    S.write_csv(a.out / 'farmshare-expanded.csv', rows,
                ['route', 'subset', 'stratum', 'n', 'ok', 'failed', 'nes', 'nes_answered', 'chrf'])
    S.write_csv(a.out / 'farmshare-expanded-pages.csv', pages,
                ['route', 'page', 'subset', 'stratum', 'source', 'ok', 'nes', 'nes_mapped', 'nes_no_marks', 'chrf'])
    summary = [r for r in rows if r['stratum'] == 'all']
    (a.out / 'farmshare-expanded.json').write_text(json.dumps({'models': summary,
      'manifest_sha256': R.C.sha256(a.manifest),
      'note': 'Different page mix: the expanded total is not directly comparable to hosted references on the original pages only. No original report overwritten; no new inference.'}, indent=2)+'\n')
    print(json.dumps(summary), flush=True)


if __name__ == '__main__':
    main()
