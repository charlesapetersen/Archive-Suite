#!/bin/bash
# S-045 on scratch JPEGs with an injected gateway, no key, network or window.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

bin="${ARCHIVEPROC_TEST_BINARY:-$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor}"
if [ ! -x "$bin" ]; then
    echo "Build ArchiveProcessor in Debug first." >&2
    exit 1
fi

work=$(mktemp -d)
source "$PWD/scripts/test-child.sh"
processor_test_init "$work"
mkdir -p "$work/backup" "$work/out"
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    LIVECAPTURE_TESTOUT="$work/out" LIVECAPTURE_TAGGING_FAILURE_SCRATCH="$work" \
    LIVECAPTURE_TAGGING_FAILURE_TEST=1 \
    processor_test_start pid "$bin" -reviewRotation NO \
    -rotationDefaultMigratedV1 YES -contextRemovedMigratedV1 YES >"$work/app.log" 2>&1

for ((i=0; i<40; i++)); do
    if [ "$(processor_test_child_state "$pid")" = exited ]; then
        result=0
        wait "$pid" || result=$?
        cat "$work/app.log"
        exit "$result"
    fi
    sleep 1
done
cat "$work/app.log" >&2
echo "Live Capture tagging failure probe timed out." >&2
exit 1
