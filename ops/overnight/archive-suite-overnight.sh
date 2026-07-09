#!/usr/bin/env bash
# Archive Suite — autonomous overnight self-resume daemon (L1).
#
# Fires a FRESH headless `claude -p` every cycle to advance the durable plan
# (.maintenance/OVERNIGHT_PLAN.md), one bounded item per session. Resilient to usage cutoffs:
# an exhausted window just fails fast and the next cycle retries when the cap resets (~5h).
#
# HARD SAFETY (see memory: autonomous-plan-cron-resume, no-force-override-destructive-git):
#   * --permission-mode default (NEVER bypassPermissions / --dangerously-skip-permissions)
#   * scoped --allowedTools + a destructive --disallowedTools denylist (deny wins over allow)
#   * per-session --max-budget-usd + wall-clock timeout so no single resume runs away or blows a window
#   * lives OUTSIDE ~/Desktop (TCC-protected) — the prior launchd attempt died with "Operation not permitted"
#     exec'ing a script under Desktop.
#
# Runs as a detached loop (primary; start with: setsid nohup … & ) OR under launchd with KeepAlive.
# Self-terminates when the plan's "RUN STATUS:" line reads COMPLETE.
set -uo pipefail

REPO="/Users/<user>/Desktop/Claude/Archive Suite"
PLAN="$REPO/.maintenance/OVERNIGHT_PLAN.md"
STATE="$HOME/.local/state/archive-overnight"
LOCK="$STATE/engine.lock"
LOG="$STATE/daemon.log"
PROMPT="$STATE/resume-prompt.txt"
CLAUDE="$HOME/.local/bin/claude"

INTERVAL="${OVERNIGHT_INTERVAL:-1200}"   # seconds between cycles (20 min)
STALE="${OVERNIGHT_STALE:-1500}"         # a lock older than this (25 min) is stale -> take over
MAXRUN="${OVERNIGHT_MAXRUN:-4500}"       # kill a single resume after 75 min
BUDGET="${OVERNIGHT_BUDGET:-30}"         # --max-budget-usd per resume session

# Tools a work session legitimately needs. deny wins over allow.
ALLOW="Bash Edit Write Read Grep Glob Task Agent Workflow TodoWrite NotebookEdit WebFetch WebSearch"
DENY="Bash(sudo:*) Bash(launchctl:*) Bash(rm -rf:*) Bash(rm -fr:*) Bash(rm -r:*) Bash(rm -R:*) Bash(git push --force:*) Bash(git push -f:*) Bash(git push --force-with-lease:*) Bash(git reset --hard:*) Bash(git clean:*) Bash(git worktree remove --force:*) Bash(git worktree remove -f:*) Bash(git branch -D:*) Bash(shutdown:*) Bash(reboot:*) Bash(halt:*) Bash(diskutil:*) Bash(dd:*) Bash(mkfs:*) Bash(curl:*) Bash(wget:*)"

mkdir -p "$STATE"
log() { printf '%s  %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# Keep the machine awake for the daemon's whole lifetime (idle-sleep only; display may sleep).
caffeinate -i -w "$$" &

log "=== daemon up (pid $$, interval ${INTERVAL}s, budget \$$BUDGET) ==="

tick() {
  # 1. Done? unload + stop.
  if grep -q '^RUN STATUS: COMPLETE' "$PLAN" 2>/dev/null; then
    log "plan RUN STATUS: COMPLETE — daemon stopping."
    launchctl bootout "gui/$(id -u)/com.archivesuite.overnight" 2>/dev/null || true
    return 9
  fi
  # 2. No plan? don't run blind.
  [ -f "$PLAN" ] || { log "no plan at $PLAN — skip."; return 0; }
  # 3. Another engine active? (lock fresh) skip this cycle.
  if [ -f "$LOCK" ]; then
    local age; age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$STALE" ]; then log "engine busy (lock ${age}s old) — skip."; return 0; fi
    log "stale lock (${age}s) — taking over."
  fi

  # 4. Acquire the lock + heartbeat it for the child's lifetime, so overlapping cycles/sessions skip.
  touch "$LOCK"
  local ppid=$$
  ( while kill -0 "$ppid" 2>/dev/null; do touch "$LOCK" 2>/dev/null; sleep 60; done ) &
  local hb=$!

  # 5. OCR key (for the E2E item) into the child env, without ever printing it.
  set -a; [ -f "$STATE/ocr-key.env" ] && . "$STATE/ocr-key.env"; set +a

  log "launching fresh resume session (timeout ${MAXRUN}s, budget \$$BUDGET)…"
  ( cd "$REPO" && timeout "$MAXRUN" "$CLAUDE" -p "$(cat "$PROMPT")" \
      --permission-mode default \
      --model opus --fallback-model sonnet \
      --max-budget-usd "$BUDGET" \
      --allowedTools $ALLOW \
      --disallowedTools $DENY \
      >> "$STATE/last-session.log" 2>&1 )
  local rc=$?
  log "resume session exited rc=$rc"

  kill "$hb" 2>/dev/null || true
  rm -f "$LOCK" 2>/dev/null || true
  return 0
}

while true; do
  tick; rc=$?
  [ "$rc" = "9" ] && break
  sleep "$INTERVAL"
done
log "=== daemon down (pid $$) ==="
