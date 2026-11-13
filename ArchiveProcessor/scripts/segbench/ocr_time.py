#!/usr/bin/env python3
"""W46.ocr-time-like-for-like. Every Mac reader, the kraken line readers and PP-DocLayoutV3 timed per page on the same
16 of the owner's pages in one run, at the session's own priority under the heavy lock, model load apart; cloud seconds
a page from the panels' existing call logs. It fills the `time` cells the stage notes mark unmeasured or not like for
like (P11-4, LAY-3).

  python3 ocr_time.py pages                       # the 16 pages, drawn by kind from ocr-truth/pages.tsv
  heavy-run.py run -- python3 ocr_time.py mac [ARM ...]   # every Mac arm in turn, or those named (a finished arm is not rerun)
  python3 ocr_time.py earlier KEY ...             # an MLX reader this run cannot start, from its earlier reading
  python3 ocr_time.py report                      # segbench-results/ocr-time-like-for-like.{json,md}, cloud included

The draw is by the pages' kind tags and a fixed seed, never by a route's output: 5 typewritten, 4 printed (2 of
them clippings, the newspaper pages a layout stage is for), 5 handwritten and both mixed pages, from the scored 96
(the three agreement pages and p081 apart). A warm-up page outside the 16 goes first in every arm.

How each arm is timed, so the figures compare:
  * Apple Vision: segbench-ocr-time (ocr_time_vision.swift), ocr.swift's settings, in one process; each page read
    three times, the median taken. Covers the JPEG decode and the recognition.
  * MLX readers (ocr_mac_local.py's five with a settings row): ocr_mac_local.collect on these pages into scratch, one
    process per reader under run-guarded.sh; its per-page wall (image prepare, prompt and generation), load apart.
  * The macOS 27 on-device model: fm_ocr.swift built here, its per-page `seconds` sidecar (load before the loop).
  * kraken: blla in one kraken process, its model loaded once (a blank page is no baseline for it: blla scales
    every input to one height); each line reader (PP-OCRv6 medium, the five script specialists) one page a call
    on blla's lines, less the median of three calls on a blank page's empty lines (the load).
  * PP-DocLayoutV3: layout.py's load_model and detect (1024 px draft decode), each page three times, median.
The mixed switch reads a typed page with the handwriting reader instead of Vision; its figure is the two readers'
medians on the typed and printed pages here, side by side.

Each arm records the QoS class of its process, the load average before and after, and the time it ran. No text
enters the repo; readings stay in the scratch store. No money.
"""
from __future__ import annotations

import csv
import ctypes
import json
import os
import random
import shutil
import statistics as S
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
TAG = 'W46.ocr-time-like-for-like'
CACHE = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
STORE = CACHE / TAG
PANEL = Path(os.environ.get('OCR_PANEL_CACHE', CACHE / 'ocr-panel-local'))
IMAGES = PANEL / 'images'
PAGES_TSV = CACHE / 'ocr-truth' / 'pages.tsv'
OCRLAB = Path(os.environ.get('OCRLAB', Path.home() / '.local/share/visionocr-ocrlab'))
LAB_PY = OCRLAB / 'venv/bin/python'
GUARD = Path.home() / 'Claude/vision-ocr/ops/ocrlab/run-guarded.sh'
RESULTS = HERE.parents[1] / 'segbench-results'
OUT_JSON = RESULTS / 'ocr-time-like-for-like.json'
OUT_MD = RESULTS / 'ocr-time-like-for-like.md'

SEED = 20261111
DRAW = {'typewritten': 5, 'printed-clipping': 2, 'printed': 2, 'handwritten': 5, 'mixed': 2}
APART = {'p086', 'p094', 'p096', 'p081'}   # agreement-only pages, and the page the headline sets apart
WARM = 'p004'                              # a typed page, one of Vision's reference pages; never among the 16
ROUNDS = 3
# the memory each asks the guard for: its MLX peak in ocr-mac-local-hw.md / ocr-mac-local.md rounded up, as those runs asked (8 GB for the two largest)
NEED_GB = {'xiaomi-ocr-0-bf16': 5, 'paddleocr-vl1.6-bf16': 4, 'lightonocr-3-4b-mlx8': 8, 'qwen3.5-9b-mlx4': 8,
           'qwen3-vl-8b-mlx4': 8}
