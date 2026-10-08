#!/usr/bin/python3
"""Tests for the Agent Manager hooks in ops/agent/ (CONTRACT.md section 2 in the manager's repo).

Each test builds a small fixture: a scratch git repo with a plan, SUITE_TODO.md and SUITE_TODO_DONE.md, and a
copy of ops/agent/ beside an ops/autonomous/ that holds the real next-queue-item.sh and worker-state.py from
this checkout plus fakes for the heavy scripts (health-gate.sh, context-budget.sh, compact-plan.sh). Nothing
outside the scratch folder is read or written, and the real gate never runs.

Run: /usr/bin/python3 -m unittest discover -s ops/agent/tests   (from the repo root)
"""
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT = os.path.dirname(HERE)
AUTONOMOUS = os.path.join(os.path.dirname(AGENT), "autonomous")
DAEMON = os.path.join(AUTONOMOUS, "archive-suite-autonomous.sh")
EM = "—"

PLAN = """# plan

RUN STATUS: IN_PROGRESS — fixture

## WORK QUEUE (priority order — do top to bottom)

- [x] **A.done — finished**
- [ ] **A.one — first item [S · ~1 session]** (lane: notes) (uses: light) (effort: high)
- [ ] **A.two — waits on the owner** (lane: reader) (blocked-on: H.ok)
- [ ] **A.three — waits on two** (blocked-on: H.two, A.one)
- [ ] **A.held — held here [hold]** (lane: docs)
- [ ] **A.bad — bad uses** (uses: lots)

## HOLD QUEUE (owner-gated — the daemon must NOT execute these)

- [ ] **H.ok — owner says yes**
- [ ] **H.two — owner second**
- [ ] **H.perm — a settled judgement** ⛔ OWNER JUDGEMENT
- [x] **H.done — answered**

## Session Log

- 2026-10-08 A.done abc — shipped

## Daemon Report — owner decisions / follow-ups

W1.x (2026-10-08) — first unheaded entry
continues on a second line.

W2.y — second entry, undated

### 2026-10-07 — a headed entry

its body paragraph

### ✅ 2026-10-06 — walkthrough done (owner): everything below is settled.

W0.old — a settled entry
"""


