#!/usr/bin/env bash
# prove-exit-logging.sh — prove the daemon says WHY it exited (added 2026-07-29).
#
# WHY THIS EXISTS. Before the change under test, only the normal loop exit logged "=== daemon down ===";
# `trap 'exit 0' TERM INT` exited immediately, so a SIGTERM logged NOTHING. SIGTERM is exactly what launchd
# sends on bootout/logout/shutdown — i.e. what effectively happens when this laptop's lid closes. So a
# perfectly ordinary overnight shutdown was indistinguishable from a crash, and on 2026-07-29 that produced a
# wrong "reproducible code failure" diagnosis. This harness pins the fix.
#
# It runs the REAL daemon, fully sandboxed via the AUTONOMOUS_* overrides (throwaway $HOME, $STATE, repo,
# plan, and a FAKE `claude` that never spends a cent). It never touches ~/.local/state/archive-autonomous,
# the real repo, or the real launchd job. Safe to run anytime. Run interactively.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DAEMON="$HERE/../archive-suite-autonomous.sh"
[ -f "$DAEMON" ] || { echo "cannot find daemon at $DAEMON" >&2; exit 1; }

T="$(mktemp -d)"
reap() { while read -r p; do kill -9 "$p" 2>/dev/null; done < "$T/daemon.pids" 2>/dev/null; }
trap 'reap; rm -rf "$T"' EXIT
: > "$T/daemon.pids"
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# ---- sandbox (mirrors prove-daemon.sh) -----------------------------------------------------------------
export HOME="$T/home"; mkdir -p "$HOME/Desktop" "$HOME/.local/bin"
BIN="$T/bin"; mkdir -p "$BIN"
for c in osascript launchctl caffeinate; do printf '#!/bin/sh\nexit 0\n' > "$BIN/$c"; chmod +x "$BIN/$c"; done
# `security` is scriptable: $SECOUT holds what it prints. Empty => taskport reminder finds no 'allow' and bails.
SECOUT="$T/secout"; : > "$SECOUT"
cat > "$BIN/security" <<STUB
#!/bin/sh
cat "$SECOUT" 2>/dev/null
exit 0
STUB
chmod +x "$BIN/security"
printf '#!/bin/sh\nexit 0\n' > "$BIN/curl"; chmod +x "$BIN/curl"
cat > "$BIN/df" <<'STUB'
#!/bin/sh
echo "Filesystem 1M-blocks Used Available Capacity iused ifree %iused Mounted on"
echo "/dev/disk1 1000000 100000 900000 11% 1 1 0% /"
STUB
chmod +x "$BIN/df"
export PATH="$BIN:$PATH"

REPO="$T/repo with space"; mkdir -p "$REPO"      # space in path: mirrors "<repo with a space in its path>"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo seed > "$REPO/f"; printf -- '- [ ] todo one\n' > "$REPO/SUITE_TODO.md"
git -C "$REPO" add -A; git -C "$REPO" commit -qm seed
git -C "$REPO" branch -f main 2>/dev/null; git -C "$REPO" update-ref refs/remotes/origin/main HEAD

PLAN="$T/plan.md"
write_plan() {   # $1 = RUN STATUS value
  cat > "$PLAN" <<EOF
RUN STATUS: ${1:-IN_PROGRESS} — test

## WORK QUEUE (priority order)
- [ ] item one

## Session Log
EOF
}
STATE="$T/state"; mkdir -p "$STATE"
# The L2 resume prompt. daemon.sh renders this into $STATE before launching, so production never runs without
# one — but this harness never seeded it and the daemon never checked, so the suite exercised a state the real
# system cannot be in. The daemon now refuses to start without one (W32.preflight-gap). Stub claude ignores it.
printf 'autonomous maintenance session for the Archive Suite (prove-exit-logging fixture prompt)\n' > "$STATE/resume-prompt.txt"
# Fake claude: sleeps so a session is genuinely IN FLIGHT when we signal the daemon (that is the case that
# used to vanish silently, and it is what leaves a stale engine.lock behind).
cat > "$T/claude" <<STUB
#!/usr/bin/env bash
sleep "\${FAKE_CLAUDE_SLEEP:-30}"
exit 0
STUB
chmod +x "$T/claude"
printf '#!/bin/sh\necho "STATUS-OK"\n' > "$T/status-stub.sh"; chmod +x "$T/status-stub.sh"

launch() {
  AUTONOMOUS_LABEL=provetest AUTONOMOUS_REPO="$REPO" AUTONOMOUS_PLAN="$PLAN" \
  AUTONOMOUS_STATE="$STATE" AUTONOMOUS_CLAUDE="$T/claude" \
  AUTONOMOUS_INTERVAL=1 AUTONOMOUS_MAXBACKOFF=4 AUTONOMOUS_IDLE_STOP=0 \
  AUTONOMOUS_MINFREE_MB=10 AUTONOMOUS_MAX_NOCOMPLETE=0 \
  AUTONOMOUS_GATE_EVERY=0 AUTONOMOUS_GATE_CMD=/bin/true \
  AUTONOMOUS_STATUS_CMD="$T/status-stub.sh" AUTONOMOUS_HB_POLL=1 \
    bash "$DAEMON" >/dev/null 2>&1 &
  local pid=$!; echo "$pid" >> "$T/daemon.pids"; echo "$pid"
}
LOG="$STATE/daemon.log"
reset() { : > "$LOG"; rm -f "$STATE/engine.lock" "$STATE/idle.since" "$STATE/STATUS.md"; : > "$SECOUT"; rm -f "$HOME/Desktop/REVERT-TASKPORT-SECURITY.txt"; }
downlines() { grep -c 'daemon down' "$LOG" 2>/dev/null | tr -d ' '; }
waitfor() { local n=0; while [ "$n" -lt 60 ]; do grep -q "$1" "$LOG" 2>/dev/null && return 0; sleep 0.2; n=$((n+1)); done; return 1; }
# Wait for a daemon pid to actually be gone. NOTE: plain `wait "$p"` does NOT work here — launch() runs inside
# a command substitution, so the daemon is a child of THAT subshell, not of this shell, and `wait` on a
# non-child returns immediately. Every assertion that counted log lines straight after a `wait` was therefore
# racing the daemon's EXIT trap; the SIGTERM case had no sleep cushion either and false-failed ~4 runs in 6
# ("expected 1 'daemon down' line, got 1" — the count changed between the test and the error message).
waitgone() { local n=0; while kill -0 "$1" 2>/dev/null && [ "$n" -lt 80 ]; do sleep 0.2; n=$((n+1)); done; }

