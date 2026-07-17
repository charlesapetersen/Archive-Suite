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
REPO="${AUTONOMOUS_REPO:-/Users/<user>/Claude/Archive Suite}"  # the checkout to work in (worktrees branch off it)
PLAN="${AUTONOMOUS_PLAN:-$REPO/.maintenance/AUTONOMOUS_PLAN.md}"     # L0 durable plan (keep it gitignored)
STATE="${AUTONOMOUS_STATE:-$HOME/.local/state/archive-autonomous}"  # runtime state (logs, lock, resume prompt)
CLAUDE="${AUTONOMOUS_CLAUDE:-$HOME/.local/bin/claude}"             # claude CLI — MUST be outside ~/Desktop (launchd/TCC)
# =======================================================================================================
LOCK="$STATE/engine.lock"; LOG="$STATE/daemon.log"; PROMPT="$STATE/resume-prompt.txt"
JOB="com.${LABEL}.autonomous"    # launchd label (matches the .plist)

INTERVAL="${AUTONOMOUS_INTERVAL:-90}"     # idle gap between cycles (90 s — near back-to-back; sessions run
                                          # ~10 min+, so this is the effective cadence. Was 1200/20min → 120s
                                          # (2026-07-11) → 90s (2026-07-12), tightened for faster throughput.
                                          # Override with AUTONOMOUS_INTERVAL.
STALE="${AUTONOMOUS_STALE:-1500}"         # a lock older than this (25 min) is stale -> take over
MAXRUN="${AUTONOMOUS_MAXRUN:-10800}"      # OUTER wall-clock backstop (3 h). The health watchdog (Layers 1+2,
                                          # below) is the PRIMARY killer now; this only fires if that fails or
                                          # a session is productive-but-endless. Was 4500/75min — raised
                                          # 2026-07-12 so healthy long sessions (Notes waves ran 30–78 min)
                                          # stop getting guillotined by the clock alone.
BUDGET="${AUTONOMOUS_BUDGET:-30}"         # --max-budget-usd per resume session
EFFORT="${AUTONOMOUS_EFFORT:-max}"        # reasoning effort for every resume session (low|medium|high|max)

# Idle backoff — the loop's answer to "nothing is happening". $INTERVAL is the cadence while the run is
# PRODUCTIVE; a cycle that advances nothing doubles the gap up to $MAXBACKOFF, and $IDLE_STOP of unbroken
# no-progress parks the run + stops the daemon. Any progress resets to $INTERVAL instantly. Rationale + the
# two waste modes this closes: ops/autonomous/README.md "Idle backoff" (added 2026-07-16).
MAXBACKOFF="${AUTONOMOUS_MAXBACKOFF:-1800}"  # ceiling on the idle gap (30 min)
IDLE_STOP="${AUTONOMOUS_IDLE_STOP:-21600}"   # 6 h of zero progress -> park + stop (0 disables the auto-stop)

# Disk guard (WS2) — a full disk fails EVERY build, so without this a long run just burns sessions failing to
# compile and never says why. Checked BEFORE launching a session; tries housekeeping to reclaim first, then
# parks + alerts. Fail-OPEN on an unreadable reading (a broken check must never stop a healthy run).
MINFREE_MB="${AUTONOMOUS_MINFREE_MB:-10240}" # park below this much free space on $REPO's volume (10 GB)

