#!/usr/bin/env python3
"""Serialize heavy work across worktrees, with validated nesting and wait liveness.

After heavy.lock it also takes the Mac-wide lock shared with Vision OCR
(mac-heavy-lock.py, W35.machine-lock), held until the child session ends.

The kernel lock has no age expiry. A published child session protects work even
if the supervisor is killed and a tool closes its inherited lock descriptor.
Unknown/corrupt ownership fails closed. All proofs use an explicit scratch state.
"""
import argparse
import contextlib
import fcntl
import importlib.util
import json
import os
import re
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

_spec = importlib.util.spec_from_file_location("mac_heavy_lock", Path(__file__).with_name("mac-heavy-lock.py"))
mac_lock = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mac_lock)


def identity(pid):
    if type(pid) is not int or pid <= 0:
        return ""
    p = subprocess.run(["ps", "-p", str(pid), "-o", "stat=,lstart="],
                       capture_output=True, text=True)
    if p.stderr.strip():
        raise RuntimeError("cannot inspect heavy owner: " + p.stderr.strip())
    fields = p.stdout.strip().split(maxsplit=1)
    return fields[1] if p.returncode == 0 and len(fields) == 2 and "Z" not in fields[0] else ""


def read(path):
    if not path.exists():
        return None
    r = json.loads(path.read_text())
    if not isinstance(r, dict) or not isinstance(r.get("token"), str) or not re.fullmatch(r"[a-f0-9]{32}", r["token"]):
        raise RuntimeError("invalid heavy ownership record")
    for key in ("owner", "child"):
        if type(r.get(key)) is not int or r[key] <= 0 or not isinstance(r.get(key + "_start"), str):
            raise RuntimeError("invalid heavy process identity")
    return r


def publish(path, record):
    tmp = path.with_name(path.name + "." + str(os.getpid()) + ".tmp")
    tmp.write_text(json.dumps(record))
    os.replace(tmp, path)


def session_live(r):
    # Child PID is also its session ID. A new process reusing that PID is
    # conservatively protected; there is never a reason to evict a live group.
    p = subprocess.run(["ps", "-ax", "-o", "pid=,stat="], capture_output=True, text=True)
    if p.returncode != 0 or p.stderr.strip():
        raise RuntimeError("cannot inspect heavy child session")
    for line in p.stdout.splitlines():
        fields = line.split()
        if len(fields) == 2 and "Z" not in fields[1]:
            try:
                if os.getsid(int(fields[0])) == r["child"]:
                    return True
            except ProcessLookupError:
                continue
    return False


def basic_active(r):
    return (bool(r["owner_start"]) and identity(r["owner"]) == r["owner_start"] or
            bool(r["child_start"]) and identity(r["child"]) == r["child_start"] or session_live(r))


def members_live(state, token):
    for path in (state / "members").glob(token + "-*.json"):
        r = read(path)
        if r and r["token"] == token and basic_active(r):
            return True
    return False


def active(state, r):
    return basic_active(r) or members_live(state, r["token"])


