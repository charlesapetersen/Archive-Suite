#!/usr/bin/env python3
"""W46.rotation-routes. Every rotation route on the same pages, each upright page turned 0/90/180/270 clockwise.

  python3 rotation_routes.py pages                    # the page list: the owner's 96 and 20 a stratum of six public ones
  heavy-run.py run -- python3 rotation_routes.py vision      # RotationDetector (local Vision) as shipped
  heavy-run.py run -- python3 rotation_routes.py tesseract   # Tesseract 5's OSD (--psm 0)
  heavy-run.py run -- <ppocr venv python> rotation_routes.py paddle       # PP-LCNet_x1_0_doc_ori through PaddleX
  python3 rotation_routes.py gateway [--orders 1|3] [--limit N]           # llmSingle / llmMajority, Gemini 3.7 Flash
  heavy-run.py run -- <lab venv python> rotation_routes.py mlx MODEL compare|single [--limit N]
  python3 rotation_routes.py report                   # segbench-results/rotation-routes.md + ArchiveOCRBench data

The pages: the 96 frozen owner originals (ocr-panel-cloud/images, read-only; scripts/test-rotation-axis.sh's set)
and 20 pages from each of six public strata local Vision is likely to miss (L1 English handwriting, L4 ledgers and
tables, L7 charters, N1 Arabic, N4 Hebrew, N5 Chinese print), drawn from the frozen 895 by a salted hash of the page
id, so no tested route chose them. Public images are the 895's own (W46.ocr-gemini37-895-paid: the 440 reference
images byte for byte, the rest made by its image_bytes).

A turn is the upright page rotated clockwise by 0/90/180/270; the right answer is the clockwise correction
(360 - turn) % 360, the app's convention. Each route gets the turned image and answers a correction or abstains:
  vision      the shipped detector (rotation_vision.swift compiled with RotationDetector.swift, as the axis test does)
  llm1/llm3   the app's LLMRotationDetector: four 800 px candidates of the turned page (JPEG 0.8), its prompt and
              labels, orderings 1 (llmSingle) or 1-3 (llmMajority, the most votes). Through the gateway, Gemini 3.7
              Flash, temperature 0, minimal reasoning. The app itself has no gateway rotation route (hasRoute) and
              asks gemini-2.5-flash-lite on a direct key; the gateway's model stands in, said so in the report.
  tesseract   `tesseract IMG stdout --psm 0`: the OSD's Rotate (degrees clockwise to upright; checked on turns)
  paddle      PP-LCNet_x1_0_doc_ori (PaddleX DocTextOrientation; label = degrees the page is turned clockwise)
  mlx         Qwen3-VL 8B 4-bit (the app's on-this-Mac OCR default) and Qwen3.5 2B 4-bit (the base of the shipped
              local segmenter) through mlx_vlm, with the app's comparative prompt (compare) and a one-image
              which-edge-is-the-top prompt (single). Seconds a call and peak memory recorded.

Gateway money: the ledger is CACHE/calls.jsonl, CAP bounds the item's total (the $7 rule; nothing else spent).
Images and replies stay in the cache (the owner's material). The key is read by gateway_gemini.api_key().
"""
from __future__ import annotations

import argparse
import base64
import collections
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]

REHEARSAL = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
CACHE = REHEARSAL / 'rotation-routes'
OWNER96 = REHEARSAL / 'ocr-panel-cloud/images'
ANSWERS = CACHE / 'answers'
PUBLIC_STRATA = ('L1', 'L4', 'L7', 'N1', 'N4', 'N5')
PER_STRATUM = 20
SALT = 'W46.rotation-routes'
TURNS = (0, 90, 180, 270)
RESULTS = HERE.parents[1] / 'segbench-results'
BENCH = HERE.parents[2] / 'ArchiveOCRBench'
PROCESSOR = HERE.parents[1]
CAP = 6.50            # the item's gateway total in dollars, under the $7 rule
MODEL = 'gemini-3.7-flash'