MLX = list(NEED_GB)
KRAKEN_OCR = {'ppocrv6-kraken-blla': None, 'kraken-german-handwriting': 'german-handwriting', 'kraken-tridis': 'tridis',
              'kraken-catmus-medieval': 'catmus-medieval', 'kraken-greek-minuscule': 'greek-minuscule',
              'kraken-biblia': 'biblia'}
QOS = {0x21: 'user-interactive', 0x19: 'user-initiated', 0x15: 'default', 0x11: 'utility', 0x09: 'background'}

# Cloud: the panels' own logs (ocr_panel.py, ocr_cloud_full.py), wall seconds a call, the 96's originals, ok calls.
CLOUD_LOGS = {'ocr-panel-cloud': ['gemini3.1-pro', 'gemini3.5-flash', 'gemini3.5-flash-lite', 'gemini3.8-flash',
                                  'gpt5.4-mini', 'gpt5.6-luna', 'mistral-large4', 'qwen3-vl-235b', 'qwen3.5-397b',
                                  'qwen3.8-flash'],
              'ocr-panel-local': ['gemini3.1-flash-lite', 'qwen3.6-27b', 'qwen3.6-35b-a3b']}


def qos():
    lib = ctypes.CDLL('/usr/lib/libSystem.dylib')
    v = lib.qos_class_self()
    return QOS.get(v, hex(v))


def stamp():
    return {'qos': qos(), 'load': [round(x, 2) for x in os.getloadavg()], 't': round(time.time(), 1)}


def save(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(obj, indent=1, sort_keys=True))
    tmp.replace(path)


def image(p):
    return IMAGES / f'{p}-original.jpg'


# --- the pages ---------------------------------------------------------------------------------------------------

def draw():
    rows = [r for r in csv.DictReader(PAGES_TSV.open(), delimiter='\t')
            if r['status'] == 'done' and r['page'] not in APART and r['page'] != WARM and image(r['page']).exists()]

    def kind(r):
        return 'printed-clipping' if r['kind'] == 'printed' and r['clippings'] else r['kind']
    rng, out = random.Random(SEED), []
    for k, n in DRAW.items():
        pool = sorted(r['page'] for r in rows if kind(r) == k)
        out += [{'page': p, 'kind': k} for p in sorted(rng.sample(pool, n))]
    return out


def pages():
    f = STORE / 'pages.json'
    if not f.exists():
        save(f, {'seed': SEED, 'warm': WARM, 'pages': draw()})
    return json.loads(f.read_text())


# --- Mac arms -----------------------------------------------------------------------------------------------------

def arm_vision(ids):
    binp = STORE / 'bin' / 'segbench-ocr-time'
    if not binp.exists():
        binp.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['swiftc', '-O', str(HERE / 'ocr_time_vision.swift'), '-o', str(binp)], check=True)
    lst = STORE / 'vision-images.txt'
    lst.write_text('\n'.join(str(image(p)) for p in [WARM] + ids) + '\n')
    got = json.loads(subprocess.run([str(binp), str(lst), str(ROUNDS)], check=True, capture_output=True, text=True).stdout)
    by = {Path(k).name.split('-')[0]: v for k, v in got['pages'].items()}
    return {'load_s': round(got['warmup_s'], 2), 'rounds': ROUNDS,
            'pages': {p: round(S.median(by[p]), 3) for p in ids}, 'runs': {p: [round(x, 3) for x in by[p]] for p in ids},
            'warm_s': round(S.median(by[WARM]), 3)}


MLX_CHILD = r'''
import json, sys
sys.path.insert(0, sys.argv[1])
import ocr_mac_local as M
key, out, ids = sys.argv[2], sys.argv[3], json.loads(sys.argv[4])
from pathlib import Path
byid = {j['page']: j for j in M.jobs()}
M.jobs = lambda: [byid[p] for p in ids]
M.out_dir = lambda k: Path(out)
M.collect(key=key)
'''


