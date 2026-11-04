#!/usr/bin/env python3
"""W46.capture-ladder, the 96 at every setting (L tests 2, 3): which capture defect costs which reader how much.

    python3 capture_ladder.py make --out DIR     # on the Mac: the defect images and pages.jsonl; no model call
    V=~/Library/Caches/ArchiveSuiteRehearsal/enh-dewarp/venv/bin/python   # sacrebleu 2.5.1, OpenCV
    $V capture_ladder.py vision      # Apple quads and Vision lines on every image; the quad arm on tilt 12 / 20
    $V capture_ladder.py signals     # the capture-time signals on every image (no reader output used)
    $V capture_ladder.py report      # score the Sherlock readings and Vision against each reader's raw baseline

The source is the panel's own original-scale image of each of the 99 owner pages (ocr-panel-local/images/
<page>-original.jpg, the file every scored route and the dewarp run read), so the dewarp run's raw readings are each
reader's no-defect baseline. Each image is degraded by one defect at one setting, deterministically (seed 46):

  Augraphy    ShadowCast, LightingGradient, ReflectedLight, LowLightNoise (one setting each, the library's defaults)
  OpenCV      motion blur 9 / 17 / 31 px, defocus (Gaussian) sigma 1.5 / 3 / 5, perspective tilt 5 / 12 / 20 degrees
  JPEG        quality 60 / 75 / 85

16 variants x 99 pages. The pack is read on the cluster by dewarp_cluster.py, unchanged, with the dewarp run's
routes (Qwen3.6-27B and LightOnOCR-3 4B, the open sweep's prompts and server arguments). Not in this pass: the 895
subset, GLM-OCR on regions, the quality verdicts and SmartDoc-QA.

The Mac half (2026-11-03). `make` is deterministic: the images regenerate byte-identical to the Sherlock manifest's
hashes, and `report` refuses a reading whose image hash differs. Apple Vision (segbench-dewarp lines, the app's
settings) reads every image; its baseline is the dewarp run's Vision reading of the same raw file. The quad arm
(dewarp_arms.quad_arm on the Apple quad of the tilted image itself) is the measurement audit's dewarp check on the
tilt 12 and 20 images, Vision only here. Signals, each computed from the image alone, as a phone could at capture:
Laplacian variance and Tenengrad inside Vision's word boxes, the clipped-highlight share and mean luminance inside the
Apple quad, the quad-to-frame margin, and the share of the image inside word boxes (DetectDocumentSegmentation returns
at most one quad, so second-quad presence is not measurable with it). Each signal's AUC against a loss of 5 NES points
or more, per reader. No slicing by the optical capture tags (CAP-1); bowF1 beside NES (OCR-6). Raw text stays in
CACHE; the committed results hold page ids and numbers only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
SEED = 46
CACHE = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
SRC = CACHE / 'ocr-panel-local/images'


def variants():
    v = [(f'aug-{n}', n) for n in ('ShadowCast', 'LightingGradient', 'ReflectedLight', 'LowLightNoise')]
    v += [(f'motion-{k}', k) for k in (9, 17, 31)] + [(f'defocus-{s}', s) for s in (1.5, 3, 5)]
    v += [(f'tilt-{d}', d) for d in (5, 12, 20)] + [(f'jpeg-{q}', q) for q in (60, 75, 85)]
    return v


def degrade(name, arg, rgb, rng):
    """`rgb`: an HxWx3 uint8 array; returns (array or None, jpeg quality)."""
    import cv2
    import numpy as np
    if name.startswith('aug-'):
        import augraphy
        np.random.seed(rng.randrange(2**31)); random.seed(rng.randrange(2**31))
        out = getattr(augraphy, arg)()(rgb)
        return np.ascontiguousarray(out[..., :3] if out.ndim == 3 else np.stack([out] * 3, -1)), 92
    if name.startswith('motion-'):
        k = np.zeros((arg, arg), np.float32); k[arg // 2, :] = 1.0 / arg
        return cv2.filter2D(rgb, -1, k, borderType=cv2.BORDER_REPLICATE), 92
    if name.startswith('defocus-'):
        return cv2.GaussianBlur(rgb, (0, 0), sigmaX=arg, sigmaY=arg, borderType=cv2.BORDER_REPLICATE), 92
    if name.startswith('tilt-'):
        h, w = rgb.shape[:2]; f = max(h, w); t = math.radians(arg)
        K = np.array([[f, 0, w / 2], [0, f, h / 2], [0, 0, 1]], np.float64)
        R = np.array([[1, 0, 0], [0, math.cos(t), -math.sin(t)], [0, math.sin(t), math.cos(t)]])
        H = K @ R @ np.linalg.inv(K)
        corners = np.array([[0, 0, 1], [w, 0, 1], [w, h, 1], [0, h, 1]], np.float64).T
        c = H @ corners; c = c[:2] / c[2]
        T = np.array([[1, 0, -c[0].min()], [0, 1, -c[1].min()], [0, 0, 1]])
        size = (int(math.ceil(c[0].max() - c[0].min())), int(math.ceil(c[1].max() - c[1].min())))
        return cv2.warpPerspective(rgb, T @ H, size, borderMode=cv2.BORDER_CONSTANT, borderValue=(255, 255, 255)), 92
    if name.startswith('jpeg-'):
        return rgb, int(arg)
    raise ValueError(name)


def cmd_make(a):
    import numpy as np
    from PIL import Image
    import ocr_panel as P
    pages = [r['page'] for r in P.rows()]
    out = a.out; rows = []
    for name, arg in variants():
        d = out / 'images' / name; d.mkdir(parents=True, exist_ok=True)
        for p in pages:
            dst = d / f'{p}.jpg'
            if not dst.exists():
                rng = random.Random(f'{SEED}/{name}/{p}')
                with Image.open(SRC / f'{p}-original.jpg') as im:
                    rgb = np.asarray(im.convert('RGB'))
                arr, q = degrade(name, arg, rgb, rng)
                im = Image.fromarray(arr)
                im.thumbnail((2400, 2400), Image.Resampling.LANCZOS)   # the panel's ceiling, after the warp
                im.save(dst, 'JPEG', quality=q)
            rows.append({'id': f'{name}/{p}', 'image': f'{a.remote}/images/{name}/{p}.jpg',
                         'sha256': hashlib.sha256(dst.read_bytes()).hexdigest()})
        print(name, len(pages), flush=True)
    (out / 'pages.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
    (out / 'pack.json').write_text(json.dumps({'variants': [n for n, _ in variants()], 'pages': len(pages),
                                               'images': len(rows), 'seed': SEED, 'source': str(SRC)}, indent=1) + '\n')
    print(len(rows), 'images ->', out)


PACK = CACHE / 'capture-ladder/pack'                      # `make --out` here; images/<variant>/<page>.jpg
WORK = CACHE / 'capture-ladder'                           # lines/, quad/, arms/, signals.json
CLUSTER = CACHE / 'sherlock-results/capture-ladder-20261022'
DEWARP = CACHE / 'enh-dewarp'
DEWARP_CLUSTER = CACHE / 'sherlock-results/dewarp-20261022'
BIN = CACHE / 'segbench/bin/segbench-dewarp'
TILT_ARMS = ('quad-tilt-12', 'quad-tilt-20')
LOSS = 0.05                                               # a "loss": the page's NES falls 5 points or more


def scored_pages():
    import ocr_panel as P
    return [r for r in P.rows() if r['page'] not in P.AGREEMENT]


def image(variant, page):
    if variant == 'raw':
        import ocr_panel as P
        return P.CACHE / 'images' / f'{page}-original.jpg'
    if variant in TILT_ARMS:
        return WORK / 'arms' / variant / f'{page}.jpg'
    return PACK / 'images' / variant / f'{page}.jpg'


def lines_path(variant, page):
    if variant == 'raw':
        return DEWARP / 'lines/raw' / f'{page}.json'
    return WORK / 'lines' / variant / f'{page}.json'


def swift(mode, rows):
    import subprocess
    WORK.mkdir(parents=True, exist_ok=True)
    jobs = WORK / f'{mode}-jobs.tsv'
    jobs.write_text(''.join(f'{s}\t{d}\n' for s, d in rows))
    subprocess.run([str(BIN), mode, str(jobs)], check=True)


def cmd_vision(a):
    """Quads on every image (raw too), the quad arm on the tilt images, then Vision lines on all of them."""
    import numpy as np
    from PIL import Image
    import dewarp_arms as A
    import enh_dewarp as E
    names = [n for n, _ in variants()]
    pages = [r['page'] for r in scored_pages()]
    swift('quad', [(image(v, p), WORK / 'quad' / v / f'{p}.json') for v in ['raw', *names] for p in pages])
    for arm in TILT_ARMS:
        src = arm.removeprefix('quad-')
        for p in pages:
            dst = image(arm, p)
            if dst.exists():
                continue
            with Image.open(image(src, p)) as im:
                img = np.asarray(im.convert('RGB'))
            out, _, _ = A.quad_arm(img, json.loads((WORK / 'quad' / src / f'{p}.json').read_text()))
            E.freeze(out, dst)
    swift('lines', [(image(v, p), lines_path(v, p)) for v in [*names, *TILT_ARMS] for p in pages])


def page_signals(variant, page):
    """Reference-free capture signals of one image, from its pixels, its Apple quad and its Vision word boxes."""
    import cv2
    import numpy as np
    g = cv2.imread(str(image(variant, page)), cv2.IMREAD_GRAYSCALE)
    h, w = g.shape
    q = json.loads((WORK / 'quad' / variant / f'{page}.json').read_text())
    mask = np.zeros_like(g, np.uint8)
    for line in json.loads(lines_path(variant, page).read_text())['lines']:
        for word in line.get('words') or [line]:
            cv2.fillPoly(mask, [np.int32(np.float64(word['quad']) * (w, h))], 1)
    inside = mask.astype(bool)
    lap = cv2.Laplacian(g, cv2.CV_64F)
    gx, gy = cv2.Sobel(g, cv2.CV_64F, 1, 0), cv2.Sobel(g, cv2.CV_64F, 0, 1)
    qmask, margin = np.ones_like(g, np.uint8), 0.
    if q.get('found'):
        poly = np.float64(q['corners']) * (w, h)
        qmask = np.zeros_like(g, np.uint8)
        cv2.fillPoly(qmask, [np.int32(poly)], 1)
        margin = float(min(poly[:, 0].min() / w, poly[:, 1].min() / h, 1 - poly[:, 0].max() / w,
                           1 - poly[:, 1].max() / h))
    qm = qmask.astype(bool)
    return {'variant': variant, 'page': page, 'text_px': float(inside.mean()),
            'laplacian_var': float(lap[inside].var()) if inside.any() else 0.,
            'tenengrad': float((gx[inside] ** 2 + gy[inside] ** 2).mean()) if inside.any() else 0.,
            'clipped': float((g[qm] >= 250).mean()), 'luminance': float(g[qm].mean() / 255),
            'quad_found': bool(q.get('found')), 'quad_count': q.get('count', 0), 'quad_margin': margin}


def cmd_signals(a):
    names = [n for n, _ in variants()]
    rows = [page_signals(v, r['page']) for v in ['raw', *names] for r in scored_pages()]
    (WORK / 'signals.json').write_text(json.dumps(rows) + '\n')
    print(len(rows), 'images ->', WORK / 'signals.json')


def cluster_readings(root, routes, expected, check_images):
    """{route: {id: (text, status)}} from an owner-collected pack, refused on any identity, model, prompt or image
    mismatch; a capped, failed or blank attempt is an empty reading and stays in the denominator."""
    import ocr_panel as P
    import enh_dewarp as E
    sys.path.insert(0, str(HERE / 'corpus'))
    import farmshare_expanded_report as X
    manifest = {}
    for line in (root / 'pages.jsonl').read_text().splitlines():
        if line.strip():
            r = json.loads(line); manifest[r['id']] = r
    if not expected <= set(manifest):
        raise SystemExit(f'{root}: the manifest lacks {len(expected - set(manifest))} expected images')
    if check_images:
        for ident in sorted(expected):
            v, p = ident.split('/')
            if hashlib.sha256(image(v, p).read_bytes()).hexdigest() != manifest[ident]['sha256']:
                raise SystemExit(f'{ident}: the local image differs from the collected manifest')
    specs = json.loads((root / 'routes.json').read_text())
    out = {}
    for route in routes:
        mode, model = E.READERS[route], E.CLUSTER_MODELS[route]
        if specs[route]['model'] != model:
            raise SystemExit(f'{route}: model differs from the frozen experiment')
        prompt = hashlib.sha256((P.PROMPT if mode == 'panel' else '').encode()).hexdigest()
        recs = {}
        for f in (root / 'out' / route).glob('*/*.json'):
            rec = json.loads(f.read_text())
            ident = rec.get('id')
            if ident not in expected:
                continue
            st = rec.get('status')
            ok = (rec.get('route') == route and rec.get('model') == model and rec.get('max_tokens') == 8192
                  and rec.get('sha256') == manifest[ident]['sha256'] and isinstance(rec.get('raw'), str)
                  and rec.get('prompt_sha256') == prompt
                  and ((st == 'ok' and rec.get('finish') == 'stop') or (st == 'cap' and rec.get('finish') == 'length')
                       or st == 'error'))
            if not ok or ident in recs:
                raise SystemExit(f'{route}/{ident}: inconsistent or duplicate result')
            recs[ident] = rec
        if set(recs) != expected:
            raise SystemExit(f'{route}: {len(recs)}/{len(expected)} results')
        out[route] = {i: (X.reading(r, mode), r['status']) for i, r in recs.items()}
    return out


READERS = {'qwen3.6-27b': 'Qwen3.6-27B', 'lightonocr3-4b': 'LightOnOCR-3 4B', 'vision': 'Apple Vision'}


def score_all():
    """One row per reader, variant and page: the panel's scorer, plus bowF1 from its word counts."""
    import ocr_panel as P
    import ocr_panel_score as S
    names = [n for n, _ in variants()]
    rows = scored_pages()
    pages = [r['page'] for r in rows]
    routes = ('qwen3.6-27b', 'lightonocr3-4b')
    lad = cluster_readings(CLUSTER, routes, {f'{v}/{p}' for v in names for p in pages}, check_images=True)
    base = cluster_readings(DEWARP_CLUSTER, routes, {f'raw/{p}' for p in pages}, check_images=False)
    out = []
    for r in rows:
        p = r['page']
        truth = (P.TRUTH / 'truth' / f'{p}.txt').read_text()
        meta = {'page': p, 'source': 'original' if r['source'] == 'original' else 'pdf image', 'kind': r['kind']}
        cells = []
        for route in routes:
            cells.append((route, 'raw', *base[route][f'raw/{p}']))
            cells += [(route, v, *lad[route][f'{v}/{p}']) for v in names]
        for v in ['raw', *names, *TILT_ARMS]:
            text = '\n'.join(l['text'] for l in json.loads(lines_path(v, p).read_text())['lines'])
            cells.append(('vision', v, text, 'ok' if text else 'blank'))
        for route, v, text, status in cells:
            s = S.score(truth, text)
            n = s['words'] + s['hyp_words']
            status = 'blank' if status == 'ok' and not text else status   # an empty reply, not a loop
            out.append({**meta, 'reader': route, 'variant': v, 'status': status, 'ok': bool(text),
                        'bowf1': 2 * (s['words'] - s['missed']) / n if n else 1.,
                        **{k: s[k] for k in ('nes', 'chrf', 'words', 'hyp_words', 'missed', 'added')}})
    return out


