#!/usr/bin/env python3
"""W35.machine-lock: the Mac-wide heavy lock shared with Vision OCR, on a scratch lock path.

Proves two projects never hold it at once (through the CLI and through heavy-run.py), a dead
holder is reclaimed, a fresh half-taken lock is not, nesting takes nothing, a heavy-run waiting
on the Mac lock is watchdog work and its gate cap is not started, and a mutant of heavy-run.py
without the take turns the exclusion check red.

All of that runs with AGENT_MANAGER_HEAVY_LOCK pointing at a missing file: the fallback, this copy's
own protocol. The DELEGATE part then points it at a scratch copy of the Agent Manager's heavy-lock
(AGENT_MANAGER_HEAVY_LOCK_SOURCE, default the installed ~/Claude/Agent Manager/bin/heavy-lock; skipped,
and said so, when neither exists) with its state in scratch, and proves the CLI hands over to it, that
delegated, fallback and heavy-run.py takers never overlap, that --lock and a non-executable helper fall
back, that argparse's --opt=value and abbreviated spellings still hand over, that a fake sysctl keeps
the real memory pressure out of it (and a 60 s cap turns a wait red instead of hanging), and that five
mutants of mac-heavy-lock.py each turn a delegate check red.

The R6 part (Agent Manager R6: heavy-run.py takes the Mac lock through the manager's Taker) proves the
holder is the manager's, its queue is first come, first served, nesting still works, the cutover never
makes two holders, and three heavy-run.py mutants each turn a check red. See the block's own comment.
"""
import shutil
import contextlib
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
    env = dict(os.environ, MAC_HEAVY_LOCK=str(lock), ARCHIVE_UNATTENDED="1", AUTONOMOUS_HEAVY_ENABLED="1",
               AGENT_MANAGER_HEAVY_LOCK=str(root / "no manager" / "heavy-lock"))  # the fallback: never the real one
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
        needle = 'return mac_lock.attempt('
        check(source.count(needle) == 1, "mutation site present")
        # The mutant lives in scratch, beside its own copy of the lock helper; 1 s intervals make the
        # unserialised overlap certain even under the daemon's QoS clamp.
        mutant = root / "mutant" / "heavy-run.py"
        mutant.parent.mkdir()
        (mutant.parent / LOCKPY.name).write_text(LOCKPY.read_text())
        mutant.write_text(source.replace(needle, 'return "nested" or mac_lock.attempt('))
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

# ---- DELEGATE: the Agent Manager's shared helper, as a scratch copy ---------------------------------
SOURCE = Path(os.environ.get("AGENT_MANAGER_HEAVY_LOCK_SOURCE")
              or Path.home() / "Claude/Agent Manager/bin/heavy-lock")
if not SOURCE.is_file():
    print("SKIP delegate: no Agent Manager heavy-lock at %s (set AGENT_MANAGER_HEAVY_LOCK_SOURCE)" % SOURCE)
