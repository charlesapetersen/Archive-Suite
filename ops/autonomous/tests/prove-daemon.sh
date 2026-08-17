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
T="$(mktemp -d)"
# Leak-proof cleanup: every launch() records its daemon pid to $T/daemon.pids; the EXIT trap kills any that
# are STILL the daemon (guarded by a command-name check, so a recycled pid is never killed). Without this, a
# run interrupted BETWEEN launch() and stop() (e.g. a harness timeout) reparents its daemon to init, which
# then spins forever against the (deleted) sandbox — a real leak observed 2026-07-17.
reap_launched() {
  [ -f "$T/daemon.pids" ] || return 0
  while read -r _p; do
    [ -n "$_p" ] || continue
    # Guard against pid RECYCLING: only kill if the pid is STILL running the EXACT $DAEMON path this harness
    # launched (matched literally — $DAEMON is quoted in the pattern). For the DEFAULT in-repo $DAEMON that
    # differs from the installed real daemon (~/.local/bin/…), so a recycled pid that became the owner's real
    # daemon won't match. CAVEAT: if you invoke this harness with $1 = the installed path, the guard degenerates
    # to the real daemon's command line and a recycled pid COULD match it — so pass the repo copy (the default).
    case "$(ps -p "$_p" -o command= 2>/dev/null)" in
      *"$DAEMON"*) kill -9 "$_p" 2>/dev/null ;;
    esac
  done < "$T/daemon.pids"
}
# NOTE: no `pkill -f provetest` here — AUTONOMOUS_LABEL=provetest is an ENV var, not argv, so `pkill -f` never
# matched the daemon anyway; reap_launched (pid-scoped) is the real reaper, and the daemon's stub children
# (sleep/claude/caffeinate) are short-lived.
trap 'reap_launched; rm -rf "$T"' EXIT
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

REPO="$T/repo with space"; mkdir -p "$REPO"          # space in path: mirrors "<repo with a space in its path>"
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

STATE="$T/state"; mkdir -p "$STATE"
# The L2 resume prompt. The real daemon is started by daemon.sh, which RENDERS this into $STATE before
# launching, so a run without one never happens in production — but the harness had never seeded it, and the
# daemon did not check, so the suite was exercising a state the real system cannot be in. It now refuses to
# start without one (W32.preflight-gap: a missing/empty prompt otherwise means a silent `claude -p ""`, which
# then reads as a usage-limit fast-fail for 72 h). The stub `claude` ignores the text; only presence matters.
printf 'autonomous maintenance session for the Archive Suite (prove-daemon fixture prompt)\n' > "$STATE/resume-prompt.txt"
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
# WS5 status-digest stub — the daemon should write its stdout to $STATE/STATUS.md each cycle + on park.
printf '#!/bin/sh\necho "STATUS-DIGEST-OK parked=${STATUS_PARKED:-no}"\n' > "$T/status-stub.sh"; chmod +x "$T/status-stub.sh"

launch() {   # $1=IDLE_STOP ; starts daemon in background, echoes pid
  AUTONOMOUS_LABEL=provetest AUTONOMOUS_REPO="$REPO" AUTONOMOUS_PLAN="$PLAN" \
  AUTONOMOUS_STATE="$STATE" AUTONOMOUS_CLAUDE="$T/claude" \
  AUTONOMOUS_INTERVAL=1 AUTONOMOUS_MAXBACKOFF=8 AUTONOMOUS_IDLE_STOP="$1" \
  AUTONOMOUS_MINFREE_MB="${MINFREE:-10240}" AUTONOMOUS_MAX_NOCOMPLETE="${MAXNC:-0}" \
  AUTONOMOUS_GATE_EVERY="${GATE_EVERY:-0}" AUTONOMOUS_GATE_CMD="${GATE_CMD:-/bin/false}" AUTONOMOUS_GATE_MAXRUN="${GATE_MAXRUN:-60}" \
  AUTONOMOUS_GATE_MAX_TIMEOUTS="${GATE_MAX_TIMEOUTS:-2}" \
  AUTONOMOUS_STATUS_CMD="${STATUS_CMD:-$T/status-stub.sh}" \
  AUTONOMOUS_COMPACTOR="${COMPACTOR:-$T/no-such-compactor}" \
  AUTONOMOUS_DOC_PREGATE="${DOC_PREGATE:-0}" \
  AUTONOMOUS_BUDGET_CMD="${BUDGET_CMD:-$T/no-such-budget}" \
  AUTONOMOUS_DOCFIX_MAX="${DOCFIX_MAX:-3}" \
  AUTONOMOUS_HB_POLL=1 \
    bash "$DAEMON" >/dev/null 2>&1 &
  local pid=$!; echo "$pid" >> "$T/daemon.pids"; echo "$pid"   # record for the leak-proof EXIT reaper
}
reset_state() { : > "$STATE/daemon.log"; : > "$CURLLOG"; rm -f "$STATE/idle.since" "$STATE/engine.lock" "$DFCTL.count" "$STATE/nocomplete.count" "$STATE/last-gate" "$STATE/last-gate.log" "$STATE/gate-timeouts" "$STATE/STATUS.md" "$STATE/doc-budget-fix" "$STATE/doc-budget-tries" "$STATE/doc-budget-head"; }
stop() { kill -TERM "$1" 2>/dev/null; wait "$1" 2>/dev/null; }   # (dropped no-op `pkill -f provetest`; label is env, not argv)
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

