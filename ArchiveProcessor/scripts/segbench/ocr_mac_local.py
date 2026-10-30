#!/usr/local/bin/python3
"""W41.mac-local-measure and W41.mac-local-hw. MLX vision models on this Mac, on the OCR panel's frozen truth set.

  run-guarded.sh --label mac-local --need-gb 8 -- <lab venv>/bin/python ocr_mac_local.py collect [--model KEY] [--limit N]
  uv run --with rapidfuzz --with 'sacrebleu==2.5.1' --with pillow python ocr_mac_local.py report

The panel's 99 frozen originals (ocr_panel.py prepare: JPEG q90, 2400 px ceiling), read by mlx-vlm with each
model's own processor at temperature 0. Qwen3-VL 8B (the default, W41.mac-local-measure) and Qwen3.5-9B get the
panel's prompt and max_tokens, the same request their hosted bf16 routes answered, so the NES gap against the
hosted responses already in the panel cache is the 4-bit-on-a-Mac penalty. LightOnOCR-3-4B (W41.mac-local-hw)
gets its card's settings instead (empty prompt, longest side 2048 px, 4096 tokens), since any other prompt is out
of its distribution; it answers plain text, scored whole. The W41.mac-local-hw models load from the Vision OCR
lab's cache by local path, read only, so nothing is downloaded. No network after the weights are cached; no
money. Raw text stays in the private panel cache (CACHE/local/<key>/); the public reports hold aggregates only.
Resumable: a page with a saved response is not read again.
"""
from __future__ import annotations
import argparse
import json
import os
import statistics
import time
from pathlib import Path

import model_store
import ocr_panel as P

KEY = 'qwen3-vl-8b-mlx4'
HOSTED = 'qwen3-vl-8b'
REPO = 'mlx-community/Qwen3-VL-8B-Instruct-4bit'
model_store.use()
OUT = P.CACHE / 'local' / KEY
REPORT = P.RESULTS / 'ocr-mac-local.md'
HW_REPORT = P.RESULTS / 'ocr-mac-local-hw.md'
GROUPS = P.RESULTS / 'ocr-mac-local-groups.csv'  # aggregates by kind, read by ArchiveOCRBench/build.py

# W41.mac-local-hw: the Vision OCR lab's handwriting pick and runner-up, as the lab ran them (its read-mlx.py),
# except that Qwen3.5-9B's thinking is switched off to match the hosted route's reasoning: off.
HW = {
    'lightonocr-3-4b-mlx8': {
        'name': 'LightOnOCR-3-4B 8-bit', 'hosted': None, 'reply': 'plain', 'prompt': '', 'max_side': 2048,
        'max_tokens': 4096, 'template': {},
        'repo': model_store.snapshot('prithivMLmods/LightOnOCR-3-4B-MLX', 'e93084acf44a380776866b23b122f48fe47cab7f') / '8bit'},
    'qwen3.5-9b-mlx4': {
        'name': 'Qwen3.5-9B 4-bit', 'hosted': 'qwen3.5-9b', 'reply': 'panel', 'prompt': None, 'max_side': None,
        'max_tokens': None, 'template': {'enable_thinking': False},
        'repo': model_store.snapshot('mlx-community/Qwen3.5-9B-4bit', '8b2b98c00a6b4d291155e4890773ca8f769aee53')},
}


def out_dir(key):
    return OUT if key == KEY else OUT.parent / key


def jobs():
    return [j for j in P.manifest()['jobs'] if j['scale'] == 'original']


def parse(spec, raw):
    """The reading's {kind, table, text}: the panel's parser for a panel reply, the whole answer for a plain one."""
    if spec['reply'] == 'plain':
        return {'kind': None, 'table': None, 'text': raw.strip()} if raw.strip() else None
    return P.T.parse_draft(raw)


