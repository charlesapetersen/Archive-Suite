#!/usr/bin/env python3
"""Prove the Processor smoke's real child teardown and pass/fail oracle on scratch.

Default mode runs the smoke script's own functions (extracted from its source, never re-typed) against
scratch children from a parent that blocks TERM, as the autonomous engine does: a child that stops on
TERM, one that ignores it, one already gone, the script's exact launch line, and a live process that is
not the script's child. Then the oracle against fixtures, including the real API-502 run that the old
oracle passed. No app, network, key, corpus or process group is touched.

    python3 ArchiveProcessor/scripts/test-smoke-teardown.py
    python3 ArchiveProcessor/scripts/test-smoke-teardown.py --real <ArchiveProcessor binary> <input dir> [mixed]

--real launches the built app headless with the script's launch block, waits for TEST_DONE, stops it with
the script's teardown and judges it with the script's oracle, all from a TERM-blocked parent. It reads the
Gemini key from the Keychain and spends what one smoke run spends (tiny images, gemini-2.5-flash-lite).
"""
from pathlib import Path
import os
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time

SOURCE = (Path(__file__).resolve().parent.parent / "test-smoke.sh").read_text()


def function(name):
    match = re.search(r"^" + name + r"\(\)\{\n.*?^\}", SOURCE, re.M | re.S)
    if not match:
        raise AssertionError(f"cannot extract real smoke function {name}")
    return match.group()


TEARDOWN = "\n".join(function(n) for n in ("smoke_child_state", "stop_smoke_child", "finish_smoke"))
ORACLE = function("check_smoke_result")
LAUNCH = shlex.split(next(line.rstrip(" \\") for line in SOURCE.splitlines() if line.startswith("python3 -c ")))
LAUNCH_BLOCK = re.search(r"^PROCESSFILES_TESTMODE=1 \\\n.*?^SMOKE_PID=\$!$", SOURCE, re.M | re.S).group()
passed = 0


def check(ok, label):
    global passed
    if not ok:
        raise AssertionError(label)
    passed += 1
    print("PASS", label, flush=True)


def run_blocked(script, timeout):
    """Run bash from a parent with TERM and HUP blocked, so the child inherits the engine's mask."""
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGHUP, signal.SIGTERM})
    try:
        proc = subprocess.Popen(["bash", "-c", script], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)
    return proc, proc.communicate(timeout=timeout)[0]


def owned_kill(marker, parent):
    """Emergency cleanup for this proof's own recorded child only."""
    if marker.exists():
        pid = int(marker.read_text())
        row = subprocess.run(["ps", "-p", str(pid), "-o", "ppid="], capture_output=True, text=True)
        if row.stdout.strip() == str(parent):
            os.kill(pid, signal.SIGKILL)


