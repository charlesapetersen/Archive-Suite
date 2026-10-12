#!/bin/bash
# Key-free ($0) self-test of the W36 review of flagged boundaries: who segments for every tagging mode and
# approach, keep/split/join into classifications, the run manifest's segmentation progress, and the window stage
# driven end to end (box/folder confirmation, the windows, the flagged pass, the skim, resume, a usage limit) on
# synthetic pages. Runs SegmentationReviewTestDriver headless — a recorded transport, no model call, no network,
# no Keychain read, no window, the manifest save kept in memory, never the corpus.
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
    SEGMENTATION_REVIEW_TEST=1 SEGMENTATION_REVIEW_TEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 90); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Segmentation review test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