else:
    with tempfile.TemporaryDirectory(prefix="mac heavy delegate [scratch] ") as scratch:
        root = Path(scratch)
        manager = root / "manager bin" / "heavy-lock"
        manager.parent.mkdir()
        shutil.copyfile(SOURCE, manager)
        manager.chmod(0o755)
        mstate = root / "manager state"
        lock = root / "old" / "mac-heavy.lock"
        mowner = mstate / "heavy.owner"
        # A fake sysctl reading "normal": the Mac's real memory pressure at critical (4) would otherwise make
        # every delegated taker wait for it to clear, and this harness is a step of the gate, which holds
        # the real Mac lock while it waits. Pinned here, whatever the caller's environment says.
        sysctl = root / "fake sysctl"
        sysctl.write_text("#!/bin/sh\necho 1\n")
        sysctl.chmod(0o755)
        env = dict(os.environ, MAC_HEAVY_LOCK=str(lock), AGENT_MANAGER_STATE=str(mstate), MAC_HEAVY_POLL="0.1",
                   AGENT_MANAGER_HEAVY_LOCK=str(manager), ARCHIVE_UNATTENDED="1", AUTONOMOUS_HEAVY_ENABLED="1",
                   HEAVY_LOCK_SYSCTL=str(sysctl))
        for k in ("ARCHIVE_HEAVY_TOKEN", "MAC_HEAVY_HELD", "HEAVY_LOCK_FILE", "MAC_HEAVY_PROJECT", "MAC_HEAVY_TOUCH"):
            env.pop(k, None)
        fallback = dict(env, AGENT_MANAGER_HEAVY_LOCK=str(root / "no manager" / "heavy-lock"))
        for path in (manager, mstate, lock):
            assert str(path).startswith(scratch), path  # never the real locks
        procs = []

        def popen(lockpy, args, environ=None):
            p = subprocess.Popen([sys.executable, str(lockpy)] + args, env=environ or env, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, start_new_session=True)
            procs.append(p)
            return p

        def kv(path):
            try:
                return dict(l.split("=", 1) for l in path.read_text().splitlines() if "=" in l)
            except OSError:
                return {}

        def hold(lockpy, args, environ=None):
            ready = root / ("ready-%d" % len(procs))
            p = popen(lockpy, args + ["run", "--", sys.executable, "-c",
                                      "import sys,time;open(sys.argv[1],'w').close();time.sleep(30)", str(ready)],
                      environ)
            return p if until(ready.exists) else None  # None: it never held (a mutant may refuse)

        def pid(p):
            return str(p.pid) if p else "no holder"

        def stop(p):
            if p:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(p.pid, signal.SIGTERM)
                p.communicate(timeout=30)

        def run(lockpy, args, environ=None):
            """The finished CompletedProcess, or one with returncode None and no output if it ran past 60 s:
            a wait that never ends turns a check red instead of hanging the gate."""
            try:
                return subprocess.run([sys.executable, str(lockpy)] + args, env=environ or env,
                                      capture_output=True, text=True, timeout=60)
            except subprocess.TimeoutExpired:
                return subprocess.CompletedProcess(args, None, "", "")

        def delegate_checks(lockpy):
            """(name, ok) for each delegate check, run against this copy of mac-heavy-lock.py."""
            out = []
            r = run(lockpy, ["status"])
            out.append(("status is the manager's", r.stdout.startswith("heavy      free")))
            r = run(lockpy, ["status"], fallback)
            out.append(("missing manager falls back", r.stdout.startswith("free (")))
            r = run(lockpy, ["run", "--", "sh", "-c", "exit 7"])
            out.append(("exit status passes through", r.returncode == 7))
            # argparse's spellings, which the manager's parser does not read, still hand over.
            r = run(lockpy, ["--label=eq-form", "run", "--", "sh", "-c", "exit 7"])
            out.append(("an --opt=value option hands over", r.returncode == 7))
            h = hold(lockpy, ["--label=eq-form"])
            out.append(("the --label=value label reaches the manager", kv(mowner).get("label") == "eq-form"))
            stop(h)
            h = hold(lockpy, ["--proj", "vision-ocr"])
            out.append(("an abbreviated --proj reaches the manager", kv(mowner).get("project") == "vision-ocr"))
            stop(h)
            h = hold(lockpy, [])
            o, old = kv(mowner), kv(lock / "owner")
            out.append(("delegated holder is the manager's, same pid, project archive-suite",
                        o.get("pid") == pid(h) and o.get("project") == "archive-suite"
                        and old.get("pid") == pid(h)))
            stop(h)
            h = hold(lockpy, ["--project", "vision-ocr"])
            out.append(("an explicit --project wins", kv(mowner).get("project") == "vision-ocr"))
            stop(h)
            other = root / "other" / "mac-heavy.lock"
            h = hold(lockpy, ["--lock", str(other)])
            out.append(("--lock falls back", kv(other / "owner").get("pid") == pid(h) and not mowner.exists()))
            stop(h)
            h = hold(lockpy, ["--lo=" + str(other)])
            out.append(("an abbreviated --lo=path falls back",
                        kv(other / "owner").get("pid") == pid(h) and not mowner.exists()))
            stop(h)
            manager.chmod(0o644)
            try:
                r = run(lockpy, ["status"])
                out.append(("non-executable manager falls back", r.stdout.startswith("free (")))
            finally:
                manager.chmod(0o755)
            return out

        try:
            for name, ok in delegate_checks(LOCKPY):
                check(ok, "delegate: " + name)
            check(not lock.exists() and not mowner.exists(), "delegate: every holder released")

            # Delegated CLI takers, fallback CLI takers (an un-switched project) and heavy-run.py: never two inside.
            log = root / "three.log"
            ps = []
            for i in range(9):
                tag = "%s%d" % ("dfh"[i % 3], i)
                cmd = ["--project", "vision-ocr", "run", "--"] + interval(log, tag)
                if i % 3 == 0:
                    ps.append(popen(LOCKPY, cmd))
                elif i % 3 == 1:
                    ps.append(popen(LOCKPY, cmd, fallback))
                else:
                    p = subprocess.Popen([sys.executable, str(HEAVY), "--state", str(root / ("heavy-%d" % i)), "run",
                                          "--"] + interval(log, tag), env=env, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, text=True, start_new_session=True)
                    procs.append(p)
                    ps.append(p)
            for p in ps:
                o, e = p.communicate(timeout=60)
                assert p.returncode == 0, (p.returncode, o, e)
            ok, lines = serialized(log)
            check(ok and len(lines) == 18, "delegate: delegated, fallback and heavy-run.py takers never overlap")

            # Mutants: each must turn at least one delegate check red. Anchors unique, file changed.
            source = LOCKPY.read_text()
            mutants = {
                "no delegate call": ("    delegate(sys.argv[1:])\n", "    pass\n"),
                "--lock not honoured": ('if helper is None or spelled is None or "--lock" in spelled[0]:',
                                        "if helper is None or spelled is None:"),
                "--opt=value not split": ('given, eq, value = argv[i].partition("=")',
                                          'given, eq, value = argv[i], "", ""'),
                "abbreviation not resolved": (" or [o for o in OPTIONS if len(given) > 2 and o.startswith(given)]",
                                              ""),
                "default project dropped": ('[helper, "--project", "archive-suite"] + spelled[1]', "[helper] + spelled[1]"),
            }
            for name, (needle, broken) in mutants.items():
                check(source.count(needle) == 1, "mutant anchor unique: " + name)
                mutant = root / "mutant" / name.replace(" ", "-") / LOCKPY.name
                mutant.parent.mkdir(parents=True)
                mutant.write_text(source.replace(needle, broken))
                check(mutant.read_text() != source, "mutant landed: " + name)
                red = [n for n, ok in delegate_checks(mutant) if not ok]
                check(red, "mutant turns delegate checks red: %s (%s)" % (name, ", ".join(red)))
        finally:
            for p in procs:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                p.communicate()