def arm_mlx(key, ids):
    out = STORE / 'mlx' / key
    order = [WARM] + ids
    cmd = [str(LAB_PY), '-c', MLX_CHILD, str(HERE), key, str(out), json.dumps(order)]
    subprocess.run([str(GUARD), '--label', f'ocr-time-{key}', '--need-gb', str(NEED_GB[key]), '--'] + cmd, check=True)
    meta = {p: json.loads((out / f'{p}-original.json').read_text())['meta'] for p in order}
    return {'load_s': meta[ids[0]]['load_s'], 'warm_s': meta[WARM]['wall_s'],
            'pages': {p: meta[p]['wall_s'] for p in ids},
            'status': {p: meta[p]['status'] for p in ids if meta[p]['status'] != 'ok'},
            'tokens': {p: meta[p]['completion_tokens'] for p in ids},
            'mlx_peak_gb': max(meta[p]['mlx_peak_gb'] for p in ids)}


def arm_fm(ids):
    binp = STORE / 'bin' / 'segbench-fm-ocr'
    if not binp.exists():
        binp.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['swiftc', '-parse-as-library', '-O', str(HERE / 'fm_ocr.swift'), '-o', str(binp)], check=True)
    out = STORE / 'fm'
    shutil.rmtree(out, ignore_errors=True)   # this arm's own scratch: a resumed call would skip pages and lose the wall
    jobs = STORE / 'fm-jobs.tsv'
    jobs.write_text(''.join(f'{image(p)}\t{out / (p + ".txt")}\n' for p in [WARM] + ids))
    t0 = time.monotonic()
    rc = subprocess.run([str(binp), str(jobs)]).returncode
    if rc not in (0, 1):   # 1: a page failed (a loop to the token cap), recorded in its sidecar
        raise subprocess.CalledProcessError(rc, binp)
    wall = time.monotonic() - t0
    rec = {p: json.loads((out / f'{p}.txt.json').read_text()) for p in [WARM] + ids}
    secs = {p: round(rec[p]['seconds'], 2) for p in ids}
    return {'warm_s': round(rec[WARM]['seconds'], 2), 'pages': secs,
            'load_s': round(wall - sum(r['seconds'] for r in rec.values()), 2),
            'failed': [p for p in ids if not rec[p].get('ok', True)]}


def kraken_call(opts, pairs, *cmd):
    sys.path.insert(0, str(HERE / 'corpus'))
    import specialists as SP
    t = time.monotonic()
    SP.kraken(opts, pairs, *cmd)
    return time.monotonic() - t


def arm_kraken(ids):
    """blla, then each line reader on blla's lines, one page a call (a many-page blla call grew past the heavy lock's
    10.8 GB limit). The CLI loads its model every call, so a page's time is its call less the load: the median of
    three calls on a blank 256 px image, which loads the model and finds nothing to do."""
    sys.path.insert(0, str(HERE / 'corpus'))
    import loop_kraken as LK
    import specialists as SP
    from PIL import Image
    res, d = {}, STORE / 'kraken'
    blank = d / 'blank.jpg'
    d.mkdir(parents=True, exist_ok=True)
    Image.new('RGB', (256, 256), 'white').save(blank)
    seg = {p: d / 'seg' / f'{p}.xml' for p in [WARM] + ids}
    seg0 = [d / 'seg0' / f'blank{k}.xml' for k in range(3)]
    for x in list(seg.values()) + seg0:
        x.parent.mkdir(parents=True, exist_ok=True)
        x.unlink(missing_ok=True)
    blla = ['-x'], 'segment', '-bl', '--text-direction', 'horizontal-lr'

    def per_page(calls, load):
        return {p: round(max(t - load, 0.0), 2) for p, t in calls.items()}
    load = S.median(kraken_call(blla[0], [(blank, x)], *blla[1:]) for x in seg0)
    calls = {p: kraken_call(blla[0], [(image(p), seg[p])], *blla[1:]) for p in [WARM] + ids}
    res['blla'] = {'load_s': round(load, 2), 'warm_s': round(calls[WARM], 2),
                   'pages': per_page({p: calls[p] for p in ids}, load)}
    for rid, key in KRAKEN_OCR.items():
        m = LK.model() if key is None else SP.model_path(key)
        txt = d / 'text' / rid
        txt.mkdir(parents=True, exist_ok=True)
        load = S.median(kraken_call(['-f', 'page'], [(x, txt / f'{x.stem}.txt')], 'ocr', '-m', str(m)) for x in seg0)
        calls = {p: kraken_call(['-f', 'page'], [(seg[p], txt / f'{p}.txt')], 'ocr', '-m', str(m)) for p in [WARM] + ids}
        res[rid] = {'load_s': round(load, 2), 'warm_s': round(calls[WARM], 2),
                    'pages': per_page({p: calls[p] for p in ids}, load), 'model': Path(m).name}
    return res


