#!/usr/bin/env bash
# ops/autonomous/arm.sh — ONE-COMMAND prep + launch + verify for the autonomous run.
#
# Collapses the whole "arm the daemon" dance (install runtime copies, check every
# prerequisite, guard the stale-COMPLETE + double-launch footguns, launch detached,
# verify the first cycle started) into a single command so it never has to be
# re-derived from README.md again.
#
# Run from the PRIMARY checkout:
#   ./ops/autonomous/arm.sh            # DEFAULT: install + verify prereqs + launch under launchd KeepAlive, so
#                                      #   a CRASH/OOM/kill auto-restarts (WS1) — best for a long unattended run.
#                                      #   Survives a daemon crash, NOT a logout/reboot (reboot out of scope).
#   ./ops/autonomous/arm.sh nohup      # opt-in: detached nohup, NO crash-restart. (GUI now runs off-screen in
#                                      #   the Tart VM — ops/gui/README §3 — so nohup no longer buys GUI-verify.)
#                                      #   `keepalive` is an explicit alias for the default.
#   ./ops/autonomous/arm.sh status     # show daemon state + supervisor + RUN STATUS + recent log (read-only)
#   ./ops/autonomous/arm.sh stop       # stop it (boots out the launchd job first, then kills the process)
#
# Prereqs it enforces (and explains if missing): claude CLI outside ~/Desktop (launchd/TCC),
# the daemon script + resume prompt present, an L0 plan whose RUN STATUS is IN_PROGRESS with
# unchecked [ ] work-queue items. See README.md for the design (L0 plan / L1 daemon / L2 prompt).
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"          # this script's checkout = where the daemon works
STATE="$HOME/.local/state/archive-autonomous"
BIN="$HOME/.local/bin"
CLAUDE="$BIN/claude"
DAEMON_SRC="$REPO/ops/autonomous/archive-suite-autonomous.sh"
DAEMON_DST="$BIN/archive-suite-autonomous.sh"
COMPACT_SRC="$REPO/ops/autonomous/compact-plan.sh"
COMPACT_DST="$BIN/compact-plan.sh"
PROMPT_SRC="$REPO/ops/autonomous/resume-prompt.txt"
PLAN="$REPO/.maintenance/AUTONOMOUS_PLAN.md"
LOG="$STATE/daemon.log"
JOB="com.archivesuite.autonomous"                        # launchd label (matches the .plist + the daemon's $JOB)
PLIST_SRC="$REPO/ops/autonomous/com.archivesuite.autonomous.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$JOB.plist"
GUI_DOMAIN="gui/$(id -u)"                                 # per-user launchd domain for the LaunchAgent

runstatus() { grep -m1 '^RUN STATUS:' "$PLAN" 2>/dev/null | cut -c1-90; }
# Why the daemon is idle is decided in ONE place, shared with status-digest.sh — see run-state-lib.sh.
# Guarded: arm.sh runs from the PRIMARY checkout, which may not have merged this file yet (memory
# `arm-installs-from-primary-checkout`). A missing lib must degrade to the old wording, not to a blank line.
if [ -r "$REPO/ops/autonomous/run-state-lib.sh" ]; then
  . "$REPO/ops/autonomous/run-state-lib.sh"
else
  idle_explanation() { printf 'running, BACKING OFF (idle %ss — reason undetermined: run-state-lib.sh not in this checkout)' "${1:-?}"; }
fi

# status — ONE renderer, in status-digest.sh. This function only forwards to it.
#
# It used to print six sections of its own (process, run state, plan, GUI, keychain, log tail) and THEN
# paste the whole digest underneath: the run state and the plan line appeared twice in two different
# wordings, and the GUI/keychain lines were fixed text that had long since stopped telling anyone anything.
# A reader had to know which of the two copies was the current one. So: no formatting lives here any more.
# `status --details` passes straight through for the diagnostics (keychain, disk, worktrees, log tail).
status() {
  local digest="$REPO/ops/autonomous/status-digest.sh"
  if [ -x "$digest" ]; then
    "$digest" "$@"
  else
    # Never leave the owner with nothing — this is the command you run when things are already broken.
    echo "status-digest.sh is missing or not executable at:"
    echo "  $digest"
    echo
    pgrep -f archive-suite-autonomous.sh >/dev/null 2>&1 \
      && echo "The worker IS running (pid $(pgrep -f archive-suite-autonomous.sh | head -1))." \
      || echo "The worker is NOT running. Start it: $0"
    tail -n 6 "$LOG" 2>/dev/null
  fi
}

