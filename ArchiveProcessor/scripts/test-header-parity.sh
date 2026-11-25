#!/bin/bash
# Key-free synthetic regression for W49.proc-catalogue-cutover: Process Files and Live Capture write the same
# page-2 provenance header (Classification line included) for the same phone-grouped pages: a two-page document,
# a box photo and a folder photo. Runs HeaderParityContract headless ($0, no OCR, no network, no GUI) on synthetic
# JPEGs in a temp dir; it never opens or modifies the archive corpus.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
if [ ! -x "$bin" ]; then
    echo "ArchiveProcessor is not built; run the documented Debug build first." >&2
    exit 1
fi

work=$(mktemp -d)
source "$PWD/scripts/test-child.sh"
processor_test_init "$work"
report="$work/result.txt"
log="$work/app.log"
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    HEADER_PARITY_TEST=1 HEADER_PARITY_TEST_OUT="$report" \
    processor_test_start pid "$bin" >"$log" 2>&1

for _ in $(seq 1 60); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Header parity test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