@contextlib.contextmanager
def metadata_lock(state):
    with (state / "metadata.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def protect(state, pid):
    # Serialize with stale-owner replacement. An ancestor can die between the
    # initial nesting query and publication; revalidate under this short lock.
    with metadata_lock(state):
        if not held(state):
            raise RuntimeError("ownership changed before nested entry")
        r = read(state / "owner.json")
        sid = os.getsid(pid)
        members = state / "members"
        members.mkdir(exist_ok=True)
        publish(members / (r["token"] + "-" + str(pid) + ".json"),
                {"token": r["token"], "owner": pid, "owner_start": identity(pid),
                 "child": sid, "child_start": identity(sid)})


def retire_members(state, token):
    for path in (state / "members").glob(token + "-*.json"):
        r = read(path)
        if r and r["token"] == token and not basic_active(r):
            path.unlink(missing_ok=True)


def descendant(pid, root):
    p = subprocess.run(["ps", "-ax", "-o", "pid=,ppid="], capture_output=True, text=True)
    if p.returncode != 0 or p.stderr.strip():
        raise RuntimeError("cannot inspect heavy ancestry")
    parents = {int(a): int(b) for a, b in (line.split() for line in p.stdout.splitlines())}
    seen = set()
    while pid > 0 and pid not in seen:
        if pid == root:
            return True
        seen.add(pid)
        pid = parents.get(pid, 0)
    return False


def belongs(r):
    leader = identity(r["child"])
    if os.getsid(0) == r["child"] and (not leader or leader == r["child_start"]):
        return True
    return bool(r["owner_start"] and identity(r["owner"]) == r["owner_start"] and
                descendant(os.getpid(), r["owner"]))


def held(state):
    token = os.environ.get("ARCHIVE_HEAVY_TOKEN", "")
    if not token:
        return False
    r = read(state / "owner.json")
    if not r or r["token"] != token or not active(state, r):
        return False
    # A surviving registered session can nest even after the original ancestor
    # exits. Token alone and a reused PID/session leader are never sufficient.
    root_member = dict(r, owner=r["child"], owner_start=r["child_start"])
    if belongs(root_member):
        return True
    for path in (state / "members").glob(token + "-*.json"):
        member = read(path)
        if member and member["token"] == token and belongs(member):
            return True
    return False


def waiting(state, root):
    r = read(state / "owner.json")
    heavy_busy = bool(r and active(state, r))
    m = None if heavy_busy else mac_lock.read_owner(mac_lock.lock_path())
    # A Mac-lock holder inside the session itself is a self-wait, not queued work.
    if not heavy_busy and not (m and mac_lock.alive(m) and not descendant(m["pid"], root)):
        return False
    for path in (state / "waiters").glob("*.json"):
        w = json.loads(path.read_text())
        # With heavy.lock free, only a waiter its last attempt found blocked by the Mac lock counts.
        if (time.time() - w["heartbeat"] < 10 and identity(w["pid"]) == w["start"]
                and (heavy_busy or w.get("mac")) and descendant(w["pid"], root)):
            return True
    return False


HOLDS_KEEP = 2000             # holds.log keeps its newest lines once it passes HOLDS_MAX_BYTES
HOLDS_MAX_BYTES = 512 * 1024


def log_hold(state, start, end, command):
    """One line per held job: start, end, seconds held, holder, command (efficiency plan, 2026-10-07).

    waits.log says how long work queued for the lock; this says how long the lock was then HELD, so a change
    to what holds it can be measured. Bounded; never a reason to fail the work."""
    worker = os.environ.get("AUTONOMOUS_WORKER_STATE", "")
    holder = (Path(worker).name if worker else "interactive") + ":" + str(os.getpid())
    line = "%s\t%s\t%.1f\t%s\t%s\n" % (time.strftime("%F %T", time.localtime(start)),
                                         time.strftime("%F %T", time.localtime(end)), end - start, holder,
                                         " ".join(command)[:200].replace("\t", " ").replace("\n", " "))
    path = state / "holds.log"
    try:
        with metadata_lock(state), path.open("a", errors="backslashreplace") as log:
            log.write(line)
            log.flush()
            if log.tell() > HOLDS_MAX_BYTES:
                lines = path.read_text(errors="backslashreplace").splitlines(keepends=True)[-HOLDS_KEEP:]
                tmp = path.with_name(path.name + ".tmp")
                tmp.write_text("".join(lines), errors="backslashreplace")
                os.replace(tmp, path)
    except (OSError, ValueError):
        pass


def start_load_sampler(pid, label, command):
    """The Agent Manager's load sampler for this held job, when the manager is installed; else None.

    Archive Suite takes the Mac lock itself (mac-heavy-lock.py's old protocol), so `heavy-lock run` never sees
    its jobs, and a nested `heavy-lock run` under MAC_HEAVY_HELD=1 runs straight through without sampling.
    So the sampler (`heavy-lock _sample`) is started directly: it appends one record per job to the manager's
    heavy-jobs.log and holds no lock. Any failure records nothing and never touches the job."""
    helper = mac_lock.manager_helper()
    # A scratch Mac lock (every harness) records into the real log only if it names a scratch manager state too.
    if not helper or (os.environ.get("MAC_HEAVY_LOCK") and not os.environ.get("AGENT_MANAGER_STATE")):
        return None
    try:
        sampler = subprocess.Popen([helper, "_sample"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, close_fds=True)
        sampler.stdin.write((json.dumps({"pid": pid, "project": "archive-suite", "label": label,
                                         "command": " ".join(command), "start": time.time()}) + "\n").encode())
        sampler.stdin.flush()
        return sampler
    except Exception:
        return None


def stop_load_sampler(sampler, rc):
    if sampler is None:
        return
    try:
        sampler.stdin.write(("end %d\n" % rc).encode())
        sampler.stdin.close()
    except Exception:
        pass


def run(state, command, ready):
    if held(state):
        protect(state, os.getpid())
        if ready:
            ready.write_text("ready\n")
        os.execvp(command[0], command)
    state.mkdir(parents=True, exist_ok=True)
    waiters = state / "waiters"
    waiters.mkdir(exist_ok=True)
    token = uuid.uuid4().hex
    waiter = waiters / (token + ".json")
    child = None
    interrupted = 0

    def stop(signum, _frame):
        nonlocal interrupted
        interrupted = signum
        if child is not None and child.poll() is None:
            # An unreaped child cannot have its PID reused. Once it is reaped,
            # surviving registered sessions keep ownership until they exit;
            # never signal a potentially reused process-group ID.
            # Signal only our freshly-created child group, never a lock owner.
            try:
                os.killpg(child.pid, signum)
            except ProcessLookupError:
                pass

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, stop)
    owner_path = state / "owner.json"
    waited_from = None
    machine = None
    session_done = False
    label = " ".join(command)[:120]
    mac_logged = False
    held_from = None
    sampler = None

    with (state / "heavy.lock").open("a+") as lock:
        try:
            blocked_by_mac = False
            while not interrupted:
                blocker = None
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    with metadata_lock(state):
                        old = read(owner_path)
                        if not old or not active(state, old):
                            if old:
                                retire_members(state, old["token"])
                            # W35.machine-lock: then the Mac-wide lock shared with Vision OCR, tried
                            # ONCE. Never wait for it holding heavy.lock: its holder may need heavy.lock
                            # next (a hand-run `mac-heavy-lock.py run`), and that would deadlock.
                            got = mac_lock.attempt("archive-suite", label)
                            if not isinstance(got, dict):
                                machine = got
                                break
                            blocker = got
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    blocked_by_mac = bool(blocker)
                except BlockingIOError:
                    pass  # another worker's turn at heavy.lock: what this one waits on is unchanged
                if blocker and not mac_logged:
                    mac_logged = True
                    mac_lock.log_wait("archive-suite", label, blocker)
                if waited_from is None:
                    waited_from = time.time()
                # "mac" lets the watchdog tell a Mac-lock wait from a heavy.lock spin.
                publish(waiter, {"pid": os.getpid(), "start": identity(os.getpid()),
                                 "heartbeat": time.time(), "mac": blocked_by_mac})
                # Each try runs `ps`; behind the Mac lock (minutes, on a loaded Mac) poll gently.
                time.sleep(1 if blocked_by_mac else .25)
            if interrupted:
                return 128 + interrupted
            if mac_logged:
                mac_lock.log_got("archive-suite", label)
            waiter.unlink(missing_ok=True)
            if waited_from is not None:
                # W35.live counts these waits; the record is never a reason to refuse the work.
                try:
                    with (state / "waits.log").open("a", errors="backslashreplace") as log:
                        log.write("%s\t%.1f\t%s\n" % (time.strftime("%F %T", time.localtime(waited_from)),
                                                      time.time() - waited_from,
                                                      " ".join(command)[:200].replace("\t", " ").replace("\n", " ")))
                except (OSError, ValueError):
                    pass
            # The launcher cannot execute the command before its birth/session
            # identity is durable. EOF on supervisor death makes it exit safely.
            rd, wr = os.pipe()
            # MAC_HEAVY_HELD tells a Vision OCR helper under this command that the Mac lock is covered.
            env = dict(os.environ, ARCHIVE_HEAVY_TOKEN=token, AUTONOMOUS_HEAVY_ENABLED="1",
                       AUTONOMOUS_HEAVY_STATE=str(state), MAC_HEAVY_HELD="1")
            try:
                child = subprocess.Popen([sys.executable, __file__, "--child", str(rd), *command],
                                         env=env, start_new_session=True, pass_fds=(rd, lock.fileno()))
                os.close(rd)
                record = {"token": token, "owner": os.getpid(), "owner_start": identity(os.getpid()),
                          "child": child.pid, "child_start": identity(child.pid)}
                publish(owner_path, record)
                if interrupted:
                    stop(interrupted, None)
                else:
                    if ready:
                        ready.write_text("ready\n")
                    os.write(wr, b"1")
                    held_from = time.time()
                    sampler = start_load_sampler(child.pid, label, command)
            finally:
                os.close(wr)
            rc = child.wait()
            # A background tool can survive a successful shell. Retain both
            # metadata and kernel ownership until the whole child session ends.
            while session_live(record) or members_live(state, token):
                time.sleep(.25)
            session_done = True
            if held_from is not None:
                stop_load_sampler(sampler, 128 - rc if rc < 0 else rc)
                log_hold(state, held_from, time.time(), command)
            retire_members(state, token)
            owner_path.unlink()
            return 128 + interrupted if interrupted else (128 - rc if rc < 0 else rc)
        finally:
            waiter.unlink(missing_ok=True)
            # Never release while the child session may still run (a failure mid-run). That buys
            # little — this supervisor exits next, and its dead pid makes the lock stale — but an
            # explicit release would hand the Mac over with the work certainly still going.
            if machine == "taken" and (child is None or session_done):
                mac_lock.release()


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--child":
        fd = int(sys.argv[2])
        granted = os.read(fd, 1)
        os.close(fd)
        if granted != b"1":
            return 125
        try:
            os.execvp(sys.argv[3], sys.argv[3:])
        except FileNotFoundError:
            return 127
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", type=Path, default=Path(os.environ.get(
        "AUTONOMOUS_HEAVY_STATE", str(Path(os.environ.get("AUTONOMOUS_STATE",
        str(Path.home() / ".local/state/archive-autonomous"))) / "heavy"))))
    parser.add_argument("--ready", type=Path)
    parser.add_argument("action", choices=("run", "held", "enter", "waiting"))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    state = args.state.resolve()
    if args.action in ("held", "enter"):
        if not held(state):
            return 1
        if args.action == "enter":
            protect(state, os.getppid())
        return 0
    if args.action == "waiting":
        return 0 if waiting(state, int(args.command[0])) else 1
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("run requires a command")
    return run(state, command, args.ready)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print("heavy work refused: " + str(error), file=sys.stderr)
        sys.exit(2)
