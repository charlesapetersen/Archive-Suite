#!/usr/bin/env python3
"""W46.dewarp-placement — dewarp for placement only, and the licence-freed dewarpers, on the owner's curled pages.

W46.dewarp-curved-select (`segbench-results/dewarp-curved-select.md`) scored a guarded UVDoc *reading copy*: the
layer carried onto the dewarped image the user would then keep. Never tested: keeping the original (the route's raw
or deskewed copy) and using the dewarp only to place the layer, Vision reading the flattened image and its words
carried back onto the original through the dewarper's own lattice (enh-dewarp.md, "Line boxes carried back through
the saved lattice"). Nor DvD and DocTr++, which the owner's 17 Nov licence call allows as optional downloads.

  python3 dewarp_placement.py prep [--dewarpers uvdoc,dvd,doctrpp]   upright copies, Apple's quad, each dewarper after
                                         the quad (its lattice and image), Vision lines on each dewarped image
                                         (torch-env's python, under heavy-run.py)
  python3 dewarp_placement.py run [--dewarpers …]   every arm on the 64 pages of place-curved-owner (torch-env)
  python3 dewarp_placement.py report     segbench-results/dewarp-placement.json

The arms, all scored with place-curved-owner's blla lines and drags on the same upright photograph:
- route: place-curved-owner's reading copy (raw, or deskewed at a median line angle of 1° or more), Vision's raw
  lines, one level run per line. Replayed; its counts must equal the committed rows.
- <d>-copy and <d>-guarded: as dewarp-curved-select's uvdoc and guarded arms, for dewarper d (the layer and drags
  carried onto d's image; guarded keeps the route where the own-sheet guard holds d back).
- <d>-place-line and <d>-place-chunk: placement only. The image is the route's copy, unchanged. Vision reads d's
  flattened image; each word's quad is carried back through d's lattice (output -> source, grid_eval) onto the
  upright photograph, then onto the route's copy. Raw Vision words that d's image does not show (outside its
  lattice) keep their raw lines, so the layer removes nothing. `line` writes one level run per carried line (the
  route's writer); `chunk` splits a carried line into consecutive level runs wherever one run would grow taller than
  1.4 median word heights, so the runs follow the bend.

A placement arm's words are its own (the flattened reading), so a blla line's expected words come from that arm's
words (place_curved.blla_expected), and an OCR difference is not a selection failure. Each arm is compared with the
route on the blla lines both score (the headline), and its own scored set is reported beside it.

Reads place-curved-owner's cached Vision and blla lines, the Reader sample copy and two UIUC originals (read only).
Writes CACHE (rebuildable) and the committed result. No network, no money.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import place_curved as PC  # noqa: E402
import dewarp_curved_select as DCS  # noqa: E402
from place_geom import (PT, carried_layer, deskew_map, identity_map, lattice_inverse, page_angle,  # noqa: E402
                        quad_bbox, run_tool)

RESULTS = HERE.parents[1] / 'segbench-results'
CACHE = DCS.REH / 'dewarp-placement'
DCS.CACHE = CACHE                 # its upright copies, HEIC conversions and quads go to this item's cache
EXTRA = CACHE / 'src'             # DvD and DocTr++ code and weights (downloaded, never bundled; dewarp_extra_arms.py)
DEWARPERS = ('uvdoc', 'dvd', 'doctrpp')
CHUNK_TALL = 1.4


# ---------------------------------------------------------------- prep
def dewarp_fn(d):
    import dewarp_arms as A
    if d == 'uvdoc':
        return lambda img: A.uvdoc_arm(img, DCS.UVDOC_SRC)
    import dewarp_extra_arms as X
    return {'dvd': lambda img: X.dvd_arm(img, EXTRA), 'doctrpp': lambda img: X.doctrpp_arm(img, EXTRA)}[d]


def after_quad(img, quad, fn):
    """dewarp_arms.uvdoc_after_quad for any dewarper: Apple's quad first, its lattice carried back through the quad."""
    import dewarp_arms as A
    q, _, found = A.quad_arm(img, quad)
    out, g = fn(q)
    if not found:
        return out, g, False
    h, w = img.shape[:2]
    qh, qw = q.shape[:2]
    H = A.homography(np.float64(quad['corners']) * (w, h), qw, qh)
    return out, A.apply_h(H, g * (qw, qh)) / (w, h), True


