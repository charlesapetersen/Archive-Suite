#!/usr/bin/env python3
"""W46.ocr-time-like-for-like. Every Mac reader, the kraken line readers and PP-DocLayoutV3 timed per page on the same
16 of the owner's pages in one run, at the session's own priority under the heavy lock, model load apart; cloud seconds
a page from the panels' existing call logs. It fills the `time` cells the stage notes mark unmeasured or not like for
like (P11-4, LAY-3).

  python3 ocr_time.py pages                       # the 16 pages, drawn by kind from ocr-truth/pages.tsv
  heavy-run.py run -- python3 ocr_time.py mac     # every Mac arm in turn (resumable: a finished arm is not rerun)
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
  * kraken (blla, PP-OCRv6 medium, the five script specialists): the CLI loads its model each call, so a page's time
    is the marginal one, (call on warm-up + 16 pages - call on the warm-up alone) / 16. A mean, no per-page spread.
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
    """blla, then each line reader on blla's lines: (warm-up + 16 pages) less (warm-up alone), over 16."""
    sys.path.insert(0, str(HERE / 'corpus'))
    import loop_kraken as LK
    import specialists as SP
    res, d = {}, STORE / 'kraken'
    order = [WARM] + ids
    seg = {p: d / 'seg' / f'{p}.xml' for p in order}
    one = {p: d / 'seg1' / f'{p}.xml' for p in [WARM]}
    for x in list(seg.values()) + list(one.values()):
        x.parent.mkdir(parents=True, exist_ok=True)
    blla = ['-x'], 'segment', '-bl', '--text-direction', 'horizontal-lr'
    t1 = kraken_call(blla[0], [(image(WARM), one[WARM])], *blla[1:])
    tn = kraken_call(blla[0], [(image(p), seg[p]) for p in order], *blla[1:])
    res['blla'] = {'one_s': round(t1, 2), 'all_s': round(tn, 2), 'per_page_s': round((tn - t1) / len(ids), 2)}
    for rid, key in KRAKEN_OCR.items():
        m = LK.model() if key is None else SP.model_path(key)
        txt = d / 'text' / rid
        txt1 = d / 'text1' / rid
        txt.mkdir(parents=True, exist_ok=True)
        txt1.mkdir(parents=True, exist_ok=True)
        t1 = kraken_call(['-f', 'page'], [(seg[WARM], txt1 / f'{WARM}.txt')], 'ocr', '-m', str(m))
        tn = kraken_call(['-f', 'page'], [(seg[p], txt / f'{p}.txt') for p in order], 'ocr', '-m', str(m))
        res[rid] = {'one_s': round(t1, 2), 'all_s': round(tn, 2), 'per_page_s': round((tn - t1) / len(ids), 2),
                    'model': Path(m).name}
    return res


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


ARMS = ['vision', *MLX, 'apple-fm-27', 'kraken', 'pp-doclayoutv3']


def mac():
    ids = [x['page'] for x in pages()['pages']]
    for arm in ARMS:
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
    return arm_layout(ids)


# --- report -------------------------------------------------------------------------------------------------------

def cloud():
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
            iv = [(r['t'] - r['wall_s'], r['t']) for r in calls]
            # calls in flight at each call's start: the concurrency the wall was measured under
            flight = [sum(1 for a, b in iv if a <= s < b) for s, _ in iv]
            w = [r['wall_s'] for r in calls]
            out[k] = {'n': len(w), 'median_s': round(S.median(w), 2), 'mean_s': round(S.mean(w), 2),
                      'p90_s': round(sorted(w)[int(0.9 * (len(w) - 1))], 2), 'in_flight_median': S.median(flight),
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
        row(k, arms[k]['pages'], arms[k]['load_s'], arms[k], 'one read a page, greedy')
        mac_rows[k]['peak_gb'] = arms[k]['mlx_peak_gb']
        mac_rows[k]['failed'] = arms[k]['status']
    row('apple-fm-27', arms['apple-fm-27']['pages'], arms['apple-fm-27']['load_s'], arms['apple-fm-27'],
        'one read a page, greedy, 4,096 tokens')
    kr = arms['kraken']
    for rid in KRAKEN_OCR:
        per = round(kr['blla']['per_page_s'] + kr[rid]['per_page_s'], 2)
        row(rid, None, round(kr[rid]['one_s'], 2), kr, f'marginal mean: blla {kr["blla"]["per_page_s"]} s + '
            f'line reading {kr[rid]["per_page_s"]} s a page')
        mac_rows[rid]['per_unit_s'] = per
        mac_rows[rid]['mean'] = True
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
    out = {'tag': TAG, 'machine': machine(), 'pages': pg, 'mac': mac_rows, 'mixed_switch': mixed, 'cloud': cloud(),
           'runs': {a: {'start': arms[a]['before']['t'], 'end': arms[a]['after']['t']} for a in ARMS}}
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
        L.append(f'| {rid} | {r["per_unit_s"]}{" (mean)" if r.get("mean") else ""} | {bk.get("typewritten", "")} | '
                 f'{bk.get("printed", "")} | {bk.get("handwritten", "")} | {bk.get("mixed", "")} | {r["p90_s"] or ""} | '
                 f'{r["load_s"]} | {r["load_avg"][0]}, {r["load_avg"][1]} | {r["note"]} |')
    L += ['', '"printed" includes the two clippings. kraken rows are blla segmentation plus the line reader, a '
          'marginal mean over the 16 (the CLI loads its model every call); their load column is one page\'s whole call.',
          '', '## The mixed switch', '',
          f'On the {x["typed_pages"]} typed and printed pages, Apple Vision {x["vision_typed_median_s"]} s a page and '
          f'LightOnOCR-3 4B {x["reader_typed_median_s"]} s a page, medians; page by page the reader takes '
          f'{x["ratio_median"]} times as long (median of the per-page ratios).', '',
          '## Cloud, wall seconds a call, from the panels\' logs', '',
          'Not a new run: the calls that made the scored readings of the 96 (the last ok call a page, the three '
          'agreement pages apart), as each panel ran them. A call\'s wall includes the queue at the provider and the '
          'calls the panel had in flight; "in flight" is the median count of calls open when each began.', '',
          '| route | n | median s | mean s | 90th pct | in flight | provider | log |', '|---|---|---|---|---|---|---|---|']
    for k, r in c.items():
        L.append(f'| {k} | {r["n"]} | {r["median_s"]} | {r["mean_s"]} | {r["p90_s"]} | {r["in_flight_median"]} | '
                 f'{r["provider"]} | {r["log"]} |')
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
        mac()
    elif cmd == 'report':
        report()
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main()
