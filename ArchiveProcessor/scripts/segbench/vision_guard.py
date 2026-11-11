#!/usr/bin/env python3
"""W46.vision-run-guard: a reference check on every bench Vision run.

One Vision run (2026-11-11 04:49, `ocr_colour_dropout.py vision`) read 58 of the owner's 96 short, mean NES 60.0 against
83.1, with whole lines missing, from the same binary, images and settings as the good runs (`segbench-results/
dewarp-bin-reread.md`). Until then no runner checked more than the exit code.

`run()` replaces a bare `subprocess.run([binary, (mode,) jobs])` for the two text-reading tools, `segbench-ocr` and
`segbench-dewarp lines`. It reads four typed pages of the 96 (REFERENCE) first and last IN THE SAME PROCESS as the run's
own jobs, and compares each reading with the counts frozen in `vision_reference.json`. A run whose reference readings
lose a line or more than 3% of their words is refused (VisionRunFault), and the outputs it wrote are moved aside into
`~/Library/Caches/ArchiveSuiteRehearsal/vision-guard/quarantine/<stamp>/` (never deleted), so a cached runner that skips
existing outputs reads them again next time instead of keeping them. On 27.2 typed pages read identically from run to
run (W46.dewarp-bin-reread: 1,532 of 1,536 identical, every difference a handwritten page, one motion-blurred page or one
character), so the slack is a margin, not a measured spread; the faulty run lost 65-75% of these pages' words. Other
`segbench-dewarp` modes (quad, encode) read no text and run unguarded.

The frozen file holds counts and hashes only (the repo is public; the texts stay in the cache). It names the OS build it
was frozen on; on another build the guard refuses until it is frozen again, since an OS update may change Vision's text.

  python3 ops/autonomous/heavy-run.py run -- python3 vision_guard.py freeze      # read the references 3 times each
  python3 ops/autonomous/heavy-run.py run -- python3 vision_guard.py check       # one guarded empty run per tool
  python3 ops/autonomous/heavy-run.py run -- python3 vision_guard.py reproduce   # the 96 read 20 times, a fault hunt
"""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
CACHE = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
IMAGES = CACHE / 'ocr-panel-local/images'   # the 96's frozen panel originals
BIN_DIR = CACHE / 'segbench/bin'
FROZEN = HERE / 'vision_reference.json'
QUARANTINE = CACHE / 'vision-guard/quarantine'
RESULTS = HERE.parents[1] / 'segbench-results'
# Typed, no handwriting, clippings or tables; four collections, originals and PDF images. The faulty run read them
# 11/27, 7/23, 12/32 and 16/44 lines.
REFERENCE = ('p004', 'p014', 'p035', 'p068')
LINE_SLACK = 1
WORD_SLACK = 0.03
TOOLS = {'segbench-ocr': None, 'segbench-dewarp lines': 'lines'}


class VisionRunFault(SystemExit):
    pass


def tool_name(mode):
    return {None: 'segbench-ocr', 'lines': 'segbench-dewarp lines'}.get(mode)


def counts(path: Path) -> dict:
    """Lines, words and a text hash of one reading: segbench-ocr's text, or segbench-dewarp lines' JSON."""
    raw = path.read_text(encoding='utf-8')
    lines = [l['text'] for l in json.loads(raw)['lines']] if path.suffix == '.json' else raw.splitlines()
    lines = [l.strip() for l in lines if l.strip()]
    text = '\n'.join(lines)
    return {'lines': len(lines), 'words': sum(len(l.split()) for l in lines),
            'sha256_16': hashlib.sha256(text.encode()).hexdigest()[:16]}


def os_build() -> str:
    return subprocess.run(['sw_vers', '-buildVersion'], capture_output=True, text=True).stdout.strip()


def image_sha(page: str) -> str:
    return hashlib.sha256((IMAGES / f'{page}-original.jpg').read_bytes()).hexdigest()[:16]


