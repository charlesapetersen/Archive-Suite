#!/usr/bin/python3
"""Tests for ops/agent/measure-review.py (W46.measure-review) and the RECURRING gate it opens.

A scratch git repo stands in for the project, with result commits made on demand; the plan is a scratch file. The
real next-queue-item.sh proves the standing item is blocked while the gate is unticked and offered once it is.
Nothing outside the scratch folder is written.

Run: /usr/bin/python3 -m unittest discover -s ops/agent/tests -p 'test_measure_review.py'   (from the repo root)
"""
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT = os.path.dirname(HERE)
AUTONOMOUS = os.path.join(os.path.dirname(AGENT), "autonomous")
spec = importlib.util.spec_from_file_location("measure_review", os.path.join(AGENT, "measure-review.py"))
mr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mr)

NOW = 1793300000.0
DAY = 86400

PLAN = """# plan

RUN STATUS: IN_PROGRESS — fixture

## WORK QUEUE (priority order — do top to bottom)

- [ ] **W46.measure-review — the standing review** (lane: segbench) (uses: light) (effort: max) (blocked-on: W46.measure-review-due)
- [ ] **W1.a — waits on a typo** (lane: ops) (blocked-on: W1.nosuch)
- [ ] **W1.b — one half of a cycle** (lane: ops) (blocked-on: W1.c)
- [ ] **W1.c — the other half** (lane: ops) (blocked-on: W1.b)
- [ ] **W1.d — waits on a done item and a gate** (lane: ops) (blocked-on: W1.done, W1.gate)

## HOLD QUEUE (owner-gated)

- [ ] **W1.gate — OWNER GATE: a question** (blocked-on: W1.d)

## RECURRING (machine-ticked gates of standing items: plan-edit.sh due|rearm, never the owner's)

- [ ] **W46.measure-review-due** — rearmed 2026-10-30: filed by the measurement audit

## Session Log
"""
TODO = """# todo

- [ ] **`W46.measure-review` — the standing review** (lane: segbench) (uses: light) (effort: max) (blocked-on: W46.measure-review-due)
- [ ] **`W1.a` — waits on a typo** (lane: ops) (blocked-on: W1.nosuch)
- [ ] **`W1.b` — one half of a cycle** (lane: ops) (blocked-on: W1.c)
- [ ] **`W1.c` — the other half** (lane: ops) (blocked-on: W1.b)
- [ ] **`W1.d` — waits on a done item and a gate** (lane: ops) (blocked-on: W1.done, W1.gate)
"""
DONE = "- [x] **W1.done — finished** · §x\n  <!-- /W1.done -->\n"


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="measure-review-")
        self.repo = os.path.join(self.tmp, "repo")
        self.state = os.path.join(self.tmp, "state")
        os.makedirs(os.path.join(self.repo, ".maintenance"))
        self.plan = os.path.join(self.repo, ".maintenance", "AUTONOMOUS_PLAN.md")
        with open(self.plan, "w") as f:
            f.write(PLAN)
        for name, text in (("SUITE_TODO.md", TODO), ("SUITE_TODO_DONE.md", DONE)):
            with open(os.path.join(self.repo, name), "w") as f:
                f.write(text)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        self.git("add", "SUITE_TODO.md", "SUITE_TODO_DONE.md")
        self.git("commit", "-q", "-m", "base")
        self.base = self.git("rev-parse", "HEAD").strip()
        self.n = 0

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def git(self, *a):
        return subprocess.run(["git", "-C", self.repo, *a], check=True, capture_output=True, text=True).stdout

    def result(self, name="r.md", card=True, path="ArchiveProcessor/segbench-results"):
        self.n += 1
        d = os.path.join(self.repo, path)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, name), "w") as f:
            f.write("# result %d\n\n%s" % (self.n, "## Measurement card\n\n- Truth: owner\n" if card else "figures\n"))
        self.git("add", "-A", path)
        self.git("commit", "-q", "-m", "result %d" % self.n)

    def other(self):
        self.n += 1
        with open(os.path.join(self.repo, "code.txt"), "w") as f:
            f.write(str(self.n))
        self.git("add", "code.txt")
        self.git("commit", "-q", "-m", "code %d" % self.n)

    def run_mr(self, *args, now=NOW):
        return mr.main([*args, "--repo", self.repo, "--state", self.state, "--plan", self.plan, "--now", str(now)])

    def seed(self, at=NOW):
        os.makedirs(os.path.join(self.state, "measure-review"), exist_ok=True)
        with open(os.path.join(self.state, "measure-review", "last.json"), "w") as f:
            json.dump({"commit": self.base, "at": at}, f)

    def ticked(self):
        return "- [x] **W46.measure-review-due**" in open(self.plan).read()

    def resolver(self):
        r = subprocess.run(["bash", os.path.join(AUTONOMOUS, "next-queue-item.sh"), self.repo], capture_output=True,
                           text=True, env=dict(os.environ, AUTONOMOUS_PLAN=self.plan, AUTONOMOUS_IGNORE_CLAIMS="1"))
        return r.stdout


