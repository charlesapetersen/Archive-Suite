#!/usr/bin/env python3
"""Bounded supervisor + actual shell/session barrier on scratch files.

Scheduler tests inject clock/process handles; claim liveness and shell startup/
claims_launch use actual harmless subprocesses. No installed daemon is touched.
Run --source-dir /path/to/ops/autonomous to inspect another worktree's sources.
"""
import argparse
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

parser = argparse.ArgumentParser()
parser.add_argument("--source-dir", type=Path, default=Path(__file__).resolve().parent.parent)
options, remaining = parser.parse_known_args()
SOURCE = options.source_dir.resolve()
REAL_POPEN = subprocess.Popen
spec = importlib.util.spec_from_file_location("supervisor_under_proof", SOURCE / "worker-supervisor.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Child:
    """Only scheduler's poll/returncode contract; never represents a live CLI."""
    def __init__(self):
        self.returncode = None
    def poll(self):
        return self.returncode


class Proof(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="worker supervisor [scratch] ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.state = self.root / "state with space"
        self.repo = self.root / "repo with space"
        self.repo.mkdir()
        self.state.mkdir()
        self.plan = self.repo / "plan.md"
        self.plan.write_text("RUN STATUS: IN_PROGRESS\n## WORK QUEUE\n")
        self.script = SOURCE / "archive-suite-autonomous.sh"
        self.env = dict(os.environ, AUTONOMOUS_INTERVAL="1", AUTONOMOUS_WINDOW_SLACK="0")
        # Always replace inherited paths to installed runtime or real CLIs.
        for key in tuple(self.env):
            if key.startswith("AUTONOMOUS_"):
                del self.env[key]
        self.env.update(AUTONOMOUS_INTERVAL="1", AUTONOMOUS_WINDOW_SLACK="0",
                        AUTONOMOUS_YIELD_CMD=str(self.root / "absent yield"),
                        AUTONOMOUS_STATUS_CMD=str(self.root / "absent status"))
        self.launches = []
        self.now = 1000
        self.owned = []
        self.addCleanup(self.stop_owned)

    def stop_owned(self):
        for child in self.owned:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=5)
            for stream in (child.stdin, child.stdout, child.stderr):
                if stream is not None:
                    stream.close()

    def supervisor(self, workers=2, agent="both"):
        args = SimpleNamespace(state=self.state, repo=self.repo, plan=self.plan,
                               script=self.script, workers=workers, agent=agent)
        sup = module.Supervisor(args, self.env)
        sup.next_upkeep = 10**12
        return sup

    def fake_launch(self, argv, **kwargs):
        # subprocess.run (process identity/yield probes) shares the module;
        # preserve real harmless probes while replacing only worker dispatch.
        if argv[:2] != ["bash", str(self.script)]:
            return REAL_POPEN(argv, **kwargs)
        env = kwargs["env"]
        child = Child()
        self.launches.append((self.now, env["AUTONOMOUS_WORKER_ID"], env["AUTONOMOUS_AGENT"], child))
        self.assertEqual(env["AUTONOMOUS_START_STAGGER"], "1")
        self.assertEqual(env["AUTONOMOUS_WORKER_CHILD"], "1")
        return child

    def cycle(self, sup, now, active=None, pauses=None):
        self.now = now
        with patch.object(module.time, "time", return_value=now), \
                patch.object(module.subprocess, "Popen", side_effect=self.fake_launch), \
                patch.object(sup, "lane_pause", side_effect=lambda lane, _: (pauses or {}).get(lane, 0)):
            if active is None:
                with patch.object(sup, "active", return_value=[]):
                    return sup.cycle(now)
            with patch.object(sup, "active", return_value=active):
                return sup.cycle(now)

    def test_bounds_fairness_and_replacement_stagger(self):
        for count in (1, 2):
            with self.subTest(workers=count):
                self.launches.clear()
                sup = self.supervisor(count)
                for now in range(1000, 1601, 10):
                    self.cycle(sup, now)
                self.assertEqual(len(self.launches), count * 2)
                self.assertEqual([r[2] for r in self.launches], ["claude"] * count + ["codex"] * count)
                self.assertEqual(sum(r[2] == "codex" for r in self.launches), count)
                # Free the first slot just after another launch. A replacement
                # must obey the global stagger, not merely its own retry delay.
                last = self.launches[-1][0]
                self.launches[0][3].returncode = 0
                self.cycle(sup, last + 1)
                self.cycle(sup, last + 59)
                self.assertEqual(len(self.launches), count * 2)
                self.cycle(sup, last + 60)
                self.assertEqual(len(self.launches), count * 2 + 1)
                self.assertTrue(all(b[0] - a[0] >= 60 for a, b in zip(self.launches, self.launches[1:])))
                self.assertEqual(self.launches[-1][1], "worker-1")

    def test_single_lane_bounds(self):
        for lane in ("claude", "codex"):
            for count in (1, 2):
                with self.subTest(lane=lane, workers=count):
                    self.launches.clear()
                    sup = self.supervisor(count, agent=lane)
                    for now in range(1000, 1301, 60):
                        self.cycle(sup, now)
                    self.assertEqual(len(self.launches), count)
                    self.assertTrue(all(row[2] == lane for row in self.launches))

    def test_yield_suppresses_new_dispatch_then_resumes(self):
        sup = self.supervisor(1)
        fake_yield = self.root / "fake priority check"
        fake_yield.write_text("#!/bin/sh\nexit 0\n")
        fake_yield.chmod(0o755)
        sup.env["AUTONOMOUS_YIELD_CMD"] = str(fake_yield)
        self.cycle(sup, 1000)
        self.assertEqual(self.launches, [])
        self.assertTrue((self.state / "yield.reason").exists())
        fake_yield.write_text("#!/bin/sh\nexit 1\n")
        self.cycle(sup, 1060)
        self.assertEqual(len(self.launches), 1)
        self.assertFalse((self.state / "yield.reason").exists())

    def test_complete_waits_for_claims_and_children_before_teardown(self):
        sup = self.supervisor(1)
        self.cycle(sup, 1000)
        self.plan.write_text("RUN STATUS: COMPLETE\n")
        with patch.object(sup, "upkeep", return_value=9) as upkeep:
            self.assertTrue(self.cycle(sup, 1060))
            upkeep.assert_not_called()
            sup.children["worker-1"].returncode = 0
            self.assertTrue(self.cycle(sup, 1120, active=[{"worker":"old", "subscription":"codex", "tag":"A"}]))
            upkeep.assert_not_called()
            self.assertFalse(self.cycle(sup, 1180))
            upkeep.assert_called_once()
        self.assertEqual(len(self.launches), 1)

    def test_failed_or_parked_worker_stops_refill_without_cancel(self):
        for code, reason in ((9, "attempt cap"), (2, None)):
            with self.subTest(code=code):
                self.launches.clear()
                sup = self.supervisor(1)
                self.cycle(sup, 1000)
                self.cycle(sup, 1060)
                if reason:
                    (self.state / "worker-1/park.reason").write_text(reason)
                sup.children["worker-1"].returncode = code
                self.assertTrue(self.cycle(sup, 1120))
                self.assertEqual(len(self.launches), 2)
                self.assertIn("worker-2", sup.children)
                self.assertTrue(sup.terminal)
                sup.children["worker-2"].returncode = 0
                self.assertFalse(self.cycle(sup, 1180))
                (self.state / "worker-1/park.reason").unlink(missing_ok=True)

    def test_pending_repair_drains_and_takes_one_slot(self):
        for name in ("gate-fix", "doc-budget-fix"):
            with self.subTest(name=name):
                self.launches.clear()
                sup = self.supervisor(1)
                self.cycle(sup, 1000)
                (self.state / name).touch()
                self.cycle(sup, 1060)
                self.assertEqual(len(self.launches), 1)
                sup.children["worker-1"].returncode = 0
                with patch.object(sup, "upkeep", return_value=0) as upkeep:
                    sup.next_upkeep = 0
                    self.cycle(sup, 1120)
                    upkeep.assert_called_once()
                self.assertEqual(len(self.launches), 2)
                self.cycle(sup, 1180)
                self.assertEqual(len(self.launches), 2)
                (self.state / name).unlink()

    def test_upkeep_due_drains_and_never_overlaps_claims(self):
        sup = self.supervisor(1)
        self.cycle(sup, 1000)
        sup.next_upkeep = 1020
        with patch.object(sup, "upkeep", return_value=0) as upkeep:
            self.cycle(sup, 1060)
            upkeep.assert_not_called()
            self.assertEqual(len(self.launches), 1)
            sup.children["worker-1"].returncode = 0
            self.cycle(sup, 1120, active=[{"worker":"orphan", "subscription":"codex", "tag":"A"}])
            upkeep.assert_not_called()
            self.cycle(sup, 1180)
            upkeep.assert_called_once()
        self.assertEqual(len(self.launches), 2)

    def test_source_refresh_drains_and_exits_without_global_park(self):
        sup = self.supervisor(1)
        self.cycle(sup, 1000)
        sup.next_upkeep = 1020
        with patch.object(sup, "upkeep", return_value=12) as upkeep:
            self.assertTrue(self.cycle(sup, 1060))
            upkeep.assert_not_called()
            sup.children["worker-1"].returncode = 0
            self.assertTrue(self.cycle(sup, 1120, active=[{"worker":"orphan", "subscription":"codex", "tag":"A"}]))
            upkeep.assert_not_called()
            self.assertFalse(self.cycle(sup, 1180))
            upkeep.assert_called_once()
        self.assertFalse(sup.terminal)
        self.assertFalse((self.state / "supervisor-park.reason").exists())
        self.assertEqual(len(self.launches), 1)

    def test_real_drained_upkeep_refreshes_committed_helper_only_change(self):
        env = self.shell_env()
        autonomous = self.repo / "ops/autonomous"
        autonomous.mkdir(parents=True)
        (autonomous / "archive-suite-autonomous.sh").write_bytes(self.script.read_bytes())
        (autonomous / "resume-prompt.txt").write_text("scratch prompt")
        helper = autonomous / "worker-supervisor.py"
        helper.write_text("# helper version one\n")
        git = ["git", "-C", str(self.repo), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"]
        subprocess.run(git + ["add", "-A"], check=True, capture_output=True)
        subprocess.run(git + ["commit", "-qm", "scratch baseline"], check=True, capture_output=True)
        installed = self.root / "installed daemon.sh"
        installed.write_bytes(self.script.read_bytes())
        binaries = self.root / "refresh fixture bin"
        binaries.mkdir()
        for name in ("security", "caffeinate"):
            command = binaries / name
            command.write_text("#!/bin/sh\nexit 0\n")
            command.chmod(0o755)
        env.update(PATH=str(binaries)+os.pathsep+env['PATH'], AUTONOMOUS_LABEL="proverefresh", XPC_SERVICE_NAME="com.proverefresh.autonomous",
                   AUTONOMOUS_GATE_EVERY="0", AUTONOMOUS_DOC_PREGATE="0", AUTONOMOUS_MINFREE_MB="1",
                   AUTONOMOUS_COMPACTOR=str(self.root / "absent compactor"))
        self.env = env
        sup = self.supervisor(1)
        sup.args.script = installed
        helper.write_text("# helper version two\n")
        subprocess.run(git + ["add", "-A"], check=True, capture_output=True)
        subprocess.run(git + ["commit", "-qm", "scratch helper-only change"], check=True, capture_output=True)
        (self.state / "restart-on-source-change").touch()
        # Neither the installed shell nor the prompt changed: imported helpers
        # alone must request a clean supervisor relaunch at the idle boundary.
        self.assertEqual(installed.read_bytes(), (autonomous / "archive-suite-autonomous.sh").read_bytes())
        self.assertEqual(sup.upkeep(), 12)
        self.assertFalse((self.state / "supervisor-park.reason").exists())
        self.assertIn("supervisor-helpers", (self.state / "daemon.log").read_text())

    def test_lane_pause_reads_all_siblings_and_account_latest(self):
        sup = self.supervisor(2)
        fake_usage = self.root / "fake usage"
        fake_usage.write_text("#!/bin/sh\nprintf '5 1200\\n'\n")
        fake_usage.chmod(0o755)
        sup.env["AUTONOMOUS_USAGE_CMD"] = str(fake_usage)
        for worker, _ in sup.workers:
            (self.state / worker).mkdir()
        (self.state / "worker-1/usage-window.last").write_text("95 1100")
        (self.state / "worker-2/usage-window.last").write_text("2 1050")
        (self.state / "worker-3/usage-window.last").write_text("90 1200 cut")
        (self.state / "worker-4/usage-window.last").write_text("1 900")
        self.assertEqual(sup.lane_pause("claude", 1000), 1100)
        self.assertEqual(sup.lane_pause("codex", 1000), 1200)
        self.assertEqual(sup.lane_pause("claude", 1100), 0)
        self.assertEqual(sup.lane_pause("codex", 1200), 0)
        # Exhausting Claude leaves Codex capacity eligible, then the lane resets.
        self.cycle(sup, 1000, pauses={"claude":1100})
        self.assertEqual(self.launches[-1][2], "codex")
        self.cycle(sup, 1100)
        self.cycle(sup, 1160)
        self.assertEqual(self.launches[-1][2], "claude")

    def test_usage_reset_slack_is_retained_to_its_boundary(self):
        readings = ["95 1100", "1 1050"]
        self.assertEqual(module.paused(readings, 1099, 95, 120), 1220)
        self.assertEqual(module.paused(readings, 1100, 95, 120), 1220)
        self.assertEqual(module.paused(readings, 1219, 95, 120), 1220)
        self.assertEqual(module.paused(readings, 1220, 95, 120), 0)

    def claim(self, tag, worker, subscription, **extra):
        directory = self.state / "claims" / tag
        directory.mkdir(parents=True)
        record = dict(tag=tag, worker=worker, lane="reader", subscription=subscription,
                      token="a" * 32, pid=os.getpid(), pid_start=module.coord.identity(os.getpid()), started=1)
        record.update(extra)
        module.coord.write_record(directory / "owner.json", record)
        return record

    def test_protected_orphan_occupies_subscription_capacity(self):
        child = subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.read()"], stdin=subprocess.PIPE)
        self.owned.append(child)
        self.claim("A", "worker-old", "codex", pid=os.getpid(), pid_start="dead owner",
                   protected=[dict(pid=child.pid, start=module.coord.identity(child.pid))])
        sup = self.supervisor(1)
        self.assertEqual(len(sup.active()), 1)
        self.cycle(sup, 1000, active=sup.active())
        self.cycle(sup, 1060, active=sup.active())
        self.assertEqual([r[2] for r in self.launches], ["claude"])
        marker = self.root / "forbidden upkeep"
        proc = subprocess.run([sys.executable, str(SOURCE / "worker-state.py"), "--state", str(self.state),
                               "--repo", str(self.repo), "--plan", str(self.plan), "idle", "--",
                               sys.executable, "-c", "from pathlib import Path; Path(" + repr(str(marker)) + ").touch()"],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 4, proc.stderr)
        self.assertFalse(marker.exists())
        self.assertTrue((self.state / "claims/A/owner.json").exists())

    def test_orphan_plus_unpublished_children_stay_within_two_slots(self):
        sup = self.supervisor(2)
        active = [{"tag":"A", "worker":"old-supervisor-worker", "subscription":"codex"}]
        for now in range(1000, 1421, 60):
            self.cycle(sup, now, active=active)
        self.assertEqual(sum(r[2] == "claude" for r in self.launches), 2)
        self.assertEqual(sum(r[2] == "codex" for r in self.launches), 1)
        # Once a pending child's claim publishes, its slot counts exactly once.
        codex_worker = next(r[1] for r in self.launches if r[2] == "codex")
        published = active + [{"tag":"B", "worker":codex_worker, "subscription":"codex"}]
        self.cycle(sup, 1480, active=published)
        self.assertEqual(sum(r[2] == "codex" for r in self.launches), 1)

    def test_unknown_claim_conservatively_occupies_both_lanes(self):
        sup = self.supervisor(1)
        self.cycle(sup, 1000, active=[{"tag":"A", "unknown":True}])
        self.assertEqual(self.launches, [])

    def test_status_lists_each_worker_and_lane(self):
        sup = self.supervisor(2)
        sup.terminal = "worker stopped"
        sup.publish([{"worker":"worker-1", "tag":"A"}], {"codex":1100})
        stream = io.StringIO()
        with redirect_stdout(stream):
            module.snapshot_status(self.state)
        text = stream.getvalue()
        for worker, lane in sup.workers:
            self.assertIn(worker + "  " + lane, text)
        self.assertIn("claimed A", text)
        self.assertIn("usage pause", text)
        self.assertIn("dispatch stopped", text)

    def shell_env(self):
        home = self.root / "home"
        home.mkdir(exist_ok=True)
        fake_cli = self.root / "fake cli"
        fake_cli.write_text("#!/bin/sh\nexit 97\n")
        fake_cli.chmod(0o755)
        (self.state / "resume-prompt.txt").write_text("scratch prompt")
        (self.state / "codex-preamble.txt").write_text("scratch codex preamble")
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True, capture_output=True)
        return dict(self.env, HOME=str(home), AUTONOMOUS_REPO=str(self.repo), AUTONOMOUS_PLAN=str(self.plan),
                    AUTONOMOUS_STATE=str(self.state), AUTONOMOUS_CLAIMS_CMD=str(SOURCE / "worker-state.py"),
                    AUTONOMOUS_CLAUDE=str(fake_cli), AUTONOMOUS_CODEX=str(fake_cli),
                    AUTONOMOUS_WORKER_CHILD="1", AUTONOMOUS_WORKER_ID="worker-1", AUTONOMOUS_AGENT="claude")

    def test_actual_child_startup_preserves_all_retry_counters(self):
        env = self.shell_env()
        self.plan.write_text("RUN STATUS: COMPLETE\n")
        directory = self.state / "worker-1"
        directory.mkdir()
        counters = [self.state / name for name in ("gate-timeouts", "doc-budget-tries", "doc-budget-head",
                                                   "gate-fix-tries", "gate-fix-head", "nocomplete.count", "idle.since")]
        counters += [directory / "nocomplete.count", directory / "idle.since"]
        for path in counters:
            path.write_text("preserve me")
        for _ in range(2):
            proc = subprocess.run(["bash", str(self.script)], env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(proc.returncode, 9, proc.stderr)
            self.assertTrue(all(p.read_text() == "preserve me" for p in counters))

    def test_explicit_supervisor_restart_resets_actual_repair_counters(self):
        sup = self.supervisor(1)
        actual_names = ("gate-timeouts", "doc-budget-tries", "doc-budget-head", "gate-fix-tries", "gate-fix-head")
        for name in actual_names:
            (self.state / name).write_text("3")
        for worker, _ in sup.workers:
            (self.state / worker).mkdir()
            (self.state / worker / "nocomplete.count").write_text("5")
        sup.prepare()
        self.assertTrue(all(not (self.state / name).exists() for name in actual_names))
        self.assertTrue(all(not (self.state / w / "nocomplete.count").exists() for w, _ in sup.workers))

    def test_inspection_failure_drains_owned_children_then_can_park(self):
        sup = self.supervisor(1)
        self.cycle(sup, 1000)
        sup.last_active = [{"worker":"worker-1", "subscription":"claude", "tag":"A"}]
        with patch.object(sup, "active", side_effect=RuntimeError("corrupt claim")), \
                patch.object(sup, "lane_pause", return_value=0):
            self.assertTrue(sup.cycle(1060))
            sup.children["worker-1"].returncode = 0
            self.assertFalse(sup.cycle(1120))
        self.assertIn("inspection required", sup.terminal)
        self.assertTrue((self.state / "supervisor-park.reason").exists())
        self.assertEqual(len(self.launches), 1)

    def test_crash_relaunch_preserves_worker_park_and_counters(self):
        sup = self.supervisor(1)
        sup.prepare()
        (self.state / "worker-1/park.reason").write_text("inspection required")
        (self.state / "gate-fix-tries").write_text("2")
        restarted = self.supervisor(1)
        restarted.prepare()
        self.assertEqual(restarted.terminal, "inspection required")
        self.assertEqual((self.state / "gate-fix-tries").read_text(), "2")
        self.assertFalse(self.cycle(restarted, 1000))
        self.assertEqual(self.launches, [])
        (self.state / "worker-3").mkdir()
        (self.state / "worker-3/park.reason").write_text("old layout park")
        (self.state / "run-generation").write_text("explicit-owner-restart")
        owner_restart = self.supervisor(1)
        owner_restart.prepare()
        self.assertFalse(owner_restart.terminal)
        self.assertFalse((self.state / "worker-1/park.reason").exists())
        self.assertFalse((self.state / "worker-3/park.reason").exists())
        self.assertFalse((self.state / "gate-fix-tries").exists())

    def test_upkeep_reconciles_owner_stop_before_idle_lock(self):
        sup = self.supervisor(1)
        fake_upkeep = self.root / "fake upkeep.sh"
        fake_upkeep.write_text('#!/bin/sh\ntest ! -e "$AUTONOMOUS_STATE/owner-stopped"\n')
        fake_upkeep.chmod(0o755)
        sup.args.script = fake_upkeep
        (self.state / "owner-stopped").touch()
        self.assertEqual(sup.upkeep(), 0)
        self.assertFalse((self.state / "owner-stopped").exists())

    def test_idle_gate_can_read_real_queue_after_claim_exists(self):
        self.plan.write_text("RUN STATUS: IN_PROGRESS\n## WORK QUEUE\n- [ ] **A — work**\n## HOLD QUEUE\n")
        (self.repo / "ops").mkdir()
        (self.repo / "ops/autonomous").symlink_to(SOURCE, target_is_directory=True)
        (self.repo / "SUITE_TODO.md").write_text("- [ ] **A — work**\n")
        (self.state / "claims").mkdir()
        env = dict(self.env, AUTONOMOUS_PLAN=str(self.plan), AUTONOMOUS_STATE=str(self.state),
                   AUTONOMOUS_REPO=str(self.repo))
        result = subprocess.run([sys.executable, str(SOURCE / "worker-state.py"), "--state", str(self.state),
                                 "--repo", str(self.repo), "--plan", str(self.plan), "idle", "--",
                                 "bash", str(SOURCE / "next-queue-item.sh"), str(self.repo)],
                                env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ok\tA\t", result.stdout)
        self.assertIn("A", result.stdout)

    def test_real_supervisor_dispatches_two_claimed_shell_workers(self):
        env = self.shell_env()
        (self.repo / "ops").mkdir()
        (self.repo / "ops/autonomous").symlink_to(SOURCE, target_is_directory=True)
        (self.repo / "SUITE_TODO.md").write_text("- [ ] **A — reader**\n- [ ] **B — notes**\n")
        self.plan.write_text("RUN STATUS: IN_PROGRESS\n## WORK QUEUE\n- [ ] **A — reader** (lane: reader)\n"
                             "- [ ] **B — notes** (lane: notes)\n## HOLD QUEUE\n## Session Log\n## Daemon Report\n")
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                        "commit", "--allow-empty", "-qm", "scratch baseline"], check=True, capture_output=True)
        sha = subprocess.check_output(["git", "-C", str(self.repo), "rev-parse", "HEAD"], text=True).strip()
        fixture_bin = self.root / "fixture bin"
        fixture_bin.mkdir()
        for name in ("caffeinate", "security"):
            command = fixture_bin / name
            command.write_text("#!/bin/sh\nexit 0\n")
            command.chmod(0o755)
        no_usage = fixture_bin / "no usage"
        no_usage.write_text("#!/bin/sh\nexit 3\n")
        no_usage.chmod(0o755)
        cli = self.root / "functional fake CLI.py"
        cli.write_text("""#!/usr/bin/env python3
import json, os, re, subprocess, sys, time
from pathlib import Path
prompt=' '.join(sys.argv[1:])
tag=re.search(r'Your ONE item is ([A-Za-z0-9._-]+)',prompt)[1]
state=Path(os.environ['AUTONOMOUS_STATE']); worker=Path(os.environ['AUTONOMOUS_WORKER_STATE']).name
row={'tag':tag,'worker':worker,'start':float((state/'dispatch.last').read_text()),
     'worker_id_leaked':'AUTONOMOUS_WORKER_ID' in os.environ,
     'role_leaked':'AUTONOMOUS_WORKER_CHILD' in os.environ}
(state/(tag+'.started')).write_text(json.dumps(row))
print(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':'scratch session'}}),flush=True)
deadline=time.monotonic()+85
while not (state/'A.started').exists() or not (state/'B.started').exists():
    if time.monotonic()>deadline: raise SystemExit('second worker never dispatched')
    time.sleep(.05)
# Witness both real reservations before either worker releases its claim.
if len(list((state/'claims').glob('*/owner.json'))) == 2:
    (state/'two-live-claims').touch()
subprocess.run([sys.executable,os.environ['PROOF_PLAN_EDIT'],os.environ['AUTONOMOUS_PLAN'],
                'complete',tag,os.environ['PROOF_SHA'],'scratch done'],check=True)
time.sleep(.3)
""")
        cli.chmod(0o755)
        wrapper = self.root / "functional supervisor.py"
        wrapper.write_text("""import importlib.util, os
from pathlib import Path
from types import SimpleNamespace
spec=importlib.util.spec_from_file_location('sup',os.environ['PROOF_SUPERVISOR'])
s=importlib.util.module_from_spec(spec);spec.loader.exec_module(s)
a=SimpleNamespace(state=Path(os.environ['AUTONOMOUS_STATE']),repo=Path(os.environ['AUTONOMOUS_REPO']),
 plan=Path(os.environ['AUTONOMOUS_PLAN']),script=Path(os.environ['PROOF_SHELL']),workers=1,agent='both')
p=s.Supervisor(a);p.poll=.1
# Global preflight has dedicated idle-lock tests; this fixture isolates real
# parent -> shell -> reservation -> CLI dispatch and its actual sixty-second gap.
p.upkeep=lambda: 0
raise SystemExit(p.run())
""")
        env.update(AUTONOMOUS_CLAUDE=str(cli), AUTONOMOUS_CODEX=str(cli), AUTONOMOUS_USAGE_CMD=str(no_usage),
                   CODEX_HOME=str(self.root / "empty codex"), PATH=str(fixture_bin)+os.pathsep+env['PATH'],
                   PROOF_SHA=sha, PROOF_PLAN_EDIT=str(SOURCE / "plan-edit.py"),
                   PROOF_SUPERVISOR=str(SOURCE / "worker-supervisor.py"), PROOF_SHELL=str(self.script))
        env.pop("AUTONOMOUS_WORKER_CHILD", None)
        env.pop("AUTONOMOUS_WORKER_ID", None)
        with (self.root / "functional.log").open("w") as output:
            child = subprocess.Popen([sys.executable, str(wrapper)], env=env, stdout=output, stderr=output,
                                     start_new_session=True)
            self.owned.append(child)
            try:
                code = child.wait(timeout=100)
            finally:
                # This fixture alone created this OS session. Retire remaining
                # heartbeat sleeps; actual CLI sessions use their own claim SIDs.
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                for path in (self.state / 'claims').glob('*/owner.json'):
                    record = json.loads(path.read_text())
                    if module.coord.session_live(record):
                        os.killpg(record['sid'], signal.SIGTERM)
        self.assertEqual(code, 0, (self.root / "functional.log").read_text())
        a = json.loads((self.state / "A.started").read_text())
        b = json.loads((self.state / "B.started").read_text())
        self.assertGreaterEqual(b['start']-a['start'], 60)
        self.assertEqual({a['worker'],b['worker']}, {'worker-1','worker-2'})
        self.assertFalse(a['worker_id_leaked'] or b['worker_id_leaked'] or a['role_leaked'] or b['role_leaked'])
        self.assertTrue((self.state / "two-live-claims").exists())
        self.assertIn('RUN STATUS: COMPLETE',self.plan.read_text())
        self.assertEqual(list((self.state / 'claims').glob('*/owner.json')), [])

    def test_actual_shell_claim_dispatch_staggers_delayed_cli_starts(self):
        env = self.shell_env()
        # Inject virtual time only into the coordinator process. The final exec
        # really reaches the harmless CLI fixture after recording actual start.
        runner = self.root / "coordinator with fake clock.py"
        runner.write_text("""#!/usr/bin/env python3
import importlib.util, os, sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('coord', os.environ['PROOF_COORD'])
c=importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
clock=[float(os.environ['PROOF_NOW'])]
c.time.time=lambda: clock[0]
c.time.monotonic=lambda: clock[0]
c.time.sleep=lambda n: clock.__setitem__(0, clock[0]+n)
sys.exit(c.main())
""")
        fixture = self.root / "harmless fake CLI.py"
        fixture.write_text("""import json, os, sys
from pathlib import Path
state=Path(os.environ['AUTONOMOUS_STATE'])
with Path(os.environ['PROOF_OUTPUT']).open('a') as f:
    f.write(json.dumps({'started':float((state/'dispatch.last').read_text()),'argv':sys.argv[1:]})+'\\n')
""")
        output = self.root / "actual starts.jsonl"
        env.update(AUTONOMOUS_CLAIMS_CMD=str(runner), PROOF_COORD=str(SOURCE / "worker-state.py"), PROOF_OUTPUT=str(output))
        for index, start in enumerate((1000, 1040, 1080), 1):
            tag = "A" + str(index)
            record = self.claim(tag, "worker-1", "claude")
            env["PROOF_NOW"] = str(start)
            # Values use shell positionals; no interpolated paths or expressions.
            command = 'source "$1"; CLAIM_TAG="$2"; CLAIM_TOKEN="$3"; claims_launch "$4" "$5" "$(claims_prompt)"'
            proc = subprocess.run(["bash", "-c", command, "proof", str(self.script), tag, record["token"],
                                   sys.executable, str(fixture)], env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(proc.returncode, 0, proc.stderr)
        rows = [json.loads(line) for line in output.read_text().splitlines()]
        self.assertEqual([r["started"] for r in rows], [1000,1060,1120])
        self.assertTrue(all("SUPERVISOR ASSIGNMENT" in r["argv"][0] for r in rows))
        self.assertTrue(all("Skip STEP 2 selection" in r["argv"][0] for r in rows))
        for index in range(1,4):
            record = json.loads((self.state / "claims" / ("A"+str(index)) / "owner.json").read_text())
            self.assertEqual(record["child"], record["sid"])
            self.assertTrue(record["child_start"])


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]] + remaining, verbosity=2)