fail() { echo "ERROR: $*" >&2; exit 1; }

# Optional `--dry-run` as the FIRST arg: preview the resolved launch mode + exit BEFORE any install/launch.
# An EXPLICIT flag (NOT an ambient env var) on purpose — an env var could be exported once while iterating and
# then silently turn a real `arm.sh` into a success-reporting no-op; a flag you have to type can't be inherited.
DRYRUN=""
if [ "${1:-}" = "--dry-run" ]; then DRYRUN=1; shift; fi

case "${1:-arm}" in
  status) shift; status "$@"; exit 0 ;;   # extra args (e.g. --details) pass through to the digest
  stop)
    # bootout FIRST — under `keepalive` (launchd KeepAlive=true) a plain pkill would just be relaunched, so we
    # must remove the launchd job before killing anything. Harmless no-op if the run is the plain nohup mode
    # (no such job). THEN pkill the loop + any resume session it spawned: a bare `claude -p` child is NOT
    # matched by the script-name pgrep (its cmdline is the prompt text), so killing only the loop orphans it
    # (reparented to init, running off stale state — the repeated-orphan bug); match sessions by the resume
    # prompt's distinctive phrase. Neither pattern matches arm.sh itself or an interactive Claude session.
    booted=0; launchctl bootout "$GUI_DOMAIN/$JOB" 2>/dev/null && { booted=1; echo "launchd job booted out."; }
    k=0
    pkill -f 'archive-suite-autonomous\.sh' && k=1
    pkill -f 'autonomous maintenance session for the Archive Suite' && k=1
    # WS7: a health gate in flight is `bash health-gate.sh` -> xcodebuild — matched by NEITHER pattern above
    # (same bare-child orphan class we fixed for sessions), so kill it too, else `stop` leaves a build running.
    pkill -f 'ops/autonomous/health-gate\.sh' 2>/dev/null && { k=1; echo "in-flight health gate stopped."; }
    if [ "$k" = 1 ]; then echo "daemon + any resume session stopped."
    elif [ "$booted" = 1 ]; then echo "launchd job stopped (its process was already down)."
    else echo "daemon was not running."; fi
    exit 0 ;;
  arm|keepalive) MODE='keepalive' ;;   # DEFAULT (2026-07-17): launchd KeepAlive so a crash/kill auto-restarts (WS1)
  nohup)         MODE='nohup' ;;       # opt-in: detached nohup (no crash-restart). (GUI now runs off-screen in
                                       # the Tart VM — ops/gui/README §3 — so nohup no longer buys GUI-verify.)
  *) fail "unknown command '${1}'. Use: arm | nohup | keepalive | status | stop" ;;
esac

# --dry-run: report the resolved launch mode and exit BEFORE any install/launch — a loud, unmistakable line so
# a preview is never mistaken for a real arm. (tests/prove-arm-dispatch.sh asserts the dispatch through this.)
[ -n "$DRYRUN" ] && { echo "arm.sh --dry-run: would launch in mode '$MODE' — NOTHING installed or launched."; exit 0; }

# ---- arm ----
# 1. prerequisites (each with a fix hint)
[ -x "$CLAUDE" ] || fail "claude CLI not executable at $CLAUDE — it MUST live outside ~/Desktop for launchd/TCC. Install/symlink it there."
[ -f "$DAEMON_SRC" ] || fail "daemon script missing: $DAEMON_SRC"
[ -f "$PROMPT_SRC" ] || fail "L2 resume prompt missing: $PROMPT_SRC"
[ -f "$PLAN" ]       || fail "L0 plan missing: $PLAN — write it (queue + directives) before arming."
mkdir -p "$BIN" "$STATE"

# 2. install the latest committed copies to the runtime location (source of truth = the repo)
install -m 755 "$DAEMON_SRC" "$DAEMON_DST"
install -m 755 "$COMPACT_SRC" "$COMPACT_DST"   # plan compactor: Session Log + Morning Review (daemon calls it between cycles)
cp "$PROMPT_SRC" "$STATE/resume-prompt.txt"
echo "installed: daemon -> $DAEMON_DST ; compactor -> $COMPACT_DST ; resume prompt -> $STATE/"

