#!/usr/bin/env python3
"""W35.workers: bounded subscription lanes; only explicit parallel mode uses this.

One-cycle shell workers retain the established watchdog, claims and verification
flow. Global maintenance is admitted only under the claims coordinator's idle
lock. Exiting never signals a CLI: surviving sessions keep their protected claim.
"""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("worker_state", HERE / "worker-state.py")
coord = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coord)
spec = importlib.util.spec_from_file_location("usage_pace", HERE / "usage-pace.py")
pace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pace)


def number(env, name, default, minimum=0):
    value = float(env.get(name, default))
    if not minimum <= value < float("inf"):
        raise ValueError(name + " is invalid")
    return value


def paused(readings, now, threshold, slack):
    """Never let an older sibling reading cancel a current exhausted window."""
    until = 0
    for row in readings:
        fields = row.split()
        if len(fields) < 2:
            continue
        try:
            pct, reset = float(fields[0]), int(fields[1])
        except ValueError:
            continue
        if reset + slack > now and (pct >= threshold or "cut" in fields[2:]):
            until = max(until, reset + slack)
    return until


# W35.three-workers: a third session in one lane also needs the Mac, which is the limit on more workers (owner,
# 2026-10-06: at 8 GB the GUI VM used all 18 GB while swap reached 10.7 of 11.2 GB). Read the way run-guarded.sh
# reads it: `kern.memorystatus_vm_pressure_level` (1 normal, 2 warn, 4 critical) and the `used` of vm.swapusage.
# Swap is measured against physical memory, not against vm.swapusage's total, which macOS grows on demand.
THIRD_SWAP_SHARE = 0.25     # no third session while swap in use exceeds this share of RAM (4.5 GB of 18)
HEAVY_RECENT = 30 * 60      # ... nor within this long of a heavy job that pushed pressure above normal


def machine_reading():
    """(pressure level, swap used MB, RAM MB) from sysctl; raises when any is unreadable."""
    out = subprocess.run(["/usr/sbin/sysctl", "-n", "kern.memorystatus_vm_pressure_level", "vm.swapusage", "hw.memsize"],
                         capture_output=True, text=True, check=True, timeout=10).stdout.splitlines()
    swap = out[1].split("used = ")[1].split()[0]
    scale = {"K": 1 / 1024, "M": 1, "G": 1024}[swap[-1]]
    return int(out[0]), float(swap[:-1]) * scale, int(out[2]) / 1048576


def heavy_pressure(path, now, recent=HEAVY_RECENT):
    """The label of a heavy job ending within `recent` seconds whose pressure went above normal, or None.

    The Agent Manager logs every heavy job's load (heavy-jobs.log, one JSON object a line): a build, a test run or
    a Vision OCR model run that has just pushed the Mac into pressure says the next one will too, even if the
    instantaneous reading has already fallen back to normal."""
    for line in pace.tail_lines(path, 1 << 18):
        try:
            job = json.loads(line)
            if job.get("pressure_peak", 1) > 1 and job["start"] + job.get("duration", 0) >= now - recent:
                return str(job.get("label") or job.get("command") or "a heavy job")
        except (ValueError, KeyError, TypeError, AttributeError):
            continue
    return None


def snapshot_status(state):
    try:
        snapshot = json.loads((state / "supervisor.json").read_text())
    except (OSError, ValueError):
        return
    alive = coord.identity(snapshot.get("pid")) == snapshot.get("pid_start") and bool(snapshot.get("pid_start"))
    print("     Workers (supervisor " + ("running" if alive else "stopped; last snapshot") + "):")
    for row in snapshot.get("workers", []):
        print("       {id}  {lane}  {status}".format(**row))
    for lane, note in sorted((snapshot.get("pace") or {}).items()):
        print("       pace " + lane + ": " + note)


