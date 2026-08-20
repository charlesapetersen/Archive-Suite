#!/usr/bin/env bash
# ops/autonomous/daemon.sh — ONE-COMMAND prep + launch + verify for the autonomous run.
#
# Renamed from `arm.sh` on 2026-08-06 (owner), and the verb "arm" is retired with it: the command is now
# `start`. `arm`/`re-arm` was jargon that had to be explained every time it appeared in a park note.
#
# Collapses the whole "start the daemon" dance (install runtime copies, check every
# prerequisite, guard the stale-COMPLETE + double-launch footguns, launch detached,
# verify the first cycle started) into a single command so it never has to be
# re-derived from README.md again.
#
# Run from the PRIMARY checkout:
#   ./ops/autonomous/daemon.sh start   # install + verify prereqs + launch under launchd KeepAlive, so a
#                                      #   CRASH/OOM/kill auto-restarts (WS1) — best for a long unattended run.
#                                      #   Survives a daemon crash AND, until you `stop`, a logout/reboot:
#                                      #   launchd re-bootstraps ~/Library/LaunchAgents at the next GUI login
#                                      #   (W32.plist-relogin). `stop` removes the plist, so a stop sticks.
#   ./ops/autonomous/daemon.sh         # same thing — a bare invocation still means `start`.
#   ./ops/autonomous/daemon.sh stop    # stop it (boots out the launchd job first, then kills the process)
#   ./ops/autonomous/daemon.sh status  # daemon state + supervisor + RUN STATUS + recent log (read-only)
#   ./ops/autonomous/daemon.sh nohup   # opt-in: detached nohup, NO crash-restart. (GUI now runs off-screen in
#                                      #   the Tart VM — ops/gui/README §3 — so nohup no longer buys GUI-verify.)
#                                      #   `keepalive` is an explicit alias for the default `start` mode.
#
# Prereqs it enforces (and explains if missing): claude CLI outside ~/Desktop (launchd/TCC),
# the daemon script + resume prompt present, an L0 plan whose RUN STATUS is IN_PROGRESS with
# unchecked [ ] work-queue items. See README.md for the design (L0 plan / L1 daemon / L2 prompt).
set -uo pipefail

# Escape a string for use as the REPLACEMENT half of `sed s|…|…|`. Only `&` and `\` are special there
# (`|` cannot appear in an absolute path we'd render). Without this a clone under a directory containing
# `&` — legal on macOS — renders the placeholder back into itself: `/Users/x/R&D/…` becomes
# `/Users/x/R__REPO__D/…` in the resume prompt and the plist, and `plutil -lint` cannot see it.
sed_repl() { printf '%s' "$1" | sed -e 's/[\\&]/\\&/g'; }

REPO="$(cd "$(dirname "$0")/../.." && pwd)"          # this script's checkout = where the daemon works
# One slug, derived the same way the daemon derives it (W32.label-state) so the two can never disagree about
# which state dir / launchd job they mean. Same literal values as before for LABEL=archivesuite.
LABEL="${AUTONOMOUS_LABEL:-archivesuite}"
STATE="${AUTONOMOUS_STATE:-$HOME/.local/state/${LABEL}-autonomous}"
BIN="$HOME/.local/bin"
CLAUDE="$BIN/claude"
DAEMON_SRC="$REPO/ops/autonomous/archive-suite-autonomous.sh"
DAEMON_DST="$BIN/archive-suite-autonomous.sh"
COMPACT_SRC="$REPO/ops/autonomous/compact-plan.sh"
COMPACT_DST="$BIN/compact-plan.sh"
PROMPT_SRC="$REPO/ops/autonomous/resume-prompt.txt"
PLAN="$REPO/.maintenance/AUTONOMOUS_PLAN.md"
LOG="$STATE/daemon.log"
LOCK="$STATE/engine.lock"                                # must match the daemon's own $LOCK (W32.stop-lock)
JOB="com.${LABEL}.autonomous"                            # launchd label (matches the .plist + the daemon's $JOB)
PLIST_SRC="$REPO/ops/autonomous/com.archivesuite.autonomous.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$JOB.plist"
GUI_DOMAIN="gui/$(id -u)"                                 # per-user launchd domain for the LaunchAgent

