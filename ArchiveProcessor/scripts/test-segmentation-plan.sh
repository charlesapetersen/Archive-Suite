#!/bin/bash
# Key-free ($0) self-test of the W36 Claude plan route (W36.seg-opt-subscription): the stream-json meter, the
# calibration and its store, the chooser's plan line and route, the first-run question and the 90% pause against the
# committed fake CLI, and that cancelling stops the claude children. Runs SegmentationPlanTestDriver headless — no
# model call, no real plan use, no network, no GUI, never the corpus.
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
    SEGMENTATION_PLAN_TEST=1 SEGMENTATION_PLAN_TEST_OUT="$report" \
    LOCALAGENT_FAKE_CLI="$PWD/scripts/localagent-fake-cli.sh" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 120); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Segmentation plan test timed out." >&2
    cat "$report.partial" >&2 2>/dev/null || true
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