BLLA_CHILD = r'''
import json, statistics as S, sys, time
from importlib import resources
from PIL import Image
from kraken import blla
from kraken.lib import vgsl
paths = json.loads(sys.argv[1])
t0 = time.time(); model = vgsl.TorchVGSLModel.load_model(resources.files('kraken').joinpath('blla.mlmodel')); load = time.time() - t0
def one(p):
    t = time.time(); seg = blla.segment(Image.open(p), text_direction='horizontal-lr', model=model)
    return time.time() - t, len(seg.lines)
w, _ = one(paths[0])
pages, lines = {}, {}
for p in paths[1:]:
    pages[p], lines[p] = one(p)
print(json.dumps({"load_s": round(load, 2), "warm_s": round(w, 2), "pages": {k: round(v, 2) for k, v in pages.items()},
                  "lines": lines}))
'''


def arm_blla(ids):
    """blla alone, in one kraken process with its model loaded once: the CLI's blank-page baseline does not isolate
    blla's load, since blla scales every input to the same height and so runs its network on a blank page too."""
    sys.path.insert(0, str(HERE / 'corpus'))
    import specialists as SP
    py = SP.KRAKEN.with_name('python')
    cmd = [str(py), '-c', BLLA_CHILD, json.dumps([str(image(p)) for p in [WARM] + ids])]
    r = subprocess.run([str(GUARD), '--label', 'ocr-time-blla', '--need-gb', '4', '--'] + cmd,
                       check=True, capture_output=True, text=True)
    got = json.loads(r.stdout.strip().splitlines()[-1])
    got['pages'] = {Path(k).name.split('-')[0]: v for k, v in got['pages'].items()}
    got['lines'] = {Path(k).name.split('-')[0]: v for k, v in got['lines'].items()}
    return got


LAYOUT_CHILD = r'''
import json, resource, statistics as S, sys, time
sys.path.insert(0, sys.argv[1])
import layout as L
from PIL import Image
import mlx.core as mx
paths, rounds = json.loads(sys.argv[2]), int(sys.argv[3])
t0 = time.time(); model = L.load_model(); load = time.time() - t0
def one(p):
    t = time.time(); im = Image.open(p); im.draft("RGB", (1024, 1024)); r = model.detect(im.convert("RGB"))
    return time.time() - t, len(r)
w, _ = one(paths[0])
runs, regions = {}, {}
for _ in range(rounds):
    for p in paths[1:]:
        s, n = one(p); runs.setdefault(p, []).append(round(s, 3)); regions[p] = n
print(json.dumps({"load_s": round(load, 2), "warm_s": round(w, 3), "runs": runs, "regions": regions,
                  "mlx_peak_gb": round(mx.get_peak_memory() / 2**30, 2),
                  "maxrss_mb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**20)}))
'''


def arm_layout(ids):
    paths = [str(image(p)) for p in [WARM] + ids]
    cmd = [str(LAB_PY), '-c', LAYOUT_CHILD, str(HERE), json.dumps(paths), str(ROUNDS)]
    r = subprocess.run([str(GUARD), '--label', 'ocr-time-layout', '--need-gb', '2', '--'] + cmd,
                       check=True, capture_output=True, text=True)
    got = json.loads(r.stdout.strip().splitlines()[-1])
    by = {Path(k).name.split('-')[0]: v for k, v in got.pop('runs').items()}
    got['regions'] = {Path(k).name.split('-')[0]: v for k, v in got['regions'].items()}
    got['pages'] = {p: round(S.median(by[p]), 3) for p in ids}
    got['runs'] = by
    return got


