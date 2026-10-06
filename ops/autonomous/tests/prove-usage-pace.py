#!/usr/bin/env python3
"""W35.pace proof: slot sizing from usage readings, on scratch files only.

Fixture lines copy the shapes of real CLI output (a claude stream-json
rate_limit_event, a codex rollout token_count). No CLI, daemon, installed state
or real ~/.codex is read: every source path is a scratch file.
Run --source-dir /path/to/ops/autonomous to inspect another worktree's sources.
"""
import argparse
import importlib.util
import json
import os
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


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, SOURCE / file)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


pace = load("pace_under_proof", "usage-pace.py")
sup_module = load("supervisor_under_proof", "worker-supervisor.py")
H = 3600


def claude_event(used, reset, **weekly):
    windows = {"five_hour": {"utilization": used, "resetsAt": reset}}
    windows.update({k: {"utilization": u, "resetsAt": r} for k, (u, r) in weekly.items()})
    return json.dumps({"type": "rate_limit_event", "rate_limit_info": {
        "status": "allowed", "resetsAt": reset, "rateLimitType": "five_hour", "overageStatus": "rejected",
        "isUsingOverage": False, "unifiedWindows": windows}, "session_id": "scratch"})


def claude_rejected(reset, kind="five_hour"):
    return json.dumps({"type": "rate_limit_event", "rate_limit_info": {
        "status": "rejected", "resetsAt": reset, "rateLimitType": kind}})


def codex_line(primary, p_reset, secondary, s_reset, limit_id="codex"):
    return json.dumps({"timestamp": "2026-10-06T14:58:12.817Z", "type": "event_msg", "payload": {
        "type": "token_count", "info": {"total_token_usage": {"input_tokens": 1}},
        "rate_limits": {"limit_id": limit_id, "limit_name": None,
                        "primary": {"used_percent": primary, "window_minutes": 300, "resets_at": p_reset},
                        "secondary": {"used_percent": secondary, "window_minutes": 10080, "resets_at": s_reset},
                        "credits": {"has_credits": False}}}})


class Rules(unittest.TestCase):
    def test_band_boundaries_follow_the_plan_margins(self):
        now, reset = 0, 2.5 * H  # half of the five-hour window gone
        cases = [(0.39, "grow"), (0.40, "steady"), (0.65, "steady"), (0.66, "tight")]
        for used, expected in cases:
            with self.subTest(used=used):
                self.assertEqual(pace.band(used, reset, 5 * H, now)[0], expected)
        # Late in the window the absolute ceilings take over.
        self.assertEqual(pace.band(0.79, 1, 5 * H, 0)[0], "grow")
        self.assertEqual(pace.band(0.80, 1, 5 * H, 0)[0], "steady")
        self.assertEqual(pace.band(0.86, 1, 5 * H, 0)[0], "tight")
        # Just after a reset nothing is elapsed, so any spend is ahead of pace.
        self.assertEqual(pace.band(0.0, 5 * H, 5 * H, 0)[0], "steady")
        self.assertEqual(pace.band(0.16, 5 * H, 5 * H, 0)[0], "tight")

    def test_weekly_gates_against_its_own_elapsed_share(self):
        now = 0
        five = (0.10, 2 * H, 5 * H)  # 60% of the window gone: far under pace
        self.assertEqual(pace.assess({"five_hour": five}, now)[0], "grow")
        # Two days into the week with 60% spent: tight, so the lane holds at one.
        week = (0.60, 5 * 24 * H, 7 * 24 * H)
        name, note = pace.assess({"five_hour": five, "weekly": week}, now)
        self.assertEqual(name, "tight")
        self.assertIn("week 60% used / 29% elapsed", note)
        self.assertEqual(pace.assess({"weekly": week}, now)[0], "unknown")
        # Early in a week nothing can be "grow" against it; the weekly window must
        # not hold a second worker back for ~17 h after every weekly reset.
        fresh_week = (0.01, 7 * 24 * H - H, 7 * 24 * H)
        self.assertEqual(pace.band(*fresh_week, now)[0], "steady")
        self.assertEqual(pace.assess({"five_hour": five, "weekly": fresh_week}, now)[0], "grow")

    def test_cap_never_drops_below_one_and_steady_keeps_the_count(self):
        sequence = [("unknown", 1), ("steady", 1), ("grow", 2), ("steady", 2), ("tight", 1),
                    ("steady", 1), ("grow", 2), ("unknown", 1)]
        cap = 1
        for name, expected in sequence:
            cap = pace.next_cap(cap, name, 2)
            self.assertEqual(cap, expected, name)
        self.assertEqual(pace.next_cap(1, "grow", 1), 1)


