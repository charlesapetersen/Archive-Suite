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
scorer on the capped pages only, failures as 0, with two cascades over the arms (RETRY_FIRST as filed and
READER_FIRST). No money; raw text stays outside git.
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
# Sources the kraken PP-OCRv6 card's public training list names (loop_kraken.py): its rows there are labelled.
KRAKEN_TRAINED_ON = {'koenigsfelden', 'kurrent', 'iforal', 'ocrd', 'voc', 'muharaf', 'eparchos'}

# The 96 (the owner's truth pages): the truth96 run's caps, same routes and prompts (2026-10-20, jobs 1861696-703).
T = LTS / 'FarmShare-truth96-20261020/outputs'
TFS = f'{FS}/truth96-20261020'
T96 = {f't96-{k}': dict(dir=T / f'{d}/results/ocr/{d}', mode=ROUTES[k]['mode'], model=ROUTES[k]['model'],
                        prompt=f'{TFS}/{d}/ocr/panel-prompt.txt', base=k)
       for k, d in (('glm-ocr', 'glm-ocr'), ('lightonocr3-4b', 'lightonocr3-4b'), ('lightonocr3-0.8b', 'lightonocr3-08b'),
                    ('paddleocr-vl1.5', 'paddleocr-vl15'), ('qwen3-vl-8b', 'qwen3-vl-8b'), ('qwen3.5-4b', 'qwen35-4b'))}
T96_PPOCR = T / 'ppocrv6-medium-native/raw'
T96_MANIFEST = f'{TFS}/truth99.jsonl'


def caps(spec):
    return sorted(k for k, r in F.read_records(spec['dir']).items() if r.get('status') == 'cap')


def cmd_caps(a):
    cluster = {}
    for line in Path(a.cluster_manifest).read_text().splitlines() if a.cluster_manifest else []:
        r = json.loads(line); cluster[r['id']] = r
    out = a.out; (out / 'caps').mkdir(parents=True, exist_ok=True)
    table = T96 if a.set == 'truth96' else ROUTES
    plan = json.loads((out / 'routes.json').read_text()) if (out / 'routes.json').exists() else {}
    for route, spec in table.items():
        ids = caps(spec)
        if not ids:
            continue
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


def texts_dir(d):
    return {f.stem: f.read_text() for f in d.glob('*.txt')} if d.is_dir() else {}


def mlx_readings(d):
    """ocr_mac_local's readings, by panel page id (p018): the parsed TEXT, '' for a failed or capped one."""
    out = {}
    for f in d.glob('*.json') if d.is_dir() else []:
        if f.name.endswith('.raw.json'):
            continue
        got = json.loads(f.read_text())
        out[got['meta']['page']] = {'text': ((got.get('parsed') or {}).get('text') or '').strip(),
                                    'status': 'cap' if got['meta']['finish'] == 'length' else 'ok' if got.get('parsed') else 'failed',
                                    'tokens': got['meta'].get('completion_tokens'), 'wall_s': got['meta'].get('wall_s')}
    return out


RETRY_FIRST = ('ngram', 'half', 'second', 'kraken-ppocrv6', 'ppocrv6')
# Chosen after the arms were scored (on the 895's pooled arms, so it is fitted there; the 96 is the check):
# kraken PP-OCRv6 where it read the page (Latin strata), then the second reader, then n-gram, then stock PP-OCRv6.
READER_FIRST = ('kraken-ppocrv6', 'second', 'ngram', 'ppocrv6')


def cascade(texts, order=RETRY_FIRST):
    """The first arm, in the given order, that gave a reading. RETRY_FIRST is the order filed: own route again with
    n-gram blocking, then at half size, then the second open reader, then the readers that cannot loop."""
    for arm in order:
        if texts.get(arm):
            return texts[arm]
    return ''


