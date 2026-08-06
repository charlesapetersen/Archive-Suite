#!/usr/bin/env bash
# PreToolUse(Bash) hook — HOST-GUI FIREWALL for unattended runs.
#
# The rule the owner set on 2026-07-30: an unattended session may drive a GUI **only inside the headless
# Tart VM** (ops/gui/vm-gui-runner.sh). Nothing it runs may take over the physical display. The resume
# prompt already says so, but a prompt is guidance, not a boundary — this hook is the boundary.
#
# WHY it exists (the incident): the daemon ran `xcodebuild test -only-testing:ArchiveNotesTests` on the
# host. Those unit bundles are APP-HOSTED (TEST_HOST = the .app), so the run launched the real app and
# parked a window on the owner's screen mid-morning. That specific hole is now closed at the source
# (ArchiveCore `ArchiveTestHost` — the app draws nothing when it is only a unit-test host), but the
# class of problem is broader than one command, and a prompt-level rule cannot enforce it. So: deny the
# whole family, mechanically, and point every denial at the VM lane that does the same job off-screen.
#
# SCOPE — unattended only. Gated on ARCHIVE_UNATTENDED=1, which the daemon exports into every session it
# spawns ($STATE/env). The owner's own interactive sessions are untouched: driving the app on the host
# with cliclick/osascript is a legitimate, useful thing to do when a human is sitting there watching.
#
# CONTRACT: exit 0 = allow (silent). exit 2 = DENY, with the reason on stderr fed back to the model.
# Fail-OPEN on any internal error — a broken hook must never wedge a run.
set -uo pipefail

[ "${ARCHIVE_UNATTENDED:-0}" = "1" ] || exit 0        # interactive session -> not our business

payload="$(cat 2>/dev/null)" || exit 0
[ -n "$payload" ] || exit 0

# Pull .tool_input.command out of the PreToolUse payload. jq if present, else a python fallback (the
# daemon's PATH is minimal, so don't assume jq).
cmd=""
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
fi
if [ -z "$cmd" ] && command -v python3 >/dev/null 2>&1; then
  cmd="$(printf '%s' "$payload" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)"
fi
[ -n "$cmd" ] || exit 0                               # not a Bash call / unparseable -> allow

deny() {   # $1 = what was blocked, $2 = the off-screen route to take instead
  cat >&2 <<EOF
BLOCKED by .claude/hooks/no-host-gui.sh — $1

This is an UNATTENDED session (ARCHIVE_UNATTENDED=1). It may not put a GUI on the owner's
physical display; that is the owner's screen and they are using it.

Do this instead: $2

If the check genuinely cannot run off-screen, DO NOT work around this hook. Leave the item for
the owner: note it in the plan's Daemon Report with what you'd need, and pick another item.
EOF
  exit 2
}

# ---- 1. Host GUI drivers: the retired cliclick/osascript path + launching an app on the host ----
# `launch.sh` builds AND launches; `gui-drive*.sh` / `capture-window.sh` are the host sighted loop.
# `osascript` is matched broadly on purpose — the daemon has no legitimate AppleScript need, and the
# interesting verbs (`activate`, `tell application`) are exactly the screen-stealing ones.
case "$cmd" in
  *launch.sh*|*gui-drive.sh*|*gui-drive-notes.sh*|*capture-window.sh*|*cliclick*|*osascript*)
    deny "a host GUI driver (launch.sh / gui-drive*.sh / capture-window.sh / cliclick / osascript)" \
         "run the app's UITests off-screen with 'ops/gui/vm-gui-runner.sh xcuitest', or the sighted
pixel loop with 'ops/gui/vm-gui-runner.sh sighted' (VNC framebuffer, never your display)." ;;
esac
# `open -a Foo` / `open Foo.app` launches an app on the host. Plain `open <file>` is fine.
case "$cmd" in
  *"open -a "*|*.app*"open "*|*"open "*.app*)
    case "$cmd" in *open*.app*|*"open -a "*) deny "launching a macOS app on the host display via 'open'" \
      "launch it inside the VM — 'tart exec archive-gui-runner …' (ops/gui/README.md §3)." ;; esac ;;
