#!/usr/bin/env python3
"""Prove answered-gate archival preserves decisions and live resolver state, on scratch only."""
import fcntl
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent.parent
PASSED = 0


def check(value, label):
    global PASSED
    assert value, label
    PASSED += 1
    print("PASS " + label, flush=True)


with tempfile.TemporaryDirectory(prefix="plan archive with space ") as scratch:
    repo = Path(scratch)
    plan = repo / "plan.md"
    archive = repo / "AUTONOMOUS_HOLD_QUEUE_ARCHIVE.md"
    (repo / "SUITE_TODO.md").write_text("")
    env = dict(os.environ, AUTONOMOUS_PLAN=str(plan), AUTONOMOUS_STATE=str(repo / "state"),
               AUTONOMOUS_IGNORE_CLAIMS="1", AUTONOMOUS_SUITE_TODO=str(repo / "SUITE_TODO.md"),
               AUTONOMOUS_SUITE_TODO_DONE=str(repo / "done.md"))
    prefix = ("RUN STATUS: IN_PROGRESS\n## WORK QUEUE\n"
              "- [ ] **W1.ready — build** (blocked-on: W1.owner-ok)\n"
              "- [ ] **W1.wait — wait** (blocked-on: W1.unanswered)\n## HOLD QUEUE\n")
    answered = ("- [x] **W1.owner-ok — OWNER GATE: which route?** — OWNER ANSWERED: "
                + "route café, cap $6.80; never send truth text. " * 12 + "\n"
                "  A contiguous continuation keeps its constraints.\n")
    open_gate = "- [ ] **W1.unanswered — OWNER GATE: needs the owner**\n  Never archive this question.\n"
    ambiguous = ("- [x] **W1.ambiguous — gate** — OWNER ANSWERED: " + "keep details. " * 25
                 + "\n\n  A separated paragraph may belong to this answer.\n\n")
    fenced = ("```md\n- [x] **W1.fake — quoted** — OWNER ANSWERED: " + "quoted only. " * 25
              + "\n```\n")
    prose = "### Historical context\nThis is not an answered gate.\n\n"
    suffix = "## RECURRING\n- [x] **W1.due**\n## Session Log\nkeep log\n## Daemon Report\nkeep question\n"
    original = prefix + answered + "\n" + open_gate + "\n" + ambiguous + prose + fenced + suffix
    plan.write_text(original)
    command = ["bash", str(HERE / "plan-edit.sh"), str(plan), "archive-answered"]

    def invoke():
        return subprocess.run(command, env=env, capture_output=True, text=True)

    def resolve():
        return subprocess.run(["bash", str(HERE / "next-queue-item.sh"), str(repo)],
                              env=env, capture_output=True, text=True, check=True).stdout

    before_queue = resolve()
    # Failed archival must not remove any answer from the plan.
    archive.mkdir()
    result = invoke()
    check(result.returncode == 2 and plan.read_text() == original,
          "archive write failure leaves every plan byte intact")
    archive.rmdir()
    # A second process must wait for the very same stable lock as other plan edits.
    with plan.with_name(plan.name + ".lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        child = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            child.communicate(timeout=0.2)
            raise AssertionError("archive action did not wait for plan lock")
        except subprocess.TimeoutExpired:
            check(plan.read_text() == original and not archive.exists(),
                  "archival waits for the shared plan lock before writing either file")
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)
        _, stderr = child.communicate(timeout=10)
        check(child.returncode == 0, "locked archive action succeeds: " + stderr)

    after = plan.read_text()
    check(answered in archive.read_text(), "full Unicode answer and contiguous constraints preserved verbatim")
    check(after.startswith(prefix) and after.endswith(suffix), "all sections outside HOLD stay byte-identical")
    check(open_gate in after and ambiguous in after and prose in after and fenced in after,
          "open gates, ambiguous continuations, narrative and fenced examples stay unchanged")
    check("- [x] **W1.owner-ok** — ANSWER ARCHIVED:" in after
          and "AUTONOMOUS_HOLD_QUEUE_ARCHIVE.md#W1.owner-ok" in after
          and "before dependent work" in after, "completed tag remains with a binding archive pointer")
    check(before_queue == resolve() and "ok\tW1.ready\t" in before_queue
          and "blocked:W1.unanswered\tW1.wait\t" in before_queue, "resolver readiness and owner dependencies are unchanged")
    archive_before = archive.read_bytes()
    check(invoke().returncode == 0 and plan.read_text() == after and archive.read_bytes() == archive_before,
          "second archival is an exact no-op")
    check(subprocess.run(command + ["extra"], env=env, capture_output=True).returncode == 2
          and plan.read_text() == after, "unexpected arguments refuse without changing plan")

print(f"prove-plan-archive: {PASSED} passed")