def ddir(d, sub):
    p = CACHE / d / sub
    p.mkdir(parents=True, exist_ok=True)
    return p


def cmd_prep(a):
    from PIL import Image
    for sub in ('up', 'quad'):
        (CACHE / sub).mkdir(parents=True, exist_ok=True)
    rs = DCS.rows()
    for r, s, _ in rs:
        k = r['key']
        if not DCS.up(k).exists():
            PC.write_upright(DCS.stored(s), DCS.up(k), s['turn'])
        W, H, _, _ = PC.vision(k)
        with Image.open(DCS.up(k)) as im:
            assert im.size == (W, H), (k, im.size, W, H)
    jobs = CACHE / 'quad-jobs.tsv'
    jobs.write_text(''.join(f"{DCS.up(r['key'])}\t{CACHE / 'quad' / (r['key'] + '.json')}\n" for r, _, _ in rs
                            if not (CACHE / 'quad' / (r['key'] + '.json')).exists()))
    if jobs.read_text():
        subprocess.run([str(DCS.DEWARP_BIN), 'quad', str(jobs)], check=True)
    for d in a.dewarpers:
        fn = None
        for n, (r, _, _) in enumerate(rs, 1):
            k = r['key']
            g, o = ddir(d, 'grids') / f'{k}.npz', ddir(d, 'out') / f'{k}.jpg'
            if g.exists() and o.exists():
                continue
            fn = fn or dewarp_fn(d)
            with Image.open(DCS.up(k)) as im:
                img = np.asarray(im.convert('RGB'))
            quad = json.loads((CACHE / 'quad' / f'{k}.json').read_text())
            out, grid, found = after_quad(img, quad, fn)
            Image.fromarray(out).save(o, quality=92)
            np.savez(g, grid=grid, out_w=out.shape[1], out_h=out.shape[0], src_w=img.shape[1], src_h=img.shape[0],
                     found=found)
            print(f'{d} {n}/{len(rs)} {k} quad found {found}', flush=True)
        jobs = CACHE / f'{d}-lines-jobs.tsv'
        jobs.write_text(''.join(f"{ddir(d, 'out') / (r['key'] + '.jpg')}\t{ddir(d, 'lines') / (r['key'] + '.json')}\n"
                                for r, _, _ in rs if not (ddir(d, 'lines') / (r['key'] + '.json')).exists()))
        if jobs.read_text():
            subprocess.run([str(DCS.DEWARP_BIN), 'lines', str(jobs)], check=True)


# ---------------------------------------------------------------- the placement-only layer
def flat_reading(d, k):
    """Vision's lines on d's flattened image, in that image's normalised coordinates."""
    dd, turn = PC.upright(json.loads((CACHE / d / 'lines' / f'{k}.json').read_text()))
    assert turn == 0, (d, k, 'flattened copy read turned', turn)
    lines, words = [], []
    for li, ln in enumerate(dd['lines']):
        ids = []
        for w in ln.get('words') or [{'quad': ln['quad'], 'text': ln['text']}]:
            if w['text'].strip():
                ids.append(len(words))
                words.append({'text': w['text'].strip(), 'quad': w['quad'], 'line': li})
        if ids:
            lines.append({'words': ids})
    return lines, words


