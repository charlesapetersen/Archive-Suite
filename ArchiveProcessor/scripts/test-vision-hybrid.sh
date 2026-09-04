#!/bin/bash
# Key-free, no-network contract for the Vision + LLM hybrid. It runs the production app headlessly,
# injects one literal text response, and verifies that the real request body contains no image payload.
set -euo pipefail
cd "$(dirname "$0")/.."
source "$PWD/scripts/test-report-wait.sh"

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$bin" ] || { echo "ArchiveProcessor is not built" >&2; exit 1; }
work=$(mktemp -d)
report="$work/result.txt"
log="$work/app.log"
cleanup() {
    kill "$pid" 2>/dev/null || true
    # The app intentionally idles after writing the report. Reap its expected SIGTERM so the shell
    # does not print a misleading “Terminated” job-control line after an otherwise green contract.
    wait "$pid" 2>/dev/null || true
    rm -rf "$work"
}

ARCHIVEPROC_HEADLESS=1 VISIONHYBRID_TEST=1 VISIONHYBRID_TEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap cleanup EXIT
wait_for_test_report "$report" "$log" "$pid" "Vision hybrid" "VISIONHYBRID" 60
cat "$report"
grep -q '^ALL PASS$' "$report"
