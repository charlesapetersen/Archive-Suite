#!/bin/bash
# Key-free, no-network contract for W41.app-institutional-compute: an institutional cluster bulk run's text through the real
# performOCRCall over an injected HTTP transport; the bulk folder, inputs and outputs are all in temporary directories.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox (2026-10-05)
set -euo pipefail
cd "$(dirname "$0")/.."
source "$PWD/scripts/test-report-wait.sh"

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$bin" ] || { echo "ArchiveProcessor is not built" >&2; exit 1; }

work=$(mktemp -d)
report="$work/result.txt"
log="$work/app.log"

ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    INSTITUTIONAL_COMPUTE_IMPORT_TEST=1 INSTITUTIONAL_COMPUTE_IMPORT_TEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

wait_for_test_report "$report" "$log" "$pid" "Institutional-compute-import" "INSTITUTIONAL_COMPUTE_IMPORT" 120
cat "$report"
grep -q '^ALL PASS$' "$report"
