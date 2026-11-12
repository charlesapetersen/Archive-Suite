#!/bin/bash
# Key-free ($0) self-test of the two interviews (W46.settings-interviews): runs SettingsInterviewsTestDriver headless,
# which checks what the general interview finds on the Mac (through a fake Keychain probe) and writes, the skipped
# interview's "Free, on this Mac", the starting points as fills, the kind measurement's sample and tally, the mix and
# public test sets the period, languages and scripts select, the priority weights the solver reads, and both
# interviews' writes into a scratch general store and a scratch collection folder it deletes. No model call, no
# network, no Keychain read, no window, never the app's own store or an output folder of the user's.
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
    SETTINGS_INTERVIEWS_TEST=1 SETTINGS_INTERVIEWS_TEST_DIR="$work/scratch" SETTINGS_INTERVIEWS_TEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 60); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Settings interviews test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
