#!/usr/bin/env python3
"""Score FarmShare collector readings of the owner's 99 frozen truth pages, as the earlier truth runs were scored.

  farmshare_truth96.py --out ../../../segbench-results/farmshare/truth --sacct OUT/sacct.txt \
      --route glm-ocr=OUT/glm-ocr:native --route qwen3-vl-8b=OUT/qwen3-vl-8b:panel \
      --route ppocrv6-medium=OUT/ppocrv6-medium-native:pipeline ...

Each ROOT is one model's folder from a truth96 run (execution-plans/truth96-farmshare-20261020.md): readings in
ROOT/results/ocr/<folder name>/<page>.json, or ROOT/raw/ for the PP-OCRv6 pipeline. Readings go through
farmshare_expanded_report.reading() in the route's mode (panel parses KIND/TABLE/TEXT; native scores the reply as
written; pipeline accepts status ok without a finish reason), and every page through ocr_panel_score.score() against
the truth text in ocr_panel.TRUTH. Caps, errors, blanks, unparsable panel replies and missing pages score as failures.
Every reading's image SHA-256 must equal the panel manifest's original; a mismatch stops the run.

Writes OUT/<label>-<job>/summary.json and pages.csv in cluster_ocr.py cmd_truth's shape: accuracy_96 without the
three agreement-only letters, agreement_3, clippings, all_99 and throughput, plus outcomes (ok, cap, error, blank,
unparsable, missing; caps that are repetitive) and strata (ocr-truth.md's draw strata and the panel's kinds, over
the 96). No inference; reads saved files only.
"""
from pathlib import Path
import argparse
import collections
import json
import sys
import zlib

import farmshare_expanded_report as X

S, P = X.S, X.R.P
FIELDS = ['page', 'ok', 'outcome', 'nes', 'chrf', 'words', 'hyp_words', 'missed', 'added', 'illegible', 'kind',
          'table_form', 'handwritten', 'clippings', 'tables', 'date_bin', 'prompt_tokens', 'completion_tokens', 'wall_s',
          'status', 'finish']
PRESET_SUFFIX = {'panel': '', 'native': '-native', 'pipeline': '-pipeline'}
REPETITIVE = 0.12  # zlib ratio below which a capped reply is a loop (open-sweep-20261019.md's threshold)


def elapsed_seconds(cell):
    """Slurm's Elapsed, [D-]HH:MM:SS or MM:SS, in seconds."""
    days, _, clock = cell.rpartition('-')
    parts = [int(x) for x in clock.split(':')]
    if len(parts) == 2:
        parts.insert(0, 0)
    if len(parts) != 3:
        raise ValueError(f'not a Slurm elapsed time: {cell!r}')
    h, m, s = parts
    return (int(days) if days else 0) * 86400 + h * 3600 + m * 60 + s


def read_sacct(text):
    """`sacct -X -P -o JobID,JobName,State,Elapsed,...` output: {job id: row}, with elapsed_s added."""
    lines = [l for l in text.splitlines() if l.strip()]
    head = lines[0].split('|')
    out = {}
    for line in lines[1:]:
        row = dict(zip(head, line.split('|')))
        row['elapsed_s'] = elapsed_seconds(row['Elapsed'])
        out[row['JobID']] = row
    return out


def outcome(record, mode, text):
    """Why a page has or has no reading: ok, missing, error, cap, unparsable (panel), blank."""
    if text:
        return 'ok'
    if not record:
        return 'missing'
    if record.get('status') == 'cap' or record.get('finish') == 'length':
        return 'cap'
    if record.get('status') != 'ok' or (mode != 'pipeline' and record.get('finish') != 'stop'):
        return 'error'
    if mode == 'panel' and (record.get('raw') or '').strip():
        return 'unparsable'
    return 'blank'


def repetitive(raw):
    b = (raw or '').encode()
    return bool(b) and len(zlib.compress(b)) / len(b) < REPETITIVE


