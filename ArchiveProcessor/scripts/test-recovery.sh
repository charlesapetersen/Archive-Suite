#!/bin/bash
# Key-free synthetic regression for the Live Capture DATA-SAFETY invariants: confirm-before-delete,
# trash-not-rm, legacy-manifest migration, and (W23.h1) conservative launch-time session pruning.
# Runs LiveCaptureRecoveryTestDriver headless ($0, no OCR, no network, no GUI). ARCHIVEPROC_TEST_BACKUP_ROOT
# points the app's own launch-time prune at a throwaway dir so it can NEVER touch the real corpus.
set -euo pipefail
cd "$(dirname "$0")/.."

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
if [ ! -x "$bin" ]; then
    echo "ArchiveProcessor is not built; run the documented Debug build first." >&2
    exit 1
fi

work=$(mktemp -d)
report="$work/result.txt"
log="$work/app.log"
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    LIVECAPTURE_RECOVERYTEST=1 LIVECAPTURE_RECOVERYTEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 60); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Recovery data-safety test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