def teardown_cases(root):
    child = root / "child.py"
    child.write_text('''import os, signal, sys, time
from pathlib import Path
mode, ready = sys.argv[1:3]
if mode == "exec-term":
    mask = signal.pthread_sigmask(signal.SIG_BLOCK, [])
    assert signal.SIGTERM not in mask, "launcher left TERM blocked"
    assert signal.SIGHUP in mask, "launcher unblocked an unrelated signal"
    assert sys.argv[3:] == ["space value", ""], "launcher changed spaced/empty arguments"
    assert os.getppid() == int(os.environ["EXPECTED_PARENT"]), "launcher changed parent"
else:
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
if mode == "inherit":
    # The pre-fix launch: TERM stays blocked, so the default action never runs.
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
    mode = "term"
if mode == "ignore":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(ready).write_text(str(os.getpid()))
if mode == "exit":
    sys.exit(0)
while True:
    time.sleep(.05)
''')

    def run_case(name, mode="term", peer=None, exit_status=None):
        work = root / name
        (work / "scratch").mkdir(parents=True)
        marker = work / "child.ready"
        if peer is not None:
            launch = f"SMOKE_PID={peer.pid}"
        else:
            if mode == "exec-term":
                launch = shlex.join(LAUNCH + [sys.executable, str(child), mode, str(marker), "space value", ""])
            else:
                launch = f"python3 {shlex.quote(str(child))} {mode} {shlex.quote(str(marker))}"
            launch += " >/dev/null 2>&1 &\nSMOKE_PID=$!"
            launch += f"\nfor n in $(seq 1 100); do [ -f {shlex.quote(str(marker))} ] && break; sleep .02; done"
            launch += f"\n[ -f {shlex.quote(str(marker))} ] || exit 9"
            launch += f'\n[ "$(cat {shlex.quote(str(marker))})" = "$SMOKE_PID" ] || exit 8'
            if mode == "exit":
                launch += "\nsleep .2"
        body = "trap finish_smoke EXIT\n" + (f"exit {exit_status}" if exit_status is not None
                                               else 'stop_smoke_child; rc=$?; stop_smoke_child || rc=1; trap - EXIT; exit "$rc"')
        script = f'''set -uo pipefail
WORK={shlex.quote(str(work / "scratch"))}
SMOKE_PID=""
export EXPECTED_PARENT=$$
{TEARDOWN}
{launch}
{body}
'''
        started = time.monotonic()
        try:
            proc, output = run_blocked(script, 25)
        except subprocess.TimeoutExpired:
            raise AssertionError(f"{name}: teardown exceeded its bound")
        check(time.monotonic() - started < 20, f"{name}: teardown is bounded")
        if peer is None:
            check(marker.exists(), f"{name}: child reached launch invariants ({output.strip()!r})")
            alive = subprocess.run(["ps", "-p", marker.read_text().strip(), "-o", "pid="], capture_output=True, text=True)
            check(not alive.stdout.strip(), f"{name}: owned child is gone")
        return proc.returncode, output, (work / "scratch").exists()

    for mode in ("term", "ignore", "exit", "exec-term", "inherit"):
        rc, output, _ = run_case(mode, mode)
        check(rc == 0, f"{mode}: stop succeeds and is idempotent")
        if mode in ("ignore", "inherit"):
            check("with KILL" in output, f"{mode}: TERM resistance reaches the owned-child KILL path")
        else:
            check("with KILL" not in output, f"{mode}: no unnecessary KILL")

    for status in (0, 7):
        rc, _, kept = run_case(f"finish-{status}", exit_status=status)
        check(rc == status, f"finish-{status}: EXIT teardown preserves status {status}")
        check(not kept, f"finish-{status}: scratch removed once the child is stopped")

    peer_ready = root / "peer.ready"
    peer = subprocess.Popen([sys.executable, str(child), "term", str(peer_ready)], stdout=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if peer_ready.exists():
                break
            time.sleep(.02)
        check(peer_ready.exists(), "unowned peer is ready")
        rc, output, _ = run_case("foreign", peer=peer)
        check(rc == 1 and "cannot verify ownership" in output, "foreign: refuses to signal a nonchild")
        for status in (0, 7):
            rc, output, kept = run_case(f"foreign-finish-{status}", peer=peer, exit_status=status)
            check(rc == (7 if status == 7 else 1), f"foreign-finish-{status}: refusal fails the run")
            check(kept and "scratch kept" in output, f"foreign-finish-{status}: scratch kept while a process may use it")
        check(peer.poll() is None, "foreign: unowned peer remains alive")
    finally:
        peer.terminate()
        peer.wait(timeout=5)


def oracle(out, want):
    script = f"{ORACLE}\ncheck_smoke_result {shlex.quote(str(out / 'TEST_DONE.txt'))} {shlex.quote(str(out))} {want}"
    proc = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=10)
    return proc.returncode, proc.stdout.strip()


def fixture(root, name, marker, rows, pdfs, inputs=None, succeeded=None, failed=None, manifest=True):
    out = root / "oracle" / name
    run = out / "run-1"
    run.mkdir(parents=True)
    if marker is not None:
        (out / "TEST_DONE.txt").write_text(marker)
    ok = sum(1 for r in rows if r[1] == "succeeded") if succeeded is None else succeeded
    inputs = len(rows) if inputs is None else inputs
    failed = len(rows) - ok if failed is None else failed
    if manifest:
        lines = [f"# provider=Gemini\tmodel=gemini-2.5-flash-lite\tmode=automatic\tinputs={inputs}\tsucceeded={ok}\tfailed={failed}\tsegments={len(rows)}",
                 "# pdf\tclassification\tstatus"]
        lines += [f"{r[0]}\t{r[2] if len(r) > 2 else ('document_start' if r[1] == 'succeeded' else '')}\t{r[1]}" for r in rows]
        (run / "manifest.tsv").write_text("\n".join(lines))
    for pdf in pdfs:
        (run / pdf).write_bytes(b"%PDF-1.4 scratch\n")
    return out


