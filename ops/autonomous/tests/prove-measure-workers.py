#!/usr/bin/env python3
"""W35.live: scratch-only proof of measure-workers.py. Fixture state and a scratch git repo; nothing installed."""
import datetime as dt
import os
from pathlib import Path
import re
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


def when_local(text):
    """Epoch of a local time, the way the tool reads rollout resets."""
    return dt.datetime.strptime(text, "%Y-%m-%d %H:%M:%S").timestamp()


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
                                               "2026-10-02 22:00:00\t6.0\tbash health-gate.sh\n"
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
    check("heavy-lock waits before 1, total 0.5 min" in out and "heavy-lock waits after  3, total 3.1 min, longest 2.0 min" in out,
          "heavy-lock waits split before/after", out)
    # W35.three-workers: by sessions running when each wait began (the 22:00 one fell between sessions).
    check("waits with 0 session(s) running (gate/upkeep): 1, total 0.1 min" in out
          and "waits with 1 session(s) running: 1, total 0.5 min" in out
          and "waits with 2 session(s) running: 2, total 3.0 min, longest 2.0 min" in out,
          "heavy-lock waits split by sessions running", out)
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

    # ----- W35.unspent ---------------------------------------------------------------------------------------
    ustate, vstate, codex = root / "u state", root / "vision state", root / "codex home"
    for d in (ustate, vstate, codex / "sessions/2026/10/01"):
        d.mkdir(parents=True)
    # 2026-10-02: 00-08 no reading · 08-13 fully spent (cut) · 13-14 no reading · 14-19 peak 56% · 19-24 no reading.
    (ustate / "usage-window.tsv").write_text(HEAD +
        "session\t2026-10-02 08:00\t2026-10-02 09:00\t60\thigh\t0\t40\t13:00\t40% (resets 13:00), 93% (resets 13:00)\t\t\t1\tcompleted\n"
        "session\t2026-10-02 09:00\t2026-10-02 09:30\t30\thigh\t1\t93\t13:00\t93% (resets 13:00)\tcut\t\t0\tfailed\n"
        "session\t2026-10-02 14:00\t2026-10-02 15:00\t60\thigh\t0\t10\t19:00\t10% (resets 19:00), 56% (resets 19:00)\t\t\t1\tcompleted\n"
        # Ran under Codex: its reset is the Codex window's, so it is Codex's, not Claude's.
        "session\t2026-09-30 22:01\t2026-09-30 23:00\t59\thigh\t0\t5\t03:00\t90% (resets 03:00)\t\t\t1\tcompleted\n"
        # Also Codex's, and cut there: the rollouts never carry the cut, so it comes over from the ledger.
        "session\t2026-10-01 15:30\t2026-10-01 16:00\t30\thigh\t1\t40\t20:00\t50% (resets 20:00)\tcut\t\t0\tfailed\n"
        # A session with no reading at all is no reading, not 0% or 100%.
        "session\t2026-10-02 20:00\t2026-10-02 21:00\t60\thigh\t0\t\t\t\t\t\t1\tcompleted\n")
    # Vision OCR's ledger: same Claude account, an extra `item` column.
    (vstate / "usage-window.tsv").write_text(
        "kind\tstart\tend\tminutes\titem\teffort\trc\tfirst_pct\tfirst_reset\twindow_peaks\tcut\n"
        "session\t2026-09-30 10:00\t2026-09-30 11:00\t60\tc46\tmedium\t0\t2\t15:00\t20% (resets 15:00)\t\n")
    ep = lambda s: int(when_local(s))
    rl = lambda lid, pct, reset, wpct, wreset: (
        '{"type":"event_msg","payload":{"rate_limits":{"limit_id":"%s","limit_name":null,"primary":{"used_percent":%s,'
        '"window_minutes":300,"resets_at":%d},"secondary":{"used_percent":%s,"window_minutes":10080,"resets_at":%d},'
        '"credits":null}}}\n' % (lid, pct, reset, wpct, wreset))
    (codex / "sessions/2026/10/01/rollout-a.jsonl").write_text(
        # One window, resets a second apart (as the CLI writes them): peak 70%.
        rl("codex", "30.0", ep("2026-10-01 03:00:30"), "40.0", ep("2026-10-05 00:00:10"))
        + rl("codex", "70.0", ep("2026-10-01 03:00:31"), "45.0", ep("2026-10-05 00:00:11"))
        + rl("codex", "50.0", ep("2026-10-01 20:00:00"), "45.0", ep("2026-10-05 00:00:11"))
        + rl("codex", "50.0", 99999999999999999999, "45.0", ep("2026-10-05 00:00:11"))  # absurd: skipped
        + rl("premium", "100.0", ep("2026-10-01 09:00:00"), "100.0", ep("2026-10-05 00:00:00"))
        # Still open at --now: neither unspent nor "no reading".
        + rl("codex", "10.0", ep("2026-10-03 02:00:00"), "46.0", ep("2026-10-05 00:00:12")))
    (codex / "sessions/2026/10/01/rollout-empty.jsonl").write_text("")
    (ustate / "last-session.log").write_text(
        '{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.5,"resetsAt":%d},'
        '"seven_day":{"utilization":0.37,"resetsAt":%d}}}}\n' % (ep("2026-10-02 19:00:00"), ep("2026-10-08 06:00:00")))

    def unspent(*extra, state_dir=ustate):
        return subprocess.run([sys.executable, str(TOOL), "--state", str(state_dir), "--unspent",
                               "--codex-home", str(codex), "--now", "2026-10-03 00:00", *extra],
                              capture_output=True, text=True, env=env)

    before = sorted((str(p), p.stat().st_mtime_ns) for d in (ustate, vstate, codex) for p in d.rglob("*"))
    r = unspent("--also-state", str(vstate))
    check(before == sorted((str(p), p.stat().st_mtime_ns) for d in (ustate, vstate, codex) for p in d.rglob("*")),
          "--unspent writes nothing")
    claude = next((l for l in r.stdout.splitlines() if l.startswith("Claude")), "")
    codex_l = next((l for l in r.stdout.splitlines() if l.startswith("Codex")), "")
    check(r.returncode == 0 and claude and codex_l, "--unspent prints a Claude and a Codex line", r.stdout + r.stderr)
    # 24 h: (0 x 5 h + 44 x 5 h) / 10 h = 22%; 14 h had no reading.
    check("24 h 22% (14 h no reading)" in claude,
          "a cut window counts as fully spent, a 56%-peak one as 44% unspent, gaps as no reading", claude)
    # 7 days adds Vision OCR's 20% window (80% unspent): (0 + 220 + 400) / 15 h = 41%; the Codex-reset row is out.
    check("7 days 41% (153 h no reading)" in claude, "Vision OCR's ledger counts; a Codex window is not Claude's", claude)
    check("weekly 37% used (resets Thu 8 Oct)" in claude, "a Claude seven_day reading is the weekly limit", claude)
    # (5 h x 30% + 5 h x 0% for the cut one) / 10 h = 15%; the absurd timestamp neither crashes nor counts.
    check("24 h no reading" in codex_l and "7 days 15% (155 h no reading)" in codex_l,
          "Codex: jittered resets are one window at its peak, a ledger cut carries over, the open window is out",
          codex_l)
    check("weekly 46% used (resets Mon 5 Oct)" in codex_l, "Codex weekly from the newest secondary reading", codex_l)
    (vstate / "usage-window.tsv").unlink()
    (ustate / "usage-window.tsv").write_text(HEAD)
    (ustate / "last-session.log").unlink()
    import shutil
    shutil.rmtree(codex / "sessions")
    r = unspent("--also-state", str(vstate))
    check(r.stdout.count("24 h no reading · 7 days no reading · weekly no reading") == 2,
          "no readings anywhere: every field says no reading", r.stdout + r.stderr)
    digest = subprocess.run(["bash", str(TOOL.parent / "status-digest.sh")], capture_output=True, text=True,
                            env=dict(env, AUTONOMOUS_STATE=str(state), AUTONOMOUS_REPO=str(repo),
                                     AUTONOMOUS_PLAN=str(root / "no plan"), CODEX_HOME=str(codex),
                                     HOME=str(root / "home")))  # not the real Vision OCR ledger
    check(re.search(r"\n  Unspent    Claude .*\n {13}Codex ", digest.stdout) is not None,
          "status-digest.sh shows the line per subscription", digest.stdout + digest.stderr)

print("measure-workers proof: %d passed, 0 failed" % PASS)
