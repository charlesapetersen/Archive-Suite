#!/bin/bash
# Key-free ($0) self-test of the Local Agent CLI backend: drives the REAL LocalAgentClient against the
# committed fake CLI (scripts/localagent-fake-cli.sh) and verifies OCRProcessor.PendingRun resume-safety
# of the new `localAgent` carrier. Headless (LOCALAGENT_TEST=1) — no real model, no network, no cost,
# never the corpus.
#
# --live (W41.app-claude-plan-reading): also reads the committed non-corpus fixture pages (scripts/e2e-fixtures)
# through the REAL `claude` on your Claude plan at claude-sonnet-5-5, one and two at once, and prints the times. It
# uses the plan's usage window, never money (the client strips the key variables). Never point it at the corpus.
#
# NOTE: this LAUNCHES the app binary (headless placeholder window), so it is deferred out of GUI-off
# autonomous sessions. For a no-launch proof of the subprocess plumbing + Codable semantics, run
# instead:  swift macOS/../scripts/localagent-mechanism-test.swift  (see scripts/localagent-mechanism-test.swift).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox (2026-10-05)
set -euo pipefail
cd "$(dirname "$0")/.."
live_pages=""
wait_s=60
if [ "${1:-}" = "--live" ]; then
    live_pages="$PWD/scripts/e2e-fixtures"
    wait_s=900
fi

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
if [ ! -x "$bin" ]; then
    echo "ArchiveProcessor is not built; run the documented Debug build first." >&2
    exit 1
fi

fake="$PWD/scripts/localagent-fake-cli.sh"
chmod +x "$fake" 2>/dev/null || true

work=$(mktemp -d)
source "$PWD/scripts/test-child.sh"
processor_test_init "$work"
report="$work/result.txt"
log="$work/app.log"
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    LOCALAGENT_TEST=1 LOCALAGENT_TEST_OUT="$report" LOCALAGENT_FAKE_CLI="$fake" LOCALAGENT_LIVE_PAGES="$live_pages" \
    processor_test_start pid "$bin" >"$log" 2>&1

for _ in $(seq 1 "$wait_s"); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Local Agent test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