def collect(limit=None, key=KEY):
    import tempfile
    import mlx.core as mx
    import mlx_vlm
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template

    spec = HW.get(key) or {'reply': 'panel', 'prompt': None, 'max_side': None, 'max_tokens': None, 'template': {}, 'repo': REPO}
    prompt = P.PROMPT if spec['prompt'] is None else spec['prompt']
    max_tokens = spec['max_tokens'] or P.MAX_TOKENS
    out = out_dir(key)
    todo = [j for j in jobs() if not (out / (j['id'] + '.json')).exists()][: limit or None]
    print(f'{key}: {len(todo)} pages to read', flush=True)
    if not todo:
        return
    if key in HW:
        os.environ['HF_HUB_OFFLINE'] = '1'  # local path, read only: never download
        if not Path(spec['repo'], 'config.json').exists():
            raise SystemExit('weights not in the lab cache: ' + str(spec['repo']))
    mx.set_cache_limit(256 * 2**20)  # as the lab's read-mlx.py: freed buffers otherwise inflate the footprint
    t0 = time.time()
    model, processor = load(str(spec['repo']), **({'trust_remote_code': True} if key in HW else {}))
    load_s = time.time() - t0
    chat = apply_chat_template(processor, model.config, prompt, num_images=1, **spec['template'])
    tmp = tempfile.mkdtemp(prefix='mac-local-shrunk-')
    for k, job in enumerate(todo, 1):
        image = P.CACHE / 'images' / (job['id'] + '.jpg')
        if P.digest(image.read_bytes()) != job['sha256']:
            raise SystemExit('image changed: ' + job['id'])
        if spec['max_side']:
            # As the lab's --max-side: shrink so the longer side is at most this, saved as PNG outside the cache.
            from PIL import Image
            im = Image.open(image); im.thumbnail((spec['max_side'], spec['max_side']), Image.LANCZOS)
            image = Path(tmp) / (job['id'] + '.png'); im.save(image)
        mx.reset_peak_memory()
        start = time.time(); first = None; text = []; last = None
        for r in stream_generate(model, processor, chat, image=[str(image)], max_tokens=max_tokens, temperature=0.0):
            if first is None:
                first = time.time()
            text.append(r.text); last = r
        wall = time.time() - start
        if spec['max_side']:
            image.unlink()
        raw = ''.join(text)
        got = parse(spec, raw)
        finish = 'length' if last is not None and last.generation_tokens >= max_tokens else 'stop'
        meta = {'key': key, 'job': job['id'], 'page': job['page'], 'scale': job['scale'], 'model': str(spec['repo']).replace(str(Path.home()), '~'),
                'runtime': 'mlx-vlm ' + mlx_vlm.__version__, 'status': 'ok' if got and finish == 'stop' else 'failed',
                'finish': finish, 'cost': 0, 'wall_s': round(wall, 2),
                'first_token_s': round((first or start + wall) - start, 2),
                'prompt_tokens': getattr(last, 'prompt_tokens', 0), 'completion_tokens': getattr(last, 'generation_tokens', 0),
                'prompt_tps': round(getattr(last, 'prompt_tps', 0.0), 1), 'gen_tps': round(getattr(last, 'generation_tps', 0.0), 1),
                'mlx_peak_gb': round(mx.get_peak_memory() / 2**30, 2), 'load_s': round(load_s, 1), 't': time.time()}
        P.save(out / (job['id'] + '.raw.json'), {'text': raw})
        P.save(out / (job['id'] + '.json'), {'meta': meta, 'parsed': got if meta['status'] == 'ok' else None})
        print(f"[{k}/{len(todo)}] {job['id']} {meta['status']} {meta['wall_s']}s "
              f"{meta['prompt_tokens']}+{meta['completion_tokens']} tok peak {meta['mlx_peak_gb']} GB", flush=True)


def load_reading(path):
    got = json.loads(path.read_text()) if path.exists() else {}
    return got.get('meta') or {}, got.get('parsed')


