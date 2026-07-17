#!/usr/bin/env bash
# prove-daemon.sh — prove-the-mechanism harness for the autonomous daemon loop.
#
# WHY THIS IS COMMITTED: every change to ops/autonomous/* is Tier-2 (adversarial review + prove-the-mechanism
# before install), and the 2-week-hardening plan lands ~10 of them. A throwaway harness gets rewritten (or
# lost — this one was, once) for each; a committed one is a real regression suite that each new workstream
# extends. Run it before installing ANY daemon change.
#
# WHAT IT DOES: runs the REAL daemon against a stub `claude`, fully sandboxed — its own HOME, STATE, and git
# REPO, with every host-touching command (security/osascript/launchctl/caffeinate/curl/df) stubbed. It can
# never touch the owner's Desktop, real repo, real state dir, launchd, or the network.
#
# USAGE:  ops/autonomous/tests/prove-daemon.sh [path/to/archive-suite-autonomous.sh]
#         (defaults to the copy next to this script's parent dir)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DAEMON="${1:-$HERE/../archive-suite-autonomous.sh}"
[ -f "$DAEMON" ] || { echo "no daemon at $DAEMON"; exit 2; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# ---- sandbox -------------------------------------------------------------------------------------------
export HOME="$T/home"; mkdir -p "$HOME/Desktop" "$HOME/.local/bin"
BIN="$T/bin"; mkdir -p "$BIN"
# `security` prints nothing -> the taskport reminder greps for 'allow', finds none, and bails.
for c in security osascript launchctl caffeinate; do printf '#!/bin/sh\nexit 0\n' > "$BIN/$c"; chmod +x "$BIN/$c"; done

# Stub `curl` (WS6): record invocations instead of phoning out.
CURLLOG="$T/curl.log"; : > "$CURLLOG"
cat > "$BIN/curl" <<STUB
#!/bin/sh
echo "CURL \$*" >> "$CURLLOG"
exit \${CURL_RC:-0}
STUB
chmod +x "$BIN/curl"

# Stub `df` (WS2): macOS-style \`df -m\` output with a scriptable Available column (\$4). \$DFCTL holds one
# value per line; each call consumes the next, then repeats the last — so a test can script "low, then
# reclaimed" to exercise the housekeeping self-heal. A non-numeric value exercises the fail-open path.
DFCTL="$T/dfctl"; echo 999999 > "$DFCTL"
cat > "$BIN/df" <<STUB
#!/bin/sh
n=\$(cat "$DFCTL.count" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$DFCTL.count"
val=\$(sed -n "\${n}p" "$DFCTL" 2>/dev/null); [ -n "\$val" ] || val=\$(tail -1 "$DFCTL" 2>/dev/null)
[ "\$val" = "FAIL" ] && exit 1
echo "Filesystem 1M-blocks Used Available Capacity iused ifree %iused Mounted on"
echo "/dev/disk1 1000000 900000 \$val 91% 1 1 0% /"
STUB
chmod +x "$BIN/df"
dfset() { : > "$DFCTL.count"; printf '%s\n' "$@" > "$DFCTL"; }
export PATH="$BIN:$PATH"

REPO="$T/repo with space"; mkdir -p "$REPO"          # space in path: mirrors "/Users/<user>/Claude/Archive Suite"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo seed > "$REPO/f"
printf -- '- [ ] todo one\n' > "$REPO/SUITE_TODO.md"   # WS4: the drain-phase tracker of record
git -C "$REPO" add -A; git -C "$REPO" commit -qm seed
git -C "$REPO" branch -f main 2>/dev/null; git -C "$REPO" update-ref refs/remotes/origin/main HEAD

PLAN="$T/plan.md"
write_plan() {   # $1 = extra WORK QUEUE text (changing it moves the fingerprint)
  cat > "$PLAN" <<EOF
RUN STATUS: IN_PROGRESS — test

## WORK QUEUE (priority order)
- [ ] item one ${1:-}

## Session Log
(churn lives here — must NOT count as progress)
EOF
  printf -- '- [ ] todo one\n' > "$REPO/SUITE_TODO.md"   # reset the drain tracker between tests
}
write_plan

STATE="$T/state"; mkdir -p "$STATE"; echo off > "$STATE/gui-mode"
CTRL="$T/ctrl"; echo "1:no" > "$CTRL"          # stub claude behaviour: "<rc>:<commit?>[:<complete-item?>]"

CHILDENV="$T/childenv.log"
cat > "$T/claude" <<STUB
#!/usr/bin/env bash
env > "$CHILDENV"          # WS6: prove what the session actually inherits
IFS=: read -r rc docommit complete < "$CTRL"
# Simulate a session appending its reasoning to the Session Log — pure churn, must not read as progress.
printf '\n### session note %s\n' "\$(date +%s%N)" >> "$PLAN"
# docommit=yes -> a CHECKPOINT commit (HEAD moves; the fingerprint moves via HEAD).
[ "\$docommit" = yes ] && { echo "\$(date +%s%N)" > "$REPO/f"; git -C "$REPO" add -A; git -C "$REPO" commit -qm work; }
# complete=... -> COMPLETE an item, raising completed_items (WS4). Two phases:
#   queue = flip a plan WORK QUEUE item (wave phase);  todo = flip a SUITE_TODO.md item (Wave-12 DRAIN phase).
case "\$complete" in
  queue) awk '/^## Session Log/ && !d {print "- [x] completed-"NR; d=1} {print}' "$PLAN" > "$PLAN.tmp" && mv "$PLAN.tmp" "$PLAN" ;;
  todo)  printf -- '- [x] done-%s\n' "\$(date +%s%N)" >> "$REPO/SUITE_TODO.md" ;;
