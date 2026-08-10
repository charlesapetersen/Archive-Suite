#!/usr/bin/env bash
# status-digest.sh — "what is the overnight worker doing?", answered in about ten seconds of reading.
#
# THE ONE STATUS RENDERER. `daemon.sh status` calls this and adds nothing of its own; the daemon writes its
# output to $STATE/STATUS.md every cycle and on park. There is deliberately no second copy of this
# formatting anywhere — daemon.sh used to print its own six sections and THEN paste this digest underneath,
# so the run state and the plan line appeared twice, in two different wordings, and a fix to one never
# reached the other. (Same failure as ops/gui/tart-lib.sh: two copies of one fact is how they drift.)
#
# AUDIENCE: the owner, at a glance, not an engineer reading logs. So the default view answers only the
# five questions actually worth waking up to —
#     is it running? · what has it done? · how much is left? · is the code healthy? · does it need me?
# — in plain words, with no jargon, no internal workstream numbers and no raw log tails. Everything else
# (keychain state, GUI lane, disk, review coverage, the log tail, launchd internals) is real but it is
# DIAGNOSTIC, so it lives behind `--details` and is only surfaced by default when it is actually a problem.
#
# READ-ONLY: no prompts, no edits, no network. Every field degrades to "?"/"—" rather than erroring, because
# this is the thing you run WHEN something is already wrong.
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"
REPO="${AUTONOMOUS_REPO:-/Users/<user>/Claude/Archive Suite}"
STATE="${AUTONOMOUS_STATE:-$HOME/.local/state/archive-autonomous}"
PLAN="${AUTONOMOUS_PLAN:-$REPO/.maintenance/AUTONOMOUS_PLAN.md}"
JOB="com.archivesuite.autonomous"; GUI_DOMAIN="gui/$(id -u)"
LOG="$STATE/daemon.log"
DAEMON_CMD="./ops/autonomous/daemon.sh"

DETAILS=0
case "${1:-}" in -d|--details|--detail|-v|--verbose|full) DETAILS=1 ;; esac

