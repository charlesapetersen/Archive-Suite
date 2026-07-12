#!/usr/bin/env bash
# Autonomous autonomous self-resume daemon (L1) — REUSABLE TEMPLATE.
# Current instance: Archive Suite. To reuse for another repo, copy this file, edit the PROJECT CONFIG
# block below (or set the AUTONOMOUS_* env vars), and write that repo's L0 plan + L2 resume prompt.
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

# ===== PROJECT CONFIG — to reuse elsewhere, edit these 5 (or set the matching AUTONOMOUS_* env vars) =====
LABEL="${AUTONOMOUS_LABEL:-archivesuite}"                            # unique slug: names the state dir + launchd job
REPO="${AUTONOMOUS_REPO:-/Users/<user>/Desktop/Claude/Archive Suite}"  # the checkout to work in (worktrees branch off it)
PLAN="${AUTONOMOUS_PLAN:-$REPO/.maintenance/AUTONOMOUS_PLAN.md}"     # L0 durable plan (keep it gitignored)
STATE="${AUTONOMOUS_STATE:-$HOME/.local/state/archive-autonomous}"  # runtime state (logs, lock, resume prompt)
CLAUDE="${AUTONOMOUS_CLAUDE:-$HOME/.local/bin/claude}"             # claude CLI — MUST be outside ~/Desktop (launchd/TCC)
# =======================================================================================================
LOCK="$STATE/engine.lock"; LOG="$STATE/daemon.log"; PROMPT="$STATE/resume-prompt.txt"
JOB="com.${LABEL}.autonomous"    # launchd label (matches the .plist)

INTERVAL="${AUTONOMOUS_INTERVAL:-120}"    # idle gap between cycles (2 min — near back-to-back; sessions run
                                          # ~10 min, so this is the effective cadence. Was 1200/20min; tightened
                                          # 2026-07-11 for faster throughput. Override with AUTONOMOUS_INTERVAL.
STALE="${AUTONOMOUS_STALE:-1500}"         # a lock older than this (25 min) is stale -> take over
MAXRUN="${AUTONOMOUS_MAXRUN:-4500}"       # kill a single resume after 75 min (wall-clock hard cap)
BUDGET="${AUTONOMOUS_BUDGET:-30}"         # --max-budget-usd per resume session
EFFORT="${AUTONOMOUS_EFFORT:-max}"        # reasoning effort for every resume session (low|medium|high|max)

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

