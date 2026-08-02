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
# ARCHIVEPROC_TEST_STATE_ROOT redirects `pending_batch.json` / `pending_run.json` away from the operator's
# Application Support directory for the life of this run (W16.bat2-fu2). It is honoured ONLY alongside
# BATCHRESUME_TEST=1 and only as an absolute directory — see OCRProcessor.pendingStateDirectory. Two things
# depend on it: the SHIPPED journal deleter can be run for real (section 16), and nothing this suite does can
# reach the operator's live paid-batch journal even if a future edit deletes one outside the seam.
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    ARCHIVEPROC_TEST_STATE_ROOT="$work/state" \
    BATCHRESUME_TEST=1 BATCHRESUME_TEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

# The cancel-WIRING sweep (W16.bat2-fu3) presses Stop 80 times and each Stop ends in a real
# checkForPendingBatch(), which decodes whatever paid-batch and interrupted-run manifests it finds. Since
# W16.bat2-fu2 that is the empty redirected state directory above rather than the operator's own, so the
# suite no longer slows down (or times out) in proportion to how large a real interrupted run is. The
# generous wait is kept anyway: a timeout here reads as a failed contract, and buying that certainty costs
# nothing on a green run.
for _ in $(seq 1 300); do [ -f "$report" ] && break; sleep 1; done
if [ ! -f "$report" ]; then tail -80 "$log" >&2; exit 1; fi
cat "$report"
grep -q '^ALL PASS$' "$report"
