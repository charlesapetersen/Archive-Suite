#!/usr/bin/env python3
"""Scratch process trees: direct stop, EXIT, TERM, INT, and the launcher's real running check.
No installed daemon, launchd, app, network, or owner state is touched.
"""
import argparse
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--fixture-lib', type=Path, default=HERE / 'fixture-processes.sh')
parser.add_argument('--launcher', type=Path, default=HERE.parent / 'daemon.sh')
args = parser.parse_args()
LIB = args.fixture_lib.resolve()
LAUNCHER = args.launcher.resolve()
PASS = 0


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


signal.signal(signal.SIGTERM, interrupted)
# A process started in the background by a non-interactive shell (`cmd &`, as the daemon can run the gate)
# inherits SIGINT as IGNORED, exec keeps it ignored, and bash can neither trap nor reset a signal ignored on
# entry — so the int/register-int/cleanup-int fixtures never saw the INT and timed out (gate-fix 2026-10-08).
# Installing a handler here makes every child exec with SIGINT at its default, which the cases require.
signal.signal(signal.SIGINT, signal.default_int_handler)


def check(condition, label):
    global PASS
    if not condition:
        raise AssertionError(label)
    PASS += 1
    print('PASS', label, flush=True)


def group_alive(pid):
    out = subprocess.check_output(['ps', '-ax', '-o', 'pgid='], text=True)
    return str(pid) in out.split()


