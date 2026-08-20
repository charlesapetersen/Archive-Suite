#!/bin/bash
# Key-free synthetic regression for the Live Capture DATA-SAFETY invariants: confirm-before-delete,
# trash-not-rm, legacy-manifest migration, (W23.h1) conservative launch-time session pruning, and
# (W3.cap-r6) staging reclaimed only when nothing is left staged.
# Runs LiveCaptureRecoveryTestDriver headless ($0, no OCR, no network, no GUI). ARCHIVEPROC_TEST_BACKUP_ROOT
# points the app's own launch-time prune at a throwaway dir so it can NEVER touch the real corpus, and
# LIVECAPTURE_TESTOUT does the same for `currentOutputDirectory` (whose fallback is the operator's real
# Settings output folder) — belt and braces for W3.cap-r6, which drives the real `finalize`.
set -euo pipefail
cd "$(dirname "$0")/.."
source "$PWD/scripts/test-report-wait.sh"

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
if [ ! -x "$bin" ]; then
    echo "ArchiveProcessor is not built; run the documented Debug build first." >&2
    exit 1
fi

work=$(mktemp -d)
report="$work/result.txt"
log="$work/app.log"
mkdir -p "$work/out"
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    LIVECAPTURE_TESTOUT="$work/out" \
    LIVECAPTURE_RECOVERYTEST=1 LIVECAPTURE_RECOVERYTEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

wait_for_test_report "$report" "$log" "$pid" "Recovery data-safety" "RECOVERYTEST"

cat "$report"
grep -q '^ALL PASS$' "$report"
