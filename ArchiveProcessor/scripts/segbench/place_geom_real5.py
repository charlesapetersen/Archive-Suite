#!/usr/bin/env python3
"""W46.place-geom-real5 — W46.place-geom's line-drag arms on Real5-OmniDocBench's Warping and Skew folders.

W46.place-geom found a deskewed reading copy lifts line selection +6.8 points on the 96's skewed pages. This asks
whether that holds on public photographs: the 155 English plain-text pages of OmniDocBench v1.5 that W46.layout-photo
uses, as Real5 photographed them warped and skewed (310 images).

  $L place_geom_real5.py fetch     the two folders' copies, frozen as the panel freezes pages; OmniDocBench.json
  $V place_geom_real5.py prep      Apple's quad, Vision's lines on the raw photograph, the quad and UVDoc lattices
  $V place_geom_real5.py truth     the line truth (below)
  $V place_geom_real5.py run       every arm and writer of W46.place-geom, through its own page_rows
  $V place_geom_real5.py report    segbench-results/place-geom-real5.{md,json}

  ($L is the Vision OCR lab's venv, which has huggingface_hub; $V is W46.enh-dewarp's venv. Run prep and run under
  ops/autonomous/heavy-run.py.)

Line truth. OmniDocBench's lines (its `line_with_spans`) are drawn on the digital page, not on Real5's photographs,
and no registration carries them through each capture. So a truth line here is a Vision line on the raw photograph
whose text is one OmniDocBench line's text (normalised, similarity ≥ 0.9, the line's best match and that line's
only taker), with Vision's own word quads as its words. That keeps the lines Vision split or joined out of the
truth, so the drag asks only what W46.place-geom asks: given Vision's words, does a drag across a real line return
them. It is not a test of lines Vision got wrong; every arm lays the same Vision lines, so it favours no arm.

Drags start at the midpoint of the first word's left quad edge and end at the midpoint of the last word's right
edge (W46.place-geom's truth boxes were ink boxes on near-level pages; on Real5's skewed photographs a box's corner
is not the word's edge). PLACE_GEOM_MARGIN moves both out along the line by that share of the word's height.

Writes the item's own cache (images, lattices, layers, drags; rebuildable) and the committed results (counts and
page ids only). The images are Apache-2.0 (Real5) and OmniDocBench's annotations research-only: scores only here.
No model reads a page beyond Apple Vision, nothing leaves the Mac, no money.
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
RESULTS = HERE.parents[1] / 'segbench-results'
REH = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
CACHE = REH / 'place-geom-real5'
OMNI = CACHE / 'omnidocbench-v1_5/OmniDocBench.json'
DEWARP = REH / 'enh-dewarp'                   # W46.enh-dewarp's UVDoc clone and weights, read only
DEWARP_BIN = REH / 'segbench/bin/segbench-dewarp'
REPO = 'PaddlePaddle/Real5-OmniDocBench'
FOLDERS = {'warp': 'Real5-OmniDocBench-Warping', 'skew': 'Real5-OmniDocBench-Skew'}
MATCH = 0.9
MARGIN = float(os.environ.get('PLACE_GEOM_MARGIN', '0'))


def pages() -> list[dict]:
    return [json.loads(x) for x in (CACHE / 'pages.jsonl').read_text().splitlines() if x.strip()]


# ---------------------------------------------------------------- fetch (lab venv)
def cmd_fetch(a):
    import concurrent.futures as cf
    import shutil
    import layout_photo as LP
    import src_omnidoc as O
    from huggingface_hub import HfApi, hf_hub_download
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    if not OMNI.exists():
        hf_hub_download('opendatalab/OmniDocBench', 'OmniDocBench.json', repo_type='dataset', revision='v1_5',
                        local_dir=OMNI.parent)
    kept = [p for p in json.loads(OMNI.read_text())
            if p['page_info']['page_attribute']['language'] == 'english' and O.truth(p)]
    files = set(HfApi().list_repo_files(REPO, repo_type='dataset'))
    rows, raw = [], CACHE / 'download'
    for p in sorted(kept, key=lambda p: p['page_info']['image_path']):
        stem = p['page_info']['image_path'].rsplit('.', 1)[0]
        for cond, folder in FOLDERS.items():
            name = next(f for f in (f'{folder}/{stem}.jpg', f'{folder}/{stem}.png') if f in files)
            rows.append({'id': f'{cond}__{stem}', 'cond': cond, 'stem': stem, 'source_file': name,
                         'omni_image': p['page_info']['image_path'],
                         'data_source': p['page_info']['page_attribute']['data_source'],
                         'image': str(CACHE / 'images' / cond / f'{stem}.jpg')})

    def one(r):
        dest = Path(r['image'])
        if not dest.exists():
            got = Path(hf_hub_download(REPO, r['source_file'], repo_type='dataset', local_dir=raw))
            with Image.open(got) as im:
                LP.freeze(im, dest)
            got.unlink()
        return r['id']
    with cf.ThreadPoolExecutor(8) as ex:
        for n, _ in enumerate(ex.map(one, rows), 1):
            if n % 50 == 0 or n == len(rows):
                print(f'fetched {n}/{len(rows)}', flush=True)
    shutil.rmtree(raw, ignore_errors=True)
    (CACHE / 'pages.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
    print(len(kept), 'pages,', len(rows), 'images')


# ---------------------------------------------------------------- prep (dewarp venv)
def swift(mode, rows):
    jobs = CACHE / f'{mode}-jobs.tsv'
    jobs.write_text(''.join('\t'.join(map(str, r)) + '\n' for r in rows))
    subprocess.run([str(DEWARP_BIN), mode, str(jobs)], check=True)
    jobs.unlink()


def cmd_prep(a):
    import numpy as np
    from PIL import Image
    import dewarp_arms as A
    from enh_dewarp import lattice_bend
    ps = pages()
    for d in ('quad', 'lines/raw', 'grids/quad', 'grids/uvdoc'):
        (CACHE / d).mkdir(parents=True, exist_ok=True)
    swift('quad', [(p['image'], CACHE / 'quad' / f'{p["id"]}.json') for p in ps])
    swift('lines', [(p['image'], CACHE / 'lines/raw' / f'{p["id"]}.json') for p in ps])
    for n, p in enumerate(ps, 1):
        todo = [arm for arm in ('quad', 'uvdoc') if not (CACHE / 'grids' / arm / f'{p["id"]}.npz').exists()]
        if todo:
            with Image.open(p['image']) as im:
                img = np.asarray(im.convert('RGB'))
            quad = json.loads((CACHE / 'quad' / f'{p["id"]}.json').read_text())
            for arm in todo:
                out, g, found = (A.quad_arm(img, quad) if arm == 'quad'
                                 else A.uvdoc_after_quad(img, quad, DEWARP / 'src'))
                np.savez(CACHE / 'grids' / arm / f'{p["id"]}.npz', grid=g, out_w=out.shape[1], out_h=out.shape[0],
                         src_w=img.shape[1], src_h=img.shape[0], found=found,
                         bend=lattice_bend(g, (img.shape[1], img.shape[0])))
        if n % 25 == 0 or n == len(ps):
            print(f'prep {n}/{len(ps)}', flush=True)


# ---------------------------------------------------------------- the line truth
def norm(s: str) -> str:
    return ' '.join(re.sub(r'[^0-9a-z]+', ' ', s.lower()).split())


def omni_lines(page: dict) -> list[str]:
    """The page's candidate lines, normalised, at least two words, each once: every text span of its blocks
    (merged blocks' included), and each block's text and its newline-separated pieces. 59 of the 155 pages, most of
    them slides, carry no spans; a Vision line that is a whole block or bullet is a printed line all the same, and a
    piece that wraps over two printed lines is longer than either line, so it matches neither."""
    out = []

    def walk(b):
        for s in b.get('line_with_spans') or []:
            if s.get('category_type') == 'text_span' and s.get('text'):
                out.append(norm(s['text']))
        text = (b.get('text') or '').strip()
        if text:
            out.append(norm(text))
            out.extend(norm(x) for x in text.split('\n'))
        for m in b.get('merge_list') or []:
            walk(m)
    for b in page['layout_dets']:
        walk(b)
    return list(dict.fromkeys(s for s in out if len(s.split()) >= 2))


def match_lines(vtexts: list[str], olines: list[str]) -> dict[int, int]:
    """Vision line k -> OmniDocBench line j, when j is k's best match at ≥ MATCH and no other Vision line takes j."""
    best = {}
    for k, v in enumerate(vtexts):
        if len(v.split()) < 2:
            continue
        scored = []
        for j, o in enumerate(olines):
            if abs(len(o) - len(v)) > 0.25 * max(len(o), len(v)):
                continue
            sm = difflib.SequenceMatcher(None, v, o, autojunk=False)
            if sm.quick_ratio() >= MATCH:            # an upper bound on ratio(), cheap
                scored.append((sm.ratio(), j))
        if scored:
            r, j = max(scored)
            if r >= MATCH:
                best[k] = j
    taken = {}
    for k, j in best.items():
        taken.setdefault(j, []).append(k)
    return {k: j for k, j in best.items() if len(taken[j]) == 1}


def cmd_truth(a):
    import place_geom as G
    omni = {p['page_info']['image_path']: p for p in json.loads(OMNI.read_text())}
    (CACHE / 'truth').mkdir(exist_ok=True)
    tot = {'vision_lines': 0, 'matched': 0}
    for p in pages():
        d = json.loads((CACHE / 'lines/raw' / f'{p["id"]}.json').read_text())
        olines = omni_lines(omni[p['omni_image']])
        vtexts = [norm(ln['text']) for ln in d['lines']]
        m = match_lines(vtexts, olines)
        words = []
        for k, ln in enumerate(d['lines']):
            # the same words, in the same order, as place_geom.vision_words reads (so truth word i is Vision word i)
            for w in ln.get('words') or [{'quad': ln['quad'], 'text': ln['text']}]:
                if not w['text'].strip():
                    continue
                words.append({'text': w['text'].strip(), 'quad': w['quad'], 'box': G.quad_bbox(w['quad']),
                              'line': k if k in m else None, 'status': 'ok'})
        tot['vision_lines'] += len(d['lines'])
        tot['matched'] += len(m)
        (CACHE / 'truth' / f'{p["id"]}.json').write_text(json.dumps(
            {'page': p['id'], 'group': p['cond'], 'kind': p['data_source'], 'width': d['width'],
             'height': d['height'], 'omni_lines': len(olines), 'matched': len(m), 'words': words}))
    print(json.dumps(tot))


# ---------------------------------------------------------------- run: W46.place-geom's page_rows on these pages
def drag_points(t, m, sc):
    """From the midpoint of the first word's left quad edge to the midpoint of the last word's right edge, moved out
    along the line by MARGIN of the word's height, carried onto the arm."""
    import numpy as np
    W, H = t['width'], t['height']
    q0 = np.asarray(t['words'][sc[0]]['quad'], float) * [W, H]
    q1 = np.asarray(t['words'][sc[-1]]['quad'], float) * [W, H]
    s, e = (q0[0] + q0[3]) / 2, (q1[1] + q1[2]) / 2
    u = (e - s) / max(1e-9, np.hypot(*(e - s)))
    hs, he = np.hypot(*(q0[3] - q0[0])), np.hypot(*(q1[2] - q1[1]))
    s_out, e_out = (s - MARGIN * hs * u) / [W, H], (e + MARGIN * he * u) / [W, H]
    s2, e2 = m([s_out, e_out])
    if not np.all(np.isfinite(s2)):
        s2 = m([s / [W, H]])[0]
    if not np.all(np.isfinite(e2)):
        e2 = m([e / [W, H]])[0]
    return s2, e2


def patch(G):
    """Point W46.place-geom's page_rows at this item's cache: Vision lines, quads and lattices kept in the same
    layout as W46.enh-dewarp's, and the quad-edge drags."""
    G.DEWARP = CACHE
    G.CACHE = CACHE
    G.drag_points = drag_points
    G.assign = assign


def assign(t, vwords):
    """Truth word i is Vision word i (the truth is Vision's own words); W46.place-geom's centre-in-box rule would
    pick a neighbour's box on a steeply skewed page, where axis-aligned word boxes overlap."""
    assert len(t['words']) == len(vwords) and all(w['text'] == v['text'] for w, v in zip(t['words'], vwords)), t['page']
    return {i: i for i in range(len(vwords))}


def cmd_run(a):
    import place_geom as G
    patch(G)
    ts = [json.loads(f.read_text()) for f in sorted((CACHE / 'truth').glob('*.json'))]
    if a.pages:
        ts = [t for t in ts if t['page'] in a.pages.split(',')]
    out = CACHE / os.environ.get('PLACE_GEOM_ROWS', 'rows.jsonl')
    done = {}
    if a.fresh and out.exists():
        out.write_text('')
    if out.exists():
        for x in out.read_text().splitlines():
            r = json.loads(x)
            done[r['meta']['page']] = r
    for n, t in enumerate(ts, 1):
        if t['page'] in done:
            continue
        rows, meta = G.page_rows(t, {})
        g = __import__('numpy').load(CACHE / 'grids/uvdoc' / f'{t["page"]}.npz')
        meta.update(bend=float(g['bend']), quad_found=bool(g['found']), cond=t['group'])
        done[t['page']] = {'meta': meta, 'rows': rows}
        with out.open('a') as f:
            f.write(json.dumps(done[t['page']]) + '\n')
        base = next(r for r in rows if (r['arm'], r['writer']) == G.BASE)
        print(f'{n}/{len(ts)} {t["page"]} lines {meta["scored_lines"]} raw-lab passed {base["passed"]}', flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    for c in ('fetch', 'prep', 'truth', 'report'):
        sub.add_parser(c)
    r = sub.add_parser('run')
    r.add_argument('--pages')
    r.add_argument('--fresh', action='store_true')
    a = ap.parse_args()
    if a.cmd == 'report':
        import place_geom_real5_report
        place_geom_real5_report.write(CACHE / 'rows.jsonl', RESULTS)
        return
    {'fetch': cmd_fetch, 'prep': cmd_prep, 'truth': cmd_truth, 'run': cmd_run}[a.cmd](a)


if __name__ == '__main__':
    main()
