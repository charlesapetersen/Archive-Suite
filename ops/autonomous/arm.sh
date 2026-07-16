#!/usr/bin/env bash
# ops/autonomous/arm.sh — ONE-COMMAND prep + launch + verify for the autonomous run.
#
# Collapses the whole "arm the daemon" dance (install runtime copies, check every
# prerequisite, guard the stale-COMPLETE + double-launch footguns, launch detached,
# verify the first cycle started) into a single command so it never has to be
# re-derived from README.md again.
#
# Run from the PRIMARY checkout:
#   ./ops/autonomous/arm.sh            # install + verify prereqs + launch + confirm first cycle
#   ./ops/autonomous/arm.sh status     # show daemon state + RUN STATUS + recent log (read-only)
#   ./ops/autonomous/arm.sh stop       # stop the detached daemon
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

runstatus() { grep -m1 '^RUN STATUS:' "$PLAN" 2>/dev/null | cut -c1-90; }
# taskport = the debugger right XCUITest needs; 'allow' = password-free. Set on `gui on`, reverted on `gui off`.
tp_is_allow() { security authorizationdb read system.privilege.taskport 2>/dev/null | grep -q '<string>allow</string>'; }
# UI-automation mode (macOS Sequoia+): the "XCTest is trying to Enable UI Automation" prompt. `automationmodetool
# enable-automationmode-without-authentication` pre-authorizes it (Apple's CI workaround) — separate from taskport.
am_state() { automationmodetool 2>/dev/null | grep -qi 'requires.*authentication' && echo auth-required || echo no-auth; }

status() {
  echo "== daemon process =="
  pgrep -fl archive-suite-autonomous.sh || echo "  (not running)"
  echo "== plan RUN STATUS =="
  runstatus || echo "  (no plan at $PLAN)"
  echo "== GUI mode =="
  echo "  $(cat "$STATE/gui-mode" 2>/dev/null || echo 'off (default)')  |  taskport: $(tp_is_allow && echo allow || echo secure)  |  UI-automation: $(am_state)   (toggle: $0 gui on|off)"
  echo "== recent daemon.log =="
  tail -n 6 "$LOG" 2>/dev/null || echo "  (no log yet)"
}

fail() { echo "ERROR: $*" >&2; exit 1; }

case "${1:-arm}" in
  status) status; exit 0 ;;
  stop)
    # Kill the daemon loop AND any resume session it spawned. A bare `claude -p` child is NOT matched by the
    # script-name pgrep (its cmdline is the prompt text), so killing only the loop orphans it — reparented to
    # init, still running off possibly-stale state (the repeated-orphan bug). Match sessions by the resume
    # prompt's distinctive phrase. Neither pattern matches arm.sh itself or an interactive Claude session.
    k=0
    pkill -f 'archive-suite-autonomous\.sh' && k=1
    pkill -f 'autonomous maintenance session for the Archive Suite' && k=1
    [ "$k" = 1 ] && echo "daemon + any resume session stopped." || echo "daemon was not running."
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
  arm) : ;;
  *) fail "unknown command '${1}'. Use: arm | status | stop | gui on|off|status" ;;
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

# 3. don't double-launch
if pgrep -f archive-suite-autonomous.sh >/dev/null; then
  echo "daemon ALREADY running — not launching a second one:"
  pgrep -fl archive-suite-autonomous.sh
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

# 5. launch detached (macOS has no setsid; subshell + nohup survives this shell returning)
( nohup "$DAEMON_DST" >"$STATE/nohup.out" 2>&1 & )
echo "launched (detached)."

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