esac
exit "\$rc"
STUB
chmod +x "$T/claude"

launch() {   # $1=IDLE_STOP ; starts daemon in background, echoes pid
  AUTONOMOUS_LABEL=provetest AUTONOMOUS_REPO="$REPO" AUTONOMOUS_PLAN="$PLAN" \
  AUTONOMOUS_STATE="$STATE" AUTONOMOUS_CLAUDE="$T/claude" \
  AUTONOMOUS_INTERVAL=1 AUTONOMOUS_MAXBACKOFF=8 AUTONOMOUS_IDLE_STOP="$1" \
  AUTONOMOUS_MINFREE_MB="${MINFREE:-10240}" AUTONOMOUS_MAX_NOCOMPLETE="${MAXNC:-0}" \
  AUTONOMOUS_GATE_EVERY="${GATE_EVERY:-0}" AUTONOMOUS_GATE_CMD="${GATE_CMD:-/bin/false}" AUTONOMOUS_GATE_MAXRUN="${GATE_MAXRUN:-60}" \
  AUTONOMOUS_GATE_MAX_TIMEOUTS="${GATE_MAX_TIMEOUTS:-2}" \
  AUTONOMOUS_HB_POLL=1 \
    bash "$DAEMON" >/dev/null 2>&1 &
  echo $!
}
reset_state() { : > "$STATE/daemon.log"; : > "$CURLLOG"; rm -f "$STATE/idle.since" "$STATE/engine.lock" "$DFCTL.count" "$STATE/nocomplete.count" "$STATE/last-gate" "$STATE/last-gate.log" "$STATE/gate-timeouts"; }
stop() { kill -TERM "$1" 2>/dev/null; wait "$1" 2>/dev/null; pkill -f provetest 2>/dev/null; }
run_daemon() { reset_state; local p; p=$(launch "$1"); sleep "$2"; stop "$p"; echo "$STATE/daemon.log"; }
gaps() { grep -o 'next attempt in [0-9]*s' "$1" | grep -o '[0-9]*' | tr '\n' ' '; }

# ================= idle backoff / auto-park (2026-07-16, ffd2165) =================
echo "[1] Mode A — rc=1 usage-limit fast-fail must back off, not spin"
echo "1:no" > "$CTRL"; write_plan; dfset 999999
L=$(run_daemon 0 26); G=$(gaps "$L"); echo "    backoff gaps: $G"
[ "$(echo "$G" | awk '{print $1, $2, $3}')" = "2 4 8" ] && ok "doubles 2 -> 4 -> 8" || bad "expected '2 4 8', got '$G'"
echo "$G" | grep -qv '16' && ok "never exceeds MAXBACKOFF=8" || bad "blew past the cap"
[ "$(grep -c 'launching fresh' "$L")" -le 6 ] && ok "spawns bounded ($(grep -c 'launching fresh' "$L") in 26s)" || bad "too many spawns"

