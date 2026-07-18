#!/bin/bash
# Key-free ($0) self-test of the Local Agent CLI backend: drives the REAL LocalAgentClient against the
# committed fake CLI (scripts/localagent-fake-cli.sh) and verifies OCRProcessor.PendingRun resume-safety
# of the new `localAgent` carrier. Headless (LOCALAGENT_TEST=1) — no real model, no network, no cost,
# never the corpus.
#
# NOTE: this LAUNCHES the app binary (headless placeholder window), so it is deferred out of GUI-off
# autonomous sessions. For a no-launch proof of the subprocess plumbing + Codable semantics, run
# instead:  swift macOS/../scripts/localagent-mechanism-test.swift  (see scripts/localagent-mechanism-test.swift).
set -euo pipefail
cd "$(dirname "$0")/.."

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
if [ ! -x "$bin" ]; then
    echo "ArchiveProcessor is not built; run the documented Debug build first." >&2
    exit 1
fi

fake="$PWD/scripts/localagent-fake-cli.sh"
chmod +x "$fake" 2>/dev/null || true

work=$(mktemp -d)
report="$work/result.txt"
log="$work/app.log"
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    LOCALAGENT_TEST=1 LOCALAGENT_TEST_OUT="$report" LOCALAGENT_FAKE_CLI="$fake" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 60); do
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
