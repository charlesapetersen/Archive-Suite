#!/usr/bin/env bash
# ops/autonomous/arm.sh — ONE-COMMAND prep + launch + verify for the autonomous run.
#
# Collapses the whole "arm the daemon" dance (install runtime copies, check every
# prerequisite, guard the stale-COMPLETE + double-launch footguns, launch detached,
# verify the first cycle started) into a single command so it never has to be
# re-derived from README.md again.
#
# Run from the PRIMARY checkout:
#   ./ops/autonomous/arm.sh            # install + verify prereqs + launch DETACHED (nohup; no crash-restart)
#   ./ops/autonomous/arm.sh keepalive  # same, but under launchd KeepAlive — a CRASH/kill auto-restarts (WS1).
#                                      #   Best for a long unattended run. Survives a daemon crash, NOT a
#                                      #   logout/reboot. GUI-verify (gui on) is better under plain `arm`.
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
# taskport = the debugger right XCUITest needs; 'allow' = password-free. Set on `gui on`, reverted on `gui off`.
tp_is_allow() { security authorizationdb read system.privilege.taskport 2>/dev/null | grep -q '<string>allow</string>'; }
# UI-automation mode (macOS Sequoia+): the "XCTest is trying to Enable UI Automation" prompt. `automationmodetool
# enable-automationmode-without-authentication` pre-authorizes it (Apple's CI workaround) — separate from taskport.
am_state() { automationmodetool 2>/dev/null | grep -qi 'requires.*authentication' && echo auth-required || echo no-auth; }

status() {
  echo "== daemon process =="
  pgrep -fl archive-suite-autonomous.sh || echo "  (not running)"
  # WS1: is it launchd-managed (crash-restart) or plain nohup (no restart)?
  if launchctl print "$GUI_DOMAIN/$JOB" >/dev/null 2>&1; then
    echo "  supervisor: launchd KeepAlive (crash-restart ON) — stop with '$0 stop'"
    # Job loaded but no process = relaunching, or crash-looping (throttled 60s). Surface it — otherwise a
    # crash-loop reads identical to healthy here.
    if ! pgrep -f archive-suite-autonomous.sh >/dev/null 2>&1; then
      lec=$(launchctl print "$GUI_DOMAIN/$JOB" 2>/dev/null | awk -F'= ' '/last exit code/{gsub(/[^0-9-]/,"",$2); print $2; exit}')
      echo "  ⚠ job loaded but NO process right now — relaunching, or crash-looping (last exit ${lec:-?}; see $STATE/launchd.err.log)"
    fi
  else
    echo "  supervisor: nohup / none (a crash will NOT restart; '$0 keepalive' for crash-restart)"
  fi
  echo "== run state =="
  # Distinguish PARKED (daemon auto-stopped after a long idle stretch — blocked on you, nothing lost) from a
  # crash, and show whether a live daemon is backing off. All derived from files the daemon writes; read-only.
  local since idle
  since=$(cat "$STATE/idle.since" 2>/dev/null)
  if pgrep -f archive-suite-autonomous.sh >/dev/null 2>&1; then
    case "$since" in
      ''|*[!0-9]*) echo "  running, productive (last cycle advanced the run)" ;;
      *) idle=$(( $(date +%s) - since ))
         echo "  running, BACKING OFF (idle ${idle}s — sessions finding no actionable work; retrying, widening the gap)" ;;
    esac
  elif tail -n 8 "$LOG" 2>/dev/null | grep -q 'PARKED'; then
    echo "  PARKED — auto-stopped after a long no-progress stretch; every queue item looks blocked on you."
    echo "  Nothing lost, plan intact. Unblock (e.g. '$0 gui on') then re-arm: '$0'."
    [ -f "$HOME/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt" ] && echo "  see: ~/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt"
  else
    echo "  stopped (normal stop, or the launching session closed — not parked). Re-arm with '$0'."
  fi
  echo "== plan RUN STATUS =="
  runstatus || echo "  (no plan at $PLAN)"
  echo "== GUI mode =="
  echo "  $(cat "$STATE/gui-mode" 2>/dev/null || echo 'off (default)')  |  taskport: $(tp_is_allow && echo allow || echo secure)  |  UI-automation: $(am_state)   (toggle: $0 gui on|off)"
  echo "== keychain =="
  # The daemon's test-smoke gate reads the OCR key via /usr/bin/security, which re-prompts until the item's
  # partition list includes Apple's tool partitions. fix-keychain-access.sh sets that + drops this marker
  # (which records the accounts it fixed). Reading item ATTRIBUTES (no -w) never prompts, so we can also flag
  # a provider key that's present but NOT in the marker — e.g. one added after the fix was last run.
  local kmark="$STATE/keychain-partition-fixed" ksvc="com.archiveprocessor.app" klc="$HOME/Library/Keychains/login.keychain-db"
  if [ -f "$kmark" ]; then
    local fixed; fixed="$(cat "$kmark" 2>/dev/null)"
    echo "  partition-list fix applied ($fixed)"
    local newkeys=""
    for a in Gemini Anthropic Mistral OpenAI Gateway; do
      if security find-generic-password -s "$ksvc" -a "$a" "$klc" >/dev/null 2>&1 && ! printf '%s' "$fixed" | grep -qw "$a"; then
        newkeys="$newkeys $a"
      fi
    done
    [ -n "$newkeys" ] && echo "  ⚠ new key(s) not yet fixed:$newkeys — re-run ./ops/autonomous/fix-keychain-access.sh"
  else
    echo "  ⚠ partition-list fix NOT applied — the daemon may wake you with 'security wants to use your keychain'."
    echo "    Run once:  ./ops/autonomous/fix-keychain-access.sh   (then re-run after rotating/adding any API key)"
  fi
  echo "== recent daemon.log =="
  tail -n 6 "$LOG" 2>/dev/null || echo "  (no log yet)"
}

