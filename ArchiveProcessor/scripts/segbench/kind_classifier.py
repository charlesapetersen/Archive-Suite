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


LABEL_COLS = ['id', 'file', 'set', 'group', 'hand', 'form', 'lowres', 'how']  # group: the source folder


def labels():
    """Every labelled page, with how its label was made. lowres is the ladder's: the quarter rung is low resolution,
    the half rung and the original are not (the readers hold at half and fall at quarter, ocr-panel-local.md)."""
    rows = []
    truth = [r for r in read_tsv(TRUTH) if r['status'] == 'done' and (PANEL_IMAGES / f"{r['page']}-original.jpg").exists()]
    for r in truth:
        form = 'yes' if r['table_form'] == 'yes' else 'no'
        how = 'truth set: kind and table_form as the drafting models and the owner left them (ocr-truth.md)'
        rows.append({'id': r['page'], 'file': str(PANEL_IMAGES / f"{r['page']}-original.jpg"), 'set': 'truth', 'group': r['folder'],
                     'hand': r['kind'], 'form': form, 'lowres': 'no', 'how': how})
        for rung in ('half', 'quarter'):
            f = PANEL_IMAGES / f"{r['page']}-{rung}.jpg"
            if f.exists():
                rows.append({'id': f"{r['page']}{rung[0]}", 'file': str(f), 'set': f'ladder-{rung}', 'group': r['folder'],
                             'hand': r['kind'],
                             'form': form, 'lowres': 'yes' if rung == 'quarter' else 'no',
                             'how': f'the truth page at the ladder\'s {rung} resolution (ocr_panel.py prepare)'})
    draws = {r['id']: r for r in read_tsv(CACHE / 'draw.tsv')}
    for r in read_tsv(CACHE / 'looked.tsv'):
        if r['drop'] == 'yes':
            continue
        d = draws[r['id']]
        rows.append({'id': r['id'], 'file': d['file'], 'set': 'drawn-forms' if r['id'].startswith('f') else 'drawn-lowres',
                     'group': str(Path(d['source']).parent),
                     'hand': r['hand'], 'form': r['form'], 'lowres': r['lowres_look'],
                     'how': f"{d['why']}; labelled by looking (looked.tsv)"})
    for line in open(HW_HELD_OUT, encoding='utf-8'):
        hid, rel = line.split('\t')[:2]
        rows.append({'id': Path(hid).stem, 'file': str(JPEGS / rel), 'set': 'held-out-hand', 'group': str(Path(rel).parent),
                     'hand': 'handwritten',
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


REPORT = RESULTS / 'kind-classifier.md'
PAGES = RESULTS / 'ocr-pages.csv'
GUIDE = RESULTS / 'ocr-page-guidance.json'
LADDER_SCORES = REHEARSAL / 'ocr-panel-local/scores.csv'
GUARD = Path.home() / '.local/share/visionocr-ocrlab/guard.tsv'
VISION_KIND_S = 4.3    # s a page, W41.bench-vision-kind: 2,099 pages in about 30 minutes on five processes
KINDS3 = ('handwritten', 'typewritten', 'printed')


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return float('nan')


def lr_fit(X, y, k, lam, iters=300):
    """Multinomial logistic regression, L2, plain gradient descent on standardised features (no sklearn here)."""
    import numpy as np
    W = np.zeros((X.shape[1], k)); b = np.zeros(k)
    Y = np.eye(k)[y]
    for _ in range(iters):
        Z = X @ W + b; Z -= Z.max(1, keepdims=True)
        P = np.exp(Z); P /= P.sum(1, keepdims=True)
        G = P - Y
        W -= 0.5 * (X.T @ G / len(X) + lam * W); b -= 0.5 * G.mean(0)
    return W, b


def loo_lr(X, y, k, groups, lam=0.05):
    """Leave-one-folder-out predictions: each page scored by a model fitted without any page from its source folder
    (pages of one box look alike, so leaving out only the page would flatter a learned classifier)."""
    import numpy as np
    out = np.zeros(len(y), dtype=int)
    groups = np.array(groups)
    for g in set(groups):
        m = groups != g
        mu, sd = X[m].mean(0), X[m].std(0) + 1e-6
        W, b = lr_fit((X[m] - mu) / sd, y[m], k, lam)
        out[~m] = np.argmax(((X[~m] - mu) / sd) @ W + b, axis=1)
    return out


def loo_threshold(xs, ys, groups, below=True):
    """Leave-one-group-out: the cut that best separates the other groups' pages, applied to this group's."""
    def best(idx):
        """Cuts sit halfway between neighbouring values of the given pages (and past both ends); of those tied for
        most right, the middle of their range."""
        v = sorted({xs[i] for i in idx})
        cands = [v[0] - 1] + [(a + b) / 2 for a, b in zip(v, v[1:])] + [v[-1] + 1]
        scored = [(sum((xs[i] <= c if below else xs[i] >= c) == ys[i] for i in idx), c) for c in cands]
        top = max(a for a, _ in scored)
        tied = [c for a, c in scored if a == top]
        return (tied[0] + tied[-1]) / 2
    preds = [None] * len(xs)
    for g in set(groups):
        rest = [i for i in range(len(xs)) if groups[i] != g]
        c = best(rest)
        for i in range(len(xs)):
            if groups[i] == g:
                preds[i] = xs[i] <= c if below else xs[i] >= c
    return preds, best(range(len(xs)))


def confusion(truth, pred, classes):
    head = '| truth \\ said | ' + ' | '.join(classes) + ' | right |\n|---|' + '---:|' * (len(classes) + 1) + '\n'
    rows = []
    for t in classes:
        idx = [i for i in range(len(truth)) if truth[i] == t]
        if not idx:
            continue
        cells = [str(sum(pred[i] == c for i in idx)) for c in classes]
        rows.append(f'| {t} | ' + ' | '.join(cells) + f' | {sum(pred[i] == t for i in idx)}/{len(idx)} |')
    return head + '\n'.join(rows)


def guard_peak(label):
    rows = [l.rstrip('\n').split('\t') for l in open(GUARD)] if GUARD.exists() else []
    rows = [r for r in rows if len(r) > 6 and r[1] == label and r[2] == '0']
    return (max(int(r[4]) for r in rows) / 1024, max(int(r[5]) for r in rows) / 1024) if rows else (None, None)


def report():
    import numpy as np
    lab = read_tsv(CACHE / 'labels.tsv')
    sig = {r['id']: r for r in read_tsv(CACHE / 'signals.tsv')}
    vk = {r['id']: r for r in read_tsv(VISION_KIND)} | {r['id']: r for r in read_tsv(CACHE / 'vision-kind.tsv')}
    fp = {}
    for line in open(CACHE / 'featureprints.tsv'):
        pid, _, v = line.rstrip('\n').partition('\t')
        fp[pid] = np.array([float(x) for x in v.split(',')])
    vlms = {}
    for key in VLMS:
        p = CACHE / 'vlm' / f'{key}.jsonl'
        rows = {r['id']: r for r in map(json.loads, open(p))} if p.exists() else {}
        if rows and all(r['id'] in rows for r in lab):
            vlms[key] = rows
        elif rows:
            print(f'{key}: {len(rows)} of {len(lab)} pages read, left out until finished', file=sys.stderr)
    missing = [r['id'] for r in lab if r['id'] not in sig or 'text_px' not in sig[r['id']] or r['id'] not in vk]
    if missing:
        raise SystemExit(f'no signals for {missing[:5]}… run signals first')
    L = []
    J = {'pages': len(lab), 'hand': [], 'form': [], 'lowres': [], 'routing': [], 'speed': []}

    # ---- 1. the hand, on each page at its own resolution (the ladder's copies left out: they are the same pages)
    orig = [r for r in lab if not r['set'].startswith('ladder')]
    truth_h = [r['hand'] for r in orig]
    vision_h = ['handwritten' if vk[r['id']]['vision_kind'] == 'handwriting' else 'typewritten' for r in orig]
    harm = [num(sig[r['id']]['harmonic']) for r in orig]
    # typewritten against printed by the harmonic, on the pages Vision does not call handwriting: cut chosen LOO
    tp = [i for i in range(len(orig)) if vision_h[i] != 'handwritten' and truth_h[i] in ('typewritten', 'printed')
          and harm[i] == harm[i]]
    cut_pred, harm_cut = loo_threshold([harm[i] for i in tp], [truth_h[i] == 'typewritten' for i in tp],
                                       [orig[i]['id'] for i in tp], below=False)
    harm_loo = {tp[j]: cut_pred[j] for j in range(len(tp))}
    vision_hp = [vision_h[i] if vision_h[i] == 'handwritten' else
                 ('typewritten' if harm_loo.get(i, harm[i] >= harm_cut if harm[i] == harm[i] else True) else 'printed')
                 for i in range(len(orig))]
    scal = ['harmonic', 'periodic', 'conf', 'text_px', 'lines']
    def feats(r, with_fp=True, sorter=True):
        s = sig[r['id']]
        x = [num(s[c]) for c in scal] + ([1.0 if vk[r['id']]['vision_kind'] == 'handwriting' else 0.0] if sorter else [])
        x = [0.0 if v != v else v for v in x]
        return np.concatenate([x, fp[r['id']]]) if with_fp else np.array(x)
    y3 = np.array([KINDS3.index(h) if h in KINDS3 else KINDS3.index('handwritten') for h in truth_h])  # mixed -> hand
    folders = [r['group'] for r in orig]
    lr_fp = [KINDS3[k] for k in loo_lr(np.array([feats(r) for r in orig]), y3, 3, folders)]
    lr_sc = [KINDS3[k] for k in loo_lr(np.array([feats(r, False) for r in orig]), y3, 3, folders, lam=0.01)]
    lr_nos = [KINDS3[k] for k in loo_lr(np.array([feats(r, sorter=False) for r in orig]), y3, 3, folders)]
    hand_methods = {'Vision OCR sorter (handwriting, else typewritten)': vision_h,
                    'Vision sorter + ink periodicity (cut chosen leave-one-out)': vision_hp,
                    'Vision signals, logistic regression (leave-one-folder-out)': lr_sc,
                    'Vision signals + feature print, logistic regression (leave-one-folder-out)': lr_fp,
                    'The same without Vision OCR\'s sorter as an input (leave-one-folder-out)': lr_nos}
    for key, rows in vlms.items():
        hand_methods[f'{key} (mlx-vlm, {VLM_SIDE} px, two-word answer)'] = [rows[r['id']]['hand'] or '?' for r in orig]
    classes = list(HANDS)
    L.append('## 1. The hand: handwritten, typewritten, printed\n')
    n = {h: truth_h.count(h) for h in HANDS}
    L.append(f'{len(orig)} pages at their own resolution: handwritten {n["handwritten"]}, typewritten {n["typewritten"]}, '
             f'printed {n["printed"]}, mixed {n["mixed"]}. Right = the hand the label gives; for the learned rows each '
             'page is scored by a model fitted without any page from its folder. Mixed pages count as handwriting for the learned rows, '
             'which have no mixed class (the guide has no mixed kind either).\n')
    L.append('| method | right | handwritten found | typewritten | printed | handwriting called on a typed or printed page |')
    L.append('|---|---:|---:|---:|---:|---:|')
    def hand_row(name, pred):
        ok = sum(p == t or (t == 'mixed' and p == 'handwritten') for p, t in zip(pred, truth_h))
        per = {h: (sum(pred[i] == h for i in range(len(orig)) if truth_h[i] == h), n[h]) for h in KINDS3}
        fa = sum(pred[i] == 'handwritten' for i in range(len(orig)) if truth_h[i] in ('typewritten', 'printed'))
        L.append(f'| {name} | {ok}/{len(orig)} | ' + ' | '.join(f'{a}/{b}' for a, b in per.values()) + f' | {fa} |')
        J['hand'].append({'method': name, 'right': ok, 'n': len(orig), 'per_kind': per, 'false_hand': fa})
    for name, pred in hand_methods.items():
        hand_row(name, pred)
    L.append(f'\nThe periodicity cut on all the pages is harmonic ≥ {harm_cut:.3f}.\n')
    best_hand = max(hand_methods, key=lambda k: sum(p == t or (t == 'mixed' and p == 'handwritten')
                                                    for p, t in zip(hand_methods[k], truth_h)))
    L.append(f'Confusions of the best row ({best_hand}):\n')
    L.append(confusion(truth_h, hand_methods[best_hand], classes) + '\n')

    # ---- 2. forms and tables
    truth_f = [r['form'] == 'yes' for r in orig]
    tab = [num(sig[r['id']]['tables']) >= 1 and num(sig[r['id']]['table_share']) >= 0 for r in orig]
    share = [num(sig[r['id']]['table_share']) for r in orig]
    sp, share_cut = loo_threshold(share, truth_f, [r['id'] for r in orig], below=False)
    form_methods = {'Vision document request finds any table': tab,
                    'Vision table share of the page (cut chosen leave-one-out)': sp}
    yf = np.array([int(t) for t in truth_f])
    form_methods['Vision signals + feature print, logistic regression (leave-one-folder-out)'] = [
        bool(k) for k in loo_lr(np.array([np.concatenate([[share[i], num(sig[r['id']]['table_cells'])], feats(r, sorter=False)])
                                          for i, r in enumerate(orig)]), yf, 2, folders)]
    for key, rows in vlms.items():
        form_methods[f'{key}'] = [rows[r['id']]['form'] == 'yes' for r in orig]
    L.append('## 2. Forms and tables\n')
    L.append(f'The same {len(orig)} pages: {sum(truth_f)} are mainly a table or a form (4 in the truth set, '
             f'{sum(truth_f) - 4} found among the drawn pages by looking).\n')
    L.append('| method | right | forms found | false calls |\n|---|---:|---:|---:|')
    for name, pred in form_methods.items():
        J['form'].append({'method': name, 'right': sum(p == t for p, t in zip(pred, truth_f)), 'n': len(orig),
                          'found': sum(p and t for p, t in zip(pred, truth_f)), 'forms': sum(truth_f),
                          'false': sum(p and not t for p, t in zip(pred, truth_f))})
        L.append(f'| {name} | {sum(p == t for p, t in zip(pred, truth_f))}/{len(orig)} | '
                 f'{sum(p and t for p, t in zip(pred, truth_f))}/{sum(truth_f)} | {sum(p and not t for p, t in zip(pred, truth_f))} |')
    L.append(f'\nThe share cut on all the pages is ≥ {share_cut:.3f} of the page.\n')

    # ---- 3. low resolution, on the ladder (original, half, quarter of the same 20 pages) and the drawn small pages
    lad_pages = {r['id'][:4] for r in lab if r['set'] == 'ladder-quarter'}
    lr_rows = [r for r in lab if r['id'][:4] in lad_pages and r['set'] in ('truth', 'ladder-half', 'ladder-quarter')]
    lr_rows += [r for r in lab if r['set'] == 'drawn-lowres']
    tpx = [num(sig[r['id']]['text_px']) for r in lr_rows]
    side = [max(num(sig[r['id']]['width']), num(sig[r['id']]['height'])) for r in lr_rows]
    yl = [r['lowres'] == 'yes' for r in lr_rows]
    grp = [r['id'][:4] for r in lr_rows]
    p_px, px_cut = loo_threshold(tpx, yl, grp)
    p_side, side_cut = loo_threshold(side, yl, grp)
    L.append('## 3. Low resolution\n')
    L.append(f'The ladder\'s {len(lad_pages)} pages at three sizes ({len(lr_rows) - 3} images) and the 3 small pages '
             f'drawn from the corpus; low resolution is the quarter rung, where the readers fall '
             '(Qwen3.6 27B 96.1 → 95.3 → 71.7 by rung), and the one drawn page judged blurred by looking. The cut is '
             'chosen leaving out every size of the page being judged.\n')
    L.append('| method | right | low found | false calls | cut on all |\n|---|---:|---:|---:|---:|')
    for name, pred, cut in (('median text line height in pixels', p_px, f'≤ {px_cut:.1f} px'),
                            ('long side of the image in pixels', p_side, f'≤ {side_cut:.0f} px')):
        J['lowres'].append({'method': name, 'label': 'quarter rung', 'cut': cut, 'found': sum(p and t for p, t in zip(pred, yl)),
                            'low': sum(yl), 'false': sum(p and not t for p, t in zip(pred, yl)), 'n': len(yl)})
        L.append(f'| {name} | {sum(p == t for p, t in zip(pred, yl))}/{len(yl)} | {sum(p and t for p, t in zip(pred, yl))}/'
                 f'{sum(yl)} | {sum(p and not t for p, t in zip(pred, yl))} | {cut} |')
    # A second definition, measured: the image reads at least 10 points worse than its original for Qwen3.6 27B
    # (the guide's forms pick and the best reader run at every rung).
    sc = {}
    for r in csv.DictReader(open(LADDER_SCORES)):
        sc[(r['key'], r['page'], r['scale'])] = num(r['nes']) if r['ok'] == 'True' else 0.0
    rung = {'truth': 'original', 'ladder-half': 'half', 'ladder-quarter': 'quarter'}
    lad = [i for i, r in enumerate(lr_rows) if r['set'] in rung]
    drop = [sc[('qwen3.6-27b', lr_rows[i]['id'][:4], 'original')] - sc[('qwen3.6-27b', lr_rows[i]['id'][:4],
                                                                        rung[lr_rows[i]['set']])] >= 0.10 for i in lad]
    d_px, dpx_cut = loo_threshold([tpx[i] for i in lad], drop, [grp[i] for i in lad])
    d_side, dside_cut = loo_threshold([side[i] for i in lad], drop, [grp[i] for i in lad])
    nq = sum(lr_rows[i]['set'] == 'ladder-quarter' for i in lad)
    L.append(f'\nMeasured instead: an image that Qwen3.6 27B reads at least 10 points worse than the same page\'s '
             f'original. {sum(drop)} of the {len(lad)} ladder images are ('
             f'{sum(d for d, i in zip(drop, lad) if lr_rows[i]["set"] == "ladder-quarter")} of the {nq} quarter, '
             f'{sum(d for d, i in zip(drop, lad) if lr_rows[i]["set"] == "ladder-half")} half): the fall is page by page, '
             'and pages with 6 px lines can read as well as their originals.\n')
    L.append('| method | right | dropped found | false calls | cut on all |\n|---|---:|---:|---:|---:|')
    for name, pred, cut in (('median text line height in pixels', d_px, f'≤ {dpx_cut:.1f} px'),
                            ('long side of the image in pixels', d_side, f'≤ {dside_cut:.0f} px')):
        J['lowres'].append({'method': name, 'label': 'Qwen3.6 27B drops 10+ points', 'cut': cut,
                            'found': sum(p and t for p, t in zip(pred, drop)), 'low': sum(drop),
                            'false': sum(p and not t for p, t in zip(pred, drop)), 'n': len(drop)})
        L.append(f'| {name} | {sum(p == t for p, t in zip(pred, drop))}/{len(drop)} | {sum(p and t for p, t in zip(pred, drop))}/'
                 f'{sum(drop)} | {sum(p and not t for p, t in zip(pred, drop))} | {cut} |')
    allpx = [num(sig[r['id']]['text_px']) for r in orig]
    L.append(f'\nOn the {len(orig)} pages at their own size, {sum(x <= px_cut for x in allpx)} have a median line '
             f'under the cut: ' + ', '.join(r['id'] for r, x in zip(orig, allpx) if x <= px_cut) + '.\n')

    # ---- 4. what a misrouted page costs: the guide's first pick for the page's kind, per page NES
    guide = {k['id']: k['picks'][0]['source']['route'] for k in json.load(open(GUIDE))['kinds']}
    nes = {}
    for r in csv.DictReader(open(PAGES)):
        nes[(r['route'], r['page'])] = num(r['nes']) if r['ok'] == 'True' else 0.0
    def route(hand, form, low):
        if low:
            return guide['low-resolution']
        if form:
            return guide['forms']
        return guide.get(hand, guide['typewritten']) if hand in KINDS3 else guide['handwritten']
    acc = [i for i, r in enumerate(orig) if r['set'] == 'truth' and (guide['handwritten'], r['id']) in nes]
    true_route = {i: route(truth_h[i], truth_f[i], False) for i in acc}
    def nes_of(i, rt):
        return nes.get((rt, orig[i]['id']))
    oracle = np.mean([nes_of(i, true_route[i]) for i in acc]) * 100
    L.append('## 4. What a wrong kind costs in reading accuracy\n')
    L.append(f'The guide\'s first pick for each kind ({", ".join(f"{k} → {v}" for k, v in guide.items())}), '
             f'on the {len(acc)} truth pages that have NES for every pick. A page goes to its flag\'s pick when it '
             'has one (low resolution first), else to its hand\'s. "Lost" is the mean NES, in points, of the routed '
             'reading below the reading the labelled kind would have chosen; a misroute can also gain.\n')
    L.append(f'Routed by the labels: {oracle:.2f}. Every page to one reader: ' + ', '.join(
        f'{rt} {np.mean([nes_of(i, rt) for i in acc]) * 100:.2f}' for rt in sorted(set(guide.values()))
        if all(nes_of(i, rt) is not None for i in acc)) + '.\n')
    L.append('| classifier | pages routed as labelled | mean NES | lost | worst page |\n|---|---:|---:|---:|---:|')
    lowflag = {i: max(num(sig[r['id']]['width']), num(sig[r['id']]['height'])) <= side_cut for i, r in enumerate(orig)}
    nolow = {i: False for i in lowflag}
    share_f = form_methods['Vision table share of the page (cut chosen leave-one-out)']
    lr_f = form_methods['Vision signals + feature print, logistic regression (leave-one-folder-out)']
    combos = {'Labels for hand and form, image size for low resolution': (truth_h, truth_f, lowflag),
              'Vision sorter + periodicity + table share + image size': (vision_hp, share_f, lowflag),
              'Vision sorter + periodicity + table share, no low-resolution flag': (vision_hp, share_f, nolow),
              'Feature-print LR for hand and form + image size': (lr_nos, lr_f, lowflag),
              'Feature-print LR for hand and form, no low-resolution flag': (lr_nos, lr_f, nolow)}
    for key in vlms:
        combos[f'{key} hand and form, no low-resolution flag'] = (
            hand_methods[next(k for k in hand_methods if k.startswith(key))], form_methods[key], nolow)
    combo_stats = {}
    for name, (hp, fpred, lflag) in combos.items():
        got, losses, same = [], [], 0
        for i in acc:
            rt = route(hp[i], fpred[i], lflag[i])
            v = nes_of(i, rt)
            if v is None:
                continue
            same += rt == true_route[i]
            got.append(v); losses.append(nes_of(i, true_route[i]) - v)
        combo_stats[name] = (np.mean(got) * 100, np.mean(losses) * 100)
        J['routing'].append({'classifier': name, 'as_labelled': same, 'n': len(acc), 'mean_nes': round(np.mean(got) * 100, 2),
                             'lost': round(np.mean(losses) * 100, 2), 'worst': round(max(losses) * 100, 1)})
        L.append(f'| {name} | {same}/{len(acc)} | {np.mean(got) * 100:.2f} | {np.mean(losses) * 100:+.2f} | '
                 f'{max(losses) * 100:.1f} |')
    # the quarter rung: what reading a low-resolution page with a reader other than the guide's low pick costs
    q = {}
    for r in csv.DictReader(open(LADDER_SCORES)):
        if r['scale'] == 'quarter':
            q[(r['key'], r['page'])] = num(r['nes']) if r['ok'] == 'True' else 0.0
    qp = sorted({p for _, p in q})
    qm = {k: np.mean([q[(k, p)] for p in qp]) * 100 for k in {k for k, _ in q} if all((k, p) in q for p in qp)}
    L.append(f'\nOn the {len(qp)} quarter-rung pages, the guide\'s low-resolution pick reads {qm[guide["low-resolution"]]:.1f}; '
             f'a missed flag sends the page to its hand\'s pick, which was not run at that size except '
             f'{guide["forms"]} ({qm.get(guide["forms"], float("nan")):.1f}). So a missed low-resolution page costs '
             f'about {qm[guide["low-resolution"]] - qm.get(guide["forms"], float("nan")):.0f} points when it lands on '
             f'{guide["forms"]}, and is unmeasured for the others.\n')

    # ---- 5. speed and memory
    L.append('## 5. Speed and memory on the M3 Pro (18 GB)\n')
    L.append('| step | s a page (median) | peak memory |\n|---|---:|---:|')
    def med(xs):
        xs = sorted(x for x in xs if x == x)
        return xs[len(xs) // 2] if xs else float('nan')
    allsig = [sig[r['id']] for r in lab]
    for c, name in (('s_text', 'Vision text lines (accurate) + ink periodicity'), ('s_tables', 'Vision document request (tables)'),
                    ('s_print', 'Vision feature print')):
        L.append(f'| {name} | {med([num(s[c]) for s in allsig]):.2f} | OS models, not measured apart |')
        J['speed'].append({'step': name, 's_page': round(med([num(s[c]) for s in allsig]), 2), 'peak_gb': None})
    L.append(f'| Vision OCR\'s sorter (W41.bench-vision-kind) | about {VISION_KIND_S} | – |')
    for key, rows in vlms.items():
        peak_mlx = max(r['mlx_peak_gb'] for r in rows.values())
        rss, foot = guard_peak(f'kind-vlm-{key}')
        foot_s = f', footprint {foot:.1f} GB (run-guarded)' if foot else ''
        J['speed'].append({'step': key, 's_page': round(med([r['wall_s'] for r in rows.values()]), 2),
                           'peak_gb': round(foot or peak_mlx, 1)})
        L.append(f'| {key} | {med([r["wall_s"] for r in rows.values()]):.2f} (load {next(iter(rows.values()))["load_s"]} s) | '
                 f'MLX {peak_mlx:.2f} GB{foot_s} |')
    # ---- 6. the recommendation, and the fitted model W41.app-page-kind can load
    Xh = np.array([feats(r, sorter=False) for r in orig])
    Xf = np.array([np.concatenate([[share[i], num(sig[r['id']]['table_cells'])], feats(r, sorter=False)])
                   for i, r in enumerate(orig)])
    model = {'_about': 'W41.bench-kind-classifier: logistic regressions on Apple Vision signals and the image feature '
                       'print (VNGenerateImageFeaturePrintRequest, default revision, macOS 26), fitted on every labelled '
                       'page at its own resolution. x = (features - mean) / sd; scores = x @ W + b; softmax. Features '
                       'in order; kind-signals.swift measures them all.',
             'measured': time.strftime('%Y-%m-%d')}
    for name, X, y, classes, lam in (('hand', Xh, y3, list(KINDS3), 0.05), ('form', Xf, yf, ['no', 'yes'], 0.05)):
        mu, sd = X.mean(0), X.std(0) + 1e-6
        W, b = lr_fit((X - mu) / sd, y, len(classes), lam)
        model[name] = {'classes': classes, 'features': (['table_share', 'table_cells'] if name == 'form' else []) + scal +
                       [f'print{j}' for j in range(len(fp[orig[0]['id']]))],
                       'mean': [round(float(v), 6) for v in mu], 'sd': [round(float(v), 6) for v in sd],
                       'W': [[round(float(v), 6) for v in row] for row in W], 'b': [round(float(v), 6) for v in b]}
    (RESULTS / 'kind-classifier-model.json').write_text(json.dumps(model, separators=(',', ':')) + '\n')
    rt = {r['classifier']: r for r in J['routing']}
    best = rt['Feature-print LR for hand and form, no low-resolution flag']
    L.append('## 6. Recommended for W41.app-page-kind\n')
    L.append(f'**Apple Vision\'s signals and its image feature print, with a logistic regression for the hand and one for '
             f'forms** (`kind-classifier-model.json`, fitted on all {len(orig)} pages; `kind-signals.swift` measures '
             f'its inputs), and **no low-resolution flag yet**. It needs no model download and runs in about '
             f'{sum(x["s_page"] for x in J["speed"][:3]):.1f} s a page on the M3 Pro with the OS\'s own models; Vision '
             f'OCR\'s sorter adds nothing to it as an input (the same {J["hand"][4]["right"]} of {len(orig)} either way) '
             'and costs about 4 s a page, so it is left out. Scored with each folder left out of the '
             f'fitting, it gets the hand right on {J["hand"][4]["right"]} of {len(orig)} pages and finds '
             f'{J["form"][2]["found"]} of {J["form"][2]["forms"]} forms with {J["form"][2]["false"]} false calls; routed by '
             f'the guide it reads {best["mean_nes"]:.2f} NES on the 96 accuracy pages, {best["lost"]:.2f} points below '
             f'routing by the true kinds ({oracle:.2f}) and above the best single reader. Its weights come from these '
             'pages and folders, so the app should keep the user\'s default when its top probability is low, and '
             'refit as labelled pages grow.\n')
    L.append('The small vision-language models are slower and worse at the distinction that matters most for the '
             'guide, typewritten against printed (the printed pick is a different reader), though they find '
             'handwriting. Low resolution is left out because neither definition is caught well: image size finds '
             'the quarter rung but also flags small originals the readers read well, which cost NES when routed to '
             'the low-resolution pick, and text height does not predict which pages actually fall. Every corpus photo '
             'is 2,592 px or more, and 12 of 1,500 sampled PDFs with no JPEG have a page image under 1,100 px (3 of '
             'them born-digital), so the case is rare.\n')
    L.append('## Limits\n')
    L.append(f'{len(orig)} pages from one corpus, with few forms ({sum(truth_f)}) and few mixed pages ({n["mixed"]}). The '
             'drawn pages were labelled by one reader looking at contact sheets, not blind; the truth set\'s kinds are '
             'its own. The 15 held-out handwriting photos come from one collection, and the drawn forms from nine folders, most of '
             'them one university\'s admissions records, so leaving a folder out may still flatter the learned rows. The '
             'learned rows owe nearly everything to the feature print: on Vision\'s scalar signals alone the hand is right on '
             f'{J["hand"][2]["right"]} of {len(orig)}. The Vision OCR sorter judged the '
             'panel originals at vision-ocr f8f97d2 (W41.bench-vision-kind) and the other pages at ff798aa. NES lost is '
             'measured only on the 96 truth pages; a missed low-resolution page is unmeasured for most readers. '
             'Seconds a page are medians from one run.\n')
    head = ['# Page-kind classifier (W41.bench-kind-classifier)\n',
            f'Measured {time.strftime("%Y-%m-%d")} on {len(lab)} labelled page images: the OCR truth set\'s 99, the '
            'resolution ladder\'s half and quarter copies of 20 of them, 27 Statistics-tagged corpus photos and 3 '
            'small corpus PDFs drawn at random and labelled by looking, and Vision OCR\'s 15 held-out handwriting '
            'photos. Every method runs on the Mac with no paid call: Apple Vision, and open weights already in the '
            'Vision OCR lab\'s cache. Reproduce: `kind_classifier.py draw`, `labels`, `signals`, `vlm --model KEY` '
            'under run-guarded.sh, then `report` (header of `scripts/segbench/kind_classifier.py`). Page images and '
            'labels stay in the private cache.\n']
    J['oracle_nes'] = round(oracle, 2)
    REPORT.write_text('\n'.join(head + L) + '\n')
    REPORT.with_suffix('.json').write_text(json.dumps(J, indent=1) + '\n')
    print(f'wrote {REPORT}', file=sys.stderr)


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
