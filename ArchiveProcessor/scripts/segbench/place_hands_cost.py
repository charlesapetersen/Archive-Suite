"""W46.place-hands-cost — the hand placement route's memory and time (05-placement.md §8).

The shipped hand route, `hand-blla-ctc`, timed page by page in one process, as the Processor would run it: kraken
blla lines, McCATMuS recognition of each line, the reading force-aligned by both matchers (one-to-one and a span of
up to 8), the `conf` pick between them (place_hands.place_ctc, unchanged), and the lab writer
(place_functional `oracle --fit`) writing the picked words onto the page as a PDF. Pages: the owner's 20 audited
hand pages (place_hands.keep). Reading: Qwen3.6-27B's saved one, the row's non-drafter headline reading.

Each run records per page the seconds of blla, recognition, alignment (both matchers and the pick) and the writer,
the process's peak resident memory after each stage (getrusage), the writer's own peak (a child process), the two
model loads, torch's thread count; the parent wraps the worker in /usr/bin/time -l for the whole process's peak
memory footprint (the figure macOS's memory pressure counts). Parity: each page's blla line count and the conf
pick's confidence against W46.place-hands' saved runs, so the timed route is the scored one.

Usage (system python3; the worker runs itself under the kraken venv, through the heavy lock):
  python3 ops/autonomous/heavy-run.py run -- python3 place_hands_cost.py run cpu1 [--device cpu|mps] [--empty-cache]
  python3 ops/autonomous/heavy-run.py run -- python3 place_hands_cost.py run cpu-x3 --repeat 3
  python3 place_hands_cost.py report --timing cpu1 cpu2 --plateau cpu-x3 --mps mps1   # place-hands-cost.json and .md
Scratch: ~/Library/Caches/ArchiveSuiteRehearsal/place-hands/{lines,hyp,pdf}/*cost*, cost/ (the runs' raw records).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import resource
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import place_hands as P  # noqa: E402

READING = 'qwen3.6-27b'
MODEL = 'mccatmus'
COST = P.CACHE / 'cost'
OUT = P.RESULTS / 'place-hands-cost'
GB = 1024 ** 3


def maxrss_gb(who=resource.RUSAGE_SELF):
    return resource.getrusage(who).ru_maxrss / GB   # bytes on macOS


ABORT_GB = float(os.environ.get('PHC_ABORT_GB', 7.0))   # the worker stops itself past this footprint, below the
# heavy lock's 60% guard (10.8 GB here), and says where


def footprint(pid=None):
    """phys_footprint in bytes (rusage_info_v0 field 7, as the heavy lock reads it): the memory macOS's pressure counts."""
    import ctypes
    import struct
    buf = ctypes.create_string_buffer(256)
    if ctypes.CDLL('/usr/lib/libproc.dylib').proc_pid_rusage(pid or os.getpid(), 0, buf) != 0:
        return 0
    return struct.unpack_from('<Q', buf.raw, 16 + 7 * 8)[0]


class Sampler:
    """The worker's own footprint every 0.1 s: the peak within each stage, the progress on disk (a killed run still
    says which page and stage it was in), and a self-stop past ABORT_GB."""

    def __init__(self, progress: Path):
        self.progress, self.name, self.peak, self.all = progress, 'start', 0, 0
        progress.parent.mkdir(parents=True, exist_ok=True)
        progress.write_text('')
        threading.Thread(target=self.loop, daemon=True).start()

    def loop(self):
        while True:
            b = footprint()
            self.peak, self.all = max(self.peak, b), max(self.all, b)
            if b > ABORT_GB * GB:
                self.log(f'ABORT footprint {b / GB:.2f} GB in {self.name}')
                os._exit(3)
            time.sleep(0.1)

    def log(self, text):
        with self.progress.open('a') as f:
            f.write(f'{time.strftime("%H:%M:%S")} {text}\n')

    def stage(self, name):
        """Start a stage; returns the peak footprint (GB) of the one that ended."""
        b = footprint()
        ended = max(self.peak, b) / GB
        self.log(f'{name} (footprint {b / GB:.2f} GB, previous stage peak {ended:.2f} GB)')
        self.name, self.peak = name, b
        return ended


