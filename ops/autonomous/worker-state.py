#!/usr/bin/env python3
"""W35.claims: serialize reservations and idle upkeep; never signal an owner.

Claims are atomic mkdir entries. A kernel flock serializes selection, metadata,
release and upkeep (and disappears on process death). Dead owners expire after
AUTONOMOUS_STALE, just like engine locks; age alone never evicts a live owner.
Empty unpublished claims expire; corrupt metadata and unknown files are preserved. All paths come from the caller's explicit state/repo arguments.
"""
import argparse
import contextlib
import fcntl
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid


def identity(pid):
    if not isinstance(pid, int) or pid <= 0:
        return ""
    p = subprocess.run(["ps", "-p", str(pid), "-o", "stat=,lstart="],
                       capture_output=True, text=True, check=False)
    if p.stderr.strip():
        raise RuntimeError("cannot inspect process identity: " + p.stderr.strip())
    fields = p.stdout.strip().split(maxsplit=1)
    return fields[1] if p.returncode == 0 and len(fields) == 2 and "Z" not in fields[0] else ""


def live(record):
    return (identity(record.get("pid")) == record.get("pid_start") and bool(record.get("pid_start"))) or session_live(record)


def session_live(record):
    if record.get("uncertain"):
        raise RuntimeError("claim requires inspection: termination victim disappeared before session capture")
    if identity(record.get("child")) == record.get("child_start") and record.get("child_start"):
        return True
    for member in record.get("protected", []):
        if identity(member["pid"]) == member["start"]:
            return True
    sessions = {member["sid"] for member in record.get("protected", []) if member.get("sid")}
    if record.get("sid"):
        sessions.add(record["sid"])
    if not sessions:
        return False
    # A process that exits between the ps snapshot and getsid() has an unknown
    # session: it may have forked a same-session successor the snapshot missed.
    # That successor is visible to a fresh snapshot, so rescan rather than
    # retaining the claim on any machine-wide exit (the cause of most refused
    # releases on a busy Mac, 6-7 Oct 2026). Still unknown after three scans:
    # retain, as before.
    for _ in range(3):
        member, unknown = session_scan(sessions)
        if member:
            return True
        if not unknown:
            return False
    return True


def session_scan(sessions):
    """(a live member was seen, some process vanished before its session was read)."""
    with subprocess.Popen(["ps", "-ax", "-o", "pid=,pgid=,stat="], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True) as probe:
        stdout, stderr = probe.communicate()
        probe_pid = probe.pid
    if probe.returncode != 0 or stderr.strip():
        raise RuntimeError("cannot inspect session process group")
    unknown = False
    # A separate OS session prevents unrelated processes joining the group.
    for line in stdout.splitlines():
        fields = line.split()
        if len(fields) == 3 and "Z" not in fields[2]:
            pid, pgid = int(fields[0]), int(fields[1])
            if pid in (probe_pid, os.getpid()):
                continue  # our owned probe necessarily exits before this scan
            try:
                if os.getsid(pid) in sessions:
                    return True, False
            except ProcessLookupError:
                # A process group never spans sessions: a live group leader
                # still names the vanished process's session.
                if pgid in sessions:
                    return True, False
                try:
                    if pgid <= 0:
                        raise ProcessLookupError(pgid)  # getsid(0) would name OUR session
                    if os.getsid(pgid) in sessions:
                        return True, False
                except OSError:
                    unknown = True
    return False, unknown


