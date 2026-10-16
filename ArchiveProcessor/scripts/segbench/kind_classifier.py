#!/usr/local/bin/python3
"""W41.bench-kind-classifier. A fast, cheap local page-kind classifier for the Processor, measured on labelled pages.

  kind_classifier.py draw                 # seeded corpus draws for forms/tables and low resolution -> CACHE/draw/
  kind_classifier.py labels               # CACHE/labels.tsv from the truth set, the ladder and CACHE/looked.tsv
  kind_classifier.py signals              # kind-signals (Vision, no model) over the labels -> CACHE/signals.tsv
  run-guarded.sh --label kind-vlm -- <lab venv>/bin/python kind_classifier.py vlm --model KEY
  <lab venv>/bin/python kind_classifier.py report   # -> segbench-results/kind-classifier.md

The kinds are the model guide's (ocr-page-guidance.json, W41.app-ocr-hierarchy): the hand (handwritten,
typewritten, printed, mixed), and two flags that cut across it, a form or table and low resolution. A page is
routed to the guide's first pick for its flag when it has one (low resolution first), else for its hand.
Images stay in the private cache (CACHE); the repo is public, so the report holds aggregates and page ids only.
Reads the corpus, never writes it. No money: Apple Vision and open weights already in the lab's cache.
"""
from __future__ import annotations
import argparse
import csv
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESULTS = HERE.parents[1] / 'segbench-results'
REHEARSAL = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
CACHE = Path(os.environ.get('KIND_CACHE', REHEARSAL / 'kind-classifier'))
TRUTH = REHEARSAL / 'ocr-truth/pages.tsv'
PANEL_IMAGES = REHEARSAL / 'ocr-panel-local/images'          # p001-original.jpg, p002-half.jpg, p002-quarter.jpg
VISION_KIND = REHEARSAL / 'vision-kind/panel.tsv'
JPEGS = Path.home() / 'Desktop/Google Drive/Archival Photos JPEGS'
CORPUS = Path.home() / 'Desktop/Google Drive/Archival Photos'
PAIRS = REHEARSAL / 'corpus-pairs/pairs.tsv'                 # W41.seg-corpus-pairs: method none = a PDF with no JPEG
ALL_TAGS = Path.home() / '.local/state/visionocr-autonomous/photo-sample/all-tags.tsv'  # Vision OCR's tag listing
HW_HELD_OUT = Path.home() / '.local/state/visionocr-autonomous/hw-sample/held-out.tsv'
PDFTOPPM =Path.home() / '.local/bin/pdftoppm'
SEED = 20261016
FORMS_DRAW = 30        # Statistics-tagged photos, looked at for a form or table
PER_FOLDER = 3
LOWRES_SAMPLE = 1500   # PDFs with no JPEG whose page image size is read; every corpus photo is 2,592 px or more
LOWRES_SIDE = 1100     # a long side under this is a candidate (the ladder's quarter rung is 313-1,020 px, half 627-2,040)
LOWRES_DRAW = 15


def read_tsv(path):
    with open(path, newline='') as f:
        return list(csv.DictReader((l for l in f if not l.startswith('#')), delimiter='\t'))


def write_tsv(path, rows, cols):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w', newline='') as f:
        w = csv.DictWriter(f, cols, delimiter='\t', extrasaction='ignore', lineterminator='\n')
        w.writeheader()
        w.writerows(rows)


def tagged():
    """(path, tags) for every corpus photo in Vision OCR's listing, junk files dropped."""
    out = []
    for line in open(ALL_TAGS, encoding='utf-8'):
        path, _, tags = line.rstrip('\n').partition('\t')
        if Path(path).suffix.lower() in ('.jpg', '.jpeg', '.png', '.heic', '.tif', '.tiff'):
            out.append((path, {t.strip() for t in tags.replace(',', ';').split(';') if t.strip()}))
    return out


def per_folder(rng, pool, n, most=PER_FOLDER):
    rng.shuffle(pool)
    seen, out = {}, []
    for path, tags in pool:
        folder = str(Path(path).parent)
        if seen.get(folder, 0) < most:
            seen[folder] = seen.get(folder, 0) + 1
            out.append((path, tags))
        if len(out) == n:
            break
    return out