def todo():
    only = set(filter(None, os.environ.get('PHC_PAGES', '').split(',')))
    return [t for t in P.pages() if t['group'] == 'owner-hand' and P.keep(t) and (not only or t['page'] in only)]


def worker(tag, device, empty_cache, repeat=1):
    import torch
    from kraken.configs import SegmentationInferenceConfig
    from kraken.kraken import SEGMENTATION_DEFAULT_MODEL
    from kraken.lib.util import open_image
    from kraken.tasks import SegmentationTaskModel
    rec = {'tag': tag, 'reading': READING, 'model': MODEL, 'torch_threads': torch.get_num_threads(),
           'device': device, 'empty_cache': empty_cache, 'repeat': repeat,
           'rss_start_gb': maxrss_gb(), 'pages': []}
    smp = Sampler(COST / f'{tag}.progress')
    smp.stage('load blla')
    t0 = time.time()
    seg_model = SegmentationTaskModel.load_model(SEGMENTATION_DEFAULT_MODEL)
    seg_cfg = SegmentationInferenceConfig(accelerator=device)
    rec['blla_load_s'], rec['rss_after_blla_load_gb'] = time.time() - t0, maxrss_gb()
    smp.stage('load ctc')
    t0 = time.time()
    loaded = P.load_ctc(MODEL, device)
    rec['ctc_load_s'], rec['rss_after_ctc_load_gb'] = time.time() - t0, maxrss_gb()
    det = f'blla-cost-{tag}'
    for rep, t in [(rep, t) for rep in range(repeat) for t in todo()]:
        k, row = P.key(t), {'page': t['page'], 'rep': rep}
        ended = smp.stage(f"{t['page']} blla")
        rec.setdefault('loads_peak_fp_gb', ended)
        t0 = time.time()
        res = seg_model.predict(im=open_image(t['image']), config=seg_cfg)
        lines = [{'baseline': ln.baseline, 'boundary': ln.boundary} for ln in res.lines if ln.baseline]
        row['blla_s'] = time.time() - t0
        P.save(P.CACHE / 'lines' / det / f'{k}.json', P.normalise(lines, t['width'], t['height'], row['blla_s']))
        row['rss_after_blla_gb'] = maxrss_gb()
        row['blla_fp_gb'] = smp.stage(f"{t['page']} align")
        t0 = time.time()
        P.place_ctc(MODEL, [t], det, [READING], loaded)
        row['align_total_s'] = time.time() - t0
        hyp_file = P.CACHE / 'hyp' / f'{det}.ctc-{MODEL}-conf.{READING}' / f'{k}.json'
        meta = json.loads(hyp_file.read_text())['meta']
        row['recognise_s'] = meta['recognise_s']
        row['match_align_s'] = row['align_total_s'] - meta['recognise_s']
        row['rss_after_align_gb'] = maxrss_gb()
        row['align_fp_gb'] = smp.stage(f"{t['page']} writer")
        pdf = P.CACHE / 'pdf' / f'cost-{tag}' / f'{k}.pdf'
        pdf.parent.mkdir(parents=True, exist_ok=True)
        t0 = time.time()
        subprocess.run([str(P.FUNCTIONAL_BIN), 'oracle', str(P.place_truth.STORE / f'{k}.json'), str(pdf),
                        '--words', str(hyp_file), '--fit'], check=True, stdout=subprocess.DEVNULL)
        row['writer_s'] = time.time() - t0
        row['writer_maxrss_gb'] = maxrss_gb(resource.RUSAGE_CHILDREN)   # the largest child so far
        if empty_cache and device == 'mps':
            torch.mps.empty_cache()
        smp.stage(f"{t['page']} done")
        row['total_s'] = row['blla_s'] + row['align_total_s'] + row['writer_s']
        # parity with W46.place-hands' saved runs
        saved_lines = P.CACHE / 'lines' / 'blla' / f'{k}.json'
        saved_hyp = P.CACHE / 'hyp' / f'blla.ctc-{MODEL}-conf.{READING}' / f'{k}.json'
        row['lines'] = len(lines)
        row['saved_lines'] = len(json.loads(saved_lines.read_text())['lines']) if saved_lines.exists() else None
        row['ctc_conf'] = meta['ctc_conf']
        row['span'] = meta['span']
        row['saved_ctc_conf'] = json.loads(saved_hyp.read_text())['meta']['ctc_conf'] if saved_hyp.exists() else None
        rec['pages'].append(row)
        print(f"{t['page']} blla {row['blla_s']:.1f}s align {row['align_total_s']:.1f}s writer {row['writer_s']:.2f}s "
              f"footprint blla {row['blla_fp_gb']:.2f} align {row['align_fp_gb']:.2f} GB", flush=True)
    rec['rss_peak_gb'], rec['fp_peak_gb'] = maxrss_gb(), smp.all / GB
    P.save(COST / f'{tag}.worker.json', rec)


