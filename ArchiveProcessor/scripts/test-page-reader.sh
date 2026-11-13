#!/bin/bash
# Key-free ($0) self-test of the one way to read a page (W42.int-s2): runs PageReaderTestDriver headless. Each
# provider's journey reads the two smoke pages (cloud replies through the no-wire seam NetworkSession.testTransport,
# the Local Agent through the committed fake CLI, Apple Vision for real), and the journey lines must equal
# scripts/page-reader-journeys.golden, recorded before the PageReader protocol existed. Also runs the seam check
# (scripts/check-page-reader-seam.sh). No model call, no network, no Keychain read, no window, never the corpus.
#
#   scripts/test-page-reader.sh [--record]   (--record rewrites the golden file; only on a deliberate text change)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox
set -euo pipefail
cd "$(dirname "$0")/.."

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
if [ ! -x "$bin" ]; then
    echo "ArchiveProcessor is not built; run the documented Debug build first." >&2
    exit 1
fi
golden="$PWD/scripts/page-reader-journeys.golden"

work=$(mktemp -d)
report="$work/result.txt"
log="$work/app.log"
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    PAGEREADER_TEST=1 PAGEREADER_TEST_OUT="$report" LOCALAGENT_FAKE_CLI="$PWD/scripts/localagent-fake-cli.sh" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 90); do
    [ -f "$report" ] && break
    sleep 1
done
if [ ! -f "$report" ]; then
    echo "Page reader test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
if [ "${1:-}" = --record ]; then
    grep '^JOURNEY ' "$report" > "$golden"
    echo "recorded $(wc -l < "$golden" | tr -d ' ') journey lines in $golden"
fi
status=0
grep -q '^ALL PASS$' "$report" || status=1
if diff <(grep '^JOURNEY ' "$report") "$golden"; then
    echo "PASS journeys equal the golden file ($(wc -l < "$golden" | tr -d ' ') lines)"
else
    echo "FAIL journeys differ from $golden (diff above: < this run, > golden)"; status=1
fi
"$PWD/scripts/check-page-reader-seam.sh" || status=1
exit $status