def readings_dir(root, mode):
    return root / 'raw' if mode == 'pipeline' else root / 'results' / 'ocr' / root.name


def settings(root, mode):
    """The run's own settings record: status.json for a vLLM route, contract.json for the pipeline."""
    if mode == 'pipeline':
        c = json.loads((root / 'contract.json').read_text())
        m = c['prepared']['models']
        return {'model': f"{m['det']['model']} + {m['rec']['model']} (stock pipeline)",
                'revision': f"det {m['det']['revision']}, rec {m['rec']['revision']}",
                'route': 'pipeline', 'versions': c['prepared']['versions']}
    return json.loads((root / 'status.json').read_text())['settings']


def collector_wall(root, mode, records):
    """Seconds the reader spent: the pilot's and the full pass's collector walls (eight requests at a time) for a
    vLLM route, the sum of the pipeline's per-page times (one page at a time) for PP-OCRv6."""
    if mode == 'pipeline':
        return sum(r.get('wall_s') or 0 for r in records.values())
    pilot = json.loads((root / 'pilot-summary.json').read_text())
    full = json.loads((readings_dir(root, mode) / 'summary.json').read_text())
    return pilot['wall_s'] + full['wall_s']


def strata(rr):
    """ocr-truth.md's draw strata (date bins; the handwritten, clippings and tables tags) and the panel's kinds."""
    groups = collections.defaultdict(list)
    for r in rr:
        groups[('date_bin', r['date_bin'] or 'undated')].append(r)
        for tag in ('handwritten', 'clippings', 'tables'):
            if (r[tag] or 'no') != 'no':
                groups[(tag, 'yes')].append(r)
        groups[('kind', r['kind'])].append(r)
    out = {}
    for (a, v), g in sorted(groups.items()):
        out.setdefault(a, {})[v] = S.aggregate(g)
    return out


