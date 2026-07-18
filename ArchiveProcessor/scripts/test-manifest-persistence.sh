#!/bin/bash
# Headless synthetic regression for Live Capture manifest durability and completion acknowledgements.
set -euo pipefail
cd "$(dirname "$0")/.."

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$bin" ] || { echo "ArchiveProcessor is not built" >&2; exit 1; }

work=$(mktemp -d)
report="$work/result.txt"
log="$work/app.log"
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    LIVECAPTURE_MANIFESTTEST=1 LIVECAPTURE_MANIFESTTEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 60); do [ -f "$report" ] && break; sleep 1; done
if [ ! -f "$report" ]; then tail -40 "$log" >&2; exit 1; fi
cat "$report"
grep -q '^ALL PASS$' "$report"