def auc(pos, neg):
    """P(a loss image's signal is worse than a no-loss image's), ties half; signals are signed so larger = worse."""
    import bisect
    if not pos or not neg:
        return None
    s = sorted(neg)
    return sum(bisect.bisect_left(s, x) + (bisect.bisect_right(s, x) - bisect.bisect_left(s, x)) / 2
               for x in pos) / (len(pos) * len(neg))


def youden(pos, neg):
    """(J, threshold, hit rate, false-alarm rate) of the cut 'signal >= t' with the largest J."""
    best = (0., None, 0., 0.)
    if not pos or not neg:
        return best
    for t in sorted(set(pos)):
        tpr = sum(x >= t for x in pos) / len(pos); fpr = sum(x >= t for x in neg) / len(neg)
        if tpr - fpr > best[0]:
            best = (tpr - fpr, t, tpr, fpr)
    return best


SIGNALS = {  # name -> (label, sign: multiplied in so that larger means worse)
    'laplacian_var': ('Laplacian variance in word boxes (low = blur)', -1),
    'tenengrad': ('Tenengrad in word boxes (low = blur)', -1),
    'clipped': ('clipped-highlight share in the quad (high = glare)', 1),
    'luminance': ('mean luminance in the quad (low = dark)', -1),
    'quad_margin': ('quad-to-frame margin (low = cut or tight)', -1),
    'text_px': ('image share in Vision word boxes (low = text missed)', -1),
}


