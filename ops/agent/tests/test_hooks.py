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
- [ ] **A.four — waits on a hold that is not ready** (blocked-on: H.wait)

## HOLD QUEUE (owner-gated — the daemon must NOT execute these)

- [ ] **H.ok — owner says yes**
- [ ] **H.two — owner second**
- [ ] **H.perm — a settled judgement** ⛔ OWNER JUDGEMENT
- [x] **H.done — answered**
- [ ] **H.wait — decide once A.one reports** (blocked-on: A.one)

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
        for f in ("next-queue-item.sh", "worker-state.py", "keychain-provider-accounts.sh", "cluster-reach.py",
                  "plan-edit.sh", "plan-edit.py"):
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
        self.env["AGENT_GATE_PGREP"] = "no-such-gate-" + os.path.basename(self.tmp)   # never a real gate

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
        self.assertEqual(list(items), ["A.one", "A.two", "A.three", "A.held", "A.bad", "A.four"])
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


class Cluster(Fixture):
    """W46.engine-cluster: a `(cluster: NAME)` item is offered only while its login answers (cluster-reach.py)."""

    ITEMS = ("- [ ] **C.sub — to submit** (lane: segbench) (uses: light) (cluster: farmshare)\n"
             "- [ ] **C.got — finished** (lane: segbench) (uses: light) (cluster: farmshare)\n"
             "- [ ] **C.run — running** (lane: segbench) (uses: light) (cluster: farmshare)\n"
             "- [ ] **C.dep — not ready** (lane: segbench) (uses: light) (cluster: farmshare) (blocked-on: H.ok)\n")

    def setUp(self):
        super().setUp()
        self.write(".maintenance/AUTONOMOUS_PLAN.md", PLAN.replace("- [ ] **A.four", self.ITEMS + "- [ ] **A.four"))
        self.calls = os.path.join(self.tmp, "ssh-calls")
        self.ssh = os.path.join(self.tmp, "fake-ssh")
        self.fake_ssh(0)
        self.mark("C.got", "finished")
        self.mark("C.run", "submitted")

    def fake_ssh(self, rc):
        with open(self.ssh, "w") as f:
            f.write("#!/bin/sh\necho \"$@\" >> %s\necho rice-01; echo cp1; echo /home/cp1\nexit %d\n"
                    % (shlex.quote(self.calls), rc))
        os.chmod(self.ssh, 0o755)

    def mark(self, tag, state):
        run(["/usr/bin/python3", os.path.join(self.repo, "ops/autonomous/cluster-reach.py"), "mark", tag, state],
            env=self.env)

    def socket(self):
        os.makedirs(os.path.join(self.tmp, ".ssh"), exist_ok=True)
        open(os.path.join(self.tmp, ".ssh", "cm-farmshare"), "w").close()

    def queue(self):
        r = self.hook("queue", CLUSTER_SSH=self.ssh)
        self.assertIn(r.returncode, (0, 3), r.stderr)
        return {d["tag"]: d for d in self.jsonl(r.stdout)}

    def report(self):
        with open(os.path.join(self.repo, ".maintenance", "AUTONOMOUS_PLAN.md")) as f:
            return f.read().split("## Daemon Report")[1]

    def ssh_args(self):
        if not os.path.exists(self.calls):
            return ""
        with open(self.calls) as f:
            return f.read()

    def ssh_calls(self):
        return len(self.ssh_args().splitlines())

    def upkeep(self):
        r = self.hook("upkeep", CLUSTER_SSH=self.ssh)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout

    def test_no_login_skips_the_items_and_upkeep_asks_once_a_day(self):
        before = self.report()
        items = self.queue()
        for tag in ("C.sub", "C.got", "C.run"):
            self.assertEqual(items[tag]["status"], "blocked", items[tag])
            self.assertTrue(items[tag]["reason"].startswith("cluster farmshare not reachable (no SSH master"))
            self.assertNotIn("blocked_on", items[tag])
        self.assertEqual(items["C.dep"]["blocked_on"], ["H.ok"])
        self.assertEqual(items["A.one"]["status"], "ok")
        self.assertEqual(self.ssh_calls(), 0)                # no socket: the network is never touched
        self.assertEqual(self.report(), before)              # the queue hook is read-only on the repo
        self.assertIn("asked the owner", self.upkeep())
        rep = self.report()
        # C.got is finished and C.run submitted (it may have finished: only a login can tell); C.dep is not ready.
        self.assertIn("FarmShare: 1 item ready to submit, 2 submitted or finished to collect", rep)
        line = next(ln for ln in rep.splitlines() if "Cluster login" in ln)
        self.assertNotRegex(line, r"(?i)no decision")        # so the owner is emailed
        self.assertIn("nothing to ask", self.upkeep())
        self.assertEqual(self.report().count("Cluster login"), 1)
        holds = {d["key"]: d for d in self.jsonl(self.hook("holds").stdout)}
        report = [d for k, d in holds.items() if k.startswith("daemon-report:")]
        self.assertIn("Cluster login", report[0]["text"])

    def test_the_ask_is_an_entry_under_the_digest_rule_too(self):
        plan = PLAN.replace("- [ ] **A.four", self.ITEMS + "- [ ] **A.four")
        head, tail = plan.split("## Daemon Report — owner decisions / follow-ups\n")
        older = ("\n### 2026-10-20 — overnight (no decision)\n\n- **[W1.a]** a mention\n- **[W1.b]** another\n\n"
                 "### ✅ 2026-10-06 — walkthrough done (owner): settled.\n")
        self.write(".maintenance/AUTONOMOUS_PLAN.md", head + "## Daemon Report — owner decisions / follow-ups\n" + older)
        self.upkeep()
        holds = {d["key"]: d for d in self.jsonl(self.hook("holds").stdout)}
        report = [d for k, d in holds.items() if k.startswith("daemon-report:")]
        self.assertEqual(len(report), 1, holds)
        self.assertIn("Cluster login", report[0]["text"])

    def test_a_live_login_offers_them_and_the_check_is_cached(self):
        self.socket()
        items = self.queue()
        self.assertEqual([items[t]["status"] for t in ("C.sub", "C.got", "C.run")], ["ok"] * 3)
        self.assertEqual(self.ssh_calls(), 1)                # one round trip for three items
        self.assertIn("ProxyCommand=false", self.ssh_args())
        self.assertIn("BatchMode=yes", self.ssh_args())
        self.queue()
        self.assertEqual(self.ssh_calls(), 1)                # within CACHE_SECONDS: no second round trip
        self.assertIn("nothing to ask", self.upkeep())
        self.assertNotIn("Cluster login", self.report())

    def test_an_unwritable_cache_still_costs_one_round_trip_per_run(self):
        self.socket()
        open(os.path.join(self.state, "cluster-reach"), "w").close()   # a file where the cache dir should be
        self.queue()
        self.assertEqual(self.ssh_calls(), 1)

    def test_a_stalled_login_is_not_reachable(self):
        self.socket()
        self.fake_ssh(255)
        items = self.queue()
        self.assertIn("preflight exited 255", items["C.sub"]["reason"])

    def test_box_holds_the_results_once_box_collect_is_done(self):
        self.mark("C.got", "in-box")
        self.assertEqual(self.queue()["C.got"]["status"], "blocked")    # W46.box-collect not done yet
        self.write("SUITE_TODO_DONE.md", "- [x] **T.old — archived**\n- [x] **W46.box-collect — Box**\n")
        items = self.queue()
        self.assertEqual((items["C.got"]["status"], items["C.sub"]["status"]), ("ok", "blocked"))

    def test_sherlock_items_are_offered_for_preparation_without_any_ssh(self):
        # Owner, 2026-10-22: the engine prepares Sherlock items on the Mac and never contacts Sherlock (its /etc/agents
        # rules), not even with a live master socket; the held item is not offered and nothing asks for a login.
        items = ("- [ ] **S.prep — to prepare** (lane: segbench) (uses: light) (cluster: sherlock)\n"
                 "- [ ] **S.held — ready** (lane: segbench) (uses: light) (cluster: sherlock) (needs: owner)\n")
        self.write(".maintenance/AUTONOMOUS_PLAN.md", PLAN.replace("- [ ] **A.four", items + "- [ ] **A.four"))
        os.makedirs(os.path.join(self.tmp, ".ssh"), exist_ok=True)
        open(os.path.join(self.tmp, ".ssh", "cm-sherlock"), "w").close()
        got = self.queue()
        self.assertEqual(got["S.prep"]["status"], "ok", got["S.prep"])
        self.assertEqual(got["S.held"]["status"], "hold")
        self.assertEqual(self.ssh_calls(), 0)
        r = run(["/usr/bin/python3", os.path.join(self.repo, "ops/autonomous/cluster-reach.py"), "check", "sherlock"],
                env=dict(self.env, CLUSTER_SSH=self.ssh), check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("never contacted", r.stdout + r.stderr)
        self.assertEqual(self.ssh_calls(), 0)
        self.assertIn("nothing to ask", self.upkeep())

    def test_hold_hands_an_item_to_the_owner(self):
        items = "- [ ] **S.prep — to prepare** (lane: segbench) (uses: light) (cluster: sherlock)\n"
        self.write(".maintenance/AUTONOMOUS_PLAN.md", PLAN.replace("- [ ] **A.four", items + "- [ ] **A.four"))
        plan = os.path.join(self.repo, ".maintenance", "AUTONOMOUS_PLAN.md")
        edit = os.path.join(self.repo, "ops/autonomous/plan-edit.sh")
        run(["/bin/bash", edit, plan, "hold", "S.prep", "ready to submit: bash x.sh"], env=self.env)
        self.assertEqual(self.queue()["S.prep"]["status"], "hold")
        with open(plan) as f:
            self.assertIn("(needs: owner) — HELD ", f.read())
        again = run(["/bin/bash", edit, plan, "hold", "S.prep", "twice"], env=self.env, check=False)
        self.assertNotEqual(again.returncode, 0)            # already held: refused, not doubled
        self.assertIn("already held", again.stderr)
        rel = run(["/bin/bash", edit, plan, "release", "S.prep", "results collected"], env=self.env)
        self.assertEqual(rel.returncode, 0)
        self.assertEqual(self.queue()["S.prep"]["status"], "ok")
        with open(plan) as f:
            body = f.read()
        self.assertIn("— RELEASED ", body)
        self.assertNotRegex(body.split("S.prep", 1)[1].split("\n", 1)[0], r"needs:\s*owner")
        bad = run(["/bin/bash", edit, plan, "release", "S.prep", "again"], env=self.env, check=False)
        self.assertIn("not held", bad.stderr)                # nothing to lift
        sneaky = run(["/bin/bash", edit, plan, "hold", "S.prep", "x (blocked-on: Z.never)"], env=self.env, check=False)
        self.assertIn("queue marker", sneaky.stderr)         # a note cannot add a prerequisite
        self.mark("S.prep", "submitted")
        got = self.queue()["S.prep"]
        self.assertEqual(got["status"], "blocked")           # jobs on Sherlock: the owner's session collects
        self.assertIn("owner-started session collects", got["reason"])
        self.assertEqual(self.ssh_calls(), 0)

    def test_hold_refuses_an_item_already_marked_hold(self):
        items = "- [ ] **S.h — held** (lane: segbench) (uses: light) (cluster: sherlock) [hold]\n"
        self.write(".maintenance/AUTONOMOUS_PLAN.md", PLAN.replace("- [ ] **A.four", items + "- [ ] **A.four"))
        plan = os.path.join(self.repo, ".maintenance", "AUTONOMOUS_PLAN.md")
        r = run(["/bin/bash", os.path.join(self.repo, "ops/autonomous/plan-edit.sh"), plan, "hold", "S.h", "n"],
                env=self.env, check=False)
        self.assertIn("already held", r.stderr)

    def test_marker_case_and_unknown_clusters(self):
        items = ("- [ ] **C.cap — capitalised** (lane: segbench) (uses: light) (cluster: FarmShare)\n"
                 "- [ ] **C.typo — misspelt** (lane: segbench) (uses: light) (cluster: sherlok)\n")
        self.write(".maintenance/AUTONOMOUS_PLAN.md", PLAN.replace("- [ ] **A.four", items + "- [ ] **A.four"))
        got = self.queue()
        self.assertEqual((got["C.cap"]["status"], got["C.typo"]["status"]), ("blocked", "blocked"))
        self.upkeep()
        rep = self.report()
        self.assertIn("FarmShare: 1 item ready to submit", rep)
        self.assertNotIn("sherlok", rep.split("Cluster login")[1].split("\n")[0])

    def test_nothing_to_ask_when_no_cluster_item_is_ready(self):
        self.write(".maintenance/AUTONOMOUS_PLAN.md", PLAN.replace(
            "- [ ] **A.four", "- [ ] **C.dep — not ready** (uses: light) (cluster: farmshare) (blocked-on: H.ok)\n"
            "- [ ] **A.four"))
        self.assertIn("nothing to ask", self.upkeep())
        self.assertNotIn("Cluster login", self.report())


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
        self.assertFalse(any("W0.old" in d["text"] for d in items))   # below the walkthrough: settled

    def test_a_hold_whose_own_prerequisite_is_open_is_not_pending(self):
        # R1 review finding 4: A.four waits on H.wait alone, but H.wait itself waits on A.one.
        by = {d["key"]: d for d in self.jsonl(self.hook("holds").stdout)}
        self.assertTrue(by["H.wait"]["permanent"])
        self.write(".maintenance/AUTONOMOUS_PLAN.md", PLAN.replace("- [ ] **A.one", "- [x] **A.one"))
        by = {d["key"]: d for d in self.jsonl(self.hook("holds").stdout)}
        self.assertFalse(by["H.wait"]["permanent"])
        # done only in SUITE_TODO_DONE.md counts too, as next-queue-item.sh counts it
        self.write(".maintenance/AUTONOMOUS_PLAN.md", PLAN.replace("(blocked-on: A.one)", "(blocked-on: T.old)"))
        by = {d["key"]: d for d in self.jsonl(self.hook("holds").stdout)}
        self.assertFalse(by["H.wait"]["permanent"])

    def test_the_daemon_report_is_one_pending_item(self):
        # R1 review finding 3 (decision 3): one item for the report, keyed by its newest entry, so a new entry
        # notifies once and the cutover notifies once.
        items = self.jsonl(self.hook("holds").stdout)
        report = [d for d in items if d["source"] == "Daemon Report"]
        self.assertEqual(len(report), 1)
        d = report[0]
        self.assertTrue(d["key"].startswith("daemon-report:"))
        self.assertFalse(d["permanent"])
        self.assertTrue(d["text"].startswith("Daemon Report: 3 decisions since the last walkthrough; newest: W1.x "
                                             "(2026-10-08) \u2014 first unheaded entry"), d["text"])
        self.assertEqual(d["since"], "2026-10-08")

    def test_keys_are_stable_and_a_new_entry_changes_the_report_key(self):
        first = [d["key"] for d in self.jsonl(self.hook("holds").stdout)]
        self.assertEqual(first, [d["key"] for d in self.jsonl(self.hook("holds").stdout)])
        self.write(".maintenance/AUTONOMOUS_PLAN.md",
                   PLAN.replace("follow-ups\n\n", "follow-ups\n\nW3.z (2026-10-09) \u2014 newest\n\n"))
        items = self.jsonl(self.hook("holds").stdout)
        second = [d["key"] for d in items]
        self.assertEqual(len(second), len(first))
        changed = set(first) ^ set(second)
        self.assertEqual(len(changed), 2)
        self.assertTrue(all(k.startswith("daemon-report:") for k in changed))
        self.assertIn("Daemon Report: 4 decisions", [d for d in items if d["source"] == "Daemon Report"][0]["text"])

    def test_mentions_never_make_or_move_the_item(self):
        # Owner, 2026-10-11: an email only when something needs him. A "no decision" entry is a mention.
        first = [d for d in self.jsonl(self.hook("holds").stdout) if d["source"] == "Daemon Report"]
        self.write(".maintenance/AUTONOMOUS_PLAN.md", PLAN.replace(
            "follow-ups\n\n", "follow-ups\n\nW3.z (2026-10-11), No decision needed yet \u2014 a mention\n\n"))
        items = [d for d in self.jsonl(self.hook("holds").stdout) if d["source"] == "Daemon Report"]
        self.assertEqual([d["key"] for d in items], [d["key"] for d in first])
        self.assertTrue(items[0]["text"].startswith("Daemon Report: 3 decisions since the last walkthrough "
                                                    "(and 1 mention); newest: W1.x"), items[0]["text"])
        only = ("## Daemon Report \u2014 owner decisions / follow-ups\n\n"
                "W3.z \u2014 worth knowing, no decision\n\nW4.q (no decision needed, FYI)\n\n"
                "### \u2705 2026-10-06 \u2014 walkthrough done (owner): everything below is settled.\n")
        self.write(".maintenance/AUTONOMOUS_PLAN.md", PLAN.split("## Daemon Report")[0] + only)
        self.assertEqual([d for d in self.jsonl(self.hook("holds").stdout) if d["source"] == "Daemon Report"], [])

    def test_a_report_entry_for_a_pending_hold_is_that_holds_detail(self):
        # Owner, 2026-10-11: one question emailed as two items, and cut off. The entry becomes the hold's detail.
        ask = "H.ok (abc1234) \u2014 your call: " + "every figure in full. " * 20 + "Options: (1) yes; (2) no."
        perm = "H.two \u2014 asked while its hold still waits on A.one"
        self.write(".maintenance/AUTONOMOUS_PLAN.md", PLAN.replace(
            "follow-ups\n\n", "follow-ups\n\n%s\n\n%s\n\n" % (ask, perm)))
        items = self.jsonl(self.hook("holds").stdout)
        by = {d["key"]: d for d in items}
        self.assertEqual(by["H.ok"]["detail"], ask)
        self.assertLess(len(by["H.ok"]["text"]), len(ask))
        self.assertNotIn("asked", by["H.ok"])
        report = [d for d in items if d["source"] == "Daemon Report"]
        self.assertEqual(len(report), 1)   # H.two's hold is permanent, so its entry still counts
        self.assertTrue(report[0]["text"].startswith("Daemon Report: 4 decisions"), report[0]["text"])
        self.assertTrue(report[0]["detail"].startswith("H.two"))
        self.write(".maintenance/AUTONOMOUS_PLAN.md", PLAN.split("## Daemon Report")[0] +
                   "## Daemon Report \u2014 owner decisions / follow-ups\n\n%s\n\n"
                   "### \u2705 2026-10-06 \u2014 walkthrough done (owner): settled.\n" % ask)
        items = self.jsonl(self.hook("holds").stdout)
        self.assertEqual([d for d in items if d["source"] == "Daemon Report"], [])
        self.assertEqual([d["key"] for d in items if not d["permanent"]], ["H.ok"])

    def test_a_walked_report_has_no_item(self):
        plan = PLAN.replace("## Daemon Report \u2014 owner decisions / follow-ups\n\n",
                            "## Daemon Report \u2014 owner decisions / follow-ups\n\n"
                            "### \u2705 2026-10-09 \u2014 walkthrough done (owner)\n\n")
        self.write(".maintenance/AUTONOMOUS_PLAN.md", plan)
        items = self.jsonl(self.hook("holds").stdout)
        self.assertEqual([d for d in items if d["source"] == "Daemon Report"], [])

    def test_an_answer_recorded_only_in_suite_todo_is_flagged(self):
        # 2026-10-13: W41.seg-cheap-more's approval went into SUITE_TODO.md alone; the gate stayed open.
        self.write("SUITE_TODO.md", "- [ ] **A.two — waits on the owner** (blocked-on: H.ok)\n")
        by = {d["key"]: d for d in self.jsonl(self.hook("holds").stdout)}
        self.assertFalse(by["H.ok"]["text"].startswith("HALF-RECORDED"))
        self.write("SUITE_TODO.md", "- [ ] **A.two — waits on the owner** OWNER APPROVED 2026-10-13\n")
        by = {d["key"]: d for d in self.jsonl(self.hook("holds").stdout)}
        self.assertTrue(by["H.ok"]["text"].startswith("HALF-RECORDED: SUITE_TODO.md no longer blocks A.two"),
                        by["H.ok"]["text"])
        self.assertIn("approve H.ok", by["H.ok"]["detail"])
        self.assertFalse(by["H.two"]["text"].startswith("HALF-RECORDED"))   # A.three has no SUITE_TODO line

    def test_approve_ticks_the_gate_and_unblocks_its_item(self):
        shutil.copy2(os.path.join(AUTONOMOUS, "plan-edit.py"), os.path.join(self.repo, "ops", "autonomous"))
        plan = os.path.join(self.repo, ".maintenance", "AUTONOMOUS_PLAN.md")
        edit = ["/usr/bin/python3", os.path.join(self.repo, "ops", "autonomous", "plan-edit.py"), plan]
        self.assertNotEqual(run(edit + ["approve", "H.done", "again"], check=False).returncode, 0)  # already ticked
        self.assertNotEqual(run(edit + ["approve", "A.two", "x"], check=False).returncode, 0)   # not a gate
        run(edit + ["approve", "H.ok", "walkthrough: yes"])
        with open(plan) as f:
            text = f.read()
        self.assertRegex(text, r"- \[x\] \*\*H\.ok — owner says yes\*\* — OWNER ANSWERED 20\d\d-\d\d-\d\d: "
                               r"walkthrough: yes\n")
        self.assertNotIn("H.ok", [d["key"] for d in self.jsonl(self.hook("holds").stdout)])
        items = {d["tag"]: d for d in self.jsonl(self.hook("queue").stdout)}
        self.assertEqual(items["A.two"]["status"], "ok")

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

    def test_no_verdict_is_red(self):
        # R1 review finding 1 (decision 1): the daemon calls any nonzero gate exit RED.
        for lines, rc in (([], 2), (["half a log"], 137), (["HEALTH GATE: GREEN"], 2)):
            with self.subTest(rc=rc):
                self.fake_gate(lines, rc)
                r = self.hook("gate")
                self.assertEqual(r.returncode, 1)
                self.assertEqual(r.stdout.splitlines()[-2:],
                                 ["HEALTH GATE: RED %s no verdict (exit %d)" % (EM, rc), "HEALTH GATE CLASS: code"])

    def test_the_sandbox_refusal_is_the_one_skip(self):
        self.fake_gate(["The health gate launches apps; request execution outside the Codex sandbox."], 3)
        r = self.hook("gate")
        self.assertEqual(r.returncode, 3)
        self.assertTrue(r.stdout.splitlines()[-1].startswith("HEALTH GATE: SKIPPED %s " % EM), r.stdout)


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
