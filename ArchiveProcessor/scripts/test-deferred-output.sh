#!/bin/bash
# Key-free, no-network contract for W49.proc-unified-pipeline-2: a standard Files run holds each output PDF back until
# the reviews are done, then writes it once; a resume does the same. Every file is in a temporary directory.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox (2026-10-05)
set -euo pipefail
cd "$(dirname "$0")/.."
source "$PWD/scripts/test-report-wait.sh"

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$bin" ] || { echo "ArchiveProcessor is not built" >&2; exit 1; }

work=$(mktemp -d)
source "$PWD/scripts/test-child.sh"
processor_test_init "$work"
report="$work/result.txt"
log="$work/app.log"

ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    DEFERRED_OUTPUT_TEST=1 DEFERRED_OUTPUT_TEST_OUT="$report" \
    processor_test_start pid "$bin" >"$log" 2>&1

wait_for_test_report "$report" "$log" "$pid" "Deferred-output" "DEFERRED_OUTPUT" 300
cat "$report"
grep -q '^ALL PASS$' "$report"
