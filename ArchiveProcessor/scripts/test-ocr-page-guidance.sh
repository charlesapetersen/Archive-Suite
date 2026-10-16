#!/bin/bash
# Key-free ($0) self-test of the OCR model picker's "what reads which pages best" note (W41.app-ocr-hierarchy).
# First checks every figure in segbench-results/ocr-page-guidance.json against the bench result file it names, then
# runs OCRPageGuidanceTestDriver headless: the table's own checks, the lines as the user reads them, and a render guard
# that the note draws non-blank pixels offscreen. No model call, no network, no Keychain read, no window, never the
# corpus.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox
set -euo pipefail
cd "$(dirname "$0")/.."

/usr/bin/python3 - segbench-results <<'EOF'
import csv, json, os, re, sys
root = sys.argv[1]
table = json.load(open(os.path.join(root, "ocr-page-guidance.json")))
bad = 0
for kind in table["kinds"]:
    for pick in kind["picks"]:
        s = pick["source"]
        path = os.path.join(root, s["file"])
        found = None
        if s["file"].endswith(".csv"):
            for row in csv.DictReader(open(path)):
                if (row.get("route") or row.get("model")) == s["route"] and row["attribute"] == s["attribute"] \
                        and row["value"] == s["value"]:
                    found = (float(row["nes"]) * 100, int(row["n"]))
        else:  # the markdown ladder table: | route | variant | ok/n | NES | ...
            for line in open(path):
                m = re.match(r"\|\s*%s\s*\|\s*%s\s*\|\s*\d+/(\d+)\s*\|\s*([\d.]+)\s*\|"
                             % (re.escape(s["route"]), re.escape(s["value"])), line)
                if m:
                    found = (float(m.group(2)), int(m.group(1)))
        name = "%s / %s" % (kind["id"], pick["name"])
        if found is None:
            print("FAIL source %s: no row in %s" % (name, s["file"])); bad += 1
        elif round(found[0], 1) != pick["nes"]:
            print("FAIL source %s: NES %.1f in table, %.2f in %s" % (name, pick["nes"], found[0], s["file"])); bad += 1
        elif found[1] != kind["pages"]:
            print("FAIL source %s: %d pages in table, %d in %s" % (name, kind["pages"], found[1], s["file"])); bad += 1
        else:
            print("PASS source %s %.1f on %d pages" % (name, pick["nes"], found[1]))
sys.exit(1 if bad else 0)
EOF

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
if [ ! -x "$bin" ]; then
    echo "ArchiveProcessor is not built; run the documented Debug build first." >&2
    exit 1
fi

work=$(mktemp -d)
report="$work/result.txt"
log="$work/app.log"
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    OCR_PAGE_GUIDANCE_TEST=1 OCR_PAGE_GUIDANCE_TEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 60); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "OCR page guidance test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
