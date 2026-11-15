#!/usr/bin/env python3
"""$0 proof of the real shared headless launcher/teardown with the engine's TERM mask.

No app, keys, network, real corpus, process-name or process-group signals. Every emergency cleanup
checks the exact recorded child's parent before signalling it. Run directly, without the heavy lock.
"""
from pathlib import Path
import os
import shlex
import signal
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
HELPER = HERE / "test-child.sh"
passed = 0


def check(condition, label):
    global passed
    assert condition, label
    passed += 1
    print("PASS", label, flush=True)


def alive(pid):
    return bool(subprocess.run(["ps", "-p", str(pid), "-o", "pid="],
                               capture_output=True, text=True).stdout.strip())


def run_case(root, name, body, *, status=0, blocked=True, keep=False, kill_path=False):
    work = root / name
    scratch = work / "scratch"
    scratch.mkdir(parents=True)
    script = f'''set -euo pipefail
source {shlex.quote(str(HELPER))}
processor_test_init {shlex.quote(str(scratch))}
export EXPECTED_PARENT=$$ PROOF_DIR={shlex.quote(str(work))}
child={shlex.quote(str(root / 'child.py'))}
{body}
'''
    previous = signal.pthread_sigmask(signal.SIG_BLOCK if blocked else signal.SIG_UNBLOCK,
                                      {signal.SIGTERM, signal.SIGHUP, signal.SIGINT})
    # Python launched in a background shell can inherit ignored INT; reset it before execing bash.
    def reset_int():
        signal.signal(signal.SIGINT, signal.SIG_DFL)
    try:
        proc = subprocess.Popen(["bash", "-c", script], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, preexec_fn=reset_int)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)
    started = time.monotonic()
    try:
        output = proc.communicate(timeout=22)[0]
        check(proc.returncode == status, f"{name}: exit {status} ({output.strip()})")
        check(time.monotonic() - started < 20, f"{name}: bounded shutdown")
        check(scratch.exists() == keep, f"{name}: scratch {'kept' if keep else 'removed'}")
        check(("with KILL" in output) == kill_path, f"{name}: expected TERM/KILL path")
        for marker in work.glob("*.pid"):
            check(not alive(int(marker.read_text())), f"{name}: {marker.name} child is gone and reaped")
        return output
    finally:
        # On a failing proof, stop only its exact still-owned children; never leave a fixture behind.
        for marker in work.glob("*.pid"):
            pid = int(marker.read_text())
            parent = subprocess.run(["ps", "-p", str(pid), "-o", "ppid="], capture_output=True, text=True)
            if parent.stdout.strip() == str(proc.pid):
                os.kill(pid, signal.SIGKILL)
        if proc.poll() is None:
            proc.kill()
        proc.communicate(timeout=5)


def cases(root):
    (root / "child.py").write_text('''import os, signal, sys, time
from pathlib import Path
mode, name = sys.argv[1:3]
mask = signal.pthread_sigmask(signal.SIG_BLOCK, [])
assert signal.SIGTERM not in mask, "launcher left TERM blocked"
assert (signal.SIGHUP in mask) == (os.environ.get("EXPECT_HUP", "1") == "1"), "unrelated mask changed"
assert os.getppid() == int(os.environ["EXPECTED_PARENT"]), "launcher changed parent/PID"
assert sys.argv[3:] == ["space value", ""], "arguments changed"
assert os.environ["PROOF_SECRET"] == "env-only-sentinel", "temporary environment assignment was lost"
if mode == "ignore": signal.signal(signal.SIGTERM, signal.SIG_IGN)
if mode == "blocked": signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
Path(os.environ["PROOF_DIR"], name + ".pid").write_text(str(os.getpid()))
if mode == "exit": sys.exit(17)
while True: time.sleep(.02)
''')
    start = '''EXPECT_HUP="$expect_hup" PROOF_SECRET=env-only-sentinel processor_test_start pid python3 "$child" "$mode" app "space value" ""
for ((n=0; n<200; n++)); do [ -f "$PROOF_DIR/app.pid" ] && break; sleep .01; done
[ "$(cat "$PROOF_DIR/app.pid")" = "$pid" ]
'''
    for mode in ("term", "ignore", "blocked", "exit"):
        body = f"mode={mode}; expect_hup=1\n" + start
        if mode == "exit":
            body += "sleep .1\n"
        body += 'processor_test_stop "$pid"\nprocessor_test_stop "$pid"\n'
        run_case(root, mode, body, kill_path=mode in ("ignore", "blocked"))

    for status in (0, 7):
        run_case(root, f"exit-{status}", "mode=term; expect_hup=1\n" + start + f"exit {status}", status=status)

    # The USB harness has a Python fake service and an app, both needing registration and unmasking.
    run_case(root, "two-children", "mode=term; expect_hup=1\n" + start + '''
PROOF_SECRET=env-only-sentinel processor_test_start fake python3 "$child" term fake "space value" ""
for ((n=0; n<200; n++)); do [ -f "$PROOF_DIR/fake.pid" ] && break; sleep .01; done
[ "$(cat "$PROOF_DIR/fake.pid")" = "$fake" ]
''')
    run_case(root, "no-child", "exit 0")
    # Traps are installed before launch. Inject an interrupt at the precise registration boundary.
    for sig, status in (("TERM", 143), ("INT", 130)):
        run_case(root, f"register-{sig}", '''expect_hup=0
set -T
trap 'if [ "$BASH_COMMAND" = "child_pid=\\$!" ]; then trap - DEBUG; printf "%s\\n" "$!" > "$PROOF_DIR/registration.pid"; kill -''' + sig + ''' "$$"; fi' DEBUG
mode=term
''' + start + '\nexit 9', status=status, blocked=False)

    # Forge a stale/corrupt registry entry pointing to a live foreign process. PPID must still veto
    # signalling it, including the KILL fallback; successful and already-failing scripts keep scratch.
    peer = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], stdout=subprocess.DEVNULL)
    try:
        for status in (0, 7):
            output = run_case(root, f"foreign-{status}",
                              f'processor_test_pids=({peer.pid})\nexit {status}',
                              status=status or 1, keep=True)
            check("Cannot verify ownership" in output and peer.poll() is None, "foreign PID never signalled")
    finally:
        peer.kill()
        peer.wait(timeout=5)

    # A failed process inspection cannot authorize a signal or scratch removal, even for an owned PID.
    # Test via stop, then restore ps so EXIT can safely clean up that owned fixture.
    run_case(root, "inspection-refusal", "mode=term; expect_hup=1\n" + start + '''
ps() { return 1; }
if processor_test_stop "$pid"; then exit 9; fi
kill -0 "$pid"
unset -f ps
''')


if __name__ == "__main__":
    if os.environ.get("CODEX_SANDBOX"):
        print("This proof needs ps to verify its scratch children; run outside the Codex sandbox.", file=sys.stderr)
        sys.exit(3)
    with tempfile.TemporaryDirectory(prefix="headless children [scratch] ") as directory:
        cases(Path(directory))
    # Parse every migrated caller, including the ones with optional launch prefixes / multiple children.
    callers = [p for p in HERE.glob("*.sh") if "processor_test_start " in p.read_text()]
    check(len(callers) == 55, "all 54 callers plus the shared helper covered")
    for caller in callers:
        subprocess.run(["bash", "-n", str(caller)], check=True)
    check(True, "all migrated scripts parse")
    print(f"{passed} checks passed")