def score_route(label, root, mode, jobs, truth_dir, rows, agreement, sacct, gpus=1):
    records = X.F.read_records(readings_dir(root, mode))
    want = {j['page'] for j in jobs}
    if not set(records) <= want:
        raise ValueError(f'{label}: readings for pages outside the manifest: {sorted(set(records) - want)}')
    job_ids = {str(r.get('job')) for r in records.values()}
    if len(job_ids) != 1:
        raise ValueError(f'{label}: readings from more than one job: {sorted(job_ids)}')
    job = job_ids.pop()
    rr, caps_repetitive, cap_pages = [], 0, []
    for j in jobs:
        page, rec = j['page'], records.get(j['page'])
        if rec and rec.get('sha256') != j['sha256']:
            raise SystemExit(f'{label} {page}: image sha256 {rec.get("sha256")} is not the panel original {j["sha256"]}')
        text = X.reading(rec, mode)
        why = outcome(rec, mode, text)
        if why == 'cap':
            cap_pages.append(page)
            caps_repetitive += repetitive(rec.get('raw'))
        usage = (rec or {}).get('usage') or {}
        row = rows[page]
        rr.append({'page': page, 'ok': bool(text), 'outcome': why,
                   **S.score((truth_dir / 'truth' / (page + '.txt')).read_text(), text),
                   **{k: row[k] for k in ('kind', 'table_form', 'handwritten', 'clippings', 'tables', 'date_bin')},
                   'prompt_tokens': usage.get('prompt_tokens'), 'completion_tokens': usage.get('completion_tokens'),
                   'wall_s': (rec or {}).get('wall_s'), 'status': (rec or {}).get('status', 'missing'),
                   'finish': (rec or {}).get('finish')})
    acc = [r for r in rr if r['page'] not in agreement]
    ok = [r for r in rr if r['ok']]
    wall = collector_wall(root, mode, records)
    mean = lambda k: sum(r[k] or 0 for r in ok) / len(ok) if ok and mode != 'pipeline' else None
    st = settings(root, mode)
    job_row = sacct.get(job, {})
    preset = label + PRESET_SUFFIX[mode]
    summary = {
        'label': f'{label}-{job}',
        'env': {'model': st['model'], 'revision': st.get('revision'), 'route': st.get('route'), 'mode': mode,
                'precision': 'pipeline default' if mode == 'pipeline' else 'bf16',
                'SLURM_JOB_ID': job, 'SLURMD_NODENAME': job_row.get('NodeList'), 'FS_MODEL': st['model'],
                'FS_PRESET': preset,
                'FS_VLLM_ARGS': st.get('server_args', ''),
                'FS_KV': 'none (pipeline)' if mode == 'pipeline' else None,
                'vllm': st.get('vllm'), 'max_tokens': st.get('max_tokens'), 'temperature': st.get('temperature'),
                'concurrency': st.get('concurrency'), 'prompt_sha256': st.get('prompt_sha256'),
                'versions': st.get('versions'),
                'note': {'panel': 'panel prompt (KIND/TABLE/TEXT), parsed as the panel parses it',
                         'native': "the model card's own prompt, reply scored as written",
                         'pipeline': 'line detection then recognition, lines joined in the pipeline order; no prompt, '
                                     'no token cap'}[mode] + '; caps, errors and blanks count as failures'},
        'throughput': {'pages': len(rr), 'ok': len(ok), 'wall_s': round(wall, 1), 'gpus': gpus,
                       'pages_per_hour_per_gpu': round(len(rr) / wall * 3600 / gpus, 1) if wall else None,
                       'mean_prompt_tokens': mean('prompt_tokens'), 'mean_completion_tokens': mean('completion_tokens'),
                       'job_elapsed_s': job_row.get('elapsed_s'),
                       'note': 'wall_s is collector time (pilot + full pass); job_elapsed_s is the Slurm job '
                               'including server start and model load'},
        'outcomes': {'all_99': dict(collections.Counter(r['outcome'] for r in rr)),
                     'accuracy_96': dict(collections.Counter(r['outcome'] for r in acc)),
                     'cap_pages': cap_pages, 'caps_repetitive': caps_repetitive},
        'accuracy_96': S.aggregate(acc),
        'agreement_3': S.aggregate([r for r in rr if r['page'] in agreement]),
        'clippings': S.aggregate([r for r in acc if (r['clippings'] or 'no') != 'no']),
        'all_99': S.aggregate(rr),
        'strata_96': strata(acc),
    }
    return summary, rr


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--route', action='append', required=True, metavar='LABEL=ROOT[:MODE]')
    ap.add_argument('--sacct', type=Path, required=True)
    ap.add_argument('--gpus', action='append', default=[], metavar='LABEL=N',
                    help='GPUs a route held (default 1; Ling 3 Flash VL holds 4)')
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    gpus = {k: int(v) for k, _, v in (g.partition('=') for g in a.gpus)}
    jobs = [j for j in json.loads((P.CACHE / 'manifest.json').read_text())['jobs'] if j['scale'] == 'original']
    rows = {r['page']: r for r in P.rows()}
    if len(jobs) != 99 or {j['page'] for j in jobs} != set(rows):
        raise SystemExit('the panel manifest and the truth table do not name the same 99 pages')
    sacct = read_sacct(a.sacct.read_text())
    for spec in a.route:
        label, root, mode = X.parse_route(spec)
        summary, rr = score_route(label, root, mode, jobs, P.TRUTH, rows, P.AGREEMENT, sacct, gpus.get(label, 1))
        out = a.out / summary['label']
        out.mkdir(parents=True, exist_ok=True)
        (out / 'summary.json').write_text(json.dumps(summary, indent=1) + '\n')
        S.write_csv(out / 'pages.csv', rr, FIELDS)  # unrounded: build.py checks pages.csv against summary.json
        acc = summary['accuracy_96']
        print(f"{summary['label']}: NES {100 * acc['nes']:.2f} answered {acc['ok']}/{acc['n']} "
              f"outcomes {summary['outcomes']['all_99']}", flush=True)


if __name__ == '__main__':
    sys.exit(main())