class Parsing(unittest.TestCase):
    def test_claude_latest_event_and_weekly_windows(self):
        lines = [claude_event(0.10, 100), "not json", '{"type":"rate_limit_event"',
                 claude_event(0.20, 100, seven_day=(0.30, 900), seven_day_opus=(0.50, 950)),
                 claude_event(0.25, 100)]
        found = pace.claude_windows(lines)
        self.assertEqual(found["five_hour"], (0.25, 100, 5 * H))
        # The fullest weekly window in its event gates, and a later event without one keeps it.
        self.assertEqual(found["weekly"], (0.50, 950, 7 * 24 * H))

    def test_claude_rejections_read_as_full(self):
        self.assertEqual(pace.claude_windows([claude_rejected(500)])["five_hour"], (1.0, 500, 5 * H))
        self.assertEqual(pace.claude_windows([claude_rejected(900, "seven_day_opus")])["weekly"],
                         (1.0, 900, 7 * 24 * H))

    def test_malformed_values_are_skipped_never_raised(self):
        bad_claude = ['{"type":"rate_limit_event","rate_limit_info":"text"}',
                      '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":Infinity}}',
                      '{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":'
                      '{"five_hour":{"utilization":NaN,"resetsAt":1e400}}}}',
                      '[{"type":"rate_limit_event"}]']
        self.assertEqual(pace.claude_windows(bad_claude), {})
        zero = codex_line(10.0, 100, 10.0, 900).replace('"window_minutes": 300', '"window_minutes": 0')
        self.assertNotIn("five_hour", pace.codex_windows([zero]))
        self.assertIn("weekly", pace.codex_windows([zero]))

    def test_codex_reads_only_the_codex_limit(self):
        lines = [codex_line(40.0, 100, 70.0, 900), codex_line(99.0, 100, 99.0, 900, limit_id="premium")]
        found = pace.codex_windows(lines)
        self.assertEqual(found["five_hour"], (0.40, 100, 300 * 60))
        self.assertEqual(found["weekly"], (0.70, 900, 10080 * 60))


class Sources(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="usage pace [scratch] ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)

    def write(self, name, lines, mtime):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines) + "\n")
        os.utime(path, (mtime, mtime))
        return path

    def test_highest_current_reading_wins_whatever_the_mtimes(self):
        # The most recently touched file holds the LOWER, older reading: a log is
        # rewritten by tool output between the CLI's ~1% usage events.
        high = self.write("high log", [claude_event(0.30, 2000, seven_day=(0.4, 9000))], 100)
        low = self.write("low log", [claude_event(0.10, 2000)], 200)
        stale = self.write("stale log", [claude_event(0.90, 999)], 300)  # its window already reset
        found = pace.current_reading([high, low, stale, self.root / "absent"], pace.claude_windows, 1000)
        self.assertEqual(found["five_hour"][:2], (0.30, 2000))
        self.assertEqual(found["five_hour"][3], str(high))
        self.assertEqual(found["weekly"][:2], (0.4, 9000))

    def test_tail_skips_a_cut_first_line(self):
        path = self.write("big log", ["x" * 100, claude_event(0.42, 2000)], 0)
        lines = pace.tail_lines(path, limit=len(claude_event(0.42, 2000)) + 5)
        self.assertEqual(pace.claude_windows(lines)["five_hour"][0], 0.42)
        self.assertNotIn("x" * 100, lines)

    def test_codex_sources_are_recent_rollouts_newest_first(self):
        self.write("codex/sessions/2026/10/06/rollout-a.jsonl", [], 1000)
        self.write("codex/sessions/2026/10/06/rollout-b.jsonl", [], 2000)
        self.write("codex/sessions/2026/10/01/rollout-old.jsonl", [], 1000 - 7 * H)
        self.write("codex/sessions/2026/10/06/other.jsonl", [], 2000)
        names = [p.name for p in pace.codex_sources(self.root / "codex", 2500)]
        self.assertEqual(names, ["rollout-b.jsonl", "rollout-a.jsonl"])


