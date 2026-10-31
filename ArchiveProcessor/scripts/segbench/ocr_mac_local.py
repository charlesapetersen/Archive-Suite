#!/usr/local/bin/python3
"""W41.mac-local-measure and W41.mac-local-hw. MLX vision models on this Mac, on the OCR panel's frozen truth set.

  run-guarded.sh --label mac-local-KEY --need-gb 8 -- <lab venv>/bin/python ocr_mac_local.py collect [--model KEY] [--limit N]
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
    # W46.ocr-new-open's Mac arm: the publisher's bf16 weights at the revision Sherlock read, with the same prompt,
    # 8,192 tokens, temperature 0 and thinking off, so the gap against the Sherlock truth96 run is the Mac runtime's.
    'xiaomi-ocr-0-bf16': {
        'name': 'Xiaomi-OCR-0 bf16', 'hosted': None, 'reply': 'plain', 'max_side': None, 'max_tokens': 8192,
        'template': {'enable_thinking': False},
        'prompt': 'Extract all information from the main body of the document image and represent it in markdown format, '
                  'ignoring headers and footers. Tables should be expressed in OTSL format, formulas in the document should '
                  'be represented using LATEX format, and the parsing should be organized according to the reading order.',
        'repo': model_store.snapshot('SeerRay-Lab/Xiaomi-OCR-0', 'ff990be318c4c68f7e621dd690231200f47e48c4')},
    'paddleocr-vl1.6-bf16': {
        'name': 'PaddleOCR-VL 1.6 bf16', 'hosted': None, 'reply': 'plain', 'prompt': 'OCR:', 'max_side': None,
        'max_tokens': 8192, 'template': {'enable_thinking': False},
        'repo': model_store.snapshot('PaddlePaddle/PaddleOCR-VL-1.6', 'c5630abae1d940eafe0697512a0325494b02ab42')},
    # W46.ocr-new-open-boxes's Mac arm: IBM's own MLX build, the card's prompt, 8,192 tokens, temperature 0. It answers
    # DocTags; the text scored is docling-core's Markdown export of the (DocTags, page) pair, the card's route and the
    # one the Sherlock run takes (sherlock/new-open-boxes/boxes_parse.py), and the element boxes are kept beside it.
    'granite-docling-258m-mlx': {
        'name': 'granite-docling-258M bf16', 'hosted': None, 'reply': 'doctags', 'prompt': 'Convert this page to docling.',
        'max_side': None, 'max_tokens': 8192, 'template': {},
        'repo': model_store.snapshot('ibm-granite/granite-docling-258M-mlx', 'e9939db25d2f296c8678d0491c4609a8c596c50a')},
}
# docling-core for the DocTags reply, installed apart from the lab venv (`uv pip install --target DIR
# docling-core==2.105.0`) and put after its site-packages, so nothing mlx-vlm imported is replaced.
DOCLING = Path(os.environ.get('DOCLING_CORE_PATH', P.CACHE.parent / 'W46.ocr-new-open-boxes' / 'docling-core-2.105.0'))


def out_dir(key):
    return OUT if key == KEY else OUT.parent / key


def jobs():
    return [j for j in P.manifest()['jobs'] if j['scale'] == 'original']


def boxes_parse():
    import sys
    here = str(Path(__file__).resolve().parent / 'sherlock' / 'new-open-boxes')
    if here not in sys.path:
        sys.path.insert(0, here)
    if str(DOCLING) not in sys.path:
        sys.path.append(str(DOCLING))
    import boxes_parse as B
    return B


def parse(spec, raw, image=None):
    """The reading's {kind, table, text}: the panel's parser for a panel reply, the whole answer for a plain one,
    docling-core's Markdown for a DocTags one (with its element boxes under 'boxes')."""
    if spec['reply'] == 'doctags':
        from PIL import Image
        B = boxes_parse()
        extra = {}
        with Image.open(image) as im:
            try:
                text, boxes = B.doctags(raw, to_markdown=lambda r: B.docling_markdown(r, im.convert('RGB')))
            except Exception as exc:  # as the Sherlock runner: the element texts, and the reason kept
                text, boxes = B.doctags(raw)
                extra = {'parse_error': f'{type(exc).__name__}: {exc}'[:300]}
        return {'kind': None, 'table': None, 'text': text, 'boxes': boxes, **extra} if text else None
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
    if spec['reply'] == 'doctags':
        boxes_parse()
        import docling_core  # noqa: F401  (fail before the model loads, not after the first page)
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
        raw = ''.join(text)
        got = parse(spec, raw, image)
        if spec['max_side']:
            image.unlink()
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
    # This collector's runs only: other scripts (ocr_rerun_noise.py) and the HW models share the plain label.
    g = [r for r in guard_rows() if r[1] in ('mac-local', 'mac-local-probe') and ' ocr_mac_local.py collect' in r[-1]
         and '--model ' not in r[-1]]
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


# The Sherlock truth96 run each Mac bf16 reader repeats, as ocr_rescore.py names the route in ocr-scorers.json.
SHERLOCK = {'xiaomi-ocr-0-bf16': 'xiaomi-ocr-0', 'paddleocr-vl1.6-bf16': 'paddleocr-vl1.6'}


