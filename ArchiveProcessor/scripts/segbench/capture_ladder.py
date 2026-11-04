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
RESAVE = 'resave-q92'   # the raw image through make's save with no defect: Vision's baseline (see BASE)
# Apple Vision moves on a re-encode alone (its JPEG 85 row was +1.6 NES against the raw file, +4.7 on the PDF
# images), so its defect rows are paired against the raw image re-saved exactly as every defect image was; the
# Sherlock readers' JPEG 85 rows are within 0.3 points of raw, so raw stays theirs (re-saving needs no new reading).
BASE = {'qwen3.6-27b': 'raw', 'lightonocr3-4b': 'raw', 'vision': RESAVE}
LOSS = 0.05                                               # a "loss": the page's NES falls 5 points or more


def scored_pages():
    import ocr_panel as P
    return [r for r in P.rows() if r['page'] not in P.AGREEMENT]


def image(variant, page):
    if variant == 'raw':
        import ocr_panel as P
        return P.CACHE / 'images' / f'{page}-original.jpg'
    if variant in TILT_ARMS or variant == RESAVE:
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
    for p in pages:
        dst = image(RESAVE, p)
        if not dst.exists():
            with Image.open(image('raw', p)) as im:
                im = im.convert('RGB')
                im.thumbnail((2400, 2400), Image.Resampling.LANCZOS)
                dst.parent.mkdir(parents=True, exist_ok=True)
                im.save(dst, 'JPEG', quality=92)
    swift('lines', [(image(v, p), lines_path(v, p)) for v in [*names, *TILT_ARMS, RESAVE] for p in pages])


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
    rows = [page_signals(v, r['page']) for v in ['raw', *names] for r in scored_pages()]   # raw: reference only
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
        for v in ['raw', RESAVE, *names, *TILT_ARMS]:
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
    best = (0.05, None, 0., 0.)   # a cut that separates by less than 5 points of J is not reported
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


VARIANT_NAMES = {
    'raw': "plain photograph (the panel's image)", RESAVE: 'plain photograph re-saved, JPEG 92 (no defect)', 'aug-ShadowCast': 'Augraphy shadow (defaults)',
    'aug-LightingGradient': 'Augraphy lighting gradient (defaults)', 'aug-ReflectedLight': 'Augraphy reflected light, glare (defaults)',
    'aug-LowLightNoise': 'Augraphy low light and noise (defaults)', 'motion-9': 'motion blur 9 px', 'motion-17': 'motion blur 17 px',
    'motion-31': 'motion blur 31 px', 'defocus-1.5': 'defocus, sigma 1.5 px', 'defocus-3': 'defocus, sigma 3 px',
    'defocus-5': 'defocus, sigma 5 px', 'tilt-5': 'tilted 5°', 'tilt-12': 'tilted 12°', 'tilt-20': 'tilted 20°',
    'jpeg-60': 'JPEG quality 60', 'jpeg-75': 'JPEG quality 75', 'jpeg-85': 'JPEG quality 85',
    'quad-tilt-12': "tilted 12°, then Apple's quad corrected", 'quad-tilt-20': "tilted 20°, then Apple's quad corrected"}
# The measured findings, written once the results were read (2026-11-03); a rerun that moves them must rewrite them.
PAGE_NOTE = ('Each of the 96 pages degraded by one synthetic defect at one setting and read again by the same reader, '
             'paired by page against that reader\'s plain image (Apple Vision against the plain image re-saved as '
             'every defect image was, because a re-save alone moves Vision 1.6 points). Glare, motion blur and heavy '
             'defocus cost every reader; tilt up to 20 degrees, JPEG down to quality 60 and Augraphy\'s shadow and '
             'lighting gradient at their defaults cost none of them more than about 2 points. Apple Vision breaks '
             'first: 9 px of motion costs it 6.6 points and 17 px 38, where Qwen3.6-27B loses 1.0 and 7.9. '
             'LightOnOCR-3 4B answers heavy blur with an empty reply (43 of 96 at 31 px). Correcting the tilt with '
             'Apple\'s quad recovers nothing for Vision, because tilt cost it little. A loop is a reading cut at the '
             'token cap or the 600 s limit; loops and blanks score 0. Synthetic defects, one at a time: real phone '
             'captures are not in this table. Detail: segbench-results/capture-ladder.md.')