fail() { echo "ERROR: $*" >&2; exit 1; }

case "${1:-arm}" in
  status) status; exit 0 ;;
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
    if [ "$k" = 1 ]; then echo "daemon + any resume session stopped."
    elif [ "$booted" = 1 ]; then echo "launchd job stopped (its process was already down)."
    else echo "daemon was not running."; fi
    exit 0 ;;
  gui)
    # GUI-mode flag: each resume session reads $STATE/gui-mode to decide whether to drive/verify GUI (see the
    # resume prompt). ON also makes XCUITest password-free by setting `taskport` allow via sudo (you're prompted
    # ONCE now, instead of a random prompt mid-run); OFF reverts taskport to secure. ON still needs TCC
    # Accessibility + Screen Recording + an unlocked/no-sleep screen. Absent flag = off (safe default).
    TP_BACKUP="$STATE/taskport-rule.backup.plist"
    case "${2:-status}" in
      on)
        echo on > "$STATE/gui-mode"
        echo "GUI mode -> ON — sessions will drive+verify GUI for visible-effect items."
        echo "  Requires: TCC Accessibility + Screen Recording + an unlocked/no-sleep screen."
        # Ensure a SECURE revert target exists — never overwrite a good backup, never capture 'allow' as the
        # revert (that would make `gui off` restore the insecure state).
        if [ ! -f "$TP_BACKUP" ]; then
          if tp_is_allow; then
            echo "  ⚠️ taskport is already 'allow' with no backup — cannot capture a secure revert target."
            echo "     When it's secure, run: security authorizationdb read system.privilege.taskport > \"$TP_BACKUP\""
          else
            security authorizationdb read system.privilege.taskport > "$TP_BACKUP" 2>/dev/null \
              && echo "  backed up the current (secure) taskport rule -> $TP_BACKUP"
          fi
        fi
        if tp_is_allow; then
          echo "  taskport: already 'allow' (XCUITest ready)."
        else
          echo "  Setting taskport password-free for XCUITest (sudo — you'll be prompted once)…"
          if sudo security authorizationdb write system.privilege.taskport allow; then
            echo "  taskport -> allow ✅ (reverted automatically on \`$0 gui off\`)."
          else
            echo "  ⚠️ taskport sudo failed/cancelled — GUI is ON (cliclick works), but XCUITest may prompt for a password."
          fi
        fi
        # UI-automation mode (Sequoia+ "Enable UI Automation" prompt — a SEPARATE gate from taskport).
        if [ "$(am_state)" = no-auth ]; then
          echo "  UI-automation mode: already enabled without auth."
        else
          echo "  Enabling UI-automation mode for XCUITest (sudo)…"
          sudo automationmodetool enable-automationmode-without-authentication >/dev/null 2>&1 \
            && echo "  UI-automation mode -> enabled ✅ (no 'Enable UI Automation' prompt)." \
            || echo "  ⚠️ automationmodetool failed/cancelled — XCUITest may still prompt 'Enable UI Automation'."
        fi
        ;;
      off)
        echo off > "$STATE/gui-mode"
        echo "GUI mode -> OFF — sessions do build+unit only, defer GUI to Morning Review, skip GUI-only items."
        if ! tp_is_allow; then
          echo "  taskport: already secure."
        elif [ -f "$TP_BACKUP" ]; then
          echo "  Reverting taskport to secure (sudo — you'll be prompted once)…"
          if sudo security authorizationdb write system.privilege.taskport < "$TP_BACKUP"; then
            echo "  taskport -> secure ✅."
          else
            echo "  ⚠️ taskport revert failed/cancelled — it is STILL 'allow'. Revert manually:"
            echo "     sudo security authorizationdb write system.privilege.taskport < \"$TP_BACKUP\""
          fi
        else
          echo "  ⚠️ taskport is 'allow' but no backup at $TP_BACKUP — cannot auto-revert; do it manually."
        fi
        # Revert UI-automation mode (re-require auth).
        if [ "$(am_state)" = auth-required ]; then
          echo "  UI-automation mode: already requires auth."
        else
          echo "  Reverting UI-automation mode (sudo)…"
          sudo automationmodetool disable-automationmode-without-authentication >/dev/null 2>&1 \
            && echo "  UI-automation mode -> requires auth ✅." \
            || echo "  ⚠️ revert failed — disable manually: sudo automationmodetool disable-automationmode-without-authentication"
        fi
        ;;
      status|"") echo "GUI mode: $(cat "$STATE/gui-mode" 2>/dev/null || echo 'off (default)')  |  taskport: $(tp_is_allow && echo allow || echo secure)  |  UI-automation: $(am_state)" ;;
      *) fail "usage: $0 gui on|off|status" ;;
    esac
    exit 0 ;;
  arm)       MODE=nohup ;;
  keepalive) MODE=keepalive ;;   # WS1: run under launchd with KeepAlive so a crash/kill auto-restarts
  *) fail "unknown command '${1}'. Use: arm | keepalive | status | stop | gui on|off|status" ;;