def placed_words(grid, flines, fwords, vlines, vwords):
    """The placement arm's words on the upright photograph: the flattened reading carried back through the lattice,
    then every raw Vision line whose words the flattened image does not show. Returns (lines, words, filled)."""
    import enh_dewarp as E
    from enh_dewarp import grid_eval
    lines, words = [], []
    for ln in flines:
        ids = []
        for j in ln['words']:
            q = grid_eval(grid, np.clip(np.asarray(fwords[j]['quad'], float), 0, 1))
            ids.append(len(words))
            words.append({'text': fwords[j]['text'], 'quad': q.tolist(), 'line': len(lines), 'box': quad_bbox(q)})
        lines.append({'words': ids})
    centres = np.array([np.float64(w['quad']).mean(0) for w in vwords]).reshape(-1, 2)
    shown = E.covered(grid, centres) if len(vwords) else np.zeros(0, bool)
    filled = 0
    for ln in vlines:
        lost = [j for j in ln['words'] if not shown[j]]
        if not lost:
            continue
        ids = []
        for j in lost:
            ids.append(len(words))
            words.append({**vwords[j], 'line': len(lines)})
        lines.append({'words': ids})
        filled += len(lost)
    return lines, words, filled


def chunk_lines(m, lines, words, tall=CHUNK_TALL):
    """Each line as consecutive level runs on the copy: a new run starts where the run's box would grow taller than
    `tall` median word heights of the line."""
    out = []
    for ln in lines:
        boxes = []
        for j in ln['words']:
            p = m(np.asarray(words[j]['quad'], float))
            p = p[np.all(np.isfinite(p), 1)]
            if len(p):
                boxes.append((j, quad_bbox(p)))
        if not boxes:
            continue
        limit = tall * float(np.median([b[3] for _, b in boxes]))
        run = [boxes[0]]
        for jb in boxes[1:]:
            ys = [b[1] for _, b in run + [jb]]
            ye = [b[1] + b[3] for _, b in run + [jb]]
            if max(ye) - min(ys) > limit:
                out.append(run)
                run = [jb]
            else:
                run.append(jb)
        out.append(run)
    res = []
    for run in out:
        pts = np.concatenate([[[b[0], b[1]], [b[0] + b[2], b[1] + b[3]]] for _, b in run])
        res.append({'text': ' '.join(words[j]['text'] for j, _ in run), 'box': quad_bbox(pts)})
    return res


# ---------------------------------------------------------------- one page
def page(r, s, c, dewarpers):
    k = r['key']
    work = CACHE / 'pages' / k
    work.mkdir(parents=True, exist_ok=True)
    W, H, vlines, vwords = PC.vision(k)
    bd = json.loads(PC.blla_path(k).read_text())
    blines = [] if bd.get('failed') else bd['lines']
    exp, _ = PC.blla_expected(blines, vwords) if blines else ([], {})
    angle = page_angle(vlines, W, H)
    route = 'deskew' if abs(angle) >= PC.DESKEW_DEG else 'raw'
    assert route == r['route'], (k, route, r['route'])
    mr = deskew_map(W, H, angle) if route == 'deskew' else identity_map(W, H)
    plans = {}                          # arm -> (map, layer lines, words, expected, kept, carried drags?)
    plans['route'] = (mr, PC.layer_lines(mr, vlines, vwords), vwords, exp, set(range(len(vwords))), False)
    out = {'key': k, 'group': r['group'], 'pair': r.get('pair'), 'class': c['page'], 'route': route, 'guard': {},
           'filled': {}, 'arms': {}}
    for d in dewarpers:
        g = np.load(CACHE / d / 'grids' / f'{k}.npz')
        assert int(g['src_w']) == W and int(g['src_h']) == H, (d, k)
        grid = g['grid']
        md = lattice_inverse(grid, float(g['out_w']), float(g['out_h']), W, H, 'uvdoc')
        lines, kept = carried_layer(md, vlines, vwords, 'lab')
        plans[f'{d}-copy'] = (md, lines, vwords, exp, kept, True)
        passes, lost_own, lost_neigh = guard(k, vwords, grid)
        out['guard'][d] = {'pass': passes, 'lost_own': lost_own, 'lost_neighbour': lost_neigh}
        flines, fwords = flat_reading(d, k)
        plines, pwords, filled = placed_words(grid, flines, fwords, vlines, vwords)
        out['filled'][d] = filled
        pexp, _ = PC.blla_expected(blines, pwords) if blines else ([], {})
        allp = set(range(len(pwords)))
        plans[f'{d}-place-line'] = (mr, PC.layer_lines(mr, plines, pwords), pwords, pexp, allp, False)
        plans[f'{d}-place-chunk'] = (mr, chunk_lines(mr, plines, pwords), pwords, pexp, allp, False)
    jobs, drags_of = [], {}
    for arm, (m, lines, words, e, kept, carried) in plans.items():
        pdf = work / f'{arm}.pdf'
        jobs.append({'out': str(pdf), 'width': m.out_w * PT, 'height': m.out_h * PT, 'lines': lines})
        drags, cut, moved = [], [], 0
        for i, ws, boundary in e:
            if carried:
                st, en, mv = DCS.drag_ends(m, words, ws, boundary)
                moved += mv
            else:
                st, en = PC.ink_drag(m, words, ws, boundary)
            if not set(ws) <= kept or not (np.all(np.isfinite(st)) and np.all(np.isfinite(en))):
                cut.append(f'b{i}')
                continue
            drags.append({'id': f'b{i}', 'expected': ' '.join(words[j]['text'] for j in ws),
                          'start': st.tolist(), 'end': en.tolist()})
        drags_of[arm] = (pdf, drags, cut, moved)
    jf = work / 'jobs.json'
    jf.write_text(json.dumps(jobs))
    run_tool([PC.WRITER, jf])
    for arm, (pdf, drags, cut, moved) in drags_of.items():
        got = DCS.drag_outcomes(pdf, drags) if drags else {}
        out['arms'][arm] = {'n': len(drags) + len(cut), 'pass': sum(bool(x['pass']) for x in got.values()),
                            'broken': sum(bool(x['broken']) for x in got.values()), 'cut': len(cut),
                            'ends_moved': moved,
                            'lines': {i: bool(x['pass']) for i, x in got.items()} | {i: False for i in cut}}
    ra, cr = out['arms']['route'], r['arms'][route]
    assert (ra['n'], ra['pass'], ra['broken']) == (cr['blla_n'], cr['blla_pass'], cr['blla_broken']), (k, ra, cr)
    for d in dewarpers:
        out['arms'][f'{d}-guarded'] = out['arms'][f'{d}-copy' if out['guard'][d]['pass'] else 'route']
    return out