def run(cmd, cwd=None, env=None, check=True):
    p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=120)
    if check and p.returncode != 0:
        raise AssertionError("%s failed (%d): %s%s" % (cmd, p.returncode, p.stdout, p.stderr))
    return p


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agent-hooks-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = os.path.join(self.tmp, "repo")
        self.state = os.path.join(self.tmp, "state")
        os.makedirs(os.path.join(self.repo, ".maintenance"))
        os.makedirs(self.state)
        shutil.copytree(AGENT, os.path.join(self.repo, "ops", "agent"),
                        ignore=shutil.ignore_patterns("tests", "__pycache__"))
        auto = os.path.join(self.repo, "ops", "autonomous")
        os.makedirs(auto)
        for f in ("next-queue-item.sh", "worker-state.py", "keychain-provider-accounts.sh"):
            shutil.copy2(os.path.join(AUTONOMOUS, f), auto)
        self.write("ops/autonomous/resume-prompt.txt", "work __REPO__\n")
        self.write(".maintenance/AUTONOMOUS_PLAN.md", PLAN)
        self.write("SUITE_TODO.md", "- [ ] **T.1 — todo**\n- [x] **T.0 — done**\n")
        self.write("SUITE_TODO_DONE.md", "- [x] **T.old — archived**\n")
        self.write(".gitignore", ".maintenance/\n")
        g = ["git", "-C", self.repo]
        run(g + ["init", "-q", "-b", "main"])
        run(g + ["-c", "user.email=t@example.invalid", "-c", "user.name=t", "add", "-A"])
        run(g + ["-c", "user.email=t@example.invalid", "-c", "user.name=t", "commit", "-q", "-m", "fixture"])
        self.env = dict(os.environ, AGENT_REPO=self.repo, AGENT_STATE=self.state, AGENT_PROJECT="fixture",
                        HOME=self.tmp)
        self.env.pop("AUTONOMOUS_PLAN", None)

    def write(self, rel, text, mode=None):
        p = os.path.join(self.repo, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
        if mode:
            os.chmod(p, mode)

    def hook(self, name, **env):
        e = dict(self.env, AGENT_HOOK=name, **env)
        return run(["/bin/bash", "-c", "ops/agent/%s.sh" % name], cwd=self.repo, env=e, check=False)

    def daemon_function(self, *names):
        """The named functions' source, cut from the daemon script as it stands in this checkout."""
        with open(DAEMON) as f:
            lines = f.read().splitlines()
        out = []
        for name in names:
            start = next(i for i, ln in enumerate(lines) if ln.startswith(name + "() {"))
            end = next(i for i in range(start, len(lines)) if lines[i] == "}")
            out += lines[start:end + 1]
        return "\n".join(out)

    def jsonl(self, out):
        return [json.loads(ln) for ln in out.splitlines() if ln.strip()]


class Queue(Fixture):
    def test_items_statuses_and_fields(self):
        r = self.hook("queue")
        self.assertEqual(r.returncode, 0, r.stderr)
        items = {d["tag"]: d for d in self.jsonl(r.stdout)}
        self.assertEqual(list(items), ["A.one", "A.two", "A.three", "A.held", "A.bad"])
        one = items["A.one"]
        self.assertEqual((one["status"], one["lanes"], one["uses"], one["effort"], one["estimate"]),
                         ("ok", ["notes"], ["light"], "high", "~1 session"))
        self.assertEqual((items["A.two"]["status"], items["A.two"]["blocked_on"]), ("blocked", ["H.ok"]))
        self.assertEqual(items["A.three"]["blocked_on"], ["H.two", "A.one"])
        self.assertEqual((items["A.held"]["status"], items["A.held"]["uses"]), ("hold", ["build"]))
        self.assertEqual(items["A.three"]["lanes"], ["suite"])          # no lane tag means suite
        self.assertEqual(items["A.bad"]["status"], "blocked")
        self.assertIn("unknown uses value: lots", items["A.bad"]["reason"])
        for d in items.values():
            self.assertTrue(set(d) <= {"tag", "status", "reason", "text", "lanes", "uses", "effort", "estimate",
                                       "blocked_on", "attempts", "sessions_since_progress"}, d)

    def test_sessions_since_progress_from_the_state(self):
        os.makedirs(os.path.join(self.state, "item-progress"))
        with open(os.path.join(self.state, "item-progress", "A.one"), "w") as f:
            f.write("2\n")
        items = {d["tag"]: d for d in self.jsonl(self.hook("queue").stdout)}
        self.assertEqual(items["A.one"]["sessions_since_progress"], 2)
        self.assertNotIn("sessions_since_progress", items["A.two"])

    def test_all_blocked_exits_3_and_empty_exits_2(self):
        plan = PLAN.replace("- [ ] **A.one", "- [x] **A.one").replace(" (blocked-on: H.ok)", " (blocked-on: H.two)")
        self.write(".maintenance/AUTONOMOUS_PLAN.md", plan)
        r = self.hook("queue")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertFalse(any(d["status"] == "ok" for d in self.jsonl(r.stdout)))
        drained = "RUN STATUS: IN_PROGRESS\n\n## WORK QUEUE\n\n- [x] **A.one — done**\n\n## HOLD QUEUE\n"
        self.write(".maintenance/AUTONOMOUS_PLAN.md", drained)
        r = self.hook("queue")
        self.assertEqual((r.returncode, r.stdout), (2, ""))

    def test_a_bad_plan_is_a_fault(self):
        os.remove(os.path.join(self.repo, ".maintenance", "AUTONOMOUS_PLAN.md"))
        r = self.hook("queue")
        self.assertEqual(r.returncode, 1)
        self.assertIn("no plan", r.stderr)


class Holds(Fixture):
    def test_permanence_and_sources(self):
        r = self.hook("holds")
        self.assertEqual(r.returncode, 0, r.stderr)
        items = self.jsonl(r.stdout)
        by = {d["key"]: d for d in items}
        self.assertFalse(by["H.ok"]["permanent"])       # A.two waits on it alone
        self.assertTrue(by["H.two"]["permanent"])       # A.three also waits on A.one
        self.assertTrue(by["H.perm"]["permanent"])
        self.assertNotIn("H.done", by)
        self.assertEqual((by["A.held"]["source"], by["A.held"]["permanent"]), ("WORK QUEUE", True))
        report = [d for d in items if d["source"] == "Daemon Report"]
        self.assertEqual(len(report), 3)
        self.assertTrue(all(d["permanent"] is False for d in report))
        self.assertTrue(report[0]["key"].startswith("report-2026-10-08-"))
        self.assertEqual(report[0]["since"], "2026-10-08")
        self.assertTrue(report[1]["key"].startswith("report-undated-"))
        self.assertNotIn("since", report[1])
        self.assertEqual(report[2]["text"], "2026-10-07 — a headed entry")
        self.assertFalse(any("W0.old" in d["text"] for d in items))   # below the walkthrough: settled

    def test_keys_are_stable_and_follow_the_entry(self):
        first = [d["key"] for d in self.jsonl(self.hook("holds").stdout)]
        self.assertEqual(first, [d["key"] for d in self.jsonl(self.hook("holds").stdout)])
        # A new entry prepended above the others adds one key and changes none.
        self.write(".maintenance/AUTONOMOUS_PLAN.md",
                   PLAN.replace("follow-ups\n\n", "follow-ups\n\nW3.z (2026-10-09) — newest\n\n"))
        second = [d["key"] for d in self.jsonl(self.hook("holds").stdout)]
        self.assertEqual(len(second), len(first) + 1)
        self.assertTrue(set(first) <= set(second))

    def test_unblocking_the_other_prerequisite_makes_a_hold_pending(self):
        self.write(".maintenance/AUTONOMOUS_PLAN.md", PLAN.replace("- [ ] **A.one", "- [x] **A.one"))
        by = {d["key"]: d for d in self.jsonl(self.hook("holds").stdout)}
        self.assertFalse(by["H.two"]["permanent"])


class FingerprintAndCompleted(Fixture):
    def test_the_fingerprint_hashes_to_the_daemons(self):
        r = self.hook("fingerprint")
        self.assertEqual(r.returncode, 0)
        mine = hashlib.sha256(r.stdout.encode()).hexdigest()
        script = 'REPO="$1"; PLAN="$2"\n%s\nwork_fingerprint\n' % self.daemon_function("work_fingerprint")
        theirs = run(["/bin/bash", "-c", script, "x", self.repo,
                      os.path.join(self.repo, ".maintenance", "AUTONOMOUS_PLAN.md")]).stdout.strip()
        self.assertEqual(mine, theirs)
        self.assertIn("## WORK QUEUE", r.stdout)
        self.assertNotIn("Daemon Report", r.stdout)

    def test_the_fingerprint_moves_with_the_queue_not_the_log(self):
        a = self.hook("fingerprint").stdout
        self.write(".maintenance/AUTONOMOUS_PLAN.md", PLAN.replace("- 2026-10-08 A.done", "- 2026-10-09 more"))
        self.assertEqual(a, self.hook("fingerprint").stdout)
        self.write(".maintenance/AUTONOMOUS_PLAN.md", PLAN.replace("- [ ] **A.one", "- [x] **A.one"))
        self.assertNotEqual(a, self.hook("fingerprint").stdout)

    def test_completed_matches_the_daemon(self):
        r = self.hook("completed")
        self.assertEqual((r.returncode, r.stdout), (0, "3\n"))   # A.done, T.0, T.old
        script = 'REPO="$1"; PLAN="$2"\n%s\ncompleted_items\n' % self.daemon_function("_tracker_ticks",
                                                                                      "completed_items")
        theirs = run(["/bin/bash", "-c", script, "x", self.repo,
                      os.path.join(self.repo, ".maintenance", "AUTONOMOUS_PLAN.md")]).stdout
        self.assertEqual(r.stdout, theirs)


class Gate(Fixture):
    def fake_gate(self, lines, rc):
        body = "".join("echo %s\n" % shlex.quote(ln) for ln in lines)
        self.write("ops/autonomous/health-gate.sh", "#!/bin/bash\n%sexit %d\n" % (body, rc), 0o755)

    def test_green(self):
        self.fake_gate(["step ok", "HEALTH GATE: GREEN (all builds) %s NOT VERIFIED: gui-vm" % EM], 0)
        r = self.hook("gate")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.splitlines()[-1], "HEALTH GATE: GREEN")
        self.assertIn("step ok", r.stdout)

    def test_red_code_doc_and_mixed(self):
        for steps, klass in (("build-reader unit-notes", "code"), ("context-budget", "doc"),
                             ("context-budget build-reader", "mixed")):
            with self.subTest(steps=steps):
                self.fake_gate(["HEALTH GATE: RED %s %s" % (EM, steps), "--- failing output ---", "boom"], 1)
                r = self.hook("gate")
                self.assertEqual(r.returncode, 1)
                self.assertEqual(r.stdout.splitlines()[-2:],
                                 ["HEALTH GATE: RED %s %s" % (EM, ", ".join(steps.split())),
                                  "HEALTH GATE CLASS: %s" % klass])

    def test_no_verdict_is_inconclusive(self):
        for lines, rc in (([], 3), (["half a log"], 137), (["HEALTH GATE: GREEN"], 2)):
            with self.subTest(rc=rc):
                self.fake_gate(lines, rc)
                r = self.hook("gate")
                self.assertEqual(r.returncode, 3)
                self.assertFalse(r.stdout.splitlines()[-1].startswith("HEALTH GATE:"))


