#!/bin/bash
# Key-free, no-network contract for W41.app-ocr-default: the default Gemini model, and the second reader
# for pages Gemini refuses, over an injected HTTP transport; every output is in one temporary directory.
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
    OCRREFUSAL_TEST=1 OCRREFUSAL_TEST_OUT="$report" \
    processor_test_start pid "$bin" >"$log" 2>&1

wait_for_test_report "$report" "$log" "$pid" "OCR-refusal" "OCRREFUSAL" 120
cat "$report"
grep -q '^ALL PASS$' "$report"
