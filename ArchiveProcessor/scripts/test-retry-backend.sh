#!/bin/bash
# Key-free, no-network contract test for Process Files retry backend locking. Uses the committed fake
# Local Agent CLI plus an injected HTTP transport; every output is in one temporary directory.
set -euo pipefail
cd "$(dirname "$0")/.."
source "$PWD/scripts/test-report-wait.sh"

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$bin" ] || { echo "ArchiveProcessor is not built" >&2; exit 1; }

work=$(mktemp -d)
report="$work/result.txt"
log="$work/app.log"
fake="$PWD/scripts/localagent-fake-cli.sh"
chmod +x "$fake" 2>/dev/null || true

ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    RETRY_BACKEND_TEST=1 RETRY_BACKEND_TEST_OUT="$report" LOCALAGENT_FAKE_CLI="$fake" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

wait_for_test_report "$report" "$log" "$pid" "Retry-backend" "RETRY" 120
cat "$report"
grep -q '^ALL PASS$' "$report"