def run(tag, device, empty_cache, repeat=1, pages=None):
    P.functional_bin()
    if pages:
        os.environ['PHC_PAGES'] = pages
    env = dict(os.environ, PLACE_HANDS_WORKER='cost', PHC_DEVICE=device, PHC_EMPTY='1' if empty_cache else '',
               PHC_REPEAT=str(repeat))
    t0 = time.time()
    p = subprocess.run(['/usr/bin/time', '-l', str(P.VENV['ctc']), __file__, 'run', tag], env=env,
                       stderr=subprocess.PIPE, text=True)
    wall = time.time() - t0
    sys.stderr.write(p.stderr[-3000:])
    if p.returncode:
        sys.exit(p.returncode)
    rec = json.loads((COST / f'{tag}.worker.json').read_text())

    def stat(label):
        m = re.search(r'^\s*(\d+)\s+' + re.escape(label) + r'\s*$', p.stderr, re.M)
        return int(m.group(1)) if m else None
    rec['process_wall_s'] = wall
    rec['time_l'] = {'maximum_resident_set_size_gb': (stat('maximum resident set size') or 0) / GB,
                     'peak_memory_footprint_gb': (stat('peak memory footprint') or 0) / GB}
    P.save(COST / f'{tag}.json', rec)
    print(json.dumps(rec['time_l']), f'wall {wall:.0f}s')


def stats(v):
    return {'median': statistics.median(v), 'mean': statistics.mean(v), 'max': max(v), 'min': min(v), 'sum': sum(v)}


def summarise(rec):
    ps = rec['pages']
    col = lambda k: [r[k] for r in ps]
    out = {'tag': rec['tag'], 'device': rec['device'], 'empty_cache': rec['empty_cache'], 'repeat': rec.get('repeat', 1),
           'pages': len(ps), 'torch_threads': rec['torch_threads'],
           'blla_load_s': rec['blla_load_s'], 'ctc_load_s': rec['ctc_load_s'],
           'peak_footprint_gb': rec['time_l']['peak_memory_footprint_gb'],
           'peak_rss_gb': rec['time_l']['maximum_resident_set_size_gb'],
           'writer_peak_rss_gb': max(col('writer_maxrss_gb')),
           'process_wall_s': rec['process_wall_s'],
           'lines_match_saved': sum(r['lines'] == r['saved_lines'] for r in ps),
           'conf_match_saved': sum(r['saved_ctc_conf'] is not None and abs(r['ctc_conf'] - r['saved_ctc_conf']) < 1e-3
                                   for r in ps)}
    for k in ('blla_s', 'recognise_s', 'match_align_s', 'align_total_s', 'writer_s', 'total_s'):
        out[k] = stats(col(k))
    reps = sorted({r.get('rep', 0) for r in ps})
    out['by_rep'] = [{'rep': n, 'peak_fp_gb': max(max(r['blla_fp_gb'], r['align_fp_gb']) for r in ps if r.get('rep', 0) == n),
                      'total_s_median': statistics.median(r['total_s'] for r in ps if r.get('rep', 0) == n)}
                     for n in reps]
    return out