def short(got: dict | None, want: dict) -> bool:
    return got is None or got['lines'] < want['lines'] - LINE_SLACK or got['words'] < want['words'] * (1 - WORD_SLACK)


def _jobs(path: Path) -> list[list[str]]:
    return [l.split('\t') for l in path.read_text(encoding='utf-8').splitlines() if l.strip()]


def run(binary, jobs, mode=None, check=True, **kw):
    """subprocess.run([binary, (mode,) jobs], check=check, **kw), with the reference pages read before and after the
    run's own jobs in the same process. Raises VisionRunFault when a reference reading comes back short."""
    cmd = [str(binary), *([mode] if mode else [])]
    tool = tool_name(mode)
    if tool is None:
        return subprocess.run([*cmd, str(jobs)], check=check, **kw)
    frozen = json.loads(FROZEN.read_text())
    if frozen['os_build'] != os_build():
        raise VisionRunFault(f'vision_guard: the references were frozen on macOS build {frozen["os_build"]}, this is '
                             f'{os_build()}; run `vision_guard.py freeze` under the heavy lock first')
    changed = [p for p in REFERENCE if not (IMAGES / f'{p}-original.jpg').exists() or image_sha(p) != frozen['images'][p]]
    if changed:
        raise VisionRunFault(f'vision_guard: reference images missing or changed in {IMAGES}: {", ".join(changed)}')
    rows = _jobs(Path(jobs))
    pending = [Path(r[1]) for r in rows if len(r) >= 2 and not Path(r[1]).exists()]
    ext = '.txt' if tool == 'segbench-ocr' else '.json'
    with tempfile.TemporaryDirectory(prefix='vision-guard-') as t:
        t = Path(t)
        refs = {(at, p): t / f'{at}-{p}{ext}' for at in ('start', 'end') for p in REFERENCE}
        ref_rows = {at: ''.join(f'{IMAGES / f"{p}-original.jpg"}\t{refs[at, p]}\n' for p in REFERENCE)
                    for at in ('start', 'end')}
        combined = t / 'jobs.tsv'
        combined.write_text(ref_rows['start'] + ''.join('\t'.join(r) + '\n' for r in rows) + ref_rows['end'],
                            encoding='utf-8')
        result = subprocess.run([*cmd, str(combined)], check=False, **kw)
        faults = []
        for (at, p), f in refs.items():
            got = counts(f) if f.exists() else None
            want = frozen['tools'][tool][p]
            if short(got, want):
                faults.append(f'{p} at the {at}: ' + ('no reading' if got is None else
                              f'{got["lines"]} lines / {got["words"]} words against {want["lines"]} / {want["words"]}'))
    if faults:
        moved = quarantine([f for f in pending if f.exists()], tool)
        raise VisionRunFault(f'vision_guard: {tool} read its reference pages short, so the run is refused '
                             f'({"; ".join(faults)}). {len(moved)} outputs moved to {moved and moved[0].parent}; '
                             f'run it again.')
    if check and result.returncode:
        raise subprocess.CalledProcessError(result.returncode, result.args)
    return result


def quarantine(files: list[Path], tool: str) -> list[Path]:
    if not files:
        return []
    d = QUARANTINE / time.strftime('%Y%m%d-%H%M%S')
    d.mkdir(parents=True, exist_ok=True)
    moved = []
    for i, f in enumerate(files):
        dest = d / f'{i:05d}-{f.name}'
        shutil.move(str(f), dest)
        moved.append(dest)
    (d / 'MOVED.json').write_text(json.dumps({'tool': tool, 'moved': {str(m): str(f) for m, f in zip(moved, files)}},
                                             indent=1) + '\n')
    return moved


def binary(tool: str) -> Path:
    return BIN_DIR / tool.split()[0]


