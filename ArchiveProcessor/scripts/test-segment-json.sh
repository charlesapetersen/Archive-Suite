#!/bin/bash
# Key-free ($0) byte-identity regression for the shared SegmentJSONBuilder: asserts the consolidated
# builder reproduces the two ORIGINAL inline segment-JSON sidecar implementations
# (OCRProcessor.writeSegmentJSON + LiveCaptureProcessor.writeSegmentJSON) byte-for-byte across an
# input matrix. Pure in-memory JSON comparison — no network, no files, no corpus. Headless self-test
# (SEGMENT_JSON_TEST=1). Build the Debug app first (documented build), then run this.
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
ARCHIVEPROC_HEADLESS=1 \
    SEGMENT_JSON_TEST=1 SEGMENT_JSON_TEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 60); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Segment-JSON byte-identity test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