def hw_card():
    """The report's measurement card (root CLAUDE.md), from the readings and ocr-scorers.json's Sherlock rows."""
    read = {k: [p for p in hw_pairs(k) if p['local_attempted']] for k in HW}
    routes = '; '.join(f"{spec['name']} ({len(read[k])} pages, {'the panel prompt' if spec['prompt'] is None else 'its own prompt'})"
                       for k, spec in HW.items())
    hosted = [f"{spec['hosted']} for {spec['name']}" for spec in HW.values() if spec['hosted']]
    gaps = []
    sc = P.RESULTS / 'ocr-scorers.json'
    if sc.exists():
        nes = {r['route']: r['nes'] for r in json.loads(sc.read_text())['summary']
               if r['set'] == 'owner96' and r['stratum'] == 'all'}
        gaps = [f"{HW[k]['name']} {100 * abs(nes[k] - nes[s]):.2f} points from its Sherlock run"
                for k, s in SHERLOCK.items() if k in nes and s in nes]
    sher = (f"; the bf16 readers land {' and '.join(gaps)} (`ocr-scorers.md`)" if gaps
            else '; their Sherlock gaps are not scored yet (`ocr_rescore.py`)')
    return ['## Measurement card', '',
            '- **Truth.** The OCR panel\'s 96 accuracy pages, the adjudicated truth (`ocr_panel.TRUTH`).',
            '- **Selection.** All 96 accuracy pages (the three agreement-only letters excluded), one reading each; '
            'none chosen by a route\'s reading.',
            f"- **Comparison.** Each Mac route at its own quantisation and prompt: {routes}. The hosted bf16 row is "
            f"{', '.join(hosted) or 'none'} only. Speed and memory are one Apple M3 Pro with 18 GB, one page at a time.",
            '- **Noise.** Local greedy routes are deterministic on one machine (`ocr-rerun-noise.md`), so the paired '
            f'interval alone tests a gap between them{sher}.',
            '- **Scope.** The 96 only: these routes\' 895 figures are Sherlock\'s, not read from the Mac.', '']


def report_hw():
    import ocr_panel_score as S
    L = ['# W41.mac-local-hw — LightOnOCR-3-4B, Qwen3.5-9B and the W46.ocr-new-open readers on our Mac', '',
         'The Vision OCR lab\'s handwriting pick (LightOnOCR-3-4B, 8-bit) and runner-up (Qwen3.5-9B, 4-bit), read on the '
         'same Apple M3 Pro with 18 GB over the OCR panel\'s 99 frozen originals and scored with the panel\'s own `score()`, '
         'so they sit on the same NES scale as every route in [the panel](ocr-panel-local.md). Reproduce: '
         '`ocr_mac_local.py collect --model KEY` under the Vision OCR lab\'s `run-guarded.sh`, one model at a time, then '
         '`ocr_mac_local.py report`. Weights from the shared model cache by local path (mlx-vlm). No money. '
         'Raw text stays in the private cache.', '',
         '- **LightOnOCR-3-4B** (`prithivMLmods/LightOnOCR-3-4B-MLX`, 8bit): its card\'s settings, as the lab ran it: an empty '
         'prompt, the 2400 px panel JPEG shrunk to 2048 px on its longest side, 4096 tokens, temperature 0. It answers plain '
         'text with no KIND line, so its whole answer is scored and it has no kind figure. No hosted route serves it.',
         f'- **Qwen3.5-9B** (`mlx-community/Qwen3.5-9B-4bit`): the panel\'s prompt, inputs, max_tokens {P.MAX_TOKENS} and '
         'temperature 0, thinking off (the hosted route\'s reasoning: off), so the gap against the hosted bf16 '
         '`qwen3.5-9b` row (DeepInfra) is the 4-bit-on-a-Mac penalty.',
         '- **Xiaomi-OCR-0** and **PaddleOCR-VL 1.6** (W46.ocr-new-open): the publisher\'s bf16 weights at the revisions '
         'Sherlock read, downloaded once into the shared model cache (`model_store`), with the Sherlock run\'s prompt '
         '(the card\'s Markdown prompt; `OCR:`), 8,192 tokens, temperature 0 and thinking off, scored whole. Their '
         'Sherlock truth96 runs are `farmshare/truth/xiaomi-ocr-0-49202334` and `paddleocr-vl1.6-49202331`.', '']
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
        # Labelled per model (`--label mac-local-KEY`), or a plain `mac-local` run whose command names the model.
        g = [r for r in guard_rows() if r[1] == 'mac-local-' + key or (r[1] == 'mac-local' and r[-1].endswith('ocr_mac_local.py collect --model ' + key))]
        if g:
            L += ['The memory guard\'s whole-process view of each collect run (date, exit, seconds, peak RSS MB, '
                  'peak physical footprint MB, swap growth MB, worst pressure level):', '']
            L += [f"- {' · '.join(r[i] for i in (0, 2, 3, 4, 5, 6, 7))}" for r in g] + ['']
    L += hw_card()
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