g() { git -C "$REPO" "$@" 2>/dev/null; }
num() { case "${1:-}" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

# Colour only when a human is watching. The daemon redirects this into STATUS.md, and escape codes in a
# file are worse than no colour at all.
if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; AMB=$'\033[33m'; RED=$'\033[31m'; OFF=$'\033[0m'
else B=""; DIM=""; GRN=""; AMB=""; RED=""; OFF=""; fi

# "3 hours"/"12 minutes" from a number of seconds — for people, not for parsing.
human_secs() {
  local s; s="$(num "${1:-0}")"
  if   [ "$s" -lt 90 ]    ; then plural "$s" second
  elif [ "$s" -lt 5400 ]  ; then plural "$(( s / 60 ))" minute
  elif [ "$s" -lt 172800 ]; then plural "$(( s / 3600 ))" hour
  else                           plural "$(( s / 86400 ))" day; fi
}
# plural N word -> "1 change" / "3 changes". Writing "change(s)" at a human is a small rudeness.
plural() { [ "$(num "${1:-0}")" = 1 ] && printf '1 %s' "$2" || printf '%s %ss' "$(num "${1:-0}")" "$2"; }
# Cut to N chars on a WORD boundary, so a truncated commit subject does not end mid-syllable.
clip() {
  local s="${1:-}" n="${2:-60}"
  [ "${#s}" -le "$n" ] && { printf '%s' "$s"; return; }
  s="${s:0:$n}"; s="${s% *}"; printf '%s…' "$s"
}

# Why the daemon is idle is decided in run-state-lib.sh, shared with daemon.sh. Guarded because daemon.sh may run
# from a checkout that predates the lib (memory `arm-installs-from-primary-checkout`).
if [ -r "$(cd "$(dirname "$0")" && pwd)/run-state-lib.sh" ]; then
  . "$(cd "$(dirname "$0")" && pwd)/run-state-lib.sh"
else
  ratelimit_reset_epoch() { return 1; }
  ratelimit_phrase() { printf 'usage cap'; }
fi

# ---------------------------------------------------------------------------------------------------
# STATE 1 — is it running, and if not, why? Sets: STATE_ICON, STATE_LINE, STATE_HINT (may be empty).
# ---------------------------------------------------------------------------------------------------
running=0; pgrep -f archive-suite-autonomous.sh >/dev/null 2>&1 && running=1
supervised=0; launchctl print "$GUI_DOMAIN/$JOB" >/dev/null 2>&1 && supervised=1
since="$(cat "$STATE/idle.since" 2>/dev/null)"
STATE_HINT=""

if [ -n "${STATUS_PARKED:-}" ]; then
  # Set by the daemon while it is parking: the process is still alive for another moment, so the pgrep
  # check below would say "working" for a run that has actually given up. The flag wins.
  STATE_ICON="${AMB}◆${OFF}"; STATE_LINE="Stopped itself — everything left needs a decision from you"
  STATE_HINT="reason: $(printf '%s' "$STATUS_PARKED" | tr -d '\n' | cut -c1-70)"
elif [ "$running" = 1 ]; then
  case "$since" in
    ''|*[!0-9]*)
      STATE_ICON="${GRN}●${OFF}"; STATE_LINE="Working now"
      # ⛔ DO NOT re-add a "— N into its current task" suffix here from engine.lock's mtime (removed
      # 2026-08-10 at the owner's request, after he noticed it saying "1 second into its current task"
      # beside a 12-minute-old commit). That reading was FALSE, not merely noisy: `engine.lock` is a
      # mutual-exclusion LEASE, not a session marker, and archive-suite-autonomous.sh heartbeats it —
      # `( while kill -0 "$ppid"; do touch "$LOCK"; sleep 60; done ) &` — for the child's whole lifetime,
      # so its age is "seconds since the last heartbeat tick" and is structurally pinned to 0-60s. It could
      # therefore NEVER show the wedged-for-three-hours session it was added to reveal; a lock older than
      # $STALE (1500s) is taken over by the next cycle anyway. The old test "proved" it only by backdating
      # the lock 2 hours by hand — an input production cannot produce.
      # Staleness is already answered honestly two lines down by "latest change <relative>" plus the Health
      # row, which is what the owner said he actually reads. If a true task age is ever wanted, it needs a
      # separate session-start stamp written once at acquire time — not this file's mtime.
      ;;
    *)
      idle=$(( $(date +%s) - since ))
      if reset="$(ratelimit_reset_epoch)"; then
        STATE_ICON="${AMB}◐${OFF}"
        STATE_LINE="Paused — it hit the $(ratelimit_phrase "$reset")"
        STATE_HINT="This is NOT out of work; it retries by itself. Idle $(human_secs "$idle")."
      else
        STATE_ICON="${AMB}◐${OFF}"
        STATE_LINE="Running, but not finding anything it can do ($(human_secs "$idle"))"
        STATE_HINT="Usually means the remaining tasks are waiting on you — see 'Needs you' below."
      fi ;;
  esac
elif [ "$supervised" = 1 ]; then
  # Job loaded but no process: either between restarts, or crash-looping. Never let those read alike.
  lec="$(launchctl print "$GUI_DOMAIN/$JOB" 2>/dev/null | awk -F'= ' '/last exit code/{gsub(/[^0-9-]/,"",$2); print $2; exit}')"
  STATE_ICON="${RED}✕${OFF}"; STATE_LINE="Set to run, but not running right now"
  STATE_HINT="Restarting, or failing to start (last exit ${lec:-?}). If this persists: $DAEMON_CMD stop, then $DAEMON_CMD start"
elif tail -n 8 "$LOG" 2>/dev/null | grep -q 'PARKED'; then
  STATE_ICON="${AMB}◆${OFF}"; STATE_LINE="Stopped itself — everything left needs a decision from you"
  STATE_HINT="Nothing is lost. Clear what it is waiting on, then restart it: $DAEMON_CMD start"
  [ -f "$HOME/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt" ] && STATE_HINT="$STATE_HINT  (see ~/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt)"
else
  STATE_ICON="${DIM}○${OFF}"; STATE_LINE="Not running"
  STATE_HINT="Nothing is working on the project right now. Start it: $DAEMON_CMD start"
fi

# ---------------------------------------------------------------------------------------------------
# STATE 2 — what has it done, how much is left, is the code healthy?
# ---------------------------------------------------------------------------------------------------
commits24="$(num "$(g log --since='24 hours ago' --oneline 2>/dev/null | wc -l | tr -d ' ')")"
lastwhen="$(g log -1 --format='%cr')"; lastwhen="${lastwhen:-—}"
lastsubj="$(clip "$(g log -1 --format='%s')" 62)"
open_todo="$(num "$(grep -cE '^\s*[-*].*\[ \]' "$REPO/SUITE_TODO.md" 2>/dev/null)")"
# Completed work lives in SUITE_TODO_DONE.md since 2026-08-01 (finishing an item MOVES its entry rather than
# ticking it in place), so counting SUITE_TODO alone reported "1 finished" the moment the archive was split out.
done_todo="$(num "$(cat "$REPO/SUITE_TODO.md" "$REPO/SUITE_TODO_DONE.md" 2>/dev/null | grep -cE '^\s*[-*].*\[[xX]\]')")"
hold="$(num "$(awk '/^## HOLD QUEUE/{f=1;next} f&&/^## /{exit} f' "$PLAN" 2>/dev/null | grep -cE '^[[:space:]]*[-*][[:space:]]+\[ \]')")"