def score_route(set_name, route, ids, ref_of, texts_of, meta_of):
    pages, cands = [], {}
    for jid in ids:
        ref, stratum = ref_of(jid)
        texts = {k: v for k, v in texts_of(jid, stratum).items() if v is not None}
        texts['cascade'], texts['cascade-readers'] = cascade(texts), cascade(texts, READER_FIRST)
        for arm, text in texts.items():
            m = meta_of(arm, jid)
            row = {'set': set_name, 'route': route, 'arm': arm, 'page': jid, 'stratum': stratum, 'ok': bool(text),
                   'status': m.get('status', ''), 'tokens': m.get('tokens', ''), 'wall_s': m.get('wall_s', ''),
                   **(S.score(ref, text, stratum) if stratum else S.score(ref, text))}
            pages.append(row); cands.setdefault(arm, []).append(row)
    rows = []
    for arm, rr in cands.items():
        agg = S.aggregate(rr)
        def num(k):
            xs = [r[k] for r in rr if isinstance(r[k], (int, float)) and not isinstance(r[k], bool)]
            return round(sum(xs), 2) if xs else ''
        rows.append({'set': set_name, 'route': route, 'arm': arm, 'caps': len(ids), 'n': len(rr),
                     **{k: agg[k] for k in ('ok', 'failed', 'nes', 'chrf')},
                     'still_capped': sum(r['status'] == 'cap' for r in rr), 'completion_tokens': num('tokens'),
                     'wall_s': num('wall_s')})
    return rows, pages


def meta_from(records):
    def get(jid):
        r = records.get(jid) or {}
        return {'status': r.get('status', ''), 'tokens': (r.get('usage') or {}).get('completion_tokens', ''), 'wall_s': r.get('wall_s', '')}
    return get


def cmd_report(a):
    rows, pages = [], []
    # The 895.
    R.MANIFEST = MANIFEST
    truth = {R.job_id(r): r for r in R.frozen()}
    saved = {k: F.read_records(v['dir']) for k, v in ROUTES.items()}
    pp = F.read_records(PPOCR['dir'])
    kraken = texts_dir(a.runs / 'kraken')
    for route, spec in ROUTES.items():
        ids = sorted(k for k, r in saved[route].items() if r.get('status') == 'cap')
        arms = {arm: arm_records(a.runs, route, arm) for arm in ARMS}
        metas = {arm: meta_from(arms[arm]) for arm in ARMS}
        def texts_of(jid, stratum):
            return {**{arm: X.reading(arms[arm][jid], spec['mode']) if jid in arms[arm] else None for arm in ARMS},
                    'second': X.reading(saved[SECOND[route]].get(jid), ROUTES[SECOND[route]]['mode']),
                    'ppocrv6': X.reading(pp.get(jid), 'pipeline'),
                    'kraken-ppocrv6': kraken.get(jid) if stratum in LATIN and kraken else None}
        rr, pg = score_route('public895', route, ids, lambda j: (Path(truth[j]['truth']).read_text(), truth[j]['stratum']),
                             texts_of, lambda arm, j: metas[arm](j) if arm in metas else {})
        for p in pg:
            p['source'] = truth[p['page']]['source']
        rows += rr; pages += pg
    # The 96 (the three agreement-only letters are kept and marked, since a cap there is a cap too).
    tsaved = {k: F.read_records(v['dir']) for k, v in T96.items()}
    t_lo4 = tsaved['t96-lightonocr3-4b']
    tpp = F.read_records(T96_PPOCR)
    k96 = texts_dir(a.runs / 'kraken96')
    ref96 = lambda j: ((X.R.P.TRUTH / 'truth' / (j + '.txt')).read_text(), None)
    for route, spec in T96.items():
        ids = sorted(k for k, r in tsaved[route].items() if r.get('status') == 'cap')
        if not ids:
            continue
        arms = {arm: arm_records(a.runs, route, arm) for arm in ARMS}
        metas = {arm: meta_from(arms[arm]) for arm in ARMS}
        second = 't96-lightonocr3-4b' if spec['base'] != 'lightonocr3-4b' else None
        def texts_of(jid, _s):
            return {**{arm: X.reading(arms[arm][jid], spec['mode']) if jid in arms[arm] else None for arm in ARMS},
                    'second': X.reading(tsaved[second].get(jid), 'native') if second else None,
                    'ppocrv6': X.reading(tpp.get(jid), 'pipeline'), 'kraken-ppocrv6': k96.get(jid)}
        rr, pg = score_route('truth96', route, ids, ref96, texts_of, lambda arm, j: metas[arm](j) if arm in metas else {})
        rows += rr; pages += pg
    # The 96's three MLX loops (Qwen3-VL 8B 4-bit on this Mac), read again by loop_mac.py.
    import ocr_mac_local as M
    base = mlx_readings(M.OUT)
    loops = {arm: mlx_readings(M.OUT.parent / (M.KEY + '-loops') / arm) for arm in ARMS}
    ids = sorted(p for p, r in base.items() if r['status'] == 'cap')
    fs8b = tsaved['t96-qwen3-vl-8b']
    def mlx_texts(jid, _s):
        return {**{arm: loops[arm][jid]['text'] if jid in loops[arm] else None for arm in ARMS},
                'second': X.reading(t_lo4.get(jid), 'native'), 'ppocrv6': X.reading(tpp.get(jid), 'pipeline'),
                'kraken-ppocrv6': k96.get(jid), 'bf16-vllm': X.reading(fs8b.get(jid), 'panel')}
    rr, pg = score_route('truth96', 'mlx-qwen3-vl-8b-4bit', ids, ref96, mlx_texts,
                         lambda arm, j: loops[arm].get(j, {}) if arm in loops else {})
    rows += rr; pages += pg
    a.out.mkdir(parents=True, exist_ok=True)
    S.write_csv(a.out / f'{a.name}.csv', rows, ['set', 'route', 'arm', 'caps', 'n', 'ok', 'failed', 'still_capped', 'nes',
                                                'chrf', 'completion_tokens', 'wall_s'])
    S.write_csv(a.out / f'{a.name}-pages.csv',
                [{k: round(v, 6) if isinstance(v, float) else v for k, v in r.items()} for r in pages],
                ['set', 'route', 'arm', 'page', 'stratum', 'source', 'ok', 'status', 'tokens', 'wall_s', 'nes', 'chrf', 'words',
                 'missed', 'added'])
    (a.out / f'{a.name}-tables.md').write_text(tables(rows, pages))
    (a.out / f'{a.name}.json').write_text(json.dumps(summary(rows, pages, a.runs, a.name), indent=1) + '\n')
    print(f'{len(rows)} rows, {len(pages)} page rows -> {a.out}')


