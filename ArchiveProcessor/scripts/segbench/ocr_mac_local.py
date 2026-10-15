#!/usr/local/bin/python3
"""W41.mac-local-measure. Qwen3-VL 8B at 4-bit (MLX) on this Mac, on the OCR panel's frozen truth set.

  run-guarded.sh --label mac-local --need-gb 8 -- <lab venv>/bin/python ocr_mac_local.py collect [--limit N]
  uv run --with rapidfuzz --with 'sacrebleu==2.5.1' --with pillow python ocr_mac_local.py report

The panel's 99 frozen originals (ocr_panel.py prepare: JPEG q90, 2400 px ceiling), its prompt and its
max_tokens, temperature 0: the same request the hosted bf16 route (Parasail) answered, read here by
mlx-vlm with the model's own processor. Only the precision and the runtime differ, so the NES gap against
the hosted responses already in the panel cache is the 4-bit penalty. No network after the weights are
cached; no money. Raw text stays in the private panel cache (CACHE/local/<key>/); the public report holds
aggregates only. Resumable: a page with a saved response is not read again.
"""
from __future__ import annotations
import argparse
import json
import os
import statistics
import time
from pathlib import Path

import ocr_panel as P

KEY = 'qwen3-vl-8b-mlx4'
HOSTED = 'qwen3-vl-8b'
REPO = 'mlx-community/Qwen3-VL-8B-Instruct-4bit'
# Separate from the Vision OCR lab's cache, which is at its own 50 GB limit.
os.environ.setdefault('HF_HOME', str(Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/mlx-hf'))
OUT = P.CACHE / 'local' / KEY
REPORT = P.RESULTS / 'ocr-mac-local.md'


def jobs():
    return [j for j in P.manifest()['jobs'] if j['scale'] == 'original']


def collect(limit=None):
    import mlx.core as mx
    import mlx_vlm
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template

    todo = [j for j in jobs() if not (OUT / (j['id'] + '.json')).exists()][: limit or None]
    print(f'{KEY}: {len(todo)} pages to read', flush=True)
    if not todo:
        return
    mx.set_cache_limit(256 * 2**20)  # as the lab's read-mlx.py: freed buffers otherwise inflate the footprint
    t0 = time.time()
    model, processor = load(REPO)
    load_s = time.time() - t0
    chat = apply_chat_template(processor, model.config, P.PROMPT, num_images=1)
    for k, job in enumerate(todo, 1):
        image = P.CACHE / 'images' / (job['id'] + '.jpg')
        if P.digest(image.read_bytes()) != job['sha256']:
            raise SystemExit('image changed: ' + job['id'])
        mx.reset_peak_memory()
        start = time.time(); first = None; text = []; last = None
        for r in stream_generate(model, processor, chat, image=[str(image)], max_tokens=P.MAX_TOKENS, temperature=0.0):
            if first is None:
                first = time.time()
            text.append(r.text); last = r
        wall = time.time() - start
        raw = ''.join(text)
        got = P.T.parse_draft(raw)
        finish = 'length' if last is not None and last.generation_tokens >= P.MAX_TOKENS else 'stop'
        meta = {'key': KEY, 'job': job['id'], 'page': job['page'], 'scale': job['scale'], 'model': REPO,
                'runtime': 'mlx-vlm ' + mlx_vlm.__version__, 'status': 'ok' if got and finish == 'stop' else 'failed',
                'finish': finish, 'cost': 0, 'wall_s': round(wall, 2),
                'first_token_s': round((first or start + wall) - start, 2),
                'prompt_tokens': getattr(last, 'prompt_tokens', 0), 'completion_tokens': getattr(last, 'generation_tokens', 0),
                'prompt_tps': round(getattr(last, 'prompt_tps', 0.0), 1), 'gen_tps': round(getattr(last, 'generation_tps', 0.0), 1),
                'mlx_peak_gb': round(mx.get_peak_memory() / 2**30, 2), 'load_s': round(load_s, 1), 't': time.time()}
        P.save(OUT / (job['id'] + '.raw.json'), {'text': raw})
        P.save(OUT / (job['id'] + '.json'), {'meta': meta, 'parsed': got if meta['status'] == 'ok' else None})
        print(f"[{k}/{len(todo)}] {job['id']} {meta['status']} {meta['wall_s']}s "
              f"{meta['prompt_tokens']}+{meta['completion_tokens']} tok peak {meta['mlx_peak_gb']} GB", flush=True)


def load_reading(path):
    got = json.loads(path.read_text()) if path.exists() else {}
    return got.get('meta') or {}, got.get('parsed')


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]


def guard_rows():
    """The memory guard's own rows for these runs: whole-process peak footprint, swap growth, pressure."""
    f = Path(os.environ.get('OCRLAB', Path.home() / '.local/share/visionocr-ocrlab')) / 'guard.tsv'
    if not f.exists():
        return []
    return [l.split('\t') for l in f.read_text().splitlines() if '\tmac-local' in l]


def report():
    import ocr_panel_score as S
    by_page = {r['page']: r for r in P.rows()}
    pairs = []
    for job in jobs():
        if job['page'] in P.AGREEMENT:
            continue
        truth = (P.TRUTH / 'truth' / (job['page'] + '.txt')).read_text()
        lm, lp = load_reading(OUT / (job['id'] + '.json'))
        hm, hp = load_reading(P.CACHE / 'responses' / HOSTED / (job['id'] + '.json'))
        pairs.append({'page': job['page'], 'kind': by_page[job['page']]['kind'], 'local_meta': lm, 'hosted_meta': hm,
                      'local_attempted': bool(lm), 'local': {**S.score(truth, lp['text'] if lp else ''), 'ok': bool(lp)},
                      'hosted': {**S.score(truth, hp['text'] if hp else ''), 'ok': bool(hp)},
                      'local_kind_ok': lp['kind'] == by_page[job['page']]['kind'] if lp else None,
                      'hosted_kind_ok': hp['kind'] == by_page[job['page']]['kind'] if hp else None})
    done = [p for p in pairs if p['local_attempted']]
    L = ['# W41.mac-local-measure — Qwen3-VL 8B at 4-bit on our Mac', '',
         f'Reproduce: `ocr_mac_local.py collect` under the Vision OCR lab\'s `run-guarded.sh`, then `ocr_mac_local.py report`. '
         f'Model `{REPO}` (mlx-vlm), on an Apple M3 Pro with 18 GB. Same 2400 px JPEG inputs, prompt, '
         f'max_tokens {P.MAX_TOKENS} and temperature 0 as the [hosted panel](ocr-panel-local.md); the hosted reference is '
         f'its `{HOSTED}` row (Parasail, bf16). Scoring is the panel\'s own `score()`. No money. Raw text stays in the private cache.', '']
    if len(done) < len(pairs):
        L += [f'**Incomplete: {len(done)} of {len(pairs)} accuracy pages read locally.** The paired table covers those only.', '']
    if not done:
        REPORT.write_text('\n'.join(L)); print('no local readings yet'); return

    def agg(side, rows):
        a = S.aggregate([{**r[side], 'cost': 0} for r in rows])
        return a
    L += ['## Accuracy, paired on the same pages', '',
          f'{len(done)} of the panel\'s 96 accuracy pages (the three agreement-only letters excluded, as there). '
          'Failed or cut-off readings score as empty, as in the panel.', '',
          '| route | completed / n | NES % | chrF2 % | words missed % | words added % | kind correct |',
          '|---|---:|---:|---:|---:|---:|---:|']
    for label, side in ((f'hosted bf16 ({HOSTED})', 'hosted'), (f'Mac MLX 4-bit ({KEY})', 'local')):
        a = agg(side, done); kc = [p[side + '_kind_ok'] for p in done if p[side + '_kind_ok'] is not None]
        L.append(f"| {label} | {a['ok']}/{a['n']} | {100*a['nes']:.2f} | {100*a['chrf']:.2f} | {100*a['miss']:.2f} | "
                 f"{100*a['add']:.2f} | {sum(kc)}/{len(kc)} |")
    d = [p['local']['nes'] - p['hosted']['nes'] for p in done]
    both = [p for p in done if p['local']['ok'] and p['hosted']['ok']]
    db = [p['local']['nes'] - p['hosted']['nes'] for p in both]
    mean = statistics.fmean(d); sd = statistics.stdev(d) if len(d) > 1 else 0
    L += ['', f'**4-bit penalty (local − hosted NES): {100*mean:+.2f} points** over {len(d)} pages '
          f'(paired SD {100*sd:.2f}, so the mean\'s standard error is about {100*sd/len(d)**.5:.2f}); '
          f'median page {100*statistics.median(d):+.2f}. '
          f'Pages where both routes completed: {len(both)}, mean {100*statistics.fmean(db) if db else 0:+.2f}. '
          f'Local better on {sum(x > 0.005 for x in d)}, within half a point on {sum(abs(x) <= 0.005 for x in d)}, '
          f'worse on {sum(x < -0.005 for x in d)}.', '',
          'Largest drops (NES points; page ids are private-cache keys, not corpus names):', '']
    for p in sorted(done, key=lambda p: p['local']['nes'] - p['hosted']['nes'])[:5]:
        L.append(f"- {p['page']} ({p['kind']}): hosted {100*p['hosted']['nes']:.1f} → local {100*p['local']['nes']:.1f}"
                 f"{'' if p['local']['ok'] else ' (local reading failed: ' + p['local_meta'].get('finish', '?') + ')'}")
    L += ['', '| kind | n | hosted NES % | local NES % | difference |', '|---|---:|---:|---:|---:|']
    for kind in sorted({p['kind'] for p in done}):
        rr = [p for p in done if p['kind'] == kind]
        h, l = agg('hosted', rr)['nes'], agg('local', rr)['nes']
        L.append(f'| {kind} | {len(rr)} | {100*h:.2f} | {100*l:.2f} | {100*(l-h):+.2f} |')

    metas = [m for job in jobs() if (m := load_reading(OUT / (job['id'] + '.json'))[0])]
    wall = [m['wall_s'] for m in metas]; peak = [m['mlx_peak_gb'] for m in metas]
    ptok = [m['prompt_tokens'] for m in metas]; ctok = [m['completion_tokens'] for m in metas]
    hosted_ptok = [hm.get('prompt_tokens') for p in done if (hm := p['hosted_meta']).get('prompt_tokens')]
    L += ['', '## Speed and memory on the 18 GB M3 Pro', '',
          f'{len(metas)} pages read (all 99 originals when complete), one at a time, model loaded once '
          f'({statistics.median(m["load_s"] for m in metas):.0f} s to load).', '',
          '| measure | median | 90th percentile | max |', '|---|---:|---:|---:|',
          f'| seconds a page (prompt + generation) | {statistics.median(wall):.1f} | {pct(wall, .9):.1f} | {max(wall):.1f} |',
          f'| seconds to first token (image encoding + prefill) | {statistics.median(m["first_token_s"] for m in metas):.1f} | '
          f'{pct([m["first_token_s"] for m in metas], .9):.1f} | {max(m["first_token_s"] for m in metas):.1f} |',
          f'| generation tokens/s | {statistics.median(m["gen_tps"] for m in metas):.1f} | – | – |',
          f'| input tokens (image + prompt) | {statistics.median(ptok):.0f} | {pct(ptok, .9):.0f} | {max(ptok):.0f} |',
          f'| output tokens | {statistics.median(ctok):.0f} | {pct(ctok, .9):.0f} | {max(ctok):.0f} |',
          f'| MLX peak memory, GB | {statistics.median(peak):.2f} | {pct(peak, .9):.2f} | {max(peak):.2f} |', '',
          f'Total reading time {sum(wall)/60:.0f} min for {len(metas)} pages; '
          f'{sum(m["status"] != "ok" for m in metas)} failed ({sum(m["finish"] == "length" for m in metas)} hit max_tokens). '
          + (f'The hosted route saw a median {statistics.median(hosted_ptok):.0f} input tokens on the same pages, '
             'so both read the image at the same visual resolution.' if hosted_ptok else '')]
    g = guard_rows()
    if g:
        L += ['', 'The memory guard\'s whole-process view of each collect run (date, exit, seconds, peak RSS MB, '
              'peak physical footprint MB, swap growth MB, worst pressure level):', '']
        L += [f"- {' · '.join(r[i] for i in (0, 2, 3, 4, 5, 6, 7))}" for r in g]
    REPORT.write_text('\n'.join(L) + '\n')
    print(f'report: {len(done)} paired pages, penalty {100*mean:+.2f} NES points')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['collect', 'report'])
    ap.add_argument('--limit', type=int)
    a = ap.parse_args()
    collect(a.limit) if a.command == 'collect' else report()


if __name__ == '__main__':
    main()
