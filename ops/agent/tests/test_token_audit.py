#!/usr/bin/python3
"""Tests for ops/agent/token-audit.py (W40.token-pass) and the plan's RECURRING gate it opens.

A synthetic projects folder holds transcripts with known figures; the ledger, the plan and a small repo are
scratch files. The real next-queue-item.sh, check-tracker-sync.sh and check-todo-stubs.sh run against the
fixture plan to prove the standing fix item's filing. Nothing outside the scratch folder is written.

Run: /usr/bin/python3 -m unittest discover -s ops/agent/tests -p 'test_token_audit.py'   (from the repo root)
"""
import datetime
import glob
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import warnings

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT = os.path.dirname(HERE)
AUTONOMOUS = os.path.join(os.path.dirname(AGENT), "autonomous")
spec = importlib.util.spec_from_file_location("token_audit", os.path.join(AGENT, "token-audit.py"))
ta = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ta)

NOW = 1793300000.0     # 2026-10-29
DAY = 86400
EM = "—"

PLAN = """# plan

RUN STATUS: IN_PROGRESS — fixture

## WORK QUEUE (priority order — do top to bottom)

- [ ] **W1.a — ordinary work** (lane: ops)
- [ ] **W40.token-fix — the standing token fix** (lane: ops) (uses: light) (blocked-on: W40.token-fix-due)

## HOLD QUEUE (owner-gated — the daemon must NOT execute these)

- [ ] **W9.gate — OWNER GATE for something**

## Session Log

## Daemon Report
"""
TODO = """# todo

- [ ] **`W1.a` — ordinary work** (lane: ops)
- [ ] **`W40.token-fix` — the standing token fix** (lane: ops) (uses: light) (blocked-on: W40.token-fix-due)
"""


def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def call(mid, t, inp, cr, cc, out, blocks=()):
    return {"type": "assistant", "timestamp": iso(t), "message": {"id": mid, "role": "assistant", "content": list(blocks),
            "usage": {"input_tokens": inp, "cache_read_input_tokens": cr, "cache_creation_input_tokens": cc,
                      "output_tokens": out}}}


def use(uid, name, **inp):
    return {"type": "tool_use", "id": uid, "name": name, "input": inp}


def result(t, uid, text):
    return {"type": "user", "timestamp": iso(t), "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": uid, "content": text}]}}


def write(path, records):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")