runstatus() { grep -m1 '^RUN STATUS:' "$PLAN" 2>/dev/null | cut -c1-90; }
# Why the daemon is idle is decided in ONE place, shared with status-digest.sh — see run-state-lib.sh.
# Guarded: daemon.sh runs from the PRIMARY checkout, which may not have merged this file yet (memory
# `daemon-start-installs-from-primary-checkout`). A missing lib must degrade to the old wording, not a blank line.
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

# W21.seed-fu — a successful partition-list repair records exactly which provider accounts existed then.
# Compare that durable snapshot with today's *attribute-only* Keychain probes before an unattended run: a
# newly added provider would otherwise reintroduce the prompt the marker claims was prevented. The helper's
# one account list is also used by fix-keychain-access.sh; DriveClientSecret is intentionally excluded because
# the CLI never reads it and touching its partition list risks an app prompt for no gain.
KEYCHAIN_PROVIDER_LIB="$REPO/ops/autonomous/keychain-provider-accounts.sh"
warn_unmarked_keychain_provider() {
  local login_keychain="$HOME/Library/Keychains/login.keychain-db" missing
  missing="$(keychain_unmarked_present_provider_accounts "$STATE/keychain-partition-fixed" "$login_keychain")"
  [ -n "$missing" ] || return 0
  missing="$(printf '%s\n' "$missing" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  echo "WARNING: Keychain partition repair predates present provider key(s): $missing"
  echo "  Run ./ops/autonomous/fix-keychain-access.sh before unattended OCR; it needs one login-password entry."
}

# Optional `--dry-run` as the FIRST arg: preview the resolved launch mode + exit BEFORE any install/launch.
# An EXPLICIT flag (NOT an ambient env var) on purpose — an env var could be exported once while iterating and
# then silently turn a real `daemon.sh` into a success-reporting no-op; a flag you have to type can't be inherited.
DRYRUN=""
if [ "${1:-}" = "--dry-run" ]; then DRYRUN=1; shift; fi