# Health watchdog (Layers 1+2) — detect a session that has gone ASTRAY without relying on the clock. The
# session runs with --output-format stream-json --include-partial-messages (see the launch in tick()), so
# last-session.log grows IN REAL TIME with a JSON event per assistant-message / tool_use / tool_result AND
# per token-delta during generation (verified: file flushes per-event on CLI 2.1.207). Token-delta streaming
# is why a long effort=max generation is NOT mistaken for a hang: the log keeps growing while the model
# thinks, so only the brief prefill/TTFT gap is truly silent. Signals, combined so no single false-positive
# kills a healthy session (each backed by an adversarial review — see ops/autonomous/README.md):
#   L1 (event heartbeat): the log's NON-rate_limit_event bytes stop growing for HB_STALL -> "quiet". (Filtered
#                         so a rate-limit spin can't masquerade as progress.)
#   L2 (liveness)       : when quiet, spare the session if EITHER an active `claude` DESCENDANT exists (a
#                         running subagent/Workflow child, whose own work doesn't stream into the parent log)
#                         OR the process tree is burning CPU (a long xcodebuild/test). Idle tree, no subagent,
#                         for HB_IDLE_N consecutive polls -> genuinely wedged -> kill. A CPU-busy tree with no
#                         subagent and no events for HB_HARD -> runaway build/loop -> kill.
# NOTE (accepted gap): a CPU-busy CHATTY loop (log keeps growing, e.g. re-running the same failing test) is
# NOT caught here — it's bounded by --max-budget-usd and the MAXRUN backstop, not the health watchdog.
# NOTE: usage-limit handling is not a separate watchdog — CLI 2.1.207 fast-fails an exhausted limit (rc=1 in
# ~2s, observed), and a rate-limit WAIT is caught by L1 (rate_limit_event bytes are filtered out).
HB_POLL="${AUTONOMOUS_HB_POLL:-20}"       # seconds between health polls
HB_STALL="${AUTONOMOUS_HB_STALL:-600}"    # non-rate-limit log quiet this long -> start the L2 idle check
HB_HARD="${AUTONOMOUS_HB_HARD:-2400}"     # CPU-busy but no events this long (no subagent) -> runaway -> kill
HB_CPU="${AUTONOMOUS_HB_CPU:-3}"          # a tree whose summed %CPU exceeds this is "busy" (spare it)
HB_IDLE_N="${AUTONOMOUS_HB_IDLE_N:-3}"    # consecutive idle polls (idle tree, no subagent) before a wedged-kill

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

# Alert config lives in its OWN file, sourced WITHOUT `set -a`, and that is load-bearing — NOT style.
# $STATE/env is the CHILD's environment: tick() re-sources it under allexport to hand PATH/OCR_KEY to
# `claude -p`. Anything placed there is inherited by every session — and a session is an LLM agent with Bash
# + WebFetch whose curl/wget deny-list exists precisely so it CANNOT phone out. Handing it the operator's
# alert endpoint/credential would defeat that (env is readable; WebFetch is a sufficient exfil channel, and
# repo content it reads over a 2-week run is a prompt-injection surface). Keeping ALERT_* as plain
# NON-exported shell vars means notify() (same shell) sees them and the child never does.
# Also deliberately does NOT source $STATE/env here: that file may set PATH, and this runs before the
# `caffeinate` launch below — a PATH without /usr/bin would silently fail to keep the Mac awake.
[ -f "$STATE/alert.env" ] && . "$STATE/alert.env"

# ===== Remote alerting (WS6) — reach an owner who is NOT at the machine =====
# Everything else the daemon does on a blocking event (a Desktop file + an osascript notification) is useless
# to an owner who is away, which is exactly when an unattended run needs them. Every "park + alert" path
# routes through here. Deliberately GENERIC (a plain POST) so no service is baked in: ntfy.sh works with zero
# setup ($STATE/alert.env: ALERT_URL="https://ntfy.sh/<your-private-topic>"), and any webhook that accepts a
# POST body will do; ALERT_AUTH is sent as an Authorization header if set. Config belongs in alert.env, NOT
# $STATE/env — see the sourcing note above (env is the CHILD's, alert.env is the daemon's).
#   * NO-OP when unconfigured (ALERT_URL unset) — the daemon must run fine without it.
#   * NEVER fatal, and --max-time so a dead network can never hang the loop.
#   * NEVER logs $ALERT_URL / $ALERT_AUTH (the URL itself is the secret for ntfy-style topics) — title only.
# NOTE: `curl` is in the DENY list for `claude -p` SESSIONS, not for this daemon loop; the loop is plain bash
# and may call it. That asymmetry is intentional: sessions must not phone out, the operator's daemon must.
notify() {
  local title msg
  # Strip CR/LF: $title becomes an HTTP header value, and curl does NOT reject embedded newlines — it emits
  # them as extra real headers (verified). Callers pass free-ish text, so sanitise at the boundary.
  title=$(printf '%s' "$1" | tr -d '\r\n')
  msg="$2"
  [ -n "${ALERT_URL:-}" ] || return 0
  # ARRAY, not a string — same lesson the ALLOW/DENY arrays above record: a header value contains spaces, so
  # it MUST be exactly one argv element. The tempting `${ALERT_AUTH:+-H "Authorization: $ALERT_AUTH"}` is
  # broken: the quotes inside a :+ expansion are literal, and it collapses to ONE malformed argv (verified on
  # bash 3.2), which curl rejects. Seeded non-empty so "${args[@]}" is safe under `set -u` on macOS bash 3.2
  # (an empty array there is an "unbound variable" error).
  local -a args=(-fsS --max-time 15 -X POST -H "Title: $title")
  [ -n "${ALERT_AUTH:-}" ] && args+=(-H "Authorization: $ALERT_AUTH")
  # Body via STDIN, never as an argv value: curl treats a LEADING '@' in --data-binary as "read this file",
  # and '@-' means "read stdin" — which, from a nohup'd daemon whose stdin is an idle TTY, hangs FOREVER and
  # is NOT bounded by --max-time (verified). No current caller starts with '@', but this is a generic sink for
  # every future workstream's alerts, so make it structurally impossible: the arg is always the literal '@-'
  # and stdin is a printf that closes immediately.
  args+=(--data-binary @- "$ALERT_URL")
  if printf '%s' "$msg" | curl "${args[@]}" >/dev/null 2>&1; then
    log "alert sent: $title"
  else
    log "alert FAILED (non-fatal, continuing): $title"
  fi
  return 0
}

