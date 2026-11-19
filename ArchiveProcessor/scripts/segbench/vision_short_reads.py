#!/usr/bin/env python3
"""W46.vision-short-reads: are any of the bench's cached Vision readings short, and what makes Vision read short?

W46.p16-dewarp-floor's first prep batch (2026-11-18 23:42 to 2026-11-19 00:06) read about 15% fewer lines on 37-45 of 64
flattened images per dewarper, a strict subset of a lone read of the same JPEG; W46.vision-run-guard's 04:49 run on
2026-11-11 read 58 of the 96 short. This checks the cached readings committed results rest on, and tries to make the
fault recur:

  cross    every cached reading of the same image bytes (any jobs file of the caches below, and the two Real5 caches)
           compared with the others; nothing is read.
  reread   a seeded sample of 20 pages per cache read again, twice, each read in its own guarded process
           (vision_guard.run), compared with the cached reading.
  split    the caches read on macOS 26.6 read whole on 27.2: the OS changed nearly every text, so each batch's split of
           shorter and longer pages is compared with the OS change's own split instead of page by page.
  place-print  all 121 of place-print's pages read twice more with its own tool, place_print_vision.
  reproduce  the 96 read under conditions that might cause it: Vision at background QoS, four readers at once, a
           torch process saturating the CPU or the GPU beside it.

Counts and hashes only are written (the repo is public; texts stay in the cache).

    python3 vision_short_reads.py cross                                                   # reads nothing
    python3 ops/autonomous/heavy-run.py run -- <torch-env python> vision_short_reads.py reread
    python3 ops/autonomous/heavy-run.py run -- <torch-env python> vision_short_reads.py split       # 26.6 caches
    python3 ops/autonomous/heavy-run.py run -- <torch-env python> vision_short_reads.py place-print # all 121 pages
    python3 ops/autonomous/heavy-run.py run -- <torch-env python> vision_short_reads.py reproduce

Each writes segbench-results/vision-short-reads/<command>.json; the report is segbench-results/vision-short-reads.md.
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import hashlib
import json
import random
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import vision_guard as VG  # noqa: E402

REH = VG.CACHE
RESULTS = VG.RESULTS
OUT = RESULTS / 'vision-short-reads'
SAMPLE = 20
TORCH_PY = REH / 'torch-env/bin/python'

# (cache, the result it feeds, tool, jobs file). Every jobs file in the item's caches whose images are still cached,
# and the other committed results' Vision jobs files beside them.
JOBS = [
    ('enh-dewarp', 'enh-dewarp, capture ladder', 'segbench-dewarp lines', 'enh-dewarp/lines-jobs.tsv'),
    ('ocr-panel-local', 'the owner panel (ocr-panel)', 'segbench-ocr', 'ocr-panel-local/vision-jobs.tsv'),
    ('ocr-panel-jpeg', 'ocr-panel-jpeg', 'segbench-ocr', 'ocr-panel-jpeg/vision-jobs.tsv'),
    ('capture-ladder', 'capture-ladder', 'segbench-dewarp lines', 'capture-ladder/lines-jobs.tsv'),
    ('colour-dropout', 'ocr-colour-dropout', 'segbench-dewarp lines', 'colour-dropout/lines-jobs.tsv'),
    ('owner-set-grow', 'owner-set-grow', 'segbench-dewarp lines', 'owner-set-grow/lines-jobs.tsv'),
    ('date-full-date', 'date-full-date sheet', 'segbench-dewarp lines', 'date-full-date/sheet/lines-jobs.tsv'),
    ('bench-corpus sample', 'the 440 reference set (corpus sample)', 'segbench-ocr', 'bench-corpus/sample/vision-jobs.tsv'),
    ('bench-corpus routes', 'the 440 reference set (routes)', 'segbench-ocr', 'bench-corpus/routes/vision-jobs.tsv'),
]
REAL5 = ('place-geom-real5/lines/raw', 'dewarp-guard/real5/lines/raw')   # the same 310 Real5 photographs, read twice
PLACE_PRINT = REH / 'place-print'
PLACE_CURVED = REH / 'place-curved-owner'


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()[:16]


def ext(tool):
    return '.txt' if tool == 'segbench-ocr' else '.json'


def mode(tool):
    return 'lines' if tool == 'segbench-dewarp lines' else None


def pairs(jobs: Path):
    """(image, cached reading) rows of a jobs file whose image and reading both still exist, first row per reading."""
    seen, out = set(), []
    for l in jobs.read_text(encoding='utf-8').splitlines():
        r = l.split('\t')
        if len(r) < 2 or r[1] in seen:
            continue
        seen.add(r[1])
        if Path(r[0]).exists() and Path(r[1]).exists():
            out.append((Path(r[0]), Path(r[1])))
    return out


def safe_counts(p: Path):
    try:
        return VG.counts(p)
    except (ValueError, KeyError, OSError):
        return None


# ---------------------------------------------------------------- power state, from the pmset log
def power_log():
    """[(time, 'AC'|'BATT')] at each change of power source the pmset log still holds (about a week)."""
    out = subprocess.run(['pmset', '-g', 'log'], capture_output=True, text=True, errors='replace').stdout
    tr, prev = [], None
    for l in out.splitlines():
        m, s = re.match(r'(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) ', l), re.search(r'Using (AC|Batt|BATT)', l)
        if m and s:
            k = 'AC' if s.group(1) == 'AC' else 'BATT'
            if k != prev:
                tr.append((dt.datetime.fromisoformat(m.group(1)), k))
                prev = k
    return tr


def power_at(tr, t: dt.datetime):
    if not tr or t < tr[0][0]:
        return None
    return [k for a, k in tr if a <= t][-1]


def mtime(p: Path) -> dt.datetime:
    return dt.datetime.fromtimestamp(p.stat().st_mtime).replace(microsecond=0)


# ---------------------------------------------------------------- cross: same bytes, every cached reading
def cmd_cross(_):
    tr = power_log()
    groups = collections.defaultdict(list)   # (tool, image sha) -> [(cache, reading path)]
    for cache, _, tool, jf in JOBS:
        for img, out in pairs(REH / jf):
            groups[tool, sha(img)].append((cache, out))
    a, b = (REH / d for d in REAL5)
    for f in sorted(a.glob('*.json')):
        if (b / f.name).exists():
            groups['segbench-dewarp lines', 'real5:' + f.stem] += [('place-geom-real5', f), ('dewarp-guard', b / f.name)]
    rows, short_rows = [], []
    for (tool, key), rs in groups.items():
        if len(rs) < 2:
            continue
        cs = [(c, p, safe_counts(p)) for c, p in rs]
        cs = [x for x in cs if x[2]]
        top = max(cs, key=lambda x: (x[2]['lines'], x[2]['words']))[2]
        for c, p, n in cs:
            row = {'tool': tool, 'image': key, 'cache': c, 'reading': str(p.relative_to(REH)), **n,
                   'max_lines': top['lines'], 'max_words': top['words'], 'made': mtime(p).isoformat(' '),
                   'power': power_at(tr, mtime(p))}
            rows.append(row)
            if VG.short(n, top):
                short_rows.append(row)
    by_cache = collections.Counter(r['cache'] for r in rows)
    res = {'groups': sum(1 for rs in groups.values() if len(rs) >= 2), 'readings': len(rows),
           'readings_by_cache': dict(sorted(by_cache.items())), 'short': short_rows,
           'identical_groups': sum(1 for (t, k), rs in groups.items() if len(rs) >= 2 and
                                   len({(safe_counts(p) or {}).get('sha256_16') for _, p in rs}) == 1)}
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'cross.json').write_text(json.dumps(res, indent=1) + '\n')
    print(f"{res['groups']} images read more than once, {res['readings']} readings, {res['identical_groups']} groups "
          f"identical, {len(short_rows)} short readings")
    for r in short_rows:
        print(' ', r['cache'], r['reading'], r['lines'], '/', r['max_lines'], r['words'], '/', r['max_words'], r['made'])


# ---------------------------------------------------------------- reread: a sample per cache, read twice
def guarded_read(tool, rows, t: Path, tag):
    """rows [(key, image)] read by tool in one guarded process into t/tag/<key><ext>; their counts."""
    d = t / tag
    d.mkdir(parents=True, exist_ok=True)
    jf = t / f'{tag}.tsv'
    jf.write_text(''.join(f'{img}\t{d / (k + ext(tool))}\n' for k, img in rows), encoding='utf-8')
    t0 = time.time()
    VG.run(VG.binary(tool), jf, mode(tool), twice=False, capture_output=True)   # one raw reading, compared here
    return {k: safe_counts(d / (k + ext(tool))) for k, _ in rows}, round(time.time() - t0, 1)


def direction(old, new):
    if old is None or new is None:
        return 'missing'
    if old['sha256_16'] == new['sha256_16']:
        return 'identical'
    return 'shorter' if VG.short(old, new) else 'longer' if VG.short(new, old) else 'within slack'


def compare(cached, a, b):
    return {'cached_vs_a': direction(cached, a), 'cached_vs_b': direction(cached, b), 'a_vs_b': direction(a, b)}


def cmd_place_print(_):
    """Every place-print page read twice more by place_print_vision (both APIs), against the cached reading: the
    sample found RecognizeDocumentsRequest reading one handwritten page 7 lines one time and 24 the next."""
    with tempfile.TemporaryDirectory(prefix='vision-short-pp-') as t:
        rows = place_print_reread(Path(t), 10 ** 6, random.Random(0))
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'place-print.json').write_text(json.dumps({'os_build': VG.os_build(), 'rows': rows}, indent=1) + '\n')
    for api in ('accurate', 'documents'):
        rs = [r for r in rows if r['cache'] == f'place-print {api}']
        print(api, len(rs), collections.Counter(r['cached_vs_a'] for r in rs),
              'a vs b', collections.Counter(r['a_vs_b'] for r in rs))


def place_curved_rows(t: Path, n, rnd):
    """place-curved-owner's upright copies are gone; made again from the HEIC or sample originals as the item made
    them (sips JPEG 92, then turned), into t."""
    import place_curved as PC
    sel = [r for r, _ in PC.selected()]
    rows = []
    for r in rnd.sample(sel, min(n, len(sel))):
        k = r['key']
        src = PC.image_of_row(r)
        if k.startswith('uiuc-'):
            heic = PC.UIUC / f'UIUC — {k.split("-")[1]}.HEIC'
            if not heic.exists():
                continue
            src = t / 'heic' / f'{k}.jpg'
            src.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '92', str(heic), '--out', str(src)],
                           check=True, stdout=subprocess.DEVNULL)
        if not src.exists():
            continue
        up = t / 'up' / f'{k}.jpg'
        up.parent.mkdir(parents=True, exist_ok=True)
        PC.write_upright(src, up, r['turn'])
        rows.append((k, up, PLACE_CURVED / 'lines-up' / f'{k}.json'))
    return rows


def place_print_reread(t: Path, n, rnd):
    jobs = [j for j in json.loads((PLACE_PRINT / 'vision-jobs.json').read_text()) if Path(j['image']).exists()]
    jobs = rnd.sample(jobs, min(n, len(jobs)))
    t.mkdir(parents=True, exist_ok=True)
    exe = t / 'place_print_vision'
    subprocess.run(['/usr/bin/swiftc', '-O', '-parse-as-library', str(HERE / 'place_print_vision.swift'), '-o',
                    str(exe)], check=True, capture_output=True)
    (t / 'pp-jobs.json').write_text(json.dumps(jobs))
    reads = {}
    for tag in ('a', 'b'):
        # place_print_vision is not one of the guard's tools; an empty guarded run on each side brackets it instead
        VG.cmd_check(None)
        subprocess.run([str(exe), str(t / 'pp-jobs.json'), str(t / f'pp-{tag}')], check=True, capture_output=True)
        reads[tag] = t / f'pp-{tag}'
    VG.cmd_check(None)
    out = []
    for api in ('accurate', 'documents'):
        for j in jobs:
            cached = PLACE_PRINT / 'vision' / api / f'{j["page"]}.json'
            c, a, b = (safe_counts(p) for p in (cached, reads['a'] / api / f'{j["page"]}.json',
                                                 reads['b'] / api / f'{j["page"]}.json'))
            out.append({'cache': f'place-print {api}', 'key': j['page'], 'cached': c, 'a': a, 'b': b,
                        'made': mtime(cached).isoformat(' ') if cached.exists() else None, **compare(c, a, b)})
    return out


def cmd_reread(a):
    tr = power_log()
    rows = []
    with tempfile.TemporaryDirectory(prefix='vision-short-reads-') as t:
        t = Path(t)
        for cache, feeds, tool, jf in JOBS:
            rnd = random.Random(f'W46.vision-short-reads {cache}')
            ps = pairs(REH / jf)
            pick = rnd.sample(ps, min(a.n, len(ps)))
            keyed = [(f'{i:03d}', img, out) for i, (img, out) in enumerate(pick)]
            got = {}
            for tag in ('a', 'b'):
                got[tag], secs = guarded_read(tool, [(k, img) for k, img, _ in keyed], t / cache.replace(' ', '-'), tag)
            for k, img, out in keyed:
                c = safe_counts(out)
                rows.append({'cache': cache, 'feeds': feeds, 'tool': tool, 'key': str(out.relative_to(REH)),
                             'cached': c, 'a': got['a'][k], 'b': got['b'][k], 'made': mtime(out).isoformat(' '),
                             'power': power_at(tr, mtime(out)), **compare(c, got['a'][k], got['b'][k])})
            print(cache, collections.Counter(r['cached_vs_a'] for r in rows if r['cache'] == cache), flush=True)
        save(tr, a, rows)
        rnd = random.Random('W46.vision-short-reads place-curved-owner')
        pc = place_curved_rows(t / 'pc', a.n, rnd)
        got = {tag: guarded_read('segbench-dewarp lines', [(k, up) for k, up, _ in pc], t / 'pc', tag)[0]
               for tag in ('a', 'b')}
        for k, up, cached in pc:
            c = safe_counts(cached)
            rows.append({'cache': 'place-curved-owner', 'feeds': 'place-curved-owner, dewarp-placement route',
                         'tool': 'segbench-dewarp lines', 'key': str(cached.relative_to(REH)), 'cached': c,
                         'a': got['a'][k], 'b': got['b'][k], 'made': mtime(cached).isoformat(' '),
                         'power': power_at(tr, mtime(cached)), **compare(c, got['a'][k], got['b'][k])})
        print('place-curved-owner', collections.Counter(r['cached_vs_a'] for r in rows
                                                        if r['cache'] == 'place-curved-owner'), flush=True)
        for r in place_print_reread(t / 'pp', a.n, random.Random('W46.vision-short-reads place-print')):
            rows.append({'feeds': 'place-print', 'tool': 'place_print_vision', 'power': power_at(
                tr, dt.datetime.fromisoformat(r['made'])) if r['made'] else None, **r})
        print('place-print', collections.Counter(r['cached_vs_a'] for r in rows if r['tool'] == 'place_print_vision'))
    save(tr, a, rows)


def save(tr, a, rows):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'reread.json').write_text(json.dumps({'os_build': VG.os_build(), 'read_at': dt.datetime.now().isoformat(
        ' ', 'seconds'), 'power_now': power_at(tr, dt.datetime.now()), 'sample': a.n, 'rows': rows}, indent=1) + '\n')


# ---------------------------------------------------------------- split: a 26.6 cache read whole on 27.2
# macOS 27.2 changed 95 of the 96's texts, so a reading made on 26.6 cannot be checked page by page against a 27.2 one.
# What a short batch would still show is direction: most of its pages shorter. The OS change alone has its own split,
# measured on the dated 26.6/27.2 pairs W46.vision-27-reread made (BASELINES); a batch is compared with the one that
# matches its material.
BASELINES = {'owner': ('ocr-panel-local/vision-26.6', 'ocr-panel-local/vision-27.2'),
             'owner lines': ('enh-dewarp/lines/raw-26.6', 'enh-dewarp/lines/raw-27.2'),
             'reference set': ('bench-corpus/routes/vision-26.6', 'bench-corpus/routes/vision-27.2')}
SPLIT = [('enh-dewarp', 'owner lines'), ('ocr-panel-jpeg', 'owner'), ('bench-corpus sample', 'reference set')]


def cmd_split(_):
    res = {'baselines': {}, 'batches': []}
    for name, (old, new) in BASELINES.items():
        c = collections.Counter(direction(safe_counts(f), safe_counts(REH / new / f.name))
                                for f in sorted((REH / old).iterdir()) if (REH / new / f.name).exists())
        res['baselines'][name] = {'pair': [old, new], **c}
    with tempfile.TemporaryDirectory(prefix='vision-short-split-') as t:
        t = Path(t)
        for cache, base in SPLIT:
            _, _, tool, jf = next(j for j in JOBS if j[0] == cache)
            ps = pairs(REH / jf)
            keyed = [(f'{i:04d}', img, out) for i, (img, out) in enumerate(ps)]
            got, secs = guarded_read(tool, [(k, img) for k, img, _ in keyed], t / cache.replace(' ', '-'), 'whole')
            per = collections.defaultdict(collections.Counter)
            for k, img, out in keyed:
                per[out.parent.name, mtime(out).strftime('%Y-%m-%d')][direction(safe_counts(out), got[k])] += 1
            for (sub, day), c in sorted(per.items()):
                res['batches'].append({'cache': cache, 'folder': sub, 'made': day, 'baseline': base, **c})
            print(cache, secs, 's', flush=True)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'split.json').write_text(json.dumps(res, indent=1) + '\n')
    for k, v in res['baselines'].items():
        print('baseline', k, {x: v.get(x, 0) for x in ('shorter', 'longer', 'within slack', 'identical')})
    for b in res['batches']:
        print(b['cache'], b['folder'], b['made'], {x: b.get(x, 0) for x in ('shorter', 'longer', 'within slack',
                                                                           'identical', 'missing')})


# ---------------------------------------------------------------- reproduce: conditions that might make it short
LOAD = r'''
import sys, time, torch
dev = sys.argv[1]
torch.set_num_threads(12)
x = torch.randn(2048, 2048, device=dev)
end = time.time() + float(sys.argv[2])
while time.time() < end:
    y = x @ x
    if dev == 'mps':
        torch.mps.synchronize()
'''


def cmd_reproduce(a):
    import ocr_panel as P
    pages = sorted(r['page'] for r in P.rows() if r['page'] not in P.AGREEMENT)
    binp = VG.binary('segbench-dewarp lines')
    runs = []

    def one(t, name, prefix=(), load=None, readers=1):
        procs, loader = [], None
        if load:
            loader = subprocess.Popen([str(TORCH_PY), '-c', LOAD, load, '600'], stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL)
            time.sleep(5)
        t0 = time.time()
        dirs = []
        for w in range(readers):
            d = t / f'{name}-{w}'
            d.mkdir()
            (d / 'jobs.tsv').write_text(''.join(f'{VG.IMAGES / f"{p}-original.jpg"}\t{d / (p + ".json")}\n'
                                                for p in pages))
            procs.append(subprocess.Popen([*prefix, str(binp), 'lines', str(d / 'jobs.tsv')],
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            dirs.append(d)
        rcs = [p.wait() for p in procs]
        secs = round(time.time() - t0, 1)
        if loader:
            loader.terminate()
            loader.wait()
        for w, d in enumerate(dirs):
            runs.append({'condition': name, 'reader': w, 'seconds': secs, 'rc': rcs[w],
                         'pages': {p: safe_counts(d / f'{p}.json') for p in pages}})
        print(name, secs, rcs, flush=True)

    with tempfile.TemporaryDirectory(prefix='vision-short-repro-') as t:
        t = Path(t)
        VG.cmd_check(None)
        one(t, 'base')
        one(t, 'qos-background', prefix=('taskpolicy', '-b'))
        one(t, 'four-readers', readers=4)
        one(t, 'cpu-load', load='cpu')
        one(t, 'gpu-load', load='mps')
        one(t, 'qos-background+cpu-load', prefix=('taskpolicy', '-b'), load='cpu')
        one(t, 'base-again')
        VG.cmd_check(None)
    base = runs[0]['pages']
    summary = []
    for r in runs:
        ps = r['pages']
        summary.append({k: r[k] for k in ('condition', 'reader', 'seconds', 'rc')} | {
            'lines': sum(x['lines'] for x in ps.values() if x), 'words': sum(x['words'] for x in ps.values() if x),
            'missing': [p for p in pages if not ps[p]],
            'changed': [p for p in pages if ps[p] and base[p] and ps[p]['sha256_16'] != base[p]['sha256_16']],
            'short': [p for p in pages if VG.short(ps[p], base[p])]})
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'reproduce.json').write_text(json.dumps({'os_build': VG.os_build(), 'pages': len(pages),
                                                    'binary_sha256_16': sha(binp), 'power_now': power_at(
                                                        power_log(), dt.datetime.now()), 'runs': summary},
                                                   indent=1) + '\n')
    for s in summary:
        print(s['condition'], s['reader'], s['seconds'], s['lines'], s['words'], len(s['changed']), s['short'])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('cross').set_defaults(f=cmd_cross)
    r = sub.add_parser('reread')
    r.add_argument('--n', type=int, default=SAMPLE)
    r.set_defaults(f=cmd_reread)
    sub.add_parser('split').set_defaults(f=cmd_split)
    sub.add_parser('place-print').set_defaults(f=cmd_place_print)
    sub.add_parser('reproduce').set_defaults(f=cmd_reproduce)
    a = ap.parse_args()
    a.f(a)


if __name__ == '__main__':
    main()
