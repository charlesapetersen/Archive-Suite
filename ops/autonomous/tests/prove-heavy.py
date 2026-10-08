#!/usr/bin/env python3
"""Exercise real heavy helper, entry wrappers, watchdog and gate execution cap."""
import json
import importlib.util
import os
from pathlib import Path
import shlex
import shutil
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
    env = dict(os.environ, AUTONOMOUS_HEAVY_STATE=str(state), ARCHIVE_UNATTENDED="1", AUTONOMOUS_HEAVY_ENABLED="1",
               MAC_HEAVY_LOCK=str(root / "mac-heavy.lock"))
    env.pop("ARCHIVE_HEAVY_TOKEN", None)
    env.pop("MAC_HEAVY_HELD", None)
    for name in ("AGENT_MANAGER_STATE", "HEAVY_LOCK_FILE", "AUTONOMOUS_WORKER_STATE"):
        env.pop(name, None)  # the manager's real heavy-jobs.log is never a fixture
    # No proof below reaches the installed Agent Manager unless it names a scratch copy (a guard mutant that
    # skipped this once wrote 22 fixture jobs into the owner's real heavy-jobs.log, 7 Oct 2026).
    env["AGENT_MANAGER_HEAVY_LOCK"] = str(root / "no manager installed")
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
        waits = [line.split("\t") for line in (state / "waits.log").read_text().splitlines()]
        # Up to 7 of the 8 racers block (fewer if one starts after its predecessor ends); nothing else does.
        check(waits[-1][2] == "true" and float(waits[-1][1]) >= .4 and 1 <= len(waits) - 1 <= 7
              and all("events" in w[2] for w in waits[:-1]),
              "only blocked entries are recorded in waits.log, with their wait time")
        holder.communicate()
        # A non-UTF-8 argument must not turn the wait record into "heavy work refused".
        bytes_ready = root / "bytes-ready"
        holder = spawn(sys.executable, "-c", "import time; time.sleep(.6)", ready=bytes_ready)
        check(until(bytes_ready.exists), "byte-argument fixture acquired lock")
        r = subprocess.run([os.fsencode(sys.executable), os.fsencode(HELPER), b"--state", os.fsencode(state),
                            b"run", b"--", b"true", b"a\xffb"], env=env, capture_output=True)
        finish(holder)
        check(r.returncode == 0 and "a\\udcffb" in (state / "waits.log").read_text(),
              "a waited entry with a non-UTF-8 argument still runs, and is logged escaped")
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
        # Build-free queries skip the lock; anything that compiles still waits for it (efficiency plan round 1).
        for query in (["-list"], ["-showBuildSettings", "-scheme", "X"], ["-version"], ["-showsdks"]):
            p = subprocess.run(["bash", str(shim), *query], env=dict(env, ARCHIVE_REAL_TOOL=str(fake)),
                               capture_output=True, text=True, timeout=3)
            check(p.returncode == 0 and "real-ran" in p.stdout, "xcodebuild %s runs while the lock is held" % query[0])
        try:
            subprocess.run(["bash", str(shim), "-scheme", "X", "build"], env=dict(env, ARCHIVE_REAL_TOOL=str(fake)),
                           capture_output=True, text=True, timeout=2)
            waited = False
        except subprocess.TimeoutExpired:
            waited = True
        check(waited, "a build still waits for the held lock")
        # Old installed supervisors lack wait liveness and readiness timing;
        # their source wrappers stay on the old path until an owner restart.
        entry = root / "entry.sh"
        entry_marker = root / "entry-marker"
        entry_cleanup = root / "entry-cleanup"
        entry.write_text(f'''set -e
. {shlex.quote(str(HERE / 'heavy-enter.sh'))}
trap {shlex.quote("touch " + shlex.quote(str(entry_cleanup)))} EXIT
printf '%s' "$1" > {shlex.quote(str(entry_marker))}
''')
        legacy = subprocess.run(["bash", str(entry), "sentinel value"], env=dict(env, AUTONOMOUS_HEAVY_ENABLED="0"),
                                capture_output=True, text=True, timeout=3)
        check(legacy.returncode == 0 and entry_marker.read_text() == "sentinel value" and entry_cleanup.exists(),
              "old unattended supervisor does not activate source locking before restart")
        entry_marker.unlink()
        entry_cleanup.unlink()
        activated = subprocess.Popen(["bash", str(entry), "sentinel value"], env=env, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True)
        children.append(activated)
        check(until(lambda: probe("waiting", activated.pid).returncode == 0) and not entry_marker.exists(),
              "restarted supervisor serializes entry before any script work")
        holder.terminate()
        finish(holder, 143)
        finish(activated)
        check(entry_marker.read_text() == "sentinel value" and entry_cleanup.exists(), "activated entry resumes after contention without losing argv or traps")
        p = subprocess.run(["bash", str(shim), "build"], env=dict(env, ARCHIVE_REAL_TOOL=str(fake)),
                           capture_output=True, text=True, timeout=5)
        check(p.returncode == 0 and "real-ran" in p.stdout, "safe shim build still reaches the real tool")
        # Extract the real gate function, retaining every timer branch. A
        # competing lock lasts longer than the execution cap; instant gate passes.
        source = (HERE / "archive-suite-autonomous.sh").read_text()
        gate_fn = source[source.index("_run_gate_once() {"):source.index("\n# Classify the gate's RED")]
        gate = root / "gate.sh"
        light = root / "gate-light-ran"
        # A gate whose light part runs unlocked and whose one heavy step queues for the held lock.
        gate.write_text("#!/bin/bash\ntouch %s\npython3 %s --state %s run -- true || exit 1\necho gate-ran\n"
                        % (shlex.quote(str(light)), shlex.quote(str(HELPER)), shlex.quote(str(state))))
        gate.chmod(0o755)
        timing = root / "timing.sh"
        timing.write_text(f'''set -uo pipefail
STATE={shlex.quote(str(root))}
HEAVY_CMD={shlex.quote(str(HELPER))}
HEAVY_STATE={shlex.quote(str(state))}
GATE_CMD={shlex.quote(str(gate))}
glog={shlex.quote(str(root / 'gate.log'))}
GATE_MAXRUN=10
_terminate_tree() {{ kill -TERM "$1"; }}
{gate_fn}
_run_gate_once
echo "gate-rc=$GATE_RC"
''')
        ready = root / "timer-holder"
        holder = spawn("sleep", "30", ready=ready)
        check(until(ready.exists), "timer fixture owns lock")
        owner()
        gate_run = subprocess.Popen(["bash", str(timing)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        children.append(gate_run)
        check(until(light.exists) and holder.poll() is None,
              "the gate's light steps run while another job holds the heavy lock (no whole-gate lock)")
        # The REAL health gate takes no whole-gate lock: a light step runs to completion while the lock is held.
        real_gate = subprocess.run(["bash", str(HERE / "health-gate.sh")], env=dict(env, AUTONOMOUS_GATE_ONLY="context-budget"),
                                   capture_output=True, text=True, timeout=60)
        check(holder.poll() is None and "✓ context-budget" in real_gate.stdout and "HEALTH GATE: GREEN (re-ran only" in real_gate.stdout,
              "health-gate.sh runs its light steps while another job holds the lock")
        out, _ = gate_run.communicate(timeout=90)
        check(gate_run.returncode == 0 and "gate-rc=0" in out and "gate-ran" in (root / "gate.log").read_text(),
              "gate execution cap excludes a step's lock wait longer than the cap")
        if holder.poll() is None:
            holder.terminate()
        holder.communicate(timeout=10)
        gate.write_text("#!/bin/bash\nsleep 25\necho gate-ran\n")
        p = subprocess.run(["bash", str(timing)], env=env, capture_output=True, text=True, timeout=60)
        check("gate-rc=2" in p.stdout, "a gate that really runs past the cap is still stopped")
        # The light-block harnesses that drive the real shim or the real VM gate (vm-lane-proof, gui-vm-proof)
        # must use a scratch lock of their own. Inheriting the gate's lock, they queued behind real work inside
        # the unlocked light block, then held the Mac-wide lock for a fake tool (7 Oct 2026, pid 17075).
        holds = state / "holds.log"
        holds_before = holds.read_text() if holds.exists() else ""
        waiters_before = {w.name for w in (state / "waiters").glob("*.json")}
        ready = root / "light-harness-holder"
        holder = spawn("sleep", "150", ready=ready)
        check(until(ready.exists), "light-harness fixture owns the lock")
        owner()
        try:
            light_gate = subprocess.run(["bash", str(HERE / "health-gate.sh")],
                                        env=dict(env, AUTONOMOUS_GATE_ONLY="vm-lane-proof gui-vm-proof"),
                                        capture_output=True, text=True, timeout=120)
            light_out = light_gate.stdout
        except subprocess.TimeoutExpired as e:
            partial = e.stdout or b""
            light_out = "TIMED OUT (queued on the held lock?)\n" + (
                partial.decode(errors="replace") if isinstance(partial, bytes) else partial)
        check(holder.poll() is None and "✓ vm-lane-proof" in light_out and "✓ gui-vm-proof" in light_out
              and "HEALTH GATE: GREEN (re-ran only" in light_out,
              "vm-lane-proof and gui-vm-proof finish while another job holds the gate's lock: " + light_out[-600:])
        check({w.name for w in (state / "waiters").glob("*.json")} <= waiters_before
              and (holds.read_text() if holds.exists() else "") == holds_before,
              "the light harnesses neither queue on nor hold the gate's lock: %r %r" % (
                  sorted({w.name for w in (state / "waiters").glob("*.json")} - waiters_before),
                  (holds.read_text() if holds.exists() else "")[len(holds_before):]))
        holder.terminate()
        holder.communicate(timeout=10)
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
                   "ArchiveProcessor/scripts/test-tag-vocabulary.sh", "ops/scale/run-scale-verify.sh",
                   "ops/gui/vm-seed-accessibility.sh",
                   "ArchiveProcessor/scripts/test-controlled-vocabulary.sh",
                   "ArchiveProcessor/scripts/test-thinking-budgets.sh",
                   "ArchiveProcessor/scripts/test-output-file-safety.sh",
                   "ArchiveProcessor/scripts/test-vision-ocr.sh",
                   "ArchiveProcessor/scripts/test-drive-store.sh",
                   "ArchiveProcessor/scripts/test-drive-transport.sh",
                   "ArchiveProcessor/scripts/test-relay-transport.sh",
                   "ArchiveProcessor/scripts/test-drive-live.sh")
        for path in entries:
            text = (ROOT / path).read_text()
            check("heavy-enter.sh" in text, "whole-script ownership wired: " + path)
        for path in ("ops/autonomous/gui-vm-gate.sh", "ops/gui/vm-gui-runner.sh",
                     "ops/gui/vm-seed-accessibility.sh"):
            text = (ROOT / path).read_text()
            check(text.index("heavy-enter.sh") < text.index("tart_lock_acquire"), "heavy-before-VM ordering: " + path)
        # Hold time and the Agent Manager's load record (efficiency plan round 1, unit 5).
        hold_state = root / "hold state"
        mstate = root / "manager state"

        def held_run(extra):
            p = subprocess.Popen([sys.executable, str(HELPER), "--state", str(hold_state), "run", "--", "sleep", "0.4"],
                                 env=dict(env, **extra), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            p.communicate(timeout=60)
            return p
        p = held_run({"AGENT_MANAGER_HEAVY_LOCK": str(root / "no manager")})
        holds = (hold_state / "holds.log").read_text().splitlines()
        f = holds[-1].split("\t")
        check(p.returncode == 0 and len(holds) == 1 and len(f) == 5 and float(f[2]) >= .4
              and f[3] == "interactive:" + str(p.pid) and f[4] == "sleep 0.4",
              "each held job logs start, end, seconds held, holder and command")
        check(not mstate.exists(), "with no manager installed the job runs and records nothing else")
        p = held_run({"AGENT_MANAGER_HEAVY_LOCK": str(root / "no manager"), "AUTONOMOUS_WORKER_STATE": "/s/worker-2"})
        check(p.returncode == 0 and (hold_state / "holds.log").read_text().splitlines()[-1].split("\t")[3]
              == "worker-2:" + str(p.pid), "a worker's held job names that worker")
        source = Path(os.environ.get("AGENT_MANAGER_HEAVY_LOCK_SOURCE",
                                     str(Path.home() / "Claude/Agent Manager/bin/heavy-lock")))
        if source.is_file():
            manager = root / "manager" / "heavy-lock"
            manager.parent.mkdir()
            shutil.copy2(source, manager)
            jobs = mstate / "heavy-jobs.log"
            mstate.mkdir()
            p = held_run({"AGENT_MANAGER_HEAVY_LOCK": str(manager), "AGENT_MANAGER_STATE": str(mstate),
                          "HEAVY_LOCK_SAMPLE_EVERY": "0.1"})
            check(p.returncode == 0 and until(lambda: jobs.exists() and jobs.read_text().strip(), 30),
                  "a held job reaches the manager's heavy-jobs.log")
            rec = json.loads(jobs.read_text().splitlines()[-1])
            check(rec["project"] == "archive-suite" and rec["command"] == "sleep 0.4" and rec["rc"] == 0
                  and rec["duration"] >= .4 and rec["samples"] >= 2,
                  "the manager's record names the project, the command, its status, duration and samples")
            before = jobs.read_text()
            # HOME is scratch here, so even a broken guard writes only to scratch-home's default manager state.
            home = root / "scratch home"
            (home / ".local/state/agent-manager").mkdir(parents=True)  # so a broken guard WOULD leave a record
            p = held_run({"AGENT_MANAGER_HEAVY_LOCK": str(manager), "HEAVY_LOCK_SAMPLE_EVERY": "0.1", "HOME": str(home)})
            time.sleep(2)
            check(p.returncode == 0 and jobs.read_text() == before
                  and not (home / ".local/state/agent-manager/heavy-jobs.log").exists(),
                  "a scratch Mac lock without a scratch manager state never samples into a manager log")
        else:
            print("SKIP manager load record: no Agent Manager heavy-lock at " + str(source), flush=True)
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
