#!/bin/bash
# Key-free, no-network contract for the Vision + LLM hybrid. It runs the production app headlessly,
# injects one literal text response, and verifies that the real request body contains no image payload.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox (2026-10-05)
set -euo pipefail
cd "$(dirname "$0")/.."
source "$PWD/scripts/test-report-wait.sh"

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$bin" ] || { echo "ArchiveProcessor is not built" >&2; exit 1; }
work=$(mktemp -d)
report="$work/result.txt"
log="$work/app.log"
source "$PWD/scripts/test-child.sh"
processor_test_init "$work"

ARCHIVEPROC_HEADLESS=1 VISIONHYBRID_TEST=1 VISIONHYBRID_TEST_OUT="$report" \
    processor_test_start pid "$bin" >"$log" 2>&1
wait_for_test_report "$report" "$log" "$pid" "Vision hybrid" "VISIONHYBRID" 60
cat "$report"
grep -q '^ALL PASS$' "$report"