# LLMRotationDetector.swift, verbatim: the prompt, the label orderings and the candidate size.
PROMPT = ("You are shown the SAME scanned document in four different rotations, labeled A, B, C, D. "
          "Exactly one of them is correctly upright: text horizontal, reading left-to-right, not upside "
          "down or sideways. Reply with EXACTLY one letter — A, B, C, or D — for the upright one. Nothing else.")
ORDERINGS = ([0, 90, 180, 270], [90, 270, 0, 180], [180, 0, 270, 90])
CANDIDATE_PX = 800
LABELS = 'ABCD'
# The one-image prompt for the local models: which edge is the top; each letter maps to a clockwise correction.
SINGLE_PROMPT = ("This is a photograph or scan of a document page. Where is the TOP of the page (the edge the "
                 "text starts from when read normally)? Reply with exactly one letter: A if the top is at the top "
                 "(the page is upright), B if the top is on the right side, C if the top is at the bottom (upside "
                 "down), D if the top is on the left side. Nothing else.")
SINGLE_MAP = {'A': 0, 'B': 270, 'C': 180, 'D': 90}

MLX_MODELS = {   # model_store's shared cache, pinned revisions
    'qwen3vl-8b': ('mlx-community/Qwen3-VL-8B-Instruct-4bit', 'defcdea7cc7a4b0858fea563cbbce171d328e457'),
    'qwen35-2b': ('mlx-community/Qwen3.5-2B-4bit', '674aaa7240b91e8012fcad5d791b7dfe5ba90207'),
}


def local_sample(ps):
    """The local models' pages: 24 of the 96 and 4 of each public stratum's 20, by the salted hash (the public
    strata are already in hash order). Sized to what an 8B model at about 8 s a comparative call can read in one
    session; 192 turns give a 95% interval of about +-7 points."""
    own = sorted((p for p in ps if p['set'] == 'owner96'),
                 key=lambda p: hashlib.sha256((SALT + p['id']).encode()).hexdigest())[:24]
    pub = [p for s in PUBLIC_STRATA for p in [q for q in ps if q['stratum'] == s][:4]]
    return own + pub


def want(turn):
    return (360 - turn) % 360


# ---------------------------------------------------------------------------------------------------- pages

def page_list():
    return [json.loads(x) for x in (CACHE / 'pages.jsonl').read_text().splitlines()]