def report(timing, plateau, mps):
    load = lambda t: json.loads((COST / f'{t}.json').read_text())
    T = [load(t) for t in timing]
    by_page = {}
    for r in T:
        for row in r['pages']:
            by_page.setdefault(row['page'], []).append(row)
    pooled = [row['total_s'] for r in T for row in r['pages']]
    diffs = [abs(rows[0]['total_s'] - rows[1]['total_s']) for rows in by_page.values() if len(rows) > 1]
    runs = [summarise(r) for r in T] + [summarise(load(t)) for t in plateau + mps]
    cpu = [s for s in runs if s['device'] == 'cpu']
    res = {'item': 'W46.place-hands-cost', 'route': 'hand-blla-ctc', 'reading': READING, 'machine': machine(),
           'gb': 'GiB, 2^30 bytes, as macOS reports memory',
           'row': {'per_unit_s': round(statistics.median(pooled), 2), 'per_unit_s_mean': round(statistics.mean(pooled), 2),
                   'per_unit_s_max': round(max(pooled), 2), 'n_page_runs': len(pooled),
                   'rerun_floor_s': {'median': round(statistics.median(diffs), 2), 'max': round(max(diffs), 2)} if diffs else None,
                   'peak_gb': round(max(s['peak_footprint_gb'] for s in cpu), 2),
                   'peak_gb_runs': [round(s['peak_footprint_gb'], 2) for s in cpu],
                   'load_s': round(max(s['blla_load_s'] + s['ctc_load_s'] for s in cpu), 2)},
           'runs': runs,
           'pages': {p: rows for p, rows in by_page.items()},
           'mps': [{k: v for k, v in load(t).items() if k != 'pages'} | {'pages_done': len(load(t)['pages'])} for t in mps],
           # a fresh process per page (run fresh-<page> --pages <page>): the page's own need, nothing carried over
           'fresh': {r['pages'][0]['page']: {'peak_footprint_gb': r['time_l']['peak_memory_footprint_gb'],
                                             'process_wall_s': r['process_wall_s'], 'route_s': r['pages'][0]['total_s']}
                     for r in (json.loads(f.read_text()) for f in sorted(COST.glob('fresh-*.json'))
                               if not f.name.endswith('.worker.json'))}}
    if res['fresh']:
        res['row']['fresh_peak_gb'] = round(max(v['peak_footprint_gb'] for v in res['fresh'].values()), 2)
    OUT.with_suffix('.json').write_text(json.dumps(res, indent=1) + '\n')
    OUT.with_suffix('.md').write_text(write_md(res))
    print(json.dumps(res['row']))


def machine():
    sh = lambda *a: subprocess.run(a, capture_output=True, text=True).stdout.strip()
    return {'model': sh('sysctl', '-n', 'hw.model'), 'chip': sh('sysctl', '-n', 'machdep.cpu.brand_string'),
            'memory_gb': int(sh('sysctl', '-n', 'hw.memsize')) / GB,
            'cores': f"{sh('sysctl', '-n', 'hw.perflevel0.physicalcpu')}P+{sh('sysctl', '-n', 'hw.perflevel1.physicalcpu')}E"}


FINDINGS = HERE / 'place_hands_cost_findings.md'