ARMS = ['vision', *MLX, 'apple-fm-27', 'kraken', 'kraken-blla', 'pp-doclayoutv3']
FM_EARLIER = CACHE / 'W46.r1-foundation' / 'ocr96'
EARLIER_DIR = PANEL / 'local'   # ocr_mac_local.py's own readings of the 96 (W41.mac-local-*, W46.ocr-new-open)


def earlier_meta(key, ids):
    return {p: json.loads((EARLIER_DIR / key / f'{p}-original.json').read_text())['meta'] for p in ids}


def arm_earlier(key, ids):
    """An MLX reader this run could not start (its weights since removed from the model cache, or the guard short of
    memory) taken from its own earlier reading of these pages: same pages, settings, machine and timer, load apart.
    The re-timed readers' agreement with their earlier readings (report) is what makes it comparable."""
    meta = earlier_meta(key, ids)
    return {'earlier': True, 'load_s': meta[ids[0]]['load_s'], 'warm_s': None,
            'pages': {p: meta[p]['wall_s'] for p in ids},
            'status': {p: meta[p]['status'] for p in ids if meta[p]['status'] != 'ok'},
            'tokens': {p: meta[p]['completion_tokens'] for p in ids},
            'mlx_peak_gb': max(meta[p]['mlx_peak_gb'] for p in ids),
            'read_on': time.strftime('%Y-%m-%d', time.localtime(max(meta[p]['t'] for p in ids)))}


def agreement(arms, ids):
    """For each MLX reader timed in this run: this run's wall over its earlier reading's, page by page, where both
    generated the same number of tokens."""
    out = {}
    for k in MLX:
        a = arms.get(k)
        if not a or a.get('earlier'):
            continue
        old = earlier_meta(k, ids)
        r = [a['pages'][p] / old[p]['wall_s'] for p in ids if a['tokens'][p] == old[p]['completion_tokens']]
        out[k] = {'pages_same_tokens': len(r), 'ratio_median': round(S.median(r), 3),
                  'ratio_min': round(min(r), 3), 'ratio_max': round(max(r), 3)}
    fm = arms.get('apple-fm-27')
    if fm and FM_EARLIER.exists():   # W46.r1-foundation's reading of the 96, sidecars beside its texts
        old = {p: json.loads((FM_EARLIER / f'{p}-original.txt.json').read_text()) for p in ids}
        new = {p: json.loads((STORE / 'fm' / f'{p}.txt.json').read_text()) for p in ids}
        r = [fm['pages'][p] / old[p]['seconds'] for p in ids if old[p].get('output_tokens') == new[p].get('output_tokens')]
        out['apple-fm-27'] = {'pages_same_tokens': len(r), 'ratio_median': round(S.median(r), 3),
                              'ratio_min': round(min(r), 3), 'ratio_max': round(max(r), 3)}
    return out


def mac(only=()):
    ids = [x['page'] for x in pages()['pages']]
    for arm in only or ARMS:
        f = STORE / 'arms' / f'{arm}.json'
        if f.exists():
            print(f'{arm}: done already')
            continue
        print(f'{arm}: timing {len(ids)} pages', flush=True)
        before = stamp()
        try:
            r = run_arm(arm, ids)
        except subprocess.CalledProcessError as e:
            if e.returncode != 75:
                raise
            print(f'{arm}: the guard refused to start it (memory); left for the next run', flush=True)
            continue
        save(f, {'arm': arm, 'before': before, 'after': stamp(), **r})
        print(f'{arm}: saved', flush=True)


def run_arm(arm, ids):
    if arm == 'vision':
        return arm_vision(ids)
    if arm in MLX:
        return arm_mlx(arm, ids)
    if arm == 'apple-fm-27':
        return arm_fm(ids)
    if arm == 'kraken':
        return arm_kraken(ids)
    if arm == 'kraken-blla':
        return arm_blla(ids)
    return arm_layout(ids)


# --- report -------------------------------------------------------------------------------------------------------

def in_flight(calls):
    """For each call (`t` its end, `wall_s` its length), how many calls were open when it began, itself included:
    the concurrency its wall was measured under."""
    iv = [(r['t'] - r['wall_s'], r['t']) for r in calls]
    return [sum(1 for a, b in iv if a <= s < b) for s, _ in iv]