def pages():
    rows = []
    for p in sorted(OWNER96.glob('*-original.jpg')):
        if p.name.split('-')[0] in ('p086', 'p094', 'p096'):
            continue                      # the three the axis test leaves out (the 96 are 99 files)
        rows.append({'id': p.stem, 'set': 'owner96', 'stratum': 'owner96', 'path': str(p),
                     'sha256': hashlib.sha256(p.read_bytes()).hexdigest()})
    if len(rows) != 96:
        raise SystemExit(f'expected the 96 owner originals, found {len(rows)}')
    import ocr_gemini37_public as GP
    GP.configure()
    R = GP.R
    ref = {j['id']: j for j in json.loads((GP.REF / 'manifest.json').read_text())['jobs']}
    by = collections.defaultdict(list)
    for r in R.frozen():
        if r['stratum'] in PUBLIC_STRATA:
            by[r['stratum']].append(r)
    for s in PUBLIC_STRATA:
        pick = sorted(by[s], key=lambda r: hashlib.sha256((SALT + R.job_id(r)).encode()).hexdigest())[:PER_STRATUM]
        for r in pick:
            jid = R.job_id(r)
            if jid in ref:
                src = GP.REF / 'images' / (jid + '.jpg')
                b = src.read_bytes()
                if GP.P.digest(b) != ref[jid]['sha256']:
                    raise SystemExit('a reference image changed: ' + jid)
                path = src
            else:
                b = GP.image_bytes(r)
                path = CACHE / 'images' / (jid + '.jpg')
                path.parent.mkdir(parents=True, exist_ok=True)
                if not path.exists():
                    path.write_bytes(b)
            rows.append({'id': jid, 'set': 'public', 'stratum': s, 'script': r.get('script'), 'path': str(path),
                         'sha256': hashlib.sha256(b).hexdigest()})
    CACHE.mkdir(parents=True, exist_ok=True)
    (CACHE / 'pages.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
    print(len(rows), dict(collections.Counter(r['stratum'] for r in rows)))


def turned(path, turn):
    """The upright page turned `turn` degrees clockwise, as a PIL image (exact, no resampling)."""
    from PIL import Image
    im = Image.open(path).convert('RGB')
    t = {0: None, 90: Image.Transpose.ROTATE_270, 180: Image.Transpose.ROTATE_180, 270: Image.Transpose.ROTATE_90}[turn]
    return im.transpose(t) if t else im


def jpeg(im, quality):
    out = io.BytesIO()
    im.save(out, 'JPEG', quality=quality)
    return out.getvalue()


def candidates(path, turn):
    """LLMRotationDetector.renderCandidates: the turned page downscaled to 800 px, then turned by each correction."""
    from PIL import Image
    im = turned(path, turn)
    im.thumbnail((CANDIDATE_PX, CANDIDATE_PX), Image.Resampling.LANCZOS)
    rot = {0: None, 90: Image.Transpose.ROTATE_270, 180: Image.Transpose.ROTATE_180, 270: Image.Transpose.ROTATE_90}
    return {c: jpeg(im.transpose(rot[c]) if rot[c] else im, 80) for c in TURNS}


def done(name):
    f = ANSWERS / (name + '.jsonl')
    if not f.exists():
        return {}
    out = {}
    for x in f.read_text().splitlines():
        r = json.loads(x)
        out[(r['id'], r['turn'])] = r
    return out


def append(name, rec):
    ANSWERS.mkdir(parents=True, exist_ok=True)
    with (ANSWERS / (name + '.jsonl')).open('a') as f:
        f.write(json.dumps(rec) + '\n')


# ---------------------------------------------------------------------------------------------------- vision

def vision():
    src = PROCESSOR / 'macOS/Sources/ArchiveProcessor/OCR'
    have = done('vision')
    todo = [p for p in page_list() if not all((p['id'], t) in have for t in TURNS)]
    if not todo:
        return print('vision: all answered')
    with tempfile.TemporaryDirectory() as w:
        exe = Path(w) / 'rotation-vision'
        subprocess.run(['swiftc', '-parse-as-library', '-O', str(src / 'VisionQueue.swift'),
                        str(src / 'RotationDetector.swift'), str(HERE / 'rotation_vision.swift'), '-o', str(exe)],
                       check=True)
        lst = Path(w) / 'list.tsv'
        lst.write_text(''.join(f"{p['id']}\t{p['path']}\n" for p in todo))
        proc = subprocess.Popen([str(exe), str(lst)], stdout=subprocess.PIPE, text=True)
        for line in proc.stdout:
            r = json.loads(line)
            if 'error' in r:
                raise SystemExit('vision could not decode ' + r['id'])
            append('vision', r)
        if proc.wait() != 0:
            raise SystemExit('rotation-vision failed')
    print('vision: done')


# ---------------------------------------------------------------------------------------------------- tesseract

def tesseract_version():
    return subprocess.run(['tesseract', '--version'], capture_output=True, text=True).stdout.split('\n')[0]


def tesseract():
    have = done('tesseract')
    with tempfile.TemporaryDirectory() as w:
        for p in page_list():
            for t in TURNS:
                if (p['id'], t) in have:
                    continue
                f = Path(w) / 'turn.png'
                turned(p['path'], t).save(f)
                t0 = time.time()
                r = subprocess.run(['tesseract', str(f), 'stdout', '--psm', '0'], capture_output=True, text=True)
                s = time.time() - t0
                m = re.search(r'Rotate: (\d+)', r.stdout)
                conf = re.search(r'Orientation confidence: ([\d.]+)', r.stdout)
                script = re.search(r'Script: (\S+)', r.stdout)
                append('tesseract', {'id': p['id'], 'turn': t, 'found': int(m.group(1)) % 360 if m else None,
                                     'conf': float(conf.group(1)) if conf else None,
                                     'script': script.group(1) if script else None, 'seconds': round(s, 3),
                                     'err': None if m else (r.stderr.strip().splitlines() or [''])[-1][:120]})
    print('tesseract: done,', tesseract_version())


# ---------------------------------------------------------------------------------------------------- paddle

def paddle():
    from paddlex import create_model
    model = create_model('PP-LCNet_x1_0_doc_ori')
    have = done('paddle')
    with tempfile.TemporaryDirectory() as w:
        for p in page_list():
            for t in TURNS:
                if (p['id'], t) in have:
                    continue
                f = Path(w) / 'turn.jpg'
                turned(p['path'], t).save(f, quality=95)
                t0 = time.time()
                res = list(model.predict(str(f), batch_size=1))[0]
                s = time.time() - t0
                label = str(res['label_names'][0])
                score = float(res['scores'][0])
                # The label is how far the page is turned clockwise (measured on p001 at all four turns, 0.92 each),
                # so the correction is its complement.
                append('paddle', {'id': p['id'], 'turn': t, 'label': label, 'score': round(score, 4),
                                  'found': (360 - int(label)) % 360, 'seconds': round(s, 3)})
    print('paddle: done')


# ---------------------------------------------------------------------------------------------------- gateway

def gw():
    import gateway_gemini as G
    G.CACHE = CACHE
    G.CAP = CAP
    return G


def ask_gateway(p, turn, order_i, cands):
    G = gw()
    order = ORDERINGS[order_i]
    content = [{'type': 'text', 'text': PROMPT}]
    for i, c in enumerate(order):
        content.append({'type': 'text', 'text': f'\nImage {LABELS[i]}:'})
        content.append({'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,' + base64.b64encode(cands[c]).decode()}})
    body = {'model': MODEL, 'temperature': 0, 'reasoning_effort': 'minimal', 'max_tokens': 2048,
            'messages': [{'role': 'user', 'content': content}]}
    if G.spent() + 0.02 > CAP:
        raise SystemExit(f'cap: ${G.spent():.4f} spent of ${CAP}')
    t = time.time()
    for attempt in range(4):
        r = G.request('/chat/completions', body, timeout=120)
        if r.status_code in (429, 500, 502, 503, 504) and attempt < 3:
            time.sleep(10 * (attempt + 1)); continue
        break
    got = r.json() if r.headers.get('content-type', '').startswith('application/json') else {'raw': r.text[:500]}
    usage = got.get('usage') or {}
    rec = {'set': 'rotation', 'job': f"{p['id']}|{turn}|{order_i}", 'http': r.status_code, 't': t,
           'wall_s': round(time.time() - t, 3), 'model': got.get('model'), 'usage': usage,
           'cost': round(G.cost(usage), 6)}
    rec = G.with_gateway_cost(rec, r)
    with (CACHE / 'calls.jsonl').open('a') as f:
        f.write(json.dumps(rec) + '\n')
    if r.status_code != 200:
        print(p['id'], turn, order_i, r.status_code, json.dumps(got)[:300])
        return None
    text = ((got.get('choices') or [{}])[0].get('message') or {}).get('content') or ''
    text = text.strip()
    # The app's parse: the reply's first character, upper-cased, must be a label.
    found = order[LABELS.index(text[0].upper())] if text and text[0].upper() in LABELS else None
    return {'id': p['id'], 'turn': turn, 'order': order_i, 'reply': text[:40], 'found': found,
            'seconds': rec['wall_s'], 'cost': G.charge(rec), 'usage': usage}


