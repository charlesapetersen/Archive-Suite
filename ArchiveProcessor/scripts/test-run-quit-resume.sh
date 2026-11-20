#!/bin/bash
# Key-free, no-network contract for W49.proc-resume-standard-runs: a quit during a standard Files run waits for the pages in flight, and
# a resume reads only the pages left, over an injected HTTP transport; every file is in a temporary directory.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox (2026-10-05)
set -euo pipefail
cd "$(dirname "$0")/.."
source "$PWD/scripts/test-report-wait.sh"

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$bin" ] || { echo "ArchiveProcessor is not built" >&2; exit 1; }

work=$(mktemp -d)
source "$PWD/scripts/test-child.sh"
processor_test_init "$work"
report="$work/result.txt"
log="$work/app.log"

ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    RUN_QUIT_RESUME_TEST=1 RUN_QUIT_RESUME_TEST_OUT="$report" \
    processor_test_start pid "$bin" >"$log" 2>&1

wait_for_test_report "$report" "$log" "$pid" "Run-quit-resume" "RUN_QUIT_RESUME" 300
cat "$report"
grep -q '^ALL PASS$' "$report"