echo "prove-exit-logging — the daemon must say WHY it exited"

# ---- 1. SIGTERM (the lid-close / launchd-bootout case) -------------------------------------------------
reset; write_plan IN_PROGRESS
p=$(launch)
if waitfor "launching fresh resume session"; then
  kill -TERM "$p" 2>/dev/null; waitgone "$p"; waitfor "daemon down"
  if [ "$(downlines)" = "1" ]; then ok "SIGTERM logs exactly ONE 'daemon down' line"; else bad "SIGTERM: expected 1 'daemon down' line, got $(downlines)"; fi
  if grep -q 'reason: SIGTERM' "$LOG"; then ok "SIGTERM names itself in the reason"; else bad "SIGTERM reason missing; log: $(grep 'daemon down' "$LOG" || echo '<none>')"; fi
  if grep -q 'lid closing' "$LOG"; then ok "SIGTERM reason mentions the lid/shutdown interpretation"; else bad "SIGTERM reason lacks the lid/shutdown hint"; fi
  if grep -qE 'session-in-flight=YES' "$LOG"; then ok "records that a resume session was in flight (stale-lock cause)"; else bad "session-in-flight not YES while a session was running"; fi
  if grep -qE 'uptime=[0-9]+s' "$LOG"; then ok "records uptime"; else bad "uptime missing"; fi
else
  bad "daemon never launched a session (harness problem)"
fi

# ---- 2. normal terminal exit (rc 9) -------------------------------------------------------------------
reset; write_plan COMPLETE
p=$(launch)
n=0; while kill -0 "$p" 2>/dev/null && [ "$n" -lt 80 ]; do sleep 0.2; n=$((n+1)); done
if kill -0 "$p" 2>/dev/null; then
  bad "daemon did not self-exit on RUN STATUS: COMPLETE (harness problem)"; kill -9 "$p" 2>/dev/null
else
  if [ "$(downlines)" = "1" ]; then ok "normal exit logs exactly ONE 'daemon down' line (no double-log)"; else bad "normal exit: expected 1 line, got $(downlines)"; fi
  # W32.park-reason — the terminal paths now name their ACTUAL cause instead of the generic catch-all. This
  # scenario drives RUN STATUS: COMPLETE, so the reason must say so. It used to read "fell out of the main
  # loop (rc 9 — RUN STATUS: COMPLETE, or parked)", which lumped two very different endings together; worse,
  # a PARK never reached it at all, because park_run's `launchctl bootout` SIGTERMs the daemon and the TERM
  # trap overwrote the reason — so every park on record was logged as "the laptop lid closing". Accept either
  # specific terminal wording, and still refuse the signal wording (asserted separately below).
  if grep -qE 'RUN STATUS: COMPLETE — the run finished its queue|PARKED \(|fell out of the main loop' "$LOG"; then
    ok "normal exit names the loop-exit reason"
  else bad "normal-exit reason missing; got: $(grep 'daemon down' "$LOG" || echo '<none>')"; fi
  if grep -q 'reason: SIGTERM' "$LOG"; then bad "normal exit wrongly blamed SIGTERM"; else ok "normal exit does NOT blame a signal"; fi
fi

# ---- 3. SIGKILL — untrappable, and that absence is itself the diagnostic ------------------------------
reset; write_plan IN_PROGRESS
p=$(launch)
if waitfor "launching fresh resume session"; then
  kill -9 "$p" 2>/dev/null; waitgone "$p"; sleep 0.5
  if [ "$(downlines)" = "0" ]; then ok "SIGKILL logs NOTHING (documents the untrappable case)"; else bad "SIGKILL somehow logged $(downlines) line(s)"; fi
  if grep -q 'daemon up' "$LOG"; then ok "'daemon up' with no 'daemon down' = the hard-kill signature"; else bad "no 'daemon up' line to pair against"; fi
else
  bad "daemon never launched a session (harness problem)"
fi

# ---- 4. REGRESSION: the EXIT trap still fires the taskport security reminder --------------------------
# _log_exit now calls remind_revert_taskport; if that call were dropped, a real standing security exposure
# would silently stop being reported. Script `security` to report the rule as 'allow' and assert the file.
reset; write_plan IN_PROGRESS
printf '<string>allow</string>\n' > "$SECOUT"
p=$(launch)
if waitfor "launching fresh resume session"; then
  kill -TERM "$p" 2>/dev/null; waitgone "$p"; sleep 0.3
  if [ -f "$HOME/Desktop/REVERT-TASKPORT-SECURITY.txt" ]; then ok "taskport reminder still fires from the EXIT trap"; else bad "taskport reminder LOST — remind_revert_taskport no longer runs on exit"; fi
  if grep -q 'reason: SIGTERM' "$LOG"; then ok "reason still logged alongside the reminder"; else bad "reason missing on the reminder path"; fi
else
  bad "daemon never launched a session (harness problem)"
fi

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