# ---- Disk guard (WS2) ----
# macOS/BSD `df -m` column 4 = Available MB. Quoted: $REPO contains a space. Everything the run writes lives
# on this one volume ($REPO + its ../suite-wt-* worktrees + their build/DD), so one check is honest here.
# Any unparseable output (empty, wrapped long-device-name line, a suffix, negative) trips the numeric guard
# below and FAILS OPEN — a broken check must never stop a healthy run.
free_mb() { df -m "$REPO" 2>/dev/null | awk 'NR==2 {print $4}'; }

# 0 = enough space (or unknown -> fail open). 1 = genuinely low even after reclaiming.
# Publishes the deciding figure in $LAST_FREE_MB so the caller's alert can't disagree with the decision (or
# render an empty number) by re-measuring.
LAST_FREE_MB="?"
disk_ok() {
  local f; f="$(free_mb)"
  case "$f" in ''|*[!0-9]*) return 0 ;; esac              # unreadable -> fail OPEN, never block a good run
  LAST_FREE_MB="$f"
  [ "$f" -ge "$MINFREE_MB" ] && return 0
  # Self-heal before giving up: housekeeping GCs spent worktrees AND their per-worktree build/DD, which is
  # usually where the gigabytes went. Purely local. Safe to call HERE only because the caller has already
  # established that no other engine is active — see the note at tick() step 3b.
  log "low disk: ${f}MB free (< ${MINFREE_MB}MB) — running housekeeping to reclaim…"
  housekeeping
  f="$(free_mb)"
  case "$f" in ''|*[!0-9]*) return 0 ;; esac
  LAST_FREE_MB="$f"
  [ "$f" -ge "$MINFREE_MB" ] && { log "disk reclaimed: ${f}MB free — continuing."; return 0; }
  return 1
}

# ===== Idle backoff (2026-07-16) — see ops/autonomous/README.md "Idle backoff" =====
# The loop used to fire every $INTERVAL unconditionally and only ever stop on `RUN STATUS: COMPLETE`, which
# a session sets ONLY after finishing the LAST "[ ]" item. So a run whose queue is non-empty but every item
# is BLOCKED (owner-gated / GUI-gated / deliberately skipped) had no terminal state and spun forever. Two
# real waste modes, both observed 2026-07-16:
#   A. usage window exhausted -> claude fast-fails rc=1 in ~3s -> ~40 pointless spawns/hour for hours.
#   B. nothing actionable -> a FULL session (reads a 250KB plan + SUITE_TODO + git log, up to $BUDGET) burns
#      real tokens to re-reach "nothing to do", every 90s.
# Fix: any cycle that ADVANCES NOTHING doubles the gap ($INTERVAL -> $MAXBACKOFF); any progress resets it.
#
# "Progress" is DERIVED, never self-reported — the session can't forget to set a flag, and a model that
# wrongly believes it worked can't lie its way out of the backoff. A cycle counts as progress iff the work
# fingerprint below actually moved (independent of exit code — see the verdict block in tick() for why rc is
# deliberately NOT part of this).
#
# The fingerprint hashes the DECISION SURFACE a fresh session reads to choose work: the repo tip, the plan's
# RUN STATUS + WORK QUEUE, and the GUI gate. Session Log / Morning Review / E2E findings are EXCLUDED ON
# PURPOSE: a no-op session still appends its reasoning there, and hashing that churn would reset the backoff
# every single cycle and silently restore the old spin.
work_fingerprint() {
  {
    git -C "$REPO" rev-parse HEAD 2>/dev/null || echo no-head
    grep -m1 '^RUN STATUS:' "$PLAN" 2>/dev/null || echo no-status
    awk '/^## WORK QUEUE/{f=1;print;next} f && /^## /{exit} f' "$PLAN" 2>/dev/null
    cat "$STATE/gui-mode" 2>/dev/null || echo no-gui
  } | shasum -a 256 2>/dev/null | cut -d' ' -f1
}