esac

# ---- 1b. Wrapper scripts that run a whole-scheme `xcodebuild test` ----
# The hook only sees the command STRING, so a script is a blind spot: `./ArchiveNotes/test-smoke.sh`
# contains no `xcodebuild` and no `-only-testing`, yet on 2026-07-30 it ran ArchiveNotesUITests on the
# owner's screen. Those scripts now restrict themselves to the unit bundle under ARCHIVE_UNATTENDED=1 and
# the PATH shim (ops/autonomous/bin/xcodebuild) catches the exec regardless — this pattern is the fast,
# legible third layer, so the model is told at the tool boundary rather than deep in a build log.
case "$cmd" in
  *test-smoke.sh*)
    deny "a whole-scheme smoke script (its 'xcodebuild test' includes the UITest bundle → host XCUITest)" \
         "run the unit bundle directly — 'xcodebuild test -only-testing:<App>Tests …' (windowless) — and
'ops/gui/vm-gui-runner.sh <reader|notes> xcuitest' for the UITests, off-screen in the VM." ;;
esac

# ---- 2. Host UITest runs ----
# A UITest bundle drives real clicks/keys for minutes and pops the "Enable UI Automation" prompt. It is
# the single worst screen-takeover, and it is ALWAYS available off-screen in the VM. Denied on the host
# whether named explicitly or reached by running a whole scheme (which includes the UITest bundle).
if printf '%s' "$cmd" | grep -qE 'xcodebuild[^|;]*[[:space:]]test(-without-building)?([[:space:]]|$)'; then
  # A run inside the VM is fine — that is the sanctioned lane.
  if ! printf '%s' "$cmd" | grep -qE 'tart[[:space:]]+exec|vm-gui-runner'; then
    if printf '%s' "$cmd" | grep -qE 'only-testing:[A-Za-z]*UITests'; then
      deny "an XCUITest bundle on the host WindowServer" \
           "'ops/gui/vm-gui-runner.sh xcuitest' runs the same tests in the headless VM."
    fi
    # No -only-testing at all => the whole scheme => the UITest bundle comes along for the ride.
    if ! printf '%s' "$cmd" | grep -q 'only-testing:'; then
      deny "a whole-scheme 'xcodebuild test' on the host (the scheme includes the UITest bundle)" \
           "add '-only-testing:<App>Tests' to run just the unit bundle (windowless since 2026-07-30),
and use 'ops/gui/vm-gui-runner.sh xcuitest' for the UITests."
    fi
  fi
fi

# ---- 3. Android emulator with a window ----
# The Live-Capture E2E needs a real emulator, but it does NOT need to be visible. `-no-window` gives an
# identical, fully driveable device over adb with nothing on screen.
if printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_-])emulator([[:space:]]|$)'; then
  if printf '%s' "$cmd" | grep -qE '@|-avd[[:space:]]' && ! printf '%s' "$cmd" | grep -q '\-no-window'; then
    deny "booting the Android emulator with a visible window" \
         "add '-no-window' — adb injection and screenshots work exactly the same headless
(scripts/e2e-phone-mac.sh is the deterministic Live-Capture route)."
  fi
fi

# ---- 4. iOS Simulator ----
# iOS is maintain-only and on hold (owner, 2026-07-09), so an unattended run has no reason to open it —
# and Simulator.app is a full-screen window. `simctl list` and other read-only queries stay allowed.
case "$cmd" in
  *"open -a Simulator"*|*"Simulator.app"*)
    deny "opening the iOS Simulator on the host display" \
         "iOS is on hold (maintain-only). Skip the item and note it for the owner." ;;
esac
if printf '%s' "$cmd" | grep -qE 'simctl[[:space:]]+(boot|launch)([[:space:]]|$)'; then
  deny "booting/launching in the iOS Simulator" \
       "iOS is on hold (maintain-only). Skip the item and note it for the owner."
fi

exit 0
