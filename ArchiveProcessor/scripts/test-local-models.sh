#!/bin/bash
# Key-free ($0) self-test of the local open-weight model route (W41.app-local-models): runs LocalModelsTestDriver headless.
# Every request goes to the app's no-wire seam (NetworkSession.testTransport); the driver checks the memory-based pick,
# the local request (token cap, temperature 0, stand-in key, timeout), the loop and reasoning guards, escalation of a
# looped page, one worker at a time and the $0 estimate, and (W41.app-local-models-fu1) the streamed reply, its loop stop and the second reading. No model call, no network, no Keychain read, no window, never
# the corpus.
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
    LOCALMODELS_TEST=1 LOCALMODELS_TEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 60); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Local-models test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
