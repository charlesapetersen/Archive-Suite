#!/usr/bin/env bash
# Source only, after creating scratch $T. Launch directly, never through $(...), so the harness owns/waits
# its children. Monitor mode assigns each fixture and all its descendants a separate process group.
set -m
FIXTURE_PIDS=()
fixture_rc=0
FIXTURE_LAUNCHING=0
FIXTURE_SIGNAL=0
fixture_group_alive() {
  ps -ax -o pgid= | awk -v group="$1" '$1 == group { found=1 } END { exit !found }'
}
fixture_launch() {
  FIXTURE_LAUNCHING=1
  "$@" &
  P=$!
  FIXTURE_PIDS+=("$P")
  FIXTURE_LAUNCHING=0
  [ "$FIXTURE_SIGNAL" = 0 ] || exit "$FIXTURE_SIGNAL"
  if [ "$(ps -p "$P" -o pgid= | tr -d ' ')" != "$P" ]; then
    # A fast refusal can already have exited; retain its wait status for the caller.
    if ! kill -0 "$P" 2>/dev/null; then return 0; fi
    echo "fixture $P has no isolated process group" >&2
    kill -TERM "$P" 2>/dev/null || true
    wait "$P" 2>/dev/null || true
    exit 1
  fi
  return 0
}
stop() {
  local pid="$1" n=0 state owned=0
  for n in "${FIXTURE_PIDS[@]+"${FIXTURE_PIDS[@]}"}"; do [ "$n" = "$pid" ] && owned=1; done
  [ "$owned" = 1 ] || { echo "refusing to stop unowned fixture $pid" >&2; return 1; }
  kill -TERM -- "-$pid" 2>/dev/null || true
  n=0
  while [ "$n" -lt 20 ]; do
    state="$(ps -p "$pid" -o stat= 2>/dev/null)"
    case "$state" in ''|*Z*) break ;; esac
    sleep 0.1; n=$((n+1))
  done
  # A daemon may have exited while its session/heartbeat/watchdog still runs. Reap the whole owned group.
  kill -KILL -- "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  n=0
  while fixture_group_alive "$pid" && [ "$n" -lt 20 ]; do sleep 0.1; n=$((n+1)); done
  if fixture_group_alive "$pid"; then
    echo "fixture group $pid survived cleanup; scratch retained at $T" >&2
    return 1
  fi
  for n in "${!FIXTURE_PIDS[@]}"; do
    [ "${FIXTURE_PIDS[$n]}" = "$pid" ] && unset 'FIXTURE_PIDS[n]'
  done
  return 0
}
fixture_cleanup() {
  local pid failed=0
  for pid in "${FIXTURE_PIDS[@]+"${FIXTURE_PIDS[@]}"}"; do stop "$pid" || failed=1; done
  [ "$failed" = 0 ] || return 1
  python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$T"
}
trap 'fixture_rc=$?; fixture_cleanup || fixture_rc=1; exit "$fixture_rc"' EXIT
fixture_signal() {
  # Defer a trappable interruption across fork/registration; otherwise EXIT could miss the new child.
  if [ "$FIXTURE_LAUNCHING" = 1 ]; then FIXTURE_SIGNAL="$1"; else exit "$1"; fi
}
trap 'fixture_signal 130' INT
trap 'fixture_signal 143' TERM