case "${1:-start}" in
  status) shift; status "$@"; exit 0 ;;   # extra args (e.g. --details) pass through to the digest
  stop)
    # W32.dry-run-stop: --dry-run must be honoured HERE. The generic guard lives below the dispatch, and this
    # arm exits before reaching it, so `--dry-run stop` used to perform a REAL stop — bootout + three pkills,
    # killing the daemon, the in-flight session and any in-flight build — while the operator was asking what it
    # WOULD do. (`status` needs no such guard: it is read-only by construction.)
    [ -n "$DRYRUN" ] && {
      echo "daemon.sh --dry-run stop: would bootout $GUI_DOMAIN/$JOB, remove $PLIST_DST, kill the loop +"
      echo "  any resume session + any in-flight health gate, and clear $LOCK — NOTHING was stopped."
      exit 0; }
    # bootout FIRST — under `keepalive` (launchd KeepAlive=true) a plain pkill would just be relaunched, so we
    # must remove the launchd job before killing anything. Harmless no-op if the run is the plain nohup mode
    # (no such job). THEN pkill the loop + any resume session it spawned: a bare `claude -p` child is NOT
    # matched by the script-name pgrep (its cmdline is the prompt text), so killing only the loop orphans it
    # (reparented to init, running off stale state — the repeated-orphan bug); match sessions by the resume
    # prompt's distinctive phrase. Neither pattern matches daemon.sh itself or an interactive Claude session.
    booted=0; launchctl bootout "$GUI_DOMAIN/$JOB" 2>/dev/null && { booted=1; echo "launchd job booted out."; }
    # W32.plist-relogin — AND REMOVE THE PLIST. `bootout` only unloads the job from the CURRENT gui/$UID
    # domain; it writes no persistent disable. launchd re-bootstraps ~/Library/LaunchAgents at the NEXT GUI
    # login, so leaving the file behind meant an intentional stop lasted only until the next login and the
    # daemon then started ITSELF — observed 2026-08-05 (hard power-off 15:25 with no `daemon down` line, boot
    # 21:56:53, `daemon up (pid 1701)` 22:00:20, no human involved). Starting this daemon is the owner's call
    # alone, so a stop has to outlive the login session. Nothing is lost: `start` re-renders and re-installs
    # the plist every time (see the keepalive branch below).
    rm -f "$PLIST_DST" 2>/dev/null || true
    k=0
    pkill -f 'archive-suite-autonomous\.sh' && k=1
    pkill -f 'autonomous maintenance session for the Archive Suite' && k=1
    # WS7: a health gate in flight is `bash health-gate.sh` -> xcodebuild — matched by NEITHER pattern above
    # (same bare-child orphan class we fixed for sessions), so kill it too, else `stop` leaves a build running.
    pkill -f 'ops/autonomous/health-gate\.sh' 2>/dev/null && { k=1; echo "in-flight health gate stopped."; }
    # W32.stop-lock — release the engine lock. `stop` is the ONE place that knows the shutdown is intentional,
    # so a lock left behind here is stale by construction. Without this, a stop during an in-flight session
    # (the common case — sessions run 10-45 min) left a lock <60s old and the NEXT `start` no-op'd
    # "engine busy — skip" every cycle until it aged past $STALE (25 min), while daemon.sh still printed
    # "✅ daemon is up and starting its first session". Observed twice: 2026-08-05 (13 consecutive skips,
    # 22 minutes lost) and 2026-08-11. The EXIT trap only ever REPORTED this ("session-in-flight=YES").
    rm -f "$LOCK" 2>/dev/null || true
    if [ "$k" = 1 ]; then echo "daemon + any resume session stopped."
    elif [ "$booted" = 1 ]; then echo "launchd job stopped (its process was already down)."
    else echo "daemon was not running."; fi
    echo "launchd job removed ($PLIST_DST) — it will NOT come back at the next login; '$0 start' reinstalls it."
    exit 0 ;;
  start|keepalive) MODE='keepalive' ;; # DEFAULT (2026-07-17): launchd KeepAlive so a crash/kill auto-restarts (WS1).
                                       # A BARE `./daemon.sh` still means `start` (renamed from `arm` 2026-08-06):
                                       # every doc and status hint says "start it: ./ops/autonomous/daemon.sh".
  nohup)         MODE='nohup' ;;       # opt-in: detached nohup (no crash-restart). (GUI now runs off-screen in
                                       # the Tart VM — ops/gui/README §3 — so nohup no longer buys GUI-verify.)
  *) fail "unknown command '${1}'. Use: start | stop | status | nohup | keepalive" ;;
esac

# --dry-run: report the resolved launch mode and exit BEFORE any install/launch — a loud, unmistakable line so
# a preview is never mistaken for a real start. (tests/prove-daemon-dispatch.sh asserts the dispatch through this.)
[ -n "$DRYRUN" ] && { echo "daemon.sh --dry-run: would launch in mode '$MODE' — NOTHING installed or launched."; exit 0; }

# ---- start ----
# 1. prerequisites (each with a fix hint)
[ -x "$CLAUDE" ] || fail "claude CLI not executable at $CLAUDE — it MUST live outside ~/Desktop for launchd/TCC. Install/symlink it there."
[ -f "$DAEMON_SRC" ] || fail "daemon script missing: $DAEMON_SRC"
[ -f "$PROMPT_SRC" ] || fail "L2 resume prompt missing: $PROMPT_SRC"
[ -f "$PLAN" ]       || fail "L0 plan missing: $PLAN — write it (queue + directives) before starting."
[ -r "$KEYCHAIN_PROVIDER_LIB" ] || fail "keychain provider list missing: $KEYCHAIN_PROVIDER_LIB"
. "$KEYCHAIN_PROVIDER_LIB"
mkdir -p "$BIN" "$STATE"
warn_unmarked_keychain_provider

