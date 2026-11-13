#!/bin/bash
# Key-free ($0) self-test of the dating route (W46.date-route): runs DateRouteTestDriver headless, which checks the Swift
# port against the bench's own cases (segbench/fixtures/date-route-cases.json, from date_route_cases.py; and every
# W46.date-route-pipeline document when the private bench cache holds swift-cases.json, `date_route_cases.py --real`),
# the decision on the tags and the sidecar, and the route end to end through performTaggingPhase with every request
# answered by the injected test transport. No real network, no Keychain read, no window, never the corpus: scratch only.
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
    DATE_ROUTE_TEST=1 DATE_ROUTE_TEST_OUT="$report" \
    DATE_ROUTE_CASES="$PWD/scripts/segbench/fixtures/date-route-cases.json" DATE_ROUTE_REAL_CASES="$HOME/Library/Caches/ArchiveSuiteRehearsal/date-route-pipeline/swift-cases.json" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 90); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Date route test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