class Child:
    def __init__(self):
        self.returncode = None

    def poll(self):
        return self.returncode


class Supervisor(unittest.TestCase):
    """lane_cap read from scratch logs, and the slot check that obeys it."""

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="usage pace supervisor [scratch] ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.state = self.root / "state with space"
        self.repo = self.root / "repo with space"
        for path in (self.state, self.repo):
            path.mkdir()
        self.plan = self.repo / "plan.md"
        self.plan.write_text("RUN STATUS: IN_PROGRESS\n## WORK QUEUE\n")
        self.vision = self.root / "vision ocr" / "last-session.log"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("AUTONOMOUS_")}
        self.env.update(AUTONOMOUS_INTERVAL="1", AUTONOMOUS_WINDOW_SLACK="0",
                        AUTONOMOUS_YIELD_CMD=str(self.root / "absent yield"),
                        AUTONOMOUS_STATUS_CMD=str(self.root / "absent status"),
                        AUTONOMOUS_SHARED_USAGE_LOGS=str(self.vision),
                        CODEX_HOME=str(self.root / "codex home"))
        self.launches = []
        self.now = 100000

    def supervisor(self, workers=2, agent="claude", **env):
        args = SimpleNamespace(state=self.state, repo=self.repo, plan=self.plan,
                               script=SOURCE / "archive-suite-autonomous.sh", workers=workers, agent=agent)
        sup = sup_module.Supervisor(args, dict(self.env, **env))
        sup.next_upkeep = 10 ** 12
        return sup

    def log(self, path, lines, mtime):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines) + "\n")
        os.utime(path, (mtime, mtime))

    def reading(self, used, elapsed, worker="worker-1", mtime=None):
        reset = int(self.now + (1 - elapsed) * 5 * H)
        self.log(self.state / worker / "last-session.log", [claude_event(used, reset)], mtime or self.now - 5)

    def fake_launch(self, argv, **kwargs):
        if argv[:2] != ["bash", str(SOURCE / "archive-suite-autonomous.sh")]:
            return REAL_POPEN(argv, **kwargs)
        child = Child()
        self.launches.append((self.now, kwargs["env"]["AUTONOMOUS_WORKER_ID"], kwargs["env"]["AUTONOMOUS_AGENT"]))
        return child

    def cycle(self, sup, now):
        self.now = now
        with patch.object(sup_module.time, "time", return_value=now), \
                patch.object(sup_module.subprocess, "Popen", side_effect=self.fake_launch), \
                patch.object(sup, "lane_pause", return_value=0), \
                patch.object(sup, "active", return_value=[]):
            return sup.cycle(now)

    def run_minutes(self, sup, minutes=4):
        for now in range(int(self.now), int(self.now) + minutes * 60 + 1, 30):
            self.cycle(sup, now)

    def test_under_pace_runs_both_workers_staggered(self):
        self.reading(0.20, 0.60)
        sup = self.supervisor()
        self.run_minutes(sup)
        self.assertEqual([w for _, w, _ in self.launches], ["worker-1", "worker-2"])
        self.assertGreaterEqual(self.launches[1][0] - self.launches[0][0], 60)
        log = (self.state / "pace.log").read_text()
        self.assertIn("claude\tgrow\t2\t5h 20% used / 60% elapsed", log)
        snapshot = json.loads((self.state / "supervisor.json").read_text())
        self.assertIn("grow, 2 of 2 slots", snapshot["pace"]["claude"])

    def test_on_or_ahead_of_pace_and_unknown_hold_one_worker(self):
        for used, elapsed in ((0.55, 0.60), (0.70, 0.40), (0.86, 0.95), (None, None)):
            with self.subTest(used=used, elapsed=elapsed):
                self.launches.clear()
                for path in self.state.glob("worker-*/last-session.log"):
                    path.unlink()
                if used is not None:
                    self.reading(used, elapsed)
                sup = self.supervisor()
                self.run_minutes(sup)
                self.assertEqual([w for _, w, _ in self.launches], ["worker-1"])

    def test_vision_ocr_spend_counts_against_the_claude_lane(self):
        # Archive Suite's own log is under pace and the MOST RECENTLY touched;
        # Vision OCR's reading of the same account window says it is ahead.
        reset = int(self.now + 2 * H)
        for archive_mtime, vision_mtime in ((self.now - 900, self.now - 10), (self.now - 1, self.now - 600)):
            with self.subTest(archive_newer=archive_mtime > vision_mtime):
                self.launches.clear()
                (self.state / "pace.log").unlink(missing_ok=True)
                self.log(self.state / "worker-1" / "last-session.log", [claude_event(0.10, reset)], archive_mtime)
                self.log(self.vision, [claude_event(0.80, reset)], vision_mtime)
                sup = self.supervisor()
                self.run_minutes(sup)
                self.assertEqual([w for _, w, _ in self.launches], ["worker-1"])
                self.assertIn("tight", (self.state / "pace.log").read_text())

    def test_tight_drops_to_one_and_steady_does_not_regrow(self):
        sup = self.supervisor()
        self.reading(0.20, 0.60)
        self.assertEqual(sup.lane_cap("claude", self.now), 2)
        self.reading(0.55, 0.60)  # steady: keep two
        self.assertEqual(sup.lane_cap("claude", self.now), 2)
        self.reading(0.80, 0.60)  # tight
        self.assertEqual(sup.lane_cap("claude", self.now), 1)
        self.reading(0.55, 0.60)  # steady again: stays at one
        self.assertEqual(sup.lane_cap("claude", self.now), 1)
        rows = (self.state / "pace.log").read_text().splitlines()
        self.assertEqual([r.split("\t")[2:4] for r in rows], [["grow", "2"], ["tight", "1"]])

    def test_codex_lane_reads_account_rollouts_with_its_weekly_gate(self):
        rollout = self.root / "codex home" / "sessions" / "2026" / "10" / "06" / "rollout-x.jsonl"
        week_reset = int(self.now + 5 * 24 * H)
        self.log(rollout, [codex_line(20.0, int(self.now + 2 * H), 10.0, week_reset)], self.now - 30)
        sup = self.supervisor(agent="codex")
        self.assertEqual(sup.lane_cap("codex", self.now), 2)
        self.log(rollout, [codex_line(20.0, int(self.now + 2 * H), 99.0, week_reset)], self.now - 20)
        self.assertEqual(sup.lane_cap("codex", self.now), 1)

    def test_one_worker_and_explicit_off_never_pace(self):
        sup = self.supervisor(workers=1)
        with patch.object(sup_module.pace, "current_reading", side_effect=AssertionError("read")):
            self.assertEqual(sup.lane_cap("claude", self.now), 1)
        sup = self.supervisor(AUTONOMOUS_PACE="0")
        with patch.object(sup_module.pace, "current_reading", side_effect=AssertionError("read")):
            self.assertEqual(sup.lane_cap("claude", self.now), 2)
        self.assertFalse((self.state / "pace.log").exists())

    def test_unreadable_source_is_unknown_not_a_crash(self):
        sup = self.supervisor()
        for error in (PermissionError("denied"), ZeroDivisionError("window")):
            with patch.object(sup_module.pace, "current_reading", side_effect=error):
                self.assertEqual(sup.lane_cap("claude", self.now), 1)
        self.assertIn("reading failed", (self.state / "pace.log").read_text())
        # A real malformed source, end to end through cycle(): dispatch continues.
        self.log(self.vision, ['{"type":"rate_limit_event","rate_limit_info":"text"}'], self.now)
        (self.state / "pace.log").chmod(0o400)  # an unwritable log never stops dispatch either
        self.addCleanup((self.state / "pace.log").chmod, 0o600)
        sup = self.supervisor()
        self.run_minutes(sup, 1)
        self.assertEqual([w for _, w, _ in self.launches], ["worker-1"])


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]] + remaining, verbosity=2)
