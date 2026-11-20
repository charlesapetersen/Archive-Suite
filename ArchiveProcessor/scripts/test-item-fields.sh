#!/bin/bash
# Key-free ($0) self-test of the item fields (W47.item-fields-build): runs ItemFieldsTestDriver headless, which checks
# reply parsing as the bench does it, the marked text, the fill policy (title case on the header; each field on the kinds it was
# scored on), the sidecar's item_fields object, and the call end to end through performTaggingPhase with every request
# answered by the injected test transport. No real network, no Keychain read, no window, never the corpus: scratch
# outputs only.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox
set -euo pipefail
cd "$(dirname "$0")/.."

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
if [ ! -x "$bin" ]; then
    echo "ArchiveProcessor is not built; run the documented Debug build first." >&2
    exit 1
fi

work=$(mktemp -d)
source "$PWD/scripts/test-child.sh"
processor_test_init "$work"
report="$work/result.txt"
log="$work/app.log"
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    ITEM_FIELDS_TEST=1 ITEM_FIELDS_TEST_OUT="$report" ITEM_FIELDS_TEST_KEEP="$work/keep" \
    processor_test_start pid "$bin" >"$log" 2>&1

for _ in $(seq 1 90); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Item fields test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"

# W40.fix-processor-evidence-rewrite-name: the rewrite of a source named with a U+00A0 keeps the name's characters,
# which PDFKit cannot see (it reads a U+00A0 as a space), and qpdf finds nothing to repair in it.
keep="$work/keep"
for f in nbsp-original.pdf nbsp-dated.pdf nbsp-name.txt; do
    [ -f "$keep/$f" ] || { echo "FAIL the U+00A0 rewrite left no $f" >&2; exit 1; }
done
qpdf="$(command -v qpdf || echo /opt/homebrew/bin/qpdf)"
for f in nbsp-original.pdf nbsp-dated.pdf; do
    if ! "$qpdf" --check "$keep/$f" >"$work/qpdf.txt" 2>&1; then
        echo "FAIL qpdf --check $f:" >&2; cat "$work/qpdf.txt" >&2; exit 1
    fi
done
python3 - "$keep" <<'PY'
import sys
from pypdf import PdfReader
keep = sys.argv[1]
name = open(f'{keep}/nbsp-name.txt', encoding='utf-8').read()
for f in ('nbsp-original.pdf', 'nbsp-dated.pdf'):
    # pypdf ends a line with an ordinary space; only that is taken off.
    lines = [ln.strip(' ') for ln in PdfReader(f'{keep}/{f}').pages[1].extract_text().splitlines()]
    if len(lines) < 2 or lines[1] != name:
        sys.exit(f'FAIL {f}: the name line is {lines[1:2]!r}, not {name!r}')
print('PASS the U+00A0 name reads back byte for byte, and qpdf --check is clean, before and after the rewrite')
PY