# 2b. ensure a stable local code-signing identity exists so Debug builds re-sign stably and the macOS
#     Keychain stops re-prompting for the API key every rebuild (see ArchiveProcessor/launch.sh).
#     Idempotent + non-fatal — a missing cert just means builds fall back to ad-hoc (the old behavior).
bash "$REPO/ops/autonomous/ensure-signing.sh" || echo "arm: ensure-signing failed (non-fatal; ad-hoc fallback)"

# 3. don't double-launch. Check the process AND the launchd job UNCONDITIONALLY (not only in keepalive mode):
#    a keepalive job can be registered but momentarily process-down (crash/throttle window), and arming plain
#    `arm.sh` then would miss it via pgrep and start a SECOND nohup sibling that park's self-bootout can't
#    stop. Checking the job regardless catches that cross-mode collision.
if pgrep -f archive-suite-autonomous.sh >/dev/null \
   || launchctl print "$GUI_DOMAIN/$JOB" >/dev/null 2>&1; then
  echo "daemon ALREADY running (or launchd job loaded) — not launching a second one:"
  pgrep -fl archive-suite-autonomous.sh || echo "  (process down but job loaded — launchd will relaunch)"
  echo "  To switch modes or restart: '$0 stop' first, then '$0' (or '$0 nohup')."
  echo; status; exit 0
fi

# 4. guard the stale-COMPLETE footgun (a finished run leaves RUN STATUS: COMPLETE; the daemon
#    would start and immediately stop). Make the fix explicit instead of silently no-op'ing.
st="$(runstatus)"
if printf '%s' "$st" | grep -q 'COMPLETE'; then
  cat >&2 <<EOF
RUN STATUS is COMPLETE — the daemon would start then immediately stop.
To (re)start a run, edit:
  $PLAN
  * set the marker line to:  RUN STATUS: IN_PROGRESS — <one-line note>
  * ensure the WORK QUEUE has unchecked [ ] items (extend it if the last run drained it).
Then re-run: $0
EOF
  exit 1
fi
echo "plan status OK: $st"

# 5. launch — launchd KeepAlive (DEFAULT, crash-restart; WS1) or opt-in detached nohup
if [ "$MODE" = keepalive ]; then
  # Install the LaunchAgent + (re)bootstrap it. RunAtLoad launches the daemon; KeepAlive=true relaunches it
  # on any bootout-less death (crash/OOM/stray signal). `arm.sh stop`, park, and plan-COMPLETE all bootout,
  # so intentional stops still stick. NOTE: a LaunchAgent loads in your GUI login session — it survives a
  # daemon CRASH, not a logout/reboot (reboot-survival is deliberately out of scope). (GUI verification now
  # runs off-screen in the Tart VM regardless of supervisor — ops/gui/README §3 — so no host TCC grant matters.)
  plutil -lint "$PLIST_SRC" >/dev/null || fail "plist is malformed: $PLIST_SRC"
  mkdir -p "$HOME/Library/LaunchAgents"
  install -m 644 "$PLIST_SRC" "$PLIST_DST"
  launchctl bootout "$GUI_DOMAIN/$JOB" 2>/dev/null || true   # clear any stale registration first
  if launchctl bootstrap "$GUI_DOMAIN" "$PLIST_DST"; then
    echo "launched (launchd KeepAlive [default]; plist -> $PLIST_DST) — a crash/kill auto-restarts."
  else
    fail "launchctl bootstrap failed — check: launchctl print $GUI_DOMAIN/$JOB"
  fi
else
  # macOS has no setsid; subshell + nohup survives this shell returning (reparented to init).
  ( nohup "$DAEMON_DST" >"$STATE/nohup.out" 2>&1 & )
  echo "launched (detached nohup — NO crash-restart; the default '$0' uses launchd KeepAlive instead)."
fi

# 6. verify the first cycle actually started (bounded poll — no unbounded wait)
ok=""
for _ in $(seq 1 20); do
  if pgrep -f archive-suite-autonomous.sh >/dev/null && tail -n 4 "$LOG" 2>/dev/null | grep -q 'daemon up'; then
    ok=1; break
  fi
  sleep 0.5
done
echo
if [ -n "$ok" ]; then echo "✅ daemon is up and starting its first session."; else
  echo "⚠️  launched, but did not confirm a fresh cycle within 10s — check the log:"; fi
status