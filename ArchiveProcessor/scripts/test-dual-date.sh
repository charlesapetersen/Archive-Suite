#!/bin/bash
# Key-free synthetic regression for W37.dual-date in the Processor: the [enclosure] marker, the segmenter's
# enclosure relation, the covering letter's date as `Sent With …` (never a neighbour's), JSON/resume
# round-trips and the PDF source-date header lines. Runs DualDateTestDriver headless ($0, no OCR, no
# network, no GUI) on synthetic files in a temp dir — it never opens or modifies the archive corpus.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox (2026-10-05)
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
    DUAL_DATE_TEST=1 DUAL_DATE_TEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 60); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Dual-date test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