echo "[2] Mode B — rc=0 but nothing advanced (Session-Log churn must not count)"
echo "0:no" > "$CTRL"; write_plan; dfset 999999
L=$(run_daemon 0 20)
grep -qE 'rc=0\) advanced nothing' "$L" && ok "clean-but-idle detected as no-progress" || bad "no-progress not detected"
G=$(gaps "$L"); [ "$(echo "$G" | awk '{print $1, $2}')" = "2 4" ] && ok "backs off despite churn" || bad "expected '2 4', got '$G'"

echo "[3] Progress (a real commit) resets the backoff"
echo "0:no" > "$CTRL"; write_plan; dfset 999999; reset_state
P=$(launch 0); sleep 12; echo "0:yes" > "$CTRL"; sleep 10; stop "$P"; L="$STATE/daemon.log"
grep -q 'progress — backoff reset to 1s' "$L" && ok "commit detected as progress -> reset" || bad "no reset on progress"
grep -q 'no progress' "$L" && ok "had backed off first" || bad "never backed off"

echo "[4] Auto-park after IDLE_STOP of no progress"
echo "1:no" > "$CTRL"; write_plan; dfset 999999
L=$(run_daemon 5 25)
grep -q 'PARKED' "$L" && ok "parked after IDLE_STOP=5s" || bad "never parked"
[ -f "$HOME/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt" ] && ok "owner-visible Desktop notice written" || bad "no Desktop notice"
grep -q 'daemon down' "$L" && ok "loop exited cleanly" || bad "daemon did not exit"

echo "[5] Regression — RUN STATUS: COMPLETE still stops immediately"
sed -i '' 's/^RUN STATUS:.*/RUN STATUS: COMPLETE/' "$PLAN"; dfset 999999
L=$(run_daemon 0 6)
grep -q 'COMPLETE — daemon stopping' "$L" && ok "COMPLETE terminates" || bad "COMPLETE path broken"
[ "$(grep -c 'launching fresh' "$L")" = 0 ] && ok "COMPLETE spawns no session" || bad "spawned despite COMPLETE"

echo "[6] Fingerprint — arming work mid-backoff wakes it early (accelerator, not gate)"
echo "1:no" > "$CTRL"; write_plan; dfset 999999; reset_state
P=$(launch 0); sleep 12; echo "0:no" > "$CTRL"; write_plan "AND A NEWLY ARMED ITEM"; sleep 10; stop "$P"; L="$STATE/daemon.log"
grep -q 'progress — backoff reset to 1s' "$L" && ok "queue edit (no commit) -> instant retry" || bad "queue edit did not reset backoff"

echo "[7] Stale idle.since from a prior run must NOT park on cycle 1 (confirmed-HIGH regression)"
echo "1:no" > "$CTRL"; write_plan; dfset 999999; reset_state
echo "$(( $(date +%s) - 100000 ))" > "$STATE/idle.since"   # ~28h-old stamp left by a dead daemon
P=$(launch 3600); sleep 9; stop "$P"; L="$STATE/daemon.log"
grep -q 'PARKED' "$L" && bad "parked on cycle 1 off a stale stamp (HIGH bug present)" || ok "stale stamp cleared at init"
[ "$(grep -c 'launching fresh' "$L")" -ge 2 ] && ok "kept retrying, not one-and-park" || bad "only one session"

echo "[8] Progress is fingerprint-move, INDEPENDENT of exit code (commit then rc=1)"
echo "1:no" > "$CTRL"; write_plan; dfset 999999; reset_state
P=$(launch 0); sleep 12; echo "1:yes" > "$CTRL"; sleep 8; stop "$P"; L="$STATE/daemon.log"
grep -q 'no progress' "$L" && ok "backed off while rc=1 committed nothing" || bad "never backed off"
grep -q 'backoff reset to 1s' "$L" && ok "rc=1-with-commit counts as progress (rc not gating)" || bad "commit+rc=1 missed"

# ================= WS6 remote alerting =================
echo "[9] WS6 — park fires a remote alert, and the endpoint secret never reaches the log"
echo "1:no" > "$CTRL"; write_plan; dfset 999999
printf 'ALERT_URL="https://example.invalid/SECRETTOKEN123"\n' > "$STATE/alert.env"
L=$(run_daemon 5 22)
grep -q 'PARKED' "$L" && ok "parked" || bad "never parked"
grep -q 'SECRETTOKEN123' "$CURLLOG" && ok "alert POSTed to the configured endpoint" || bad "no alert sent"
grep -q 'alert sent' "$L" && ok "alert logged as sent" || bad "alert not logged"
grep -q 'SECRETTOKEN123' "$L" && bad "SECRET LEAKED into daemon.log" || ok "endpoint/token never logged"