def pdf_image_side(path):
    """The long side in pixels of the largest image a PDF declares, read from its bytes (None when none is plain):
    the largest, because a page can carry a thumbnail or a logo besides its photograph."""
    with open(path, 'rb') as f:
        data = f.read()
    sides = [max(int(m.group(1)), int(m.group(3))) for m in
             re.finditer(rb'/Width\s+(\d+)(.{0,200}?)/Height\s+(\d+)', data, re.S)]
    sides += [max(int(m.group(1)), int(m.group(3))) for m in
              re.finditer(rb'/Height\s+(\d+)(.{0,200}?)/Width\s+(\d+)', data, re.S)]
    return max(sides) if sides else None


def copy_in(rows, prefix, root):
    """Copy each drawn photo into the private cache, or render a PDF's first page at its image's own size
    (read the corpus, write only the cache)."""
    d = CACHE / 'draw'
    d.mkdir(parents=True, exist_ok=True)
    out = []
    for i, (path, tags, extra) in enumerate(rows):
        pid = f'{prefix}{i + 1:02d}'
        side = extra.pop('side', None)
        if side:
            dst = d / f'{pid}.jpg'
            if not dst.exists():
                subprocess.run([str(PDFTOPPM), '-f', '1', '-l', '1', '-singlefile', '-jpeg', '-jpegopt', 'quality=95',
                                '-scale-to', str(side), path, str(dst.with_suffix(''))], check=True)
        else:
            dst = d / f'{pid}{Path(path).suffix.lower()}'
            if not dst.exists():
                shutil.copyfile(path, dst)
        out.append({'id': pid, 'file': str(dst), 'source': str(Path(path).relative_to(root)),
                    'tags': '; '.join(sorted(tags)), **extra})
    return out


def draw():
    photos = tagged()
    rng = random.Random(SEED)
    forms = per_folder(rng, [p for p in photos if 'Statistics' in p[1]], FORMS_DRAW)
    rows = copy_in([(p, t, {'why': 'Statistics tag'}) for p, t in forms], 'f', JPEGS)
    unpaired = [str(CORPUS / r['pdf']) for r in read_tsv(PAIRS) if r['method'] == 'none']
    sizes = {p: pdf_image_side(p) for p in rng.sample(unpaired, LOWRES_SAMPLE)}
    small = [(p, set()) for p, side in sizes.items() if side and side < LOWRES_SIDE]
    print(f'{len(small)} of {LOWRES_SAMPLE} sampled PDFs with no JPEG have a page image under {LOWRES_SIDE} px',
          file=sys.stderr)
    picked = per_folder(rng, small, LOWRES_DRAW, most=1)
    rows += copy_in([(p, t, {'why': f'PDF with no JPEG, long side {sizes[p]} px', 'side': sizes[p]})
                     for p, t in picked], 'r', CORPUS)
    write_tsv(CACHE / 'draw.tsv', rows, ['id', 'file', 'source', 'tags', 'why'])
    (CACHE / 'draw-stats.json').write_text(json.dumps({
        'photos': len(photos), 'statistics': sum('Statistics' in t for _, t in photos), 'unpaired_pdfs': len(unpaired),
        'lowres_sample': LOWRES_SAMPLE, 'lowres_unread': sum(v is None for v in sizes.values()),
        'lowres_small': len(small)}, indent=1))
    print(f'{len(rows)} pages drawn into {CACHE / "draw"}', file=sys.stderr)


LABEL_COLS = ['id', 'file', 'set', 'hand', 'form', 'lowres', 'how']