def write_md(res):
    S, m, row = res['runs'], res['machine'], res['row']
    f2 = lambda x: f'{x:.2f}'
    L = ['# W46.place-hands-cost — the hand placement route\'s memory and time', '',
         'Generated by `ArchiveProcessor/scripts/segbench/place_hands_cost.py report` (05-placement.md §8). The shipped '
         'hand route `hand-blla-ctc` run page by page in one process: kraken blla lines, McCATMuS recognition, the '
         'reading force-aligned by both matchers (one-to-one and a span of up to 8), the `conf` pick, and the lab '
         f'writer (`place_functional oracle --fit`) writing the picked words into a PDF. Reading: {res["reading"]} '
         f'(saved). Machine: {m["chip"]} ({m["cores"]}), {m["memory_gb"]:.0f} GB, {m["model"]}. Memory in GB means '
         'GiB (2^30 bytes), as macOS reports it; footprint is phys_footprint, the figure memory pressure and the heavy '
         'lock count. No money, no cluster.', '']
    if FINDINGS.exists():
        L += [FINDINGS.read_text().strip(), '']
    L += ['## Per run', '',
          '| run | device | pages | torch threads | blla s/page (median) | recognition | matchers + pick | writer | whole route s/page (median, mean, max) | model loads s (blla, McCATMuS) | peak footprint GB | peak RSS GB | writer peak RSS GB | parity: lines, conf |',
          '|---|---|---:|---:|---:|---:|---:|---:|---|---|---:|---:|---:|---|']
    for s in S:
        dev = s['device'] + (' + empty_cache' if s['empty_cache'] else '')
        L.append(f"| {s['tag']} | {dev} | {s['pages']} | {s['torch_threads']} | {s['blla_s']['median']:.2f} | "
                 f"{s['recognise_s']['median']:.2f} | {s['match_align_s']['median']:.2f} | {s['writer_s']['median']:.2f} | "
                 f"{s['total_s']['median']:.2f}, {s['total_s']['mean']:.2f}, {s['total_s']['max']:.2f} | "
                 f"{s['blla_load_s']:.1f}, {s['ctc_load_s']:.1f} | {f2(s['peak_footprint_gb'])} | {f2(s['peak_rss_gb'])} | "
                 f"{f2(s['writer_peak_rss_gb'])} | {s['lines_match_saved']}/{s['pages']}, {s['conf_match_saved']}/{s['pages']} |")
    L += ['', '## The footprint by pass over the 20 pages (one process)', '',
          '| run | pass | peak footprint GB | whole route s/page (median) |', '|---|---:|---:|---:|']
    for s in S:
        for b in s['by_rep']:
            L.append(f"| {s['tag']} | {b['rep'] + 1} | {b['peak_fp_gb']:.2f} | {b['total_s_median']:.2f} |")
    for x in res['mps']:
        L += ['', f"MPS run `{x['tag']}`: {x['pages_done']} pages done" +
              (f", peak footprint {x['time_l']['peak_memory_footprint_gb']:.2f} GB" if 'time_l' in x else ', stopped (see Findings)') + '.']
    if res['fresh']:
        F = res['fresh']
        worst = max(F, key=lambda p: F[p]['peak_footprint_gb'])
        L += ['', '## A fresh process per page (CPU)', '',
              f"Each page alone in its own process (`run fresh-<page> --pages <page>`), loads included: peak footprint "
              f"{min(v['peak_footprint_gb'] for v in F.values()):.2f} to {F[worst]['peak_footprint_gb']:.2f} GB (the most on "
              f"{worst}); the process's wall time {min(v['process_wall_s'] for v in F.values()):.0f} to "
              f"{max(v['process_wall_s'] for v in F.values()):.0f} s, of which the route "
              f"{min(v['route_s'] for v in F.values()):.1f} to {max(v['route_s'] for v in F.values()):.1f} s.", '',
              '| page | peak footprint GB | process wall s | route s |', '|---|---:|---:|---:|']
        L += [f"| {p} | {v['peak_footprint_gb']:.2f} | {v['process_wall_s']:.1f} | {v['route_s']:.2f} |" for p, v in F.items()]
    L += ['', '## Per page (seconds and footprint after the stage; timing runs, first then second)', '',
          '| page | lines | blla s | recognition s | matchers + pick s | writer s | whole s | footprint after blla GB |',
          '|---|---:|---|---|---|---|---|---|']
    for p, rows in res['pages'].items():
        c = lambda k: ' / '.join(f'{r[k]:.2f}' for r in rows)
        L.append(f"| {p} | {rows[0]['lines']} | {c('blla_s')} | {c('recognise_s')} | {c('match_align_s')} | "
                 f"{c('writer_s')} | {c('total_s')} | {c('blla_fp_gb')} |")
    return '\n'.join(L) + '\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('run')
    r.add_argument('tag')
    r.add_argument('--device', choices=('cpu', 'mps'), default='cpu')
    r.add_argument('--repeat', type=int, default=1, help='the 20 pages this many times in one process (does the footprint level off?)')
    r.add_argument('--pages', help='only these pages (a fresh process per page: the worst page\'s own need)')
    r.add_argument('--empty-cache', action='store_true', help='torch.mps.empty_cache() after each page')
    rp = sub.add_parser('report')
    rp.add_argument('--timing', nargs=2, required=True, help='the two timing runs (the rerun floor is their per-page difference)')
    rp.add_argument('--plateau', nargs='*', default=[])
    rp.add_argument('--mps', nargs='*', default=[])
    a = ap.parse_args()
    if a.cmd == 'run':
        if os.environ.get('PLACE_HANDS_WORKER') == 'cost':
            worker(a.tag, os.environ['PHC_DEVICE'], bool(os.environ.get('PHC_EMPTY')), int(os.environ['PHC_REPEAT']))
        else:
            run(a.tag, a.device, a.empty_cache, a.repeat, a.pages)
    else:
        report(a.timing, a.plateau, a.mps)


if __name__ == '__main__':
    main()
