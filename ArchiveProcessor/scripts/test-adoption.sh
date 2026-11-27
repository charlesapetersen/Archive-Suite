#!/bin/bash
# Key-free ($0) self-test of the pre-app archive adoption tool (W49.corpus-adoption-tool): runs AdoptionTestDriver
# headless on a fixture tree it makes in a scratch folder. No model call, no network, no window, never the corpus.
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
processor_test_init "$work" unlock
report="$work/result.txt"
mkdir "$work/fixtures"
log="$work/app.log"
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    ADOPTION_TEST=1 ADOPTION_TEST_OUT="$report" ADOPTION_TEST_DIR="$work/fixtures" \
    processor_test_start pid "$bin" >"$log" 2>&1

for _ in $(seq 1 120); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Adoption test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
