# run-state-lib.sh — the one place that decides WHY the daemon is idle.
# SOURCE this (`. "$(dirname "$0")/run-state-lib.sh"`), never execute it.
#
# WHY THIS FILE EXISTS. On 2026-07-31 `daemon.sh status` said "running, BACKING OFF (idle 3375s — sessions
# finding no actionable work)" for an hour while the truth was a 429: every session since 06:35 had been
# refused by the five-hour usage cap and died in ~5 seconds, and `next-queue-item.sh` was offering ~20
# actionable items the whole time. The two states call for OPPOSITE responses from the owner — "the queue
# is drained, go add work / stop the daemon" versus "it is throttled, it resumes by itself at 07:30" — and
# the status line asserted the first while the second was true. The daemon's BACKOFF *behaviour* is right
# either way (waiting longer is exactly what a cap wants); only the explanation was wrong, so this file
# changes reporting only and touches no control flow.
#
# Both `daemon.sh` and `status-digest.sh` render this state, so the detector lives here rather than being
# written twice — the same lesson as ops/gui/tart-lib.sh, where a fix landing in one of two copies is how
# the tart-PATH trap survived three sessions.
#
# Works under `set -uo pipefail` (both callers) — no unguarded command substitution, no bare final `[ ]`.

# ratelimit_reset_epoch [logfile] — echo the cap's reset epoch and return 0 if the MOST RECENT session
# ended refused by a usage cap; return 1 (echoing nothing) otherwise. Reads only the last session's own
# log, so a cap hit yesterday cannot colour today's status.
#
# Keyed on the TERMINAL result line (`"api_error_status":429`), not on the `rate_limit_event` record: a
# session can log a rate_limit_event, recover and go on to do useful work, and reporting that as throttled
# would be the same class of lie in the other direction. `resetsAt` is read separately because it appears
# on the event, not the result.
ratelimit_reset_epoch() {
  local f="${1:-${STATE:-$HOME/.local/state/archive-autonomous}/last-session.log}" reset
  [ -f "$f" ] || return 1
  grep -q '"api_error_status":429' "$f" 2>/dev/null || return 1
  reset="$(grep -o '"resetsAt":[0-9]*' "$f" 2>/dev/null | tail -1 | cut -d: -f2)"
  printf '%s' "${reset:-}"
  return 0
}

# ratelimit_phrase EPOCH — a human tail for the status line. Distinguishes "still capped, resumes at HH:MM"
# from "the cap has already lifted, the next scheduled attempt will get through", because those are also
# different owner actions (wait vs. it is already fixing itself).
ratelimit_phrase() {
  local reset="${1:-}" now
  now="$(date +%s)"
  case "$reset" in
    ''|*[!0-9]*) printf 'usage cap' ; return 0 ;;
  esac
  if [ "$reset" -gt "$now" ] 2>/dev/null; then
    printf 'usage cap, resets %s' "$(date -r "$reset" '+%H:%M' 2>/dev/null || echo '?')"
  else
    printf 'usage cap, already reset %s — next attempt should get through' \
      "$(date -r "$reset" '+%H:%M' 2>/dev/null || echo '?')"
  fi
}

# idle_explanation IDLE_SECONDS — the full one-line reason a live daemon is not advancing. This is the
# function the status renderers call; it is what keeps the wording identical in both of them.
idle_explanation() {
  local idle="${1:-?}" reset
  if reset="$(ratelimit_reset_epoch)"; then
    printf 'running, THROTTLED (idle %ss — last session was REFUSED by the %s; this is NOT an empty queue)' \
      "$idle" "$(ratelimit_phrase "$reset")"
  else
    printf 'running, BACKING OFF (idle %ss — sessions finding no actionable work; retrying, widening the gap)' \
      "$idle"
  fi
}
