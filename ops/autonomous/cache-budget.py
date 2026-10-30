#!/usr/bin/env python3
"""cache-budget.py — the size of the bench cache, per folder, against a budget (W40.cache-budget).

The bench cache (~/Library/Caches/ArchiveSuiteRehearsal) is where segbench items put downloaded models, Python
environments, rendered pages and outputs. Nothing cleared it, and it grew from 37 GB (21 Oct) to 92 GB (29 Oct)
until the engine parked at 10 GB free. This script only measures and reports; it never deletes or moves anything.
The upkeep hook (ops/agent/upkeep.sh) runs it between sessions, warn-only.

  cache-budget.py            the report, at most every --every hours (default 6); otherwise repeats the last one
  cache-budget.py --force    measure now

The report goes to stdout and to $AGENT_STATE/cache-budget.txt. Lines starting "WARN" are the ones that matter.

The budgets (owner may change them; derivation 2026-10-29, cache 48 GB after the owner cleared 17.6 GB of
rebuildable PDFs, disk 926 GB with 32 GB free):
  * TOTAL 65 GB: what the cache held after the cleanup, 50 GB with every open item's inputs, plus the 13.3 GB of
    lab models that moved into mlx-hf on 30 Oct from outside the cache. Growth past it is the next item's scratch
    that nobody cleared.
  * a folder 5 GB: the largest single item folders left were 7 and 6 GB, both holding rendered stage images and
    a private PyTorch environment that the rules now say to clear or share.
  * the shared model caches (mlx-hf, hf) 35 GB: models are reused across items, so they are allowed more.
    Raised from 15 GB on 30 Oct, when mlx-hf became the Mac's one model cache (segbench/model_store.py): the
    Vision OCR lab's 13.3 GB of models moved in and 12.2 GB of duplicates elsewhere went to the Trash, leaving
    mlx-hf at 30.6 GB with every model once.
  * available disk (free plus purgeable) 30 GB: the engine parks at 10 GB (MINFREE_MB); 30 leaves room for a model download and a build.
Environments are listed with their PyTorch version, so a private copy of the shared stack (segbench/torch-env.sh)
shows up. Retired worktrees are listed for the owner; nothing here removes them.
"""
import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

