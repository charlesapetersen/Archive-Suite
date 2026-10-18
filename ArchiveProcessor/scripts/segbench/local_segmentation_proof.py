#!/usr/bin/env python3
"""Own a loopback mlx-vlm server and the local:mac proof under the caller's heavy lock.

scripts/test-local-segmentation-proof.sh [--output /tmp/new-directory] [--python /path/to/mlx-venv/bin/python]

Uses installed packages and local weights read-only, with downloads disabled. The guard uses the lab's
limits: 12 GiB summed RSS/physical footprint, 2 GiB swap growth, critical system memory pressure; it
requires normal pressure and 4 GiB reclaimable before starting. No dependency on another project's scripts
or state. Artifacts stay in a fresh scratch directory, including the proof's text-free boundary JSON.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

PROCESSOR = Path(__file__).resolve().parents[2]
DEFAULT_LAB = Path.home() / '.local/share/visionocr-ocrlab'


def command(*args):
    return subprocess.check_output(args, text=True, timeout=10)


def system_memory():
    swap = float(re.search(r'used = ([\d.]+)M', command('/usr/sbin/sysctl', '-n', 'vm.swapusage'))[1])
    pressure = int(command('/usr/sbin/sysctl', '-n', 'kern.memorystatus_vm_pressure_level'))
    return swap, pressure


def reclaimable_mb():
    size = int(command('/usr/sbin/sysctl', '-n', 'hw.pagesize'))
    pages = sum(int(n) for n in re.findall(r'Pages (?:free|inactive|speculative|purgeable):\s+(\d+)\.', command('/usr/bin/vm_stat')))
    return pages * size / 2**20


def tree_memory(root):
    rows = [(int(pid), int(parent), int(rss)) for pid, parent, rss, state in
            (line.split() for line in command('/bin/ps', '-axo', 'pid=,ppid=,rss=,stat=').splitlines()) if 'Z' not in state]
    wanted = {root}
    while True:
        children = {pid for pid, parent, _ in rows if parent in wanted}
        if children <= wanted:
            break
        wanted |= children
    rss = sum(rss for pid, _, rss in rows if pid in wanted) / 1024
    footprint = 0.0
    for pid in wanted:
        # Metal buffers are mostly invisible to RSS. Failure to measure a live process is a refusal.
        p = subprocess.run(['/usr/bin/footprint', '-p', str(pid)], capture_output=True, text=True, timeout=10)
        match = re.search(r'Footprint:\s+([\d.]+)\s*([KMG]?B)', p.stdout)
        if match:
            footprint += float(match[1]) * {'B': 1 / 2**20, 'KB': 1 / 1024, 'MB': 1, 'GB': 1024}[match[2]]
        elif any(int(current) == pid and 'Z' not in state for current, state in
                 (line.split() for line in command('/bin/ps', '-axo', 'pid=,stat=').splitlines())):
            raise RuntimeError(f'cannot measure physical footprint of live pid {pid}')
    return rss, footprint


def finished(process):
    # ps can observe a zombie without reaping it. Retain that leader until group cleanup, so its pid
    # (also its group id) cannot be recycled even when descendants outlive it. macOS Python lacks waitid.
    status = command('/bin/ps', '-o', 'stat=', '-p', str(process.pid)).strip()
    if not status:
        raise RuntimeError(f'cannot inspect owned child {process.pid}')
    return 'Z' in status


def group_live(group):
    return any(int(pgid) == group and 'Z' not in status for pgid, status in
               (line.split() for line in command('/bin/ps', '-axo', 'pgid=,stat=').splitlines()))


def stop(process, grace=5):
    if process is None:
        return None
    # Never poll/wait before signalling: our unreaped leader reserves this process group id.
    if not group_live(process.pid):
        return process.wait(timeout=5)
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except PermissionError:
        # macOS can report EPERM for a group containing only zombies; no live process is signalled.
        if group_live(process.pid):
            raise
    deadline = time.monotonic() + grace
    while group_live(process.pid) and time.monotonic() < deadline:
        time.sleep(.1)
    if group_live(process.pid):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            if group_live(process.pid):
                raise
    return process.wait(timeout=5)



def run_app(binary, report, log):
    """Keep the actual app unreaped until cleanup; Bash cannot safely own a stale numeric pid."""
    child = None
    old_handlers = {}
    def interrupted(signum, frame):
        raise RuntimeError(f'app proof interrupted by signal {signum}')
    signals = {signal.SIGTERM, signal.SIGINT, signal.SIGHUP}
    for sig in signals:
        old_handlers[sig] = signal.signal(sig, interrupted)
    blocked = signal.pthread_sigmask(signal.SIG_UNBLOCK, signals)
    try:
        with Path(log).open('w') as out:
            child = subprocess.Popen([str(binary)], stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + 3600
            while not Path(report).exists():
                if finished(child):
                    raise RuntimeError(f'app exited before writing its proof; see {log}')
                if time.monotonic() > deadline:
                    raise RuntimeError(f'app proof timed out; see {log}')
                time.sleep(.25)
        return 0
    finally:
        try:
            # A headless test app has nothing to save after its report or a stop; end it immediately.
            stop(child, grace=0)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, blocked)
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)


def run(args):
    output = Path(args.output).resolve() if args.output else Path(tempfile.mkdtemp(prefix='ap-local-seg-proof-'))
    if args.output:
        output.mkdir(parents=True, exist_ok=False)
    print(f'Artifacts: {output}', flush=True)
    model = Path(args.model).expanduser().resolve()
    config = (model / 'config.json').read_bytes()
    quant = json.loads(config).get('quantization', {})
    if quant.get('bits') != 8:
        raise RuntimeError(f'expected the real 8-bit model, found quantization {quant}')
    swap0, pressure = system_memory()
    available = reclaimable_mb()
    if pressure != 1 or available < 4096:
        raise RuntimeError(f'memory not quiet: pressure={pressure}, reclaimable={available:.0f} MB (need normal and 4096 MB)')
    # An unused OS-assigned port avoids interfering with somebody else's local service.
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    url = f'http://127.0.0.1:{port}/v1'
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', HF_HUB_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1',
               HF_HOME=str(output / 'hf'), XDG_CACHE_HOME=str(output / 'cache'),
               SEGMENTATION_PROOF_LOCAL_URL=url, SEGMENTATION_PROOF_LOCAL_MODEL=str(model),
               SEGMENTATION_PROOF_JSON=str(output / 'result.json'))
    server = proof = None
    metrics = dict(model=str(model), config_sha256=hashlib.sha256(config).hexdigest(), quantization=quant,
                   base_url=url, peak_rss_mb=0, peak_footprint_mb=0, peak_swap_growth_mb=0, max_pressure=pressure)
    started = time.monotonic()
    rc = 1
    completed = False
    def interrupted(signum, frame):
        raise RuntimeError(f'interrupted by signal {signum}')
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, interrupted)
    # The engine blocks these in its worker; our supervised server/app must be terminable.
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM, signal.SIGINT, signal.SIGHUP})
    try:
        with (output / 'server.log').open('w') as log, (output / 'proof.log').open('w') as proof_log:
            server = subprocess.Popen([args.python, '-m', 'mlx_vlm.server', '--host', '127.0.0.1', '--port', str(port)],
                                      env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            while True:
                if finished(server):
                    raise RuntimeError('mlx-vlm stopped; see server.log')
                rss, footprint = tree_memory(os.getpid())
                swap, pressure = system_memory()
                metrics['peak_rss_mb'] = max(metrics['peak_rss_mb'], round(rss))
                metrics['peak_footprint_mb'] = max(metrics['peak_footprint_mb'], round(footprint))
                metrics['peak_swap_growth_mb'] = max(metrics['peak_swap_growth_mb'], round(swap - swap0))
                metrics['max_pressure'] = max(metrics['max_pressure'], pressure)
                if max(rss, footprint) > 12288 or swap - swap0 > 2048 or pressure >= 4:
                    raise RuntimeError(f'memory guard tripped: rss={rss:.0f} footprint={footprint:.0f} MB, swap growth={swap - swap0:.0f} MB, pressure={pressure}')
                if proof is None:
                    try:
                        with opener.open(url + '/models', timeout=1) as response:
                            ready = response.status == 200
                    except (urllib.error.URLError, TimeoutError):
                        ready = False
                    if ready:
                        proof = subprocess.Popen(['bash', str(PROCESSOR / 'scripts/test-segmentation-proof.sh'), '--runs', 'local:mac'],
                                                 env=env, stdout=proof_log, stderr=subprocess.STDOUT, start_new_session=True)
                    elif time.monotonic() - started > 90:
                        raise RuntimeError('mlx-vlm did not become ready in 90 s')
                elif finished(proof):
                    completed = True
                    break
                if time.monotonic() - started > 1800:
                    raise RuntimeError('local proof exceeded 30 minutes')
                time.sleep(2)
    except Exception as error:
        metrics['error'] = str(error)
        print(str(error), flush=True)
    finally:
        # A cleanup error for one child must never skip the other child or the evidence file.
        for process in (proof, server):
            try:
                # Allow the inner app supervisor to finish its own bounded teardown before escalation.
                child_rc = stop(process, grace=15 if process is proof else 5)
                if process is proof and completed:
                    rc = child_rc
            except Exception as error:
                metrics.setdefault('cleanup_errors', []).append(str(error))
                rc = 1
        metrics.update(exit=rc, seconds=round(time.monotonic() - started, 1))
        (output / 'guard.json').write_text(json.dumps(metrics, indent=2) + '\n')
    print(json.dumps(metrics, indent=2), flush=True)
    if (output / 'proof.log').exists():
        print((output / 'proof.log').read_text(), flush=True)
    return rc


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output')
    parser.add_argument('--python', default=str(DEFAULT_LAB / 'venv/bin/python'))
    parser.add_argument('--model', default=str(DEFAULT_LAB / 'mlx/seg-qwen3.5-2b-8bit'))
    parser.add_argument('--app', help=argparse.SUPPRESS)
    parser.add_argument('--report', help=argparse.SUPPRESS)
    parser.add_argument('--app-log', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.app:
        if not args.report or not args.app_log:
            parser.error('--app requires --report and --app-log')
        raise SystemExit(run_app(args.app, args.report, args.app_log))
    raise SystemExit(run(args))
