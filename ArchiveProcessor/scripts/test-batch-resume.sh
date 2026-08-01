#!/bin/bash
# Key-free, no-network regression for Process Files batch/non-batch crash-resume manifests,
# plus the three paid batch clients' provider response-shape contract (W16.bat1 — BatchParseContract)
# and the cancel path's journal-retention contract (W16.bat2 — BatchCancelContract) plus its wiring
# (W16.bat2-fu — BatchCancelWiringContract: the real cancel() with both cancel-path seams stubbed).
set -euo pipefail
cd "$(dirname "$0")/.."

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$bin" ] || { echo "ArchiveProcessor is not built" >&2; exit 1; }

work=$(mktemp -d)
report="$work/result.txt"
log="$work/app.log"
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    BATCHRESUME_TEST=1 BATCHRESUME_TEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

# 4s on a machine with no pending manifests — but the cancel-WIRING sweep (W16.bat2-fu3) presses Stop 80
# times, and each Stop ends in a real checkForPendingBatch() that decodes whatever paid-batch and
# interrupted-run manifests the operator actually has and re-derives their fingerprints. A large
# interrupted run makes that the dominant cost, so the wait is minutes: a timeout here reads as a failed
# contract, and this one would fire exactly when the owner has a live paid batch. (Closes with
# W16.bat2-fu2, which makes those paths redirectable under test.)
for _ in $(seq 1 300); do [ -f "$report" ] && break; sleep 1; done
if [ ! -f "$report" ]; then tail -80 "$log" >&2; exit 1; fi
cat "$report"
grep -q '^ALL PASS$' "$report"