GB = 1024 ** 3
CACHE = Path(os.environ.get('ARCHIVE_BENCH_CACHE', Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'))
STATE = Path(os.environ.get('AGENT_STATE', Path.home() / '.local/state/archive-autonomous'))
RETIRED = STATE / 'retired-worktrees'
TOTAL_GB = float(os.environ.get('CACHE_BUDGET_TOTAL_GB', 65))
FOLDER_GB = float(os.environ.get('CACHE_BUDGET_FOLDER_GB', 5))
MODEL_GB = float(os.environ.get('CACHE_BUDGET_MODEL_GB', 35))
FREE_GB = float(os.environ.get('CACHE_BUDGET_FREE_GB', 30))
MODEL_CACHES = ('mlx-hf', 'hf')
# The upkeep hook as a whole has 300 s (Agent Manager CONTRACT.md); measuring took 25 s on 29 Oct. Past this
# many seconds the rest is not measured and the report says it is incomplete.
DEADLINE = time.monotonic() + float(os.environ.get('CACHE_BUDGET_SECONDS', 120))
SKIPPED, PARTIAL = [], []


def du_bytes(p):
    """Allocated size, as du reports it (APFS clones count in full, as they do for du)."""
    left = DEADLINE - time.monotonic()
    try:
        if left <= 0:
            raise subprocess.TimeoutExpired('du', 0)
        r = subprocess.run(['du', '-sk', str(p)], capture_output=True, text=True, timeout=left)
        if r.returncode != 0:   # an unreadable subfolder: du still prints the total of what it could read
            PARTIAL.append(str(p))
        return int(r.stdout.split()[0]) * 1024
    except subprocess.TimeoutExpired:
        SKIPPED.append(str(p))
        return 0
    except (subprocess.SubprocessError, ValueError, IndexError):
        return 0


def gb(n):
    return '%.1f GB' % (n / GB)


def environments(root, depth=3):
    """Every venv (a pyvenv.cfg) up to depth folders down, with its PyTorch version when it has one."""
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        rel = Path(dirpath).relative_to(root)
        if 'pyvenv.cfg' in filenames:
            torch = '-'
            for sp in Path(dirpath).glob('lib/python*/site-packages'):
                for info in sp.glob('torch-*.dist-info'):
                    torch = info.name[len('torch-'):-len('.dist-info')]
            found.append((str(rel), torch, du_bytes(dirpath)))
            dirnames[:] = []
        elif len(rel.parts) >= depth:
            dirnames[:] = []
    return found


_JXA = ('ObjC.import("Foundation"); function run(argv) {'
        ' var k = "NSURLVolumeAvailableCapacityForImportantUsageKey";'
        ' var v = $.NSURL.fileURLWithPath(argv[0]).resourceValuesForKeysError($([k]), null).objectForKey(k);'
        ' return v.isNil() ? "" : String(v.longLongValue); }')


def available_bytes(path):
    """Free plus purgeable bytes, as Finder's "Available" counts them (owner, 2026-10-30): macOS lets purgeable space
    (local Time Machine snapshots, evictable caches) fill what is free and gives it back when something writes, so
    statvfs alone kept this report under its floor. The Agent Manager's diskspace.py reads the same key. Falls back to
    statvfs, which is never larger, when osascript cannot answer."""
    plain = shutil.disk_usage(path).free
    try:
        out = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', _JXA, str(path)],
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return plain
    return max(plain, int(out)) if out.isdigit() else plain


def report():
    lines, warns = [], []
    if not CACHE.is_dir():
        return ['cache-budget: no bench cache at %s' % CACHE], []
    folders = sorted(((p.name, du_bytes(p)) for p in CACHE.iterdir() if not p.is_symlink()),
                     key=lambda x: -x[1])
    total = sum(s for _, s in folders)
    free = available_bytes(CACHE)
    lines.append('bench cache %s: %s (budget %g GB); disk available %s, free plus purgeable (floor %g GB); measured %s'
                 % (CACHE, gb(total), TOTAL_GB, gb(free), FREE_GB, time.strftime('%Y-%m-%d %H:%M')))
    if total > TOTAL_GB * GB:
        warns.append('WARN cache %s is over its %g GB budget' % (gb(total), TOTAL_GB))
    if free < FREE_GB * GB:
        warns.append('WARN disk available %s is under the %g GB floor' % (gb(free), FREE_GB))
    lines.append('folders (largest first, those over 100 MB):')
    for name, size in folders:
        cap = MODEL_GB if name in MODEL_CACHES else FOLDER_GB
        if size > cap * GB:
            warns.append('WARN folder %s is %s, over its %g GB budget' % (name, gb(size), cap))
        if size >= 100 * 1024 ** 2:
            lines.append('  %9s  %s' % (gb(size), name))
    envs = environments(CACHE)
    torch_envs = [e for e in envs if e[1] != '-' and e[0] != 'torch-env']   # torch-env is the shared one
    lines.append('environments (%d, %d with a private PyTorch; new items use segbench/torch-env.sh):'
                 % (len(envs), len(torch_envs)))
    for rel, torch, size in sorted(envs):
        lines.append('  %9s  %-40s torch %s%s' % (gb(size), rel, torch, '  (shared)' if rel == 'torch-env' else ''))
    if len(torch_envs) > 1:
        lines.append('  (%s in private PyTorch environments)' % gb(sum(e[2] for e in torch_envs)))
    if RETIRED.is_dir():
        trees = sorted(p for p in RETIRED.iterdir() if p.is_dir())
        lines.append('retired worktrees, for the owner (never deleted here): %d in %s, %s'
                     % (len(trees), RETIRED, gb(du_bytes(RETIRED)) if trees else '0 GB'))
        for p in trees:
            try:
                when = time.strftime('%Y-%m-%d', time.localtime(p.stat().st_mtime))
            except OSError:   # removed by the engine since the listing
                continue
            lines.append('  %s  %s' % (when, p.name))
    if SKIPPED:
        warns.append('WARN incomplete: out of time before measuring %d paths (counted as 0), first %s'
                     % (len(SKIPPED), SKIPPED[0]))
    if PARTIAL:
        warns.append('WARN partial: %d paths had unreadable parts (counted as far as du could read), first %s'
                     % (len(PARTIAL), PARTIAL[0]))
    return lines, warns


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--force', action='store_true', help='measure now, whatever the age of the last report')
    ap.add_argument('--every', type=float, default=6.0, help='hours between measurements (default 6)')
    a = ap.parse_args()
    out = STATE / 'cache-budget.txt'
    if not a.force and out.is_file() and time.time() - out.stat().st_mtime < a.every * 3600:
        sys.stdout.write('cache-budget: last measured %s (under %g h ago):\n'
                         % (time.strftime('%H:%M', time.localtime(out.stat().st_mtime)), a.every))
        sys.stdout.write(out.read_text())
        return 0
    lines, warns = report()
    text = '\n'.join(warns + lines) + '\n'
    try:
        STATE.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix('.tmp')
        tmp.write_text(text)
        tmp.replace(out)
    except OSError as e:
        text += 'cache-budget: the report was not saved (%s)\n' % e
    sys.stdout.write(text)
    return 0


if __name__ == '__main__':
    sys.exit(main())
