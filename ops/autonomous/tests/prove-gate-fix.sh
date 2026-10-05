#!/usr/bin/env bash
# prove-gate-fix.sh — a red health gate goes to a fix SESSION before it may park (owner, 2026-10-05).
#
# WHAT IT PROVES, against the real daemon with a stub gate and a stub claude:
#   [1] a code red that survives the retry writes $STATE/gate-fix, does NOT park, and launches a session that
#       finds the request waiting for it;
#   [2] the next GREEN gate retires the request and its attempt count;
#   [3] a fix session that commits and leaves the gate red counts an attempt, and the run parks only after
#       AUTONOMOUS_GATEFIX_MAX of them;
#   [4] a fix session that commits nothing does not burn an attempt.
# Sandboxed like prove-daemon.sh: own HOME, STATE and git REPO; host commands stubbed.
set -uo pipefail
unset AUTONOMOUS_AGENT

HERE="$(cd "$(dirname "$0")" && pwd)"
DAEMON="${1:-$HERE/../archive-suite-autonomous.sh}"
[ -f "$DAEMON" ] || { echo "no daemon at $DAEMON"; exit 2; }
T="$(mktemp -d)"
reap() {
  [ -f "$T/daemon.pids" ] || return 0
  while read -r p; do case "$(ps -p "$p" -o command= 2>/dev/null)" in *"$DAEMON"*) kill -9 "$p" 2>/dev/null ;; esac; done < "$T/daemon.pids"
}
trap 'reap; rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

export HOME="$T/home"; mkdir -p "$HOME/Desktop" "$HOME/.local/bin"
BIN="$T/bin"; mkdir -p "$BIN"
for c in security osascript launchctl caffeinate curl; do printf '#!/bin/sh\nexit 0\n' > "$BIN/$c"; chmod +x "$BIN/$c"; done
cat > "$BIN/df" <<'STUB'
#!/bin/sh
echo "Filesystem 1M-blocks Used Available Capacity iused ifree %iused Mounted on"
echo "/dev/disk1 1000000 1000 999999 1% 1 1 0% /"
STUB
chmod +x "$BIN/df"
export PATH="$BIN:$PATH"

REPO="$T/repo with space"; mkdir -p "$REPO"
git -C "$REPO" init -q; git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo seed > "$REPO/f"; printf -- '- [ ] todo one\n' > "$REPO/SUITE_TODO.md"
git -C "$REPO" add -A; git -C "$REPO" commit -qm seed
git -C "$REPO" branch -f main 2>/dev/null; git -C "$REPO" update-ref refs/remotes/origin/main HEAD
PLAN="$T/plan.md"
printf 'RUN STATUS: IN_PROGRESS — test\n\n## WORK QUEUE (priority order)\n- [ ] item one\n\n## Session Log\n' > "$PLAN"
STATE="$T/state"; mkdir -p "$STATE"
printf 'autonomous maintenance session for the Archive Suite (prove-gate-fix fixture prompt)\n' > "$STATE/resume-prompt.txt"

# The stub gate: $GATECTL holds "red" or "green". A red prints the verdict line the daemon classifies, naming a
# step this file's own fake health-gate defines, so the request can carry the step's command.
GATECTL="$T/gatectl"; GATE="$T/health-gate.sh"
cat > "$GATE" <<STUB
#!/bin/bash
# step notes-ui bash ops/gui/vm-gui-runner.sh notes xcuitest
if [ "\$(cat "$GATECTL")" = red ]; then echo "── notes-ui ──"; echo "  ✗ notes-ui (rc=1)"; echo "HEALTH GATE: RED — notes-ui"; exit 1; fi
echo "HEALTH GATE: GREEN"; exit 0
STUB
chmod +x "$GATE"
# The fake gate script also needs the `step` line the request quotes, at line start:
printf 'step notes-ui bash ops/gui/vm-gui-runner.sh notes xcuitest\n' >> "$GATE"

# The stub claude: records whether the request was there, and commits when $SESSCTL says so.
SESSCTL="$T/sessctl"; SEEN="$T/seen"
cat > "$T/claude" <<STUB
#!/bin/bash
[ -f "$STATE/gate-fix" ] && { echo "saw-request" >> "$SEEN"; cp "$STATE/gate-fix" "$T/request.copy"; }
if [ "\$(cat "$SESSCTL")" = commit ]; then echo "\$(date +%s%N)" > "$REPO/f"; git -C "$REPO" add -A; git -C "$REPO" commit -qm fix; fi
exit 0
STUB
chmod +x "$T/claude"
printf '#!/bin/sh\necho STATUS-OK\n' > "$T/status-stub.sh"; chmod +x "$T/status-stub.sh"