def lenient_text(path):
    """A failed reading's text after its TEXT: line, for a reply whose only fault is its header (e.g. a KIND outside
    the four the prompt allows). None when there is no such line or the reading hit max_tokens."""
    import re
    raw = path.with_name(path.name.replace('.json', '.raw.json'))
    meta, parsed = load_reading(path)
    if parsed or not raw.exists() or meta.get('finish') != 'stop':
        return None
    m = re.search(r'(?m)^\s*TEXT:[ \t]*\n?(.*)\Z', json.loads(raw.read_text())['text'].strip(), re.S)
    return m.group(1).strip() if m else None


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
                      'lenient': S.score(truth, lp['text'] if lp else (lenient_text(OUT / (job['id'] + '.json')) or '')),
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
          f'worse on {sum(x < -0.005 for x in d)}.', '']
    fmt = [p for p in done if not p['local']['ok'] and p['local_meta'].get('finish') == 'stop']
    if fmt:
        dl = [p['lenient']['nes'] - p['hosted']['nes'] for p in done]
        L += [f'{len(fmt)} local reading(s) ended normally but broke the reply format (a KIND outside the four allowed, '
              'or no TEXT line), so the panel\'s parser scores them empty. Taking the text after `TEXT:` instead, as an app '
              f'could, the penalty is **{100*statistics.fmean(dl):+.2f} points**: that is the reading penalty, the strict figure '
              'above adds the format slips.', '']
    L += [
          'Largest drops (NES points; page ids are private-cache keys, not corpus names):', '']
    for p in sorted(done, key=lambda p: p['local']['nes'] - p['hosted']['nes'])[:5]:
        L.append(f"- {p['page']} ({p['kind']}): hosted {100*p['hosted']['nes']:.1f} → local {100*p['local']['nes']:.1f}"
                 f"{'' if p['local']['ok'] else ' (local reading failed: ' + p['local_meta'].get('finish', '?') + ')'}")
    L += ['', '| kind | n | hosted NES % | local NES % | difference |', '|---|---:|---:|---:|---:|']
    for kind in sorted({p['kind'] for p in done}):
        rr = [p for p in done if p['kind'] == kind]
        h, l = agg('hosted', rr)['nes'], agg('local', rr)['nes']
        L.append(f'| {kind} | {len(rr)} | {100*h:.2f} | {100*l:.2f} | {100*(l-h):+.2f} |')
    write_groups([(KEY, 'local', done), (HOSTED, 'hosted', done)] + hw_groups())

    metas = [m for job in jobs() if (m := load_reading(OUT / (job['id'] + '.json'))[0])]
    wall = [m['wall_s'] for m in metas]; peak = [m['mlx_peak_gb'] for m in metas]
    ptok = [m['prompt_tokens'] for m in metas]; ctok = [m['completion_tokens'] for m in metas]
    hosted_ptok = [hm.get('prompt_tokens') for p in done if (hm := p['hosted_meta']).get('prompt_tokens')]
    L += ['', '## Speed and memory on the 18 GB M3 Pro', '',
          f'{len(metas)} of the 99 originals read, one at a time, model loaded once '
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
    loops = sum(m['finish'] == 'length' for m in metas)
    L += ['', '## What it means for the app route (W41.app-local-models)', '',
          f'- Where both routes finished a page, 4-bit reads as well as bf16 ({100*statistics.fmean(db) if db else 0:+.2f} NES points '
          f'over {len(both)} pages). The strict penalty comes from whole-page failures, not from worse reading.',
          f'- {loops} of {len(metas)} pages ran away to the {P.MAX_TOKENS}-token limit (a repetition loop), each costing '
          f'{statistics.fmean(m["wall_s"] for m in metas if m["finish"] == "length") / 60 if loops else 0:.1f} minutes. '
          'A local route needs a repetition stop or a much lower token cap scaled to the page, and a retry or fallback on such a page.',
          '- Accept any KIND line and keep the text after `TEXT:`; a strict parser throws away readings like the one above.',
          f'- Speed is about {statistics.median(wall):.0f} s a page, so 102k pages (the corpus’s PDF count, at one photograph each) would be about '
          f'{102000 * statistics.median(wall) / 86400:.0f} days of continuous reading on this Mac. '
          f'Roughly {statistics.median(m["first_token_s"] for m in metas):.0f} s of each page is image encoding and prefill, '
          'fixed by the 2400 px input; generation runs at about '
          f'{statistics.median(m["gen_tps"] for m in metas):.0f} tokens a second.',
          f'- Memory: {max(peak):.1f} GB at MLX\'s peak, about 8.4 GB of whole-process footprint, on an 18 GB Mac with the owner\'s '
          'usual apps open. It ran without the memory guard tripping, but with memory pressure at "warn"; 18 GB is enough '
          'for this model only with little else heavy running.',
          f'- The load time ({statistics.median(m["load_s"] for m in metas):.0f} s) is with the weights already in the file cache; '
          'a cold first load reads 5.5 GB from disk.']
    g = [r for r in guard_rows() if r[1] in ('mac-local', 'mac-local-probe')]
    if g:
        L += ['', 'The memory guard\'s whole-process view of each collect run (date, exit, seconds, peak RSS MB, '
              'peak physical footprint MB, swap growth MB, worst pressure level):', '']
        L += [f"- {' · '.join(r[i] for i in (0, 2, 3, 4, 5, 6, 7))}" for r in g]
    REPORT.write_text('\n'.join(L) + '\n')
    print(f'report: {len(done)} paired pages, penalty {100*mean:+.2f} NES points')
    report_hw()


def write_groups(sets):
    """One row per model and group: every page over the 96, then each kind. sets: (model, side, pairs)."""
    import csv
    import ocr_panel_score as S
    with GROUPS.open('w', newline='') as f:
        w = csv.writer(f, lineterminator='\n')
        w.writerow(['model', 'attribute', 'value', 'n', 'ok', 'nes', 'chrf', 'miss', 'add', 'words'])
        for model, side, done in sets:
            for attr, value, rr in [('all', 'accuracy-96', done)] + [
                    ('kind', k, [p for p in done if p['kind'] == k]) for k in sorted({p['kind'] for p in done})]:
                a = S.aggregate([{**r[side], 'cost': 0} for r in rr])
                w.writerow([model, attr, value, a['n'], a['ok']] + [repr(a[k]) for k in ('nes', 'chrf', 'miss', 'add')] + [a['words']])


def hw_pairs(key):
    """W41.mac-local-hw: one model's 96 accuracy pages scored like the panel, with the hosted route's when it has one."""
    import ocr_panel_score as S
    spec, by_page, out = HW[key], {r['page']: r for r in P.rows()}, out_dir(key)
    pairs = []
    for job in jobs():
        if job['page'] in P.AGREEMENT:
            continue
        truth = (P.TRUTH / 'truth' / (job['page'] + '.txt')).read_text()
        lm, lp = load_reading(out / (job['id'] + '.json'))
        kind = by_page[job['page']]['kind']
        row = {'page': job['page'], 'kind': kind, 'local_meta': lm, 'local_attempted': bool(lm),
               'local': {**S.score(truth, lp['text'] if lp else ''), 'ok': bool(lp)},
               'lenient': S.score(truth, lp['text'] if lp else (lenient_text(out / (job['id'] + '.json')) or '')),
               'local_kind_ok': lp['kind'] == kind if lp and lp.get('kind') else None}
        if spec['hosted']:
            hm, hp = load_reading(P.CACHE / 'responses' / spec['hosted'] / (job['id'] + '.json'))
            row.update(hosted={**S.score(truth, hp['text'] if hp else ''), 'ok': bool(hp)}, hosted_meta=hm,
                       hosted_kind_ok=hp['kind'] == kind if hp else None)
        pairs.append(row)
    return pairs


def hw_groups():
    sets = []
    for key in HW:
        done = [p for p in hw_pairs(key) if p['local_attempted']]
        if done:
            sets.append((key, 'local', done))
    return sets


def report_hw():
    import ocr_panel_score as S
    L = ['# W41.mac-local-hw — LightOnOCR-3-4B and Qwen3.5-9B on our Mac', '',
         'The Vision OCR lab\'s handwriting pick (LightOnOCR-3-4B, 8-bit) and runner-up (Qwen3.5-9B, 4-bit), read on the '
         'same Apple M3 Pro with 18 GB over the OCR panel\'s 99 frozen originals and scored with the panel\'s own `score()`, '
         'so they sit on the same NES scale as every route in [the panel](ocr-panel-local.md). Reproduce: '
         '`ocr_mac_local.py collect --model KEY` under the Vision OCR lab\'s `run-guarded.sh`, one model at a time, then '
         '`ocr_mac_local.py report`. Weights from the lab\'s cache by local path (mlx-vlm), nothing downloaded. No money. '
         'Raw text stays in the private cache.', '',
         '- **LightOnOCR-3-4B** (`prithivMLmods/LightOnOCR-3-4B-MLX`, 8bit): its card\'s settings, as the lab ran it: an empty '
         'prompt, the 2400 px panel JPEG shrunk to 2048 px on its longest side, 4096 tokens, temperature 0. It answers plain '
         'text with no KIND line, so its whole answer is scored and it has no kind figure. No hosted route serves it.',
         f'- **Qwen3.5-9B** (`mlx-community/Qwen3.5-9B-4bit`): the panel\'s prompt, inputs, max_tokens {P.MAX_TOKENS} and '
         'temperature 0, thinking off (the hosted route\'s reasoning: off), so the gap against the hosted bf16 '
         '`qwen3.5-9b` row (DeepInfra) is the 4-bit-on-a-Mac penalty.', '']
    for key, spec in HW.items():
        pairs = hw_pairs(key)
        done = [p for p in pairs if p['local_attempted']]
        L += [f'## {spec["name"]} (`{key}`)', '']
        if len(done) < len(pairs):
            L += [f'**Incomplete: {len(done)} of {len(pairs)} accuracy pages read.**', '']
        if not done:
            L += ['Not read yet.', '']
            continue
        sides = ([(f'hosted bf16 ({spec["hosted"]})', 'hosted')] if spec['hosted'] else []) + [(f'Mac MLX ({key})', 'local')]
        L += [f'{len(done)} of the panel\'s 96 accuracy pages (the three agreement-only letters excluded, as there). '
              'Failed or cut-off readings score as empty, as in the panel.', '',
              '| route | completed / n | NES % | chrF2 % | words missed % | words added % | kind correct |',
              '|---|---:|---:|---:|---:|---:|---:|']
        for label, side in sides:
            a = S.aggregate([{**p[side], 'cost': 0} for p in done])
            kc = [p[side + '_kind_ok'] for p in done if p[side + '_kind_ok'] is not None]
            L.append(f"| {label} | {a['ok']}/{a['n']} | {100*a['nes']:.2f} | {100*a['chrf']:.2f} | {100*a['miss']:.2f} | "
                     f"{100*a['add']:.2f} | {f'{sum(kc)}/{len(kc)}' if kc else '–'} |")
        if spec['hosted']:
            d = [p['local']['nes'] - p['hosted']['nes'] for p in done]
            both = [p for p in done if p['local']['ok'] and p['hosted']['ok']]
            db = [p['local']['nes'] - p['hosted']['nes'] for p in both]
            sd = statistics.stdev(d) if len(d) > 1 else 0
            L += ['', f'**Mac 4-bit − hosted bf16 NES: {100*statistics.fmean(d):+.2f} points** over {len(d)} pages '
                  f'(standard error about {100*sd/len(d)**.5:.2f}; a negative figure is a 4-bit-on-a-Mac penalty); '
                  f'pages where both completed: {len(both)}, mean {100*statistics.fmean(db) if db else 0:+.2f}. '
                  f"Failed: hosted {sum(not p['hosted']['ok'] for p in done)}, Mac {sum(not p['local']['ok'] for p in done)}."]
            fmt = [p for p in done if not p['local']['ok'] and p['local_meta'].get('finish') == 'stop']
            if fmt:
                dl = [p['lenient']['nes'] - p['hosted']['nes'] for p in done]
                L += ['', f'{len(fmt)} local reading(s) ended normally but broke the reply format, so the panel\'s parser scores '
                      f'them empty; taking the text after `TEXT:` instead, the difference is {100*statistics.fmean(dl):+.2f} points.']
        L += ['', '| kind | n | ' + ' | '.join(f'{lab.split(" (")[0]} NES %' for lab, _ in sides) + ' |',
              '|---|---:|' + '---:|' * len(sides)]
        for kind in sorted({p['kind'] for p in done}):
            rr = [p for p in done if p['kind'] == kind]
            L.append(f'| {kind} | {len(rr)} | ' + ' | '.join(
                f"{100*S.aggregate([{**p[side], 'cost': 0} for p in rr])['nes']:.2f}" for _, side in sides) + ' |')
        metas = [m for job in jobs() if (m := load_reading(out_dir(key) / (job['id'] + '.json'))[0])]
        wall = [m['wall_s'] for m in metas]; peak = [m['mlx_peak_gb'] for m in metas]
        ptok = [m['prompt_tokens'] for m in metas]; ctok = [m['completion_tokens'] for m in metas]
        L += ['', f'## Speed and memory: {key}', '',
              f'{len(metas)} of the 99 originals read, one at a time, model loaded once '
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
              f'{sum(m["status"] != "ok" for m in metas)} failed ({sum(m["finish"] == "length" for m in metas)} hit max_tokens).', '']
        g = [r for r in guard_rows() if r[1] == 'mac-local-' + key]
        if g:
            L += ['The memory guard\'s whole-process view of each collect run (date, exit, seconds, peak RSS MB, '
                  'peak physical footprint MB, swap growth MB, worst pressure level):', '']
            L += [f"- {' · '.join(r[i] for i in (0, 2, 3, 4, 5, 6, 7))}" for r in g] + ['']
    HW_REPORT.write_text('\n'.join(L).rstrip('\n') + '\n')
    print('report: ' + ', '.join(f"{k} {sum(p['local_attempted'] for p in hw_pairs(k))} pages" for k in HW))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['collect', 'report'])
    ap.add_argument('--limit', type=int)
    ap.add_argument('--model', default=KEY, choices=[KEY, *HW])
    a = ap.parse_args()
    collect(a.limit, a.model) if a.command == 'collect' else report()


if __name__ == '__main__':
    main()