def cloud(ids):
    """Each cloud route's wall a call on the 16 pages the Mac arms read (the table's figure) and on all of the 96."""
    out = {}
    for log, keys in CLOUD_LOGS.items():
        rows = [json.loads(line) for line in (CACHE / log / 'calls.jsonl').open()]
        for k in keys:
            last = {}
            for r in rows:
                if (r.get('key') == k and r.get('status') == 'ok' and r.get('scale') == 'original'
                        and not r.get('pilot') and r.get('wall_s') and r['page'] not in {'p086', 'p094', 'p096'}):
                    last[r['job']] = r      # the call whose reading was kept: the last ok one
            calls = sorted(last.values(), key=lambda r: r['t'])
            flight = in_flight(calls)
            w = [r['wall_s'] for r in calls]
            w16 = [r['wall_s'] for r in calls if r['page'] in ids]
            out[k] = {'n16': len(w16), 'median_s': round(S.median(w16), 2), 'n': len(w), 'median96_s': round(S.median(w), 2),
                      'mean_s': round(S.mean(w), 2), 'p90_s': round(sorted(w)[int(0.9 * (len(w) - 1))], 2),
                      'in_flight_median': round(S.median(flight), 1),
                      'provider': calls[0].get('provider_slug'), 'log': f'{log}/calls.jsonl'}
    return out


def med(d):
    return round(S.median(d.values()), 2)


def report():
    pg = pages()
    kinds = {x['page']: x['kind'] for x in pg['pages']}
    ids = list(kinds)
    arms = {a: json.loads((STORE / 'arms' / f'{a}.json').read_text()) for a in ARMS
            if (STORE / 'arms' / f'{a}.json').exists()}
    missing = [a for a in ARMS if a not in arms]
    if missing:
        raise SystemExit(f'arms not timed yet: {missing}')
    typed = [p for p in ids if kinds[p] in ('typewritten', 'printed', 'printed-clipping')]
    mac_rows = {}

    def row(rid, per_page, load, a, note=''):
        r = {'per_unit_s': med(per_page) if per_page else None, 'load_s': load, 'n': len(per_page) if per_page else 16,
             'by_kind': {k: round(S.median([per_page[p] for p in ids if kinds[p].startswith(k)]), 2)
                         for k in ('typewritten', 'printed', 'handwritten', 'mixed')} if per_page else None,
             'p90_s': round(sorted(per_page.values())[int(0.9 * (len(per_page) - 1))], 2) if per_page else None,
             'qos': a['before']['qos'], 'load_avg': [a['before']['load'][0], a['after']['load'][0]], 'note': note}
        mac_rows[rid] = r
    row('apple-vision', arms['vision']['pages'], arms['vision']['load_s'], arms['vision'],
        f'median of {ROUNDS} reads a page, one process')
    for k in MLX:
        e = arms[k].get('earlier')
        row(k, arms[k]['pages'], arms[k]['load_s'], arms[k],
            f'earlier reading of these pages ({arms[k]["read_on"]}), not re-timed here' if e else 'one read a page, greedy')
        if e:
            mac_rows[k]['qos'] = None
            mac_rows[k]['load_avg'] = None
            mac_rows[k]['earlier'] = arms[k]['read_on']
        mac_rows[k]['peak_gb'] = arms[k]['mlx_peak_gb']
        mac_rows[k]['failed'] = arms[k]['status']
    row('apple-fm-27', arms['apple-fm-27']['pages'], arms['apple-fm-27']['load_s'], arms['apple-fm-27'],
        'one read a page, greedy, 4,096 tokens')
    kr, bl = arms['kraken'], arms['kraken-blla']
    for rid in KRAKEN_OCR:
        both = {p: round(bl['pages'][p] + kr[rid]['pages'][p], 2) for p in ids}
        row(rid, both, round(bl['load_s'] + kr[rid]['load_s'], 2), kr,
            f'blla {med(bl["pages"])} s (in one process, its model loaded once) + line reading {med(kr[rid]["pages"])} s '
            f'(one page a call less a call on a blank page), medians')
    lay = arms['pp-doclayoutv3']
    row('pp-doclayoutv3', lay['pages'], lay['load_s'], lay, f'median of {ROUNDS} detections a page, 1024 px draft')
    mac_rows['pp-doclayoutv3']['peak_gb'] = lay['mlx_peak_gb']
    mac_rows['pp-doclayoutv3']['maxrss_mb'] = lay['maxrss_mb']
    v = arms['vision']['pages']
    lo = arms['lightonocr-3-4b-mlx8']['pages']
    mixed = {'reader': 'lightonocr-3-4b-mlx8', 'typed_pages': len(typed),
             'vision_typed_median_s': round(S.median(v[p] for p in typed), 2),
             'reader_typed_median_s': round(S.median(lo[p] for p in typed), 2),
             'ratio_median': round(S.median(lo[p] / v[p] for p in typed), 1)}
    out = {'tag': TAG, 'machine': machine(), 'pages': pg, 'mac': mac_rows, 'mixed_switch': mixed, 'cloud': cloud(ids),
           'agreement_with_earlier': agreement(arms, ids),
           'runs': {a: {'start': arms[a]['before']['t'], 'end': arms[a]['after']['t']} for a in ARMS
                    if not arms[a].get('earlier')}}
    save(OUT_JSON, out)
    OUT_MD.write_text(markdown(out))
    print(f'wrote {OUT_JSON.name} and {OUT_MD.name}')


