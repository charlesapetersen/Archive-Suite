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
# shellcheck disable=SC2015 # ok/bad always return success; assertion chains are intentional.
set -uo pipefail
unset AUTONOMOUS_AGENT

HERE="$(cd "$(dirname "$0")" && pwd)"
DAEMON="${1:-$HERE/../archive-suite-autonomous.sh}"
[ -f "$DAEMON" ] || { echo "no daemon at $DAEMON"; exit 2; }
T="$(mktemp -d)"
# Monitor mode gives every directly launched fixture its own process group, including its session and
# watchdog descendants. Only groups verified at launch are recorded for cleanup.
set -m
FIXTURE_PIDS=()
group_alive() {
  ps -ax -o pgid= | awk -v group="$1" '$1 == group { found=1 } END { exit !found }'
}
stop() {
  local pid="$1" n=0 state
  kill -TERM -- "-$pid" 2>/dev/null || true
  while [ "$n" -lt 20 ]; do
    state="$(ps -p "$pid" -o stat= 2>/dev/null)"
    case "$state" in ''|*Z*) break ;; esac
    sleep 0.1; n=$((n+1))
  done
  # TERM can exit the daemon during a session, leaving heartbeat/watchdog children alive. Reap the entire
  # owned group before resetting scratch state, including on harness interruption.
  kill -KILL -- "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  n=0
  while group_alive "$pid" && [ "$n" -lt 20 ]; do sleep 0.1; n=$((n+1)); done
  if group_alive "$pid"; then
    echo "fixture process group $pid survived cleanup; scratch state retained at $T" >&2
    return 1
  fi
  for n in "${!FIXTURE_PIDS[@]}"; do
    [ "${FIXTURE_PIDS[$n]}" = "$pid" ] && unset 'FIXTURE_PIDS[n]'
  done
  return 0
}
cleanup() {
  local pid
  for pid in "${FIXTURE_PIDS[@]+"${FIXTURE_PIDS[@]}"}"; do stop "$pid" || return 1; done
  python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$T"
}
fixture_rc=0
trap 'fixture_rc=$?; cleanup || fixture_rc=1; exit "$fixture_rc"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

