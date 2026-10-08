#!/usr/bin/env python3
"""prove-session-policy.py — W35.session-policy (Agent Manager stage 7, daemon side).

Runs the REAL daemon (and, as the baseline, the daemon as it is on origin/main) against a scratch repo, state and
plan, with the real worker-state.py making the reservation, a stub `bin/grant`, a stub `claude` that records its
argv, and a stub heavy-lock helper. Each daemon run launches one session: the stub claude sets RUN STATUS to
COMPLETE first, so the daemon exits after it.

WHAT IT PROVES
  [1] the evidence a stub grant receives for an ordinary item, a gate fix and an escalated item;
  [2] the launch line uses the returned model, fallback, effort and budget, and the usage row names the model;
  [3] the wall limit is not charged while the session is queued for the heavy lock, and still fires outside it;
  [4] the quiet limit is applied to the health watchdog;
  [5] the per-item counter climbs on a no-commit session and resets on a commit naming the tag, independently for
      two tags, ignores a commit for a longer tag, and is removed when the item completes;
  [6] the escalate file is used once and only for its own tag;
  [7] policy-omitted, a missing helper, garbage, a timeout, a non-zero exit and an unusable policy each give the
      baseline daemon's launch line byte for byte (the claim token normalised);
  [8] an operator-exported AUTONOMOUS_BUDGET still wins, and the log says so;
  [9] a wait at the policy ask releases the claim and launches nothing.
Usage: prove-session-policy.sh [BASELINE_DAEMON]  (default: `git show origin/main:` of the daemon)
"""
import json, os, re, shutil, signal, subprocess, sys, tempfile, time
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
DAEMON = HERE / "archive-suite-autonomous.sh"
PASS = FAIL = 0


def check(cond, msg):
    global PASS, FAIL
    if cond:
        PASS += 1; print("  \033[32mPASS\033[0m " + msg)
    else:
        FAIL += 1; print("  \033[31mFAIL\033[0m " + msg)


root = Path(tempfile.mkdtemp(prefix="prove-session-policy-"))
repo = root / "repo with space"; state = root / "state"; plan = root / "plan.md"; bindir = root / "bin"
for d in (repo / "ops", state, bindir, root / "home/Desktop"):
    d.mkdir(parents=True)
(repo / "ops/autonomous").symlink_to(HERE, target_is_directory=True)
(repo / "SUITE_TODO.md").write_text("")
git = lambda *a: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True)
git("init", "-q"); git("config", "user.name", "fixture"); git("config", "user.email", "fixture@example.invalid")
git("add", "SUITE_TODO.md"); git("commit", "-qm", "seed"); git("update-ref", "refs/remotes/origin/main", "HEAD")
(state / "resume-prompt.txt").write_text("autonomous maintenance session (prove-session-policy fixture prompt)\n")

for name in ("security", "osascript", "launchctl", "caffeinate", "curl"):
    f = bindir / name; f.write_text("#!/bin/sh\nexit 0\n"); f.chmod(0o755)
(bindir / "df").write_text("#!/bin/sh\necho 'Filesystem 1M-blocks Used Available Capacity Mounted'\n"
                           "echo '/dev/test 1000000 1 999999 1% /'\n"); (bindir / "df").chmod(0o755)

# Stub grant: a call without --evidence is the stage 4 hold check and is always granted. A call with it records
# the evidence and answers as $root/grant-mode says.
GRANT = root / "grant"
GRANT.write_text("#!/usr/bin/env python3\nimport json,sys,time,shutil\nfrom pathlib import Path\n"
                 f"R=Path({str(root)!r}); S=Path({str(state)!r})\n" + r'''
a = sys.argv[1:]
if "--evidence" not in a:
    pre = R / "pretries"
    if pre.exists(): (S / "gate-fix-tries").write_text(pre.read_text()); pre.unlink()
    print("granted"); sys.exit(0)
ev = a[a.index("--evidence") + 1]; out = Path(a[a.index("--policy-out") + 1])
n = len(list(R.glob("evidence-*.json"))) + 1
shutil.copy(ev, R / ("evidence-%d.json" % n))
(R / "grant-args.json").write_text(json.dumps(a))
mode = (R / "grant-mode").read_text().strip()
if mode.startswith("policy:"):
    out.write_text(json.dumps({"policy": json.loads(mode[7:])})); print("granted"); print("policy: x")
elif mode == "omitted":
    out.write_text(json.dumps({"policy": None, "omitted": "fixture omitted"})); print("granted"); print("policy-omitted: fixture")
elif mode == "garbage":
    out.write_text("not json {"); print("granted")
elif mode == "timeout":
    time.sleep(20); print("granted")
elif mode == "wait":
    print("wait: fixture priority"); sys.exit(75)
elif mode == "fail":
    sys.exit(3)
else:
    print("granted")
''')
GRANT.chmod(0o755)

