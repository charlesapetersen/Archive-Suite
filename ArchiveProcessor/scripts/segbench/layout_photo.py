#!/usr/bin/env python3
"""W46.layout-photo — whether DocLayout-YOLO collapses on our photographs (the Mac half).

    <lab venv>/bin/python layout_photo.py pages                       # WORK/pages.jsonl
    <lab venv>/bin/python layout_photo.py detect --detector yolo|pp   # WORK/regions/<detector>.json
    $(torch-env.sh)        layout_photo.py detect --detector heron
    <lab venv>/bin/python layout_photo.py detect --detector vision    # the Swift helper (layout_photo_vision.swift)
    <lab venv>/bin/python layout_photo.py hands                       # segbench-results/layout-photo-hands.{json,md}
    <lab venv>/bin/python layout_photo.py pack --out DIR              # the Sherlock pack (GLM-OCR on the new arms)

Four detectors, each as the app or its maker would run it:
  yolo    DocLayout-YOLO DocStructBench (the ONNX export of the weights the app ships as Core ML), imgsz 1024,
          conf 0.25, ordered by the app's region sort (`layout_order.order_app_regions`, Recogniser.swift
          `LayoutModel.crops`). W46.ocr-regions read YOLO through newspaper-ocr's own layout processing and order;
          this arm is the app's setup instead.
  pp      PP-DocLayoutV3 (the mlx-vlm port, conf 0.5, 1,024 px), its own reading order, as W46.ocr-regions ran it.
  heron   docling-layout-heron (RT-DETRv2, Apache-2.0), 640 x 640 as docling runs it, conf 0.3, the app's region sort.
  vision  Apple Vision's RecognizeDocumentsRequest (macOS 26): title, paragraphs, tables and lists, its own order.

Pages: the 96 (the panel's frozen originals, the three agreement-only letters kept and marked at scoring), L9,
L4, L1 and L2 of the 895 (the frozen originals). Boxes are page fractions keyed by the cluster's page id, so the
cluster cuts the same boxes from the 2,400 px copy each route read whole (W46.ocr-regions' convention). Detectors
see the frozen originals at their own input sizes. Regions and labels only: no text or pixels leave the Mac here.

`hands` answers the handwriting arm without a reader: on L1, L2 and the 96's handwritten pages, how many pages
each detector leaves with no region a reader would read, the share of the page's ink inside the regions it
would read, and the ink it labels picture (which the region step drops). Ink is a pixel darker than 128 on the
page at 1,000 px, less a 2% margin (scanner borders and box edges); it is a proxy for text, stated as such.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import layout_order as LO           # noqa: E402  (stdlib only)
import regions_cluster as C         # noqa: E402  (stdlib only at import)

CACHE = Path(os.environ.get('ARCHIVE_BENCH_CACHE', Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'))
WORK = CACHE / 'layout-photo'
RESULTS = HERE.parent.parent / 'segbench-results'
LAB = Path.home() / '.local/share/visionocr-ocrlab'
HUB = LAB / 'hf/hub'
VISION_BIN = WORK / 'bin/layout-photo-vision'
STRATA = ('L9', 'L4', 'L1', 'L2')
GLM_SETS = ('L9', 'L4', 'owner99')        # where GLM-OCR reads each arm (the item's "the 96, L9 and L4")
PACK_ARMS = {'yolo': 'yolo_appsort', 'heron': 'heron', 'vision': 'vision_doc'}   # pp's GLM reading already exists
DETECTORS = {
    'yolo': 'DocLayout-YOLO DocStructBench ONNX, imgsz 1024, conf 0.25, app region sort',
    'pp': 'PP-DocLayoutV3 (mlx-vlm port), conf 0.5, 1024 px, model reading order',
    'heron': 'docling-layout-heron (RT-DETRv2), 640 x 640, conf 0.3, app region sort',
    'vision': 'Apple Vision RecognizeDocumentsRequest (macOS 26): title, paragraphs, tables, lists; its order',
}


def snapshot(repo: str) -> Path:
    snaps = sorted((HUB / f'models--{repo.replace("/", "--")}' / 'snapshots').iterdir())
    assert len(snaps) == 1, snaps
    return snaps[0]


# ---------------------------------------------------------------- pages

def cmd_pages(a):
    import regions as G
    import routes as R
    import ocr_panel as P
    R.MANIFEST = G.MANIFEST
    rows = []
    for r in R.frozen():
        if r['stratum'] in STRATA:
            rows.append({'id': R.job_id(r), 'set': 'public895', 'stratum': r['stratum'], 'groups': [r['stratum']],
                         'image': r['image'], 'image_sha256': r['image_sha256']})
    panel = {r['page']: r for r in P.rows()}
    for pid, set_, _s, path in G.mac_pages():
        if set_ == 'owner99':
            groups = ['agreement-only'] if pid in P.AGREEMENT else ['the 96', *G.kinds_of(panel[pid])]
            rows.append({'id': pid, 'set': set_, 'stratum': None, 'groups': groups, 'image': str(path)})
    assert len({r['id'] for r in rows}) == len(rows)
    WORK.mkdir(parents=True, exist_ok=True)
    (WORK / 'pages.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
    print(len(rows), 'pages ->', WORK / 'pages.jsonl')


def load_pages() -> list[dict]:
    return [json.loads(x) for x in (WORK / 'pages.jsonl').read_text().splitlines() if x.strip()]


# ---------------------------------------------------------------- detectors: each returns (w, h, regions)
# A region is {label, order, score, box: [x0, y0, x1, y1] page fractions}, in reading order.

def _app_sorted(rows: list[list], w: int, h: int) -> list[dict]:
    """rows: [label, score, x0, y0, x1, y1] in pixels -> regions in the app's region order."""
    boxes = [r[2:] for r in rows]
    out = []
    for k, i in enumerate(LO.order_app_regions(boxes), 1):
        lab, score, x0, y0, x1, y1 = rows[i]
        box = [max(0.0, x0 / w), max(0.0, y0 / h), min(1.0, x1 / w), min(1.0, y1 / h)]
        out.append({'label': lab, 'order': k, 'score': round(float(score), 3), 'box': [round(v, 5) for v in box]})
    return out


