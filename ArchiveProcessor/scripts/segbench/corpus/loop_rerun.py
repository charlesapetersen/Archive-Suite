#!/usr/bin/env python3
"""W46.ocr-loops — whether the open routes' capped pages are recoverable (the Mac half).

  loop_rerun.py caps --out DIR          # each route's capped pages in the open sweep -> DIR/caps/<route>.jsonl,
                                        # DIR/routes.json (the cluster job's settings), DIR/sbatch.txt
  loop_rerun.py report --runs DIR --out DIR [--name loop-rerun-20261021]

Inputs are the open sweep's saved readings in Long term storage (`open-sweep-20261019.md`, "Reproduce"); a cap
is a reading whose status is `cap` (8,192 tokens without a stop). The cluster half is `loop_rerun_cluster.py`
under `loop-rerun-job.sh`: arm `ngram` (no 4-token sequence repeated, at full size) and arm `half` (1200 px).
The report adds, with no new calls, the second-reader arm (another open route's saved reading of the same page)
and kraken PP-OCRv6 on blla lines where `loop_kraken.py` has read them, and scores every arm with the panel's
scorer on the capped pages only, failures as 0. No money; raw text stays outside git.
"""
from pathlib import Path
import argparse
import collections
import json
import os
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import routes as R                       # noqa: E402
import farmshare_results as F           # noqa: E402
import ocr_panel_score as S             # noqa: E402
import farmshare_expanded_report as X   # noqa: E402

LTS = Path(os.environ.get('LTS', Path.home() / 'Claude/Long term storage'))
O = LTS / 'FarmShare-open-sweep-20261019/outputs'
Q = LTS / 'FarmShare-20261019/results/ocr'
G = LTS / 'FarmShare-general-sweep-20261019/outputs'
PP = LTS / 'FarmShare-ppocrv6-20261019/outputs'
MANIFEST = LTS / 'FarmShare-20261019/recovery/manifest-895.jsonl'
FS = '/scratch/users/cp1/fs-ocr'
CLUSTER_MANIFEST = f'{FS}/open-sweep-20261019/public895.jsonl'   # the same 895 images, cluster paths
ONE_GPU = ('--tensor-parallel-size 1 --max-model-len 16384 --kv-cache-dtype auto --gpu-memory-utilization 0.90 '
           '--max-num-seqs 16')   # every one-GPU route's recorded server_args (cache-contract.json, receipts)
PANEL = f'{FS}/interactive-20261018/ocr/panel-prompt.txt'   # sha256 2ab7ab03…, the 96's prompt

# route -> saved readings, scoring mode, and the cluster job's settings (model, served name, prompt, GPUs).
ROUTES = {
    'glm-ocr': dict(dir=O / 'glm-ocr/results/ocr/glm-ocr', mode='native', model='zai-org/GLM-OCR',
                    prompt=f'{FS}/open-sweep-20261019/glm-ocr/ocr/panel-prompt.txt'),
    'lightonocr3-4b': dict(dir=O / 'lightonocr3-4b/results/ocr/lightonocr3-4b', mode='native',
                           model='lightonai/LightOnOCR-3-4B', prompt=f'{FS}/open-sweep-20261019/lightonocr3-4b/ocr/panel-prompt.txt'),
    'lightonocr3-0.8b': dict(dir=O / 'lightonocr3-08b/results/ocr/lightonocr3-08b', mode='native',
                             model='lightonai/LightOnOCR-3-0.8B', prompt=f'{FS}/open-sweep-20261019/lightonocr3-08b/ocr/panel-prompt.txt'),
    'paddleocr-vl1.5': dict(dir=O / 'paddleocr-vl15/results/ocr/paddleocr-vl15', mode='native',
                            model='PaddlePaddle/PaddleOCR-VL-1.5', prompt=f'{FS}/open-sweep-20261019/paddleocr-vl15/ocr/panel-prompt.txt'),
    'qwen3-vl-8b': dict(dir=O / 'qwen3-vl-8b/results/ocr/qwen3-vl-8b', mode='panel',
                        model='Qwen/Qwen3-VL-8B-Instruct', prompt=f'{FS}/open-sweep-20261019/qwen3-vl-8b/ocr/panel-prompt.txt'),
    'qwen3.5-4b': dict(dir=O / 'qwen35-4b/results/ocr/qwen35-4b', mode='panel', model='Qwen/Qwen3.5-4B',
                       prompt=f'{FS}/open-sweep-20261019/qwen35-4b/ocr/panel-prompt.txt'),
    'qwen3.6-27b': dict(dir=Q / 'qwen3.6-27b', mode='panel', model='Qwen/Qwen3.6-27B-FP8', prompt=PANEL),
    'qwen3.5-27b': dict(dir=Q / 'qwen3.5-27b', mode='panel', model='Qwen/Qwen3.5-27B-FP8', prompt=PANEL),
    'qwen3.6-35b-a3b': dict(dir=Q / 'qwen3.6-35b-a3b', mode='panel', model='Qwen/Qwen3.6-35B-A3B-FP8', prompt=PANEL),
    'ling3-flash-vl-fp8': dict(dir=G / 'ling3-flash-vl-fp8/results/ocr/ling3-flash-vl-fp8', mode='panel',
                               model=f'{FS}/hf/hub/models--inclusionAI--Ling-3.0-flash-VL-fp8/snapshots/'
                                     '6f040eebd79d756ab4f6ef69a86d194a569198e0', prompt=PANEL, gpus=4,
                               concurrency=4, hours=6,
                               vllm_args='--tensor-parallel-size 4 --max-model-len 16384 --kv-cache-dtype auto '
                                         '--gpu-memory-utilization 0.90 --max-num-seqs 4 --disable-custom-all-reduce '
                                         '--enforce-eager --trust-remote-code --enable-expert-parallel'),
}
PPOCR = dict(dir=PP / 'ppocrv6-medium-native/raw', mode='pipeline')
# The second reader for a route's caps: LightOnOCR-3 4B for every other route, Qwen3.6 27B for LightOnOCR-3 4B's
# (the audit's "LightOnOCR-3 4B for Qwen caps and the reverse"); stock PP-OCRv6 as the reader that cannot loop.
SECOND = {k: 'lightonocr3-4b' for k in ROUTES}
SECOND['lightonocr3-4b'] = 'qwen3.6-27b'
ARMS = ('ngram', 'half')
LATIN = {'L1', 'L2', 'L3', 'L4', 'L5', 'L6', 'L7', 'L8', 'L9'}


