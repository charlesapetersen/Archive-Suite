#!/bin/bash
# Key-free synthetic regression for the Process Files OUTPUT-WARNING contract (W23.m5 + W23.h5-fu):
# a Finder-tag write the filesystem refuses is REPORTED rather than swallowed by `try?`, a PDF that
# could not embed its scan is reported too, both records self-heal on a successful retry, merge hands
# the bookkeeping to the file that survives it, and the end-of-run summary names the affected files.
# Runs ProcessFilesTagWarningTestDriver headless ($0, no OCR, no network, no GUI) on synthetic files in
# a temp dir — it never opens or modifies the archive corpus.
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
    PROCESSFILES_TAGWARN_TEST=1 PROCESSFILES_TAGWARN_TEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 60); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Process Files output-warning test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
