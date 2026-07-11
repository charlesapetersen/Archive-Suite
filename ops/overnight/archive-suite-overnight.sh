#!/usr/bin/env bash
# Autonomous overnight self-resume daemon (L1) — REUSABLE TEMPLATE.
# Current instance: Archive Suite. To reuse for another repo, copy this file, edit the PROJECT CONFIG
# block below (or set the OVERNIGHT_* env vars), and write that repo's L0 plan + L2 resume prompt.
#
# Fires a FRESH headless `claude -p` every cycle to advance a durable plan, one bounded item per session.
# Resilient to usage cutoffs: an exhausted window just fails fast and the next cycle retries when the cap
# resets (~5h). The durable plan (L0) is the real resilience — any fresh session recovers state from it.
#
# HARD SAFETY (see memory: autonomous-plan-cron-resume, no-force-override-destructive-git):
#   * --permission-mode default (NEVER bypassPermissions / --dangerously-skip-permissions)
#   * scoped --allowedTools + a destructive --disallowedTools denylist (deny wins over allow)
#   * per-session --max-budget-usd + wall-clock timeout so no single resume runs away or blows a window
#   * script + CLAUDE live OUTSIDE ~/Desktop (TCC-protected) — a prior launchd attempt died with
#     "Operation not permitted" exec'ing a script under Desktop.
#
# Runs as a detached loop (primary; start with: ( nohup … >log 2>&1 & )  — macOS has no setsid) OR under
# launchd with KeepAlive. The detached, session-scoped run is the NORMAL, accepted setup: it uses the
# launching session's TCC/screen grant, and if that session closes the daemon just stops — restart it next
# session (durable plan ⇒ no loss). Reboot-durability (launchd) is OPTIONAL, not needed for normal use.
# Self-terminates when the plan's "RUN STATUS:" line reads COMPLETE (a plain greppable line — no markdown).
set -uo pipefail

# ===== PROJECT CONFIG — to reuse elsewhere, edit these 5 (or set the matching OVERNIGHT_* env vars) =====
LABEL="${OVERNIGHT_LABEL:-archivesuite}"                            # unique slug: names the state dir + launchd job
REPO="${OVERNIGHT_REPO:-/Users/<user>/Desktop/Claude/Archive Suite}"  # the checkout to work in (worktrees branch off it)
PLAN="${OVERNIGHT_PLAN:-$REPO/.maintenance/OVERNIGHT_PLAN.md}"     # L0 durable plan (keep it gitignored)
STATE="${OVERNIGHT_STATE:-$HOME/.local/state/archive-overnight}"  # runtime state (logs, lock, resume prompt)
CLAUDE="${OVERNIGHT_CLAUDE:-$HOME/.local/bin/claude}"             # claude CLI — MUST be outside ~/Desktop (launchd/TCC)
# =======================================================================================================
LOCK="$STATE/engine.lock"; LOG="$STATE/daemon.log"; PROMPT="$STATE/resume-prompt.txt"
JOB="com.${LABEL}.overnight"    # launchd label (matches the .plist)

INTERVAL="${OVERNIGHT_INTERVAL:-1200}"   # seconds between cycles (20 min)
STALE="${OVERNIGHT_STALE:-1500}"         # a lock older than this (25 min) is stale -> take over
MAXRUN="${OVERNIGHT_MAXRUN:-4500}"       # kill a single resume after 75 min (HARD cap)
IDLE_MAX="${OVERNIGHT_IDLE_MAX:-1200}"   # ALSO kill a session emitting NO new output for 20 min (fast hang detection)
BUDGET="${OVERNIGHT_BUDGET:-30}"         # --max-budget-usd per resume session
EFFORT="${OVERNIGHT_EFFORT:-max}"        # reasoning effort for every resume session (low|medium|high|max)

# Tools a work session legitimately needs. deny wins over allow. ARRAYS (not strings): patterns contain
# spaces (e.g. "Bash(rm -rf:*)"), so they MUST each be one argv element — passed as "${DENY[@]}", never
# unquoted (unquoted word-splits the space and claude sees "-rf:*)" as an unknown option).
ALLOW=(Bash Edit Write Read Grep Glob Task Agent Workflow TodoWrite NotebookEdit WebFetch WebSearch)
DENY=(
  "Bash(sudo:*)" "Bash(launchctl:*)"
  "Bash(rm -rf:*)" "Bash(rm -fr:*)" "Bash(rm -r:*)" "Bash(rm -R:*)"
  "Bash(git push --force:*)" "Bash(git push -f:*)" "Bash(git push --force-with-lease:*)"
  "Bash(git reset --hard:*)" "Bash(git clean:*)"
  "Bash(git worktree remove --force:*)" "Bash(git worktree remove -f:*)" "Bash(git branch -D:*)"
  "Bash(shutdown:*)" "Bash(reboot:*)" "Bash(halt:*)"
  "Bash(diskutil:*)" "Bash(dd:*)" "Bash(mkfs:*)" "Bash(curl:*)" "Bash(wget:*)"
)

