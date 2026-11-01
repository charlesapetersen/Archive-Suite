#!/bin/bash
# Key-free ($0) self-test of the provider error messages (W40.fix-processor-gemini-402-message): runs ProviderErrorTestDriver headless.
# Canned reply bodies only: a 402 must read as credit or billing (provider and billing page named), never as a rate
# limit, and a 429 must stay the rate limit. No request, no network, no Keychain read, no window, never the corpus.
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
    PROVIDER_ERROR_TEST=1 PROVIDER_ERROR_TEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 60); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Provider error test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