echo "[9b] WS6 — ALERT_AUTH with spaces must arrive as ONE argv element (word-split regression)"
# The naive `${ALERT_AUTH:+-H "Authorization: $ALERT_AUTH"}` collapses to one malformed argv on bash 3.2 and
# curl rejects it — the alert silently never sends. The stub records argv one-per-line to prove the split.
cat > "$BIN/curl" <<STUB
#!/bin/sh
for a in "\$@"; do echo "ARG:\$a" >> "$CURLLOG"; done
exit 0
STUB
chmod +x "$BIN/curl"
printf 'ALERT_URL="https://example.invalid/SECRETTOKEN123"\nALERT_AUTH="Bearer tok with spaces"\n' > "$STATE/alert.env"
echo "1:no" > "$CTRL"; write_plan; dfset 999999
L=$(run_daemon 5 22)
grep -qx 'ARG:Authorization: Bearer tok with spaces' "$CURLLOG" \
  && ok "auth header is exactly one argv element" \
  || bad "auth header word-split/mangled: $(grep '^ARG:' "$CURLLOG" | tr '\n' '|')"
grep -qx 'ARG:-H' "$CURLLOG" && ok "-H passed as its own element" || bad "-H not a separate element"
# restore the simple recording stub for later tests
cat > "$BIN/curl" <<STUB
#!/bin/sh
echo "CURL \$*" >> "$CURLLOG"
exit \${CURL_RC:-0}
STUB
chmod +x "$BIN/curl"

echo "[10] WS6 — unconfigured is a silent no-op (daemon must run fine without alerting)"
rm -f "$STATE/env" "$STATE/alert.env"; echo "1:no" > "$CTRL"; write_plan; dfset 999999
L=$(run_daemon 5 20)
grep -q 'PARKED' "$L" && ok "still parks with no ALERT_URL" || bad "park broke when unconfigured"
[ -s "$CURLLOG" ] && bad "curl called despite no ALERT_URL" || ok "no curl invoked (clean no-op)"
grep -q 'alert FAILED' "$L" && bad "logged a spurious alert failure" || ok "no spurious failure logged"

# ================= WS2 disk guard =================
echo "[11] WS2 — low disk parks + alerts and NEVER launches a session"
# alert.env (NOT $STATE/env): the disk guard parks at tick step 3b, BEFORE step 5 sources the child env — so a
# misplaced config would silently fail to alert on the very first cycle. This asserts the documented setup.
printf 'ALERT_URL="https://example.invalid/SECRETTOKEN123"\n' > "$STATE/alert.env"
echo "0:no" > "$CTRL"; write_plan; dfset 100          # 100MB free, persistently (< MINFREE 10240)
L=$(run_daemon 0 8)
grep -q 'PARKED (low disk' "$L" && ok "parked on low disk" || bad "did not park on low disk"
[ "$(grep -c 'launching fresh' "$L")" = 0 ] && ok "no session launched (never builds on a full disk)" || bad "launched a session anyway"
grep -q 'SECRETTOKEN123' "$CURLLOG" && ok "low-disk alert reached the endpoint" || bad "no low-disk alert"
grep -q 'daemon down' "$L" && ok "loop exited cleanly" || bad "daemon did not exit"

echo "[12] WS2 — unreadable df FAILS OPEN (a broken check must never stop a healthy run)"
rm -f "$STATE/env" "$STATE/alert.env"; echo "0:no" > "$CTRL"; write_plan; dfset notanumber
L=$(run_daemon 0 8)
grep -q 'PARKED' "$L" && bad "parked on an unreadable df (should fail open)" || ok "did not park on garbage df"
[ "$(grep -c 'launching fresh' "$L")" -ge 1 ] && ok "kept working normally" || bad "stopped launching sessions"
dfset FAIL                                            # df exits 1, no output at all
L=$(run_daemon 0 8)
grep -q 'PARKED' "$L" && bad "parked when df exited nonzero (should fail open)" || ok "df exit!=0 also fails open"