launch() {
  env AUTONOMOUS_LABEL=provegatefix AUTONOMOUS_REPO="$REPO" AUTONOMOUS_PLAN="$PLAN" AUTONOMOUS_STATE="$STATE" \
    AUTONOMOUS_CLAUDE="$T/claude" AUTONOMOUS_INTERVAL=1 AUTONOMOUS_MAXBACKOFF=2 AUTONOMOUS_IDLE_STOP=0 \
    AUTONOMOUS_MAX_NOCOMPLETE=0 AUTONOMOUS_GATE_EVERY=1 AUTONOMOUS_GATE_CMD="$GATE" AUTONOMOUS_GATE_MAXRUN=30 \
    AUTONOMOUS_GATEFIX_MAX="${GFMAX:-3}" AUTONOMOUS_STATUS_CMD="$T/status-stub.sh" AUTONOMOUS_COMPACTOR="$T/none" \
    AUTONOMOUS_DOC_PREGATE=0 AUTONOMOUS_BUDGET_CMD="$T/none" AUTONOMOUS_HB_POLL=1 AUTONOMOUS_YIELD_CMD="$T/no-yield" \
    AUTONOMOUS_USAGE_CMD="$HERE/../usage-window.sh" AUTONOMOUS_WINDOW_POLL=1 \
    bash "$DAEMON" >"$T/daemon.out" 2>&1 &
  local pid=$!; echo "$pid" >> "$T/daemon.pids"; echo "$pid"
}
stop() { kill -TERM "$1" 2>/dev/null; wait "$1" 2>/dev/null; sleep 0.3; }
reset() { : > "$STATE/daemon.log"; rm -f "$STATE"/gate-fix* "$STATE/last-gate" "$STATE/last-gate.log" "$STATE/idle.since" \
          "$STATE/engine.lock" "$SEEN" "$T/request.copy" "$HOME/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt"; }
L="$STATE/daemon.log"

echo "[1] a code red that survives the retry goes to a fix session, not a park"
reset; echo red > "$GATECTL"; echo commit > "$SESSCTL"; P=$(launch); sleep 6; stop "$P"
grep -q 'gate fix: handed the failing gate step(s) (notes-ui)' "$L" && ok "handed to a session" || bad "not handed: $(grep -E 'gate|PARK' "$L" | tail -3)"
grep -q 'PARKED' "$L" && bad "parked on the first red" || ok "did not park"
[ -s "$SEEN" ] && ok "the session found the request waiting" || bad "the session never saw the request"
grep -q 'notes-ui: step notes-ui bash ops/gui/vm-gui-runner.sh notes xcuitest' "$T/request.copy" 2>/dev/null \
  && ok "the request names the step's own command" || bad "request lacks the step command: $(head -6 "$T/request.copy" 2>/dev/null)"
grep -q 'HEALTH GATE: RED — notes-ui' "$T/request.copy" 2>/dev/null && ok "the request carries the log's tail" || bad "no log tail in the request"

echo "[2] the next GREEN gate retires the request"
echo green > "$GATECTL"; echo none > "$SESSCTL"; P=$(launch); sleep 5; stop "$P"
grep -q 'gate fix: the gate is GREEN — the fix request is retired' "$L" && ok "retired on green" || bad "not retired: $(tail -4 "$L")"
[ ! -f "$STATE/gate-fix" ] && [ ! -f "$STATE/gate-fix-tries" ] && ok "request and count removed" || bad "request or count left behind"

echo "[3] committed fixes that leave it red count, and the run parks after GATEFIX_MAX of them"
reset; echo red > "$GATECTL"; echo commit > "$SESSCTL"; P=$(GFMAX=2 launch); sleep 26; stop "$P"
grep -q 'attempt 1/2' "$L" && grep -q 'attempt 2/2' "$L" && ok "two attempts handed over" || bad "attempts: $(grep -o 'attempt [0-9]/[0-9]' "$L" | tr '\n' ' ')"
grep -q 'PARKED' "$L" && ok "parked after the attempts were spent" || bad "never parked: $(grep -E 'gate fix|PARK' "$L" | tail -3)"
grep -q 'fix sessions committed changes and the gate is still red' "$HOME/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt" 2>/dev/null \
  && ok "the park note says fix sessions were tried" || bad "park note does not say so"

echo "[4] a fix session that commits nothing does not burn an attempt"
reset; echo red > "$GATECTL"; echo none > "$SESSCTL"; P=$(GFMAX=1 launch); sleep 20; stop "$P"
grep -q 'no commit since the last fix attempt — not counting it' "$L" && ok "an empty session is not counted" || bad "not reported: $(grep 'gate fix' "$L" | tail -2)"
grep -q 'PARKED' "$L" && bad "parked although no fix was attempted" || ok "no park without a committed attempt"

echo ""
echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" = 0 ]