def gateway(orders, limit, concurrency=4):
    CACHE.mkdir(parents=True, exist_ok=True)
    have = {}
    for i in range(3):
        for k, v in done(f'gw-order{i}').items():
            have[(k[0], k[1], i)] = v
    ps = page_list()
    if limit:
        # a pilot: the first `limit` pages of each set, so both sets are priced
        ps = [p for p in ps if p['set'] == 'owner96'][:limit] + [p for p in ps if p['set'] == 'public'][::20][:limit]
    jobs = [(p, t, i) for p in ps for t in TURNS for i in range(orders) if (p['id'], t, i) not in have]

    def one(j):
        p, t, i = j
        return i, ask_gateway(p, t, i, candidates(p['path'], t))
    with ThreadPoolExecutor(concurrency) as ex:
        for i, rec in ex.map(one, jobs):
            if rec:
                append(f'gw-order{i}', rec)
    G = gw()
    print(f'gateway: {len(jobs)} calls asked; ${G.spent():.4f} spent in all; {G.billed_note(G.ledger())}')


# ---------------------------------------------------------------------------------------------------- mlx

def mlx(name, mode, limit, sample=True):
    import model_store
    model_store.use()
    import mlx.core as mx
    from mlx_vlm import generate, load
    from mlx_vlm.prompt_utils import apply_chat_template
    path = model_store.snapshot(*MLX_MODELS[name])
    model, processor = load(str(path))
    config = model.config
    out = f'mlx-{name}-{mode}'
    have = done(out)
    ps = page_list()
    if limit:
        ps = [p for p in ps if p['set'] == 'owner96'][:limit] + [p for p in ps if p['set'] == 'public'][::20][:limit]
    elif sample:
        ps = local_sample(ps)
    with tempfile.TemporaryDirectory() as w:
        for p in ps:
            for t in TURNS:
                if (p['id'], t) in have:
                    continue
                if mode == 'compare':
                    cands = candidates(p['path'], t)
                    order = ORDERINGS[0]
                    imgs = []
                    for i, c in enumerate(order):
                        f = Path(w) / f'{LABELS[i]}.jpg'
                        f.write_bytes(cands[c]); imgs.append(str(f))
                    # The app's message: the prompt, then "\nImage A:" before each image (LLMRotationDetector.ask).
                    content = [{'type': 'text', 'text': PROMPT}]
                    for i in range(4):
                        content += [{'type': 'text', 'text': f'\nImage {LABELS[i]}:'}, {'type': 'image'}]
                    prompt = processor.apply_chat_template([{'role': 'user', 'content': content}], tokenize=False,
                                                           add_generation_prompt=True, enable_thinking=False)
                else:
                    from PIL import Image
                    im = turned(p['path'], t)
                    im.thumbnail((CANDIDATE_PX, CANDIDATE_PX), Image.Resampling.LANCZOS)
                    f = Path(w) / 'page.jpg'
                    im.save(f, quality=80); imgs = [str(f)]
                    prompt = apply_chat_template(processor, config, SINGLE_PROMPT, num_images=1, enable_thinking=False)
                mx.reset_peak_memory()
                t0 = time.time()
                res = generate(model, processor, prompt, image=imgs, max_tokens=8, temperature=0.0, verbose=False)
                s = time.time() - t0
                reply = (res.text if hasattr(res, 'text') else str(res)).strip()
                reply = re.sub(r'<think>.*?</think>', '', reply, flags=re.S).strip()
                ch = reply[:1].upper()
                if mode == 'compare':
                    found = ORDERINGS[0][LABELS.index(ch)] if ch in LABELS else None
                else:
                    found = SINGLE_MAP.get(ch)
                append(out, {'id': p['id'], 'turn': t, 'reply': reply[:40], 'found': found, 'seconds': round(s, 3),
                             'peak_gb': round(mx.get_peak_memory() / 1e9, 2)})
    print(out, 'done')


# ---------------------------------------------------------------------------------------------------- main

def main():
    a = argparse.ArgumentParser()
    a.add_argument('cmd')
    a.add_argument('args', nargs='*')
    a.add_argument('--orders', type=int, default=3)
    a.add_argument('--limit', type=int, default=0)
    a.add_argument('--all', action='store_true', help='mlx: every page, not the local sample')
    o = a.parse_args()
    if o.cmd == 'pages':
        pages()
    elif o.cmd == 'vision':
        vision()
    elif o.cmd == 'tesseract':
        tesseract()
    elif o.cmd == 'paddle':
        paddle()
    elif o.cmd == 'gateway':
        gateway(o.orders, o.limit)
    elif o.cmd == 'mlx':
        mlx(o.args[0], o.args[1], o.limit, sample=not o.all)
    elif o.cmd == 'report':
        import rotation_report
        rotation_report.report()
    else:
        raise SystemExit('unknown command ' + o.cmd)


if __name__ == '__main__':
    main()