SWEEP = HERE.parents[2] / 'segbench-results/bench-corpus/open-sweep-20261019.json'
ARM_ORDER = ('ngram', 'half', 'second', 'kraken-ppocrv6', 'ppocrv6', 'bf16-vllm', 'cascade', 'cascade-readers')
POOLED = tuple(a for a in ARM_ORDER if a != 'bf16-vllm')


def tables(rows, pages):
    """The report's tables, from whatever arms have readings; an arm with none shows a dash."""
    overall = {m['route']: m['nes'] for m in json.loads(SWEEP.read_text())['models']
               if m['subset'] == 'full895' and m['stratum'] == 'all'}
    by = {(r['set'], r['route'], r['arm']): r for r in rows}
    cell = lambda r: '–' if r is None else f"{100 * r['nes']:.1f} ({r['ok']}/{r['n']})"
    out = ['NES % on the capped pages only (answered / pages); the original reading of every one of them scores 0.', '',
           '| route | caps | ' + ' | '.join(ARM_ORDER) + ' | 895 NES before | after cascade | after cascade-readers |',
           '|---|---:|' + '---:|' * len(ARM_ORDER) + '---:|---:|---:|']
    for route in ROUTES:
        rs = [by.get(('public895', route, arm)) for arm in ARM_ORDER]
        caps_n = next(r['caps'] for r in rs if r)
        before = overall.get(route)
        afters = []
        for arm in ('cascade', 'cascade-readers'):
            casc = by.get(('public895', route, arm))
            after = before + casc['nes'] * casc['n'] / 895 if before is not None and casc else None
            afters.append('–' if after is None else f'{100 * after:.1f}')
        out.append(f'| {route} | {caps_n} | ' + ' | '.join(cell(r) for r in rs) +
                   f" | {'–' if before is None else f'{100 * before:.1f}'} | " + ' | '.join(afters) + ' |')
    out += ['', 'By script, the cascade and its parts, all routes pooled (pages, NES %):', '',
            '| strata | ' + ' | '.join(POOLED) + ' |', '|---|' + '---:|' * len(POOLED)]
    for label, test in (('Latin (L1-L9)', lambda s: s in LATIN), ('other scripts (N1-N6)', lambda s: s not in LATIN)):
        cells = []
        for arm in POOLED:
            pr = [p for p in pages if p['set'] == 'public895' and p['arm'] == arm and test(p['stratum'])]
            cells.append('–' if not pr else f"{100 * sum(p['nes'] for p in pr) / len(pr):.1f} ({len(pr)})")
        out.append(f'| {label} | ' + ' | '.join(cells) + ' |')
    kp = [p for p in pages if p['set'] == 'public895' and p['arm'] == 'kraken-ppocrv6']
    for label, test in (('trained on the source', lambda p: p.get('source') in KRAKEN_TRAINED_ON),
                        ('not in its public training list', lambda p: p.get('source') not in KRAKEN_TRAINED_ON)):
        pr = [p for p in kp if test(p)]
        if pr:
            out.append(f'| kraken PP-OCRv6, {label} | – | – | – | {100 * sum(p["nes"] for p in pr) / len(pr):.1f} ({len(pr)}) | – | – | – |')
    out += ['', 'The 96 (the owner\'s truth pages), the same arms:', '',
            '| route | caps | ' + ' | '.join(ARM_ORDER) + ' |', '|---|---:|' + '---:|' * len(ARM_ORDER)]
    for route in [*T96, 'mlx-qwen3-vl-8b-4bit']:
        rs = [by.get(('truth96', route, arm)) for arm in ARM_ORDER]
        if any(rs):
            out.append(f"| {route} | {next(r['caps'] for r in rs if r)} | " + ' | '.join(cell(r) for r in rs) + ' |')
    return '\n'.join(out) + '\n'