# Housekeeping — GC the daemon's OWN spent worktrees + branches so they don't pile up for the owner.
# Runs in the daemon loop BETWEEN sessions. SAFETY is structural, in layers (this survived an adversarial
# Tier-2 review — see ops/autonomous/README.md "housekeeping"):
#   * NO --force, EVER. Plain `git worktree remove` makes git itself REFUSE any worktree with uncommitted or
#     untracked content. So housekeeping CANNOT destroy unpushed/in-progress work — not a maintainer's, not a
#     watchdog-killed session's, not a live build's. A dirty/in-use worktree is SKIPPED and logged; it does
#     NOT treat "merged" as "safe to blow away". (This is why the review's data-loss + race findings don't
#     bite: the dangerous cases are all dirty or in-use, and git refuses to remove those.)
#   * MERGED-ONLY: only touch a wt/ ref whose tip is an ANCESTOR of origin/main — its commits are provably
#     pushed, so branch -D drops nothing reachable and worktree removal loses no committed work.
#   * SCOPE (split, because sessions don't reliably follow the wt/autonomous-$stamp template — they improvise
#     slugs like wt/notes-w3s1-…): WORKTREE removal (Phase 1) stays narrow to "wt/autonomous*" so it can never
#     reclaim a clean *interactive* worktree out from under you. BRANCH deletion (Phase 2) covers ALL merged
#     "wt/*" refs — safe regardless of slug because git refuses to delete a branch checked out in any worktree
#     (an active worktree, yours or the daemon's, is protected) and the merged gate means zero data loss.
#   * PURELY LOCAL: no `git fetch` (the session's `push … HEAD:main` already advanced the shared
#     refs/remotes/origin/main the primary checkout sees) — so this can never hang the loop on a dead network.
#   * NEVER the primary checkout ($REPO); every step best-effort (|| true / 2>/dev/null) — no `set -e`, so a
#     failing git call can't abort the daemon loop.
housekeeping() {
  cd "$REPO" 2>/dev/null || return 0
  git rev-parse --verify --quiet origin/main >/dev/null 2>&1 || return 0   # no ref yet -> nothing to compare
  git worktree prune 2>/dev/null || true                                   # drop admin entries for gone dirs
  local dir ref br removed=0 skipped=0 delbr=0
  # Phase 1: remove SPENT worktrees with a PLAIN remove (never --force) — git refuses if there is any
  # uncommitted/untracked content, which is exactly the safety we want. Must precede branch deletion (git
  # won't delete a branch still checked out in a worktree).
  while IFS=$'\t' read -r dir ref; do
    [ -n "$dir" ] || continue
    [ "$dir" = "$REPO" ] && continue                                       # never the primary checkout
    case "$ref" in refs/heads/wt/autonomous*) ;; *) continue ;; esac       # only the daemon's own namespace
    git merge-base --is-ancestor "$ref" origin/main 2>/dev/null || continue # only provably-pushed work
    if git worktree remove "$dir" 2>/dev/null; then removed=$((removed+1)); else skipped=$((skipped+1)); fi
  done < <(git worktree list --porcelain \
             | awk '/^worktree /{w=substr($0,10)} /^branch /{print w"\t"substr($0,8)}')
  git worktree prune 2>/dev/null || true
  # Phase 2: delete ALL merged wt/* branches (any slug the sessions used). Safe: no working tree involved,
  # git refuses to delete a branch still checked out anywhere (so an active worktree — a dirty one skipped
  # above, YOUR interactive one, or the running session's — keeps its branch), and the ancestor gate means -D
  # drops no unpushed commit (plain -d would refuse these because local main lags origin/main).
  while read -r br; do
    [ -n "$br" ] || continue
    case "$br" in wt/*) ;; *) continue ;; esac
    git merge-base --is-ancestor "$br" origin/main 2>/dev/null || continue
    git branch -D "$br" 2>/dev/null && delbr=$((delbr+1))
  done < <(git for-each-ref --format='%(refname:short)' refs/heads/wt/ 2>/dev/null)
  [ $((removed + delbr)) -gt 0 ] && log "housekeeping: GC'd $removed spent worktree(s), $delbr merged branch(es)"
  [ "$skipped" -gt 0 ] && log "housekeeping: left $skipped merged-but-dirty/in-use worktree(s) for manual review"
  return 0
}

# SECURITY REMINDER (owner: TOP PRIORITY) — on ANY daemon exit, if the taskport debugger authorization is
# still password-free ('allow'), loudly remind the owner to REVERT it: daemon.log + a visible Desktop file +
# a macOS notification (best-effort). Fires once; no-op once taskport is back to authenticate-user.
_reminded=0
remind_revert_taskport() {
  [ "$_reminded" = 1 ] && return; _reminded=1
  security authorizationdb read system.privilege.taskport 2>/dev/null | grep -q '<string>allow</string>' || return
  local bk="$STATE/taskport-rule.backup.plist"
  local m="Autonomous run has EXITED but taskport debugger auth is STILL 'allow' (password-free). REVERT it:  sudo security authorizationdb write system.privilege.taskport < $bk"
  log "!!!!!!!!!!!! SECURITY REMINDER: $m"
  { echo "[$(date '+%F %T')] Archive Suite autonomous run exited."; echo; echo "$m"; } > "$HOME/Desktop/REVERT-TASKPORT-SECURITY.txt" 2>/dev/null || true
  osascript -e 'display notification "taskport auth is still password-free — REVERT it (see REVERT-TASKPORT-SECURITY.txt on your Desktop)." with title "Archive Suite: revert security setting" sound name "Basso"' >/dev/null 2>&1 || true
}
trap remind_revert_taskport EXIT
trap 'exit 0' TERM INT

# Children must be INDEPENDENT claude sessions, not NESTED. When this daemon is armed from an interactive
# Claude session it inherits CLAUDECODE / CLAUDE_CODE_* / CLAUDE_EFFORT etc., and a child `claude -p` would
# refuse to launch ("cannot be launched inside another Claude Code session"). The daemon needs none of them,
# so scrub every CLAUDE* var from this process; children then inherit a clean env. (Keeps OCR_KEY etc.)
for _v in $(env | sed -n 's/^\(CLAUDE[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$_v"; done

# Keep the machine awake for the daemon's whole lifetime. -d (prevent DISPLAY sleep) is essential, not just
# -i: even on AC (where the system won't idle-sleep), once the display sleeps macOS drops its "prevent sleep
# while display is on" assertion and the machine darkwakes/sleeps anyway — this cost a ~5h overnight stall
# on 2026-07-12 (display slept 03:27 → 5h gap). -di holds the display on and keeps the whole machine up.
caffeinate -di -w "$$" &

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
  # Watchdog A — wall-clock hard cap: TERM then KILL claude after MAXRUN. $cpid is claude's own pid.
  ( sleep "$MAXRUN"; kill -TERM "$cpid" 2>/dev/null; sleep 15; kill -KILL "$cpid" 2>/dev/null ) &
  local wpid=$!
  # Watchdog B — usage-limit fast-fail. When the account hits its cap, `claude -p` can SPIN printing
  # "You've hit your limit · resets …" for the full MAXRUN instead of exiting (wasted a 75-min window twice
  # on 2026-07-12, and squanders capacity that frees when the cap resets mid-hang). Watch only THIS session's
  # NEW output (from the byte offset captured at launch) and kill once that string repeats ≥3× — then the
  # next ~2-min cycle retries fresh. This is NOT the removed idle-watchdog: that keyed on ABSENCE of output
  # (false-killing healthy long sessions because claude buffers normal output to the end); THIS keys on a
  # SPECIFIC string that genuinely streams during the hang, and the ≥3 threshold ignores a one-off transient.
  local off; off=$(wc -c < "$STATE/last-session.log" 2>/dev/null || echo 0)
  ( while kill -0 "$cpid" 2>/dev/null; do
      sleep 20
      hits=$(tail -c "+$((off+1))" "$STATE/last-session.log" 2>/dev/null | grep -c "You've hit your limit")
      if [ "${hits:-0}" -ge 3 ]; then
        printf '%s  %s\n' "$(date '+%F %T')" "watchdog: usage-limit spam (${hits}x) — fast-failing session" >> "$LOG"
        kill -TERM "$cpid" 2>/dev/null; sleep 5; kill -KILL "$cpid" 2>/dev/null; break
      fi
    done ) &
  local lpid=$!
  wait "$cpid"; local rc=$?
  kill "$wpid" "$lpid" 2>/dev/null; wait "$wpid" "$lpid" 2>/dev/null
  log "resume session exited rc=$rc"

  kill "$hb" 2>/dev/null || true
  rm -f "$LOCK" 2>/dev/null || true
  housekeeping   # GC this (and any prior) session's spent worktree/branch — see above. Only after a real run.
  return 0
}

while true; do
  tick; rc=$?
  [ "$rc" = "9" ] && break
  sleep "$INTERVAL"
done
log "=== daemon down (pid $$) ==="