def labels():
    """Every labelled page, with how its label was made. lowres is the ladder's: the quarter rung is low resolution,
    the half rung and the original are not (the readers hold at half and fall at quarter, ocr-panel-local.md)."""
    rows = []
    truth = [r for r in read_tsv(TRUTH) if r['status'] == 'done' and (PANEL_IMAGES / f"{r['page']}-original.jpg").exists()]
    for r in truth:
        form = 'yes' if r['table_form'] == 'yes' else 'no'
        how = 'truth set: kind and table_form as the drafting models and the owner left them (ocr-truth.md)'
        rows.append({'id': r['page'], 'file': str(PANEL_IMAGES / f"{r['page']}-original.jpg"), 'set': 'truth',
                     'hand': r['kind'], 'form': form, 'lowres': 'no', 'how': how})
        for rung in ('half', 'quarter'):
            f = PANEL_IMAGES / f"{r['page']}-{rung}.jpg"
            if f.exists():
                rows.append({'id': f"{r['page']}{rung[0]}", 'file': str(f), 'set': f'ladder-{rung}', 'hand': r['kind'],
                             'form': form, 'lowres': 'yes' if rung == 'quarter' else 'no',
                             'how': f'the truth page at the ladder\'s {rung} resolution (ocr_panel.py prepare)'})
    draws = {r['id']: r for r in read_tsv(CACHE / 'draw.tsv')}
    for r in read_tsv(CACHE / 'looked.tsv'):
        if r['drop'] == 'yes':
            continue
        d = draws[r['id']]
        rows.append({'id': r['id'], 'file': d['file'], 'set': 'drawn-forms' if r['id'].startswith('f') else 'drawn-lowres',
                     'hand': r['hand'], 'form': r['form'], 'lowres': r['lowres_look'],
                     'how': f"{d['why']}; labelled by looking (looked.tsv)"})
    for line in open(HW_HELD_OUT, encoding='utf-8'):
        hid, rel = line.split('\t')[:2]
        rows.append({'id': Path(hid).stem, 'file': str(JPEGS / rel), 'set': 'held-out-hand', 'hand': 'handwritten',
                     'form': 'no', 'lowres': 'no',
                     'how': 'Vision OCR\'s held-out handwriting photos (HW-PAGES-2026-10-15.tsv): Handwritten tag, by eye'})
    write_tsv(CACHE / 'labels.tsv', rows, LABEL_COLS)
    print(f'{len(rows)} labelled pages -> {CACHE / "labels.tsv"}', file=sys.stderr)


def signals():
    """Vision's signals and feature prints for every labelled page, and Vision OCR's page kind for those its
    W41.bench-vision-kind run did not cover (the panel originals are already in VISION_KIND)."""
    tool = Path('/tmp/kind-signals')
    src = HERE / 'kind_signals/kind-signals.swift'
    if not tool.exists() or src.stat().st_mtime > tool.stat().st_mtime:
        subprocess.run(['swiftc', '-O', '-o', str(tool), '-target', 'arm64-apple-macos26.0', str(src)], check=True)
    rows = read_tsv(CACHE / 'labels.tsv')
    lst = CACHE / 'signals-list.tsv'
    lst.write_text(''.join(f"{r['id']}\t{r['file']}\n" for r in rows))
    with open(CACHE / 'signals.tsv', 'w') as out:
        subprocess.run([str(tool), str(lst), str(CACHE / 'featureprints.tsv')], stdout=out, check=True)
    done = {r['id'] for r in read_tsv(VISION_KIND)}
    rest = CACHE / 'vision-kind-list.tsv'
    rest.write_text(''.join(f"{r['id']}\t{r['file']}\n" for r in rows if r['id'] not in done))
    with open(CACHE / 'vision-kind.tsv', 'w') as out:
        subprocess.run(['bash', str(HERE / 'vision_kind/run.sh'), str(rest)], stdout=out, check=True)