mkdir -p "$STATE"
log() { printf '%s  %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# SECURITY REMINDER (owner: TOP PRIORITY) — on ANY daemon exit, if the taskport debugger authorization is
# still password-free ('allow'), loudly remind the owner to REVERT it: daemon.log + a visible Desktop file +
# a macOS notification (best-effort). Fires once; no-op once taskport is back to authenticate-user.
_reminded=0
remind_revert_taskport() {
  [ "$_reminded" = 1 ] && return; _reminded=1
  security authorizationdb read system.privilege.taskport 2>/dev/null | grep -q '<string>allow</string>' || return
  local bk="$STATE/taskport-rule.backup.plist"
  local m="Overnight run has EXITED but taskport debugger auth is STILL 'allow' (password-free). REVERT it:  sudo security authorizationdb write system.privilege.taskport < $bk"
  log "!!!!!!!!!!!! SECURITY REMINDER: $m"
  { echo "[$(date '+%F %T')] Archive Suite overnight run exited."; echo; echo "$m"; } > "$HOME/Desktop/REVERT-TASKPORT-SECURITY.txt" 2>/dev/null || true
  osascript -e 'display notification "taskport auth is still password-free — REVERT it (see REVERT-TASKPORT-SECURITY.txt on your Desktop)." with title "Archive Suite: revert security setting" sound name "Basso"' >/dev/null 2>&1 || true
}
trap remind_revert_taskport EXIT
trap 'exit 0' TERM INT

# Children must be INDEPENDENT claude sessions, not NESTED. When this daemon is armed from an interactive
# Claude session it inherits CLAUDECODE / CLAUDE_CODE_* / CLAUDE_EFFORT etc., and a child `claude -p` would
# refuse to launch ("cannot be launched inside another Claude Code session"). The daemon needs none of them,
# so scrub every CLAUDE* var from this process; children then inherit a clean env. (Keeps OCR_KEY etc.)
for _v in $(env | sed -n 's/^\(CLAUDE[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$_v"; done

# Keep the machine awake for the daemon's whole lifetime (idle-sleep only; display may sleep).
caffeinate -i -w "$$" &

log "=== daemon up (pid $$, interval ${INTERVAL}s, budget \$$BUDGET) ==="

tick() {
  # 1. Done? unload + stop.
  if grep -q '^RUN STATUS: COMPLETE' "$PLAN" 2>/dev/null; then
    log "plan RUN STATUS: COMPLETE — daemon stopping."
    launchctl bootout "gui/$(id -u)/$JOB" 2>/dev/null || true
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

  # 5. Optional per-project env hook (e.g. a test API key) into the child env, without ever printing it.
  #    Archive Suite: $STATE/ocr-key.env holds `OCR_KEY=…` for the E2E (absent by default -> Keychain fallback).
  set -a; [ -f "$STATE/env" ] && . "$STATE/env"; [ -f "$STATE/ocr-key.env" ] && . "$STATE/ocr-key.env"; set +a

  log "launching fresh resume session (timeout ${MAXRUN}s, budget \$$BUDGET)…"
  cd "$REPO" || { log "cannot cd $REPO — skip."; kill "$hb" 2>/dev/null; rm -f "$LOCK"; return 0; }
  # Portable wall-clock timeout (macOS has no `timeout`/`gtimeout`): run claude in the background, and a
  # watchdog TERM/KILLs it after MAXRUN. $cpid is claude's own pid (backgrounded directly, no subshell).
  "$CLAUDE" -p "$(cat "$PROMPT")" \
      --permission-mode default \
      --model opus --fallback-model sonnet \
      --effort "$EFFORT" \
      --max-budget-usd "$BUDGET" \
      --allowedTools "${ALLOW[@]}" \
      --disallowedTools "${DENY[@]}" \
      >> "$STATE/last-session.log" 2>&1 &
  local cpid=$!
  # Watchdog: kill on IDLE (no new session-log output for IDLE_MAX = fast hang detection, e.g. stuck on a
  # native prompt) OR on the MAXRUN hard cap. A busy session appends output regularly, so idle-kill spares
  # legitimately long work while catching hangs ~4x faster than the hard cap alone.
  local sesslog="$STATE/last-session.log"
  (
    wd_start=$(date +%s); wd_last=$(wc -c < "$sesslog" 2>/dev/null || echo 0); wd_idle=$wd_start
    while kill -0 "$cpid" 2>/dev/null; do
      sleep 30
      wd_now=$(date +%s); wd_sz=$(wc -c < "$sesslog" 2>/dev/null || echo 0)
      [ "$wd_sz" != "$wd_last" ] && { wd_last=$wd_sz; wd_idle=$wd_now; }
      if [ $(( wd_now - wd_idle )) -ge "$IDLE_MAX" ]; then
        log "watchdog: no new output for ${IDLE_MAX}s — killing stuck session (pid $cpid)"
        kill -TERM "$cpid" 2>/dev/null; sleep 15; kill -KILL "$cpid" 2>/dev/null; break
      fi
      if [ $(( wd_now - wd_start )) -ge "$MAXRUN" ]; then
        log "watchdog: hit ${MAXRUN}s hard cap — killing session (pid $cpid)"
        kill -TERM "$cpid" 2>/dev/null; sleep 15; kill -KILL "$cpid" 2>/dev/null; break
      fi
    done
  ) &
  local wpid=$!
  wait "$cpid"; local rc=$?
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
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