esac

# ---- arm ----
# 1. prerequisites (each with a fix hint)
[ -x "$CLAUDE" ] || fail "claude CLI not executable at $CLAUDE — it MUST live outside ~/Desktop for launchd/TCC. Install/symlink it there."
[ -f "$DAEMON_SRC" ] || fail "daemon script missing: $DAEMON_SRC"
[ -f "$PROMPT_SRC" ] || fail "L2 resume prompt missing: $PROMPT_SRC"
[ -f "$PLAN" ]       || fail "L0 plan missing: $PLAN — write it (queue + directives) before arming."
mkdir -p "$BIN" "$STATE"

# 2. install the latest committed copies to the runtime location (source of truth = the repo)
install -m 755 "$DAEMON_SRC" "$DAEMON_DST"
install -m 755 "$COMPACT_SRC" "$COMPACT_DST"   # plan Session-Log compactor (daemon calls it between cycles)
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
  echo "  To switch modes or restart: '$0 stop' first, then '$0 [keepalive]'."
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

# 5. launch — nohup (default) or launchd KeepAlive (crash-restart; WS1)
if [ "$MODE" = keepalive ]; then
  # Install the LaunchAgent + (re)bootstrap it. RunAtLoad launches the daemon; KeepAlive=true relaunches it
  # on any bootout-less death (crash/OOM/stray signal). `arm.sh stop`, park, and plan-COMPLETE all bootout,
  # so intentional stops still stick. NOTE: a LaunchAgent loads in your GUI login session — it survives a
  # daemon CRASH, not a logout/reboot (reboot-survival is deliberately out of scope). GUI-verify (gui on) is
  # best under plain `arm` (nohup) where the daemon inherits the terminal's TCC grants; a LaunchAgent may not.
  plutil -lint "$PLIST_SRC" >/dev/null || fail "plist is malformed: $PLIST_SRC"
  mkdir -p "$HOME/Library/LaunchAgents"
  install -m 644 "$PLIST_SRC" "$PLIST_DST"
  launchctl bootout "$GUI_DOMAIN/$JOB" 2>/dev/null || true   # clear any stale registration first
  if launchctl bootstrap "$GUI_DOMAIN" "$PLIST_DST"; then
    echo "launched (launchd KeepAlive; plist -> $PLIST_DST)."
  else
    fail "launchctl bootstrap failed — check: launchctl print $GUI_DOMAIN/$JOB"
  fi
else
  # macOS has no setsid; subshell + nohup survives this shell returning (reparented to init).
  ( nohup "$DAEMON_DST" >"$STATE/nohup.out" 2>&1 & )
  echo "launched (detached nohup — no crash-restart; use '$0 keepalive' for a long unattended run)."
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