LAB_HUB = Path.home() / '.local/share/visionocr-ocrlab/hf/hub'
VLMS = {  # open weights already in the Vision OCR lab's cache, loaded by local path, read only
    'qwen3.5-2b-mlx4': LAB_HUB / 'models--mlx-community--Qwen3.5-2B-4bit/snapshots/674aaa7240b91e8012fcad5d791b7dfe5ba90207',
    'qwen3.5-4b-mlx4': LAB_HUB / 'models--lmstudio-community--Qwen3.5-4B-MLX-4bit/snapshots/c43ee1d65576a5d98de1e8405cac93c371a655c1',
}
VLM_SIDE = 1024        # the longer side the model sees: kind needs the page's look, not its words
VLM_PROMPT = (
    'Look at this photographed archival page and classify it. Reply with exactly two words, nothing else.\n'
    'Word 1, how the text was made: typewritten (a typewriter or a computer printout in a fixed-width font), '
    'printed (typeset or printed: books, newspapers, magazines, brochures, letterpress), handwritten '
    '(written by hand), or mixed (typed or printed with a large share of handwriting).\n'
    'Word 2: table if the page is mainly a table of figures or a form with fields to fill, otherwise text.')
HANDS = ('typewritten', 'printed', 'handwritten', 'mixed')


def parse_vlm(raw):
    words = re.findall(r'[a-z]+', raw.lower())
    hand = next((w for w in words if w in HANDS), None)
    form = 'yes' if 'table' in words else 'no' if 'text' in words else None
    return hand, form


def vlm(key):
    import tempfile
    import mlx.core as mx
    import mlx_vlm
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    from PIL import Image, ImageOps

    os.environ['HF_HUB_OFFLINE'] = '1'  # local path, read only: never download
    repo = VLMS[key]
    if not (repo / 'config.json').exists():
        raise SystemExit(f'weights not in the lab cache: {repo}')
    out = CACHE / 'vlm' / f'{key}.jsonl'
    out.parent.mkdir(parents=True, exist_ok=True)
    done = {json.loads(l)['id'] for l in open(out)} if out.exists() else set()
    todo = [r for r in read_tsv(CACHE / 'labels.tsv') if r['id'] not in done]
    print(f'{key}: {len(todo)} pages', flush=True)
    if not todo:
        return
    mx.set_cache_limit(256 * 2**20)
    t0 = time.time()
    model, processor = load(str(repo))
    load_s = time.time() - t0
    chat = apply_chat_template(processor, model.config, VLM_PROMPT, num_images=1, enable_thinking=False)
    tmp = Path(tempfile.mkdtemp(prefix='kind-vlm-'))
    with open(out, 'a') as f:
        for k, r in enumerate(todo, 1):
            start = time.time()
            im = ImageOps.exif_transpose(Image.open(r['file'])).convert('RGB')
            im.thumbnail((VLM_SIDE, VLM_SIDE), Image.LANCZOS)
            shrunk = tmp / f"{r['id']}.png"
            im.save(shrunk)
            mx.reset_peak_memory()
            text, last = [], None
            for g in stream_generate(model, processor, chat, image=[str(shrunk)], max_tokens=12, temperature=0.0):
                text.append(g.text); last = g
            shrunk.unlink()
            raw = ''.join(text)
            hand, form = parse_vlm(raw)
            row = {'id': r['id'], 'key': key, 'raw': raw.strip()[:80], 'hand': hand, 'form': form,
                   'wall_s': round(time.time() - start, 2), 'prompt_tokens': getattr(last, 'prompt_tokens', 0),
                   'mlx_peak_gb': round(mx.get_peak_memory() / 2**30, 2), 'load_s': round(load_s, 1),
                   'runtime': 'mlx-vlm ' + mlx_vlm.__version__}
            f.write(json.dumps(row) + '\n'); f.flush()
            print(f"[{k}/{len(todo)}] {r['id']} {hand} {form} {row['wall_s']}s peak {row['mlx_peak_gb']} GB", flush=True)
    tmp.rmdir()


def report():
    raise SystemExit('report: not written yet (checkpoint)')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    for c in ('draw', 'labels', 'signals', 'report'):
        sub.add_parser(c)
    sub.add_parser('vlm').add_argument('--model', choices=sorted(VLMS), required=True)
    a = ap.parse_args()
    if a.cmd == 'vlm':
        vlm(a.model)
    else:
        {'draw': draw, 'labels': labels, 'signals': signals, 'report': report}[a.cmd]()


if __name__ == '__main__':
    main()
