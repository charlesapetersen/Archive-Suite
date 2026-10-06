#!/usr/bin/env python3
"""W35.live: scratch-only proof of measure-workers.py. Fixture state and a scratch git repo; nothing installed."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

TOOL = Path(__file__).resolve().parent.parent / "measure-workers.py"
PASS = 0


def check(value, label, detail=""):
    global PASS
    if not value:
        print("FAIL " + label + ("\n" + detail if detail else ""))
        sys.exit(1)
    PASS += 1
    print("PASS " + label, flush=True)


HEAD = "kind\tstart\tend\tminutes\teffort\trc\tfirst_pct\tfirst_reset\twindow_peaks\tcut\tcost_usd\tturns\tended\n"

with tempfile.TemporaryDirectory(prefix="measure workers [scratch] ") as scratch:
    root = Path(scratch)
    state = root / "state"
    (state / "worker-1").mkdir(parents=True)
    (state / "worker-2").mkdir()
    (state / "heavy").mkdir()
    # Before the split: one window cut at 100%. After: two workers share the 21:00 window (peak 80%).
    (state / "worker-1" / "usage-window.tsv").write_text(HEAD +
        "session\t2026-10-01 10:00\t2026-10-01 11:00\t60\thigh\t0\t0\t15:00\t0% (resets 15:00), 60% (resets 15:00)\t\t\t1\tcompleted\n"
        "session\t2026-10-01 11:00\t2026-10-01 11:30\t30\thigh\t1\t60\t15:00\t100% (resets 15:00)\tcut\t\t0\tfailed\n"
        "wait\t2026-10-01 11:32\t2026-10-01 15:01\t209\t-\t-\t100\t15:00\t\tcut\t\t\t\n"
        "session\t2026-10-02 19:00\t2026-10-02 20:00\t60\thigh\t0\t10\t21:00\t10% (resets 21:00), 70% (resets 21:00)\t\t\t1\tcompleted\n")
    (state / "usage-window.tsv").symlink_to(state / "worker-1" / "usage-window.tsv")  # root alias: counted once
    (state / "worker-2" / "usage-window.tsv").write_text(HEAD +
        "session\t2026-10-02 19:01\t2026-10-02 20:30\t89\thigh\t0\t11\t21:00\t11% (resets 21:00), 80% (resets 21:00)\t\t\t1\tcompleted\n"
        # A 23:00 session whose 02:00 reset is on the NEXT day.
        "session\t2026-10-02 23:00\t2026-10-02 23:30\t30\thigh\t0\t0\t02:00\t5% (resets 02:00)\t\t\t1\tcompleted\n"
        # Malformed rows (review finds): skipped whole, never a crash or a half-counted window.
        "wait\t2026-10-02 23:40\t2026-10-02 23:50\t10\t-\t-\t-\t02:00\t\tcut\t\t\t\n"
        "session\t2026-10-02 23:41\t2026-10-02 23:50\t9\thigh\t0\t0\t25:99\t99% (resets 24:00)\t\t\t1\tcompleted\n"
        "short\trow\n")
    (state / "pace.log").write_text("2026-10-02 16:00:00\tclaude\tgrow\t2\tfive-hour 0%\n"
                                    "2026-10-02 20:00:00\tclaude\ttight\t1\tfive-hour 80%\n")
    (state / "heavy" / "waits.log").write_text("2026-10-01 10:30:00\t30.0\tbash test-smoke.sh\n"
                                               "2026-10-02 19:30:00\t120.0\tbash health-gate.sh\n"
                                               "2026-10-02 19:40:00\t60.0\txcodebuild test\n"
                                               "2026-10-02 19:45:00\t1.2.3\tbad\n"
                                               "2026-10-02 19:46:00\n")
    (state / "worker-2" / "last-session.log").write_text(
        '{"type":"user","message":{"content":[{"type":"tool_result","content":"CONFLICT (content): Merge conflict in SUITE_TODO.md"}]}}\n'
        '{"type":"assistant","message":{"content":[{"type":"text","text":"no CONFLICT (content): Merge conflict in here"}]}}\n')

    repo = root / "repo with space"
    remote = root / "remote.git"
    env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
    git = lambda *a, **k: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True, text=True,
                                         env=dict(env, **k.get("env", {})))
    subprocess.run(["git", "init", "-q", "--bare", str(remote)], check=True, env=env)
    subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True, env=env)
    git("config", "user.email", "t@example.invalid"); git("config", "user.name", "t")
    done = repo / "SUITE_TODO_DONE.md"
    text = "# Done\n"
    for stamp, tag in [("2026-10-01 12:00:00", "W1.a"), ("2026-10-02 19:30:00", "W1.b"),
                       ("2026-10-02 20:10:00", "W1.c"), ("2026-10-02 20:20:00", "W1.b")]:
        text += "- [x] **%s — thing** SHIPPED\n" % tag
        done.write_text(text)
        git("add", "-A")
        git("commit", "-q", "-m", tag, env={"GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp})
    git("remote", "add", "origin", str(remote)); git("push", "-q", "origin", "main")

    def run(*extra):
        return subprocess.run([sys.executable, str(TOOL), "--state", str(state), "--repo", str(repo),
                               "--since", "2026-10-01", "--now", "2026-10-03 00:00", *extra],
                              capture_output=True, text=True, env=env)

    r = run()
    out = r.stdout
    check(r.returncode == 0, "report runs on fixture state", r.stderr)
    check("split: 2026-10-02 16:00 (first pace.log line)" in out, "split defaults to the first pace.log line", out)
    check("reset 2026-10-01 15:00  before peak 100%  cut   2 session(s)" in out,
          "a cut window keeps its peak and cut mark, wait row folded in", out)
    check("reset 2026-10-02 21:00  after  peak  80%        2 session(s)" in out,
          "two workers' ledgers merge into one window; the root alias is not double-counted", out)
    check("reset 2026-10-03 02:00  after  peak   5%        1 session(s)" in out and "99%" not in out, "an HH:MM reset earlier than its session start rolls to the next day", out)
    check("before 1 window(s), mean peak 100%, 1 reached the cut" in out and
          "after  2 window(s), mean peak 42%, 0 reached the cut" in out, "before/after window summaries", out)
    check("2026-10-02   3  W1.b W1.c W1.b" in out or "2026-10-02   3  W1.b W1.b W1.c" in out
          or "2026-10-02   3  W1.c W1.b W1.b" in out, "items counted per day", out)
    check("items finished more than once: W1.b (" in out, "an item finished twice is a collision", out)
    check("worker-2/last-session.log ×1" in out, "a git conflict in a tool result counts; a quote in prose does not", out)
    check("heavy-lock waits before 1, total 0.5 min" in out and "heavy-lock waits after  2, total 3.0 min, longest 2.0 min" in out,
          "heavy-lock waits split before/after", out)
    check("claude 2 slot(s): 240 min" in out and "claude 1 slot(s): 240 min" in out, "time at each slot count", out)
    r = run("--split", "2026-10-03 00:00")
    wins = r.stdout.split("== Items")[0].split("== Five")[1]
    check("after " not in wins and "reset 2026-10-03 02:00  spans" in wins and "before 2 window(s), mean peak 90%" in wins,
          "--split overrides the default; a straddling window is listed but kept out of both means", r.stdout)
    (state / "pace.log").unlink()
    check("no multi-worker run yet" in run().stdout, "no pace.log reports no multi-worker run")
    before = sorted(p.stat().st_mtime_ns for p in state.rglob("*") if p.is_file())
    run()
    check(before == sorted(p.stat().st_mtime_ns for p in state.rglob("*") if p.is_file()), "the report writes nothing")

print("measure-workers proof: %d passed, 0 failed" % PASS)
