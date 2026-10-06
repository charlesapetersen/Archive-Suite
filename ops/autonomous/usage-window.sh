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
# CODEX (2026-10-04). Codex writes its readings into the session's ROLLOUT file under ~/.codex/sessions, not
# into the `codex exec --json` stream, as `"rate_limits":{…"primary":{"used_percent":91.0,"window_minutes":300,
# "resets_at":<epoch>},"secondary":{…weekly…}}`. A LOG holding such lines is read the same way: the primary
# (five-hour) window, unless the weekly one is exhausted, which then reads as 100% until ITS reset. With
# --codex-latest (or with no LOG when AUTONOMOUS_AGENT=codex) it reads the newest rollout of ANY session that
# has a reading, because the window is the account's and the owner's own Codex sessions spend it too.
#
# USAGE:  usage-window.sh [--raw] [--codex-latest | LOG]    LOG defaults to $STATE/last-session.log
# OUTPUT: "five-hour window 73% used, resets 18:10 (in 67 min)"; with --raw, "73 1790555400".
# EXIT:   0 known · 3 no rate_limit_event in the log yet, or (without --raw) the latest is from a window that
#         has since reset
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

raw=0; [ "${1:-}" = "--raw" ] && { raw=1; shift; }
latest=0; [ "${1:-}" = "--codex-latest" ] && { latest=1; shift; }
STATE="${AUTONOMOUS_STATE:-$HOME/.local/state/archive-autonomous}"   # the daemon exports AUTONOMOUS_STATE to sessions
# A session calls this with no argument. Under codex its own log holds no readings, so read codex's instead.
# The daemon's agent choice is in $STATE/agent (daemon.sh writes it); there is deliberately no environment
# variable for it, because an exported one leaked into the health gate and its harnesses (2026-10-04 review).
[ -z "${1:-}" ] && [ "$( { tr -d '[:space:]' < "$STATE/agent"; } 2>/dev/null)" = codex ] && latest=1

# Codex readings (see the header): the account-wide "codex" limit only. Other limit_ids occur in real rollouts
# ("premium", with primary null) and say nothing about the codex window.
codex_ev() {
  grep -o '"rate_limits":{"limit_id":"codex"[^}]*}[^}]*}[^}]*}' "$1" 2>/dev/null | awk '
    { pp = ""; pr = ""; sp = ""; sr = ""
      if (match($0, /"primary":\{"used_percent":[0-9.]+,"window_minutes":[0-9]+,"resets_at":[0-9]+/)) {
        x = substr($0, RSTART, RLENGTH); split(x, a, /[:,]/); pp = a[3]; pr = a[7] }
      if (match($0, /"secondary":\{"used_percent":[0-9.]+,"window_minutes":[0-9]+,"resets_at":[0-9]+/)) {
        x = substr($0, RSTART, RLENGTH); split(x, a, /[:,]/); sp = a[3]; sr = a[7] }
      if (sp != "" && sp + 0 >= 100) { printf "100 %s weekly\n", sr; next }
      if (pp != "") printf "%d %s five_hour\n", pp + 0.5, pr
    }' | tail -1
}

ev=""
if [ "$latest" = 1 ]; then
  # Newest rollout first (by mtime), modified within the last six hours: an older reading cannot describe the
  # current five-hour window. The first file that yields a CODEX reading wins — not merely the first with any
  # "rate_limits", which can be a premium-only file (the 2026-10-04 review's case: exit 3 at 97%).
  LOG="codex rollouts"
  while IFS= read -r f; do
    ev="$(codex_ev "$f")"; [ -n "$ev" ] && { LOG="$f"; break; }
  done < <(find "${CODEX_HOME:-$HOME/.codex}/sessions" -name 'rollout-*.jsonl' -mmin -360 2>/dev/null \
           | while IFS= read -r x; do printf '%s\t%s\n' "$(stat -f %m "$x")" "$x"; done | sort -rn | cut -f2-)
  [ -n "$ev" ] || { [ "$raw" = 1 ] || echo "five-hour window: unknown (no recent codex session has a reading)"; exit 3; }
else
  LOG="${1:-${AUTONOMOUS_WORKER_STATE:-$STATE}/last-session.log}"
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
  [ -n "$ev" ] || ev="$(codex_ev "$LOG")"
fi
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