def cmd_report(a):
    import csv
    import ocr_panel as P
    import ocr_panel_score as S
    names = [n for n, _ in variants()]
    rows = score_all()
    by = {(r['reader'], r['variant'], r['page']): r for r in rows}
    pages = [{**r, 'source': 'original' if r['source'] == 'original' else 'pdf image'} for r in scored_pages()]
    groups = [('originals', lambda r: r['source'] == 'original'), ('PDF images', lambda r: r['source'] == 'pdf image'),
              ('typewritten', lambda r: r['kind'] == 'typewritten'), ('printed', lambda r: r['kind'] == 'printed'),
              ('handwritten', lambda r: r['kind'] == 'handwritten')]
    pct = lambda x: f'{100 * x:.1f}'
    ci = lambda d: f"{100 * d['delta']:+.1f} ({100 * d['lo']:+.1f} to {100 * d['hi']:+.1f})"
    summary, L = [], []
    for reader, label in READERS.items():
        vs = names + (list(TILT_ARMS) if reader == 'vision' else [])
        L += [f'## {label}', '',
              '| defect | n | loops (cap / timeout) | blank | NES strict % | Δ NES strict (95% CI) | NES answered % | bowF1 % | '
              'Δ bowF1 (95% CI) | words missed % | words added % | pages losing ≥5 NES |',
              '|---|---:|---:|---:|---:|---|---:|---:|---|---:|---:|---:|']
        bb = [by[reader, 'raw', r['page']] for r in pages]
        for v in ['raw', *vs]:
            rr = [by[reader, v, r['page']] for r in pages]
            words = sum(r['words'] for r in rr)
            ans = [r for r in rr if r['ok']]
            dn = S.paired([r['nes'] for r in rr], [b['nes'] for b in bb])
            db = S.paired([r['bowf1'] for r in rr], [b['bowf1'] for b in bb])
            cell = {'reader': reader, 'variant': v, 'n': len(rr), 'failed': len(rr) - len(ans),
                    'loops': sum(r['status'] in ('cap', 'error') for r in rr),
                    'blank': sum(r['status'] == 'blank' for r in rr),
                    'nes': sum(r['nes'] for r in rr) / len(rr),
                    'nes_answered': sum(r['nes'] for r in ans) / len(ans) if ans else 0.,
                    'bowf1': sum(r['bowf1'] for r in rr) / len(rr), 'd_nes': dn, 'd_bowf1': db,
                    'missed': sum(r['missed'] for r in rr) / words, 'added': sum(r['added'] for r in rr) / words,
                    'lost5': sum(b['nes'] - r['nes'] >= LOSS for r, b in zip(rr, bb))}
            summary.append(cell)
            raw = v == 'raw'
            L.append(f"| {v} | {len(rr)} | {cell['loops']} | {cell['blank']} | {pct(cell['nes'])} | {'—' if raw else ci(dn)} | "
                     f"{pct(cell['nes_answered'])} | {pct(cell['bowf1'])} | {'—' if raw else ci(db)} | "
                     f"{pct(cell['missed'])} | {pct(cell['added'])} | {'—' if raw else cell['lost5']} |")
        L += ['', f'Δ NES strict by page group, paired against {label} on the raw image (n in brackets):', '',
              '| defect | ' + ' | '.join(g for g, _ in groups) + ' |', '|---|' + '---|' * len(groups)]
        for v in vs:
            cells = []
            for _, f in groups:
                pp = [r['page'] for r in pages if f(r)]
                d = S.paired([by[reader, v, p]['nes'] for p in pp], [by[reader, 'raw', p]['nes'] for p in pp])
                cells.append(f"{ci(d)} [{d['n']}]")
            L.append(f'| {v} | ' + ' | '.join(cells) + ' |')
        L.append('')
    sig = {(s['variant'], s['page']): s for s in json.loads((WORK / 'signals.json').read_text())}
    L += ['## Capture-time signals against a loss of 5 NES points or more', '',
          '| signal | ' + ' | '.join(f'{lab} AUC' for lab in READERS.values()) + ' | ' +
          ' | '.join(f'{lab}: cut (hit / false alarm)' for lab in READERS.values()) + ' |',
          '|---|' + '---:|' * len(READERS) + '---|' * len(READERS)]
    sig_rows = []
    for name, (label, sign) in SIGNALS.items():
        aucs, cuts = [], []
        for reader in READERS:
            pos, neg = [], []
            for v in names:
                for r in pages:
                    loss = by[reader, 'raw', r['page']]['nes'] - by[reader, v, r['page']]['nes'] >= LOSS
                    (pos if loss else neg).append(sign * sig[v, r['page']][name])
            u = auc(pos, neg); _, t, tpr, fpr = youden(pos, neg)
            aucs.append('—' if u is None else f'{u:.2f}')
            cuts.append('—' if t is None else
                        f'{"≥" if sign > 0 else "≤"} {sign * t:.4g} ({100 * tpr:.0f}% / {100 * fpr:.0f}%)')
            sig_rows.append({'signal': name, 'reader': reader, 'auc': u, 'cut': None if t is None else sign * t,
                             'hit': tpr, 'false_alarm': fpr, 'losses': len(pos), 'cases': len(pos) + len(neg)})
        L.append(f'| {label} | ' + ' | '.join(aucs) + ' | ' + ' | '.join(cuts) + ' |')
    L += ['', 'Losses (of {} defect images): '.format(len(names) * len(pages)) + ', '.join(
        f"{lab} {next(s['losses'] for s in sig_rows if s['reader'] == rd)}" for rd, lab in READERS.items()) + '.', '']
    res = P.RESULTS
    fields = ['reader', 'variant', 'page', 'source', 'kind', 'status', 'ok', 'nes', 'chrf', 'bowf1', 'words',
              'hyp_words', 'missed', 'added']
    with (res / 'capture-ladder-pages.csv').open('w', newline='') as f:
        w = csv.DictWriter(f, fields, extrasaction='ignore', lineterminator='\n'); w.writeheader()
        for r in rows:
            w.writerow({k: round(v, 6) if isinstance(v, float) else v for k, v in r.items()})
    with (res / 'capture-ladder-signals.csv').open('w', newline='') as f:
        keys = ['variant', 'page', *SIGNALS, 'quad_found', 'quad_count']
        w = csv.DictWriter(f, keys, extrasaction='ignore', lineterminator='\n'); w.writeheader()
        for s in sig.values():
            w.writerow({k: round(v, 6) if isinstance(v, float) else v for k, v in s.items()})
    (res / 'capture-ladder.json').write_text(json.dumps({'loss': LOSS, 'summary': summary, 'signals': sig_rows},
                                                        indent=1) + '\n')
    (WORK / 'tables.md').write_text('\n'.join(L) + '\n')
    print('\n'.join(L))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('make'); p.add_argument('--out', type=Path, required=True)
    p.add_argument('--remote', default='/scratch/users/cp1/fs-ocr/capture-ladder-20261022')
    for name in ('vision', 'signals', 'report'):
        sub.add_parser(name)
    a = ap.parse_args()
    {'make': cmd_make, 'vision': cmd_vision, 'signals': cmd_signals, 'report': cmd_report}[a.cmd](a)


if __name__ == '__main__':
    main()