def guard(k, vwords, grid):
    """dewarp_curved_select.guard for any lattice: (passes, own words lost, neighbour words lost)."""
    import enh_dewarp as E
    from dewarp_guard import split_lost
    quad = json.loads((CACHE / 'quad' / f'{k}.json').read_text())
    words = [(w['line'], np.float64(w['quad']).mean(0), None) for w in vwords]
    centres = np.array([w[1] for w in words]).reshape(-1, 2)
    shown = E.covered(grid, centres) if len(words) else np.zeros(0, bool)
    corners = quad['corners'] if quad.get('found') else [[0, 0], [1, 0], [1, 1], [0, 1]]
    own, neigh = split_lost(words, shown, corners)
    return not own, len(own), len(neigh)


def cmd_run(a):
    rows = []
    for r, s, c in DCS.rows():
        x = page(r, s, c, a.dewarpers)
        rows.append(x)
        print(f"{x['group']:6} {x['key']:11} {x['class']:6} "
              + ' '.join(f"{arm} {v['pass']}/{v['n']}" for arm, v in x['arms'].items()), flush=True)
    (CACHE / f"rows-{'-'.join(a.dewarpers)}.json").write_text(json.dumps(rows))


# ---------------------------------------------------------------- the report
def common(x, arm, base='route'):
    """(lines both score, arm passes, base passes) on one page."""
    la, lb = x['arms'][arm]['lines'], x['arms'][base]['lines']
    ids = set(la) & set(lb)
    return len(ids), sum(la[i] for i in ids), sum(lb[i] for i in ids)