# NOTE (why the fingerprint is an ACCELERATOR, not a gate): it is tempting to SKIP the session outright while
# the fingerprint is unchanged ("a fresh session would provably reach the same conclusion — don't pay for
# it"). That is WRONG and was rejected on evidence: on 2026-07-16 the 09:34 session concluded "nothing
# autonomously actionable", then at 10:40 — same HEAD, same queue, same gui-mode, i.e. an IDENTICAL
# fingerprint — a session found real work and shipped the code-signing fix (496d202) plus the segment-json
# de-dup. These sessions are NONDETERMINISTIC, so "same inputs => same conclusion" does not hold. A skip-gate
# would have suppressed that work indefinitely. So an unchanged fingerprint only means "keep backing off"
# (still retrying, just rarely); a CHANGED one is a positive signal to retry NOW.
BACKOFF="$INTERVAL"
IDLE_SINCE="$STATE/idle.since"
# Clear the idle stamp at every daemon startup so the two halves of the state machine share a lifetime:
# BACKOFF is in-memory (dies with the process), so idle.since must too — otherwise a stale stamp from a
# PRIOR run makes the first no-progress cycle compute a huge idle age and PARK on cycle 1, turning the
# owner's re-arm (an explicit "try again" signal) into a single retry. Arming a run always buys a full
# $IDLE_STOP window. (Confirmed-HIGH review finding, 2026-07-16 — see README "Idle backoff".)
rm -f "$IDLE_SINCE" 2>/dev/null || true

note_progress() {   # something moved -> back to the productive cadence
  [ "$BACKOFF" != "$INTERVAL" ] && log "progress — backoff reset to ${INTERVAL}s."
  BACKOFF="$INTERVAL"; rm -f "$IDLE_SINCE" 2>/dev/null || true
}

# Sleep out the current $BACKOFF, but WAKE EARLY the moment the decision surface changes. This is the other
# half of "accelerator, not gate": backing off is what stops the waste, but the owner arming an item or
# flipping gui-mode must not then sit through a 30-minute nap — that flip is exactly what unblocked the
# 2026-07-15 run. Without this the backoff is a pure latency tax on the owner's own unblocking action.
# Poll cost is trivial (one rev-parse + one hash per step) and bounded to a 30s granularity.
backoff_sleep() {
  local fp0 waited=0 step
  fp0="$(work_fingerprint)"
  step="$BACKOFF"; [ "$step" -gt 30 ] && step=30
  while [ "$waited" -lt "$BACKOFF" ]; do
    sleep "$step"; waited=$(( waited + step ))
    if [ "$(work_fingerprint)" != "$fp0" ]; then
      log "decision surface changed during backoff (commit / queue edit / GUI flip) — retrying now."
      note_progress; return 0
    fi
  done
}

