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
#   xcodebuild test -scheme ArchiveNotesUnit -destination 'platform=macOS' \
#     -only-testing:ArchiveNotesTests -derivedDataPath ./build/DD
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

# GUI SAFETY (W9.c4, 2026-08-20). The whole scheme includes ArchiveNotesUITests, which drives an app and
# must stay an explicit off-screen VM action. This inexpensive smoke gate is ALWAYS the app-hosted unit
# bundle — not only when a daemon happens to set ARCHIVE_UNATTENDED. The unit-test host suppresses its own
# window; the GUI suite remains opt-in at `ops/gui/vm-gui-runner.sh notes xcuitest`.
UNIT_TEST_SELECTOR=(-only-testing:ArchiveNotesTests)

echo "=== Archive Notes smoke test (build + unit tests) · $TS ==="
( cd "$PROJ" && xcodegen generate >/dev/null 2>&1 \
   && xcodebuild test -scheme ArchiveNotesUnit -destination 'platform=macOS' "${UNIT_TEST_SELECTOR[@]}" -derivedDataPath ./build/DD ) \
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