# $STATE/last-gate only advances on a GREEN gate (the daemon writes HEAD there only on rc=0), so on its own
# this block is STRUCTURALLY incapable of reporting a gate that has since gone RED. On 2026-08-06 it printed
# "Build and tests passed, 30 changes ago" for a run that had PARKED on a RED gate 41 minutes earlier — read
# as "healthy, just a bit stale" when the truth was "the last full check FAILED". last-gate.log always holds
# the LAST gate run's verdict (the retry-once overwrites it) and that verdict NAMES the failing step, so read
# it. ⚠️ It is written IN PLACE, so it lies WHILE a gate is executing — skip it then (memory
# `health-gate-red-retry-once`).
gate_red=""; gate_code=""
if ! pgrep -f 'ops/autonomous/health-gate\.sh' >/dev/null 2>&1; then
  gate_red="$(grep -m1 '^HEALTH GATE: RED' "$STATE/last-gate.log" 2>/dev/null \
              | sed 's/^HEALTH GATE: RED[^A-Za-z0-9]*//' | tr -s ' ' | sed 's/^ *//; s/ *$//')"
fi
# Same doc-vs-code split the daemon's park note uses: context-budget/tracker-sync/coherence guard DOCUMENTS,
# everything else builds or tests CODE. Split on spaces explicitly — do not trust the ambient IFS.
if [ -n "$gate_red" ]; then
  oldifs="$IFS"; IFS=' '
  for s in $gate_red; do
    case "$s" in context-budget|tracker-sync|coherence) : ;; *) gate_code="${gate_code:+$gate_code }$s" ;; esac
  done
  IFS="$oldifs"
fi
gate_last="$(cat "$STATE/last-gate" 2>/dev/null)"
if [ -n "$gate_code" ]; then
  HEALTH="The last full check FAILED: $gate_code — the build or tests are broken"
elif [ -n "$gate_red" ]; then
  HEALTH="The last full check FAILED: $gate_red — the code built and passed; a document is over its size limit"
elif [ -n "$gate_last" ] && g cat-file -e "${gate_last}^{commit}" 2>/dev/null; then
  gate_behind="$(num "$(g rev-list --count "$gate_last..HEAD")")"
  case "$gate_behind" in
    0) HEALTH="Build and tests passed, on the current code" ;;
    1) HEALTH="Build and tests passed, 1 change ago" ;;
    *) HEALTH="Build and tests passed, $gate_behind changes ago" ;;
  esac
else
  HEALTH="Not checked yet — the next run will do a full build and test"
fi

# ---------------------------------------------------------------------------------------------------
# STATE 3 — does it need me? Only genuine, actionable asks; each says what to DO, not what is wrong.
# ---------------------------------------------------------------------------------------------------
needs=""
add_need() { needs="$needs"$'\n'"    • $1"; }
[ -f "$HOME/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt" ] && \
  add_need "It parked and left you a note: ~/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt — then restart it"
security authorizationdb read system.privilege.taskport 2>/dev/null | grep -q '<string>allow</string>' && \
  add_need "A security setting is still relaxed (password-free taskport) — see ~/Desktop/REVERT-TASKPORT-SECURITY.txt"
[ -f "$STATE/keychain-partition-fixed" ] || \
  add_need "Keychain not set up — it may interrupt you with a password box. Run once: ./ops/autonomous/fix-keychain-access.sh"
[ "$hold" -gt 0 ] 2>/dev/null && \
  add_need "$hold task(s) are held back for you to decide (they touch things with no undo)"
