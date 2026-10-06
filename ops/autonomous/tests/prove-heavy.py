#!/usr/bin/env python3
"""Exercise real heavy helper, entry wrappers, watchdog and gate execution cap."""
import json
import importlib.util
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
HELPER = HERE / "heavy-run.py"
spec = importlib.util.spec_from_file_location("heavy_helper", HELPER)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
PASS = 0


def check(value, label):
    global PASS
    assert value, label
    PASS += 1
    print("PASS " + label, flush=True)


def until(predicate, seconds=8):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(.05)
    return False


with tempfile.TemporaryDirectory(prefix="heavy work [scratch] ") as scratch:
    root = Path(scratch)
    state = root / "state with space"
    env = dict(os.environ, AUTONOMOUS_HEAVY_STATE=str(state), ARCHIVE_UNATTENDED="1", AUTONOMOUS_HEAVY_ENABLED="1")
    env.pop("ARCHIVE_HEAVY_TOKEN", None)
    children = []
    groups = []

    def spawn(*command, extra=None, ready=None):
        args = [sys.executable, str(HELPER), "--state", str(state)]
        if ready:
            args += ["--ready", str(ready)]
        p = subprocess.Popen([*args, "run", "--", *command], env=dict(env, **(extra or {})),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        children.append(p)
        return p

    def owner():
        r = json.loads((state / "owner.json").read_text())
        if (r["child"], r["child_start"]) not in groups:
            groups.append((r["child"], r["child_start"]))
        return r

    def probe(action, *args, extra=None):
        return subprocess.run([sys.executable, str(HELPER), "--state", str(state), action, *map(str, args)],
                              env=dict(env, **(extra or {})), capture_output=True, text=True)

    def finish(p, expected=0):
        out, err = p.communicate(timeout=10)
        assert p.returncode == expected, (p.returncode, out, err)
        return out

    try:
        check(probe("held").returncode == 1 and not state.exists(), "ownership query is read-only")
        log = root / "events"
        command = ("from pathlib import Path; import time; "
                   f"p=Path({str(log)!r}); "
                   "f=p.open('a'); f.write('start\\n'); f.flush(); time.sleep(.2); "
                   "f.write('end\\n'); f.close()")
        racers = [spawn(sys.executable, "-c", command) for _ in range(8)]
        for p in racers:
            finish(p)
        check(log.read_text().splitlines() == ["start", "end"] * 8, "eight competing workers serialize")
        check(not (state / "owner.json").exists(), "normal exit retires ownership")
        nested = root / "nested.sh"
        nested.write_text(f'''set -e
. {shlex.quote(str(HERE / 'heavy-enter.sh'))}
python3 {shlex.quote(str(HELPER))} held
python3 {shlex.quote(str(HELPER))} run -- python3 {shlex.quote(str(HELPER))} held
echo nested-ok
''')
        check("nested-ok" in finish(spawn("bash", str(nested))), "nested scripts and tools reuse validated ownership")
        finish(spawn("bash", "-c", "exit 7"), 7)
        check(True, "command failure preserves exit status and releases lock")
        finish(spawn(str(root / "missing")), 127)
        check(True, "missing executable fails and releases lock")
        held_ready = root / "held-ready"
        holder = spawn(sys.executable, "-c", "import time; time.sleep(60)", ready=held_ready)
        check(until(held_ready.exists), "holder acquired lock")
        r = owner()
        old = time.time() - 100000
        os.utime(state / "heavy.lock", (old, old))
        waiting_ready = root / "waiting-ready"
        waiter = spawn("true", ready=waiting_ready)
        check(until(lambda: probe("waiting", waiter.pid).returncode == 0), "fresh validated waiter is watchdog work")
        check(not waiting_ready.exists(), "live owner remains protected regardless of age")
        source = (HERE / "archive-suite-autonomous.sh").read_text()
        watchdog_fn = source[source.index("health_watchdog() {"):source.index("\ntick() {")]
        watchdog = root / "watchdog.sh"
        watchdog.write_text(f'''set -uo pipefail
HEAVY_CMD={shlex.quote(str(HELPER))}
HEAVY_STATE={shlex.quote(str(state))}
HB_POLL=.1; HB_STALL=1; HB_IDLE_N=1; HB_HARD=2; HB_CPU=3; AGENT=claude
LOG={shlex.quote(str(root / 'watchdog.log'))}
KILLED={shlex.quote(str(root / 'killed'))}
_meaningful_bytes() {{ echo 0; }}
_has_claude_descendant() {{ return 1; }}
_tree_cpu() {{ echo 0; }}
_terminate_tree() {{ echo killed >> "$LOG"; }}
{watchdog_fn}
health_watchdog {waiter.pid} /dev/null 0
''')
        monitor = subprocess.Popen(["bash", str(watchdog)], env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        children.append(monitor)
        time.sleep(2.2)
        check(monitor.poll() is None and not (root / "killed").exists(),
              "real watchdog spares a quiet CPU-idle session waiting for heavy work")

        check(probe("waiting", os.getpid() + 10000000).returncode == 1, "unrelated session gains no waiter liveness")
        check(probe("held", extra={"ARCHIVE_HEAVY_TOKEN": r["token"]}).returncode == 1,
              "a copied token in an unrelated session cannot bypass the lock")
        waiter.send_signal(signal.SIGTERM)
        finish(waiter, 143)
        check(not list((state / "waiters").glob("*.json")), "cancelled waiter retires its heartbeat")
        finish(monitor)
        check(True, "watchdog exits when its waiting session exits")
        holder.send_signal(signal.SIGTERM)
        finish(holder, 143)
        check(probe("waiting", os.getpid()).returncode == 1, "no owner means no waiting liveness")
        # Child deliberately closes inherited descriptors. The durable session
        # record must protect it even after the supervisor suffers SIGKILL.
        surviving = root / "surviving-ready"
        release_survivor = root / "release-survivor"
        holder = spawn(sys.executable, "-c",
                       "import os,time; from pathlib import Path; os.closerange(3,256); " +
                       f"p=Path({str(release_survivor)!r})\nwhile not p.exists(): time.sleep(.05)", ready=surviving)
        check(until(surviving.exists), "crash fixture acquired lock")
        r = owner()
        time.sleep(.15)
        holder.kill()
        holder.wait()
        after = root / "after-crash"
        waiter = spawn("true", ready=after)
        time.sleep(.4)
        check(not after.exists(), "surviving child protects work after supervisor death and fd closure")
        release_survivor.touch()
        finish(waiter)
        check(after.exists(), "dead child session is reclaimed without an age override")
        holder.communicate()
        detached_ready = root / "detached-ready"
        release_detached = root / "release-detached"
        detached_result = root / "detached-result"
        nested_command = (f"from pathlib import Path; import time,subprocess,sys\np=Path({str(release_detached)!r})\n"
                          "while not p.exists(): time.sleep(.05)\n" +
                          f"r=subprocess.run([sys.executable,{str(HELPER)!r},'run','--','true'])\n" +
                          f"Path({str(detached_result)!r}).write_text(str(r.returncode))")
        detached = spawn(sys.executable, "-c",
                         "import subprocess,sys; p=subprocess.Popen([sys.executable," + repr(str(HELPER)) +
                         ", 'run','--',sys.executable,'-c'," + repr(nested_command) +
                         "],start_new_session=True); p.wait()", ready=detached_ready)
        check(until(detached_ready.exists), "detached nested fixture acquired ownership")
        r = owner()
        check(until(lambda: bool(list((state / "members").glob(r["token"] + "-*.json")))),
              "nested helper durably protects its separate session")
        detached.kill()
        detached.wait()
        if helper.identity(r["child"]) == r["child_start"]:
            os.killpg(r["child"], signal.SIGTERM)
        after_detached = root / "after-detached"
        waiter = spawn("true", ready=after_detached)
        time.sleep(.35)
        check(not after_detached.exists(), "separate nested session survives original owner/group death without overlap")
        release_detached.touch()
        finish(waiter)
        detached.communicate()
        check(after_detached.exists(), "detached nested ownership retires after its real process exits")
        check(detached_result.read_text() == "0", "surviving registered session can nest after its original ancestor exits")
        # A poisoned record refuses, rather than silently admitting two owners.
        (state / "owner.json").write_text("not json")
        finish(spawn("true"), 2)
        check(True, "corrupt ownership fails closed")
        (state / "owner.json").unlink()
        # Refusals must happen before lock waiting; stubs never reach Xcode/app.
        blockready = root / "guard-holder"
        holder = spawn("sleep", "60", ready=blockready)
        check(until(blockready.exists), "guard fixture owns lock")
        owner()
        fake = root / "fake-xcodebuild"
        fake.write_text("#!/bin/bash\necho real-ran\n")
        fake.chmod(0o755)
        shim = HERE / "bin/xcodebuild"
        for args, extra, expected in ((["test"], {"CODEX_SANDBOX": "seatbelt"}, 3),
                                     (["test"], {"CODEX_SANDBOX": ""}, 74)):
            p = subprocess.run(["bash", str(shim), *args], env=dict(env, ARCHIVE_REAL_TOOL=str(fake), **extra),
                               capture_output=True, text=True, timeout=3)
            check(p.returncode == expected and "real-ran" not in p.stdout, "GUI/sandbox refusal precedes heavy waiting")
        holder.terminate()
        finish(holder, 143)
        p = subprocess.run(["bash", str(shim), "build"], env=dict(env, ARCHIVE_REAL_TOOL=str(fake)),
                           capture_output=True, text=True, timeout=5)
        check(p.returncode == 0 and "real-ran" in p.stdout, "safe shim build still reaches the real tool")
        # Extract the real gate function, retaining every timer branch. A
        # competing lock lasts longer than the execution cap; instant gate passes.
        source = (HERE / "archive-suite-autonomous.sh").read_text()
        gate_fn = source[source.index("_run_gate_once() {"):source.index("\n# Classify the gate's RED")]
        gate = root / "gate.sh"
        gate.write_text("#!/bin/bash\necho gate-ran\n")
        gate.chmod(0o755)
        timing = root / "timing.sh"
        timing.write_text(f'''set -uo pipefail
STATE={shlex.quote(str(root))}
HEAVY_CMD={shlex.quote(str(HELPER))}
HEAVY_STATE={shlex.quote(str(state))}
GATE_CMD={shlex.quote(str(gate))}
glog={shlex.quote(str(root / 'gate.log'))}
GATE_MAXRUN=2
_terminate_tree() {{ kill -TERM "$1"; }}
{gate_fn}
_run_gate_once
echo "gate-rc=$GATE_RC"
''')
        ready = root / "timer-holder"
        holder = spawn("sleep", "3", ready=ready)
        check(until(ready.exists), "timer fixture owns lock")
        owner()
        p = subprocess.run(["bash", str(timing)], env=env, capture_output=True, text=True, timeout=12)
        finish(holder)
        check(p.returncode == 0 and "gate-rc=0" in p.stdout and "gate-ran" in (root / "gate.log").read_text(),
              "gate execution cap excludes contention longer than the cap")
        check('waiting "$cpid"' in source and 'quiet_since=0; idle_streak=0; continue' in source,
              "watchdog consults validated heavy waiters and resets idle budget")
        vm_lock = root / "old-live-vm-lock"
        vm_lock.mkdir()
        (vm_lock / "pid").write_text(str(os.getpid()))
        os.utime(vm_lock, (old, old))
        vm_probe = subprocess.run(["bash", "-c", '. "$1"; tart_lock_acquire 0; echo "vm-rc=$?"',
                                   "vm-proof", str(ROOT / "ops/gui/tart-lib.sh")],
                                  env=dict(env, TART_LOCK_DIR=str(vm_lock), TART_LOCK_STALE="1"),
                                  capture_output=True, text=True, timeout=3)
        check("vm-rc=1" in vm_probe.stdout and vm_lock.exists(),
              "old VM lock never evicts its live owner")
        # Pin whole-script coverage before any cwd changes or VM acquisition.
        entries = ("test-smoke.sh", "ops/autonomous/health-gate.sh", "ops/autonomous/gui-vm-gate.sh",
                   "ops/gui/vm-gui-runner.sh", "ArchiveReader/test-smoke.sh", "ArchiveNotes/test-smoke.sh",
                   "ArchiveProcessor/test-smoke.sh", "ArchiveProcessor/scripts/require-unsandboxed.sh",
                   "ArchiveProcessor/scripts/android-ui-drive.sh", "ArchiveProcessor/scripts/test-relay-golden.sh",
                   "ArchiveProcessor/scripts/test-tag-vocabulary.sh", "ops/scale/run-scale-verify.sh")
        for path in entries:
            text = (ROOT / path).read_text()
            check("heavy-enter.sh" in text, "whole-script ownership wired: " + path)
        for path in ("ops/autonomous/gui-vm-gate.sh", "ops/gui/vm-gui-runner.sh"):
            text = (ROOT / path).read_text()
            check(text.index("heavy-enter.sh") < text.index("tart_lock_acquire"), "heavy-before-VM ordering: " + path)
    finally:
        # Release crash fixtures even if an assertion interrupted the proof.
        for name in ("release-survivor", "release-detached"):
            (root / name).touch()
        for pid, birth in groups:
            try:
                if helper.identity(pid) == birth:
                    os.killpg(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        for p in children:
            if p.poll() is None:
                p.terminate()
            try:
                p.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
                p.communicate()
print(f"Heavy work proof: {PASS} passed, 0 failed")
