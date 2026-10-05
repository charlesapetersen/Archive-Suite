#!/usr/bin/env python3
"""Scratch process trees: direct stop, EXIT, TERM, INT, and the launcher's real running check.
No installed daemon, launchd, app, network, or owner state is touched.
"""
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
LIB = HERE / 'fixture-processes.sh'
LAUNCHER = HERE.parent / 'daemon.sh'
PASS = 0


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
        for mode in ('stop', 'exit', 'failure', 'term', 'int'):
            scratch = root / mode
            script = root / f'{mode}.sh'
            record = root / f'{mode}.pids'
            script.write_text(f'''set -uo pipefail
T={shlex.quote(str(scratch))}; mkdir -p "$T"
. {shlex.quote(str(LIB))}
fixture_launch bash {shlex.quote(str(sleeper))}
p1=$P
fixture_launch bash {shlex.quote(str(sleeper))}
p2=$P
printf '%s\\n' "$p1" "$p2" > {shlex.quote(str(record))}
case {mode} in
  stop) stop "$p1" || exit 1; stop "$p2" || exit 1
        stop {peer.pid} && exit 1; exit 0 ;;
  exit) exit 0 ;;
  failure) exit 7 ;;
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
                check(rc == {'term': 143, 'int': 130, 'failure': 7}.get(mode, 0), f'{mode}: exit status retained ({rc})')
                check(await_true(lambda: not any(group_alive(p) for p in pids)), f'{mode}: leaders and descendants reaped')
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