class Supervisor:
    def __init__(self, args, env=None):
        self.args = args
        self.env = dict(os.environ if env is None else env)
        self.state, self.repo, self.plan = args.state, args.repo, args.plan
        loaded = subprocess.run(["git", "-C", str(self.repo), "rev-parse", "HEAD"],
                                capture_output=True, text=True, check=False)
        self.source_sha = loaded.stdout.strip() if loaded.returncode == 0 else ""
        self.stale = number(self.env, "AUTONOMOUS_STALE", 1500)
        self.interval = number(self.env, "AUTONOMOUS_INTERVAL", 90, 1)
        self.poll = min(30, number(self.env, "AUTONOMOUS_WINDOW_POLL", 30, 1))
        self.threshold = number(self.env, "AUTONOMOUS_WINDOW_WAIT_AT", 95)
        self.slack = number(self.env, "AUTONOMOUS_WINDOW_SLACK", 120)
        self.stop = False
        self.last_launch = 0
        self.next_upkeep = 0
        self.children = {}
        self.ready = {}
        lanes = ("claude", "codex") if args.agent == "both" else (args.agent,)
        self.workers = [("worker-" + str(i + 1), lane)
                        for i, lane in enumerate(lane for lane in lanes for _ in range(args.workers))]
        self.terminal = ""
        self.global_stopped = False
        self.cursor = 0
        self.last_active = []
        # W35.pace: per-lane slot count, sized from the usage readings (usage-pace.py).
        self.pacing = self.args.workers > 1 and self.env.get("AUTONOMOUS_PACE", "1") != "0"
        self.caps = {}
        self.pace_notes = {}
        self.lane_reasons = {}  # the last hold logged per lane, so a wait is logged once per change, not per cycle
        self.machine_note = None  # the last third-session hold logged, for the same reason

    def child_env(self, worker, lane, upkeep=False):
        env = self.env.copy()
        env.update(AUTONOMOUS_REPO=str(self.repo), AUTONOMOUS_STATE=str(self.state),
                   AUTONOMOUS_PLAN=str(self.plan), AUTONOMOUS_AGENT=lane,
                   AUTONOMOUS_WORKER_ID=worker, AUTONOMOUS_MAX_WORKERS="1",
                   AUTONOMOUS_WORKER_CHILD="0" if upkeep else "1",
                   AUTONOMOUS_UPKEEP_ONLY="1" if upkeep else "0")
        env.pop("AUTONOMOUS_SUPERVISOR_SOURCE_SHA", None)
        if upkeep:
            env["AUTONOMOUS_SUPERVISOR_SOURCE_SHA"] = self.source_sha
        else:
            env["AUTONOMOUS_START_STAGGER"] = "1"
        # Runtime control belongs to the parent, never to a gate/test subprocess.
        env.pop("AUTONOMOUS_SUPERVISOR_PARK", None)
        return env

    def active(self):
        with coord.locked(self.state / "coordination.lock"):
            stale = 0 if (self.state / "owner-stopped").exists() else self.stale
            return [record for _, record in coord.claims(self.state, stale)]

    def lane_pause(self, lane, now):
        readings = []
        for worker, worker_lane in self.workers:
            if worker_lane == lane:
                try:
                    readings.append((self.state / worker / "usage-window.last").read_text())
                except FileNotFoundError:
                    pass
        # Codex exposes the account-wide latest reading; Claude sibling logs are
        # the available CLI events. Slot sizing below the pause is lane_cap's.
        if lane == "codex":
            command = self.env.get("AUTONOMOUS_USAGE_CMD", str(self.repo / "ops/autonomous/usage-window.sh"))
            p = subprocess.run([command, "--raw", "--codex-latest"], env=self.env,
                               capture_output=True, text=True, check=False)
            if p.returncode == 0:
                readings.append(p.stdout)
        return paused(readings, now, self.threshold, self.slack)

    def pace_sources(self, lane, now):
        if lane == "codex":
            return pace.codex_sources(self.env.get("CODEX_HOME", str(Path.home() / ".codex")), now)
        # Live and finished Claude worker logs, plus Vision OCR's: one account, one window.
        shared = self.env.get("AUTONOMOUS_SHARED_USAGE_LOGS",
                              str(Path.home() / ".local/state/visionocr-autonomous/last-session.log"))
        return ([self.state / worker / "last-session.log" for worker, l in self.workers if l == lane]
                + [Path(p) for p in shared.split(os.pathsep) if p])

    def lane_cap(self, lane, now):
        """How many sessions this lane may hold now; the fixed limit when pacing is off."""
        if not self.pacing:
            return min(self.args.workers, 2)  # a third slot always needs the "wide" band (W35.three-workers)
        try:
            parse = pace.codex_windows if lane == "codex" else pace.claude_windows
            name, note = pace.assess(pace.current_reading(self.pace_sources(lane, now), parse, now), now)
        except Exception as exc:  # any bad source is an unknown reading: cycle() must never die here
            name, note = "unknown", "reading failed: " + repr(exc)
        previous = self.caps.get(lane, 1)
        cap = pace.next_cap(previous, name, self.args.workers)
        if cap != previous or lane not in self.caps:
            try:
                with (self.state / "pace.log").open("a") as log:
                    log.write("%s\t%s\t%s\t%d\t%s\n" % (time.strftime("%F %T", time.localtime(now)),
                                                         lane, name, cap, note))
            except OSError:
                pass  # the log is for W35.live's measurements, never a reason to stop dispatch
        self.caps[lane] = cap
        self.pace_notes[lane] = "%s, %d of %d slots (%s)" % (name, cap, self.args.workers, note)
        return cap

    def publish(self, active, pauses):
        rows = []
        for worker, lane in self.workers:
            own = [r for r in active if r.get("worker") == worker]
            status = "idle"
            if own:
                status = "claimed " + ", ".join(r["tag"] for r in own)
            elif worker in self.children:
                status = "starting / finishing session"
            elif pauses.get(lane):
                status = "usage pause until " + time.strftime("%H:%M", time.localtime(pauses[lane]))
            elif self.terminal:
                status = "dispatch stopped: " + self.terminal
            rows.append(dict(id=worker, lane=lane, status=status))
        coord.write_record(self.state / "supervisor.json", dict(pid=os.getpid(), pid_start=coord.identity(os.getpid()),
                           updated=time.time(), workers=rows, terminal=self.terminal, pace=self.pace_notes))
        command = self.env.get("AUTONOMOUS_STATUS_CMD", str(self.repo / "ops/autonomous/status-digest.sh"))
        if Path(command).is_file():
            env = self.env.copy()
            env.update(AUTONOMOUS_REPO=str(self.repo), AUTONOMOUS_STATE=str(self.state), AUTONOMOUS_PLAN=str(self.plan))
            if self.terminal:
                env["STATUS_PARKED"] = self.terminal
            output = subprocess.run([command], env=env, capture_output=True, check=False)
            if output.returncode == 0:
                tmp = self.state / "STATUS.md.tmp"
                tmp.write_bytes(output.stdout)
                tmp.replace(self.state / "STATUS.md")

    def reap(self, now):
        for worker, child in list(self.children.items()):
            if child.poll() is None:
                continue
            del self.children[worker]
            directory = self.state / worker
            try:
                delay = max(self.interval, float((directory / "next-delay").read_text()))
            except (OSError, ValueError):
                delay = self.interval
            self.ready[worker] = now + delay
            if (directory / "park.reason").exists():
                self.terminal = (directory / "park.reason").read_text().strip()
            elif child.returncode not in (0, 9):
                self.terminal = worker + " exited unexpectedly (" + str(child.returncode) + ")"

    def repair_pending(self):
        return any((self.state / name).exists() for name in ("doc-budget-fix", "gate-fix"))

    def upkeep(self):
        # Reconcile intentional stops BEFORE taking idle's coordination lock.
        # Nested restart under that lock would deadlock on its separately opened fd.
        if (self.state / "owner-stopped").exists():
            restart = subprocess.run([sys.executable, str(HERE / "worker-state.py"), "--state", str(self.state),
                                     "--repo", str(self.repo), "--plan", str(self.plan), "restart"],
                                    env=self.env, capture_output=True, check=False)
            if restart.returncode:
                return restart.returncode
        # The idle helper inherits locks into the shell. It holds plan.lock too;
        # coordinated compactor and housekeeping don't re-acquire that lock.
        lane = self.workers[0][1]
        env = self.child_env("worker-1", lane, upkeep=True)
        with (self.state / "supervisor-upkeep.log").open("a") as output:
            return subprocess.run([sys.executable, str(HERE / "worker-state.py"), "--state", str(self.state),
                                   "--repo", str(self.repo), "--plan", str(self.plan), "idle", "--",
                                   "bash", str(self.args.script)], env=env, stdout=output, stderr=output,
                                  check=False).returncode

    def cycle(self, now):
        self.reap(now)
        scan_failed = False
        try:
            active = self.active()  # survived CLI/descendants count even after shell death
            self.last_active = active
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
            scan_failed = True
            self.terminal = "worker state inspection required: " + str(exc)
            active = self.last_active  # preserve state, drain known children, then park
        pauses = {lane: self.lane_pause(lane, now) for _, lane in self.workers}
        caps = {lane: self.lane_cap(lane, now) for lane in dict.fromkeys(l for _, l in self.workers)}
        self.publish(active, pauses)
        if self.terminal:
            (self.state / "supervisor-park.reason").write_text(self.terminal)
        if self.terminal or self.stop:
            return bool(self.children or (active and not scan_failed))  # preserve unknown files; drain owned children
        if self.plan.exists() and any(line.startswith("RUN STATUS: COMPLETE") for line in self.plan.read_text().splitlines()):
            if self.children or active:
                return True
            self.upkeep()  # established COMPLETE teardown, no session launch
            return False
        repair = self.repair_pending()
        if (repair or (self.state / "owner-stopped").exists()) and (active or self.children):
            return True  # drain; no ordinary refill that could starve the repair
        if not active and not self.children and (repair or now >= self.next_upkeep):
            rc = self.upkeep()
            self.next_upkeep = time.time() + max(self.interval, 60 * len(self.workers))
            if rc == 12:
                return False  # drained source refresh; KeepAlive relaunches, never park
            if rc == 9:
                self.global_stopped = True
                self.terminal = ((self.state / "supervisor-park.reason").read_text().strip()
                                 if (self.state / "supervisor-park.reason").exists() else "global preflight stopped the run")
                return False
            if rc not in (0, 4, 10):
                self.terminal = "global preflight failed (" + str(rc) + ")"
                return False
            if rc in (4, 10):
                return True
            repair = self.repair_pending()
        # Once an idle gate becomes due, prevent a permanent refill stream from
        # starving it: drain at the next global preflight interval.
        if (active or self.children) and now >= self.next_upkeep:
            return True
        if self.last_launch and now - self.last_launch < 60:
            return True
        asked, held, machine = {}, None, {}
        for offset in range(len(self.workers)):
            index = (self.cursor + offset) % len(self.workers)
            worker, lane = self.workers[index]
            if worker in self.children or any(r.get("worker") == worker for r in active):
                continue
            if pauses[lane] or now < self.ready.get(worker, 0):
                continue
            # Any live claim from an earlier supervisor occupies its lane's slot.
            # Worker IDs must keep the same lane after restart; metadata records it.
            claimed_workers = {r.get("worker") for r in active}
            pending_children = sum(w in self.children and w not in claimed_workers and l == lane
                                   for w, l in self.workers)
            other_lane_active = pending_children + sum(r.get("subscription", "unknown") in (lane, "unknown") for r in active)
            if other_lane_active >= caps[lane]:
                continue
            if other_lane_active >= 2 and self.machine_hold(now, machine) is not None:
                continue  # a third session waits for the Mac; the first two never do
            if repair and (active or self.children):
                break
            reason = self.held(worker, lane, asked)
            if reason is not None:
                held = reason
                continue
            directory = self.state / worker
            directory.mkdir(exist_ok=True)
            (directory / "agent").write_text(lane)
            with (directory / "worker.log").open("a") as output:
                child = subprocess.Popen(["bash", str(self.args.script)], env=self.child_env(worker, lane),
                                         stdout=output, stderr=output, close_fds=True)
            self.children[worker] = child
            self.last_launch = now
            self.cursor = (index + 1) % len(self.workers)
            break
        # yield.reason says the run as a whole is waiting (status-digest shows "Waiting"): only when no lane was
        # granted and nothing is running. A lane held while another works is still a working run.
        if held is not None and not any(r is None for r in asked.values()) and not (self.children or active):
            (self.state / "yield.reason").write_text(held + "\n")
        elif asked:
            (self.state / "yield.reason").unlink(missing_ok=True)
        return True

    def machine_hold(self, now, cache):
        """Why the Mac cannot take a third session now, or None; read once per cycle (`cache` is per cycle)."""
        if "reason" in cache:
            return cache["reason"]
        try:
            level, swap_mb, ram_mb = machine_reading()
            share = number(self.env, "AUTONOMOUS_THIRD_SWAP_SHARE", THIRD_SWAP_SHARE)
            if level > 1:
                reason = "memory pressure above normal (level %d)" % level
            elif swap_mb > share * ram_mb:
                reason = "swap over %d%% of RAM (%.1f of %.0f GB)" % (round(share * 100), swap_mb / 1024, ram_mb / 1024)
            else:
                log = self.env.get("AUTONOMOUS_HEAVY_JOBS_LOG",
                                   str(Path.home() / ".local/state/agent-manager/heavy-jobs.log"))
                job = heavy_pressure(log, now)
                reason = None if job is None else "a recent heavy job raised memory pressure (%s)" % job
        except (OSError, ValueError, IndexError, KeyError, subprocess.SubprocessError) as exc:
            reason = "no machine reading (%s)" % exc  # unknown is not calm: hold the third slot only
        cache["reason"] = reason
        head = lambda text: text and text.split(" (")[0]  # the "(…)" detail changes every cycle
        if head(reason) != head(self.machine_note):
            self.log("third session %s." % ("held — " + reason if reason else "allowed again: the Mac is calm"))
        self.machine_note = reason
        return reason

    def held(self, worker, lane, asked):
        """Why this lane must not start a session now, or None; asked once per lane per cycle.

        The Agent Manager's grant helper is asked first (stage 4, 2026-10-07): it owns the cross-project rules,
        such as another project's exclusive job (Vision OCR's bake-off), a subscription at its stop threshold, and
        priority while a window is tight. Exit 0 is granted and 75 is wait. When the helper is absent, or answers
        anything else, yield-check.sh decides as before (exit 0 = hold off), so a manager fault cannot stop work."""
        if lane in asked:
            return asked[lane]
        reason, decided = None, False
        grant = self.env.get("AUTONOMOUS_GRANT_CMD",
                             os.path.join(self.env.get("HOME", str(Path.home())), "Claude/Agent Manager/bin/grant"))
        if Path(grant).is_file() and os.access(grant, os.X_OK):
            try:
                answer = subprocess.run([grant, "--project", self.env.get("AUTONOMOUS_GRANT_PROJECT", "Archive Suite"),
                                         "--agent", lane, "--worker", worker], env=self.env, capture_output=True,
                                        text=True, check=False,
                                        timeout=float(self.env.get("AUTONOMOUS_GRANT_TIMEOUT", 30)))
                if answer.returncode == 0:
                    decided = True
                elif answer.returncode == 75:
                    line = (answer.stdout.strip().splitlines() or [""])[0]
                    reason = (line[len("wait: "):] if line.startswith("wait: ") else line) or "the Agent Manager says wait"
                    decided = True
            except (OSError, subprocess.SubprocessError, ValueError):
                pass  # a timeout, a bad AUTONOMOUS_GRANT_TIMEOUT or an unrunnable helper: yield-check.sh decides
        if not decided:
            yield_cmd = self.env.get("AUTONOMOUS_YIELD_CMD", str(self.repo / "ops/autonomous/yield-check.sh"))
            if Path(yield_cmd).is_file():
                yielded = subprocess.run([yield_cmd], env=self.env, capture_output=True, text=True, check=False)
                if yielded.returncode == 0:
                    reason = yielded.stdout.strip() or "the priority project is busy"
        asked[lane] = reason
        # Logged once per change of reason, compared without the "(…)" detail as the shell does (it names the page
        # being read and changes every cycle). A hold is not idleness: the lane's idle stopwatches are cleared, or
        # hours of waiting would park the run on its first unproductive session after the hold ends.
        previous = self.lane_reasons.get(lane)
        if reason is not None:
            if previous is None or reason.split(" (")[0] != previous.split(" (")[0]:
                self.log("yielding — %s lane: %s; no %s session until it ends." % (lane, reason, lane))
            for name, worker_lane in self.workers:
                if worker_lane == lane:
                    (self.state / name / "idle.since").unlink(missing_ok=True)
        elif previous is not None:
            self.log("yield over — %s lane no longer waiting: %s." % (lane, previous.split(" (")[0]))
        self.lane_reasons[lane] = reason
        return reason

    def log(self, message):
        try:
            with (self.state / "daemon.log").open("a") as log:
                log.write("%s  [supervisor] %s\n" % (time.strftime("%F %T"), message))
        except OSError:
            pass  # the log is for the owner; never a reason to stop dispatch

    def run(self):
        self.state.mkdir(parents=True, exist_ok=True)
        with (self.state / "supervisor.lock").open("a+") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError("supervisor already running")
            self.prepare()
            for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                signal.signal(sig, lambda *_: setattr(self, "stop", True))
            awake = subprocess.Popen(["caffeinate", "-di", "-w", str(os.getpid())], close_fds=True)
            while self.cycle(time.time()):
                time.sleep(self.poll)
            self.publish(self.last_active, {})
            # Only the supervising process requests a durable global park, after
            # dispatched shells finish. A worker never unloads the other lane.
            if self.terminal and not self.global_stopped:
                env = self.child_env("worker-1", self.workers[0][1], upkeep=True)
                env["AUTONOMOUS_SUPERVISOR_PARK"] = self.terminal
                subprocess.run(["bash", str(self.args.script)], env=env, check=False)
        return 0 if not self.terminal else 9

    def prepare(self):
        legacy = self.state / "engine.lock"
        if legacy.exists() and not legacy.is_symlink() and time.time() - legacy.stat().st_mtime < self.stale:
            raise RuntimeError("serial engine still active; refusing migration")
        # Root artifacts retain the established worker-1 view. Never overwrite a
        # regular artifact; preserve it, and keep surviving claims untouched.
        for name in ("engine.lock", "last-session.log", "last-session.txt", "session-killed",
                     "usage-window.last", "usage-window.tsv"):
            path = self.state / name
            if path.exists() and not path.is_symlink():
                target = self.state / "worker-1" / name
                if name.startswith("usage-window") and not target.exists():
                    target.parent.mkdir(exist_ok=True)
                    target.write_bytes(path.read_bytes())
                path.rename(self.state / (name + ".pre-workers-" + str(time.time_ns())))
            if path.is_symlink():
                path.unlink()
            path.symlink_to(self.state / "worker-1" / name)
        # Explicit owner starts have a new generation. launchd crash relaunches
        # retain counters and terminal reasons, including parks written while the
        # old supervisor was dead and never present in its child table.
        generation_path = self.state / "run-generation"
        generation = generation_path.read_text().strip() if generation_path.exists() else "initial"
        previous = self.state / "supervisor-generation"
        fresh = not previous.exists() or previous.read_text().strip() != generation
        if fresh:
            directories = {self.state / worker for worker, _ in self.workers}
            directories.update(self.state.glob("worker-[0-9]*"))
            for directory in directories:
                if directory.is_symlink() or (directory.exists() and not directory.is_dir()):
                    raise RuntimeError("unexpected worker state path (preserved): " + str(directory))
                directory.mkdir(exist_ok=True)
                for name in ("idle.since", "nocomplete.count", "park.reason"):
                    (directory / name).unlink(missing_ok=True)
            for name in ("idle.since", "nocomplete.count", "gate-timeouts", "doc-budget-tries",
                         "doc-budget-head", "gate-fix-tries", "gate-fix-head", "supervisor-park.reason"):
                (self.state / name).unlink(missing_ok=True)
            previous.write_text(generation)
        else:
            reasons = list(self.state.glob("worker-*/park.reason"))
            reasons += [self.state / "supervisor-park.reason"]
            for path in reasons:
                if path.exists():
                    self.terminal = path.read_text().strip() or "worker park requires inspection"
                    break



def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--repo", type=Path)
    p.add_argument("--state", required=True, type=Path)
    p.add_argument("--plan", type=Path)
    p.add_argument("--script", type=Path)
    p.add_argument("--agent", choices=("claude", "codex", "both"), default="claude")
    p.add_argument("--workers", type=int, choices=(1, 2, 3), default=1)
    p.add_argument("--status", action="store_true")
    args = p.parse_args()
    if args.status:
        snapshot_status(args.state)
        return 0
    if not all((args.repo, args.plan, args.script)):
        p.error("--repo, --plan and --script are required")
    if args.workers == 3 and args.agent != "claude":
        p.error("--workers 3 is for the Claude lane alone (W35.three-workers); use --workers 2 with --agent " + args.agent)
    return Supervisor(args).run()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print("worker-supervisor: " + str(exc), file=sys.stderr)
        sys.exit(2)