# Park the run: stop cleanly and say so LOUDLY (log + Desktop file + local notification + REMOTE alert)
# rather than idle forever holding a caffeinate assertion. Callers: the idle path (no progress for
# $IDLE_STOP) and the disk guard (WS2) — hence the reason/message parameters rather than a hardcoded idle
# message. Deliberately does NOT rewrite RUN STATUS: the plan stays IN_PROGRESS so a plain re-arm resumes
# with no edit, and the EXIT trap still fires the taskport security reminder.
#   $1 = short reason (log + notification title)   $2 = the owner-facing message
park_run() {
  local reason="$1" m="$2"
  rm -f "$IDLE_SINCE" 2>/dev/null || true   # belt-and-braces: never leave a stamp a re-arm could trip over
  log "!!!!!!!!!!!! PARKED ($reason) — stopping. $m"
  { echo "[$(date '+%F %T')] $m"; } > "$HOME/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt" 2>/dev/null || true
  notify "Archive Suite: run parked ($reason)" "$m"
  # $reason goes in as an argv PARAMETER, never interpolated into the script text: a double quote in it would
  # otherwise close the AppleScript string and the rest would EXECUTE (`do shell script …` — verified RCE).
  # Today's callers are fixed text + numbers, but one future caller surfacing a build error or a path is all
  # it would take, so make it structurally impossible.
  osascript -e 'on run argv
display notification ("Run parked: " & (item 1 of argv) & ". See ARCHIVE-SUITE-RUN-PARKED.txt on your Desktop.") with title "Archive Suite: autonomous run parked" sound name "Basso"
end run' "$reason" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)/$JOB" 2>/dev/null || true
}

# Returns 9 when the run has been idle past $IDLE_STOP (caller stops the loop); 0 to keep going.
note_no_progress() {
  local now idle since
  now=$(date +%s)
  # Re-stamp on anything non-numeric (missing, empty, or a truncated write) — a bad stamp must never wedge
  # the arithmetic below, and re-stamping only ever DELAYS the park (fails safe: never an early auto-stop).
  since=$(cat "$IDLE_SINCE" 2>/dev/null)
  case "$since" in ''|*[!0-9]*) since="$now"; echo "$now" > "$IDLE_SINCE" 2>/dev/null || true ;; esac
  idle=$(( now - since ))
  BACKOFF=$(( BACKOFF * 2 ))
  [ "$BACKOFF" -gt "$MAXBACKOFF" ] && BACKOFF="$MAXBACKOFF"
  if [ "$IDLE_STOP" -gt 0 ] && [ "$idle" -ge "$IDLE_STOP" ]; then
    local hrs=$(( IDLE_STOP / 3600 ))
    park_run "no progress for ${hrs}h" \
      "Archive Suite autonomous run PARKED: ${hrs}h with no progress — every remaining queue item looks blocked on you (owner/GUI-gated). Nothing was lost; the plan is intact. Check:  ./ops/autonomous/arm.sh status   then re-arm with:  ./ops/autonomous/arm.sh"
    return 9
  fi
  log "no progress (idle ${idle}s) — next attempt in ${BACKOFF}s."
  return 0
}

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
  notify "Archive Suite: REVERT security setting" "$m"   # WS6 — an away owner must hear about a standing exposure
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

# ---- Health watchdog (Layers 1+2) — see the HB_* config block above for the full rationale. ----
# Print pid $1 and every descendant pid. macOS `ps` has no recursive ppid filter, so snapshot the whole
# pid/ppid table once and BFS it. Purely local, best-effort (a dead pid just yields nothing).
_descendants() {
  local root="$1" map frontier all next p k kids
  map="$(ps -axo pid=,ppid= 2>/dev/null)"
  frontier="$root"; all="$root"
  while [ -n "$frontier" ]; do
    next=""
    for p in $frontier; do
      kids="$(printf '%s\n' "$map" | awk -v pp="$p" '$2==pp{print $1}')"
      for k in $kids; do
        case " $all " in *" $k "*) ;; *) all="$all $k"; next="$next $k" ;; esac
      done
    done
    frontier="$next"
  done
  printf '%s\n' $all
}

# Kill pid $1 AND its whole descendant tree (so a runaway build/git child isn't orphaned when claude dies).
# Snapshots the tree UP FRONT (once claude dies its children reparent to init and drop off _descendants), TERMs
# all now, and schedules a DETACHED KILL backstop that survives this daemon's own cleanup of the watchdog — so
# there is no race between "main reaps the watchdog" and "the KILL lands". Returns immediately.
_terminate_tree() {
  local root="$1" victims p
  kill -0 "$root" 2>/dev/null || return 0        # never fire on a stale/reused pid (orphaned-watchdog guard)
  victims="$(_descendants "$root")"
  for p in $victims; do kill -TERM "$p" 2>/dev/null; done
  ( sleep 8; for p in $victims; do kill -KILL "$p" 2>/dev/null; done ) &
}

