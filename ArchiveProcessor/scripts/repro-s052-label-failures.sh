#!/bin/bash
# S-052: run Process Files through the normal pipeline on two synthetic label photos.
# The local gateway accepts both transcriptions. Its label requests both fail with HTTP 500
# by default. In the mixed case, both replies include usage and only one supplies a usable field.
# S-053: missing-model uses the OpenAI preset with a stand-in that lists only the preset's page reader.
# Usage after a Debug build: bash ArchiveProcessor/scripts/repro-s052-label-failures.sh [mixed|missing-model]
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

scenario="${1:-refused}"
gateway_preset=
gateway_upstream=Gemini
gateway_models=
page_model=stand-in
case "$scenario" in
    refused) label_replies='[]' ;;
    mixed) label_replies='[{"collection_title":"Test Papers"}, {}]' ;;
    missing-model)
        label_replies='[]'
        page_model=gpt-5.4-mini
        gateway_preset=openai
        gateway_upstream=OpenAI
        gateway_models="$page_model"
        ;;
    *) echo "Expected refused, mixed or missing-model." >&2; exit 2 ;;
esac

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

FAKE_GATEWAY_FAIL_OTHER=1 FAKE_GATEWAY_LABEL_REPLIES="$label_replies" FAKE_GATEWAY_MODELS="$gateway_models" \
    processor_test_start gateway_pid python3 scripts/fake_gateway.py \
    "$port" "$work/gateway.tsv" 500 stand-in-key >"$work/gateway.log" 2>&1
sleep 1
[ "$(processor_test_child_state "$gateway_pid")" = running ] || { cat "$work/gateway.log" >&2; exit 1; }

if [ "$scenario" = missing-model ]; then
    python3 - "$gateway/models" "$page_model" <<'PY_CATALOG'
import json
import sys
from urllib.request import Request, urlopen

url, page_model = sys.argv[1:]
with urlopen(Request(url, headers={"Authorization": "Bearer stand-in-key"}), timeout=5) as response:
    models = [entry["id"] for entry in json.load(response)["data"]]
if models != [page_model]:
    sys.exit(f"Unexpected stand-in model catalog: {models!r}")
print(f"Stand-in model catalog: {models[0]}")
PY_CATALOG
fi

# Keep the recovery journal and other Application Support files under scratch as well.
CFFIXED_USER_HOME="$work/home" ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    PROCESSFILES_TESTMODE=1 PROCESSFILES_TESTKEY=stand-in-key PROCESSFILES_TESTIN="$work/in" \
    PROCESSFILES_TESTOUT="$work/out" PROCESSFILES_MAXIMAGES=2 PROCESSFILES_TAGGING=none \
    PROCESSFILES_GATEWAY_URL="$gateway" PROCESSFILES_GATEWAY_MODEL="$page_model" \
    PROCESSFILES_METER=1 PROCESSFILES_CAP_USD=1 PROCESSFILES_REDIRECT_URL="$gateway/chat/completions" \
    PROCESSFILES_GATEWAY_PRESET="$gateway_preset" PROCESSFILES_GATEWAY_UPSTREAM="$gateway_upstream" \
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

python3 - "$work" "${manifests[0]}" "$scenario" "$page_model" <<'PY'
import json
import sys
from pathlib import Path

work, manifest = map(Path, sys.argv[1:3])
scenario, page_model = sys.argv[3:5]
mixed = scenario == "mixed"
run = manifest.parent
requests = (work / "gateway.tsv").read_text().splitlines()
labels = [line for line in requests if "This photo was taken in an archive reading room" in line]
page_reads = [line for line in requests if line.startswith(f"ocr\t{page_model}\t")]
expected_kind = {"mixed": "labels", "refused": "other-500", "missing-model": "model_not_found-404"}[scenario]
if len(requests) != 4 or len(page_reads) != 2 or len(labels) != 2 or any(
    line.split("\t")[:2] != [expected_kind, "gpt-5.6-luna"] for line in labels
):
    sys.exit(f"Expected two page reads and two label replies for {sys.argv[3]}. Got {requests!r}")
if scenario == "missing-model":
    wire = [line for line in (run / "requests.tsv").read_text().splitlines() if not line.startswith("#")]
    if len(wire) != 4 or any(not line.startswith("api.openai.com/v1/chat/completions\t") for line in wire):
        sys.exit(f"Expected only the four OpenAI-preset completions, with no model lookup. Got {wire!r}")
    label_wire = [line for line in wire if "\tmodel=gpt-5.6-luna\t" in line]
    if len(label_wire) != 2 or any(not line.endswith("params=max_tokens:1200,reasoning_effort:low") for line in label_wire):
        sys.exit(f"Unexpected label requests: {label_wire!r}")
    for line in wire:
        print(f"Original request: {line}")
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
summary = (run / "status.txt").read_text().strip()
print(summary)
if mixed:
    expected_note = "1 box or folder label read through the gateway (GPT 5.6 Luna), 1 failed attempt, $0.0016."
else:
    expected_note = "0 box or folder labels read through the gateway (GPT 5.6 Luna), 2 failed attempts, $0.0000."
if expected_note not in summary:
    sys.exit(f"Missing gateway summary {expected_note!r}")
if "1 label photo read nothing" not in summary:
    sys.exit("Missing the separate warning about the empty folder label.")
container_file = run / ".archivesuite" / "containers.json"
markers = {(marker["start"], marker["level"]): marker for marker in json.loads(container_file.read_text())["runs"]}
for marker in markers.values():
    print(f"Marker: {marker['start']}\t{marker['level']}\t{json.dumps(marker.get('fields', {}), sort_keys=True)}")
box = markers["01-box.pdf", "box"]
folder = markers["02-folder.pdf", "folder"]
container = box["fields"]["container"]
if container["value"] != "Box 17" or container["reader"] != "vision+parser":
    sys.exit("Missing the local Box 17 proposal.")
if mixed:
    title = markers["01-box.pdf", "collection"]["fields"]["collectionTitle"]
    if title["value"] != "Test Papers" or title["reader"] != "gpt-5.6-luna":
        sys.exit("Missing the gateway collection title.")
if folder.get("fields"):
    sys.exit("Expected an empty folder marker.")
PY
