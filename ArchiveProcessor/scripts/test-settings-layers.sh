#!/bin/bash
# Key-free ($0) self-test of the settings layers (W46.settings-layers): runs SettingsLayersTestDriver headless, which
# checks the general, project and collection layers' live resolution with sources and resets, the money habit's
# ceiling, the solver's inputs, the general store, and the collection's settings document writer (atomic, never
# through a link, an unreadable file set aside, a newer one left alone) on scratch folders it deletes. No model call,
# no network, no Keychain read, no window, never the app's own store or an output folder of the user's.
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
    SETTINGS_LAYERS_TEST=1 SETTINGS_LAYERS_TEST_DIR="$work/scratch" SETTINGS_LAYERS_TEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 60); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Settings layers test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