echo "[23c] WS7 — the park note NAMES the failing step, and never sells a DOCUMENT failure as a code regression"
# 2026-08-06: the daemon parked with reader/notes/processor-build/coherence/tracker-sync/gui-vm ALL GREEN and
# `context-budget` the ONLY failing step (one execution plan 110% over its size budget) — and told the owner it
# was "a reproducible build/test regression" on "a broken tree". He went looking for a bug that did not exist.
# The step name was on disk the whole time, in the gate's own "HEALTH GATE: RED —<steps>" line; the note just
# never read it. The >=40 filler lines below are the crux: the gate prints that much AFTER its verdict, so the
# note's embedded `tail -25` can NEVER contain the verdict — which is why parsing it explicitly is the fix.
{ printf '#!/bin/sh\n'
  printf 'echo "  \xe2\x9c\x97 context-budget (rc=1)"\n'
  printf 'echo "HEALTH GATE: RED \xe2\x80\x94 context-budget"\n'
  printf 'echo "--- failing output (tail) ---"\n'
  printf 'i=0; while [ $i -lt 40 ]; do echo "filler line $i"; i=$((i+1)); done\n'
  printf 'echo "\xe2\x9c\x97 context-budget: OVER budget: execution-plans/despotlight.md"\n'
  printf 'exit 1\n'; } > "$T/gate-red-doc.sh"; chmod +x "$T/gate-red-doc.sh"
echo "0:yes" > "$CTRL"; write_plan; dfset 999999
L=$(GATE_EVERY=1 GATE_CMD="$T/gate-red-doc.sh" run_daemon 0 8)
grep -q 'PARKED (health gate RED (x2) — context-budget' "$L" && ok "park reason names the failing step" || bad "park reason is still anonymous"
grep -q 'NOTHING IS WRONG WITH THE CODE' "$L" && ok "a document RED is not sold as a code regression" || bad "document park still implies a code regression"
grep -q 'broken tree' "$L" && bad "still asserts a broken tree for a document-size failure" || ok "no broken-tree claim on a document RED"
grep -q 'despotlight' "$L" && ok "names the over-budget document" || bad "did not name the offending file"
grep -q 'context-budget.sh' "$L" && ok "points at that step's own remedy" || bad "no remedy pointer"
# …and a REAL code regression must KEEP the original wording. The fix must not launder a broken build.
{ printf '#!/bin/sh\necho "BUILD FAILED: boom in Reader"\n'
  printf 'echo "HEALTH GATE: RED \xe2\x80\x94 reader"\nexit 1\n'; } > "$T/gate-red-code.sh"; chmod +x "$T/gate-red-code.sh"
echo "0:yes" > "$CTRL"; write_plan; dfset 999999
L=$(GATE_EVERY=1 GATE_CMD="$T/gate-red-code.sh" run_daemon 0 8)
grep -q 'build/test regression' "$L" && ok "a real code RED still says regression" || bad "lost the code-regression wording on a real build failure"
grep -q 'PARKED (health gate RED (x2) — reader' "$L" && ok "code RED names its step too" || bad "code RED is still anonymous"
grep -q 'NOTHING IS WRONG WITH THE CODE' "$L" && bad "called a broken build a document problem" || ok "code RED not misfiled as a document problem"