def cmd_freeze(_):
    """Read each reference page three times with each tool, in three processes; freeze only when all agree."""
    out = {'os_build': os_build(), 'machine': platform.machine(), 'line_slack': LINE_SLACK, 'word_slack': WORD_SLACK,
           'images': {p: image_sha(p) for p in REFERENCE}, 'tools': {}}
    for tool, mode in TOOLS.items():
        ext = '.txt' if mode is None else '.json'
        reads = []
        for k in range(3):
            with tempfile.TemporaryDirectory(prefix='vision-freeze-') as t:
                t = Path(t)
                (t / 'jobs.tsv').write_text(''.join(f'{IMAGES / f"{p}-original.jpg"}\t{t / (p + ext)}\n'
                                                    for p in REFERENCE))
                subprocess.run([str(binary(tool)), *([mode] if mode else []), str(t / 'jobs.tsv')], check=True,
                               capture_output=True)
                reads.append({p: counts(t / (p + ext)) for p in REFERENCE})
        if any(r != reads[0] for r in reads):
            raise SystemExit(f'{tool}: the three reference readings differ, so nothing is frozen: {reads}')
        out['tools'][tool] = reads[0]
        out['tools'][tool + ' sha256_16'] = hashlib.sha256(binary(tool).read_bytes()).hexdigest()[:16]
    FROZEN.write_text(json.dumps(out, indent=1) + '\n')
    print(json.dumps(out['tools'], indent=1))


def cmd_check(_):
    """One guarded run per tool with no jobs of its own: the references alone, start and end."""
    for tool, mode in TOOLS.items():
        with tempfile.TemporaryDirectory() as t:
            (Path(t) / 'jobs.tsv').write_text('')
            run(binary(tool), Path(t) / 'jobs.tsv', mode, capture_output=True)
        print(tool, 'ok')


def cmd_reproduce(a):
    """The 96 read N times by segbench-dewarp lines, one process each, every page compared with the first run's
    reading: one attempt to make the 04:49 fault recur. Counts only are written."""
    import ocr_panel as P
    pages = sorted(r['page'] for r in P.rows() if r['page'] not in P.AGREEMENT)
    runs = []
    with tempfile.TemporaryDirectory(prefix='vision-reproduce-') as t:
        t = Path(t)
        for k in range(a.runs):
            d = t / f'r{k:02d}'
            d.mkdir()
            (d / 'jobs.tsv').write_text(''.join(f'{IMAGES / f"{p}-original.jpg"}\t{d / (p + ".json")}\n' for p in pages))
            t0 = time.time()
            subprocess.run([str(binary('segbench-dewarp lines')), 'lines', str(d / 'jobs.tsv')], check=True,
                           capture_output=True)
            runs.append({'seconds': round(time.time() - t0, 1), 'pages': {p: counts(d / f'{p}.json') for p in pages}})
            print(f'run {k + 1}: {runs[-1]["seconds"]} s', flush=True)
    base = runs[0]['pages']
    summary = []
    for k, r in enumerate(runs):
        changed = [p for p in pages if r['pages'][p]['sha256_16'] != base[p]['sha256_16']]
        shorter = [p for p in pages if short(r['pages'][p], base[p])]
        summary.append({'run': k + 1, 'seconds': r['seconds'], 'changed': changed, 'short': shorter,
                        'lines': sum(x['lines'] for x in r['pages'].values()),
                        'words': sum(x['words'] for x in r['pages'].values())})
    res = {'os_build': os_build(), 'machine': platform.machine(), 'pages': len(pages), 'runs': summary,
           'binary_sha256_16': hashlib.sha256(binary('segbench-dewarp lines').read_bytes()).hexdigest()[:16]}
    (RESULTS / 'vision-run-guard.json').write_text(json.dumps(res, indent=1) + '\n')
    for s in summary:
        print(s['run'], s['lines'], s['words'], len(s['changed']), s['short'])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('freeze').set_defaults(f=cmd_freeze)
    sub.add_parser('check').set_defaults(f=cmd_check)
    r = sub.add_parser('reproduce')
    r.add_argument('--runs', type=int, default=20)
    r.set_defaults(f=cmd_reproduce)
    a = ap.parse_args()
    sys.path.insert(0, str(HERE))
    a.f(a)


if __name__ == '__main__':
    main()