# Daemon Report: count OPEN checkboxes, then quote the first. Handles both shapes — the `- [ ]` checklist
# rows and the older `- **[YYYY-MM-DD] …` prose entries. Sub-headings inside the section must stay ###; a
# `## ` there correctly ends the scan (and would silently empty this list, so it is worth knowing).
mr_open="$(awk '/^## (Daemon Report|Morning Review)/{f=1;next} f&&/^## /{exit} f&&/^[[:space:]]*- \[ \]/{c++} END{print c+0}' "$PLAN" 2>/dev/null)"
mr_open="$(num "$mr_open")"
# Real newlines via add_need, printed with %s not %b — plan text can contain backslashes that %b would eat.
mr="$(awk '/^## (Daemon Report|Morning Review)/{f=1;next} f&&/^## /{exit} f&&/^[[:space:]]*- (\[ \]|\*\*\[)/{print; exit}' "$PLAN" 2>/dev/null | tr -d '\\\r' | sed 's/^[[:space:]]*//' | cut -c1-64)"
if [ "$mr_open" -gt 0 ] 2>/dev/null; then
  add_need "$mr_open thing(s) waiting on your decision — first: ${mr}…"
elif [ -n "$mr" ]; then
  add_need "Notes are waiting for you to read — first: ${mr}…"
fi

# ---------------------------------------------------------------------------------------------------
# RENDER — the default view. Five answers, nothing else.
# ---------------------------------------------------------------------------------------------------
printf '%s\n' "${B}Archive Suite — overnight worker${OFF}   ${DIM}$(date '+%a %-d %b, %H:%M')${OFF}"
printf '\n  %s  %s\n' "$STATE_ICON" "${B}${STATE_LINE}${OFF}"
[ -n "$STATE_HINT" ] && printf '     %s%s%s\n' "$DIM" "$STATE_HINT" "$OFF"

if [ "$commits24" -gt 0 ] 2>/dev/null; then
  printf '\n  %-10s %s in the last 24 hours · latest %s\n' "Done" "$(plural "$commits24" change)" "$lastwhen"
else
  printf '\n  %-10s nothing in the last 24 hours · latest change %s\n' "Done" "$lastwhen"
fi
[ -n "$lastsubj" ] && printf '  %-10s %s%s%s\n' "" "$DIM" "\"$lastsubj\"" "$OFF"
printf '  %-10s %s to do · %s finished\n' "Left" "$(plural "$open_todo" task)" "$done_todo"
printf '  %-10s %s\n' "Health" "$HEALTH"

if [ -n "$needs" ]; then
  printf '\n  %-10s%s\n' "Needs you" "$needs"
else
  printf '\n  %-10s %sNothing right now.%s\n' "Needs you" "$GRN" "$OFF"
fi

# ---------------------------------------------------------------------------------------------------
# RENDER — --details. The diagnostics, for when the top-line view says something is wrong.
# ---------------------------------------------------------------------------------------------------
if [ "$DETAILS" = 1 ]; then
  wt="$(num "$(g worktree list 2>/dev/null | grep -c 'wt/')")"
  disk="$(df -m "$REPO" 2>/dev/null | awk 'NR==2{printf "%.0f", $4/1024}')"
  printf '\n  %s\n' "${B}Details${OFF}"
  printf '  %-18s %s\n' "current code" "$(g log -1 --format='%h %s' | cut -c1-62)"
  printf '  %-18s %s\n' "plan" "$(grep -m1 '^RUN STATUS:' "$PLAN" 2>/dev/null | cut -c1-62 || echo '(no plan file)')"
  printf '  %-18s %s\n' "restart on crash" "$([ "$supervised" = 1 ] && echo 'yes (launchd keeps it alive)' || echo 'no (plain background process)')"
  printf '  %-18s %s\n' "disk free" "${disk:-?} GB"
  printf '  %-18s %s\n' "spare worktrees" "$wt"
  printf '  %-18s %s\n' "keychain" "$([ -f "$STATE/keychain-partition-fixed" ] && cat "$STATE/keychain-partition-fixed" 2>/dev/null || echo 'not set up')"
  printf '  %-18s %s\n' "GUI checks" "run off-screen in the Tart VM (ops/gui/README §3)"
  printf '  %-18s %s\n' "code reviews" "$(grep -q 'REVIEW_ENABLED_DEFAULT=0' "$REPO/ops/autonomous/next-review-unit.sh" 2>/dev/null && echo 'paused by you' || echo 'on')"
  printf '\n  %s\n' "${B}Last few log lines${OFF}"
  tail -n 6 "$LOG" 2>/dev/null | sed 's/^/    /' || printf '    (no log yet)\n'
else
  printf '\n  %smore: %s status --details%s\n' "$DIM" "$DAEMON_CMD" "$OFF"
fi