# 2. install the latest committed copies to the runtime location (source of truth = the repo)
install -m 755 "$DAEMON_SRC" "$DAEMON_DST"
install -m 755 "$COMPACT_SRC" "$COMPACT_DST"   # plan compactor: Session Log + Daemon Report (daemon calls it between cycles)
# The committed prompt carries a __REPO__ placeholder rather than one machine's absolute path; the
# daemon renders the real checkout in here, since the session that reads it needs a literal path.
sed "s|__REPO__|$(sed_repl "$REPO")|g" "$PROMPT_SRC" >"$STATE/resume-prompt.txt"
echo "installed: daemon -> $DAEMON_DST ; compactor -> $COMPACT_DST ; resume prompt -> $STATE/"

# 2b. ensure a stable local code-signing identity exists so Debug builds re-sign stably and the macOS
#     Keychain stops re-prompting for the API key every rebuild (see ArchiveProcessor/launch.sh).
#     Idempotent + non-fatal — a missing cert just means builds fall back to ad-hoc (the old behavior).
bash "$REPO/ops/autonomous/ensure-signing.sh" || echo "daemon.sh: ensure-signing failed (non-fatal; ad-hoc fallback)"

# 3. don't double-launch. Check the process AND the launchd job UNCONDITIONALLY (not only in keepalive mode):
#    a keepalive job can be registered but momentarily process-down (crash/throttle window), and starting plain
#    `daemon.sh` then would miss it via pgrep and start a SECOND nohup sibling that park's self-bootout can't
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
# W32.complete-substring — ANCHORED. This used to be an unanchored `grep -q 'COMPLETE'` over the first 90
# chars, so an IN_PROGRESS plan whose one-line note merely mentioned the word (e.g. "RUN STATUS: IN_PROGRESS
# — finish the COMPLETE-path cleanup") refused to start, telling the owner to fix a status line that was
# already correct. Only a line that genuinely READS complete should trip this.
if printf '%s' "$st" | grep -qE '^RUN STATUS:[[:space:]]*COMPLETE'; then
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
  # on any bootout-less death (crash/OOM/stray signal). `daemon.sh stop`, park, and plan-COMPLETE all bootout,
  # so intentional stops still stick. NOTE: a LaunchAgent loads in your GUI login session — it survives a
  # daemon CRASH — and ALSO a logout/reboot, which was long documented here as out of scope and is not:
  # launchd re-bootstraps ~/Library/LaunchAgents at the next GUI login and RunAtLoad starts the job. That is
  # why `stop`/park/COMPLETE now REMOVE the plist (W32.plist-relogin) — otherwise an intentional stop lasted
  # only until the next login and the daemon restarted itself, unasked. (GUI verification now
  # runs off-screen in the Tart VM regardless of supervisor — ops/gui/README §3 — so no host TCC grant matters.)
  # launchd expands neither `~` nor `$HOME` in a path, so the committed template carries a __HOME__
  # placeholder and the real home is rendered in here. Lint the RENDERED file — that is what launchd loads.
  mkdir -p "$HOME/Library/LaunchAgents"
  rendered="$(mktemp)"
  sed -e "s|__HOME__|$(sed_repl "$HOME")|g" -e "s|__REPO__|$(sed_repl "$REPO")|g" "$PLIST_SRC" >"$rendered" \
    || { rm -f "$rendered"; fail "could not render plist: $PLIST_SRC"; }
  plutil -lint "$rendered" >/dev/null || { rm -f "$rendered"; fail "plist is malformed after rendering: $PLIST_SRC"; }
  install -m 644 "$rendered" "$PLIST_DST"
  rm -f "$rendered"
  launchctl bootout "$GUI_DOMAIN/$JOB" 2>/dev/null || true   # clear any stale registration first
  if launchctl bootstrap "$GUI_DOMAIN" "$PLIST_DST"; then
    echo "launched (launchd KeepAlive [default]; plist -> $PLIST_DST) — a crash/kill auto-restarts."
  else
    fail "launchctl bootstrap failed — check: launchctl print $GUI_DOMAIN/$JOB"
  fi
else
  # macOS has no setsid; subshell + nohup survives this shell returning (reparented to init).
  # AUTONOMOUS_REPO must be passed the same way the launchd lane passes it (plist EnvironmentVariables):
  # the installed daemon sits outside any checkout and refuses to start without it.
  ( AUTONOMOUS_REPO="$REPO" nohup "$DAEMON_DST" >"$STATE/nohup.out" 2>&1 & )
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