# ---- R6: heavy-run.py takes the Mac lock THROUGH the manager's helper (Agent Manager R6, 2026-10-08) -------------
# heavy-run.py loads bin/heavy-lock as a module and drives its Taker, so its holder is the manager's holder (seen by
# `heavy-lock status`), its waiters sit in the manager's queue, and the queue is first come, first served across
# projects. Proves: the holder is visible; a manager waiter queued during a heavy-run job goes before the same
# project's next, back-to-back job; nesting inside a held job takes nothing; an old-protocol holder (a job running
# the code from before this change, at cutover) is never joined by a second holder, in either direction; the
# opposite lock order still finishes; and three mutants of heavy-run.py each turn a check red.
if SOURCE.is_file():
    with tempfile.TemporaryDirectory(prefix="mac heavy r6 [scratch] ") as scratch:
        root = Path(scratch)
        manager = root / "manager bin" / "heavy-lock"
        manager.parent.mkdir()
        shutil.copyfile(SOURCE, manager)
        manager.chmod(0o755)
        queue_built = "def ahead(" in manager.read_text()
        mstate = root / "manager state"
        lock = root / "old" / "mac-heavy.lock"
        sysctl = root / "fake sysctl"
        sysctl.write_text("#!/bin/sh\necho 1\n")
        sysctl.chmod(0o755)
        env = dict(os.environ, MAC_HEAVY_LOCK=str(lock), AGENT_MANAGER_STATE=str(mstate), MAC_HEAVY_POLL="0.1",
                   AGENT_MANAGER_HEAVY_LOCK=str(manager), ARCHIVE_UNATTENDED="1", AUTONOMOUS_HEAVY_ENABLED="1",
                   HEAVY_LOCK_SYSCTL=str(sysctl))
        for k in ("ARCHIVE_HEAVY_TOKEN", "MAC_HEAVY_HELD", "HEAVY_LOCK_FILE", "MAC_HEAVY_PROJECT", "MAC_HEAVY_TOUCH",
                  "HEAVY_LOCK_FRESH"):
            env.pop(k, None)
        old_code = dict(env, AGENT_MANAGER_HEAVY_LOCK=str(root / "no manager" / "heavy-lock"))  # the pre-R6 path
        for path in (manager, mstate, lock):
            assert str(path).startswith(scratch), path  # never the real locks
        procs = []
        runs = [0]

        def start(args, environ=None):
            p = subprocess.Popen(args, env=environ or env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                 start_new_session=True)
            procs.append(p)
            return p

        def finish(p, seconds=60):
            """The exit status, or None if it ran past `seconds` (then it is killed): a hang turns a check red."""
            try:
                p.communicate(timeout=seconds)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(p.pid, signal.SIGKILL)
                p.communicate()
                return None
            return p.returncode

        def gated(log, tag, go):
            # "<tag> start", then wait for the go file, then "<tag> end".
            return [sys.executable, "-c", "import os,sys,time\nf=open(sys.argv[1],'a');f.write(sys.argv[2]+' start\\n')"
                    "\nf.flush()\nwhile not os.path.exists(sys.argv[3]): time.sleep(.05)\nf.write(sys.argv[2]+' end\\n')",
                    str(log), tag, str(go)]

        def mstatus():
            return subprocess.run([str(manager), "status"], env=env, capture_output=True, text=True).stdout

        def lines(log):
            return log.read_text().splitlines() if log.exists() else []

        def r6_checks(heavy_py):
            out = []
            runs[0] += 1
            base = root / ("run-%d" % runs[0])
            base.mkdir()

            def heavy(state, command, environ=None):
                return start([sys.executable, str(heavy_py), "--state", str(base / state), "run", "--"] + command,
                             environ)

            # 1 + 3. Holder visible; a manager waiter goes before this project's next back-to-back job.
            log, go = base / "order.log", base / "go-1"
            h1 = heavy("project", gated(log, "h1", go))
            until(lambda: "h1 start" in lines(log))
            st = mstatus()
            out.append(("a heavy-run job is the manager's holder",
                        "heavy      HELD by '" in st and "(archive-suite, pid %d)" % h1.pid in st))
            w = start([str(manager), "run", "--project", "vision-ocr", "--label", "manager-waiter", "--"]
                      + interval(log, "w", .3), dict(env, MAC_HEAVY_POLL="1.5"))
            out.append(("the manager waiter is queued behind it",
                        until(lambda: "label=manager-waiter" in mstatus()) and "w start" not in lines(log)))
            h2 = heavy("project", interval(log, "h2", .3))
            until(lambda: any((base / "project" / "waiters").glob("*.json")))
            time.sleep(.5)
            go.touch()
            rcs = [finish(p) for p in (h1, w, h2)]
            ok, got = serialized(log)
            out.append(("holder, manager waiter and the next job never overlap", rcs == [0, 0, 0] and ok))
            starts = [l.split()[0] for l in got if l.endswith(" start")]
            if queue_built:
                out.append(("first come, first served: the manager waiter before the back-to-back job",
                            starts == ["h1", "w", "h2"]))
            else:
                print("SKIP first-come order: %s predates the manager's queue (merge the Agent Manager R6 branch)"
                      % SOURCE, flush=True)

            # 2. Nesting inside a held job: the same state (token), another state, the manager's CLI with and
            #    without MAC_HEAVY_HELD; all straight through, and the outer still holds afterwards.
            seen = base / "nested-status"
            script = ('set -e; "$1" "$2" --state "$3" run -- true; "$1" "$2" --state "$4" run -- true; '
                      '"$5" run -- true; env -u MAC_HEAVY_HELD "$5" run -- true; "$5" status > "$6" || true')
            n = heavy("nest", ["bash", "-c", script, "_", sys.executable, str(heavy_py), str(base / "nest"),
                               str(base / "nest-other"), str(manager), str(seen)])
            rc = finish(n, 30)
            out.append(("nested takers inside a held job take nothing and finish",
                        rc == 0 and "(archive-suite, pid %d)" % n.pid in (seen.read_text() if seen.exists() else "")))
            out.append(("the outer job releases after nesting", mstatus().startswith("heavy      free")
                        and not lock.exists()))

            # 4. Cutover, old holder first: a job on the pre-R6 code holds only the mkdir lock. A new job waits
            #    (watchdog work, in the manager's queue) and never joins it.
            log, go = base / "cutover.log", base / "go-2"
            old = heavy("old-code", gated(log, "old", go), old_code)
            until(lambda: "old start" in lines(log))
            new = heavy("new-code", interval(log, "new", .3))
            listed = until(lambda: "waiting    pid %d" % new.pid in mstatus())
            st = mstatus()
            probe = subprocess.run([sys.executable, str(heavy_py), "--state", str(base / "new-code"), "waiting",
                                    str(new.pid)], env=env).returncode
            out.append(("a new job waits for an old-code holder, listed in the manager's queue",
                        listed and "old lock   HELD by" in st and "new start" not in lines(log)))
            out.append(("that wait is watchdog work", probe == 0))
            go.touch()
            rcs = [finish(p) for p in (old, new)]
            ok, got = serialized(log)
            out.append(("old-code holder then new job, never both", rcs == [0, 0] and ok and len(got) == 4))

            # 4b. New holder first: a job still on the pre-R6 code (a waiter loaded before the change) waits.
            log, go = base / "cutover-2.log", base / "go-3"
            new = heavy("new-code-2", gated(log, "new", go))
            until(lambda: "new start" in lines(log))
            old = heavy("old-code-2", interval(log, "old", .3), old_code)
            time.sleep(1.5)
            out.append(("an old-code job waits for a new holder", "old start" not in lines(log)))
            go.touch()
            rcs = [finish(p) for p in (new, old)]
            ok, got = serialized(log)
            out.append(("new holder then old-code job, never both", rcs == [0, 0] and ok and len(got) == 4))

            # 5. Opposite lock order: a manager CLI holder whose command needs heavy.lock, while a heavy-run on the
            #    same state queues. Waiting for the Mac lock while holding heavy.lock would deadlock here.
            ready = base / "order-ready"
            outer = start([str(manager), "run", "--", "bash", "-c", 'touch "$1"; sleep 1; exec "$2" "$3" --state "$4" '
                           'run -- true', "_", str(ready), sys.executable, str(heavy_py), str(base / "shared")])
            until(ready.exists)
            queued = heavy("shared", ["true"])
            out.append(("opposite lock orders both finish (no hold-and-wait)",
                        [finish(outer), finish(queued)] == [0, 0]))
            out.append(("every holder released", mstatus().startswith("heavy      free") and not lock.exists()))
            return out

        try:
            for name, ok in r6_checks(HEAVY):
                check(ok, "r6: " + name)
            source = HEAVY.read_text()
            mutants = {
                "manager never loaded": ("    manager = manager_lock()\n", "    manager = None\n"),
                "the taker is never tried": ("    got = taker.attempt()\n", "    got = None\n"),
                "a waiter is not in the manager's queue": ("                    taker.register()\n",
                                                           "                    pass\n"),
            }
            for name, (needle, broken) in mutants.items():
                check(source.count(needle) == 1, "r6 mutant anchor unique: " + name)
                mutant = root / "mutant" / name.replace(" ", "-").replace("'", "") / HEAVY.name
                mutant.parent.mkdir(parents=True)
                shutil.copyfile(LOCKPY, mutant.parent / LOCKPY.name)
                mutant.write_text(source.replace(needle, broken))
                check(mutant.read_text() != source, "r6 mutant landed: " + name)
                red = [n for n, ok in r6_checks(mutant) if not ok]
                check(red, "r6 mutant turns checks red: %s (%s)" % (name, ", ".join(red)))
        finally:
            for p in procs:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                p.communicate()

print(f"Mac heavy lock proof: {PASS} passed, 0 failed")
