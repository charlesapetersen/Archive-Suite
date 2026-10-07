#!/usr/bin/env python3
"""One heavy job at a time on this Mac, across projects (W35.machine-lock).

Archive Suite's side of a lock shared with Vision OCR, whose own copy is
`~/Claude/vision-ocr/ops/autonomous/mac-heavy-lock.sh` (bash; its `mac-heavy-lock` item). Neither
repo depends on the other, so the WIRE PROTOCOL below is the contract: change it in both or neither.

  lock     ~/.local/state/mac-heavy.lock, a DIRECTORY taken with mkdir (atomic).
  owner    <lock>/owner, key=value lines: pid= project= label= start=<epoch> started=<local time>,
           written to a temporary name and renamed into place.
  release  by the holder, on exit. Only the pid in `owner` removes it.
  stale    the owner pid is not running, or started after `start` (a recycled pid), or `owner` is
           missing and the directory is over 60 s old (a taker died between mkdir and write). The
           next taker removes it inside <lock>.reclaim — a mkdir mutex, re-checking staleness inside
           it, so two reclaimers cannot delete each other's fresh lock; a mutex over 60 s old is
           abandoned and broken by rename — and logs that to <dir>/mac-heavy.log.
  wait     a taker waits, polling, logged once; callers must not charge the wait to a time limit.
  nesting  MAC_HEAVY_HELD=1 is exported to the holder's command; a nested take runs straight
           through. This copy also treats a live holder that is its own ancestor as nesting.

A caller that holds another lock must not WAIT here while holding it (hold-and-wait deadlocks
against a holder that needs that lock next): use attempt() and back off, as heavy-run.py does.
Tests point MAC_HEAVY_LOCK at a scratch path; never at the real lock.

DELEGATE (Agent Manager stage 2). Run as a command, this file hands over to the Agent Manager's shared
helper when it is installed: if AGENT_MANAGER_HEAVY_LOCK (default ~/Claude/Agent Manager/bin/heavy-lock)
names an executable file, main() execs it with the same arguments, adding `--project archive-suite`
first so this file's default project survives. That helper takes its own kernel lock AND this mkdir
lock, so every taker here still sees it. Otherwise, or when --lock is given (the manager has no such
option), the command runs exactly as below. Importing this file (heavy-run.py does) never delegates:
the functions here are the old protocol itself. The manager is not required for this project to run.
Tests set AGENT_MANAGER_HEAVY_LOCK to a scratch copy, or to a missing path for the fallback.
"""
import argparse
import contextlib
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

DEFAULT = Path.home() / ".local/state/mac-heavy.lock"
GRACE = 60


def lock_path(path=None):
    return Path(path or os.environ.get("MAC_HEAVY_LOCK") or DEFAULT)


def _log(lock, project, text):
    try:
        with (lock.parent / "mac-heavy.log").open("a", errors="backslashreplace") as f:
            f.write("%s\t%s\t%s\n" % (time.strftime("%F %T"), project, text.replace("\n", " ")))
    except OSError:
        pass


def _age(path):
    try:
        return time.time() - path.stat().st_mtime
    except FileNotFoundError:
        return 0


def read_owner(lock):
    try:
        text = (lock / "owner").read_text(errors="replace")
    except OSError:
        return None
    r = dict(line.split("=", 1) for line in text.splitlines() if "=" in line)
    try:
        r["pid"] = int(r["pid"])
    except (KeyError, ValueError):
        return None
    return r if r["pid"] > 0 else None


def _started(pid):
    """Epoch the process started, None if it is not running (or a zombie), 0 if unreadable."""
    p = subprocess.run(["ps", "-p", str(pid), "-o", "stat=,lstart="], capture_output=True, text=True)
    fields = p.stdout.strip().split(maxsplit=1)
    if p.returncode != 0 or len(fields) != 2 or "Z" in fields[0]:
        return None
    try:
        t = time.strptime(" ".join(fields[1].split()), "%a %b %d %H:%M:%S %Y")
    except ValueError:
        return 0
    # lstart is local time without a zone: in the repeated hour when clocks go back it has two
    # readings. Take the earlier, so a live holder is never judged recycled (more lenient = safe).
    readings = {int(time.mktime(t[:8] + (dst,))) for dst in (-1, 0, 1)}
    return min([e for e in readings if time.localtime(e)[:6] == t[:6]] or readings)


def alive(r):
    """The owner is running and is the process that took the lock (not a recycled pid)."""
    started = _started(r["pid"])
    if started is None:
        return False
    try:
        return not started or started <= int(r.get("start", "")) + 1
    except ValueError:
        return True  # unreadable start: trust the pid rather than break a live lock


def _ancestors(pid):
    p = subprocess.run(["ps", "-ax", "-o", "pid=,ppid="], capture_output=True, text=True)
    parents = dict(tuple(map(int, line.split())) for line in p.stdout.splitlines() if len(line.split()) == 2)
    seen = []
    while pid > 0 and pid not in seen:
        seen.append(pid)
        pid = parents.get(pid, 0)
    return seen


def _stale(lock):
    if not lock.is_dir():
        return None
    r = read_owner(lock)
    if r:
        return None if alive(r) else r
    return {"pid": "?", "project": "?", "label": "no owner file"} if _age(lock) >= GRACE else None