class Fixture(unittest.TestCase):
    def setUp(self):
        warnings.simplefilter("ignore", ResourceWarning)
        self.tmp = tempfile.mkdtemp(prefix="token-audit-")
        self.repo = os.path.join(self.tmp, "repo")
        self.state = os.path.join(self.tmp, "state")
        self.projects = os.path.join(self.tmp, "projects")
        os.makedirs(os.path.join(self.repo, ".maintenance"))
        os.makedirs(self.state)
        self.plan = os.path.join(self.repo, ".maintenance", "AUTONOMOUS_PLAN.md")
        open(self.plan, "w").write(PLAN)
        open(os.path.join(self.repo, "SUITE_TODO.md"), "w").write(TODO)
        open(os.path.join(self.repo, "SUITE_TODO_DONE.md"), "w").write("# done\n")
        for rel, n in (("CLAUDE.md", 1000), ("ops/autonomous/resume-prompt.txt", 500), ("ArchiveProcessor/CLAUDE.md", 300),
                       ("ArchiveReader/CLAUDE.md", 300), ("ArchiveNotes/CLAUDE.md", 300), ("big.txt", 50000)):
            os.makedirs(os.path.dirname(os.path.join(self.repo, rel)) or self.repo, exist_ok=True)
            open(os.path.join(self.repo, rel), "w").write("x" * n)
        self.umbrella = os.path.join(self.tmp, "umbrella.md")
        open(self.umbrella, "w").write("u" * 100)
        os.environ["TOKEN_AUDIT_UMBRELLA"] = self.umbrella
        self.folder = os.path.join(self.projects, ta.encode(self.repo))
        self.ledger = os.path.join(self.state, "ledger.jsonl")

    def tearDown(self):
        os.environ.pop("TOKEN_AUDIT_UMBRELLA", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def args(self, *extra):
        return ["--repo", self.repo, "--state", self.state, "--plan", self.plan, "--projects", self.projects,
                "--project", "P", "--now", str(NOW)] + list(extra)

    def ledger_rows(self, rows):
        with open(self.ledger, "a") as f:
            for r in rows:
                f.write(json.dumps(dict({"project": "P"}, **r)) + "\n")

    def engine_session(self, sid, item, start, first, later, reads=(), big=0, sub=None):
        """One engine transcript: a first call of context FIRST (split over two records, as Claude Code writes
        them), then calls of context LATER; reads whole of each path in READS; one Bash result of BIG chars."""
        recs = [{"type": "queue-operation", "timestamp": iso(start),
                 "content": "ENGINE ASSIGNMENT (Agent Manager engine)\nYour item: %s - title" % item},
                call(sid + "-m0", start + 1, 2, first - 1002, 1000, 50),
                call(sid + "-m0", start + 1, 2, first - 1002, 1000, 70)]
        t = start + 2
        for i, ctx in enumerate(later):
            blocks = []
            if i < len(reads):
                blocks = [use("%s-r%d" % (sid, i), "Read", file_path=os.path.join(self.repo, reads[i]))]
            elif big and i == len(reads):
                blocks = [use(sid + "-b", "Bash", command="cat big.txt")]
            recs.append(call("%s-m%d" % (sid, i + 1), t, 1, ctx - 1, 0, 10, blocks))
            if i < len(reads):
                recs.append(result(t + 0.5, "%s-r%d" % (sid, i), "x" * 100))
            elif big and i == len(reads):
                recs.append(result(t + 0.5, sid + "-b", "x" * big))
            t += 1
        write(os.path.join(self.folder, sid + ".jsonl"), recs)
        if sub is not None:
            write(os.path.join(self.folder, sid, "subagents", "agent-1.jsonl"),
                  [{"type": "user", "timestamp": iso(start + 3), "message": {"role": "user", "content": "brief"}},
                   call("sub-" + sid, start + 4, sub, 0, 0, 0)])


class FiguresTest(Fixture):
    def build(self):
        s = NOW - 2 * DAY
        # A: first call 50,000; later 60,000 and 70,000; reads a.md twice; one 30,000-char result; subagent 5,000.
        self.engine_session("A", "W1.a", s, 50000, [60000, 70000, 80000], reads=["CLAUDE.md", "CLAUDE.md"], big=30000, sub=5000)
        # B: first call 54,000; later 64,000; a second session of W1.a.
        self.engine_session("B", "W1.a", s + 3600, 54000, [64000])
        # C: first call 58,000; its item is not finished.
        self.engine_session("C", "W2.b", s + 7200, 58000, [58000])
        # An interactive session, not counted.
        write(os.path.join(self.folder, "I.jsonl"), [
            {"type": "user", "timestamp": iso(s), "message": {"role": "user", "content": "hello"}},
            call("I-m0", s + 1, 9, 900000, 0, 1)])
        # An engine session from before the window.
        self.engine_session("OLD", "W1.a", NOW - 30 * DAY, 99000, [99000])
        os.utime(os.path.join(self.folder, "OLD.jsonl"), (NOW - 30 * DAY, NOW - 30 * DAY))
        self.ledger_rows([
            {"item": "W1.a", "started": s - 5, "at": s + 100, "item_finished": False},
            {"item": "W1.a", "started": s + 3595, "at": s + 3700, "item_finished": True},
            {"item": "W2.b", "started": s + 7195, "at": s + 7300, "item_finished": False},
            {"item": "W1.a", "started": s - 1, "at": s, "item_finished": True, "project": "Other"}])

    def test_known_figures(self):
        self.build()
        self.assertEqual(ta.main(["run", "--no-open"] + self.args()), 0)
        rec = json.loads(open(os.path.join(self.state, "token-audit", "passes.jsonl")).read().splitlines()[-1])
        self.assertEqual(rec["sessions"], 3)                       # A, B, C; not I, not OLD
        self.assertEqual(rec["calls"], 4 + 2 + 2)                  # the split first record counts once
        self.assertEqual(rec["first_call_median"], 54000)
        self.assertEqual(rec["first_call_min"], 50000)
        self.assertEqual(rec["context_per_call"], (50000 + 60000 + 70000 + 80000 + 54000 + 64000 + 58000 + 58000) // 8)
        # W1.a finished: A + B, context + output (A's first call keeps the fuller output, 70), plus A's subagent.
        a = 50000 + 70 + 60010 + 70010 + 80010 + 5000
        b = 54000 + 70 + 64010
        self.assertEqual(rec["items_finished"], 1)
        self.assertEqual(rec["tokens_per_item_median"], a + b)
        self.assertEqual(rec["breaches"], [])
        self.assertFalse(rec["opened"])
        rep = open(os.path.join(self.state, "token-audit", "latest.md")).read()
        self.assertIn("| W1.a | CLAUDE.md | 2 |", rep)                 # read whole twice in one session
        self.assertIn("| CLAUDE.md | 2 | 1 | 1,000 |", rep)             # size on disk
        self.assertIn("| `cat big.txt` | 1 | 30,000 |", rep)
        self.assertNotIn("99,000", rep)

    def test_probes_placeholders_media_and_persisted_results(self):
        self.build()
        s = NOW - 2 * DAY
        # A probe: an ENGINE ASSIGNMENT prompt with no ledger row. Not measured (it would be the smallest first call).
        self.engine_session("PR", "W40.probe", s + 9000, 1000, [1000])
        with open(os.path.join(self.folder, "C.jsonl"), "a") as f:
            for r in (
                # A zero-usage placeholder record is not a call, even carrying tool uses.
                call("C-syn", s + 7300, 0, 0, 0, 0, [use("C-png", "Read", file_path="/x/shots/a.png"),
                                                      use("C-diff", "Bash", command="git diff")]),
                result(s + 7301, "C-png", ""),
                dict(result(s + 7302, "C-diff", "p" * 2000), toolUseResult={"persistedOutputSize": 600000}),
            ):
                f.write(json.dumps(r) + "\n")
        ta.main(["run", "--no-open"] + self.args())
        rec = json.loads(open(os.path.join(self.state, "token-audit", "passes.jsonl")).read().splitlines()[-1])
        self.assertEqual((rec["sessions"], rec["calls"], rec["first_call_min"]), (3, 8, 50000))
        rep = open(os.path.join(self.state, "token-audit", "latest.md")).read()
        self.assertIn("| `git diff [persisted]` | 1 | 600,000 |", rep)
        self.assertIn("left out (1 in the window)", rep)
        self.assertNotIn("a.png", rep)
        self.assertIn("1 engine-prompt transcripts with no ledger row", rep)

    def test_partial_reads_are_not_whole(self):
        s = NOW - DAY
        self.ledger_rows([{"item": "W1.a", "started": s - 5, "at": s + 100}])
        write(os.path.join(self.folder, "P.jsonl"), [
            {"type": "queue-operation", "timestamp": iso(s), "content": "ENGINE ASSIGNMENT\nYour item: W1.a - t"},
            call("m0", s + 1, 1, 100, 0, 1, [use("u1", "Read", file_path=os.path.join(self.repo, "CLAUDE.md"), offset=5, limit=9)]),
            result(s + 2, "u1", "x" * 10)])
        ta.main(["run", "--no-open"] + self.args())
        self.assertIn("| none | | | |", open(os.path.join(self.state, "token-audit", "latest.md")).read())

    def test_worktree_paths_name_the_repo_file(self):
        self.assertEqual(ta.norm("/Users/cp1/Claude/.worktrees/archive-suite/suite-wt-1-2/CLAUDE.md", "/r"), "CLAUDE.md")
        self.assertEqual(ta.norm("/Users/cp1/Claude/suite-wt-1-2/a/b.py", "/r"), "a/b.py")
        self.assertEqual(ta.command_key("Bash", {"command": "cd /Users/cp1/Claude/.worktrees/archive-suite/suite-wt-9/x && ls\nmore"}, "/r"),
                         "cd <worktree>/x && ls")


class VerdictTest(Fixture):
    def setUp(self):
        super().setUp()
        self.min_compare = ta.MIN_COMPARE
        ta.MIN_COMPARE = 1                                      # one session is enough to compare, here

    def tearDown(self):
        ta.MIN_COMPARE = self.min_compare
        super().tearDown()

    def last(self, *lines, **fig):
        os.makedirs(os.path.join(self.state, "token-audit"), exist_ok=True)
        with open(os.path.join(self.state, "token-audit", "passes.jsonl"), "w") as f:
            for line in lines:
                f.write(line + "\n")
            f.write(json.dumps(dict({"at": NOW - 8 * DAY, "date": "2026-10-21", "sessions": 25}, **fig)) + "\n")

    def session(self, first, later, start=NOW - DAY, sid="A"):
        self.engine_session(sid, "W1.a", start, first, later)
        os.utime(os.path.join(self.folder, sid + ".jsonl"), (start + 200, start + 200))   # written during its run
        self.ledger_rows([{"item": "W1.a", "started": start - 5, "at": start + 100}])

    def test_too_few_sessions_compare_no_trend(self):
        ta.MIN_COMPARE = 2
        self.session(90000, [90000])
        self.last(first_call_median=50000, context_per_call=50000)
        self.assertEqual(self.run_pass()["breaches"], [])
        self.assertIn("recorded but not compared", open(os.path.join(self.state, "token-audit", "latest.md")).read())

    def test_a_regression_nobody_was_handed_stays_out_of_the_baseline(self):
        self.last(first_call_median=50000, context_per_call=50000)
        self.session(60000, [60000])
        rec = self.run_pass("--no-open")                        # found, not handed on: not a baseline
        self.assertEqual(len(rec["breaches"]), 2)
        self.assertFalse(rec["baseline"])
        shutil.rmtree(self.folder)
        self.session(60000, [60000], start=NOW + DAY, sid="B")
        a = self.args()
        a[a.index("--now") + 1] = str(NOW + 2 * DAY)
        ta.main(["run"] + a)
        rec = json.loads(open(os.path.join(self.state, "token-audit", "passes.jsonl")).read().splitlines()[-1])
        self.assertEqual(len(rec["breaches"]), 2)               # still compared with 50,000, not 60,000
        self.assertTrue(rec["opened"])
        self.assertTrue(rec["baseline"])

    def test_a_thin_pass_is_not_a_baseline(self):
        ta.MIN_COMPARE = 2
        self.last(first_call_median=50000, context_per_call=50000, sessions=25)
        with open(os.path.join(self.state, "token-audit", "passes.jsonl"), "a") as f:
            f.write(json.dumps({"at": NOW - 4 * DAY, "date": "2026-10-25", "sessions": 1, "first_call_median": 40000,
                                "context_per_call": 40000, "baseline": True}) + "\n")
        self.session(52000, [52000])
        self.session(52000, [52000], start=NOW - DAY + 600, sid="B")
        self.assertEqual(self.run_pass()["breaches"], [])       # +4% on the 25-session pass, not +30% on the thin one

    def test_a_corrupt_line_is_skipped_not_the_history(self):
        self.last("{not json", first_call_median=50000, context_per_call=50000)
        self.session(60000, [60000])
        self.assertEqual(len(self.run_pass()["breaches"]), 2)

    def test_a_gate_left_ticked_is_reported(self):
        self.session(50000, [50000])
        self.last(first_call_median=50000, context_per_call=50000)
        subprocess.run(["/bin/bash", os.path.join(AUTONOMOUS, "plan-edit.sh"), self.plan, "due", "W40.token-fix-due", "x"], check=True)
        rec = self.run_pass()
        self.assertTrue(rec["stale_gate"])
        self.assertIn("did not re-arm it", open(os.path.join(self.state, "token-audit", "latest.md")).read())

    def run_pass(self, *extra):
        ta.main(["run"] + list(extra) + self.args())
        return json.loads(open(os.path.join(self.state, "token-audit", "passes.jsonl")).read().splitlines()[-1])

    def test_ten_percent_worse_opens_the_fix(self):
        self.session(55000, [60000])
        self.last(first_call_median=50000, context_per_call=60000)    # 55,000 is +10%; 57,500 is -4%
        rec = self.run_pass()
        self.assertEqual(len(rec["breaches"]), 1)
        self.assertIn("first-call context", rec["breaches"][0])
        self.assertTrue(rec["opened"])
        plan = open(self.plan).read()
        self.assertIn("## RECURRING", plan)
        self.assertRegex(plan, r"- \[x\] \*\*W40\.token-fix-due\*\* — DUE \d{4}-\d\d-\d\d: token pass")

    def test_nine_percent_worse_does_not(self):
        self.session(54500, [54500])
        self.last(first_call_median=50000, context_per_call=50000)
        rec = self.run_pass()
        self.assertEqual(rec["breaches"], [])
        self.assertNotIn("RECURRING", open(self.plan).read())

    def test_a_file_over_its_budget_opens_the_fix(self):
        open(os.path.join(self.repo, "ArchiveNotes/CLAUDE.md"), "w").write("x" * 24001)
        rec = self.run_pass()
        self.assertEqual(rec["breaches"], ["ArchiveNotes/CLAUDE.md is 24001 B, over its budget of 24000 B"])
        self.assertTrue(rec["opened"])

    def test_over_the_20k_target_alone_does_not(self):
        open(os.path.join(self.repo, "ArchiveNotes/CLAUDE.md"), "w").write("x" * 22000)
        self.assertEqual(self.run_pass()["breaches"], [])

    def test_budgets_come_from_context_budget(self):
        b = {rel: budget for rel, _, _, budget, _ in ta.budgets(ta.Env(ta.argparse.Namespace(
            repo=self.repo, state=self.state, ledger=None, plan=None, projects=self.projects, project="P", now=NOW)))}
        self.assertEqual(b["ArchiveProcessor/CLAUDE.md"], 24000)
        self.assertEqual(b["CLAUDE.md"], 40000)
        self.assertIsNotNone(b["ops/autonomous/resume-prompt.txt"])
        self.assertEqual(b["~/Claude/CLAUDE.md"], 12000)

    def test_no_open_reports_only(self):
        open(os.path.join(self.repo, "CLAUDE.md"), "w").write("x" * 40001)
        rec = self.run_pass("--no-open")
        self.assertFalse(rec["opened"])
        self.assertEqual(open(self.plan).read(), PLAN)


class CadenceTest(Fixture):
    def sessions_in_ledger(self, n, after):
        self.ledger_rows([{"item": "W1.a", "started": after + 10 + i, "at": after + 20 + i} for i in range(n)])

    def upkeep(self, now=NOW):
        a = self.args()
        a[a.index("--now") + 1] = str(now)
        return ta.main(["upkeep"] + a)

    def passes(self):
        p = os.path.join(self.state, "token-audit", "passes.jsonl")
        return open(p).read().splitlines() if os.path.exists(p) else []

    def test_too_few_sessions_costs_nothing(self):
        self.sessions_in_ledger(19, NOW - DAY)
        self.upkeep()
        self.assertEqual(self.passes(), [])
        self.assertEqual(glob.glob(os.path.join(self.state, "token-audit", "pass-*")), [])

    def test_twenty_sessions_runs_once_a_week(self):
        self.sessions_in_ledger(20, NOW - DAY)
        self.upkeep()
        self.assertEqual(len(self.passes()), 1)
        self.assertEqual(len(glob.glob(os.path.join(self.state, "token-audit", "pass-*"))), 1)
        self.sessions_in_ledger(40, NOW)
        self.upkeep(NOW + 6 * DAY)                                  # not due yet, however many sessions
        self.assertEqual(len(self.passes()), 1)
        self.upkeep(NOW + 7 * DAY + 60)
        self.assertEqual(len(self.passes()), 2)

    def test_a_manual_run_counts_as_the_last_pass(self):
        self.sessions_in_ledger(25, NOW - 2 * DAY)
        ta.main(["run", "--no-open"] + self.args())
        self.sessions_in_ledger(1, NOW)
        self.upkeep(NOW + 3600)
        self.assertEqual(len(self.passes()), 1)                 # not due: the manual run was an hour ago

    def test_codex_sessions_do_not_count_toward_the_threshold(self):
        self.ledger_rows([{"item": "W1.a", "agent": "codex", "started": NOW - DAY + i, "at": NOW - DAY + i + 5} for i in range(30)])
        self.upkeep()
        self.assertEqual(self.passes(), [])

    def test_sessions_are_counted_since_the_last_pass(self):
        self.sessions_in_ledger(20, NOW - DAY)
        self.upkeep()
        self.sessions_in_ledger(5, NOW)
        self.upkeep(NOW + 8 * DAY)
        self.assertEqual(len(self.passes()), 1)

    def test_todays_stamp_is_exclusive(self):
        self.sessions_in_ledger(20, NOW - 10 * DAY)
        os.makedirs(os.path.join(self.state, "token-audit"))
        old = os.path.join(self.state, "token-audit", "pass-" + datetime.datetime.fromtimestamp(NOW).strftime("%Y-%m-%d"))
        open(old, "w").close()
        os.utime(old, (NOW - 8 * DAY, NOW - 8 * DAY))           # due, but another run holds today's name
        self.upkeep()
        self.assertEqual(self.passes(), [])

    def test_a_failed_pass_removes_its_stamp(self):
        self.sessions_in_ledger(20, NOW - DAY)
        orig = ta.run_pass
        ta.run_pass = lambda env: (_ for _ in ()).throw(RuntimeError("boom"))
        try:
            with self.assertRaises(RuntimeError):
                self.upkeep()
        finally:
            ta.run_pass = orig
        self.assertEqual(glob.glob(os.path.join(self.state, "token-audit", "pass-*")), [])


class GateFilingTest(Fixture):
    """The standing fix item: blocked until the pass ticks its gate, runnable after, blocked again on rearm; the
    two tracker checks pass in every state, and the owner is never asked about the gate."""

    def sh(self, script, *args):
        env = dict(os.environ, AUTONOMOUS_PLAN=self.plan, AUTONOMOUS_TODO=os.path.join(self.repo, "SUITE_TODO.md"),
                   AUTONOMOUS_TODO_DONE=os.path.join(self.repo, "SUITE_TODO_DONE.md"),
                   AUTONOMOUS_SUITE_TODO_DONE=os.path.join(self.repo, "SUITE_TODO_DONE.md"), AUTONOMOUS_IGNORE_CLAIMS="1")
        return subprocess.run(["/bin/bash", os.path.join(AUTONOMOUS, script)] + list(args), env=env,
                              capture_output=True, text=True, timeout=60)

    def status(self):
        p = self.sh("next-queue-item.sh", self.repo)
        rows = {l.split("\t")[1]: l.split("\t")[0] for l in p.stdout.splitlines() if l.count("\t") >= 2}
        return rows["W40.token-fix"]

    def edit(self, *args):
        p = subprocess.run(["/bin/bash", os.path.join(AUTONOMOUS, "plan-edit.sh"), self.plan] + list(args),
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)

    def checks_pass(self):
        for script in ("check-tracker-sync.sh", "check-todo-stubs.sh"):
            p = self.sh(script)
            self.assertEqual(p.returncode, 0, script + ": " + p.stdout + p.stderr)

    def test_due_and_rearm(self):
        self.assertTrue(self.status().startswith("blocked:"))      # the gate does not exist yet: unmet
        self.checks_pass()
        self.edit("due", "W40.token-fix-due", "token pass 2026-10-29: 1 finding")
        self.assertEqual(self.status(), "ok")
        self.checks_pass()
        plan = open(self.plan).read()
        self.assertLess(plan.index("## HOLD QUEUE"), plan.index("## RECURRING"))
        self.assertLess(plan.index("## RECURRING"), plan.index("## Session Log"))
        self.assertIn("\n\n## Session Log", plan)                  # the next section keeps its blank line
        self.edit("rearm", "W40.token-fix-due", "fixed in abc1234")
        self.assertTrue(self.status().startswith("blocked:"))
        self.checks_pass()
        self.edit("due", "W40.token-fix-due", "token pass 2026-11-05")
        self.assertEqual(self.status(), "ok")
        self.assertEqual(open(self.plan).read().count("W40.token-fix-due**"), 1)   # one gate line, rewritten
        # A dated record of a finished fix in the DONE file changes none of it.
        with open(os.path.join(self.repo, "SUITE_TODO_DONE.md"), "a") as f:
            f.write("- [x] **W40.token-fix-20261105 — token fix** · §W40\n  <!-- /W40.token-fix-20261105 -->\n")
        self.assertEqual(self.status(), "ok")
        self.checks_pass()

    def test_the_gate_is_not_an_owner_hold(self):
        self.edit("due", "W40.token-fix-due", "token pass")
        self.edit("rearm", "W40.token-fix-due", "done")
        env = dict(os.environ, AGENT_REPO=self.repo, AUTONOMOUS_PLAN=self.plan, AGENT_STATE=self.state)
        p = subprocess.run(["/usr/bin/python3", os.path.join(AGENT, "hooks.py"), "holds"], env=env,
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        keys = [json.loads(l)["key"] for l in p.stdout.splitlines()]
        self.assertEqual(keys, ["W9.gate"])

    def test_rearm_files_an_open_gate_and_due_reopens_a_complete_run(self):
        self.edit("rearm", "W40.token-fix-due", "filed")
        self.assertIn("- [ ] **W40.token-fix-due** — rearmed", open(self.plan).read())
        self.assertTrue(self.status().startswith("blocked:"))
        bad = subprocess.run(["/bin/bash", os.path.join(AUTONOMOUS, "plan-edit.sh"), self.plan, "due", "W40.token-fix-due",
                              "x (blocked-on: y)"], capture_output=True, text=True)
        self.assertNotEqual(bad.returncode, 0)                     # a note may not smuggle a queue marker
        open(self.plan, "w").write(PLAN.replace("RUN STATUS: IN_PROGRESS — fixture", "RUN STATUS: COMPLETE"))
        self.edit("due", "W40.token-fix-due", "token pass")
        self.assertIn("RUN STATUS: IN_PROGRESS", open(self.plan).read())

    def test_a_standing_item_cannot_be_completed(self):
        self.edit("rearm", "W40.token-fix-due", "filed")
        p = subprocess.run(["/bin/bash", os.path.join(AUTONOMOUS, "plan-edit.sh"), self.plan, "complete", "W40.token-fix",
                            "abc1234", "done"], capture_output=True, text=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("standing item", p.stderr)
        self.edit("complete", "W1.a", "abc1234", "done")         # an ordinary item still completes

    def test_compactor_knows_the_section(self):
        self.assertIn("|RECURRING|", open(os.path.join(AUTONOMOUS, "compact-plan.sh")).read())


if __name__ == "__main__":
    unittest.main()
