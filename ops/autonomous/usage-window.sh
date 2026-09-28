#!/usr/bin/env bash
# ops/autonomous/usage-window.sh — how much of the five-hour usage window is spent, from the session's own log.
#
# `claude -p --output-format stream-json` writes a `rate_limit_event` into the session log as the session runs.
# While the session is allowed, the event carries `unifiedWindows.five_hour` with `utilization` (0-1) and
# `resetsAt` (epoch seconds). When a limit REJECTS the session, the event has `"status":"rejected"`, a top-level
# `resetsAt` and a `rateLimitType`, and no utilization; that reads as 100% (observed in the 2026-08 fast-fails).
# This prints the latest event of either kind. A session calls it to decide whether to hand out subagents or
# work alone (resume prompt, USAGE WINDOW); the daemon calls it with --raw after each session.
# Ported from vision-ocr's usage-window.sh (owner, 2026-09-28); the rejected case is this copy's addition.
#
# USAGE:  usage-window.sh [--raw] [LOG]    LOG defaults to $STATE/last-session.log
# OUTPUT: "five-hour window 73% used, resets 18:10 (in 67 min)"; with --raw, "73 1790555400".
# EXIT:   0 known · 3 no rate_limit_event in the log yet, or (without --raw) the latest is from a window that
#         has since reset
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

raw=0; [ "${1:-}" = "--raw" ] && { raw=1; shift; }
STATE="${AUTONOMOUS_STATE:-$HOME/.local/state/archive-autonomous}"   # the daemon exports AUTONOMOUS_STATE to sessions
LOG="${1:-$STATE/last-session.log}"

# One "<pct> <resetsAt> <type>" per rate_limit_event, in log order; the last one wins.
ev="$(grep '"type":"rate_limit_event"' "$LOG" 2>/dev/null | awk '
  /"status":"rejected"/ {
    if (match($0, /"resetsAt":[0-9]+/)) { r = substr($0, RSTART + 11, RLENGTH - 11) } else next
    t = "limit"; if (match($0, /"rateLimitType":"[a-z_]+"/)) t = substr($0, RSTART + 17, RLENGTH - 18)
    print 100, r, t; next
  }
  match($0, /"five_hour":\{"utilization":[0-9.]+,"resetsAt":[0-9]+/) {
    s = substr($0, RSTART, RLENGTH); sub(/.*"utilization":/, "", s); split(s, a, /,"resetsAt":/)
    printf "%d %s five_hour\n", a[1] * 100 + 0.5, a[2]
  }' | tail -1)"
[ -n "$ev" ] || { [ "$raw" = 1 ] || echo "five-hour window: unknown (no rate_limit_event in $LOG yet)"; exit 3; }
read -r pct reset kind <<< "$ev"

if [ "$raw" = 1 ]; then
  echo "$pct $reset"
else
  label="five-hour window"; [ "$kind" = five_hour ] || label="$kind limit"
  secs=$(( reset - $(date +%s) )); mins=$(( secs / 60 ))
  if [ "$secs" -gt 0 ]; then
    echo "$label ${pct}% used, resets $(date -r "$reset" '+%H:%M') (in ${mins} min)"
  else
    # A reading from a window that has since reset says nothing about the current one. Run outside a daemon
    # session on 2026-09-28, this printed a six-week-old "100% used", which the resume prompt would read as
    # "no subagents". Say unknown instead, with the date, and exit 3 like a log with no event.
    echo "$label: unknown (the last reading, ${pct}%, is from a window that reset $(date -r "$reset" '+%F %H:%M'))"
    exit 3
  fi
fi