def _reclaim(lock, project):
    """Remove a stale lock under the shared mkdir mutex. True if this call removed one."""
    mutex = Path(str(lock) + ".reclaim")
    try:
        os.mkdir(mutex)
    except FileExistsError:
        if _age(mutex) >= GRACE:
            dead = Path("%s.dead.%d" % (mutex, os.getpid()))
            try:
                os.rename(mutex, dead)
                shutil.rmtree(dead, ignore_errors=True)
                _log(lock, project, "removed an abandoned %s" % mutex)
            except OSError:
                pass
        return False
    try:
        r = _stale(lock)  # asked again INSIDE the mutex
        if not r:
            return False
        shutil.rmtree(lock, ignore_errors=True)
        _log(lock, project, "reclaimed from dead holder '%s' (%s, pid %s)" % (r.get("label"), r.get("project"),
                                                                             r["pid"]))
        return True
    finally:
        with contextlib.suppress(FileNotFoundError):  # an abandoned-mutex breaker may have renamed it
            os.rmdir(mutex)


def attempt(project, label, lock=None, pid=None):
    """One non-blocking try: 'taken' (caller must release), 'nested', or the live owner record."""
    lock, pid = lock_path(lock), pid or os.getpid()
    lock.parent.mkdir(parents=True, exist_ok=True)
    for _ in range(3):
        try:
            os.mkdir(lock)
        except FileExistsError:
            r = read_owner(lock)
            if r and alive(r):
                return "nested" if r["pid"] in _ancestors(pid) else r
            if _stale(lock) and _reclaim(lock, project):
                continue
            return r or {"pid": "?", "project": "?", "label": "being taken"}
        tmp = lock / ("owner.%d" % pid)
        tmp.write_text("pid=%d\nproject=%s\nlabel=%s\nstart=%d\nstarted=%s\n" % (
            pid, project, label.replace("\n", " ")[:200], time.time(), time.strftime("%F %T")),
            errors="backslashreplace")
        os.replace(tmp, lock / "owner")
        return "taken"
    return {"pid": "?", "project": "?", "label": "contended"}


def log_wait(project, label, owner, lock=None):
    note = "'%s' (pid %d) waiting for '%s' (%s, pid %s)" % (label, os.getpid(), owner.get("label"),
                                                           owner.get("project"), owner["pid"])
    _log(lock_path(lock), project, note)
    print("mac-heavy-lock: " + note, file=sys.stderr, flush=True)


def log_got(project, label, lock=None):
    _log(lock_path(lock), project, "'%s' took the lock after waiting" % label)


def take(project, label, lock=None, pid=None, poll=1.0, interrupted=lambda: False):
    """Block until held, holding NO other lock meanwhile. 'taken', 'nested', or None if interrupted."""
    if os.environ.get("MAC_HEAVY_HELD") == "1":
        return "nested"
    logged = False
    while not interrupted():
        got = attempt(project, label, lock, pid)
        if isinstance(got, str):
            if logged:
                log_got(project, label, lock)
            return got
        if not logged:
            logged = True
            log_wait(project, label, got, lock)
        time.sleep(poll)
    return None


def release(lock=None, pid=None):
    lock, pid = lock_path(lock), pid or os.getpid()
    r = read_owner(lock)
    if r and r["pid"] == pid:
        shutil.rmtree(lock, ignore_errors=True)


def manager_helper():
    """The Agent Manager's heavy-lock if it is installed and executable, else None."""
    path = os.environ.get("AGENT_MANAGER_HEAVY_LOCK") or str(Path.home() / "Claude/Agent Manager/bin/heavy-lock")
    path = os.path.expanduser(path)
    return path if os.path.isfile(path) and os.access(path, os.X_OK) else None


def options(argv):
    """The option names given before the action, as argparse below reads them (after it, all is command)."""
    names, i = [], 0
    while i < len(argv) and argv[i].startswith("-") and argv[i] != "--":
        name = argv[i].split("=", 1)[0]
        names.append(name)
        i += 1 if "=" in argv[i] else 2
    return names


def delegate(argv):
    """Exec the manager's helper with these arguments; return only if there is none to exec."""
    helper = manager_helper()
    if helper is None or "--lock" in options(argv):
        return
    try:
        os.execv(helper, [helper, "--project", "archive-suite"] + argv)
    except OSError as e:
        print("mac-heavy-lock: cannot run %s (%s); using this copy" % (helper, e), file=sys.stderr, flush=True)


def main():
    delegate(sys.argv[1:])
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lock", type=Path)
    ap.add_argument("--project", default="archive-suite")
    ap.add_argument("--label", default="")
    ap.add_argument("action", choices=("run", "status"))
    ap.add_argument("command", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    if a.action == "status":
        lock = lock_path(a.lock)
        r = read_owner(lock)
        if not lock.is_dir():
            print("free (%s)" % lock)
        else:
            print("held by pid %s (%s '%s') since %s%s" % (
                r["pid"], r.get("project"), r.get("label"), r.get("started"), "" if alive(r) else " — STALE")
                  if r else "held, no owner file yet%s" % (" — STALE" if _stale(lock) else ""))
        return 0
    cmd = a.command[1:] if a.command[:1] == ["--"] else a.command
    if not cmd:
        ap.error("run requires a command")
    stop = []
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda s, _f: stop.append(s))
    got = take(a.project, a.label or " ".join(cmd)[:80], a.lock, interrupted=lambda: bool(stop))
    if got is None:
        return 128 + stop[0]
    try:
        if stop:  # a signal between the take and here must not be swallowed
            return 128 + stop[0]
        try:
            child = subprocess.Popen(cmd, env=dict(os.environ, MAC_HEAVY_HELD="1"))
        except FileNotFoundError:
            return 127
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, lambda s, _f: child.send_signal(s))
        if stop:
            child.send_signal(stop[0])
        rc = child.wait()
        return 128 - rc if rc < 0 else rc
    finally:
        if got == "taken":
            release(a.lock)


if __name__ == "__main__":
    sys.exit(main())