# Stub claude: COMPLETE first (so the daemon stops after this one session), record argv, then act per claude-mode.
CLAUDE = root / "claude"
CLAUDE.write_text("#!/usr/bin/env bash\n"
                  f"R={str(root)!r}; PLAN={str(plan)!r}; REPO={str(repo)!r}\n" + r'''
sed -i '' 's/^RUN STATUS: IN_PROGRESS/RUN STATUS: COMPLETE/' "$PLAN"
n=$(ls "$R"/argv-*.json 2>/dev/null | wc -l | tr -d ' '); n=$((n+1))
python3 -c 'import json,sys; open(sys.argv[1],"w").write(json.dumps(sys.argv[2:]))' "$R/argv-$n.json" "$@"
while IFS= read -r act; do
  case "$act" in
    commit:*) git -C "$REPO" commit -q --allow-empty -m "${act#commit:}" ;;
    tick:*)   sed -i '' "s/^- \[ \] \*\*${act#tick:} /- [x] **${act#tick:} /" "$PLAN" ;;
    escalate:*) printf '%s\n' "${act#escalate:}" > "$AUTONOMOUS_WORKER_STATE/escalate" ;;
    sleep:*)  sleep "${act#sleep:}" ;;
  esac
done < "$R/claude-mode"
exit 0
''')
CLAUDE.chmod(0o755)

HEAVY = root / "heavy.py"   # `waiting PID` answers yes while $root/heavy-waiting exists
HEAVY.write_text(f"import sys\nfrom pathlib import Path\nsys.exit(0 if 'waiting' in sys.argv and Path({str(root / 'heavy-waiting')!r}).exists() else 1)\n")

baseline = root / "baseline-daemon.sh"
if len(sys.argv) > 1:
    shutil.copy(sys.argv[1], baseline)
else:
    src = subprocess.run(["git", "-C", str(HERE), "show", "origin/main:ops/autonomous/archive-suite-autonomous.sh"],
                         capture_output=True, text=True)
    if src.returncode != 0 or "W35.session-policy" in src.stdout:
        sys.exit("no pre-change baseline on origin/main; pass one as the first argument")
    baseline.write_text(src.stdout)

ITEMS = {
    "alpha": "- [ ] **W99.alpha — ordinary item [M · ~1-2 sessions]** (lane: ops) (uses: build)",
    "beta": "- [ ] **W99.beta — second item [S · ~1 session]** (lane: notes) (uses: light)",
}


def setplan(*keys):
    plan.write_text("RUN STATUS: IN_PROGRESS — test\n\n## WORK QUEUE (priority order)\n"
                    + "\n".join(ITEMS[k] for k in keys) + "\n## HOLD QUEUE\n## Session Log\n")


