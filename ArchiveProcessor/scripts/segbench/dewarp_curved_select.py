#!/usr/bin/env python3
"""W46.dewarp-curved-select — does a guarded UVDoc reading copy select better than the route's copy on the owner's
bound or curled pages, and does it cost the flat pages?

W46.dewarp-guard (`segbench-results/dewarp-guard.md`) found the print layer's selection gap on the 24 pages of
place-curved-owner that Gemini 3.7 Flash classed bound or curled (−21.9, −29.0 to −14.0), and a guard that keeps
UVDoc from cutting own-sheet words. This scores the guarded copy there for selection, with place-curved-owner's drags.

  python3 dewarp_curved_select.py prep     upright copies of the 64 pages, Apple's quad on each, and UVDoc 4c9b82b5's
                                           lattice after the quad (torch-env's python, under heavy-run.py)
  python3 dewarp_curved_select.py run      the route's copy (replayed) and the UVDoc copy, each with Vision's lines
                                           carried onto it, the lab writer and PDFKit's drags (torch-env's python)
  python3 dewarp_curved_select.py report   segbench-results/dewarp-curved-select.json

The arms, all on the same upright photograph, with the same Vision lines and the same blla truth lines:
- route: place-curved-owner's reading copy, raw or deskewed (median line angle 1° or more), its layer written
  exactly as that item wrote it. Replayed here so each line's outcome is known; its counts must equal the committed
  rows.
- uvdoc: UVDoc after Apple's quad (dewarp_arms.uvdoc_after_quad), Vision's lines carried through the inverted lattice
  (place_geom.lattice_inverse, carried_layer with the lab writer), the drags carried the same way.
- guarded: uvdoc where the guard passes, the route elsewhere. The guard (dewarp_guard.split_lost): no own-sheet
  Vision word of the raw reading falls outside the lattice, own when inside Apple's quad or on a Vision line that keeps
  another shown word. It reads no truth.

A blla line with a word the UVDoc copy does not show cannot be dragged there; it counts as a failure on that arm
(`cut`). The guard allows that only for neighbour text. A drag end that falls just off the copy while its word is
shown is moved to the copy's edge (drag_ends, counted as `ends_moved`).

Reads place-curved-owner's cached Vision lines and blla lines, the Reader sample copy and two UIUC originals (read
only, converted into this item's cache). Writes CACHE (rebuildable) and the committed result. No network, no money.
"""
from __future__ import annotations

import argparse
import json
import random
import statistics
import subprocess
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import place_curved as PC  # noqa: E402
from place_geom import PT, carried_layer, identity_map, deskew_map, lattice_inverse, page_angle, run_tool  # noqa: E402

RESULTS = HERE.parents[1] / 'segbench-results'
REH = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
CACHE = REH / 'dewarp-curved-select'
UVDOC_SRC = REH / 'enh-dewarp/src'            # UVDoc 4c9b82b5 with best_model.pkl, as W46.enh-dewarp ran it
DEWARP_BIN = REH / 'segbench/bin/segbench-dewarp'
SEED, DRAWS = 4611, 2000
CURVED_CLASSES = ('bound', 'curled')


def rows():
    """place-curved-owner's 64 committed rows, each with its survey record (stored path, turn) and its class."""
    pco = json.loads((RESULTS / 'place-curved-owner.json').read_text())
    survey = {r['key']: r for r in json.loads((PC.CACHE / 'survey.json').read_text())}
    cls = json.loads((RESULTS / 'dewarp-guard-class.json').read_text())['pages']
    return [(r, survey[r['key']], cls[r['key']]) for r in pco['rows']]