# Integer sum of %CPU across pid $1's process tree. macOS `ps %cpu` is a decaying average over recent real
# time, so a tree quiet for HB_STALL decays toward 0 while a live build/test stays high.
_tree_cpu() {
  local p cpu total=0
  for p in $(_descendants "$1"); do
    cpu="$(ps -o %cpu= -p "$p" 2>/dev/null | tr -d ' ')"
    case "$cpu" in ''|*[!0-9.]*) continue ;; esac
    total="$(awk -v t="$total" -v c="$cpu" 'BEGIN{printf "%d", t + c}')"
  done
  printf '%s\n' "$total"
}

# Meaningful log bytes = size of the stream-json log EXCLUDING rate_limit_event lines, so a rate-limit spin
# (log growing with only throttle notices) does NOT register as progress. Anchored to the "type":"..." key
# (not a bare substring) so a tool_result that merely CONTAINS the text "rate_limit_event" isn't dropped.
_meaningful_bytes() {
  grep -v '"type":"rate_limit_event"' "$1" 2>/dev/null | wc -c | tr -d ' '
}

# True if any DESCENDANT of pid $1 (not $1 itself) is a `claude` process = a running subagent/Workflow child.
# A subagent's own work does NOT stream into the parent's log and may sit at ~0% CPU (blocked on the API), so
# its mere presence is an independent liveness signal. Matches a lowercase "/claude" path component (the CLI
# lives under ~/.local/.../claude); the repo path is ~/Claude (capital C), so built apps under it (e.g.
# ArchiveNotes.app) are NOT matched.
_has_claude_descendant() {
  local p comm
  for p in $(_descendants "$1"); do
    [ "$p" = "$1" ] && continue
    comm="$(ps -o comm= -p "$p" 2>/dev/null)"
    case "$comm" in */claude|*/claude/*) return 0 ;; esac
  done
  return 1
}

# Monitor claude pid $1 and TERM/KILL it when the session is wedged or a single tool has run away. Args:
#   $1=cpid  $2=stream-json logfile  $3=baseline meaningful-byte count at launch.
# Globals: HB_POLL HB_STALL HB_HARD HB_CPU LOG. Returns when cpid dies (0) or after it issues a kill.
health_watchdog() {
  local cpid="$1" logf="$2" last="$3"
  local quiet_since=0 now sz quiet busy idle_streak=0
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  while kill -0 "$cpid" 2>/dev/null; do
    sleep "$HB_POLL"
    sz="$(_meaningful_bytes "$logf")"
    case "$sz" in ''|*[!0-9]*) sz="$last" ;; esac
    if [ "$sz" -gt "$last" ]; then last="$sz"; quiet_since=0; idle_streak=0; continue; fi  # L1: real event -> alive
    now="$(date +%s)"
    [ "$quiet_since" = 0 ] && quiet_since="$now"
    quiet=$(( now - quiet_since ))
    [ "$quiet" -lt "$HB_STALL" ] && continue                     # not quiet long enough to judge yet
    # L2 — quiet >= HB_STALL. Spare if the session is still doing real work by EITHER signal:
    if _has_claude_descendant "$cpid"; then idle_streak=0; continue; fi      # (a) active subagent/Workflow child
    busy="$(_tree_cpu "$cpid")"; case "$busy" in ''|*[!0-9]*) busy=0 ;; esac
    if [ "$busy" -gt "$HB_CPU" ]; then                                       # (b) CPU-busy tool (build/test)
      idle_streak=0
      [ "$quiet" -lt "$HB_HARD" ] && continue                               # legit long build/test -> spare
      printf '%s  %s\n' "$(date '+%F %T')" \
        "watchdog: CPU-busy but no events ${quiet}s (>= HB_HARD ${HB_HARD}s), no subagent — runaway build/loop, killing tree of pid $cpid" >> "$LOG"
      _terminate_tree "$cpid"; return 0
    fi
    # Idle tree, no subagent. Require HB_IDLE_N consecutive idle polls so a brief low-CPU dip (linking, I/O
    # wait) inside a real tool doesn't false-kill.
    idle_streak=$(( idle_streak + 1 ))
    [ "$idle_streak" -lt "$HB_IDLE_N" ] && continue
    printf '%s  %s\n' "$(date '+%F %T')" \
      "watchdog: session wedged (${quiet}s no events, tree idle ${busy}% CPU, ${idle_streak} idle polls) — killing tree of pid $cpid" >> "$LOG"
    _terminate_tree "$cpid"; return 0
  done
  return 0
}

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

  # 3b. Disk guard (WS2). Placed AFTER the step-3 "another engine active" check ON PURPOSE, not for tidiness:
  #     disk_ok() calls housekeeping() to try to reclaim, and housekeeping's whole safety argument rests on
  #     running BETWEEN sessions with no session active. Checking earlier would let this engine GC another,
  #     live engine's worktree mid-build — and `git worktree remove` (no --force) does NOT refuse a worktree
  #     whose only content is gitignored, which is exactly what build/DD is (verified). Still before the
  #     lock/launch, so we never start a session we already know cannot build.
  if ! disk_ok; then
    park_run "low disk (${LAST_FREE_MB}MB free)" \
      "Archive Suite autonomous run PARKED — LOW DISK: only ${LAST_FREE_MB}MB free on the repo volume (need ${MINFREE_MB}MB). Every build would fail, so the run stopped instead of burning sessions. Free some space (per-worktree build/DD is usually the culprit), then re-arm:  ./ops/autonomous/arm.sh"
    return 9
  fi

  # 3c. Snapshot the decision surface BEFORE the session so we can tell afterwards whether the session
  #     actually advanced the run (see the idle-backoff block above). Cheap: one rev-parse + one hash.
  local fp_before; fp_before="$(work_fingerprint)"

  # 4. Acquire the lock + heartbeat it for the child's lifetime, so overlapping cycles/sessions skip.
  touch "$LOCK"
  local ppid=$$
  ( while kill -0 "$ppid" 2>/dev/null; do touch "$LOCK" 2>/dev/null; sleep 60; done ) &
  local hb=$!

  # 5. Optional per-project env hook (e.g. a test API key) into the child env, without ever printing it.
  #    Archive Suite: $STATE/ocr-key.env holds `OCR_KEY=…` for the E2E (absent by default -> Keychain fallback).
  set -a; [ -f "$STATE/env" ] && . "$STATE/env"; [ -f "$STATE/ocr-key.env" ] && . "$STATE/ocr-key.env"; set +a
  # Defence in depth (WS6): alert config belongs in $STATE/alert.env, but if an operator puts ALERT_* in
  # $STATE/env by mistake, the `set -a` above just marked them for export and the session would inherit the
  # alert credential. Strip the export attribute only — notify() (this shell) keeps the value, the child
  # cannot see it. Mirrors the CLAUDE*-scrub rationale below.
  export -n ALERT_URL ALERT_AUTH 2>/dev/null || true

  log "launching fresh resume session (backstop ${MAXRUN}s, budget \$$BUDGET, health-wd on)…"
  cd "$REPO" || { log "cannot cd $REPO — skip."; kill "$hb" 2>/dev/null; rm -f "$LOCK"; return 0; }
  # Fresh per-session log (keep one previous). stream-json is larger than text, so don't append forever; a
  # fresh file also gives the heartbeat + usage watchdogs a clean zero baseline.
  local SLOG="$STATE/last-session.log"
  [ -f "$SLOG" ] && mv -f "$SLOG" "$SLOG.prev" 2>/dev/null; : > "$SLOG"
  # Run claude in the background so watchdogs can TERM/KILL it (macOS has no `timeout`). $cpid is claude's own
  # pid. --output-format stream-json --include-partial-messages makes $SLOG grow with a JSON event per
  # message/tool AND per token-delta during generation, IN REAL TIME — the health watchdog (Watchdog C) uses
  # that as a liveness heartbeat (token-delta streaming keeps a long effort=max generation from looking hung).
  "$CLAUDE" -p "$(cat "$PROMPT")" \
      --permission-mode default \
      --model opus --fallback-model sonnet \
      --effort "$EFFORT" \
      --max-budget-usd "$BUDGET" \
      --output-format stream-json --verbose --include-partial-messages \
      --allowedTools "${ALLOW[@]}" \
      --disallowedTools "${DENY[@]}" \
      >> "$SLOG" 2>&1 &
  local cpid=$!
  # Watchdog A — OUTER wall-clock backstop. POLLS cpid liveness (rather than one long unconditional sleep) so
  # it self-exits promptly when the session ends AND never fires _terminate_tree against a stale/reused pid if
  # the daemon dies uncleanly (crash/OOM/kill-by-pid). Last resort behind the health watchdog (Watchdog C).
  ( waited=0
    while [ "$waited" -lt "$MAXRUN" ]; do
      kill -0 "$cpid" 2>/dev/null || exit 0
      sleep "$HB_POLL"; waited=$(( waited + HB_POLL ))
    done
    _terminate_tree "$cpid" ) &
  local wpid=$!
  # (No separate usage-limit watchdog: CLI 2.1.207 fast-fails an exhausted limit on its own — rc=1 in ~2s,
  # observed — and a rate-limit WAIT is caught by Watchdog C, whose heartbeat filters rate_limit_event bytes.
  # The old text-scraping usage grep was dropped: it can't see stream-json's structured event and would
  # false-kill a session that merely reads a file mentioning the limit phrase — this daemon being one.)
  # Watchdog C — health (Layers 1+2): event heartbeat + subagent/CPU liveness. PRIMARY killer for wedged/
  # runaway sessions (see health_watchdog + the HB_* config block). Baseline 0 (fresh log).
  health_watchdog "$cpid" "$SLOG" 0 &
  local cwpid=$!
  wait "$cpid"; local rc=$?
  kill "$wpid" "$cwpid" 2>/dev/null; wait "$wpid" "$cwpid" 2>/dev/null
  log "resume session exited rc=$rc"
  # Best-effort readable mirror of the final result for Morning Review (jq present -> extract; else skip).
  if command -v jq >/dev/null 2>&1; then
    jq -rc 'select(.type=="result") | (.result // .error // empty)' "$SLOG" 2>/dev/null \
      | tail -1 > "$STATE/last-session.txt" 2>/dev/null || true
  fi

  # Progress verdict — DERIVED, not self-reported (see the idle-backoff block above): progress is the
  # decision surface actually MOVING, independent of exit code. Deliberately NOT gated on rc==0: a session
  # that ships a commit and is THEN killed (budget cap / watchdog) or exits nonzero still advanced the run,
  # and must reset the backoff — gating on rc==0 would let a run that keeps committing-then-dying march to a
  # false park. The failure side needs no rc check either: a usage-limit fast-fail (rc=1, ~3s) can't move
  # the fingerprint, so it falls through to no-progress on its own. Evaluated HERE — before housekeeping +
  # compact-plan — so neither the worktree GC nor a Session-Log compaction is mistaken for the run advancing.
  local fp_after; fp_after="$(work_fingerprint)"
  local verdict=0
  if [ -n "$fp_after" ] && [ "$fp_after" != "$fp_before" ]; then
    note_progress
  else
    log "session (rc=$rc) advanced nothing (queue + tip unchanged) — no progress."
    note_no_progress || verdict=9
  fi

  kill "$hb" 2>/dev/null || true
  rm -f "$LOCK" 2>/dev/null || true
  housekeeping   # GC this (and any prior) session's spent worktree/branch — see above. Only after a real run.
  # Keep the durable plan small: archive old Session Log entries so the plan a fresh session reads doesn't
  # inflate startup cost unbounded. Runs HERE — between cycles, lock released, NO session active — so it can
  # never race a session's Session Log append. Self-gating (no-op under its trigger); failure never breaks
  # the loop (the compactor bails leaving the plan untouched; the `|| true` swallows any error anyway).
  if [ -x "$HOME/.local/bin/compact-plan.sh" ]; then
    "$HOME/.local/bin/compact-plan.sh" "$REPO" >> "$LOG" 2>&1 || true
  fi
  return "$verdict"
}

# The gap is $BACKOFF (not a flat $INTERVAL): it IS $INTERVAL while the run is productive, doubles toward
# $MAXBACKOFF once cycles stop advancing anything, and is cut short the moment the decision surface changes.
# rc 9 = terminal (RUN STATUS: COMPLETE, or parked after $IDLE_STOP of no progress) -> fall out of the loop
# and let the EXIT trap fire the taskport security reminder.
while true; do
  tick; rc=$?
  [ "$rc" = "9" ] && break
  backoff_sleep
done
log "=== daemon down (pid $$) ==="
