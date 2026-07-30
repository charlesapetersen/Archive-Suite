#!/usr/bin/env bash
# prove-no-host-gui.sh — lock the HOST-GUI FIREWALL (.claude/hooks/no-host-gui.sh).
#
# The owner's rule (2026-07-30): an unattended session drives a GUI ONLY inside the headless Tart VM;
# nothing it runs may take over the physical display. That hook is the mechanical boundary behind the
# rule, so its allow/deny surface needs the same regression protection as the daemon itself — a pattern
# that silently stops matching would hand the screen back to the daemon with no visible symptom until
# the owner is interrupted again.
#
# Feeds the hook real PreToolUse payloads and asserts exit 2 (DENY) / exit 0 (ALLOW). Three axes:
#   1. the four blocked lanes are actually blocked when ARCHIVE_UNATTENDED=1
#   2. the legitimate neighbours of each (the VM lane, unit-only tests, headless emulator, read-only
#      simctl) are NOT collateral damage — an over-broad firewall would just get worked around
#   3. an INTERACTIVE session (no ARCHIVE_UNATTENDED) keeps full host GUI access — a human at the
#      keyboard driving the app is the sanctioned use of cliclick/launch.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../../../.claude/hooks/no-host-gui.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

# t <label> <allow|deny> <command> [unattended=1]
t() {
  local label="$1" want="$2" cmd="$3" un="${4:-1}" payload got rc
  payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$cmd")
  printf '%s' "$payload" | ARCHIVE_UNATTENDED="$un" bash "$HOOK" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && got=deny || got=allow
  [ "$got" = "$want" ] && ok "$label -> $got" || no "$label -> $got (want $want)"
}

echo "== 1. blocked lanes (unattended) =="
t "host UITest named"        deny "xcodebuild test -scheme ArchiveReader -only-testing:ArchiveReaderUITests -destination 'platform=macOS'"
t "whole-scheme test"        deny "cd ArchiveNotes/macOS && xcodebuild test -scheme ArchiveNotes -derivedDataPath ./build/DD"
t "launch.sh"                deny "./launch.sh reader"
t "gui-drive.sh"             deny "source scripts/gui-drive.sh && gd_click 100 200"
t "gui-drive-notes.sh"       deny "bash ArchiveNotes/scripts/gui-drive-notes.sh"
t "cliclick"                 deny "/opt/homebrew/bin/cliclick c:640,400"
t "osascript"                deny "osascript -e 'quit app \"ArchiveReader\"'"
t "capture-window.sh"        deny "shot=\$(ops/gui/capture-window.sh ArchiveReader)"
t "open -a <app>"            deny "open -a ArchiveNotes"
t "emulator -avd windowed"   deny "emulator -avd Pixel_7 -netdelay none"
t "emulator @name windowed"  deny "emulator @Pixel_7"
t "iOS Simulator"            deny "open -a Simulator"
t "simctl boot"              deny "xcrun simctl boot 'iPhone 15'"
t "test-smoke.sh wrapper"    deny "./ArchiveNotes/test-smoke.sh"
t "test-smoke via root"      deny "bash test-smoke.sh notes"

echo "== 2. legitimate neighbours must survive (unattended) =="
t "unit bundle only"         allow "xcodebuild test -scheme ArchiveNotes -only-testing:ArchiveNotesTests -derivedDataPath ./build/DD"
t "build (no test)"          allow "xcodebuild -scheme ArchiveProcessor -configuration Debug build"
t "UITest INSIDE the VM"     allow "tart exec archive-gui-runner bash -lc \"xcodebuild test -project X -scheme ArchiveReader -only-testing:ArchiveReaderUITests\""
t "vm-gui-runner"            allow "ops/gui/vm-gui-runner.sh xcuitest"
t "emulator -no-window"      allow "emulator -avd Pixel_7 -no-window -no-audio"
t "simctl list (read-only)"  allow "xcrun simctl list devices"
t "plain open <file>"        allow "git log --oneline -5 && open README.md"
t "xcodegen"                 allow "xcodegen generate"

echo "== 2b. the wrapper-script hole (2026-07-30): a script name hides the xcodebuild inside it =="
# ./ArchiveNotes/test-smoke.sh contains no "xcodebuild" and no "-only-testing", yet its whole-scheme
# `xcodebuild test` ran ArchiveNotesUITests on the owner's screen. The hook is only ONE of three layers
# (script self-guard + PATH shim are the others) but it must still catch the literal command.
t "smoke wrapper is named"   deny "cd /tmp && bash \"/Users/x/ArchiveReader/test-smoke.sh\""

echo "== 3. interactive sessions keep host GUI (ARCHIVE_UNATTENDED unset) =="
t "launch.sh"                allow "./launch.sh reader" 0
t "host UITest"              allow "xcodebuild test -only-testing:ArchiveReaderUITests" 0
t "cliclick"                 allow "cliclick c:10,10" 0
t "test-smoke.sh"            allow "./ArchiveNotes/test-smoke.sh" 0

echo
echo "prove-no-host-gui: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
