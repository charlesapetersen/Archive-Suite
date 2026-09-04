#!/bin/bash
# Key-free ($0) self-test of processing-history + Local Agent durable provenance: exercises
# RunHistorySnapshot.makeRun, estimator-derived cost, a scratch PDF's Local Agent header/parser round-trip,
# and ProcessingHistoryStore's record / newest-first / bounded-trim / persistence / clear behavior. Headless
# (PROCESSING_HISTORY_TEST=1),
# run against a THROWAWAY UserDefaults suite — never .standard, never the corpus, never the operator's
# real history.
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
    PROCESSING_HISTORY_TEST=1 PROCESSING_HISTORY_TEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 60); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Processing-history test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