echo "[9c] WS6 — the alert credential must NEVER reach the claude session's environment (confirmed-HIGH)"
# $STATE/env is the CHILD's env (tick sources it under `set -a` to hand PATH/OCR_KEY to claude). A session is
# an LLM with Bash+WebFetch and a curl/wget deny-list precisely so it can't phone out — it must not hold the
# operator's alert endpoint. alert.env must stay daemon-only; and even a MISPLACED ALERT_* in env must be
# stripped of its export attribute before the child spawns.
rm -f "$STATE/env"; : > "$CHILDENV"
printf 'ALERT_URL="https://example.invalid/SECRETTOKEN123"\n' > "$STATE/alert.env"
echo "0:no" > "$CTRL"; write_plan; dfset 999999
L=$(run_daemon 0 8)
grep -q 'SECRETTOKEN123' "$CHILDENV" && bad "SECRET LEAKED into the session env (via alert.env)" || ok "alert.env stays daemon-only — child env clean"
grep -q 'alert sent\|CURL' "$L" "$CURLLOG" >/dev/null 2>&1 || true
# now the misplacement case: operator wrongly puts it in the child's env file
: > "$CHILDENV"
printf 'ALERT_URL="https://example.invalid/MISPLACED456"\n' > "$STATE/env"
rm -f "$STATE/alert.env"
L=$(run_daemon 0 8)
grep -q 'MISPLACED456' "$CHILDENV" && bad "misplaced ALERT_URL in \$STATE/env LEAKED to the child" || ok "misplaced ALERT_* un-exported before spawn (defence in depth)"
rm -f "$STATE/env"

echo "[11b] WS2 — must NOT run housekeeping while another engine is active (confirmed-HIGH reentrancy)"
# housekeeping's safety argument assumes "between sessions, none active"; `git worktree remove` does NOT
# refuse a worktree whose only content is gitignored (build/DD), so GCing a live engine's worktree mid-build
# is real. The disk check must therefore sit AFTER the "engine busy" skip.
rm -f "$STATE/alert.env"; echo "0:no" > "$CTRL"; write_plan; dfset 100   # low disk would trigger reclaim…
reset_state; touch "$STATE/engine.lock"                                  # …but another engine holds a FRESH lock
P=$(launch 0); sleep 6; stop "$P"; L="$STATE/daemon.log"
grep -q 'engine busy' "$L" && ok "skipped the cycle (engine busy)" || bad "did not detect the busy engine"
grep -q 'running housekeeping to reclaim' "$L" && bad "ran housekeeping while another engine was live" || ok "no housekeeping while another engine is live"
grep -q 'PARKED' "$L" && bad "parked while another engine was live" || ok "did not park behind a live engine"
rm -f "$STATE/engine.lock"

echo "[13] WS2 — housekeeping self-heal: low then reclaimed -> continue, no park"
echo "0:no" > "$CTRL"; write_plan; dfset 100 50000    # 1st read low, 2nd (post-housekeeping) fine
L=$(run_daemon 0 8)
grep -q 'running housekeeping to reclaim' "$L" && ok "attempted reclaim before giving up" || bad "no reclaim attempt"
grep -q 'disk reclaimed' "$L" && ok "detected the reclaim and continued" || bad "did not continue after reclaim"
grep -q 'PARKED' "$L" && bad "parked despite reclaiming enough space" || ok "did not park"

# ================= WS4 per-item attempt cap =================
echo "[14] WS4 — commits that complete NO queue item park after MAX_NOCOMPLETE (the checkpoint-loop backoff can't catch)"
echo "0:yes:no" > "$CTRL"; write_plan; dfset 999999      # every session commits (fingerprint moves) but never completes an item
L=$(MAXNC=3 run_daemon 0 14)
grep -q 'attempt streak 1/3' "$L" && ok "counts checkpoint-only sessions" || bad "no streak count"
grep -q 'PARKED (no item completed in 3 sessions' "$L" && ok "parked at the cap with a clear reason" || bad "never parked at the cap"
grep -q 'daemon down' "$L" && ok "loop exited cleanly" || bad "did not exit"