echo "[23d] WS7 — a DOCUMENT-only RED must SELF-REPAIR (compact) and NOT park (owner, 2026-08-10)"
# "We don't want it to park when it hits the budget cap. We want it to fix itself." A document RED is a file
# that grew, not a regression — and the daemon already calls compact-plan.sh every cycle. Until now it parked
# and asked the owner to hand-run that same compactor. Root cause of the 2026-08-10 case: compact-plan's WQ
# pass had a 120 KB trigger the plan's own 180 KB budget could never let it reach, so the plan drifted to
# 108% and the gate parked with the fix sitting one unreachable threshold away.
# Gate stub: RED, RED, then GREEN — i.e. green only on the run that FOLLOWS the compaction.
# Count file baked in at write time (as gate-flaky.sh does) rather than passed through the environment —
# launch() rebuilds the daemon's env explicitly, so an inline VAR= on run_daemon is a fragile channel.
cat > "$T/gate-doc-then-green.sh" <<GDG
#!/bin/sh
c="$T/gdg.count"; n=\$(cat "\$c" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "\$c"
if [ "\$n" -ge 3 ]; then echo "gate ok after compaction"; exit 0; fi
echo "HEALTH GATE: RED — context-budget"
echo "✗ context-budget: OVER budget: .maintenance/AUTONOMOUS_PLAN.md"
exit 1
GDG
chmod +x "$T/gate-doc-then-green.sh"
# Compactor stub: records that it ran, so "self-repaired" can never be inferred from the log text alone.
printf '#!/bin/sh\necho "compact-plan: archived N lines"\necho ran >> "%s"\nexit 0\n' "$T/compacted.marker" > "$T/compactor.sh"
chmod +x "$T/compactor.sh"
rm -f "$T/gdg.count" "$T/compacted.marker"
echo "0:yes" > "$CTRL"; write_plan; dfset 999999
L=$(GATE_EVERY=1 GATE_CMD="$T/gate-doc-then-green.sh" COMPACTOR="$T/compactor.sh" run_daemon 0 10)
grep -q 'attempting SELF-REPAIR' "$L" && ok "a document-only RED triggers self-repair" || bad "no self-repair attempted on a document RED"
[ -f "$T/compacted.marker" ] && ok "the compactor actually RAN (marker written, not just logged)" || bad "compactor never executed"
grep -q 'GREEN after SELF-REPAIR' "$L" && ok "gate went green after the repair" || bad "did not recover after repair"
grep -q 'PARKED' "$L" && bad "PARKED despite repairing itself — the whole point was not to" || ok "did NOT park (fixed itself)"
[ -s "$STATE/last-gate" ] && ok "recorded last-gate after the self-repaired green" || bad "last-gate not recorded on a repaired green"

echo "[23e] WS7 — if self-repair does NOT clear it, still park, and SAY repair was tried"
# The note must not imply the owner has an unrun remedy available when the daemon already ran it.
rm -f "$T/compacted.marker"
echo "0:yes" > "$CTRL"; write_plan; dfset 999999
L=$(GATE_EVERY=1 GATE_CMD="$T/gate-red-doc.sh" COMPACTOR="$T/compactor.sh" run_daemon 0 10)
grep -q 'attempting SELF-REPAIR' "$L" && ok "tried to repair first" || bad "parked without trying"
grep -q 'STILL RED after self-repair' "$L" && ok "logged that the repair did not clear it" || bad "silent about the failed repair"
grep -q 'PARKED (health gate RED (x2) — context-budget' "$L" && ok "parks, still naming the failing step" || bad "park reason lost the step name"
grep -q 'self-repair attempted' "$L" && ok "the park note says repair was already attempted" || bad "note implies an unrun remedy"
grep -q 'NOTHING IS WRONG WITH THE CODE' "$L" && ok "still not sold as a code regression" || bad "document park implies a code bug again"

echo "[23f] WS7 — a CODE red must NEVER be self-repaired (compaction cannot fix a broken build)"
# Laundering a build failure through a compactor would be strictly worse than the bug this replaced.
rm -f "$T/compacted.marker"
echo "0:yes" > "$CTRL"; write_plan; dfset 999999
L=$(GATE_EVERY=1 GATE_CMD="$T/gate-red-code.sh" COMPACTOR="$T/compactor.sh" run_daemon 0 10)
grep -q 'SELF-REPAIR' "$L" && bad "attempted to compact away a BUILD failure" || ok "no self-repair on a code RED"
[ -f "$T/compacted.marker" ] && bad "ran the compactor for a broken build" || ok "compactor never invoked for code"
grep -q 'build/test regression' "$L" && ok "still reported as a regression" || bad "lost the regression wording"
grep -q 'PARKED (health gate RED (x2) — reader' "$L" && ok "parked on the code RED as before" || bad "code RED no longer parks"

echo "[23g] WS7 — a MIXED red (document + code) is treated as CODE: no repair, parks as a regression"
{ printf '#!/bin/sh\n'
  printf 'echo "HEALTH GATE: RED \xe2\x80\x94 context-budget reader"\n'
  printf 'echo "BUILD FAILED: boom"\nexit 1\n'; } > "$T/gate-red-mixed.sh"; chmod +x "$T/gate-red-mixed.sh"
rm -f "$T/compacted.marker"
echo "0:yes" > "$CTRL"; write_plan; dfset 999999
L=$(GATE_EVERY=1 GATE_CMD="$T/gate-red-mixed.sh" COMPACTOR="$T/compactor.sh" run_daemon 0 10)
grep -q 'SELF-REPAIR' "$L" && bad "self-repaired a mixed RED that includes a code failure" || ok "mixed RED is not self-repaired"
[ -f "$T/compacted.marker" ] && bad "compactor ran on a mixed RED" || ok "compactor not invoked on a mixed RED"
grep -q 'build/test regression' "$L" && ok "mixed RED keeps the conservative code wording" || bad "mixed RED misfiled as a document problem"

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

# ================= WS5 STATUS digest =================
echo "[27] WS5 — the daemon writes \$STATE/STATUS.md each cycle (and on park)"
echo "1:no" > "$CTRL"; write_plan; dfset 999999
L=$(run_daemon 0 6)
[ -s "$STATE/STATUS.md" ] && ok "STATUS.md written" || bad "STATUS.md not written"
grep -q 'STATUS-DIGEST-OK' "$STATE/STATUS.md" 2>/dev/null && ok "digest content present" || bad "digest content missing"

echo "[27b] WS5 — STATUS.md is refreshed on PARK, and the park flag reaches the digest (not stale 'running')"
echo "1:no" > "$CTRL"; write_plan; dfset 999999; rm -f "$STATE/STATUS.md"
L=$(run_daemon 5 22)
grep -q 'PARKED' "$L" && [ -s "$STATE/STATUS.md" ] && ok "STATUS.md refreshed at park" || bad "STATUS.md not refreshed on park"
grep -qE 'parked=.*(progress|blocked)' "$STATE/STATUS.md" 2>/dev/null && ok "park flag passed to the digest" || bad "park flag not passed ($(cat "$STATE/STATUS.md" 2>/dev/null | tr -d '\n'))"


# ================= WS13 — the DOC PRE-GATE (2026-08-12) =================
# WHY THESE EXIST. Until 2026-08-12 a document over budget went: gate RED -> retry the WHOLE gate -> run a
# compactor that could only ever fix ONE of the nine budgeted files -> gate a THIRD time -> PARK. It fired
# twice for real (2026-08-06 despotlight.md at 110%, 2026-08-12 CLAUDE.md at 107%) and the 2026-08-12 instance
# burned 61 minutes on three full build+test runs to rediscover a `wc -c` result. The pre-gate checks the
# budgets BEFORE the gate is launched and dispatches per FILE: the compactor for the one file it owns, and a
# bounded SESSION for everything else. It must never park on the first failure, and must still park eventually.
BUDGET_STUB="$T/budget-stub.sh"
# Stub protocol: reads $T/budget.state for the machine lines to emit, exits 1 if any OVER/TOTAL OVER is present.
cat > "$BUDGET_STUB" <<'BSTUB'
#!/bin/sh
s="$(cat "$BSTATE" 2>/dev/null)"
echo "  (stub context-budget report)"
printf '%s\n' "$s"
printf '%s' "$s" | grep -qE '^context-budget: (OVER|TOTAL OVER)' && exit 1
exit 0
BSTUB
chmod +x "$BUDGET_STUB"
bstate() { printf '%s\n' "$1" > "$T/budget.state"; }
# The stub needs $BSTATE in its env; launch() rebuilds the env explicitly, so bake the path in via a wrapper.
cat > "$T/budget-cmd.sh" <<WCMD
#!/bin/sh
BSTATE="$T/budget.state" exec "$BUDGET_STUB" "\$@"
WCMD
chmod +x "$T/budget-cmd.sh"
DOCFIX="$STATE/doc-budget-fix"

# ============================================================================================================
# WS13 doc pre-gate — REWRITTEN 2026-08-16 for the policy this suite had stopped matching (W32.prove-stale).
#
# On 2026-08-13 the owner made PER-FILE document budgets ADVISORY: only the per-session ORIENTATION TOTAL
# gates (`7311aff`). That commit updated context-budget.sh, health-gate.sh and prove-context-budget.sh — and
# NOT this file. So 28a-28f/28i went on driving per-file overages and asserting the retired per-file dispatch,
# and this suite sat at 114 passed / 19 FAILED on a clean tree from that day until now. Nothing caught it:
# prove-daemon.sh is one of two harnesses deliberately excluded from health-gate.sh (runtime, ~10 min), and
# README §"Regression suite" only tells a human to run it before a daemon change — at which point 19
# pre-existing failures make a NEW regression indistinguishable from the noise. That is the README's own
# "an unrun test is worse than no test" warning, realised.
#
# ⛔ DO NOT "fix" a failure here by re-arming per-file dispatch. The code is right; these tests were wrong.
#    doc_pregate() carries the same ⛔, and context-budget.sh:208 carries it for the exit code.
#
# THE POLICY THESE NOW ASSERT:
#   * a per-file OVER or NEAR is measured, LOGGED as advisory, and dispatches NOTHING;
#   * only `context-budget: TOTAL OVER` dispatches — compactor first (free, in-cycle), then a session;
#   * park remains the backstop, counted by HEAD moving, not by cycles.
# ============================================================================================================

echo "[28a] WS13 — a PER-FILE overage is ADVISORY: measured, logged, and it dispatches NOTHING (owner, 2026-08-13)"
# This is the de-gating itself. Three documents sit permanently at 92-99% of their per-file caps, so before
# 2026-08-13 the daemon handed sessions prose-shrinking instead of queue work every cycle forever — and one
# such trim deleted a whole policy section from AGENTS.md. DOCFIX_MAX=1 is the most hostile setting available:
# if anything dispatched, the park backstop would be reachable inside this window.
bstate "context-budget: OVER CLAUDE.md 25682 24000
context-budget: NEAR AGENTS.md 20811 21000
context-budget: TOTAL OK 434506 500000"
echo "0:yes" > "$CTRL"; write_plan; dfset 999999
# ⚠️ GATE_EVERY=0 deliberately. A per-file overage does not defer the gate (that is the point), so leaving a
# RED document gate armed here would park for the GATE — correct behaviour, but a different assertion, and it
# would mask what this case is actually about. The gate's own document handling is [23a-d]'s job.
L=$(GATE_EVERY=0 DOC_PREGATE=1 DOCFIX_MAX=1 BUDGET_CMD="$T/budget-cmd.sh" run_daemon 0 10)
grep -q 'per-file advisory' "$L" && ok "logged the per-file state as ADVISORY (still measured, still visible)" || bad "did not log the per-file advisory"
grep -q 'per-file caps do not gate work' "$L" && ok "the log says plainly that per-file caps do not gate" || bad "advisory line does not state the policy"
[ -f "$DOCFIX" ] && bad "queued a trim for a merely per-file overage — the 2026-08-13 de-gating is undone" || ok "wrote NO fix request (per-file does not dispatch)"
grep -q 'health gate DEFERRED' "$L" && bad "deferred the gate for a per-file overage" || ok "did not defer the gate"
grep -q 'PARKED' "$L" && bad "PARKED on a per-file overage, at DOCFIX_MAX=1" || ok "did not park"
grep -q 'launching fresh' "$L" && ok "got on with normal queue work instead" || bad "no session launched at all"

echo "[28b] WS13 — a TOTAL overage runs the compactor FIRST, in-cycle, with no session and no park"
# The mechanical remedy. ⚠️ The condition is the TOTAL being over and the plan being present — NOT the plan
# being over its own per-file cap. That widening is `b0dc76a`/`4784c09`: ORIENT_TOTAL (500,000) is deliberately
# TIGHTER than the sum of the per-file caps (518,000), so the total can be over while EVERY file is inside its
# own cap and $over_files is empty. The old test required a per-file plan overage, which is now the shape a
# total overage almost never has, so it was asserting a branch the daemon no longer takes.
printf '#!/bin/sh\nprintf "context-budget: TOTAL OK 1 2\\n" > "%s"\necho ran >> "%s"\nexit 0\n' \
  "$T/budget.state" "$T/compacted2.marker" > "$T/compactor2.sh"; chmod +x "$T/compactor2.sh"
rm -f "$T/compacted2.marker"
bstate "context-budget: WARN SUITE_TODO.md 200000 205000
context-budget: TOTAL OVER 520000 500000"
echo "0:yes" > "$CTRL"; write_plan; dfset 999999
L=$(GATE_EVERY=0 DOC_PREGATE=1 BUDGET_CMD="$T/budget-cmd.sh" COMPACTOR="$T/compactor2.sh" run_daemon 0 8)
# Assert the DISPATCH DECISION from the log: the between-cycles housekeeping compaction runs $COMPACTOR every
# cycle regardless, so a bare marker check would pass even if the pre-gate had done nothing — vacuously green.
grep -q 'orientation total over — running the plan compactor first' "$L" && ok "dispatched the compactor for a TOTAL overage" || bad "pre-gate never dispatched the compactor for a TOTAL overage"
[ -f "$T/compacted2.marker" ] && ok "…and the compactor really executed (marker written, not just logged)" || bad "compactor never executed"
grep -q 'fixed it itself' "$L" && ok "reported a genuine in-cycle self-heal" || bad "did not report self-healing"
[ -f "$DOCFIX" ] && bad "asked a session to fix what the compactor already fixed" || ok "no session hand-off needed"
grep -q 'PARKED' "$L" && bad "parked after successfully self-healing" || ok "did not park"

echo "[28c] WS13 — a TOTAL overage the compactor CANNOT fix is handed to a session, not parked"
# The compactor runs but does not bring the total under (it can only shrink AUTONOMOUS_PLAN.md; the growth may
# be anywhere). The remedy that CAN work is editorial, so it goes to the next session as its one bounded item.
printf '#!/bin/sh\necho ran >> "%s"\nexit 0\n' "$T/compacted3.marker" > "$T/compactor3.sh"; chmod +x "$T/compactor3.sh"
rm -f "$T/compacted3.marker"
bstate "context-budget: WARN SUITE_TODO.md 200000 205000
context-budget: TOTAL OVER 520000 500000"
echo "0:yes" > "$CTRL"; write_plan; dfset 999999
L=$(GATE_EVERY=1 GATE_CMD="$T/gate-red-doc.sh" DOC_PREGATE=1 DOCFIX_MAX=99 BUDGET_CMD="$T/budget-cmd.sh" COMPACTOR="$T/compactor3.sh" run_daemon 0 10)
grep -q 'handed the trim to the next session' "$L" && ok "handed the trim to a session once the free remedy failed" || bad "no session hand-off after the compactor failed to fix it"
[ -f "$DOCFIX" ] && ok "wrote the fix request a session reads ($DOCFIX)" || bad "no fix request written"
head -1 "$DOCFIX" 2>/dev/null | grep -q '^REQUIRED' && ok "the request is marked REQUIRED (the total IS over)" || bad "request not marked REQUIRED"
grep -q 'health gate DEFERRED' "$L" && ok "DEFERRED the expensive gate (it would RED on the doc being fixed)" || bad "ran the gate anyway — it will RED and park for the document"
grep -q 'launching fresh' "$L" && ok "still launched a session (the trim is the session's work)" || bad "no session launched, so nothing will do the trim"
grep -q 'PARKED' "$L" && bad "PARKED on the first total overage — WS13 exists so it does not" || ok "did NOT park on the first overage"
# …and the claim it must NOT make: this runs before any build, so it cannot speak to code health.
grep -q 'NOTHING IS WRONG WITH THE CODE' "$L" && bad "the pre-gate asserted the code is fine, having run no build at all" || ok "makes no unearned claim about the code"

echo "[28d] WS13 — NEAR dispatches NOTHING (the pre-emptive-trim case was RETIRED 2026-08-13)"
# ⛔ This asserts the ABSENCE of the old behaviour. NEAR used to queue a pre-emptive ADVISORY trim, which is
# precisely the mechanism the owner objected to: three documents sit permanently at 92-99%, so it asked every
# cycle forever. NEAR is still measured and logged; it must never dispatch again.
bstate "context-budget: NEAR SUITE_TODO.md 195000 205000
context-budget: TOTAL OK 434506 500000"
echo "0:yes" > "$CTRL"; write_plan; dfset 999999
L=$(GATE_EVERY=0 DOC_PREGATE=1 BUDGET_CMD="$T/budget-cmd.sh" run_daemon 0 8)
grep -q 'near=\[SUITE_TODO.md\]' "$L" && ok "NEAR is still MEASURED and logged (visibility kept)" || bad "NEAR no longer even reported"
[ -f "$DOCFIX" ] && bad "queued a pre-emptive trim for a NEAR — the retired behaviour is back" || ok "wrote no request for a NEAR"
grep -q 'health gate DEFERRED' "$L" && bad "deferred the gate for a file that is merely NEAR its budget" || ok "did not defer the gate on a NEAR"
grep -q 'PARKED' "$L" && bad "parked on a NEAR" || ok "did not park on a NEAR"

echo "[28e] WS13 — all clear CLEARS a satisfied request, so a fixed document cannot re-ask forever"
bstate "context-budget: TOTAL OK 100 500000"
echo "0:yes" > "$CTRL"; write_plan; dfset 999999
reset_state; printf 'REQUIRED\nFILES: CLAUDE.md\n' > "$DOCFIX"; echo 2 > "$STATE/doc-budget-tries"
P=$(GATE_EVERY=0 DOC_PREGATE=1 BUDGET_CMD="$T/budget-cmd.sh" launch 0); sleep 7; stop "$P"; L="$STATE/daemon.log"
[ -f "$DOCFIX" ] && bad "left a satisfied fix request in place — every future session would burn itself on it" || ok "cleared the satisfied request"
[ -f "$STATE/doc-budget-tries" ] && bad "left the attempt counter, so an unrelated later overage starts pre-charged toward a park" || ok "cleared the attempt counter"

echo "[28f] WS13 — PARK IS STILL THE BACKSTOP: after DOCFIX_MAX failed attempts it parks, and says both remedies were tried"
# Without this the daemon would queue a trim forever for a document no session can fix (usually a wrong budget).
# Driven by a TOTAL overage: since 2026-08-13 a per-file OVER dispatches nothing, so the old per-file fixture
# could never reach the backstop this case exists to prove (W32.prove-stale).
bstate "context-budget: WARN SUITE_TODO.md 200000 205000
context-budget: TOTAL OVER 520000 500000"
echo "0:yes" > "$CTRL"; write_plan; dfset 999999
printf '#!/bin/sh\nexit 0\n' > "$T/compactor-noop.sh"; chmod +x "$T/compactor-noop.sh"
L=$(GATE_EVERY=0 DOC_PREGATE=1 BUDGET_CMD="$T/budget-cmd.sh" DOCFIX_MAX=1 COMPACTOR="$T/compactor-noop.sh" run_daemon 0 14)
grep -q 'PARKED (documents over budget after 1 trim attempts' "$L" && ok "parks once the attempt cap is hit" || bad "never parked despite exceeding DOCFIX_MAX ($(grep -c 'handed the trim' "$L") hand-offs)"
grep -q 'compact-plan.sh ran (it can only shrink' "$L" && ok "the note says WHY the mechanical remedy could not help" || bad "note does not explain the compactor's scope"
grep -q 'BUDGET is wrong rather than the document' "$L" && ok "the note names the likeliest real cause after repeated failures" || bad "note offers no diagnosis"
grep -q 'context-budget.sh' "$L" && ok "points at the remedy + the derivation of the numbers" || bad "no pointer to context-budget.sh"

echo "[28h] WS13 — a TOTAL overage with NO per-file OVER still names something actionable"
# Rule 1 means the sum can exceed its budget while every individual file is inside its own — so the OVER list
# is legitimately EMPTY here and a naive "FILES: $over" hands a session a request naming nothing. Not
# hypothetical: growth projections on 2026-08-12 put the total at its budget in ~3 weeks (SUITE_TODO.md alone
# grows ~2.8 KB/day), so this is a path the daemon WILL take.
bstate "context-budget: WARN SUITE_TODO.md 200000 205000
context-budget: TOTAL OVER 520000 500000"
echo "0:yes" > "$CTRL"; write_plan; dfset 999999
L=$(GATE_EVERY=0 DOC_PREGATE=1 DOCFIX_MAX=99 BUDGET_CMD="$T/budget-cmd.sh" run_daemon 0 8)
[ -f "$DOCFIX" ] && ok "a total-only overage still produces a fix request" || bad "no request written for a total overage"
head -1 "$DOCFIX" 2>/dev/null | grep -q '^REQUIRED' && ok "marked REQUIRED (the gate will stay RED)" || bad "total overage not marked REQUIRED"
# The assertion that matters: the FILES line must never be empty.
grep -qE '^FILES: *$' "$DOCFIX" 2>/dev/null && bad "FILES: is EMPTY — the session is told to fix nothing in particular" || ok "FILES: names a target rather than being blank"
grep -q 'ORIENTATION TOTAL' "$DOCFIX" 2>/dev/null && ok "says it is the TOTAL, not one file" || bad "does not explain that the total is what is over"
grep -q 'SUITE_TODO.md' "$DOCFIX" 2>/dev/null && ok "points at a tracker, which is the report's own remedy" || bad "no tracker named as the target"
grep -q 'PARKED' "$L" && bad "parked on a total overage instead of queueing the trim" || ok "did not park"

echo "[28i] WS13 — THE LAPTOP CASE: sessions that commit nothing must NEVER push the run toward a park"
# Owner, 2026-08-12: "this is a laptop and I'm moving around throughout the day opening and closing the
# machine." A lid close kills the in-flight session. If an attempt were counted per CYCLE, $DOCFIX_MAX such
# cycles would park the run over a trim no session ever got a fair run at — a false park. An attempt is
# therefore counted only when HEAD MOVES. Here the stub commits NOTHING ("0:no"), which is what a killed
# session looks like from the outside, and DOCFIX_MAX is 1 — the most hostile setting available. It must
# still not park, however many cycles run.
# TOTAL overage, as [28f] — a per-file OVER no longer dispatches, so it could not exercise the counter.
bstate "context-budget: WARN SUITE_TODO.md 200000 205000
context-budget: TOTAL OVER 520000 500000"
echo "0:no" > "$CTRL"; write_plan; dfset 999999
L=$(GATE_EVERY=0 DOC_PREGATE=1 DOCFIX_MAX=1 BUDGET_CMD="$T/budget-cmd.sh" run_daemon 0 16)
grep -q 'PARKED' "$L" && bad "PARKED after cycles that committed nothing — a laptop lid close would now stop the run over an unattempted trim" || ok "does not park when no session ever committed"
grep -q 'not counting it' "$L" && ok "logged that an empty/killed session was NOT counted as an attempt" || bad "silently counted (or never re-checked) a session that did nothing"
[ "$(cat "$STATE/doc-budget-tries" 2>/dev/null)" = "1" ] && ok "the attempt counter stayed at 1 across several cycles" || bad "counter drifted to '$(cat "$STATE/doc-budget-tries" 2>/dev/null)' without any commit"
# …and the contrast is [28f], where sessions DO commit: there HEAD moves, attempts count, and it parks.

echo "[28g] WS13 — the pre-gate can be turned OFF, and then the old gate path is untouched"
# A TOTAL overage, i.e. a state that WOULD dispatch — otherwise "disabled" proves nothing, because a per-file
# overage dispatches nothing even when the pre-gate is ON (W32.prove-stale).
bstate "context-budget: TOTAL OVER 520000 500000"
echo "0:yes" > "$CTRL"; write_plan; dfset 999999
L=$(GATE_EVERY=0 DOC_PREGATE=0 BUDGET_CMD="$T/budget-cmd.sh" run_daemon 0 6)
grep -q 'doc pre-gate' "$L" && bad "the pre-gate ran with AUTONOMOUS_DOC_PREGATE=0" || ok "AUTONOMOUS_DOC_PREGATE=0 disables it completely"
[ -f "$DOCFIX" ] && bad "wrote a fix request while disabled" || ok "writes nothing while disabled"

echo
echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" = 0 ]