def paired(xs, arm, draws=DCS.DRAWS, seed=DCS.SEED):
    """Pooled pass on the lines both arm and route score: arm, route, arm minus route with a page bootstrap."""
    import random
    cs = [common(x, arm) for x in xs]

    def d(sel):
        n = sum(c[0] for c in sel)
        return 100 * (sum(c[1] for c in sel) - sum(c[2] for c in sel)) / n if n else 0.0
    n = sum(c[0] for c in cs)
    if not n:
        return None
    rng = random.Random(seed)
    ds = sorted(d([rng.choice(cs) for _ in cs]) for _ in range(draws))
    per = [100 * (c[1] - c[2]) / c[0] for c in cs if c[0]]
    return {'lines': n, 'arm': round(100 * sum(c[1] for c in cs) / n, 1), 'route': round(100 * sum(c[2] for c in cs) / n, 1),
            'delta': [round(d(cs), 1), round(ds[int(0.025 * draws)], 1), round(ds[int(0.975 * draws) - 1], 1)],
            'better': sum(p > 0 for p in per), 'worse': sum(p < 0 for p in per)}


def summary(xs, arms):
    xs = [x for x in xs if x['arms']['route']['n']]
    s = {'pages': len(xs)}
    for arm in arms:
        if not all(arm in x['arms'] for x in xs):
            continue
        own_n = sum(x['arms'][arm]['n'] for x in xs)
        s[arm] = {'own_lines': own_n,
                  'own_pass': round(100 * sum(x['arms'][arm]['pass'] for x in xs) / own_n, 1) if own_n else None,
                  'cut': sum(x['arms'][arm]['cut'] for x in xs), 'broken': sum(x['arms'][arm]['broken'] for x in xs)}
        if arm != 'route':
            s[arm]['vs_route'] = paired(xs, arm)
    for d in {a.split('-')[0] for a in arms if a != 'route'}:
        if all(d in x['guard'] for x in xs):
            s[f'{d}-guard_pass'] = sum(x['guard'][d]['pass'] for x in xs)
            s[f'{d}-filled_words'] = sum(x['filled'][d] for x in xs)
    return s


def cmd_report(a):
    by = {}
    for f in sorted(CACHE.glob('rows-*.json')):
        for x in json.loads(f.read_text()):
            if x['key'] in by:
                by[x['key']]['arms'] |= x['arms']
                by[x['key']]['guard'] |= x['guard']
                by[x['key']]['filled'] |= x['filled']
            else:
                by[x['key']] = x
    xs = list(by.values())
    arms = ['route'] + sorted({arm for x in xs for arm in x['arms'] if arm != 'route'})
    curved_all = [x for x in xs if x['group'] == 'curved']
    curved = [x for x in curved_all if x['class'] in DCS.CURVED_CLASSES]
    keys = {x['key'] for x in curved}
    flat = [x for x in xs if x['group'] == 'flat' and x['pair'] in keys]
    out = {'item': 'W46.dewarp-placement',
           'sets': {'curved bound or curled': summary(curved, arms), 'their flat pairs': summary(flat, arms),
                    'curved, classed flat': summary([x for x in curved_all if x not in curved], arms),
                    'all 64': summary(xs, arms)},
           'owner_pages': {x['key']: {arm: f"{v['pass']}/{v['n']}" for arm, v in x['arms'].items()}
                           | {'guard': x['guard']} for x in xs if x['key'] in PC.OWNER_PAGES},
           'rows': [{k: v for k, v in x.items() if k != 'arms'}
                    | {'arms': {arm: {kk: vv for kk, vv in v.items() if kk != 'lines'} for arm, v in x['arms'].items()}}
                    for x in xs]}
    (RESULTS / 'dewarp-placement.json').write_text(json.dumps(out, indent=1) + '\n')
    print(json.dumps({k: v for k, v in out.items() if k != 'rows'}, indent=1))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    for c in ('prep', 'run', 'report'):
        p = sub.add_parser(c)
        if c != 'report':
            p.add_argument('--dewarpers', default='uvdoc', type=lambda v: [d for d in v.split(',') if d])
    a = ap.parse_args()
    if a.cmd != 'report':
        assert set(a.dewarpers) <= set(DEWARPERS), a.dewarpers
    {'prep': cmd_prep, 'run': cmd_run, 'report': cmd_report}[a.cmd](a)


if __name__ == '__main__':
    main()