def machine():
    def sysctl(k):
        return subprocess.run(['sysctl', '-n', k], capture_output=True, text=True).stdout.strip()
    return {'cpu': sysctl('machdep.cpu.brand_string'), 'memory_gb': round(int(sysctl('hw.memsize')) / 2**30),
            'os': subprocess.run(['sw_vers', '-productVersion'], capture_output=True, text=True).stdout.strip()}


def markdown(o):
    m, c, x = o['mac'], o['cloud'], o['mixed_switch']
    when = time.strftime('%Y-%m-%d', time.localtime(min(r['start'] for r in o['runs'].values())))
    L = [f'# Every Mac reader, the detectors and the cloud routes timed like for like ({TAG})', '',
         f'{o["machine"]["cpu"]}, {o["machine"]["memory_gb"]} GB, macOS {o["machine"]["os"]}, {when}. '
         f'The same 16 of the owner\'s pages for every Mac arm, one arm after another under the heavy lock, at the '
         f'session\'s own priority (QoS {m["apple-vision"]["qos"]}, which runs at full speed: a CPU loop takes 1.25 s '
         f'at utility and at user-initiated alike, 3.88 s at background). Model load is kept apart, and a warm-up page '
         f'({o["pages"]["warm"]}) goes first in every arm. Drawn by kind tag and seed {o["pages"]["seed"]}: '
         + ', '.join(f'{p["page"]} {p["kind"]}' for p in o['pages']['pages']) + '.', '',
         '## Mac, seconds a page', '',
         '| route | median s a page | typewritten | printed | handwritten | mixed | 90th pct | load s | load average before, after | how |',
         '|---|---|---|---|---|---|---|---|---|---|']
    for rid, r in m.items():
        bk = r['by_kind'] or {}
        L.append(f'| {rid} | {r["per_unit_s"]} | {bk.get("typewritten", "")} | '
                 f'{bk.get("printed", "")} | {bk.get("handwritten", "")} | {bk.get("mixed", "")} | {r["p90_s"] or ""} | '
                 f'{r["load_s"]}{" (first call\'s warm-up in a fresh process, not a model load)" if rid == "apple-vision" else ""} | {", ".join(map(str, r["load_avg"])) if r["load_avg"] else "-"} | {r["note"]} |')
    L += ['', '"printed" includes the two clippings. kraken rows are blla segmentation plus the line reader on its '
          'lines, page by page; the load column is both models\' load. Apple Vision\'s load is the first call\'s warm-up in '
          'a fresh process, not a model load, and no row depends on it.',
          '', '### The earlier Mac seconds stand', '',
          'The readers timed again here took, page by page, this much of their earlier readings\' wall on the same '
          'pages (where both generated the same tokens): '
          + '; '.join(f'{k} {a["ratio_median"]} (range {a["ratio_min"]} to {a["ratio_max"]}, {a["pages_same_tokens"]} pages)'
                      for k, a in o['agreement_with_earlier'].items())
          + '. So the earlier ocr-mac-local and r1-foundation seconds were not slowed by the engine sessions they ran in, '
          'and a reader this run could not start is taken from its earlier reading of the same pages: '
          + (', '.join(f'{k} (read {r["earlier"]})' for k, r in m.items() if r.get('earlier')) or 'none') + '.',
          '', '## The mixed switch', '',
          f'On the {x["typed_pages"]} typed and printed pages, Apple Vision {x["vision_typed_median_s"]} s a page and '
          f'LightOnOCR-3 4B {x["reader_typed_median_s"]} s a page, medians; page by page the reader takes '
          f'{x["ratio_median"]} times as long (median of the per-page ratios).', '',
          '## Cloud, wall seconds a call, from the panels\' logs', '',
          'Not a new run: the calls that made the scored readings of the 96 (the last ok call a page, the three '
          'agreement pages apart), as each panel ran them. The figure the settings table takes is the median on the 16 '
          'pages the Mac arms read, so the page mix matches; the 96 columns are every scored page. A call\'s wall '
          'includes the queue at the provider and the calls the panel had in flight; "in flight" is the median count '
          'of calls already running when each began, itself included.', '',
          '| route | median s, the 16 | n | median s, the 96 | mean s, the 96 | 90th pct, the 96 | n | in flight | provider | log |',
          '|---|---|---|---|---|---|---|---|---|---|']
    for k, r in c.items():
        L.append(f'| {k} | {r["median_s"]} | {r["n16"]} | {r["median96_s"]} | {r["mean_s"]} | {r["p90_s"]} | {r["n"]} | '
                 f'{r["in_flight_median"]:g} | {r["provider"]} | {r["log"]} |')
    L += ['', 'Gemini 3.7 Flash on the gateway keeps its own figure (`gemini37-vs-38.md`, 9.43 s median on the 96) and '
          'Claude Sonnet 5.5 its mean through `claude -p` (`ocr-panel-cloud.md`, 10 s, three at once). Mistral OCR 4.1 '
          'logged no time and stays unmeasured.', '',
          '## Measurement card', '',
          '- **Truth.** None: time, not accuracy. Nothing here is scored.',
          '- **Selection.** By the pages\' kind tags (`ocr-truth/pages.tsv`) and a fixed seed; no route\'s output chose '
          'a page.',
          '- **Comparison.** One machine, one session, the same pages and images for every Mac arm, back to back, '
          'each reader at the settings it was scored with; load apart, a warm-up page first. Cloud figures are the '
          'scoring runs\' calls and are not like for like with each other in concurrency or time of day.',
          '- **Page mix.** The 16 hold more handwritten and mixed pages than the 96 and fewer long ones, so a median '
          'here is not the 96\'s (the on-device model: 4.0 s here, 9.5 s on the 96, on the same per-page times). Compare '
          'routes within this file, not against a 96-page median elsewhere.',
          f'- **Noise.** n 16 pages a Mac arm. Vision and PP-DocLayoutV3 read each page {ROUNDS} times (the per-page '
          'runs are in the JSON); the MLX readers are greedy and read once. The Mac was shared with other sessions\' '
          'light work: the load average before and after each arm is in the table.',
          '- **Scope.** One M3 Pro 18 GB laptop. Seconds on a 16, 32 or 64 GB Mac, on photographed newspapers, and with '
          'other work running at once are not measured. Mixed pages are 2 of the 16.', '']
    return '\n'.join(L)


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'pages':
        print(json.dumps(pages(), indent=1))
    elif cmd == 'mac':
        mac(sys.argv[2:])
    elif cmd == 'earlier':
        ids = [x['page'] for x in pages()['pages']]
        for key in sys.argv[2:]:
            save(STORE / 'arms' / f'{key}.json', {'arm': key, 'before': stamp(), 'after': stamp(), **arm_earlier(key, ids)})
            print(f'{key}: taken from its earlier reading')
    elif cmd == 'report':
        report()
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main()
