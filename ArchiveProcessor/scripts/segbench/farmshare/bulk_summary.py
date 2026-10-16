#!/usr/bin/env python3
"""Summarise a bulk run for the repo: one row per page and the breakdown by the model's own kind label.
No transcript text leaves FarmShare: a failed reply's KIND line is read and the rest dropped.

  python3 bulk_summary.py OUT_DIR GPUS "MODEL NOTE" LOG...     # LOG: the shards' fs-ocr-bulk-<id>.out files
Writes OUT_DIR/summary.json and OUT_DIR/pages.csv (page, status, finish, kind, table, tokens, seconds, attempts)."""
import csv, glob, json, re, sys, collections
from pathlib import Path
out, gpus, model, logs = Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4:]
rows = {}
for f in (out / '_meta').glob('*.json'):
    m = json.loads(f.read_text())
    rows[f.stem] = {'page': f.stem.replace('.jpg', ''), 'status': m.get('status', 'ok'), 'finish': m.get('finish'),
                    'kind': m.get('kind'), 'table': m.get('table'), 'prompt_tokens': m.get('prompt_tokens'),
                    'completion_tokens': m.get('completion_tokens'), 'wall_s': m.get('wall_s'),
                    'attempts': m.get('attempts', 1)}
answered = set(rows)
for f in sorted(out.glob('failed-*.jsonl')):
    for line in f.read_text().splitlines():
        r = json.loads(line)
        key = r['image']
        if key in answered:      # read again later and answered; otherwise the page's latest failure counts
            continue
        k = re.search(r'KIND:\s*(\w+)', r.get('raw') or '')
        rows[key] = {'page': key.replace('.jpg', ''), 'status': r.get('status'), 'finish': r.get('finish'),
                     'kind': k.group(1).lower() if k else None, 'table': None, 'prompt_tokens': r.get('prompt_tokens'),
                     'completion_tokens': r.get('completion_tokens'), 'wall_s': r.get('wall_s'),
                     'attempts': r.get('attempts', 1)}
shards = [json.loads(l) for log in logs for l in open(log) if l.startswith('{"pages"')]
by_kind = collections.defaultdict(lambda: {'pages': 0, 'failed': 0, 'tokens_out': 0, 'tables': 0})
for r in rows.values():
    b = by_kind[r['kind'] or 'unknown']
    b['pages'] += 1; b['failed'] += r['status'] != 'ok'; b['tokens_out'] += r['completion_tokens'] or 0
    b['tables'] += r['table'] is True
for b in by_kind.values():
    b['mean_tokens_out'] = round(b.pop('tokens_out') / b['pages'])
failed = [r for r in rows.values() if r['status'] != 'ok']
wall = sum(s['wall_s'] for s in shards)
summary = {'pages': len(rows), 'ok': len(rows) - len(failed), 'failed': len(failed), 'gpus': gpus,
           'shards': [{k: s[k] for k in ('pages', 'ok', 'wall_s', 'pages_per_hour_per_gpu')} for s in shards],
           'per_hour_per_gpu': round(sum(s['pages'] for s in shards) / wall * 3600, 1),
           'per_hour_total': round(gpus * sum(s['pages'] for s in shards) / wall * 3600, 1),
           'failures': collections.Counter(f"{r['status']} ({r['finish']})" for r in failed),
           # The loop guard (W41.farmshare-loop-guard): pages read twice, how many the retry answered, and why the
           # rest were listed for escalation.
           'retried': sum(r['attempts'] > 1 for r in rows.values()),
           'recovered_by_retry': sum(r['attempts'] > 1 and r['status'] == 'ok' for r in rows.values()),
           'escalated': collections.Counter(json.loads(l)['reason'] for f in sorted(out.glob('escalate-*.jsonl'))
                                            for l in f.read_text().splitlines() if l.strip()),
           'by_kind': dict(sorted(by_kind.items(), key=lambda kv: -kv[1]['pages'])),
           'note': model + '. wall_s per page is with the server\'s whole batch in flight, so it ranks pages but '
                   'is not a page time. Kind is the model\'s own label.'}
(out / 'summary.json').write_text(json.dumps(summary, indent=1) + '\n')
with (out / 'pages.csv').open('w', newline='') as f:
    w = csv.DictWriter(f, ['page', 'status', 'finish', 'kind', 'table', 'prompt_tokens', 'completion_tokens', 'wall_s',
                           'attempts'])
    w.writeheader(); w.writerows(sorted(rows.values(), key=lambda r: r['page']))
print(json.dumps({k: summary[k] for k in ('pages', 'ok', 'failed', 'per_hour_per_gpu', 'per_hour_total', 'failures', 'retried',
                                       'recovered_by_retry', 'escalated', 'by_kind')}, indent=1))