def stored(s):
    """The stored image: the sample copy, or for UIUC a JPEG converted from the HEIC original (place_curved's
    owner_images, into this cache; the corpus is only read)."""
    if not s['key'].startswith('uiuc-'):
        return PC.SAMPLE / s['rel']
    dst = CACHE / 'heic' / f"{s['key']}.jpg"
    if not dst.exists():
        dst.parent.mkdir(parents=True, exist_ok=True)
        src = PC.UIUC / f"UIUC — {s['key'].split('-')[1]}.HEIC"
        subprocess.run(['sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '92', str(src), '--out', str(dst)],
                       check=True, stdout=subprocess.DEVNULL)
    return dst


def up(key):
    return CACHE / 'up' / f'{key}.jpg'


def cmd_prep(a):
    from PIL import Image
    import dewarp_arms as A
    for d in ('up', 'quad', 'grids'):
        (CACHE / d).mkdir(parents=True, exist_ok=True)
    rs = rows()
    for r, s, _ in rs:
        k = r['key']
        if not up(k).exists():
            PC.write_upright(stored(s), up(k), s['turn'])
        W, H, _, _ = PC.vision(k)
        with Image.open(up(k)) as im:
            assert im.size == (W, H), (k, im.size, W, H)   # the copy place-curved-owner's Vision lines were read on
    jobs = CACHE / 'quad-jobs.tsv'
    jobs.write_text(''.join(f"{up(r['key'])}\t{CACHE / 'quad' / (r['key'] + '.json')}\n" for r, _, _ in rs
                            if not (CACHE / 'quad' / (r['key'] + '.json')).exists()))
    if jobs.read_text():
        subprocess.run([str(DEWARP_BIN), 'quad', str(jobs)], check=True)
    for n, (r, _, _) in enumerate(rs, 1):
        k = r['key']
        g = CACHE / 'grids' / f'{k}.npz'
        if g.exists():
            continue
        with Image.open(up(k)) as im:
            img = np.asarray(im.convert('RGB'))
        quad = json.loads((CACHE / 'quad' / f'{k}.json').read_text())
        out, grid, found = A.uvdoc_after_quad(img, quad, UVDOC_SRC)
        np.savez(g, grid=grid, out_w=out.shape[1], out_h=out.shape[0], src_w=img.shape[1], src_h=img.shape[0],
                 found=found)
        print(f'uvdoc {n}/{len(rs)} {k} quad found {found}', flush=True)


def guard(k, W, H, vlines, vwords, grid):
    """The own-sheet guard on the raw upright reading: (passes, own words lost, neighbour words lost)."""
    import enh_dewarp as E
    from dewarp_guard import split_lost
    quad = json.loads((CACHE / 'quad' / f'{k}.json').read_text())
    words = [(w['line'], np.float64(w['quad']).mean(0), None) for w in vwords]
    centres = np.array([w[1] for w in words]).reshape(-1, 2)
    shown = E.covered(grid, centres) if len(words) else np.zeros(0, bool)
    corners = quad['corners'] if quad.get('found') else [[0, 0], [1, 0], [1, 1], [0, 1]]
    own, neigh = split_lost(words, shown, corners)
    return not own, len(own), len(neigh)


def drag_ends(m, vwords, ws, boundary, steps=200):
    """place_curved.ink_drag's two ends carried onto the arm. UVDoc's copy often ends right at the text's left margin,
    so the first word's left edge (or the last's right) can lie just off the copy while the word itself is shown. Such
    an end is walked toward its word's centre to the first point the copy shows: the copy's edge, where a reader
    would start the drag. Returns (start, end, ends moved)."""
    b0, b1 = vwords[ws[0]]['box'], vwords[ws[-1]]['box']
    src = []
    for x, b in ((b0[0], b0), (b1[0] + b1[2], b1)):
        y = PC.vertical_mid(boundary, x)
        src.append((x, b[1] + b[3] / 2 if y is None else y))
    src = PC.clip(src)
    out, moved = [], 0
    for (x, y), b in zip(src, (b0, b1)):
        p = m([(x, y)])[0]
        if not np.all(np.isfinite(p)):
            c = (b[0] + b[2] / 2, b[1] + b[3] / 2)
            walk = m([(x + (c[0] - x) * t, y + (c[1] - y) * t) for t in np.linspace(0, 1, steps + 1)[1:]])
            ok = np.all(np.isfinite(walk), 1)
            if ok.any():
                p, moved = walk[np.argmax(ok)], moved + 1
        out.append(p)
    return out[0], out[1], moved


def drag_outcomes(pdf, drags):
    dj, do = pdf.with_suffix('.drags.json'), pdf.with_suffix('.drag-out.json')
    dj.write_text(json.dumps({'lines': drags}))
    run_tool([PC.FUNCTIONAL, 'drag', dj, pdf, do])
    return {g['id']: g for g in json.loads(do.read_text())['lines']}


def page(r, s, c):
    k = r['key']
    work = CACHE / 'pages' / k
    work.mkdir(parents=True, exist_ok=True)
    W, H, vlines, vwords = PC.vision(k)
    bd = json.loads(PC.blla_path(k).read_text())
    exp, _ = ([], {}) if bd.get('failed') else PC.blla_expected(bd['lines'], vwords)
    angle = page_angle(vlines, W, H)
    route = 'deskew' if abs(angle) >= PC.DESKEW_DEG else 'raw'
    assert route == r['route'], (k, route, r['route'])
    g = np.load(CACHE / 'grids' / f'{k}.npz')
    assert int(g['src_w']) == W and int(g['src_h']) == H, k
    maps = {'route': deskew_map(W, H, angle) if route == 'deskew' else identity_map(W, H),
            'uvdoc': lattice_inverse(g['grid'], float(g['out_w']), float(g['out_h']), W, H, 'uvdoc')}
    passes, lost_own, lost_neigh = guard(k, W, H, vlines, vwords, g['grid'])
    jobs, plans = [], {}
    for arm, m in maps.items():
        pdf = work / f'{arm}.pdf'
        if arm == 'route':
            lines, kept = PC.layer_lines(m, vlines, vwords), set(range(len(vwords)))
        else:
            lines, kept = carried_layer(m, vlines, vwords, 'lab')
        jobs.append({'out': str(pdf), 'width': m.out_w * PT, 'height': m.out_h * PT, 'lines': lines})
        drags, cut, moved = [], [], 0
        for i, ws, boundary in exp:
            if arm == 'route':
                s, e = PC.ink_drag(m, vwords, ws, boundary)   # place-curved-owner's drag, unchanged
            else:
                s, e, mv = drag_ends(m, vwords, ws, boundary)
                moved += mv
            if not set(ws) <= kept or not (np.all(np.isfinite(s)) and np.all(np.isfinite(e))):
                cut.append(f'b{i}')
                continue
            drags.append({'id': f'b{i}', 'expected': ' '.join(vwords[j]['text'] for j in ws),
                          'start': s.tolist(), 'end': e.tolist()})
        plans[arm] = (pdf, drags, cut, moved)
    jf = work / 'jobs.json'
    jf.write_text(json.dumps(jobs))
    unplaced = json.loads(run_tool([PC.WRITER, jf]))['unplaced']
    out = {'key': k, 'group': r['group'], 'pair': r.get('pair'), 'class': c['page'], 'lines_bent': c['lines_bent'],
           'route': route, 'quad_found': bool(g['found']), 'guard_pass': passes, 'lost_own': lost_own,
           'lost_neighbour': lost_neigh, 'arms': {}}
    for arm, (pdf, drags, cut, moved) in plans.items():
        got = drag_outcomes(pdf, drags) if drags else {}
        out['arms'][arm] = {'n': len(drags) + len(cut), 'pass': sum(bool(x['pass']) for x in got.values()),
                            'broken': sum(bool(x['broken']) for x in got.values()), 'cut': len(cut),
                            'ends_moved': moved,
                            'unplaced': sum(1 for u in unplaced if u['out'] == str(pdf)),
                            'lines': {i: bool(x['pass']) for i, x in got.items()} | {i: False for i in cut}}
    ra, cr = out['arms']['route'], r['arms'][route]
    # the replay must be place-curved-owner's committed row exactly
    assert (ra['n'], ra['pass'], ra['broken']) == (cr['blla_n'], cr['blla_pass'], cr['blla_broken']), (k, ra, cr)
    out['arms']['guarded'] = out['arms']['uvdoc' if passes else 'route']
    return out


def cmd_run(a):
    out = []
    for r, s, c in rows():
        x = page(r, s, c)
        out.append(x)
        print(f"{x['group']:6} {x['key']:11} {x['class']:6} guard {'pass' if x['guard_pass'] else 'held'} "
              f"(own {x['lost_own']}, neighbour {x['lost_neighbour']}) "
              + ' '.join(f"{arm} {v['pass']}/{v['n']}" for arm, v in x['arms'].items()), flush=True)
    (CACHE / 'rows.json').write_text(json.dumps(out))


# ---------------------------------------------------------------- the report
def rate(xs, arm):
    n = sum(x['arms'][arm]['n'] for x in xs)
    return 100 * sum(x['arms'][arm]['pass'] for x in xs) / n if n else float('nan')


def boot(vals, draws=DRAWS, seed=SEED):
    if not vals:
        return None
    rng = random.Random(seed)
    ms = sorted(statistics.mean(rng.choice(vals) for _ in vals) for _ in range(draws))
    return [round(statistics.mean(vals), 1), round(ms[int(0.025 * draws)], 1), round(ms[int(0.975 * draws) - 1], 1)]


def pooled_paired(xs, arm, base='route', draws=DRAWS, seed=SEED):
    """Pooled line pass of arm minus base on the same pages, with a page bootstrap."""
    rng = random.Random(seed)
    d = rate(xs, arm) - rate(xs, base)
    ds = sorted(rate(b, arm) - rate(b, base) for b in ([rng.choice(xs) for _ in xs] for _ in range(draws)))
    return [round(d, 1), round(ds[int(0.025 * draws)], 1), round(ds[int(0.975 * draws) - 1], 1)]


def summary(xs):
    xs = [x for x in xs if x['arms']['route']['n']]
    s = {'pages': len(xs), 'guard_pass': sum(x['guard_pass'] for x in xs),
         'lines': sum(x['arms']['route']['n'] for x in xs)}
    for arm in ('route', 'uvdoc', 'guarded'):
        s[arm] = {'pass': round(rate(xs, arm), 1), 'cut': sum(x['arms'][arm]['cut'] for x in xs),
                  'broken': sum(x['arms'][arm]['broken'] for x in xs),
                  'ends_moved': sum(x['arms'][arm].get('ends_moved', 0) for x in xs)}
    for arm in ('uvdoc', 'guarded'):
        per = [100 * (x['arms'][arm]['pass'] - x['arms']['route']['pass']) / x['arms']['route']['n'] for x in xs]
        s[arm] |= {'pooled_delta': pooled_paired(xs, arm), 'page_delta': boot(per),
                   'better': sum(p > 0 for p in per), 'worse': sum(p < 0 for p in per)}
    ps = [x for x in xs if x['guard_pass']]
    if ps:
        s['passing_only'] = {'pages': len(ps), 'route': round(rate(ps, 'route'), 1),
                             'uvdoc': round(rate(ps, 'uvdoc'), 1), 'pooled_delta': pooled_paired(ps, 'uvdoc')}
    return s


def pair_gap(curved, flat, arm):
    """Curved page minus its flat pair, per pair page rates, on one arm (as place-curved-owner's paired figure)."""
    by = {x['key']: x for x in curved}
    diffs = []
    for f in flat:
        c = by.get(f['pair'])
        if c and c['arms'][arm]['n'] and f['arms'][arm]['n']:
            diffs.append(100 * c['arms'][arm]['pass'] / c['arms'][arm]['n']
                         - 100 * f['arms'][arm]['pass'] / f['arms'][arm]['n'])
    return {'pairs': len(diffs), 'mean': boot(diffs)}


def cmd_report(a):
    xs = json.loads((CACHE / 'rows.json').read_text())
    curved_all = [x for x in xs if x['group'] == 'curved']
    curved = [x for x in curved_all if x['class'] in CURVED_CLASSES]
    keys = {x['key'] for x in curved}
    flat = [x for x in xs if x['group'] == 'flat' and x['pair'] in keys]
    other_curved = [x for x in curved_all if x['class'] not in CURVED_CLASSES]
    out = {'item': 'W46.dewarp-curved-select', 'uvdoc': 'UVDoc 4c9b82b5 best_model.pkl, after Apple quad, CPU, torch-env',
           'sets': {'curved bound or curled': summary(curved), 'their flat pairs': summary(flat),
                    'curved, classed flat': summary(other_curved), 'all 64': summary(xs)},
           'pair_gap': {arm: pair_gap(curved, flat, arm) for arm in ('route', 'guarded', 'uvdoc')},
           'owner_pages': {x['key']: {k: x[k] for k in ('class', 'guard_pass', 'lost_own', 'lost_neighbour')}
                           | {'route_copy': x['route']}
                           | {arm: f"{v['pass']}/{v['n']}" for arm, v in x['arms'].items()}
                           for x in xs if x['key'] in PC.OWNER_PAGES},
           'rows': [{k: v for k, v in x.items() if k != 'arms'}
                    | {'arms': {arm: {kk: vv for kk, vv in v.items() if kk != 'lines'} for arm, v in x['arms'].items()}}
                    for x in xs]}
    (RESULTS / 'dewarp-curved-select.json').write_text(json.dumps(out, indent=1) + '\n')
    print(json.dumps({k: v for k, v in out.items() if k != 'rows'}, indent=1))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    for c in ('prep', 'run', 'report'):
        sub.add_parser(c)
    a = ap.parse_args()
    {'prep': cmd_prep, 'run': cmd_run, 'report': cmd_report}[a.cmd](a)


if __name__ == '__main__':
    main()