class Yolo:
    def __init__(self):
        import ast
        import onnx
        import onnxruntime as ort
        w = snapshot('wybxc/DocLayout-YOLO-DocStructBench-onnx') / 'doclayout_yolo_docstructbench_imgsz1024.onnx'
        m = onnx.load(str(w))
        self.names = ast.literal_eval({p.key: p.value for p in m.metadata_props}['names'])
        self.sess = ort.InferenceSession(m.SerializeToString(), providers=['CPUExecutionProvider'])

    def __call__(self, img, imgsz=1024, conf=0.25):
        # The lab's layout-regions.py run_yolo, with the session held: letterbox to 1024, end-to-end boxes.
        import cv2
        import numpy as np
        a = cv2.cvtColor(np.array(img.convert('RGB')), cv2.COLOR_RGB2BGR)
        h, w = a.shape[:2]
        r = min(imgsz / h, imgsz / w)
        rh, rw = int(round(h * r)), int(round(w * r))
        a = cv2.resize(a, (rw, rh), interpolation=cv2.INTER_AREA)
        ph, pw = (imgsz - rh) % 32, (imgsz - rw) % 32
        a = cv2.copyMakeBorder(a, ph // 2, ph - ph // 2, pw // 2, pw - pw // 2, cv2.BORDER_CONSTANT,
                               value=(114, 114, 114))
        x = np.transpose(a, (2, 0, 1))[None].astype(np.float32) / 255.0
        preds = self.sess.run(None, {'images': x})[0][0]
        rows = [[self.names[int(p[5])], float(p[4]), *(float(v) for v in ((p[0] - pw // 2) / r, (p[1] - ph // 2) / r,
                 (p[2] - pw // 2) / r, (p[3] - ph // 2) / r))] for p in preds[preds[:, 4] > conf]]
        return w, h, _app_sorted(rows, w, h)


class PP:
    def __init__(self):
        import layout
        self.model = layout.load_model()

    def __call__(self, img):
        import regions as G
        w, h = img.size                       # before draft, which shrinks the decode
        img.draft('RGB', (1024, 1024))        # as layout.py and regions.py prepare decode it (img is unloaded)
        return w, h, G.boxes_pp(self.model.detect(img.convert('RGB')))


class Heron:
    def __init__(self):
        import torch
        from transformers import RTDetrImageProcessor, RTDetrV2ForObjectDetection
        self.torch = torch
        self.dev = 'mps' if torch.backends.mps.is_available() else 'cpu'
        w = snapshot('ds4sd/docling-layout-heron')
        self.proc = RTDetrImageProcessor.from_pretrained(str(w))
        self.model = RTDetrV2ForObjectDetection.from_pretrained(str(w)).eval().to(self.dev)

    def __call__(self, img, imgsz=640, conf=0.3):
        t = self.torch
        im = img.convert('RGB'); w, h = im.size
        x = self.proc(images=[im], size={'height': imgsz, 'width': imgsz}, return_tensors='pt').to(self.dev)
        with t.no_grad():
            res = self.model(**x)
        found = self.proc.post_process_object_detection(res, threshold=conf, target_sizes=t.tensor([[h, w]]))[0]
        names = self.model.config.id2label
        rows = [[names[l].lower(), s] + [float(v) for v in b]
                for s, l, b in zip(found['scores'].tolist(), found['labels'].tolist(), found['boxes'].tolist())]
        return w, h, _app_sorted(rows, w, h)


def detect_vision(todo: list[dict], store: dict, dest: Path):
    if not VISION_BIN.exists():
        VISION_BIN.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['swiftc', '-O', str(HERE / 'layout_photo_vision.swift'), '-o', str(VISION_BIN)], check=True)
    lst = WORK / 'vision-todo.tsv'
    lst.write_text(''.join(f'{p["id"]}\t{p["image"]}\n' for p in todo))
    got = WORK / 'vision-out.jsonl'
    rc = subprocess.run([str(VISION_BIN), str(lst), str(got)]).returncode
    for x in got.read_text().splitlines():
        j = json.loads(x)
        store['pages'][j['id']] = {'w': j['w'], 'h': j['h'], 'seconds': round(j['seconds'], 3), 'regions': j['regions']}
    save(dest, store)
    lst.unlink(); got.unlink()
    if rc:
        raise SystemExit(f'vision helper exit {rc}')


def save(dest: Path, store: dict):
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix('.part'); tmp.write_text(json.dumps(store)); tmp.replace(dest)


def regions_path(det: str, pageset: str = 'bench') -> Path:
    return WORK / 'regions' / (f'{det}.json' if pageset == 'bench' else f'{pageset}-{det}.json')


def run_detector(det: str, pages: list[dict], dest: Path):
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    store = json.loads(dest.read_text()) if dest.exists() else {'detector': DETECTORS[det], 'pages': {}}
    if store['detector'] != DETECTORS[det]:
        raise SystemExit(f'{dest} was made by {store["detector"]!r}; move it aside to rerun')
    todo = [p for p in pages if p['id'] not in store['pages']]
    if det == 'vision':
        return detect_vision(todo, store, dest) if todo else None
    model = {'yolo': Yolo, 'pp': PP, 'heron': Heron}[det]() if todo else None
    t0 = time.time()
    for n, p in enumerate(todo, 1):
        img = Image.open(p['image'])
        t = time.time()
        w, h, regs = model(img)
        store['pages'][p['id']] = {'w': w, 'h': h, 'seconds': round(time.time() - t, 3), 'regions': regs}
        if n % 25 == 0 or n == len(todo):
            save(dest, store)
            print(f'{det}: {n}/{len(todo)} pages, {(time.time() - t0) / n:.2f} s a page', flush=True)


def cmd_detect(a):
    if a.pageset == 'bench':
        return run_detector(a.detector, load_pages(), regions_path(a.detector))
    pages = real5_pages()
    if a.detector in REAL5_PREP_DETECTORS:
        pages = [p for p in pages if p['cond'] in REAL5_COND or p['cond'] in REAL5_PREPPED]
    else:
        pages = [p for p in pages if p['cond'] in REAL5_COND]
    run_detector(a.detector, pages, regions_path(a.detector, 'real5'))


# ---------------------------------------------------------------- Real5-OmniDocBench (photographed modern print)
# Every English page of OmniDocBench v1.5 that src_omnidoc's rule keeps (no table, displayed equation, mask or
# inline LaTeX, so the truth is plain text): 155 of the 628 English pages, all of them rather than a sample. The
# same page in four of Real5's folders: Scanning (the baseline each drop is measured from), Illumination, Warping
# and Skew; Screen-Photography is not a condition a box photograph has. On Warping and Skew, also our staged
# pre-step: Apple's document quad with a perspective correction, and UVDoc after the quad (W46.enh-dewarp's arms,
# its code and weights). Every image is frozen as the panel freezes pages (2,400 px ceiling, JPEG 90), and that
# copy is what the detectors see on the Mac and what the cluster crops.

REAL5 = WORK / 'real5'
REAL5_REPO = 'PaddlePaddle/Real5-OmniDocBench'
REAL5_COND = {'scan': 'Real5-OmniDocBench-Scanning', 'illum': 'Real5-OmniDocBench-Illumination',
              'warp': 'Real5-OmniDocBench-Warping', 'skew': 'Real5-OmniDocBench-Skew'}
REAL5_PREPPED = ('warp-quad', 'warp-uvdoc', 'skew-quad', 'skew-uvdoc')
REAL5_PREP_DETECTORS = ('yolo', 'pp')        # the staged route's detector: the shipped one and the best other
DEWARP = CACHE / 'enh-dewarp'                # W46.enh-dewarp's venv, UVDoc clone and quad helper, used read-only
DEWARP_BIN = CACHE / 'segbench/bin/segbench-dewarp'
SIDE = 2400


def omnidoc_pages() -> list[dict]:
    return json.loads((REAL5 / 'omnidocbench-v1_5/OmniDocBench.json').read_text())


def real5_pages() -> list[dict]:
    return [json.loads(x) for x in (REAL5 / 'pages.jsonl').read_text().splitlines() if x.strip()]


def freeze(img, dest: Path) -> str:
    """The panel's freezing (ocr_panel._prepare, enh_dewarp.freeze): RGB, 2400 px ceiling, LANCZOS, JPEG 90."""
    import hashlib
    from PIL import Image
    im = img.convert('RGB')
    im.thumbnail((SIDE, SIDE), Image.Resampling.LANCZOS)
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix('.tmp')
    im.save(tmp, 'JPEG', quality=90)
    tmp.replace(dest)
    return hashlib.sha256(dest.read_bytes()).hexdigest()


def cmd_real5_fetch(a):
    """Download the four folders' copies of the kept pages (Hugging Face, Apache-2.0 images), freeze them, and
    write each page's truth text. The originals are deleted once frozen; only the frozen copies are kept."""
    import shutil
    import src_omnidoc as O
    from huggingface_hub import HfApi, hf_hub_download
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    kept = [p for p in omnidoc_pages() if p['page_info']['page_attribute']['language'] == 'english' and O.truth(p)]
    files = set(HfApi().list_repo_files(REAL5_REPO, repo_type='dataset'))
    import concurrent.futures as cf
    rows, raw = [], REAL5 / 'download'
    for p in sorted(kept, key=lambda p: p['page_info']['image_path']):
        stem = p['page_info']['image_path'].rsplit('.', 1)[0]
        truth = REAL5 / 'truth' / f'{stem}.txt'
        truth.parent.mkdir(parents=True, exist_ok=True)
        truth.write_text(O.truth(p))
        for cond, folder in REAL5_COND.items():
            dest = REAL5 / 'images' / cond / f'{stem}.jpg'
            name = next(f for f in (f'{folder}/{stem}.jpg', f'{folder}/{stem}.png') if f in files)
            rows.append({'id': f'real5__{cond}__{stem}', 'set': 'real5', 'cond': cond, 'stem': stem,
                         'source_file': name, 'data_source': p['page_info']['page_attribute']['data_source'],
                         'image': str(dest)})

    def one(r):
        dest = Path(r['image'])
        if not dest.exists():
            got = Path(hf_hub_download(REAL5_REPO, r['source_file'], repo_type='dataset', local_dir=raw))
            with Image.open(got) as im:
                freeze(im, dest)
            got.unlink()
        return r['id']
    with cf.ThreadPoolExecutor(8) as ex:
        for n, _ in enumerate(ex.map(one, rows), 1):
            if n % 40 == 0 or n == len(rows):
                print(f'fetched {n}/{len(rows)}', flush=True)
    shutil.rmtree(raw, ignore_errors=True)
    (REAL5 / 'pages.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
    print(len(kept), 'pages,', len(rows), 'images ->', REAL5 / 'pages.jsonl')


def cmd_real5_prep(a):
    """Run under W46.enh-dewarp's venv (torch, OpenCV): the quad and UVDoc-after-quad arms on the Warping and
    Skew copies, frozen beside them; the lattices are not kept (no text layer is carried here)."""
    import numpy as np
    from PIL import Image
    sys.path.insert(0, str(HERE))
    import dewarp_arms as A
    base = [p for p in real5_pages() if p['cond'] in ('warp', 'skew')]
    jobs = REAL5 / 'quad-jobs.tsv'
    todo = [p for p in base if not (REAL5 / 'quad' / p['cond'] / f'{p["stem"]}.json').exists()]
    if todo:
        for p in todo:
            (REAL5 / 'quad' / p['cond']).mkdir(parents=True, exist_ok=True)
        jobs.write_text(''.join(f'{p["image"]}\t{REAL5 / "quad" / p["cond"] / (p["stem"] + ".json")}\n' for p in todo))
        subprocess.run([str(DEWARP_BIN), 'quad', str(jobs)], check=True)
        jobs.unlink()
    rows = [p for p in real5_pages() if p['cond'] in REAL5_COND]
    for n, p in enumerate(base, 1):
        quad = json.loads((REAL5 / 'quad' / p['cond'] / f'{p["stem"]}.json').read_text())
        with Image.open(p['image']) as im:
            img = np.asarray(im.convert('RGB'))
        for arm in ('quad', 'uvdoc'):
            cond = f'{p["cond"]}-{arm}'
            dest = REAL5 / 'images' / cond / f'{p["stem"]}.jpg'
            found = quad.get('found', False)
            if not dest.exists():
                out, _grid, found = (A.quad_arm(img, quad) if arm == 'quad' else A.uvdoc_after_quad(img, quad, DEWARP / 'src'))
                freeze(Image.fromarray(out), dest)
            rows.append({**p, 'id': f'real5__{cond}__{p["stem"]}', 'cond': cond, 'image': str(dest), 'quad_found': bool(found)})
        if n % 25 == 0 or n == len(base):
            print(f'prep {n}/{len(base)}', flush=True)
    (REAL5 / 'pages.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
    print(len(rows), 'images ->', REAL5 / 'pages.jsonl')


# ---------------------------------------------------------------- the handwriting arm

INK_LEVEL, INK_SIDE, MARGIN = 128, 1000, 0.02
HANDS = ('L1', 'L2', 'handwritten')
CONTEXT = ('L9', 'L4', 'the 96')


def read_regions(det: str) -> dict:
    return json.loads(regions_path(det).read_text())['pages']


def page_measures(img_path: str, regs: list[dict]) -> dict:
    import numpy as np
    from PIL import Image
    im = Image.open(img_path); im.draft('L', (INK_SIDE, INK_SIDE))
    im = im.convert('L'); im.thumbnail((INK_SIDE, INK_SIDE))
    a = np.asarray(im) < INK_LEVEL
    h, w = a.shape
    mx, my = int(w * MARGIN), int(h * MARGIN)
    inner = np.zeros_like(a); inner[my:h - my, mx:w - mx] = True
    ink = a & inner

    def mask(boxes):
        m = np.zeros_like(a)
        for b in boxes:
            m[int(b[1] * h):int(np.ceil(b[3] * h)), int(b[0] * w):int(np.ceil(b[2] * w))] = True
        return m
    kept = C.keep_regions(regs)
    read = mask([r['box'] for r in kept])
    pict = mask([r['box'] for r in regs if r['label'] in C.DROP])
    total = int(ink.sum()) or 1
    return {'regions': len(regs), 'read': len(kept), 'pictures': sum(r['label'] in C.DROP for r in regs),
            'ink_read': float((ink & read).sum() / total), 'ink_picture_only': float((ink & pict & ~read).sum() / total)}


def summarise(vals: list[dict]) -> dict:
    import statistics as st
    n = len(vals)
    return {'pages': n, 'no_region_read': sum(v['read'] == 0 for v in vals),
            'with_picture': sum(v['pictures'] > 0 for v in vals),
            'ink_read_mean': round(st.mean(v['ink_read'] for v in vals), 4),
            'ink_read_under_80': sum(v['ink_read'] < 0.8 for v in vals),
            'ink_picture_only_mean': round(st.mean(v['ink_picture_only'] for v in vals), 4),
            'regions_mean': round(st.mean(v['read'] for v in vals), 1)}


def cmd_hands(a):
    pages = [p for p in load_pages() if 'agreement-only' not in p['groups']]
    out = {'ink': f'pixel < {INK_LEVEL} at {INK_SIDE} px long side, {MARGIN:.0%} margin excluded', 'detectors': {}}
    per_page = {}
    for det in DETECTORS:
        regs = read_regions(det)
        m = {p['id']: page_measures(p['image'], regs[p['id']]['regions']) for p in pages}
        per_page[det] = m
        secs = sorted(regs[p['id']]['seconds'] for p in pages)
        out['detectors'][det] = {'setup': DETECTORS[det], 'median_seconds': secs[len(secs) // 2], 'groups': {
            g: summarise([m[p['id']] for p in pages if g in p['groups']]) for g in HANDS + CONTEXT}}
        print(det, json.dumps(out['detectors'][det]['groups']['handwritten']), flush=True)
    out['pages'] = {det: per_page[det] for det in per_page}
    RESULTS.mkdir(exist_ok=True)
    (RESULTS / 'layout-photo-hands.json').write_text(json.dumps(out, indent=1) + '\n')
    (RESULTS / 'layout-photo-hands.md').write_text(hands_md(out))
    print('->', RESULTS / 'layout-photo-hands.md')


def hands_md(out: dict) -> str:
    names = {'L1': 'L1 historical hands', 'L2': 'L2 Bentham', 'handwritten': "the 96's handwritten",
             'L9': 'L9 newspapers', 'L4': 'L4 registers', 'the 96': 'the 96, all'}
    lines = ['| Detector | Pages | Nothing read | Ink read, mean | Pages under 80% ink read | Pages with a picture '
             '| Ink only in pictures, mean | Regions read, mean |', '|---|---|---|---|---|---|---|---|']
    body = []
    for g in HANDS + CONTEXT:
        body.append(f'\n**{names[g]}**\n')
        body += lines
        for det, d in out['detectors'].items():
            s = d['groups'][g]
            body.append(f'| {det} | {s["pages"]} | {s["no_region_read"]} | {s["ink_read_mean"]:.1%} | '
                        f'{s["ink_read_under_80"]} | {s["with_picture"]} | {s["ink_picture_only_mean"]:.1%} | '
                        f'{s["regions_mean"]} |')
    setups = '\n'.join(f'- **{k}**: {d["setup"]}; median {d["median_seconds"]:.2f} s a page on this Mac'
                       for k, d in out['detectors'].items())
    return ('# W46.layout-photo — the four detectors on handwriting, before any reader\n\n'
            'Generated by `scripts/segbench/layout_photo.py hands`; per-page figures in `layout-photo-hands.json`. '
            f'Ink: {out["ink"]}, a proxy for text. "Read" is what the region step would send to a reader '
            '(`regions_cluster.keep_regions`: no picture labels, no box 90% inside a larger kept one).\n\n'
            f'{setups}\n' + '\n'.join(body) + '\n')


# ---------------------------------------------------------------- the Sherlock pack

SH_SCRATCH = '/scratch/users/cp1/fs-ocr'      # $FS_ROOT on Sherlock (sherlock/sh.env)
PILOT_STEM = 'PPT_1637904769_page_001'        # the pilot's first eight pages: this page in all eight conditions
WHOLE = [{'label': 'page', 'order': 1, 'score': 1.0, 'box': [0.0, 0.0, 1.0, 1.0]}]
SUPPORT = {'corpus': ('layout_photo_cluster.py', 'regions_cluster.py', 'layout-photo-job.sh',
                      'layout-photo-stage-job.sh', 'layout-photo-submit.sh'),
           'sherlock': ('sh.env', 'bin/py', 'bin/vllm')}


def sha256(p: Path) -> str:
    import hashlib
    return hashlib.sha256(p.read_bytes()).hexdigest()


def cmd_pack(a):
    """The Sherlock pack. The 96, L9 and L4 in the three new arms, on the pages W46.ocr-regions read: the same
    ids, the same 2,400 px cluster copies (by path and sha256, already in Sherlock's scratch), the same request.
    The Real5 images travel in the pack (images/, about 0.6 GB), with every arm: whole page, the four detectors
    on the four conditions, and whole, YOLO and PP-DocLayoutV3 on the quad and UVDoc copies."""
    import shutil
    out = a.out.resolve(); name = out.name
    src = CACHE / 'sherlock-results/regions-20261021'
    bench = [json.loads(x) for x in (src / 'pages.jsonl').read_text().splitlines() if x.strip()]
    bench = [p for p in bench if p['set'] == 'owner99' or p.get('stratum') in GLM_SETS]
    r5 = real5_pages()
    assert len(r5) == 155 * (len(REAL5_COND) + len(REAL5_PREPPED)), len(r5)
    r5.sort(key=lambda p: (p['stem'] != PILOT_STEM, p['id']))
    assert all(p['stem'] == PILOT_STEM for p in r5[:8])
    pack_pages = []
    for p in r5:
        rel = Path('images') / p['cond'] / Path(p['image']).name
        (out / rel).parent.mkdir(parents=True, exist_ok=True)
        if not (out / rel).exists():
            shutil.copyfile(p['image'], out / rel)
        pack_pages.append({'id': p['id'], 'image': f'{SH_SCRATCH}/{name}/{rel}', 'sha256': sha256(out / rel),
                           'set': 'real5', 'stratum': None, 'cond': p['cond'], 'stem': p['stem'],
                           'data_source': p['data_source'], 'source': 'real5'})
    pack_pages += bench
    routes = json.loads((src / 'routes.json').read_text())
    (out / 'regions').mkdir(parents=True, exist_ok=True)
    (out / 'pages.jsonl').write_text(''.join(json.dumps(p) + '\n' for p in pack_pages))
    (out / 'routes.json').write_text(json.dumps({'glm-ocr': routes['glm-ocr']}, indent=2) + '\n')
    base = [p['id'] for p in r5 if p['cond'] in REAL5_COND]
    every = [p['id'] for p in r5]
    bench_ids = [p['id'] for p in bench]
    plan = {'whole': (None, every), 'yolo_appsort': ('yolo', bench_ids + every), 'pp-doclayoutv3': ('pp', every),
            'heron': ('heron', bench_ids + base), 'vision_doc': ('vision', bench_ids + base)}
    crops, setups = {}, {}
    for arm, (det, ids) in plan.items():
        if det is None:
            pages = {i: WHOLE for i in ids}; setups[arm] = 'the whole page, one crop'
        else:
            regs = {**read_regions(det), **json.loads(regions_path(det, 'real5').read_text())['pages']}
            missing = [i for i in ids if i not in regs]
            assert not missing, (det, missing[:5])
            pages = {i: regs[i]['regions'] for i in ids}; setups[arm] = DETECTORS[det]
        (out / 'regions' / f'{arm}.json').write_text(json.dumps({'detector': setups[arm], 'pages': pages}) + '\n')
        crops[arm] = sum(len(C.keep_regions(r)) for r in pages.values())
    for f in ('regions_cluster.py', 'layout_photo_cluster.py'):
        shutil.copyfile(HERE / 'corpus' / f, out / f)
    for d, files in SUPPORT.items():
        for f in files:
            dest = out / 'support' / d / f
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(HERE / d / f, dest)
    freeze = {'tag': 'W46.layout-photo', 'pack': name, 'reader': 'glm-ocr', 'arms': setups,
              'pages': {'bench': len(bench), 'real5': len(r5)}, 'crops': crops, 'crops_total': sum(crops.values()),
              'code_sha256': {f: sha256(out / f) for f in ('regions_cluster.py', 'layout_photo_cluster.py')},
              'regions_sha256': {f.name: sha256(f) for f in sorted((out / 'regions').glob('*.json'))},
              'pages_sha256': sha256(out / 'pages.jsonl')}
    (out / 'freeze.json').write_text(json.dumps(freeze, indent=1) + '\n')
    (out / 'README.md').write_text(
        f'# W46.layout-photo — GLM-OCR on four layout detectors\' regions\n\n'
        f'Submit only from an owner-started Sherlock session:\n\n    bash <pack>/support/corpus/layout-photo-submit.sh <pack>\n\n'
        f'Four jobs: CPU stage, an eight-page pilot, two GLM-OCR shards. {sum(crops.values()):,} crops '
        f'({len(bench)} bench pages, {len(r5)} Real5 images).\n'
        f'Results: `$GROUP_HOME/$USER/archive-suite/sherlock-results/{name}/`.\n'
        'Size and necessity review: `execution-plans/items/W46.layout-photo.md` in the repo.\n')
    print(json.dumps({'pages': freeze['pages'], 'crops': crops, 'total': freeze['crops_total']}))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('pages')
    d = sub.add_parser('detect'); d.add_argument('--detector', choices=sorted(DETECTORS), required=True)
    d.add_argument('--pageset', choices=('bench', 'real5'), default='bench')
    sub.add_parser('hands')
    sub.add_parser('real5-fetch')
    sub.add_parser('real5-prep')
    p = sub.add_parser('pack'); p.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    {'pages': cmd_pages, 'detect': cmd_detect, 'hands': cmd_hands, 'pack': cmd_pack,
     'real5-fetch': cmd_real5_fetch, 'real5-prep': cmd_real5_prep}[a.cmd](a)


if __name__ == '__main__':
    main()
