#!/bin/bash
# Key-free ($0) self-test of W49.proc-fix-s042 (suspect S-042): runs TaggingFailureTestDriver headless, which drives
# performTaggingPhase on four documents whose tagging calls get an answer, a provider 500, a timeout and a reply that
# is not the tag JSON, every request answered by the injected test transport. It checks that the three failed calls
# are named in the status line and the run log, are not counted as tagged, are asked once each, and that a Redo whose
# calls answer clears them. No real network, no Keychain read, no window, never the corpus: scratch only.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox
set -euo pipefail
cd "$(dirname "$0")/.."

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
if [ ! -x "$bin" ]; then
    echo "ArchiveProcessor is not built; run the documented Debug build first." >&2
    exit 1
fi

work=$(mktemp -d)
source "$PWD/scripts/test-child.sh"
processor_test_init "$work"
report="$work/result.txt"
log="$work/app.log"
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    TAGGING_FAILURE_TEST=1 TAGGING_FAILURE_TEST_OUT="$report" \
    processor_test_start pid "$bin" >"$log" 2>&1

for _ in $(seq 1 60); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Tagging failure test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