@contextlib.contextmanager
def locked(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield f


def write_record(path, value):
    tmp = path.with_name(path.name + ".tmp")
    with tmp.open("w") as f:
        json.dump(value, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def validate_record(record, tag):
    if not isinstance(record, dict) or record.get("tag") != tag:
        raise ValueError("claim tag does not match directory")
    valid(record.get("worker", ""))
    for lane in str(record.get("lane", "")).split(","):
        valid(lane)
    if type(record.get("pid")) is not int or record["pid"] <= 0 or not isinstance(record.get("pid_start"), str) or not record["pid_start"]:
        raise ValueError("missing claim owner identity")
    if not isinstance(record.get("token"), str) or not re.fullmatch(r"[a-f0-9]{32}", record["token"]):
        raise ValueError("invalid claim token")
    if type(record.get("started")) not in (float, int) or not math.isfinite(record["started"]) or record["started"] <= 0:
        raise ValueError("invalid claim start time")
    if "subscription" in record and record["subscription"] not in ("claude", "codex", "unknown"):
        raise ValueError("invalid subscription lane")
    if "child" in record or "child_start" in record:
        if type(record.get("child")) is not int or record["child"] <= 0 or not isinstance(record.get("child_start"), str) or not record["child_start"]:
            raise ValueError("missing CLI identity")
    if "sid" in record and (type(record["sid"]) is not int or record["sid"] != record.get("child")):
        raise ValueError("invalid session identity")
    if "protected" in record:
        if not isinstance(record["protected"], list):
            raise ValueError("invalid protected descendants")
        for member in record["protected"]:
            if not isinstance(member, dict) or type(member.get("pid")) is not int or member["pid"] <= 0 or not isinstance(member.get("start"), str) or not member["start"]:
                raise ValueError("invalid protected descendant identity")
            if "sid" in member and (type(member["sid"]) is not int or member["sid"] <= 0):
                raise ValueError("invalid protected descendant session")
    if "uncertain" in record and type(record["uncertain"]) is not bool:
        raise ValueError("invalid descendant uncertainty")
    if "release_refused" in record and (type(record["release_refused"]) not in (float, int)
                                        or not math.isfinite(record["release_refused"]) or record["release_refused"] <= 0):
        raise ValueError("invalid release refusal time")


# A claim kept after a refused release (its CLI and supervisor are gone, but something in its session
# lives on) expires this long after the first refusal, like a stale one. An hour outlasts the longest
# heavy job a finished session can leave behind (a Notes VM UI run, ~21 min); before this bound the
# claim was held for as long as any straggler lived, and under the old "suite" default that idled
# every other worker (W35.vm-mem x3, W9.e2 x2 on 7 Oct 2026).
PRESERVED_TTL = int(os.environ.get("AUTONOMOUS_PRESERVED_CLAIM_TTL", "3600"))


def preserved_expired(record):
    refused = record.get("release_refused")
    if not refused or record.get("uncertain") or time.time() - refused < PRESERVED_TTL:
        return False
    for key in ("pid", "child"):
        if record.get(key) and record.get(key + "_start") and identity(record[key]) == record[key + "_start"]:
            return False  # the supervisor or the CLI itself is still running: never expire
    return True


def heavy_work_in_session(state, record):
    """A process in the claim's session is queued for, or holds, the heavy lock.

    The hour bound is sized to the longest heavy JOB, not to the time a straggler spends queued for the lock:
    with three workers and a 20-minute gate a left-behind Notes VM run waited over 40 minutes before its
    21-minute run (7 Oct 2026). heavy-run.py's waiter records and its owner record are in that process's own
    session (the held job itself runs in a new one, under the owner), so either names work still in progress."""
    sessions = {member["sid"] for member in record.get("protected", []) if member.get("sid")}
    if record.get("sid"):
        sessions.add(record["sid"])
    if not sessions:
        return False
    heavy = Path(os.environ.get("AUTONOMOUS_HEAVY_STATE") or state / "heavy")
    found = []
    try:
        owner = json.loads((heavy / "owner.json").read_text())
        found.append((owner.get("owner"), owner.get("owner_start")))
    except (OSError, ValueError, AttributeError):
        pass
    for path in sorted((heavy / "waiters").glob("*.json")):
        try:
            waiter = json.loads(path.read_text())
            if time.time() - float(waiter["heartbeat"]) < 10:  # heavy-run.py refreshes it every 0.25-1 s
                found.append((waiter.get("pid"), waiter.get("start")))
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            continue
    for pid, start in found:
        try:
            if isinstance(pid, int) and pid > 0 and start and identity(pid) == start and os.getsid(pid) in sessions:
                return True
        except (RuntimeError, ProcessLookupError):
            continue  # an uninspectable heavy record names no work; the claim's own checks still apply
    return False


def claims(state, stale):
    """Only retire a known dead, expired claim, under coordination.lock."""
    directory = state / "claims"
    if not directory.exists():
        return []
    result = []
    for entry in sorted(directory.iterdir()):
        if not entry.is_dir() or entry.is_symlink():
            raise RuntimeError("unexpected claim entry: " + str(entry))
        names = {p.name for p in entry.iterdir()}
        if not names:
            # An interrupted mkdir cannot have launched a CLI: reserve returns only
            # after durable metadata. Protect it for STALE, then remove only empty.
            if time.time() - entry.stat().st_mtime >= stale:
                entry.rmdir()
                continue
            result.append((entry, {"tag": entry.name, "lane": "suite", "unknown": True}))
            continue
        if names - {"owner.json", "owner.json.tmp"}:
            raise RuntimeError("unexpected files in claim: " + str(entry))
        if "owner.json" not in names and "owner.json.tmp" in names:
            # A complete temp record is the interrupted atomic publish, under our
            # shared lock. Validate it before finishing that same publish.
            pending = json.loads((entry / "owner.json.tmp").read_text())
            validate_record(pending, entry.name)
            os.replace(entry / "owner.json.tmp", entry / "owner.json")
        elif "owner.json.tmp" in names:
            # The previous record remains authoritative after interrupted update.
            (entry / "owner.json.tmp").unlink()
        try:
            record = json.loads((entry / "owner.json").read_text())
            validate_record(record, entry.name)
        except (OSError, ValueError) as exc:
            raise RuntimeError("invalid claim (preserved): " + str(entry)) from exc
        expired = not record.get("unknown") and preserved_expired(record)
        if expired and heavy_work_in_session(state, record):
            # Still queued for or holding the heavy lock: the bound restarts from now, so it measures the time
            # since the straggler was last seen waiting or working, never the time it spent in the queue.
            record["release_refused"] = time.time()
            write_record(entry / "owner.json", record)
            expired = False
        if not record.get("unknown") and (expired or
                                          not live(record) and time.time() - entry.stat().st_mtime >= stale):
            # No recursive removal: unexpected files preserve the claim and stop dispatch.
            if {p.name for p in entry.iterdir()} != {"owner.json"}:
                raise RuntimeError("unexpected files in expired claim: " + str(entry))
            (entry / "owner.json").unlink()
            entry.rmdir()
            continue
        result.append((entry, record))
    return result


LANE_RE = re.compile(r"\(lane:\s*([A-Za-z0-9._-]+(?:\s*,\s*[A-Za-z0-9._-]+)*)\s*\)")


def lanes(text):
    """An item's conflict territory: `(lane: a,b)` is a set; no tag means `suite`."""
    m = LANE_RE.search(text)
    return frozenset(x.strip() for x in m[1].split(",")) if m else frozenset(["suite"])


def conflicts(mine, record):
    """`suite` conflicts with every lane; other lane sets conflict when they intersect."""
    theirs = frozenset(str(record.get("lane", "suite")).split(","))
    return "suite" in mine or "suite" in theirs or bool(mine & theirs)


def valid(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value):
        raise ValueError("invalid tag/worker: " + repr(value))
    return value


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--state", required=True, type=Path)
    p.add_argument("--repo", required=True, type=Path)
    p.add_argument("--plan", type=Path)
    p.add_argument("--stale", type=int, default=int(os.environ.get("AUTONOMOUS_STALE", "1500")))
    sub = p.add_subparsers(dest="action", required=True)
    reserve = sub.add_parser("reserve")
    reserve.add_argument("worker", type=valid)
    reserve.add_argument("pid", type=int)
    reserve.add_argument("--special", choices=["doc-budget-fix", "gate-fix", "review"])
    for name in ("release", "heartbeat", "child", "worktree"):
        cmd = sub.add_parser(name)
        cmd.add_argument("tag", type=valid)
        cmd.add_argument("token")
        if name in ("child", "worktree"):
            cmd.add_argument("value")
    sub.add_parser("filter")
    sub.add_parser("stopped")
    sub.add_parser("restart")
    upkeep = sub.add_parser("idle")
    upkeep.add_argument("command", nargs=argparse.REMAINDER)
    session = sub.add_parser("session")
    session.add_argument("tag", type=valid)
    session.add_argument("token")
    session.add_argument("command", nargs=argparse.REMAINDER)
    protect = sub.add_parser("protect")
    protect.add_argument("tag", type=valid)
    protect.add_argument("token")
    protect.add_argument("pids", type=int, nargs="+")
    args = p.parse_args()
    state = args.state.resolve()
    env = os.environ.copy()
    plan = args.plan or Path(env.get("AUTONOMOUS_PLAN", str(args.repo / ".maintenance/AUTONOMOUS_PLAN.md")))
    session_command = None
    plan = plan.resolve()
    env["AUTONOMOUS_PLAN"] = str(plan)
    dispatch_guard = None
    if args.action == "session" and env.pop("AUTONOMOUS_START_STAGGER", "") == "1":
        # Serialize actual CLI starts, including a shell delayed before session().
        # Do not hold coordination.lock while waiting: releases remain responsive.
        dispatch_guard = (state / "dispatch.lock").open("a+")
        fcntl.flock(dispatch_guard, fcntl.LOCK_EX)
        try:
            last = float((state / "dispatch.last").read_text())
        except FileNotFoundError:
            last = 0
        if not math.isfinite(last) or last < 0:
            raise ValueError("invalid dispatch start stamp (preserved)")
        remaining = max(0, min(60, last + 60 - time.time()))
        deadline = time.monotonic() + remaining
        while time.monotonic() < deadline:
            time.sleep(min(1, deadline - time.monotonic()))
    if args.action == "filter" and not (state / "claims").exists():
        # Advisory resolver reads must not initialize the installed runtime of a
        # still-running serial daemon. Actual reservations always lock below.
        for row in sys.stdin.read().splitlines():
            if len(row.split("\t", 2)) != 3:
                raise ValueError("malformed resolver row")
            print(row)
        return 0
    with locked(state / "coordination.lock") as coordination:
        stopped = state / "owner-stopped"
        if args.action == "stopped":
            stopped.touch()
        if args.action in ("stopped", "restart"):
            if not stopped.exists():
                return 0
            active = claims(state, 0)  # explicit owner stop, never a normal crash
            for lock in state.glob("worker-*/engine.lock"):
                if not any(r.get("worker") == lock.parent.name or r.get("unknown") for _, r in active):
                    lock.unlink()
            if active:
                return 4
            stopped.unlink()
            return 0
        active = claims(state, args.stale)
        if args.action == "filter":
            rows = sys.stdin.read().splitlines()
            for row in rows:
                fields = row.split("\t", 2)
                if len(fields) != 3:
                    raise ValueError("malformed resolver row")
                status, tag, text = fields
                lane = lanes(text)
                if any(r.get("tag") == tag or conflicts(lane, r) for _, r in active):
                    continue
                print(row)
            return 0
        if args.action == "reserve":
            start = identity(args.pid)
            if not start:
                raise ValueError("claim owner is not alive")
            if any(r.get("worker") == args.worker for _, r in active):
                return 4
            # Repairs serialize the whole suite. A pending request wins even if
            # it appeared after the worker's pre-reservation snapshot.
            pending = next((name for name in ("doc-budget-fix", "gate-fix") if (state / name).exists()), None)
            if pending and env.get("AUTONOMOUS_WORKER_RESERVATION_V2") == "1":
                args.special = pending
            if args.special:
                rows = ["ok\t" + args.special + "\tspecial repair/review"]
            else:
                env["AUTONOMOUS_IGNORE_CLAIMS"] = "1"
                env["AUTONOMOUS_PLAN"] = str(plan)
                proc = subprocess.run(["bash", str(args.repo / "ops/autonomous/next-queue-item.sh"), str(args.repo)],
                                      env=env, capture_output=True, text=True)
                if proc.returncode not in (0, 3, 4):
                    raise RuntimeError(proc.stderr or proc.stdout)
                rows = proc.stdout.splitlines() if proc.returncode in (0, 4) else []
            for row in rows:
                fields = row.split("\t", 2)
                if len(fields) != 3 or fields[0] != "ok":
                    continue
                _, tag, text = fields
                valid(tag)
                if re.search(r"\[hold\]|needs:\s*owner", text, re.I):
                    continue
                lane = lanes(text)
                if any(r.get("tag") == tag or conflicts(lane, r) for _, r in active):
                    continue
                directory = state / "claims" / tag
                directory.parent.mkdir(parents=True, exist_ok=True)
                directory.mkdir()  # atomic claim; a pre-existing entry is never overwritten
                token = uuid.uuid4().hex
                record = dict(tag=tag, worker=args.worker, pid=args.pid, pid_start=start,
                              lane=",".join(sorted(lane)), subscription=env.get("AUTONOMOUS_SUBSCRIPTION", "unknown"), token=token, started=time.time(), text=text)
                write_record(directory / "owner.json", record)
                print(tag + "\t" + token + "\t" + text)
                return 0
            return 4
        if args.action == "idle":
            if active:
                return 4
            # Compatibility: an old serial daemon has no claim. Keep its fresh lock protected.
            locks = [state / "engine.lock"] + list(state.glob("worker-*/engine.lock"))
            if any(f.exists() and time.time() - f.stat().st_mtime < args.stale for f in locks):
                return 4
            command = args.command
            if command[:1] == ["--"]:
                command = command[1:]
            if not command:
                return 0
            env["AUTONOMOUS_COORDINATED_UPKEEP"] = "1"
            # Idle holds coordination.lock and proves there are no claims. Queue
            # reads in check-handoff/health-gate must not reacquire that same lock.
            # This flag reaches only this upkeep child, never dispatched sessions.
            env["AUTONOMOUS_IGNORE_CLAIMS"] = "1"
            # Same lock as plan-edit: compaction and tick/report edits cannot overlap.
            with locked(plan.with_name(plan.name + ".lock")) as plan_lock:
                # Keep both flocks in the mutating child if its coordinator dies.
                return subprocess.run(command, env=env, check=False,
                                      pass_fds=(coordination.fileno(), plan_lock.fileno())).returncode
        matches = [(d, r) for d, r in active if d.name == args.tag and r.get("token") == args.token]
        if len(matches) != 1:
            return 4
        directory, record = matches[0]
        if args.action == "session":
            session_command = args.command
            if session_command[:1] == ["--"]:
                session_command = session_command[1:]
            if not session_command:
                raise ValueError("missing session command")
            # Publish ownership BEFORE exec. If the supervisor died and a new claim
            # won, the token check above refuses to launch the old CLI at all.
            os.setsid()
            record["child"] = os.getpid()
            record["child_start"] = identity(os.getpid())
            record["sid"] = os.getsid(0)
            if not record["child_start"]:
                raise RuntimeError("cannot identify session process")
            write_record(directory / "owner.json", record)
            os.utime(directory, None)
        elif args.action == "release":
            # A supervisor may exit while its CLI survives. Keep that CLI's work claimed.
            if session_live(record):
                if not record.get("release_refused"):
                    record["release_refused"] = time.time()  # starts the preserved-claim bound
                    write_record(directory / "owner.json", record)
                return 4
            if {p.name for p in directory.iterdir()} != {"owner.json"}:
                raise RuntimeError("unexpected files in claim: " + str(directory))
            (directory / "owner.json").unlink()
            directory.rmdir()
        elif args.action == "heartbeat":
            os.utime(directory, None)
        elif args.action == "protect":
            members = record.setdefault("protected", [])
            for pid in args.pids:
                try:
                    sid = os.getsid(pid)
                except ProcessLookupError:
                    # No safe way to reconstruct an escaped SID after its root
                    # disappeared. Preserve the claim rather than clear blindly.
                    record["uncertain"] = True
                    continue
                start = identity(pid)
                member = {"pid": pid, "start": start or "exited-after-session-snapshot", "sid": sid}
                if start and member not in members:
                    members.append(member)
                elif not start:
                    members.append(member)  # SID remains the successor protection
            write_record(directory / "owner.json", record)
            os.utime(directory, None)
            if record.get("uncertain"):
                raise RuntimeError("termination victim disappeared before session capture; claim preserved")
        else:
            if args.action == "child":
                record["child"] = int(args.value)
                record["child_start"] = identity(record["child"])
                if not record["child_start"]:
                    raise ValueError("child is not alive")
            else:
                path = Path(args.value).resolve()
                common = subprocess.check_output(["git", "-C", str(path), "rev-parse", "--path-format=absolute",
                                                  "--git-common-dir"], text=True).strip()
                expected = subprocess.check_output(["git", "-C", str(args.repo), "rev-parse", "--path-format=absolute",
                                                    "--git-common-dir"], text=True).strip()
                if common != expected or path == args.repo.resolve():
                    raise ValueError("worktree must be isolated in this repository")
                record["worktree"] = str(path)
            write_record(directory / "owner.json", record)
            os.utime(directory, None)
        if session_command is None:
            return 0
    # exec preserves PID + birth identity; flock is closed before a long session.
    if dispatch_guard is not None:
        stamp = state / "dispatch.last.tmp"
        stamp.write_text(str(time.time()))
        stamp.replace(state / "dispatch.last")
        # CLOEXEC releases this lock at exec, after the start stamp is published.
    env.pop("AUTONOMOUS_WORKER_RESERVATION_V2", None)
    env.pop("AUTONOMOUS_SUBSCRIPTION", None)
    os.execvpe(session_command[0], session_command, env)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print("worker-state: " + str(exc), file=sys.stderr)
        sys.exit(2)