echo "[15] WS4 — DRAIN-PHASE completion (SUITE_TODO flip, plan WORK QUEUE static) RESETS the streak (the confirmed-HIGH scenario)"
# This is the exact case the review caught: the run's current mode completes items in SUITE_TODO.md while the
# plan WORK QUEUE stays constant. If completion were measured off the plan WORK QUEUE alone, cc would never
# rise and a healthy item-per-session drain would false-park after MAX_NOCOMPLETE.
write_plan; dfset 999999; reset_state
P=$(MAXNC=6 launch 0)
echo "0:yes:no"   > "$CTRL"; sleep 4      # a few checkpoints (streak climbs)
echo "0:yes:todo" > "$CTRL"; sleep 3      # complete a SUITE_TODO item (plan WORK QUEUE unchanged) -> reset
echo "0:yes:no"   > "$CTRL"; sleep 4      # checkpoints again (streak restarts from 1)
stop "$P"; L="$STATE/daemon.log"
grep -q 'attempt streak reset' "$L" && ok "SUITE_TODO completion detected -> streak reset" || bad "reset not logged (drain completion missed!)"
[ "$(grep -c 'attempt streak 1/6' "$L")" -ge 2 ] && ok "streak restarted from 1 after the reset" || bad "streak did not restart (count=$(grep -c 'attempt streak 1/6' "$L"))"
grep -q 'PARKED (no item completed' "$L" && bad "parked despite the drain completion resetting the streak" || ok "did not park a healthy drain run"

echo "[15b] WS4 — WAVE-PHASE completion (plan WORK QUEUE flip) also resets the streak"
write_plan; dfset 999999; reset_state
P=$(MAXNC=6 launch 0)
echo "0:yes:no"    > "$CTRL"; sleep 4
echo "0:yes:queue" > "$CTRL"; sleep 3     # complete a plan WORK QUEUE item -> reset
echo "0:yes:no"    > "$CTRL"; sleep 4
stop "$P"; L="$STATE/daemon.log"
grep -q 'attempt streak reset' "$L" && ok "WORK QUEUE completion detected -> streak reset" || bad "reset not logged"
grep -q 'PARKED (no item completed' "$L" && bad "parked despite a wave completion" || ok "did not park"

echo "[16] WS4 — a stale nocomplete.count from a prior run must NOT park on cycle 1 (mirror the idle.since HIGH)"
echo "0:yes:no" > "$CTRL"; write_plan; dfset 999999; reset_state
echo 10 > "$STATE/nocomplete.count"      # stale, well over the cap
P=$(MAXNC=5 launch 0); sleep 4; stop "$P"; L="$STATE/daemon.log"
grep -q 'PARKED (no item completed' "$L" && bad "parked off a stale count (startup didn't clear it)" || ok "stale count cleared at startup"
grep -q 'attempt streak 1/5' "$L" && ok "streak restarted from 1" || bad "did not restart from 1"

