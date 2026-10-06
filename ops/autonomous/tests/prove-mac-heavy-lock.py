#!/usr/bin/env python3
"""W35.machine-lock: the Mac-wide heavy lock shared with Vision OCR, on a scratch lock path.

Proves two projects never hold it at once (through the CLI and through heavy-run.py), a dead
holder is reclaimed, a fresh half-taken lock is not, nesting takes nothing, a heavy-run waiting
on the Mac lock is watchdog work and its gate cap is not started, and a mutant of heavy-run.py
without the take turns the exclusion check red.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent.parent
LOCKPY = HERE / "mac-heavy-lock.py"
HEAVY = HERE / "heavy-run.py"
PASS = 0


def check(value, label):
    global PASS
    assert value, label
    PASS += 1
    print("PASS " + label, flush=True)


def until(predicate, seconds=10):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(.05)
    return False


def interval(log, tag, seconds=.15):
    # Appends "<tag> start" / "<tag> end" around a sleep.
    return [sys.executable, "-c", "import sys,time\nf=open(sys.argv[1],'a')\nf.write(sys.argv[2]+' start\\n');"
            "f.flush();time.sleep(float(sys.argv[3]));f.write(sys.argv[2]+' end\\n');f.close()",
            str(log), tag, str(seconds)]


def serialized(log):
    lines = log.read_text().splitlines()
    pairs = [(lines[i], lines[i + 1]) for i in range(0, len(lines) - 1, 2)]
    return len(lines) % 2 == 0 and all(a.endswith(" start") and b == a[:-6] + " end" for a, b in pairs), lines


with tempfile.TemporaryDirectory(prefix="mac heavy [scratch] ") as scratch:
    root = Path(scratch)
    lock = root / "state dir" / "mac-heavy.lock"
    env = dict(os.environ, MAC_HEAVY_LOCK=str(lock), ARCHIVE_UNATTENDED="1", AUTONOMOUS_HEAVY_ENABLED="1")
    env.pop("ARCHIVE_HEAVY_TOKEN", None)
    env.pop("MAC_HEAVY_HELD", None)  # the real gate holds the real lock; this proof must not inherit that
    mlog = lock.parent / "mac-heavy.log"
    procs = []

    def popen(args, **kw):
        # Own session per taker, so cleanup can kill a holder's grandchildren (they keep the pipes open).
        p = subprocess.Popen(args, env=dict(env, **kw.pop("extra", {})), stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, start_new_session=True, **kw)
        procs.append(p)
        return p

    def cli(project, *command):
        return popen([sys.executable, str(LOCKPY), "--project", project, "run", "--", *command])

    def heavy(helper, state, *command, ready=None):
        args = [sys.executable, str(helper), "--state", str(state)] + (["--ready", str(ready)] if ready else [])
        return popen(args + ["run", "--", *command])

    def done(p, expected=0):
        out, err = p.communicate(timeout=30)
        assert p.returncode == expected, (p.returncode, out, err)
        return out, err

    def status():
        return subprocess.run([sys.executable, str(LOCKPY), "status"], env=env, capture_output=True,
                              text=True).stdout

    def owner_pid():
        try:
            return int(dict(l.split("=", 1) for l in (lock / "owner").read_text().splitlines())["pid"])
        except (OSError, KeyError, ValueError):
            return 0

    try:
        check(status().startswith("free") and not lock.exists(), "status is read-only and reports free")

        # 1. Two projects through the CLI: never both inside.
        log = root / "cli.log"
        racers = [cli("archive-suite" if i % 2 else "vision-ocr", *interval(log, "%s%d" % ("ab"[i % 2], i)))
                  for i in range(8)]
        for p in racers:
            done(p)
        ok, lines = serialized(log)
        check(ok and len(lines) == 16, "eight takers from two projects never overlap")
        check(not lock.exists(), "holders release on exit")

        # 2. heavy-run.py (Archive Suite, separate heavy states = separate worktree machines) vs a Vision OCR
        #    CLI taker: heavy.lock alone could not serialize these, only the Mac lock does.
        def mixed(helper, tag, seconds=.15):
            log = root / ("mixed-%s.log" % tag)
            ps = []
            for i in range(6):
                if i % 2:
                    ps.append(heavy(helper, root / ("heavy-%s-%d" % (tag, i)), *interval(log, "h%d" % i, seconds)))
                else:
                    ps.append(cli("vision-ocr", *interval(log, "v%d" % i, seconds)))
            for p in ps:
                done(p)
            return serialized(log)

        ok, lines = mixed(HEAVY, "real")
        check(ok and len(lines) == 12, "heavy-run.py and a Vision OCR taker never overlap")

        # 3. Mutant: heavy-run.py without the take must turn exclusion red.
        source = HEAVY.read_text()
        needle = 'got = mac_lock.attempt('
        check(source.count(needle) == 1, "mutation site present")
        # The mutant lives in scratch, beside its own copy of the lock helper; 1 s intervals make the
        # unserialised overlap certain even under the daemon's QoS clamp.
        mutant = root / "mutant" / "heavy-run.py"
        mutant.parent.mkdir()
        (mutant.parent / LOCKPY.name).write_text(LOCKPY.read_text())
        mutant.write_text(source.replace(needle, 'got = "nested" or mac_lock.attempt('))
        ok, _ = mixed(mutant, "mutant", 1.0)
        check(not ok, "mutant without the take overlaps (the proof can fail)")

        # 4. A SIGKILLed holder is reclaimed, and the reclaim is logged.
        ready = root / "holder-ready"
        holder = cli("vision-ocr", sys.executable, "-c",
                     "import sys,time;open(sys.argv[1],'w').close();time.sleep(60)", str(ready))
        check(until(ready.exists) and owner_pid() == holder.pid, "holder owns the lock")
        os.killpg(holder.pid, signal.SIGKILL)
        holder.communicate()
        check("STALE" in status(), "status flags a dead holder")
        t = time.monotonic()
        done(cli("archive-suite", "true"))
        check(time.monotonic() - t < 5 and not lock.exists(), "dead holder is reclaimed")
        check("(vision-ocr, pid %d)" % holder.pid in mlog.read_text().split("reclaimed from dead holder")[-1],
              "reclaim is logged")

        # 5. A half-taken lock (no owner file): fresh is respected, old is reclaimed.
        lock.mkdir()
        late = cli("archive-suite", "true")
        time.sleep(1.5)
        check(late.poll() is None, "a fresh lock without an owner file is waited on")
        old = time.time() - 120
        os.utime(lock, (old, old))
        done(late)
        check(not lock.exists(), "an old lock without an owner file is reclaimed")

        # 6. Live holder: a waiter waits (logged once), heavy-run's wait is watchdog work and its
        #    --ready (which starts the gate cap) is not written until it holds the lock.
        ready = root / "live-ready"
        holder = cli("vision-ocr", sys.executable, "-c",
                     "import sys,time;open(sys.argv[1],'w').close();time.sleep(60)", str(ready))
        check(until(ready.exists), "live holder acquired")
        hstate = root / "heavy-wait"
        gate_ready = root / "gate-ready"
        waiter = heavy(HEAVY, hstate, "true", ready=gate_ready)
        probe = lambda: subprocess.run([sys.executable, str(HEAVY), "--state", str(hstate), "waiting",
                                        str(waiter.pid)], env=env).returncode
        check(until(lambda: probe() == 0), "heavy-run waiting on the Mac lock is watchdog work")
        time.sleep(1.5)
        check(waiter.poll() is None and not gate_ready.exists(), "gate cap not started while waiting")
        text = mlog.read_text()
        check(text.count("(vision-ocr, pid %d)" % holder.pid) == 1, "the wait is logged once")
        holder.send_signal(signal.SIGTERM)
        done(holder, 128 + signal.SIGTERM)
        done(waiter)
        check(gate_ready.exists() and not lock.exists(), "waiter proceeds after release and releases")
        check(probe() == 1, "no blocker means no waiting liveness")

        # 6b. With heavy.lock free and the Mac lock held, only a waiter marked as blocked by the Mac
        #     lock is watchdog work (a heavy.lock spin with nobody to wait for is not).
        ready = root / "spin-ready"
        holder = cli("vision-ocr", sys.executable, "-c",
                     "import sys,time;open(sys.argv[1],'w').close();time.sleep(60)", str(ready))
        check(until(ready.exists), "holder for waiter-phase case")
        spin = root / "heavy-spin"
        (spin / "waiters").mkdir(parents=True)
        # The "session" is a separate process: the holder must not sit inside it.
        session = popen(["sleep", "30"])
        until(lambda: subprocess.run(["ps", "-p", str(session.pid), "-o", "lstart="], capture_output=True,
                                     text=True).stdout.strip() != "")
        rec = spin / "waiters" / ("0" * 32 + ".json")

        def phase(mac, pid=session.pid):
            start = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="], capture_output=True,
                                   text=True).stdout.strip()
            rec.write_text(json.dumps({"pid": pid, "start": start, "heartbeat": time.time(), "mac": mac}))
            return subprocess.run([sys.executable, str(HEAVY), "--state", str(spin), "waiting", str(pid)],
                                  env=env).returncode
        check(phase(False) == 1, "a heavy.lock spin is not spared by someone else's Mac lock")
        check(phase(True) == 0, "a Mac-lock wait is spared")
        check(phase(True, os.getpid()) == 1, "waiting on a Mac lock held inside the session itself is not spared")
        holder.send_signal(signal.SIGTERM)
        done(holder, 128 + signal.SIGTERM)

        # 6c. Lock order: a hand-run CLI holder whose command needs heavy.lock, while a heavy-run on the
        #     same state queues behind it. Waiting for the Mac lock while holding heavy.lock deadlocks here.
        shared = root / "heavy-shared"
        ready = root / "order-ready"
        outer = cli("archive-suite", "bash", "-c", 'touch "$1"; sleep 1; exec "$2" "$3" --state "$4" run -- true',
                    "_", str(ready), sys.executable, str(HEAVY), str(shared))
        check(until(ready.exists), "CLI holder took the Mac lock first")
        queued = heavy(HEAVY, shared, "true")
        done(outer)
        done(queued)
        check(not lock.exists(), "opposite lock orders both finish (no hold-and-wait)")

        # 6d. A recycled pid: the owner pid is alive but is a different process.
        other = popen(["sleep", "30"])
        lock.mkdir()
        (lock / "owner").write_text("pid=%d\nproject=vision-ocr\nlabel=x\nstart=1000\n" % other.pid)
        check("STALE" in status(), "status flags a recycled pid")
        done(cli("archive-suite", "true"))
        check(not lock.exists(), "a recycled pid's lock is reclaimed")

        # 7. Nesting: a descendant of the holder takes nothing and does not release it.
        out, _ = done(cli("archive-suite", sys.executable, str(LOCKPY), "--project", "archive-suite", "run",
                          "--", sys.executable, str(LOCKPY), "status"))
        check("held by pid" in out, "nested taker runs inside the outer hold")
        check(not lock.exists(), "outer holder still releases")

        # 8. SIGTERM while waiting exits without taking.
        ready = root / "term-ready"
        holder = cli("vision-ocr", sys.executable, "-c",
                     "import sys,time;open(sys.argv[1],'w').close();time.sleep(60)", str(ready))
        check(until(ready.exists), "holder for interrupt case")
        w = cli("archive-suite", "true")
        check(until(lambda: "'true' (pid %d) waiting for" % w.pid in mlog.read_text()),
              "second waiter queued")
        w.send_signal(signal.SIGTERM)
        done(w, 128 + signal.SIGTERM)
        check(owner_pid() == holder.pid, "interrupted waiter leaves the holder's lock alone")
        holder.send_signal(signal.SIGTERM)
        done(holder, 128 + signal.SIGTERM)
    finally:
        for p in procs:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            p.communicate()
print(f"Mac heavy lock proof: {PASS} passed, 0 failed")
