#!/usr/bin/env bash
# status-digest.sh (WS5) — print a ONE-SCREEN digest of the autonomous run so a check-in is a 5-second read
# instead of grepping daemon.log + the plan + git + df + worktrees by hand. READ-ONLY (no prompts, no edits,
# no network). The daemon regenerates $STATE/STATUS.md each cycle + on park; `arm.sh status` also runs this.
# All fields degrade gracefully (a missing source prints "?"/"—", never an error).
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"
REPO="${AUTONOMOUS_REPO:-/Users/<user>/Claude/Archive Suite}"
STATE="${AUTONOMOUS_STATE:-$HOME/.local/state/archive-autonomous}"
PLAN="${AUTONOMOUS_PLAN:-$REPO/.maintenance/AUTONOMOUS_PLAN.md}"
JOB="com.archivesuite.autonomous"; GUI_DOMAIN="gui/$(id -u)"
LOG="$STATE/daemon.log"
g() { git -C "$REPO" "$@" 2>/dev/null; }
num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

# ---- run state (mirrors arm.sh) ----
run_state() {
  local since
  # STATUS_PARKED is set by the daemon's write_status when it regenerates the digest DURING park_run — at
  # that instant the daemon process is still alive (bootout hasn't fired), so the pgrep branch below would
  # wrongly say "running". Honor the explicit flag first.
  if [ -n "${STATUS_PARKED:-}" ]; then
    echo "PARKED — $(printf '%s' "$STATUS_PARKED" | cut -c1-60) (blocked on you; re-arm after fixing)"; return
  fi
  if pgrep -f archive-suite-autonomous.sh >/dev/null 2>&1; then
    since=$(cat "$STATE/idle.since" 2>/dev/null)
    case "$since" in ''|*[!0-9]*) echo "running, productive" ;;
      *) echo "running, BACKING OFF (idle $(( $(date +%s) - since ))s — no actionable work)" ;; esac
  elif tail -n 8 "$LOG" 2>/dev/null | grep -q 'PARKED'; then
    echo "PARKED — $(tail -n 40 "$LOG" 2>/dev/null | grep -m1 'PARKED' | sed 's/.*PARKED (\([^)]*\)).*/\1/;s/.*PARKED/parked/' | cut -c1-60) (blocked on you)"
  else echo "stopped (re-arm: ./ops/autonomous/arm.sh keepalive)"; fi
}
supervisor() { launchctl print "$GUI_DOMAIN/$JOB" >/dev/null 2>&1 && echo "launchd KeepAlive (crash-restart)" || echo "nohup/none"; }

# ---- backlog counts ----
qcount() { g log >/dev/null 2>&1 || { echo "?"; return; }; grep -cE "$1" "$2" 2>/dev/null || echo 0; }
wq() { awk '/^## WORK QUEUE/{f=1;next} f&&/^## /{exit} f' "$PLAN" 2>/dev/null; }
open_todo="$(num "$(grep -cE '^\s*[-*].*\[ \]' "$REPO/SUITE_TODO.md" 2>/dev/null)")"
done_todo="$(num "$(grep -cE '^\s*[-*].*\[[xX]\]' "$REPO/SUITE_TODO.md" 2>/dev/null)")"
open_wq="$(num "$(wq | grep -cE '^[[:space:]]*[-*][[:space:]]+\[ \]')")"
hold="$(num "$( { awk '/^## HOLD QUEUE/{f=1;next} f&&/^## /{exit} f' "$PLAN" 2>/dev/null | grep -cE '^[[:space:]]*[-*][[:space:]]+\[ \]'; } )")"

# ---- health gate ----
gate_line() {
  local last; last="$(cat "$STATE/last-gate" 2>/dev/null)"
  if [ -n "$last" ] && g cat-file -e "$last^{commit}"; then
    echo "last GREEN @ ${last:0:12} ($(num "$(g rev-list --count "$last..HEAD")") commits since)"
  else echo "not yet run (or stale marker → will run next cadence)"; fi
}
# ---- review coverage ----
review_line() {
  local tsv="$REPO/.maintenance/review/last-reviewed.tsv"      # WS11 state (gitignored, primary checkout)
  [ -f "$tsv" ] || { echo "no unit reviewed yet"; return; }
  # num() guards the count (BSD `grep -c` prints 0 AND exits 1 on no match — a `|| echo 0` would double-print).
  echo "$(num "$(grep -cvE '^__any__' "$tsv" 2>/dev/null)")/9 units reviewed (last: $(awk -F'\t' '$1!="__any__"{print $1}' "$tsv" 2>/dev/null | tail -1))"
}

# ---- owner-needed ----
# Accumulate with REAL newlines (via add_need) and print with `printf %s`, NOT `%b` — plan-derived content
# (the Morning-Review snippet) may contain backslashes, and %b would expand a stray \n/\c and mangle/truncate
# the section. Strip any control chars from the snippet too, belt-and-braces.
needs=""
add_need() { needs="$needs"$'\n'"  • $1"; }
[ -f "$HOME/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt" ] && add_need "PARKED — see ~/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt, then re-arm"
security authorizationdb read system.privilege.taskport 2>/dev/null | grep -q '<string>allow</string>' && add_need "taskport is 'allow' (password-free) — revert: see ~/Desktop/REVERT-TASKPORT-SECURITY.txt"
[ -f "$STATE/keychain-partition-fixed" ] || add_need "keychain partition-fix not applied — run ./ops/autonomous/fix-keychain-access.sh (stops 'security' prompts)"
[ "$hold" -gt 0 ] 2>/dev/null && add_need "$hold hold-queue item(s) await you (Tier-3/SPEC/corpus/irreversible) — see the plan's ## HOLD QUEUE"
# Morning Review OPEN head (first bullet), if the plan has one
mr="$(awk '/^## Morning Review/{f=1;next} f&&/^## /{exit} f&&/^- /{print; exit}' "$PLAN" 2>/dev/null | tr -d '\\\r' | cut -c1-72)"
[ -n "$mr" ] && add_need "Morning Review has entries (top): ${mr}…"

printf '=== Archive Suite — autonomous run STATUS (%s) ===\n' "$(date '+%F %T')"
printf 'RUN:      %s   [%s]\n' "$(run_state)" "$(supervisor)"
printf 'PLAN:     %s\n' "$(grep -m1 '^RUN STATUS:' "$PLAN" 2>/dev/null | cut -c1-88 || echo '(no plan)')"
printf 'HEAD:     %s  |  commits last 24h: %s  |  last: %s\n' \
  "$(g log -1 --format='%h %s' | cut -c1-66)" "$(num "$(g log --since='24 hours ago' --oneline | wc -l | tr -d ' ')")" "$(g log -1 --format='%cr')"
printf 'BACKLOG:  SUITE_TODO %s open / %s done  |  plan WORK QUEUE %s open  |  hold-queue %s\n' "$open_todo" "$done_todo" "$open_wq" "$hold"
printf 'GATE:     %s\n' "$(gate_line)"
printf 'REVIEW:   %s\n' "$(review_line)"
printf 'DISK:     %sGB free  |  worktrees: %s wt/*\n' \
  "$(df -m "$REPO" 2>/dev/null | awk 'NR==2{printf "%.0f", $4/1024}')" "$(num "$(g worktree list | grep -c 'wt/')")"
printf -- '--- NEEDS YOU: ---'
if [ -n "$needs" ]; then printf '%s\n' "$needs"; else printf '\n  • nothing — the run is autonomous.\n'; fi