def oracle_cases(root):
    good = [("input1.pdf", "succeeded"), ("input2.pdf", "succeeded")]
    both = ["input1.pdf", "input2.pdf"]
    rc, out = oracle(fixture(root, "pass", "Done. 2 succeeded, 0 failed. 2 segments tagged.", good, both), 2)
    check(rc == 0 and out.startswith("Done. 2 succeeded, 0 failed."), f"oracle: all-succeeded run passes and prints its marker ({rc}: {out})")
    plain = [("input1.pdf", "succeeded", ""), ("input2.pdf", "succeeded", "")]
    rc, _ = oracle(fixture(root, "unclassified", "Done. 2 succeeded, 0 failed.", plain, both), 2)
    check(rc == 0, "oracle: a succeeded job with an empty classification still passes")
    mixed = good + [("mixed.pdf", "succeeded")]
    rc, _ = oracle(fixture(root, "mixed", "Done. 3 succeeded, 0 failed.", mixed, both + ["mixed.pdf"]), 3)
    check(rc == 0, "oracle: three-input mixed run passes")

    # The run W41.ocr-prompt-app recorded: an API 502 left a placeholder PDF, and the old oracle said PASS.
    red = {
        "api-502": ("Done. 1 succeeded, 1 failed. 2 segments tagged.", [good[0], ("input2.pdf", "failed")], both, {}),
        "marker-lies": ("Done. 2 succeeded, 0 failed.", [good[0], ("input2.pdf", "failed")], both, {"failed": 0}),
        "header-lies": ("Done. 2 succeeded, 0 failed.", [good[0], ("input2.pdf", "failed")], both, {"succeeded": 2, "failed": 0}),
        "error-marker": ("ERROR: no inputs", good, both, {}),
        "no-marker": (None, good, both, {}),
        "short-run": ("Done. 1 succeeded, 0 failed.", good[:1], both[:1], {}),
        "missing-pdf": ("Done. 2 succeeded, 0 failed.", good, both[:1], {}),
        "extra-pdf": ("Done. 2 succeeded, 0 failed.", good, both + ["stray.pdf"], {}),
        "unmapped-output": ("Done. 2 succeeded, 0 failed.", [good[0], ("", "succeeded")], both, {}),
        "no-manifest": ("Done. 2 succeeded, 0 failed.", good, both, {"manifest": False}),
    }
    for name, (marker, rows, pdfs, extra) in red.items():
        rc, out = oracle(fixture(root, name, marker, rows, pdfs, **extra), 2)
        check(rc == 1 and out, f"oracle: {name} goes red ({out})")


def real(binary, inputs, mixed):
    key = subprocess.run(["security", "find-generic-password", "-s", "com.archiveprocessor.app", "-a", "Gemini", "-w"],
                         capture_output=True, text=True).stdout.strip()
    check(bool(key), "real: Gemini key available")
    expected = 3 if mixed else 2
    with tempfile.TemporaryDirectory(prefix="smoke teardown real ") as directory:
        work = Path(directory)
        out, applog = work / "out", work / "app.log"
        out.mkdir()
        script = f'''set -uo pipefail
WORK={shlex.quote(str(work / "unused"))}
SMOKE_PID=""
KEY="$SMOKE_KEY"; unset SMOKE_KEY
EXPECTED={expected}
PROCESSFILES_TEST_MIXED={1 if mixed else 0}
IN={shlex.quote(str(inputs))}
OUT={shlex.quote(str(out))}
DONE="$OUT/TEST_DONE.txt"
BIN={shlex.quote(str(binary))}
APPLOG={shlex.quote(str(applog))}
{TEARDOWN}
{ORACLE}
{LAUNCH_BLOCK}
echo "CHILD $SMOKE_PID"
for _ in $(seq 1 90); do [ -f "$DONE" ] && break; sleep 2; done
stop_smoke_child || {{ echo "STOP FAILED"; exit 3; }}
rm -f "$HOME/Library/Application Support/ArchiveProcessor/pending_run.json" \\
      "$HOME/Library/Application Support/ArchiveProcessor/pending_batch.json" 2>/dev/null
result=$(check_smoke_result "$DONE" "$OUT" "$EXPECTED") || {{ echo "ORACLE RED: $result"; exit 4; }}
echo "ORACLE GREEN: $result"
'''
        os.environ["SMOKE_KEY"] = key
        started = time.monotonic()
        try:
            proc, output = run_blocked(script, 300)
        finally:
            del os.environ["SMOKE_KEY"]
        print(output.replace(key, "[KEY]"), end="")
        print(f"real: {time.monotonic() - started:.0f}s, rc={proc.returncode}")
        check(proc.returncode == 0 and "ORACLE GREEN" in output, "real: blocked-TERM run exits by itself and passes the oracle")
        check("with KILL" not in output, "real: the app stopped on TERM, no KILL needed")
        pid = re.search(r"CHILD (\d+)", output).group(1)
        alive = subprocess.run(["ps", "-p", pid, "-o", "pid="], capture_output=True, text=True)
        check(not alive.stdout.strip(), "real: the app is gone")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--real"]:
        real(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4:5] == ["mixed"])
    else:
        syntax = subprocess.run(["bash", "-n"], input=SOURCE, capture_output=True, text=True)
        check(syntax.returncode == 0, f"smoke script parses ({syntax.stderr.strip()})")
        with tempfile.TemporaryDirectory(prefix="smoke teardown [scratch] ") as directory:
            teardown_cases(Path(directory))
            oracle_cases(Path(directory))
    print(f"{passed} checks passed")
