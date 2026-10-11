#!/bin/bash
# Key-free ($0) self-test of the W36 window segmenter: the bundled options.json, the bench's window layout and
# prompts byte for byte, the parser, both combining rules, failure → flagged, the usage-limit stop and resume, and
# a reproduction of the bench's verdict on every gap of one recorded development box
# (scripts/segbench/engine-fixture-deaver.json: recorded answers, cues blanked). Runs
# SegmentationEngineTestDriver headless — no model call, no network, no GUI, never the corpus.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox
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
    SEGMENTATION_ENGINE_TEST=1 SEGMENTATION_ENGINE_TEST_OUT="$report" \
    SEGMENTATION_ENGINE_FIXTURE="$PWD/scripts/segbench/engine-fixture-deaver.json" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 60); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Segmentation engine test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