def caps(route):
    return sorted(k for k, r in F.read_records(ROUTES[route]['dir']).items() if r.get('status') == 'cap')


def cmd_caps(a):
    cluster = {}
    for line in Path(a.cluster_manifest).read_text().splitlines() if a.cluster_manifest else []:
        r = json.loads(line); cluster[r['id']] = r
    out = a.out; (out / 'caps').mkdir(parents=True, exist_ok=True)
    plan, lines = {}, []
    for route, spec in ROUTES.items():
        ids = caps(route)
        rows = [cluster[i] for i in ids] if cluster else [{'id': i} for i in ids]
        (out / 'caps' / f'{route}.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
        plan[route] = {'model': spec['model'], 'served': route, 'prompt': spec['prompt'],
                       'vllm_args': spec.get('vllm_args', ONE_GPU), 'concurrency': spec.get('concurrency', 8),
                       'gpus': spec.get('gpus', 1), 'hours': spec.get('hours', 4), 'caps': len(ids)}
        print(route, len(ids), flush=True)
    (out / 'routes.json').write_text(json.dumps(plan, indent=2) + '\n')


def arm_records(runs, route, arm):
    d = runs / 'out' / route / arm
    return F.read_records(d) if d.is_dir() else {}


def cmd_report(a):
    R.MANIFEST = MANIFEST
    truth = {R.job_id(r): r for r in R.frozen()}
    saved = {k: F.read_records(v['dir']) for k, v in ROUTES.items()}
    pp = F.read_records(PPOCR['dir'])
    kraken = {}
    kdir = a.runs / 'kraken'
    if kdir.is_dir():
        for f in kdir.glob('*.txt'):
            kraken[f.stem] = f.read_text()
    rows, pages = [], []
    for route, spec in ROUTES.items():
        ids = sorted(k for k, r in saved[route].items() if r.get('status') == 'cap')
        arms = {arm: arm_records(a.runs, route, arm) for arm in ARMS}
        cands = {}
        for jid in ids:
            t = truth[jid]
            ref = Path(t['truth']).read_text()
            texts = {
                'ngram': X.reading(arms['ngram'].get(jid), spec['mode']) if jid in arms['ngram'] else None,
                'half': X.reading(arms['half'].get(jid), spec['mode']) if jid in arms['half'] else None,
                'second': X.reading(saved[SECOND[route]].get(jid), ROUTES[SECOND[route]]['mode']),
                'ppocrv6': X.reading(pp.get(jid), 'pipeline'),
                'kraken-ppocrv6': kraken.get(jid) if t['stratum'] in LATIN and kraken else None,
            }
            for arm, text in texts.items():
                if text is None:
                    continue
                rec = arms.get(arm, {}).get(jid) if arm in ARMS else None
                row = {'route': route, 'arm': arm, 'page': jid, 'stratum': t['stratum'], 'ok': bool(text),
                       'status': (rec or {}).get('status', ''), 'tokens': ((rec or {}).get('usage') or {}).get('completion_tokens', ''),
                       **S.score(ref, text, t['stratum'])}
                pages.append(row)
                cands.setdefault(arm, []).append(row)
        for arm, rr in cands.items():
            agg = S.aggregate(rr)
            toks = [r['tokens'] for r in rr if isinstance(r['tokens'], int)]
            rows.append({'route': route, 'arm': arm, 'caps': len(ids), 'n': len(rr), **{k: agg[k] for k in ('ok', 'failed', 'nes', 'chrf')},
                         'still_capped': sum(r['status'] == 'cap' for r in rr), 'completion_tokens': sum(toks) if toks else ''})
    a.out.mkdir(parents=True, exist_ok=True)
    S.write_csv(a.out / f'{a.name}.csv', rows, ['route', 'arm', 'caps', 'n', 'ok', 'failed', 'still_capped', 'nes', 'chrf', 'completion_tokens'])
    S.write_csv(a.out / f'{a.name}-pages.csv',
                [{k: round(v, 6) if isinstance(v, float) else v for k, v in r.items()} for r in pages],
                ['route', 'arm', 'page', 'stratum', 'ok', 'status', 'tokens', 'nes', 'chrf', 'words', 'missed', 'added'])
    print(json.dumps(rows, indent=1))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    c = sub.add_parser('caps'); c.add_argument('--out', type=Path, required=True)
    c.add_argument('--cluster-manifest', help='public895.jsonl copied from the cluster (image paths there)')
    r = sub.add_parser('report'); r.add_argument('--runs', type=Path, required=True)
    r.add_argument('--out', type=Path, required=True); r.add_argument('--name', default='loop-rerun-20261021')
    a = ap.parse_args()
    {'caps': cmd_caps, 'report': cmd_report}[a.cmd](a)


if __name__ == '__main__':
    main()
