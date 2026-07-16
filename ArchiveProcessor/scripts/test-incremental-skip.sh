#!/bin/bash
# Key-free ($0) functional regression for incremental processing (skip already-processed files).
# Drives the pure IncrementalSkip decision over scratch files with controlled modification dates and
# asserts the conservative "when in doubt, PROCESS" rule across every fail-safe branch (no output,
# newer/older/equal mtime, base-name collision, candidate == source, directory-named output,
# nonexistent source, mixed-case, re-OCR cross-dir, mixed set, all-skipped). Headless self-test
# (INCREMENTAL_SKIP_TEST=1), scratch-isolated to a mktemp dir — never the corpus.
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
    INCREMENTAL_SKIP_TEST=1 INCREMENTAL_SKIP_TEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 60); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Incremental-skip test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
