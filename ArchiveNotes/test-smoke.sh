#!/bin/bash
# test-smoke.sh — Archive Notes Tier-1 smoke test (cheap, repeatable regression gate).
#
# Build + run the unit-test suite. No network, no corpus access.
# Prints PASS/FAIL + the executed test count.
#
# File safety: see GUI_SAFETY.md — no test/GUI drive ever writes the real store
# or corpus; NotesTagProjector's DEBUG scratch-write guard enforces it. The
# durable-link E2E lives in DurableLinkE2ETests + scripts/e2e-durable-links.sh.
#
#   xcodegen generate
#   xcodebuild test -scheme ArchiveNotes -destination 'platform=macOS' -derivedDataPath ./build/DD
#
# A run log is kept under `.maintenance/test-results/` (gitignored).
# Usage: bash ArchiveNotes/test-smoke.sh
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"

ROOT="$(cd "$(dirname "$0")" && pwd)"          # .../ArchiveNotes (outer app dir)
PROJ="$ROOT/macOS"                              # inner XcodeGen project dir
LOGDIR="$ROOT/.maintenance/test-results"; mkdir -p "$LOGDIR"
TS=$(date +%Y%m%d-%H%M%S)
LOG="$LOGDIR/smoke-notes-$TS.log"

# UNATTENDED SAFETY (2026-07-30). This script's `xcodebuild test` runs the scheme's WHOLE test action, and
# the scheme includes ArchiveNotesUITests — so on the host it launches the XCUITest runner, drives the real
# app for minutes and raises the macOS "Automation Running" banner on the owner's screen. That is exactly
# what happened when a daemon session ran this script: the repo's own loop ("run the touched app's smoke
# test") led it straight into a host GUI takeover, and the PreToolUse hook could not see it because the
# command string it inspected was just "./test-smoke.sh".
#
# So the boundary lives HERE, at the source, not only in a string matcher: unattended runs get the unit
# bundle only. The UITests are not skipped, they MOVE — ops/gui/vm-gui-runner.sh notes xcuitest runs the
# same suite off-screen in the headless Tart VM, and the periodic health gate runs it there too.
ONLY=""
if [ "${ARCHIVE_UNATTENDED:-0}" = "1" ]; then
  ONLY="-only-testing:ArchiveNotesTests"
  echo "  (unattended: unit bundle only — ArchiveNotesUITests runs off-screen via ops/gui/vm-gui-runner.sh notes xcuitest)"
fi

echo "=== Archive Notes smoke test (build + unit tests) · $TS ==="
( cd "$PROJ" && xcodegen generate >/dev/null 2>&1 \
   && xcodebuild test -scheme ArchiveNotes -destination 'platform=macOS' -derivedDataPath ./build/DD $ONLY ) \
   >"$LOG" 2>&1
rc=$?

# Aggregate executed-tests count across the suites (last "Executed N tests" line is the total).
count=$(grep -Eo 'Executed [0-9]+ test[s]?' "$LOG" | tail -1)

if [ "$rc" -eq 0 ] && grep -q "TEST SUCCEEDED" "$LOG"; then
  echo "SMOKE (notes): PASS — ${count:-tests executed}"
  echo "  run log: $LOG"
  exit 0
else
  echo "SMOKE (notes): FAIL — ${count:-no test count parsed}"
  echo "  failure log: $LOG"
  grep -E 'error:|failed|TEST FAILED|BUILD FAILED' "$LOG" | tail -20
  exit 1
fi