class Pregate(Fixture):
    def fake_budget(self, lines):
        body = "".join("echo %s\n" % shlex.quote(ln) for ln in lines)
        self.write("ops/autonomous/context-budget.sh", "#!/bin/bash\n%sexit 0\n" % body, 0o755)

    def test_only_the_total_dispatches(self):
        self.fake_budget(["context-budget: OVER ArchiveNotes/CLAUDE.md 80000 77000",
                          "context-budget: TOTAL OK 400000 500000"])
        self.assertEqual(self.hook("pregate").returncode, 0)
        self.fake_budget(["context-budget: OVER .maintenance/AUTONOMOUS_PLAN.md 130000 125000",
                          "context-budget: OVER My Notes.md 9 8",
                          "context-budget: TOTAL OVER 510000 500000"])
        r = self.hook("pregate")
        self.assertEqual(r.returncode, 10)
        self.assertIn("510000 of 500000 bytes", r.stdout)
        self.assertIn(".maintenance/AUTONOMOUS_PLAN.md, My Notes.md", r.stdout)

    def test_no_budget_script_fails_open(self):
        self.assertEqual(self.hook("pregate").returncode, 0)


class Precheck(Fixture):
    def setUp(self):
        super().setUp()
        self.claude = os.path.join(self.tmp, "claude")
        with open(self.claude, "w") as f:
            f.write("#!/bin/sh\n")
        os.chmod(self.claude, 0o755)

    def test_ok_and_each_refusal(self):
        self.assertEqual(self.hook("precheck", AGENT_CLAUDE=self.claude).returncode, 0)
        r = self.hook("precheck", AGENT_CLAUDE=os.path.join(self.tmp, "none"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("claude CLI not executable", r.stdout)
        with open(os.path.join(self.state, "agent"), "w") as f:
            f.write("codex\n")
        r = self.hook("precheck", AGENT_CLAUDE=self.claude, AGENT_CODEX=os.path.join(self.tmp, "none"))
        self.assertIn("codex CLI not executable", r.stdout)
        os.remove(os.path.join(self.state, "agent"))
        self.write(".maintenance/AUTONOMOUS_PLAN.md", PLAN.replace("RUN STATUS: IN_PROGRESS", "RUN STATUS: COMPLETE"))
        r = self.hook("precheck", AGENT_CLAUDE=self.claude)
        self.assertEqual(r.returncode, 1)
        self.assertIn("COMPLETE", r.stdout)
        self.write(".maintenance/AUTONOMOUS_PLAN.md", PLAN.replace("fixture", "fixture, not the COMPLETE path"))
        self.assertEqual(self.hook("precheck", AGENT_CLAUDE=self.claude).returncode, 0)
        os.remove(os.path.join(self.repo, ".maintenance", "AUTONOMOUS_PLAN.md"))
        r = self.hook("precheck", AGENT_CLAUDE=self.claude)
        self.assertIn("plan missing", r.stdout)


class Status(Fixture):
    def test_counts_and_health(self):
        r = self.hook("status")
        self.assertEqual(r.returncode, 0, r.stderr)
        d = json.loads(r.stdout)
        self.assertEqual((d["done_24h"], d["left"], d["finished"]), (1, 1, 2))
        self.assertTrue(d["health"].startswith("Not checked yet"))
        self.assertIn("Keychain not set up", d["note"])
        head = run(["git", "-C", self.repo, "rev-parse", "HEAD"]).stdout.strip()
        with open(os.path.join(self.state, "last-gate"), "w") as f:
            f.write(head + "\n")
        open(os.path.join(self.state, "keychain-partition-fixed"), "w").close()
        d = json.loads(self.hook("status").stdout)
        self.assertEqual(d["health"], "Build and tests passed, on the current code")
        self.assertNotIn("note", d)
        with open(os.path.join(self.state, "last-gate.log"), "w") as f:
            f.write("HEALTH GATE: RED %s context-budget\n" % EM)
        d = json.loads(self.hook("status").stdout)
        self.assertIn("a document is over its size limit", d["health"])
        with open(os.path.join(self.state, "last-gate.log"), "w") as f:
            f.write("HEALTH GATE: RED %s build-reader context-budget\n" % EM)
        d = json.loads(self.hook("status").stdout)
        self.assertEqual(d["health"], "The last full check FAILED: build-reader; the build or tests are broken")


class Upkeep(Fixture):
    def test_compactor_abort_fails_upkeep_and_checks_never_do(self):
        self.write("ops/autonomous/check-tracker-sync.sh", "#!/bin/bash\necho drift\nexit 1\n", 0o755)
        self.write("ops/autonomous/check-todo-stubs.sh", "#!/bin/bash\nexit 0\n", 0o755)
        self.write("ops/autonomous/compact-plan.sh", "#!/bin/bash\necho no-op\nexit 0\n", 0o755)
        r = self.hook("upkeep")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("drift", r.stdout)
        self.write("ops/autonomous/compact-plan.sh", "#!/bin/bash\necho abort\nexit 1\n", 0o755)
        r = self.hook("upkeep")
        self.assertEqual(r.returncode, 1)
        self.assertIn("ABORTED", r.stdout)


class NoOtherProject(unittest.TestCase):
    def test_no_hook_names_another_project(self):
        for f in sorted(os.listdir(AGENT)):
            p = os.path.join(AGENT, f)
            if os.path.isfile(p):
                with open(p) as fh:
                    text = fh.read().lower()
                for name in ("vision" + sep + "ocr" for sep in (" ", "-", "")):
                    self.assertNotIn(name, text, f)


if __name__ == "__main__":
    unittest.main()