SIGNALS_NOTE = ('Signals a phone can measure at capture, from the image alone, against a loss of 5 NES points or more '
                'on each of the 1,536 defect images (0.5 is no information). Sharpness inside the word boxes and the '
                'share of the image the word boxes cover separate losses only moderately (AUC 0.70 to 0.78), and their '
                'best cuts differ threefold between readers; the clipped-highlight share does not see the glare that '
                'costs 9 points (0.50 to 0.53), and lower luminance goes with fewer losses, not more. The cuts are '
                'in-sample on synthetic images; none is ready to be a live warning without a check on real captures.')
FINDINGS = """## Findings

- **Glare, motion blur and heavy defocus cost every reader; nothing else measured does.** Augraphy's reflected light
  costs Qwen3.6-27B 10.3 NES points, LightOnOCR-3 4B 9.3 and Apple Vision 8.7, on 39 to 46 of the 96 pages each.
  Tilt to 20 degrees, JPEG at quality 60, 75 or 85, and Augraphy's shadow and lighting gradient at their defaults
  cost none of the three more than 2 points (most intervals cross 0; ShadowCast's default shadow is faint).
- **Apple Vision's tolerance is far tighter than the open readers'.** Motion 9 px: Vision -6.6, LightOn -2.6, the 27B
  -1.0 (interval crosses 0). Motion 17 px: -38.3, -12.2, -7.9. Defocus sigma 3: -15.2, -2.7, -2.0. Defocus 5: -53.8,
  -15.3, -15.1. Motion 31 px wrecks all three (-73, -60, -38). The order-free bowF1 falls as far as NES, so these are
  lost words, not reordering. For Vision, handwriting falls least under blur in absolute terms (its handwriting
  baseline is lowest).
- **How each reader fails differs.** The 27B times out at 600 s (29 images, 18 of them motion 31, 6 defocus 5; a loop,
  scored 0); its answered pages stay high (71 at motion 31). LightOnOCR replies empty (66 images, 43 at motion 31)
  more often than it loops (16). Vision returns no text on 31 motion-31 and 17 defocus-5 images.
- **Low light and noise:** Vision -3.3 (-5.6 to -1.4), LightOn -1.3 and the 27B -0.1 (both intervals cross 0).
- **Tilt, and the dewarp check (measurement audit ENH-1):** tilt costs Vision 1.2 to 1.7 NES points, but its bowF1
  only 0.2 to 0.5, so most of that is line order. Apple's quad correction of the tilted image recovers nothing
  measurable (tilt 12: -0.7 against -1.2; tilt 20: -1.7 against -1.4; both intervals overlap). The open readers lose
  at most 0.6 on any tilt, so there is nothing for a dewarp arm to recover for them, and none was run.
- **Re-saving alone moves Vision.** The raw file read against the same image re-saved at JPEG 92 differs by 1.6 NES
  (bowF1 1.5, 0.6 to 2.4), 4.7 on the PDF images; Vision is deterministic, so this is its sensitivity to small pixel
  changes, and its defect rows are paired against the re-saved image for that reason. The Sherlock readers' JPEG 85
  rows are 0.3 and 0.1 from raw.
- **Capture-time signals are weak on their own.** Sharpness inside Vision's word boxes (Laplacian variance, Tenengrad)
  and the share of the image inside word boxes reach AUC 0.70 to 0.78 against a 5-point loss; the clipped-highlight
  share does not detect the glare defect (0.50 to 0.53) and luminance is inverted (glare brightens). The best cuts
  differ threefold between readers and are in-sample: a live blur warning could start from sharpness in word boxes,
  but its threshold needs real captures.

What this means for the companion's guidance: hold the phone still and avoid reflections; tilt and compression need
no warning for any reader, and the gateway or open readers forgive blur that Vision does not, so a blur warning
matters most where Vision reads on the device.
"""
REPORT_HEAD = """# W46.capture-ladder: what a capture defect costs each reader, on the owner's 96

Generated by `scripts/segbench/capture_ladder.py report`; the method is in its docstring. Page-level numbers:
`capture-ladder-pages.csv` (every reader, defect and page) and `capture-ladder-signals.csv` (every image's signals).

Each of the 96 scored pages (the panel's 99 less its three agreement letters) was degraded by one defect at one
setting, from the panel's own image (2,400 px on the long side for 95 of them), and read by Qwen3.6-27B and
LightOnOCR-3 4B on Sherlock (one L40S per job, temperature 0, the open sweep's prompts, 8,192 tokens, a 600 s limit
per request) and by Apple Vision on this Mac with the app's settings. Each reader's baseline is its own reading of the
plain image from the dewarp run (W46.enh-dewarp), same settings. A loop is a reading cut at the token cap or the time
limit; a blank is a reply with no text. Both score 0 (strict NES); NES answered leaves them out. bowF1 is the
bag-of-words F1 from the panel's word counts, so it ignores reading order. Δ is paired by page: mean, 95% bootstrap.

"""
CARD = """
## Measurement card

- **Truth:** the 96's adjudicated truth (`ocr_truth`), the same for every image of a page. The figure is a change
  within one reader against one fixed truth, so a drafter bias in the truth moves the plain and the defect image alike
  and largely cancels; it does not cancel in a comparison between readers, which this report does not rank on. The
  owner's blind check found the typed-page truth fit for ranking (measurement audit, 2026-10-30).
- **Selection:** all 96 scored pages, every defect; no page chosen by a reader's result or by ABBYY text. The optical
  capture tags are not used to slice (CAP-1, kappa 0.14-0.47 against a blind retag).
- **Comparison:** the same pages, prompts, decoding and server arguments as each reader's baseline. One difference:
  every defect image went through the ladder's own JPEG save (quality 92, or the JPEG row's quality) after the panel's
  JPEG 90, so a second encoding is inside every Δ; the JPEG 85 row bounds it. The baseline was read on 2026-10-22 in a
  separate job of the same container.
- **Noise:** n 96 per cell, paired intervals as above. No rerun floor has been measured for these two Sherlock readers
  (W46.ocr-rerun-noise measured Gemini 3.7 Flash, range 0.24 points, and Qwen3-VL 8B on MLX, 0). vLLM at temperature 0
  is not bit-deterministic with batching, so the JPEG 75 and 85 rows, near-invisible changes, are the practical floor
  here: a Δ inside them, or one whose interval crosses 0, is read as no effect. Apple Vision is deterministic.
- **Scope:** synthetic defects on the owner's pages, one defect at a time, at the library defaults for Augraphy's four
  (ShadowCast's default shadow is faint, so its row may understate a real shadow). Not settled here: combined defects,
  real phone captures (SmartDoc-QA), the public 895, GLM-OCR on regions, the 2B segmentation student, and the
  readers' own quality verdicts. Signal AUCs and cuts are in-sample on synthetic images: a cut for the companion app
  needs a held-out check on real captures before it ships.
"""


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
        b0 = BASE[reader]
        heads = ['raw'] + ([RESAVE] if b0 == RESAVE else [])
        L += [f'## {label}', '',
              '| defect | n | loops (cap / timeout) | blank | NES strict % | Δ NES strict (95% CI) | NES answered % | bowF1 % | '
              'Δ bowF1 (95% CI) | words missed % | words added % | pages losing ≥5 NES |',
              '|---|---:|---:|---:|---:|---|---:|---:|---|---:|---:|---:|']
        bb = [by[reader, b0, r['page']] for r in pages]
        for v in [*heads, *vs]:
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
            cell['baseline'] = v == b0
            summary.append(cell)
            raw = v == b0
            L.append(f"| {v} | {len(rr)} | {cell['loops']} | {cell['blank']} | {pct(cell['nes'])} | {'—' if raw else ci(dn)} | "
                     f"{pct(cell['nes_answered'])} | {pct(cell['bowf1'])} | {'—' if raw else ci(db)} | "
                     f"{pct(cell['missed'])} | {pct(cell['added'])} | {'—' if raw else cell['lost5']} |")
        L += ['', f'Δ NES strict by page group, paired against {label} on the {VARIANT_NAMES[b0]} (n in brackets):', '',
              '| defect | ' + ' | '.join(g for g, _ in groups) + ' |', '|---|' + '---|' * len(groups)]
        for v in vs:
            cells = []
            for _, f in groups:
                pp = [r['page'] for r in pages if f(r)]
                d = S.paired([by[reader, v, p]['nes'] for p in pp], [by[reader, b0, p]['nes'] for p in pp])
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
                    loss = by[reader, BASE[reader], r['page']]['nes'] - by[reader, v, r['page']]['nes'] >= LOSS
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
    page = {'report': 'capture-ladder.md', 'loss': LOSS, 'readers': READERS, 'variants': VARIANT_NAMES,
            'signal_names': {k: v[0] for k, v in SIGNALS.items()}, 'note': PAGE_NOTE, 'signals_note': SIGNALS_NOTE,
            'summary': summary, 'signals': sig_rows}
    (res / 'capture-ladder.json').write_text(json.dumps(page, indent=1) + '\n')
    (WORK / 'tables.md').write_text('\n'.join(L) + '\n')
    (res / 'capture-ladder.md').write_text(REPORT_HEAD + FINDINGS + '\n' + '\n'.join(L) + '\n' + CARD)
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