# ================= WS7 health gate =================
# Stub gates (no real builds): green exits 0, red prints + exits 1, hang sleeps forever, flaky fails once
# then passes (via a counter file — exercises the WS7 retry-once).
printf '#!/bin/sh\necho "gate ok"\nexit 0\n' > "$T/gate-green.sh"; chmod +x "$T/gate-green.sh"
printf '#!/bin/sh\necho "BUILD FAILED: boom in Reader"\nexit 1\n' > "$T/gate-red.sh"; chmod +x "$T/gate-red.sh"
printf '#!/bin/sh\nsleep 999\n' > "$T/gate-hang.sh"; chmod +x "$T/gate-hang.sh"
cat > "$T/gate-flaky.sh" <<FLAKY
#!/bin/sh
c="$T/flaky.count"; n=\$(cat "\$c" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "\$c"
[ "\$n" -ge 2 ] && { echo "green on attempt \$n"; exit 0; }
echo "Lost connection to test manager (transient) attempt \$n"; exit 1
FLAKY
chmod +x "$T/gate-flaky.sh"

echo "[22] WS7 — a DUE gate that passes is GREEN: runs, records last-gate, and is NON-terminal (run continues)"
echo "1:no" > "$CTRL"; write_plan; dfset 999999
L=$(GATE_EVERY=1 GATE_CMD="$T/gate-green.sh" run_daemon 0 8)
grep -q 'health gate GREEN' "$L" && ok "gate ran green" || bad "gate did not run/pass"
[ -s "$STATE/last-gate" ] && ok "recorded last-gate sha" || bad "last-gate not recorded"
grep -q 'launching fresh' "$L" && ok "green gate is non-terminal — daemon continued to normal work" || bad "daemon stopped after a green gate"

echo "[23] WS7 — a REPRODUCIBLE failure (red twice) parks + alerts; does NOT launch a session"
printf 'ALERT_URL="https://example.invalid/GATETOKEN9"\n' > "$STATE/alert.env"
echo "0:yes" > "$CTRL"; write_plan; dfset 999999
L=$(GATE_EVERY=1 GATE_CMD="$T/gate-red.sh" run_daemon 0 8)
grep -q 'retrying ONCE' "$L" && ok "retried once before parking" || bad "did not retry before parking"
grep -q 'PARKED (health gate RED (x2)' "$L" && ok "parked only after a reproducible 2nd failure" || bad "did not park on x2 red"
grep -q 'GATETOKEN9' "$CURLLOG" && ok "alerted the owner" || bad "no alert on red gate"
[ "$(grep -c 'launching fresh' "$L")" = 0 ] && ok "no session launched (gate gates the cycle)" || bad "launched a session despite red gate"
rm -f "$STATE/alert.env"

echo "[23b] WS7 — a FLAKY failure (red once, then green) must NOT park (F1 retry-once)"
rm -f "$T/flaky.count"; echo "0:no" > "$CTRL"; write_plan; dfset 999999
L=$(GATE_EVERY=1 GATE_CMD="$T/gate-flaky.sh" run_daemon 0 8)
grep -q 'GREEN on retry' "$L" && ok "transient failure recovered on retry -> green" || bad "flaky failure not recovered"
grep -q 'PARKED (health gate' "$L" && bad "PARKED on a flaky (transient) failure" || ok "did not park a healthy run on a flaky test"

echo "[24] WS7 — a single gate TIMEOUT is killed + SKIPPED (inconclusive; must NOT park a healthy run)"
echo "0:no" > "$CTRL"; write_plan; dfset 999999
L=$(GATE_EVERY=1 GATE_CMD="$T/gate-hang.sh" GATE_MAXRUN=2 GATE_MAX_TIMEOUTS=9 run_daemon 0 8)
grep -q 'health gate TIMED OUT' "$L" && ok "timed out + killed" || bad "did not time out a hung gate"
grep -q 'PARKED (health gate' "$L" && bad "PARKED on a single hang (should skip)" || ok "did not park on a single hang (inconclusive)"
pgrep -f gate-hang >/dev/null && { bad "hung gate process leaked"; pkill -f gate-hang; } || ok "hung gate process was killed"

echo "[24b] WS7 — PERSISTENT timeouts escalate: park + alert after GATE_MAX_TIMEOUTS consecutive hangs"
printf 'ALERT_URL="https://example.invalid/HANGTOKEN7"\n' > "$STATE/alert.env"
echo "0:no" > "$CTRL"; write_plan; dfset 999999
L=$(GATE_EVERY=1 GATE_CMD="$T/gate-hang.sh" GATE_MAXRUN=2 GATE_MAX_TIMEOUTS=2 run_daemon 0 14)
grep -q 'PARKED (health gate hung' "$L" && ok "parked after repeated hangs" || bad "did not escalate persistent hangs to a park"
grep -q 'HANGTOKEN7' "$CURLLOG" && ok "alerted the owner about the hang" || bad "no alert on persistent hang"
pkill -f gate-hang 2>/dev/null; rm -f "$STATE/alert.env"

echo "[25] WS7 — NOT due (few commits since last gate) -> no gate, normal session runs"
# Manual launch pattern: seed last-gate AFTER reset_state (run_daemon would wipe it).
echo "1:no" > "$CTRL"; write_plan; dfset 999999; reset_state
git -C "$REPO" rev-parse HEAD > "$STATE/last-gate"    # just gated at HEAD -> 0 commits since
P=$(GATE_EVERY=100 GATE_CMD="$T/gate-green.sh" launch 0); sleep 6; stop "$P"; L="$STATE/daemon.log"
grep -q 'health gate DUE' "$L" && bad "ran a gate when not due" || ok "skipped the gate (not due)"
grep -q 'launching fresh' "$L" && ok "normal session ran instead" || bad "no session ran"

echo "[26] WS7 — bad/stale last-gate sha FAILS OPEN (gate due), not a silent skip"
echo "1:no" > "$CTRL"; write_plan; dfset 999999; reset_state
echo deadbeefdeadbeefdeadbeefdeadbeefdeadbeef > "$STATE/last-gate"   # seed AFTER reset (see [25])
P=$(GATE_EVERY=100 GATE_CMD="$T/gate-green.sh" launch 0); sleep 8; stop "$P"; L="$STATE/daemon.log"
grep -q 'health gate DUE' "$L" && ok "bad last-gate sha -> gate ran (fail-open)" || bad "bad sha silently skipped the gate"

echo
echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" = 0 ]
