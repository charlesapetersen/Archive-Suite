#!/bin/bash
# Key-free ($0) self-test of the collection's review records (W46.kit-corrections-store): runs
# ReviewCorrectionsTestDriver headless, which checks how a run's reviewed gaps are built (checked, changed, accepted;
# label photos and removed pages left out), written beside the output (atomically, a resumed run's record replaced,
# never through a link, nothing created in a missing folder) and read back, and the lines format; then the kit's
# reader (kit_corrections.py) counts the records the app wrote. Scratch folders only, deleted after. No model call,
# no network, no Keychain read, no window, never an output folder of the user's.
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
    REVIEW_CORRECTIONS_TEST=1 REVIEW_CORRECTIONS_TEST_DIR="$work/scratch" REVIEW_CORRECTIONS_TEST_OUT="$report" \
    REVIEW_CORRECTIONS_TEST_KEEP="$work/kept" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 60); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Review corrections test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"

# The kit reads what the app wrote: the newer of the two runs over the same pages is counted, 3 gaps ruled of 4 known,
# and the one line of hand "A. L.".
counted=$(/usr/bin/python3 scripts/segbench/institutional-compute/kit_corrections.py count "$work/kept" --json)
/usr/bin/python3 - "$counted" <<'PY'
import json, sys
(r,) = json.loads(sys.argv[1])
got = (r["name"], r["gaps"]["ruled"], r["gaps"]["known"], [(h["hand"], h["lines"]) for h in r["lines"]])
want = ("Lincoln box 1", 3, 4, [("A. L.", 1)])
print("PASS kit reads the app's records" if got == want else f"FAIL kit reads the app's records: got {got} want {want}")
sys.exit(got != want)
PY