class Cadence(Base):
    def test_not_due_below_the_count_and_inside_the_week(self):
        self.seed()
        for _ in range(mr.MIN_RESULTS - 1):
            self.result()
        self.other()
        self.assertEqual(self.run_mr("upkeep", now=NOW + DAY), 0)
        self.assertFalse(self.ticked())
        self.assertIn("blocked:W46.measure-review-due\tW46.measure-review", self.resolver())

    def test_due_at_the_count_opens_the_standing_item(self):
        self.seed()
        for _ in range(mr.MIN_RESULTS):
            self.result()
        self.run_mr("upkeep", now=NOW + DAY)
        self.assertTrue(self.ticked())
        self.assertIn("ok\tW46.measure-review", self.resolver())

    def test_due_after_a_week_with_one_result(self):
        self.seed()
        self.result()
        self.run_mr("upkeep", now=NOW + 6 * DAY)
        self.assertFalse(self.ticked())
        self.run_mr("upkeep", now=NOW + 7 * DAY)
        self.assertTrue(self.ticked())

    def test_a_quiet_week_opens_nothing(self):
        self.seed()
        self.other()
        self.run_mr("upkeep", now=NOW + 30 * DAY)
        self.assertFalse(self.ticked())

    def test_only_result_paths_count(self):
        self.seed()
        for _ in range(mr.MIN_RESULTS):
            self.other()
        self.run_mr("upkeep", now=NOW + DAY)
        self.assertFalse(self.ticked())

    def test_done_moves_the_window_and_a_ticked_gate_is_left_alone(self):
        self.seed()
        for _ in range(mr.MIN_RESULTS):
            self.result()
        self.run_mr("upkeep", now=NOW + DAY)
        before = open(self.plan).read()
        self.run_mr("upkeep", now=NOW + 2 * DAY)          # still ticked: no second edit
        self.assertEqual(open(self.plan).read(), before)
        self.run_mr("done", "HEAD", now=NOW + 2 * DAY)
        mr.plan_edit(mr.Env(type("A", (), {"repo": self.repo, "state": self.state, "plan": self.plan, "now": NOW})()),
                     "rearm", [mr.GATE, "review done"])
        self.run_mr("upkeep", now=NOW + 3 * DAY)
        self.assertFalse(self.ticked())

    def test_first_run_seeds_with_the_audit_commit(self):
        # The seed commit is not in this scratch repo, so git fails: the error surfaces instead of a silent tick.
        with self.assertRaises(RuntimeError):
            self.run_mr("upkeep")
        d = json.load(open(os.path.join(self.state, "measure-review", "last.json")))
        self.assertEqual(d["commit"], mr.SEED)
        self.assertFalse(self.ticked())


class Checks(Base):
    def test_cards_lists_reports_without_a_card(self):
        self.seed()
        self.result("good.md", card=True)
        self.result("bad.md", card=False)
        self.result("data.json", card=False)
        self.assertEqual(mr.cards(mr.Env(type("A", (), {"repo": self.repo, "state": self.state, "plan": self.plan,
                                                        "now": NOW})())),
                         ["ArchiveProcessor/segbench-results/bad.md"])

    def test_deps_finds_the_typo_and_the_cycle_not_the_done_item_or_the_gate(self):
        env = mr.Env(type("A", (), {"repo": self.repo, "state": self.state, "plan": self.plan, "now": NOW})())
        problems = mr.deps(env)
        self.assertIn("W1.a waits on W1.nosuch, which has no checkbox anywhere", problems)
        self.assertTrue(any(p.startswith("cycle: ") and "W1.b" in p and "W1.c" in p for p in problems))
        self.assertTrue(any(p.startswith("cycle: ") and "W1.d" in p and "W1.gate" in p for p in problems))
        self.assertFalse(any("W1.done" in p for p in problems))
        self.assertEqual(len([p for p in problems if p.startswith("cycle")]), 2)


if __name__ == "__main__":
    unittest.main()