FIXTURE_HOME="$T/home"; mkdir -p "$FIXTURE_HOME/Desktop" "$FIXTURE_HOME/.local/bin"
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
saw_request=0
[ -f "$STATE/gate-fix" ] && { cp "$STATE/gate-fix" "$T/request.copy" && saw_request=1; }
if [ "\$(cat "$SESSCTL")" = commit ]; then
  n=\$(cat "$T/commits" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$T/commits"
  echo "fix \$n" > "$REPO/f"; git -C "$REPO" add -A && git -C "$REPO" commit -qm fix || exit 1
fi
[ "\$saw_request" = 1 ] && echo "saw-request" >> "$SEEN"
# Optional RED-to-GREEN scheduling stress: keep the first session in flight after it saw the request.
sleep "\${GATEFIX_FIXTURE_DELAY:-0}"
exit 0
STUB
chmod +x "$T/claude"
printf '#!/bin/sh\necho STATUS-OK\n' > "$T/status-stub.sh"; chmod +x "$T/status-stub.sh"

launch() {
  env -u BASH_ENV -u SHELLOPTS HOME="$FIXTURE_HOME" GATEFIX_FIXTURE_DELAY="${1:-0}" AUTONOMOUS_LABEL=provegatefix AUTONOMOUS_REPO="$REPO" AUTONOMOUS_PLAN="$PLAN" AUTONOMOUS_STATE="$STATE" \
    AUTONOMOUS_CLAUDE="$T/claude" AUTONOMOUS_INTERVAL=1 AUTONOMOUS_MAXBACKOFF=2 AUTONOMOUS_IDLE_STOP=0 \
    AUTONOMOUS_MAX_NOCOMPLETE=0 AUTONOMOUS_GATE_EVERY=1 AUTONOMOUS_GATE_CMD="$GATE" AUTONOMOUS_GATE_MAXRUN=30 \
    AUTONOMOUS_GATEFIX_MAX="${GFMAX:-3}" AUTONOMOUS_STATUS_CMD="$T/status-stub.sh" AUTONOMOUS_COMPACTOR="$T/none" \
    AUTONOMOUS_DOC_PREGATE=0 AUTONOMOUS_BUDGET_CMD="$T/none" AUTONOMOUS_HB_POLL=1 AUTONOMOUS_YIELD_CMD="$T/no-yield" \
    AUTONOMOUS_USAGE_CMD="$HERE/../usage-window.sh" AUTONOMOUS_WINDOW_POLL=1 \
    bash "$DAEMON" >"$T/daemon.out" 2>&1 &
  P=$!
  if [ "$(ps -p "$P" -o pgid= | tr -d ' ')" != "$P" ]; then
    echo "fixture $P has no isolated process group" >&2
    kill -TERM "$P" 2>/dev/null; wait "$P" 2>/dev/null
    exit 1
  fi
  FIXTURE_PIDS+=("$P")
}
reset() { : > "$STATE/daemon.log"; rm -f "$STATE"/gate-fix* "$STATE/last-gate" "$STATE/last-gate.log" "$STATE/idle.since" \
          "$STATE/engine.lock" "$SEEN" "$T/request.copy" "$FIXTURE_HOME/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt"; }
L="$STATE/daemon.log"
# Observe the event under test, rather than sampling at an arbitrary sleep boundary. A missing event still
# fails the original assertions; the deadline only bounds a broken fixture (same 30 s as the stub gate cap).
await_condition() {
  local deadline=$((SECONDS+30))
  while [ "$SECONDS" -lt "$deadline" ]; do
    "$@" && return 0
    kill -0 "$P" 2>/dev/null || break
    sleep 0.1
  done
  return 1
}
await_event() { await_condition grep -q "$1" "${2:-$L}" 2>/dev/null; }
retired() {
  grep -q 'gate fix: the gate is GREEN — the fix request is retired' "$L" &&
    [ ! -f "$STATE/gate-fix" ] && [ ! -f "$STATE/gate-fix-tries" ] && [ ! -f "$STATE/gate-fix-head" ]
}
two_sessions() {
  local n; n="$(grep -c saw-request "$SEEN" 2>/dev/null || true)"
  [ "${n:-0}" -ge 2 ]
}

echo "[1] a code red that survives the retry goes to a fix session, not a park"
reset; echo red > "$GATECTL"; echo commit > "$SESSCTL"; launch "${GATEFIX_FIXTURE_DELAY:-0}"
await_event saw-request "$SEEN" || true
grep -q 'gate fix: handed the failing gate step(s) (notes-ui)' "$L" && ok "handed to a session" || bad "not handed: $(grep -E 'gate|PARK' "$L" | tail -3)"
grep -q 'PARKED' "$L" && bad "parked on the first red" || ok "did not park"
[ -s "$SEEN" ] && ok "the session found the request waiting" || bad "the session never saw the request"
grep -q 'notes-ui: step notes-ui bash ops/gui/vm-gui-runner.sh notes xcuitest' "$T/request.copy" 2>/dev/null \
  && ok "the request names the step's own command" || bad "request lacks the step command: $(head -6 "$T/request.copy" 2>/dev/null)"
grep -q 'HEALTH GATE: RED — notes-ui' "$T/request.copy" 2>/dev/null && ok "the request carries the log's tail" || bad "no log tail in the request"

echo "[2] the next GREEN gate retires the request"
# Keep the SAME fixture alive: SIGTERM during [1]'s session intentionally leaves engine.lock behind in
# production. Restarting immediately tested that stale lock, not whether the next GREEN gate retires a fix.
echo green > "$GATECTL"; echo none > "$SESSCTL"
await_condition retired || true
stop "$P" || exit 1
grep -q 'gate fix: the gate is GREEN — the fix request is retired' "$L" && ok "retired on green" || bad "not retired: $(tail -4 "$L")"
[ ! -f "$STATE/gate-fix" ] && [ ! -f "$STATE/gate-fix-tries" ] && [ ! -f "$STATE/gate-fix-head" ] && ok "request and count removed" || bad "request or count left behind"

echo "[3] committed fixes that leave it red count, and the run parks after GATEFIX_MAX of them"
reset; echo red > "$GATECTL"; echo commit > "$SESSCTL"; GFMAX=2 launch
await_event 'fix sessions committed changes and the gate is still red' "$FIXTURE_HOME/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt" || true
stop "$P" || exit 1
grep -q 'attempt 1/2' "$L" && grep -q 'attempt 2/2' "$L" && ok "two attempts handed over" || bad "attempts: $(grep -o 'attempt [0-9]/[0-9]' "$L" | tr '\n' ' ')"
grep -q 'PARKED' "$L" && ok "parked after the attempts were spent" || bad "never parked: $(grep -E 'gate fix|PARK' "$L" | tail -3)"
grep -q 'fix sessions committed changes and the gate is still red' "$FIXTURE_HOME/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt" 2>/dev/null \
  && ok "the park note says fix sessions were tried" || bad "park note does not say so"

echo "[4] a fix session that commits nothing does not burn an attempt"
reset; echo red > "$GATECTL"; echo none > "$SESSCTL"; GFMAX=1 launch
await_condition two_sessions || true
stop "$P" || exit 1
grep -q 'no commit since the last fix attempt — not counting it' "$L" && ok "an empty session is not counted" || bad "not reported: $(grep 'gate fix' "$L" | tail -2)"
grep -q 'PARKED' "$L" && bad "parked although no fix was attempted" || ok "no park without a committed attempt"
two_sessions && ok "an empty fix session is offered another attempt" || bad "empty session was not offered another attempt"
[ "$(cat "$STATE/gate-fix-tries" 2>/dev/null)" = 1 ] && ok "empty sessions leave the attempt count at one" || bad "empty session changed the attempt count"

echo ""
echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" = 0 ]