def await_true(predicate, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(.05)
    return False


with tempfile.TemporaryDirectory(prefix='harness lifecycle [scratch] ') as root:
    root = Path(root)
    sleeper = root / 'sleeper.sh'
    sleeper.write_text('sleep 60 &\nwait\n')
    processes = []
    groups = []
    try:
        # A separate peer is the counterweight: cleanup may kill only the groups this harness recorded.
        peer = subprocess.Popen(['bash', str(sleeper)], start_new_session=True)
        processes.append(peer)
        groups.append(peer.pid)
        for mode in ('stop', 'exit', 'failure', 'term', 'int', 'register-term', 'register-int', 'cleanup-term', 'cleanup-int', 'ps-failure'):
            scratch = root / mode
            script = root / f'{mode}.sh'
            record = root / f'{mode}.pids'
            registration = ''
            if mode.startswith('register-'):
                sig = 'TERM' if mode == 'register-term' else 'INT'
                debug = f'if [ "$BASH_COMMAND" = \'P=$!\' ]; then printf \'%s\\n\' "$!" > {shlex.quote(str(record))}; trap - DEBUG; kill -{sig} "$$"; fi'
                registration = 'set -T\ntrap ' + shlex.quote(debug) + ' DEBUG\n'
            if mode.startswith('cleanup-'):
                sig = 'TERM' if mode == 'cleanup-term' else 'INT'
                debug = f'if [ "$BASH_COMMAND" = \'local pid failed=0\' ]; then trap - DEBUG; kill -{sig} "$$"; fi'
                registration = 'set -T\ntrap ' + shlex.quote(debug) + ' DEBUG\n'
            script.write_text(f'''set -uo pipefail
T={shlex.quote(str(scratch))}; mkdir -p "$T"
. {shlex.quote(str(LIB))}
{registration}fixture_launch bash {shlex.quote(str(sleeper))}
p1=$P
fixture_launch bash {shlex.quote(str(sleeper))}
p2=$P
printf '%s\\n' "$p1" "$p2" > {shlex.quote(str(record))}
case {mode} in
  stop) stop "$p1" || exit 1; stop "$p2" || exit 1
        stop {peer.pid} && exit 1; exit 0 ;;
  exit|cleanup-*) exit 0 ;;
  failure) exit 7 ;;
  ps-failure) ps() {{ [ "$1" = -ax ] && return 1; command ps "$@"; }}; exit 0 ;;
  *) while :; do sleep .1; done ;;
esac
''')
            with (root / f'{mode}.log').open('w') as log:
                harness = subprocess.Popen(['bash', str(script)], stdout=log, stderr=log)
                processes.append(harness)
                check(await_true(record.exists), f'{mode}: both fixture groups registered')
                pids = [int(p) for p in record.read_text().split()]
                groups.extend(pids)
                if mode in ('term', 'int'):
                    check(all(group_alive(p) for p in pids), f'{mode}: groups alive before interrupt')
                    harness.send_signal(signal.SIGTERM if mode == 'term' else signal.SIGINT)
                rc = harness.wait(timeout=8)
                check(rc == {'term': 143, 'int': 130, 'register-term': 143, 'register-int': 130, 'failure': 7, 'ps-failure': 1}.get(mode, 0), f'{mode}: exit status retained ({rc})')
                check(await_true(lambda: not any(group_alive(p) for p in pids)), f'{mode}: leaders and descendants reaped')
                if mode == 'ps-failure':
                    check(scratch.exists(), 'ps-failure: uncertain process inspection retains scratch')
                else:
                    check(not scratch.exists(), f'{mode}: scratch deleted only after reaping')
                check(peer.poll() is None, f'{mode}: unrelated peer survives')

        # Extract the production function and guard, not a copy. Evaluate only that region, never installs
        # or the launch branches. launchctl here is a shell stub, never the host executable.
        source = LAUNCHER.read_text()
        function = source.split('daemon_pids() {', 1)[1].split('\n}', 1)[0]
        function = 'daemon_pids() {' + function + '\n}\n'
        guard = source.split('if daemon_pids >/dev/null \\\n', 1)[1].split('\nfi', 1)[0]
        guard = 'if daemon_pids >/dev/null \\\n' + guard + '\nfi\necho START-ALLOWED\n'
        env = dict(os.environ, TEST_DAEMON_DST=str(root / 'installed home.[x]+/.local/bin/archive-suite-autonomous.sh'))
        target = Path(env['TEST_DAEMON_DST'])
        copies = [root / 'worktree/ops/autonomous/archive-suite-autonomous.sh', Path(str(target) + '.bak'),
                  Path(str(target).replace('home.[x]+', 'homeaxxx'))]
        def verdict(loaded=False):
            env['TEST_JOB_LOADED'] = '1' if loaded else '0'
            code = '''DAEMON_DST="$TEST_DAEMON_DST"; GUI_DOMAIN=fixture; JOB=fixture
launchctl() { [ "$TEST_JOB_LOADED" = 1 ]; }
status() { :; }
''' + function + guard
            return subprocess.check_output(['bash', '-c', code], env=env, text=True)
        for path in copies:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(sleeper.read_text())
            process = subprocess.Popen(['bash', str(path)], start_new_session=True)
            processes.append(process)
            groups.append(process.pid)
        check('START-ALLOWED' in verdict(), 'scratch, suffix, and regex-lookalike copies do not block start')
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(sleeper.read_text())
        installed = subprocess.Popen(['bash', str(target), '--fixture'], start_new_session=True)
        processes.append(installed)
        groups.append(installed.pid)
        check(await_true(lambda: 'ALREADY running' in verdict()), 'installed path with spaces/metacharacters blocks start')
        check(str(installed.pid) in verdict(), 'refusal identifies the installed pid')
        os.killpg(installed.pid, signal.SIGKILL)
        installed.wait()
        check(await_true(lambda: 'START-ALLOWED' in verdict()), 'test copies alone allow start again')
        check('ALREADY running' in verdict(True), 'loaded job still blocks a second launch when process is down')
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        # Let each harness finish its own EXIT reaper even if failure occurred before PID registration.
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        # Only process groups created above, never name-wide pkill or an installed job.
        for pid in groups:
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for process in processes:
            if process.poll() is None:
                process.kill()
            process.wait()
print(f'{PASS} passed')