base_env = {k: v for k, v in os.environ.items() if not k.startswith(("AUTONOMOUS_", "CLAUDE"))}
base_env.update(HOME=str(root / "home"), PATH=str(bindir) + ":" + os.environ["PATH"],
                MAC_HEAVY_LOCK=str(root / "mac-heavy.lock"),
                AUTONOMOUS_LABEL="provesessionpolicy", AUTONOMOUS_REPO=str(repo), AUTONOMOUS_PLAN=str(plan),
                AUTONOMOUS_STATE=str(state), AUTONOMOUS_SUITE_TODO=str(repo / "SUITE_TODO.md"),
                AUTONOMOUS_SUITE_TODO_DONE=str(repo / "done.md"), AUTONOMOUS_AGENT="claude",
                AUTONOMOUS_CLAUDE=str(CLAUDE), AUTONOMOUS_WORKER_ID="worker-1", AUTONOMOUS_DOC_PREGATE="0",
                AUTONOMOUS_GATE_EVERY="0", AUTONOMOUS_COMPACTOR=str(root / "none"),
                AUTONOMOUS_YIELD_CMD=str(root / "none"), AUTONOMOUS_GRANT_CMD=str(GRANT),
                AUTONOMOUS_USAGE_CMD=str(root / "none"), AUTONOMOUS_STATUS_CMD="/usr/bin/true",
                AUTONOMOUS_HEAVY_CMD=str(HEAVY), AUTONOMOUS_HB_POLL="1", AUTONOMOUS_INTERVAL="1",
                AUTONOMOUS_MAX_NOCOMPLETE="0", AUTONOMOUS_IDLE_STOP="0", AUTONOMOUS_GRANT_TIMEOUT="2")
LOG = state / "daemon.log"


def tail(start):   # this run's part of the log: an offset in BYTES (the log has multi-byte dashes)
    return LOG.read_bytes()[start:].decode(errors="replace") if LOG.exists() else ""