def arm_wall(runs, route, arm):
    """The cluster arm's wall seconds on one GPU (summary.json; vLLM's start-up excluded), None if it never ran."""
    f = runs / 'out' / route / arm / 'summary.json'
    return json.loads(f.read_text())['wall_s'] if f.exists() else None


def summary(rows, pages, runs, name):
    """The figures ArchiveOCRBench draws (build.py → loops): per route and arm NES on the caps, answered / pages,
    the 895 before and after each cascade, the GPU seconds of the two cluster arms, and the arms pooled by script."""
    overall = {m['route']: m['nes'] for m in json.loads(SWEEP.read_text())['models']
               if m['subset'] == 'full895' and m['stratum'] == 'all'}
    by = {(r['set'], r['route'], r['arm']): r for r in rows}
    arm = lambda r: None if r is None else {'nes': round(r['nes'], 4), 'ok': r['ok'], 'n': r['n']}

    def route_rows(set_name, routes):
        out = []
        for route in routes:
            rs = {k: by.get((set_name, route, k)) for k in ARM_ORDER}
            if not any(rs.values()):
                continue
            row = {'route': route, 'caps': next(r['caps'] for r in rs.values() if r),
                   'arms': {k: arm(v) for k, v in rs.items() if v}}
            if set_name == 'public895':
                before = overall.get(route)
                row['before'] = None if before is None else round(before, 4)
                for k in ('cascade', 'cascade-readers'):
                    c = rs[k]
                    row['after_' + k] = None if before is None or not c else round(before + c['nes'] * c['n'] / 895, 4)
                row['gpu_s'] = {k: arm_wall(runs, route, k) for k in ARMS}
            out.append(row)
        return out
    pooled = {}
    for label, test in (('latin', lambda s: s in LATIN), ('other', lambda s: s not in LATIN)):
        pooled[label] = {}
        for k in POOLED:
            pr = [p for p in pages if p['set'] == 'public895' and p['arm'] == k and test(p['stratum'])]
            if pr:
                pooled[label][k] = {'nes': round(sum(p['nes'] for p in pr) / len(pr), 4), 'n': len(pr)}
    return {'report': f'bench-corpus/{name}.md', 'retry_first': list(RETRY_FIRST), 'reader_first': list(READER_FIRST),
            'public895': route_rows('public895', ROUTES), 'truth96': route_rows('truth96', [*T96, 'mlx-qwen3-vl-8b-4bit']),
            'pooled': pooled, 'not_run': {'ling3-flash-vl-fp8': 'n-gram and half arms cancelled by the owner, 2026-10-23'}}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    c = sub.add_parser('caps'); c.add_argument('--out', type=Path, required=True)
    c.add_argument('--cluster-manifest', help='public895.jsonl / truth99.jsonl copied from the cluster (its image paths)')
    c.add_argument('--set', choices=['public895', 'truth96'], default='public895')
    r = sub.add_parser('report'); r.add_argument('--runs', type=Path, required=True)
    r.add_argument('--out', type=Path, required=True); r.add_argument('--name', default='loop-rerun-20261021')
    a = ap.parse_args()
    {'caps': cmd_caps, 'report': cmd_report}[a.cmd](a)


if __name__ == '__main__':
    main()
