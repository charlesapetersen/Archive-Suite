#!/bin/bash
# test-smoke.sh — Archive Reader Tier-1 smoke test (cheap, repeatable regression gate).
#
# Build + run the unit-test suite. No OCR, no network, no corpus access (the Reader tests run on
# scratch copies, per its Core Directive). Prints PASS/FAIL + the executed test count.
#
#   xcodegen generate
#   xcodebuild test -scheme ArchiveReader -destination 'platform=macOS' -derivedDataPath ./build/DD
#
# A run log is kept under `.maintenance/test-results/` (gitignored).
# Usage: bash ArchiveReader/test-smoke.sh
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"

ROOT="$(cd "$(dirname "$0")" && pwd)"          # .../ArchiveReader (outer app dir)
PROJ="$ROOT/ArchiveReader"                     # inner XcodeGen project dir
LOGDIR="$ROOT/.maintenance/test-results"; mkdir -p "$LOGDIR"
TS=$(date +%Y%m%d-%H%M%S)
LOG="$LOGDIR/smoke-reader-$TS.log"

echo "=== Archive Reader smoke test (build + unit tests) · $TS ==="
( cd "$PROJ" && xcodegen generate >/dev/null 2>&1 \
   && xcodebuild test -scheme ArchiveReader -destination 'platform=macOS' -derivedDataPath ./build/DD ) \
   >"$LOG" 2>&1
rc=$?

# Aggregate executed-tests count across the suites (last "Executed N tests" line is the total).
count=$(grep -Eo 'Executed [0-9]+ test[s]?' "$LOG" | tail -1)

if [ "$rc" -eq 0 ] && grep -q "TEST SUCCEEDED" "$LOG"; then
  echo "SMOKE (reader): PASS — ${count:-tests executed}"
  echo "  run log: $LOG"
  exit 0
else
  echo "SMOKE (reader): FAIL — ${count:-no test count parsed}"
  echo "  failure log: $LOG"
  grep -E 'error:|failed|TEST FAILED|BUILD FAILED' "$LOG" | tail -20
  exit 1
fi
