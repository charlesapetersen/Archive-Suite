#!/bin/bash
# S-052: run Process Files through the normal pipeline on two synthetic label photos.
# The local gateway accepts both transcriptions and returns HTTP 500 for both label reads.
# Usage: bash ArchiveProcessor/scripts/repro-s052-label-failures.sh (after the documented Debug build).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

built_app="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app"
[ -x "$built_app/Contents/MacOS/ArchiveProcessor" ] || { echo "Build Archive Processor Debug first." >&2; exit 1; }
work="$(mktemp -d /private/tmp/ap-s052.XXXXXX)"
echo "Scratch artifacts: $work"
source "$PWD/scripts/test-child.sh"
# The preferences daemon does not honor CFFIXED_USER_HOME. Give only the scratch
# bundle a unique preferences domain, and drop that domain after the test stops.
scratch_app="$work/ArchiveProcessor.app"
scratch_id="org.archivesuite.test.s052.${work##*.}"
processor_test_after_stop() {
    defaults delete "$scratch_id" >/dev/null 2>&1 || true
}
processor_test_init
ditto "$built_app" "$scratch_app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $scratch_id" "$scratch_app/Contents/Info.plist"
codesign --force --sign "Archive Suite Dev" --preserve-metadata=entitlements,flags "$scratch_app"
bin="$scratch_app/Contents/MacOS/ArchiveProcessor"
mkdir -p "$work"/{in,out,home}
port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
gateway="http://127.0.0.1:$port/v1"

# Vision can recover the number on one label. The blank photo has no fields for it to recover.
magick -size 1200x800 xc:white -font '/System/Library/Fonts/Supplemental/Arial.ttf' \
    -pointsize 120 -gravity center -fill black -annotate +0+0 'Box 17' "$work/in/01-box.jpg"
magick -size 1200x800 xc:white "$work/in/02-folder.jpg"

FAKE_GATEWAY_FAIL_OTHER=1 processor_test_start gateway_pid python3 scripts/fake_gateway.py \
    "$port" "$work/gateway.tsv" 500 stand-in-key >"$work/gateway.log" 2>&1
sleep 1
[ "$(processor_test_child_state "$gateway_pid")" = running ] || { cat "$work/gateway.log" >&2; exit 1; }

# Keep the recovery journal and other Application Support files under scratch as well.
CFFIXED_USER_HOME="$work/home" ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    PROCESSFILES_TESTMODE=1 PROCESSFILES_TESTKEY=stand-in-key PROCESSFILES_TESTIN="$work/in" \
    PROCESSFILES_TESTOUT="$work/out" PROCESSFILES_MAXIMAGES=2 PROCESSFILES_TAGGING=none \
    PROCESSFILES_GATEWAY_URL="$gateway" PROCESSFILES_GATEWAY_MODEL=stand-in \
    PROCESSFILES_METER=1 PROCESSFILES_CAP_USD=1 PROCESSFILES_REDIRECT_URL="$gateway/chat/completions" \
    processor_test_start app_pid "$bin" -readContainerLabels YES -ocrWorkerCount 1 >"$work/app.log" 2>&1

# The manifest comes after the summary and the stand-in request log, so wait for it to be written.
for ((i=0; i<90; i++)); do
    manifests=("$work"/out/run-*/manifest.tsv)
    [ -f "${manifests[0]}" ] && break
    sleep 1
done
[ -s "${manifests[0]}" ] || { tail -35 "$work/app.log" >&2; exit 1; }
processor_test_stop "$app_pid"
processor_test_stop "$gateway_pid"

python3 - "$work" "${manifests[0]}" <<'PY'
import json
import sys
from pathlib import Path

work, manifest = map(Path, sys.argv[1:])
run = manifest.parent
requests = (work / "gateway.tsv").read_text().splitlines()
labels = [line for line in requests if "This photo was taken in an archive reading room" in line]
if len(requests) != 4 or len(labels) != 2 or any(not line.startswith("other-500\t") for line in labels):
    sys.exit(f"Expected two page reads and two HTTP 500 label replies. Got {requests!r}")
rows = [line.split("\t") for line in manifest.read_text().splitlines() if not line.startswith("#")]
expected = [
    ["01-box.pdf", "box_label", "succeeded"],
    ["02-folder.pdf", "folder_label", "succeeded"],
]
if rows != expected:
    sys.exit(f"Expected two successful page transcriptions classified as labels. Got {rows!r}")
for pdf, classification, status in rows:
    if not (run / pdf).is_file():
        sys.exit(f"Missing generated PDF: {pdf}")
    print(f"PDF: {pdf}\t{classification}\t{status}")
for line in labels:
    print(f"Gateway: {line}")
print((run / "status.txt").read_text().strip())
container_file = run / ".archivesuite" / "containers.json"
if container_file.is_file():
    for marker in json.loads(container_file.read_text())["runs"]:
        print(f"Marker: {marker['start']}\t{marker['level']}\t{json.dumps(marker.get('fields', {}), sort_keys=True)}")
else:
    print("No container file written.")
PY
