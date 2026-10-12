#!/usr/bin/env python3
"""Run the real E2E teardown on scratch children, including one that ignores TERM.
No app, daemon, engine, network, corpus, or shared process group is used.
"""
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time

SOURCE = Path(__file__).with_name("e2e-phone-mac.sh").read_text()


def function(name):
    match = re.search(r"^" + name + r"\(\)\{\n.*?^\}", SOURCE, re.M | re.S)
    if not match:
        raise AssertionError(f"cannot extract real E2E function {name}")
    return match.group()


FUNCTIONS = "\n".join(function(name) for name in (
    "redact_ready_token", "redact_closed_maclog", "mac_child_state",
    "stop_mac_test_child", "cleanup", "sanitize_artifacts", "finish_harness",
))
LAUNCH = shlex.split(next(line.rstrip(" \\") for line in SOURCE.splitlines() if line.startswith("python3 -c ")))
passed = 0


def check(ok, label):
    global passed
    if not ok:
        raise AssertionError(label)
    passed += 1
    print("PASS", label, flush=True)


with tempfile.TemporaryDirectory(prefix="e2e cleanup [scratch] ") as directory:
    root = Path(directory)
    child = root / "child.py"
    child.write_text('''import os, signal, sys, time
from pathlib import Path
mode, ready = sys.argv[1:3]
def stopped(signum, frame):
    print("FINAL_WRITE token=FAKE_BEARER", flush=True)
    sys.exit(0)
if mode == "exec-term":
    mask = signal.pthread_sigmask(signal.SIG_BLOCK, [])
    assert signal.SIGTERM not in mask, "launcher left TERM blocked"
    assert signal.SIGHUP in mask, "launcher unblocked an unrelated signal"
    assert sys.argv[3:] == ["space value", ""], "launcher changed spaced/empty arguments"
    assert os.getppid() == int(os.environ["EXPECTED_PARENT"]), "launcher changed parent"
else:
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
signal.signal(signal.SIGTERM, signal.SIG_IGN if mode == "ignore" else stopped)
Path(ready).write_text(str(os.getpid()))
if mode == "exit":
    stopped(0, None)
while True:
    time.sleep(.05)
''')

    def run_case(name, mode="term", peer=None, exit_status=None):
        work = root / name
        work.mkdir()
        maclog, ready, report, marker = (work / n for n in ("mac.log", "ready.txt", "report.txt", "child.ready"))
        ready.write_text("READY token=FAKE_BEARER\n")
        report.write_text("report\n")
        launch = f"python3 {shlex.quote(str(child))} {mode} {shlex.quote(str(marker))} >\"$MACLOG\" 2>&1 &\nMAC_PID=$!"
        if mode == "exec-term":
            launch = shlex.join(LAUNCH + [sys.executable, str(child), mode, str(marker), "space value", ""]) + ' >"$MACLOG" 2>&1 &\nMAC_PID=$!'
        if peer is not None:
            maclog.write_text("PRESERVE token=FAKE_BEARER\n")
            launch = f"MAC_PID={peer.pid}"
        else:
            launch += f"\nfor n in $(seq 1 100); do [ -f {shlex.quote(str(marker))} ] && break; sleep .02; done"
            launch += f"\n[ -f {shlex.quote(str(marker))} ] || exit 9"
            launch += f'\n[ "$(cat {shlex.quote(str(marker))})" = "$MAC_PID" ] || exit 8'
            if mode == "exit":
                launch += "\nsleep .1"
        body = 'cleanup; rc=$?; cleanup || rc=1; exit "$rc"'
        if exit_status is not None:
            body = f"trap finish_harness EXIT\nexit {exit_status}"
        script = f'''set -uo pipefail
MACLOG={shlex.quote(str(maclog))}
READYFILE={shlex.quote(str(ready))}
REPORT={shlex.quote(str(report))}
SHOTS={shlex.quote(str(work))}
MAC_PID=""
export EXPECTED_PARENT=$$
log() {{ printf '%s\n' "$*"; }}
{FUNCTIONS}
{launch}
{body}
'''
        started = time.monotonic()
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGHUP, signal.SIGTERM})
        try:
            proc = subprocess.Popen(["bash", "-c", script], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        try:
            output, _ = proc.communicate(timeout=25)
        except subprocess.TimeoutExpired:
            # Only this proof's own recorded children are eligible for emergency cleanup.
            if marker.exists():
                pid = int(marker.read_text())
                row = subprocess.run(["ps", "-p", str(pid), "-o", "ppid="], capture_output=True, text=True)
                if row.stdout.strip() == str(proc.pid):
                    import os
                    os.kill(pid, signal.SIGKILL)
            proc.kill()
            proc.communicate()
            raise AssertionError(f"{name}: real cleanup exceeded its bound")
        check(time.monotonic() - started < 20, f"{name}: teardown is bounded")
        if peer is None:
            check(marker.exists(), f"{name}: child reached launch invariants: {maclog.read_text()!r}")
            pid = marker.read_text().strip()
            alive = subprocess.run(["ps", "-p", pid, "-o", "pid="], capture_output=True, text=True)
            check(not alive.stdout.strip(), f"{name}: owned child is gone")
        return proc.returncode, output, maclog.read_text(), ready.read_text()

    for mode in ("term", "ignore", "exit", "exec-term"):
        rc, output, log, ready = run_case(mode, mode)
        check(rc == 0, f"{mode}: cleanup succeeds and is idempotent")
        check("FAKE_BEARER" not in log + ready, f"{mode}: closed artifacts are redacted")
        if mode != "ignore":
            check("FINAL_WRITE token=[REDACTED]" in log, f"{mode}: final child write precedes redaction")
            check("with KILL" not in output, f"{mode}: no unnecessary KILL")
        else:
            check("with KILL" in output, "ignore: TERM resistance reaches the owned-child KILL path")

    peer_ready = root / "peer.ready"
    peer = subprocess.Popen(["python3", str(child), "term", str(peer_ready)], stdout=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if peer_ready.exists():
                break
            time.sleep(.02)
        check(peer_ready.exists(), "counterweight peer is ready")
        for status in (None, 0, 7):
            rc, output, log, _ = run_case(f"foreign-{status}", peer=peer, exit_status=status)
            check(rc == (7 if status == 7 else 1), f"foreign-{status}: refusal propagates through cleanup/EXIT")
            check(peer.poll() is None, f"foreign-{status}: unowned peer remains alive")
            check(log == "PRESERVE token=FAKE_BEARER\n", f"foreign-{status}: live log inode is not replaced")
    finally:
        peer.terminate()
        peer.wait(timeout=5)

    rc, _, _, _ = run_case("failure-exit", exit_status=7)
    check(rc == 7, "EXIT cleanup preserves an existing failure status")

print(f"E2E CLEANUP: {passed} checks passed")