def run(mode="", grant="none", daemon=DAEMON, extra=None, until=None, timeout=45):
    """One daemon run; returns (argv of the session or None, evidence dict or None, this run's log text)."""
    for f in list(root.glob("argv-*.json")) + list(root.glob("evidence-*.json")):
        f.unlink()
    plan.write_text(plan.read_text().replace("RUN STATUS: COMPLETE", "RUN STATUS: IN_PROGRESS"))
    (root / "claude-mode").write_text(mode + "\n")
    (root / "grant-mode").write_text(grant + "\n")
    start = LOG.stat().st_size if LOG.exists() else 0
    env = dict(base_env, **(extra or {}))
    with (root / "daemon.out").open("w") as out:
        p = subprocess.Popen(["bash", str(daemon)], env=env, stdout=out, stderr=out, start_new_session=True)
        deadline = time.time() + timeout
        while p.poll() is None and time.time() < deadline:
            if until and until(tail(start)):
                time.sleep(1); break
            time.sleep(0.2)
        try:
            os.killpg(p.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        p.wait()
    (state / "worker-1/engine.lock").unlink(missing_ok=True)
    argv = [json.loads(f.read_text()) for f in sorted(root.glob("argv-*.json"))]
    ev = [json.loads(f.read_text()) for f in sorted(root.glob("evidence-*.json"))]
    return (argv[0] if argv else None), (ev[-1] if ev else {}), tail(start)


def norm(argv):
    return [re.sub(r"\b[0-9a-f]{32}\b", "TOKEN", a) for a in argv] if argv else argv


def flag(argv, name):
    return argv[argv.index(name) + 1] if argv and name in argv else None


def counter(tag):
    f = state / "item-progress" / tag
    return f.read_text().strip() if f.exists() else None


POLICY = dict(model="fable", fallback_model="opus", effort="high", wall_limit_seconds=14400,
              wall_excludes="heavy-lock-wait", quiet_limit_seconds=600, budget_usd=175, rung=1)
pol = lambda **kw: "policy:" + json.dumps(dict(POLICY, **kw))

try:
    print("[7a] baseline: the launch line of the daemon as it was before this change")
    setplan("alpha")
    base_argv, _, blog = run(daemon=baseline)
    check(base_argv is not None and flag(base_argv, "--model") == "opus" and flag(base_argv, "--max-budget-usd") == "60",
          "baseline daemon launched opus with the fixed $60 cap")
    shutil.rmtree(state / "item-progress", ignore_errors=True)

    print("[1][2] an ordinary item: evidence out, the policy in the launch line")
    setplan("alpha")
    argv, ev, log = run(grant=pol())
    check(ev is not None and ev.get("item") == "W99.alpha" and ev.get("uses") == "build"
          and ev.get("estimate_sessions") == "~1-2 sessions" and ev.get("sessions_since_progress") == 0
          and ev.get("escalate_requested") is False and "is_gatefix" not in ev and "marker" not in ev,
          "ordinary evidence: item, uses, estimate as written, count 0, no escalate, no gate fix: %s" % ev)
    ga = json.loads((root / "grant-args.json").read_text())
    check(ga[:6] == ["--project", "Archive Suite", "--agent", "claude", "--worker", "worker-1"] and "--policy-out" in ga,
          "asked with --agent claude, the worker, --evidence and --policy-out")
    check(flag(argv, "--model") == "fable" and flag(argv, "--fallback-model") == "opus"
          and flag(argv, "--effort") == "high" and flag(argv, "--max-budget-usd") == "175",
          "launch line uses the returned model, fallback, effort and budget")
    check(norm(argv)[norm(argv).index("--max-budget-usd") + 2:] == norm(base_argv)[norm(base_argv).index("--max-budget-usd") + 2:]
          and norm(argv)[:2] == norm(base_argv)[:2], "everything else in the launch line is unchanged")
    check("session policy for W99.alpha: model=fable fallback=opus effort=high wall=14400s (heavy-lock wait excluded) quiet=600s budget=$175" in log,
          "the policy is logged")
    check("backstop 14400s, model fable, effort high, budget $175" in log, "the launch log line names the policy values")
    rows = (state / "usage-window.tsv").read_text().splitlines()
    check(rows[0].endswith("\tmodel") and rows[-1].split("\t")[-1] == "fable" and rows[-1].split("\t")[4] == "high",
          "usage row carries model and effort; header names the column")
    check(counter("W99.alpha") == "1", "no-commit session: W99.alpha count 0 -> 1")

    print("[5] per-item counters, independent per tag")
    _, ev, _ = run(grant=pol())
    check(ev.get("sessions_since_progress") == 1 and counter("W99.alpha") == "2", "second no-commit session: sent 1, now 2")
    setplan("beta", "alpha")
    _, ev, _ = run(grant=pol())
    check(ev.get("item") == "W99.beta" and ev.get("sessions_since_progress") == 0 and counter("W99.beta") == "1"
          and counter("W99.alpha") == "2", "W99.beta counts on its own; W99.alpha untouched")
    setplan("alpha")
    run("commit:W99.alpha-fu: a different item", grant=pol())
    check(counter("W99.alpha") == "3", "a commit naming only the longer tag W99.alpha-fu is not progress on W99.alpha")
    _, ev, _ = run("commit:test(ops): W99.alpha (checkpoint 1/2) — progress", grant=pol())
    check(ev.get("sessions_since_progress") == 3 and counter("W99.alpha") == "0" and counter("W99.beta") == "1",
          "a commit naming the tag resets W99.alpha to 0; W99.beta keeps 1")
    run("tick:W99.alpha", grant=pol())
    check(counter("W99.alpha") is None, "the item's completion removes its counter")

    print("[6] escalate: used once, and only for its own tag")
    setplan("alpha")
    run("escalate:W99.beta\tneeds a stronger model", grant=pol())
    esc = state / "worker-1/escalate"
    check(esc.exists(), "the session wrote $AUTONOMOUS_WORKER_STATE/escalate")
    _, ev, _ = run(grant=pol())
    check(ev.get("escalate_requested") is False and esc.exists(), "an ask for W99.alpha does not send or delete W99.beta's request")
    setplan("beta", "alpha")
    _, ev, _ = run(grant=pol())
    check(ev.get("escalate_requested") is True and ev.get("escalate_reason") == "needs a stronger model" and not esc.exists(),
          "the next W99.beta ask sends it with its reason, then deletes it")
    _, ev, _ = run(grant=pol())
    check(ev.get("escalate_requested") is False, "the following W99.beta ask is back to no escalate")

    print("[1] a gate fix")
    setplan("alpha")
    (state / "gate-fix").write_text("GATE FIX — fixture\n")
    (root / "pretries").write_text("2\n")   # _gatefix_handoff has counted this try as 2 (daemon start clears the file)
    _, ev, _ = run(grant=pol(), extra={"AUTONOMOUS_GATEFIX_MAX": "3"})
    check(ev is not None and ev.get("item") == "gate-fix" and ev.get("is_gatefix") is True and ev.get("gatefix_tries") == 2
          and ev.get("gatefix_max") == 3 and "sessions_since_progress" not in ev,
          "gate-fix evidence: is_gatefix, this try (2) as counted, gatefix_max, no per-item count: %s" % ev)
    check(not (state / "item-progress/gate-fix").exists(), "a gate fix keeps no per-item counter")
    (state / "gate-fix").unlink(missing_ok=True); (state / "gate-fix-tries").unlink(missing_ok=True)

    print("[3] the wall limit and the heavy-lock queue")
    (root / "heavy-waiting").write_text("")
    _, _, log = run("sleep:7", grant=pol(wall_limit_seconds=3))
    check("resume session exited rc=0" in log and not (state / "worker-1/session-killed").exists(),
          "queued for the heavy lock the whole time: a 3 s wall limit does not fire on a 7 s session")
    (root / "heavy-waiting").unlink()
    _, _, log = run("sleep:15", grant=pol(wall_limit_seconds=3))
    check((state / "worker-1/session-killed").exists() and "resume session exited rc=0" not in log,
          "not queued: the same 3 s wall limit kills the session")
    (root / "heavy-waiting").write_text("")
    _, _, log = run("sleep:7", grant=pol(wall_limit_seconds=3, wall_excludes=None))
    check((state / "worker-1/session-killed").exists(), "without wall_excludes=heavy-lock-wait the queue time is charged")
    (root / "heavy-waiting").unlink()

    print("[4] the quiet limit")
    _, _, log = run("sleep:30", grant=pol(quiet_limit_seconds=2))
    check("watchdog: session wedged" in log, "a 2 s quiet limit reaches the health watchdog")
    _, _, log = run("sleep:6", grant=pol())
    check("watchdog:" not in log and "resume session exited rc=0" in log, "the default 600 s quiet limit leaves a 6 s quiet session alone")

    print("[8] an operator export wins")
    argv, _, log = run(grant=pol(), extra={"AUTONOMOUS_BUDGET": "11"})
    check(flag(argv, "--max-budget-usd") == "11" and flag(argv, "--model") == "fable" and "operator export kept: budget (AUTONOMOUS_BUDGET=11)" in log,
          "AUTONOMOUS_BUDGET=11 keeps the budget, the rest follows the policy, and the log says so")

    print("[7] every fallback gives the baseline launch line byte for byte")
    for name, grant, extra in (("policy-omitted", "omitted", None), ("missing helper", "none", {"AUTONOMOUS_GRANT_CMD": str(root / "absent")}),
                               ("garbage output", "garbage", None), ("timeout", "timeout", None), ("exit 3", "fail", None),
                               ("unusable policy", pol(fallback_model="fable"), None), ("bad effort", pol(effort="ultra"), None)):
        argv, _, log = run(grant=grant, extra=extra)
        check(argv is not None and norm(argv) == norm(base_argv), "%s: launch line == baseline" % name)
        check("session policy: none (" in log, "%s: the log says the fixed settings were used" % name)

    print("[9] a wait at the policy ask holds")
    setplan("alpha")
    argv, _, log = run(grant="wait", until=lambda t: "says wait" in t, timeout=20)
    check(argv is None and "the Agent Manager says wait (fixture priority) — releasing W99.alpha" in log,
          "no session launched, the wait is logged")
    check(not (state / "claims/W99.alpha").exists(), "the claim was released")
finally:
    print("\n=================== %d passed, %d failed ===================" % (PASS, FAIL))
    if FAIL == 0:
        shutil.rmtree(root, ignore_errors=True)
    else:
        print("ARTIFACT: " + str(root))
sys.exit(1 if FAIL else 0)
