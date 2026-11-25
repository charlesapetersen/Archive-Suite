#!/bin/bash
# repro-suspects-filing.sh — W49.proc-suspects-filing: the reproduce attempts for the Processor's filing and tagging
# suspects (verification/SUSPECTS.md), each a real Process Files run through `startProcessing` (PROCESSFILES_TESTMODE),
# on synthetic scratch photos, against the stand-in gateway (scripts/fake_gateway.py) on 127.0.0.1 — $0, no network.
#
#   ./scripts/repro-suspects-filing.sh [case ...]     cases: s034-copysource s034-none s036-dotdot s036-slash
#                                                     s036-empty s017-preocred s017-images-toggle s033-noyear
#                                                     s035-resume s031-window
#
# Each case prints the review gates the run raised and every PDF it wrote with its Finder tags, read from the xattr
# (finder_tags.py), and a verdict line `CASE <name>: <what was seen>`. The run folders stay in the printed scratch
# directory for inspection. It never reads or writes anything outside a fresh mktemp directory.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
BIN="$REPO/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$BIN" ] || { echo "ArchiveProcessor is not built (macOS/build/DD)" >&2; exit 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ap-suspects-filing.XXXXXX")
echo "scratch: $WORK"
source "$REPO/scripts/test-child.sh"
processor_test_init "$WORK"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')

# Six photos: the stand-in's class cycle makes them box label, folder label, start, continuation, start, start.
make_photos() {   # dir [source tag]
    mkdir -p "$1"
    local i
    for i in 1 2 3 4 5 6; do
        magick -size 600x400 xc:white -fill black -draw "rectangle 40,40 $((100 + i * 60)),$((80 + i * 30))" "$1/p$i.jpg"
        [ -n "${2:-}" ] && python3 - "$1/p$i.jpg" "$2" <<'EOF'
import plistlib, subprocess, sys
data = plistlib.dumps([sys.argv[2]], fmt=plistlib.FMT_BINARY)
subprocess.run(['xattr', '-wx', 'com.apple.metadata:_kMDItemUserTags', data.hex(), sys.argv[1]], check=True)
EOF
    done
}

show_pdfs() {   # root
    python3 - "$1" <<'EOF'
import os, sys
sys.path.insert(0, os.path.join(os.getcwd(), 'scripts'))
from finder_tags import read_tags
root = sys.argv[1]
for d, _, fs in sorted(os.walk(root)):
    for f in sorted(fs):
        if f.endswith('.pdf'):
            p = os.path.join(d, f)
            names, label, status = read_tags(p)
            print(f'  pdf  {os.path.relpath(p, root)}\ttags={names}\tlabel={label}\t{status}')
EOF
}

run_case() {   # name indir outdir env...
    local name="$1" indir="$2" out="$3"; shift 3
    mkdir -p "$out"
    local glog="$out/gateway.log"
    env "${GW_ENV[@]}" python3 "$REPO/scripts/fake_gateway.py" "$PORT" "$glog" 500 stand-in-key &
    local gw=$!
    sleep 1
    # Bash exports a function call's temporary assignments only when they are literal, so the case's switches are
    # exported here and taken back after the start (test-child.sh starts the app as this shell's own child).
    local kv vars=(ARCHIVEPROC_HEADLESS=1 "ARCHIVEPROC_TEST_BACKUP_ROOT=$WORK/backup"
        PROCESSFILES_TESTMODE=1 PROCESSFILES_TESTKEY=stand-in-key
        "PROCESSFILES_GATEWAY_URL=http://127.0.0.1:$PORT/v1" PROCESSFILES_GATEWAY_MODEL=stand-in
        PROCESSFILES_METER=1 PROCESSFILES_CAP_USD=100
        "PROCESSFILES_TESTIN=$indir" "PROCESSFILES_TESTOUT=$out" "PROCESSFILES_TESTDONE=$out/DONE.txt"
        PROCESSFILES_MAXIMAGES=6 "$@")
    for kv in "${vars[@]}"; do export "$kv"; done
    processor_test_start pid "$BIN" >"$out/app.log" 2>&1
    for kv in "${vars[@]}"; do unset "${kv%%=*}"; done
    local i
    for i in $(seq 1 120); do [ -f "$out/DONE.txt" ] && break; sleep 1; done
    processor_test_stop "$pid"
    kill "$gw" 2>/dev/null; wait "$gw" 2>/dev/null
    rm -f "$HOME/Library/Application Support/ArchiveProcessor/pending_run.json"
    local rd; rd=$(ls -d "$out"/run-* 2>/dev/null | head -1)
    echo "── $name   driver: $(cat "$out/DONE.txt" 2>/dev/null || echo '(timed out)')"
    [ -n "$rd" ] && sed 's/^/  gate /' "$rd/gates.tsv" 2>/dev/null
    [ -n "$rd" ] && echo "  status: $(cat "$rd/status.txt" 2>/dev/null)"
    show_pdfs "$out"
    RD="$rd"
}

verdict() { echo "CASE $1: $2"; }
GW_ENV=(FAKE_GATEWAY_UNUSED=1)
cases=("$@")
[ ${#cases[@]} -eq 0 ] && cases=(s034-copysource s034-none s036-dotdot s036-slash s036-empty s017-preocred s017-images-toggle s033-noyear
                                 s035-resume s031-window)

for c in "${cases[@]}"; do
    GW_ENV=(FAKE_GATEWAY_UNUSED=1)
    case "$c" in
    s034-copysource)   # S-034: Copy source tags + Collection ID — does the box photo's PDF keep its copied source tag?
        make_photos "$WORK/$c-in" "Source Tag A"
        run_case "$c" "$WORK/$c-in" "$WORK/$c" PROCESSFILES_TAGGING=copySource PROCESSFILES_COLLSEG=1
        labels=$(show_pdfs "$WORK/$c" | grep "'Box'\|'Folder'")
        kept=$(printf '%s\n' "$labels" | grep -c 'Source Tag A')
        verdict "$c" "$(printf '%s\n' "$labels" | grep -c pdf) box/folder PDF(s) tagged Box/Folder, $kept of them still carry the copied 'Source Tag A'";;
    s034-none)         # S-034: No tagging + Collection ID — is a Box tag written?
        make_photos "$WORK/$c-in"
        run_case "$c" "$WORK/$c-in" "$WORK/$c" PROCESSFILES_TAGGING=none PROCESSFILES_COLLSEG=1
        n=$(show_pdfs "$WORK/$c" | grep -c "'Box'\|'Folder'")
        verdict "$c" "$n PDF(s) carry a Box/Folder tag under No tagging";;
    s036-dotdot|s036-slash|s036-empty)   # S-036: a collection name typed in the sheet, Confirm pressed without Return
        case "$c" in s036-dotdot) nm='..';; s036-slash) nm='a/b';; s036-empty) nm='';; esac
        make_photos "$WORK/$c-in"
        run_case "$c" "$WORK/$c-in" "$WORK/$c" PROCESSFILES_TAGGING=automatic PROCESSFILES_COLLSEG=1 \
            PROCESSFILES_CONFIRMCOLL=1 PROCESSFILES_COLLNAME="$nm"
        outside=$(find "$WORK/$c" -maxdepth 1 -name '*.pdf' | wc -l | tr -d ' ')
        inrun=$(find "$RD" -maxdepth 1 -name '0*.pdf' | wc -l | tr -d ' ')
        verdict "$c" "name '$nm': $outside PDF(s) filed OUTSIDE the run's output folder, $inrun numbered PDF(s) loose in it; folders: $(cd "$RD" && find . -mindepth 1 -type d ! -name 'JSON Output' | tr '\n' ' ')";;
    s017-preocred)     # S-017: Pre-OCRed input + Collection ID + Review document segmentation — is a review raised?
        make_photos "$WORK/$c-src"
        run_case "$c-make" "$WORK/$c-src" "$WORK/$c-make" PROCESSFILES_TAGGING=automatic
        mkdir -p "$WORK/$c-in"; find "$WORK/$c-make" -name '*.pdf' -exec cp {} "$WORK/$c-in/" \;
        xattr -c "$WORK/$c-in"/*.pdf
        run_case "$c" "$WORK/$c-in" "$WORK/$c" PROCESSFILES_TAGGING=automatic PROCESSFILES_PREOCRED=1 \
            PROCESSFILES_COLLSEG=1 PROCESSFILES_REVIEWDOCSEG=1
        verdict "$c" "gates raised: $(tr '\t\n' ': ' < "$RD/gates.tsv")";;
    s017-images-toggle)   # S-017 (side): does Review document segmentation change what an image run raises?
        make_photos "$WORK/$c-in"
        run_case "$c-on" "$WORK/$c-in" "$WORK/$c-on" PROCESSFILES_TAGGING=automatic PROCESSFILES_COLLSEG=1 PROCESSFILES_REVIEWDOCSEG=1
        on=$(tr '\t\n' ': ' < "$RD/gates.tsv")
        run_case "$c-off" "$WORK/$c-in" "$WORK/$c-off" PROCESSFILES_TAGGING=automatic PROCESSFILES_COLLSEG=1
        off=$(tr '\t\n' ': ' < "$RD/gates.tsv")
        verdict "$c" "toggle on: $on | toggle off: $off";;
    s033-noyear)       # S-033: a tag reply with year null and date_uncertain false — is Date Uncertain written?
        make_photos "$WORK/$c-in"
        GW_ENV=(FAKE_GATEWAY_TAGS_JSON='{"year": null, "month": null, "day": null, "date_uncertain": false, "subject_tags": ["War Department"], "format": "Letter"}')
        run_case "$c" "$WORK/$c-in" "$WORK/$c" PROCESSFILES_TAGGING=automatic
        docs=$(show_pdfs "$WORK/$c" | grep -v "'Box'\|'Folder'" | grep -c ' pdf ')
        unc=$(show_pdfs "$WORK/$c" | grep -v "'Box'\|'Folder'" | grep -c "Date Uncertain")
        verdict "$c" "$unc of $docs document PDF(s) carry Date Uncertain";;
    s035-resume)       # S-035: a finished paid batch resumed under Automatic, saved with the whole-run review on and
                       # off — which review gates does it raise? (W40.fix-processor-resume-reviews: the probe checks them)
        mkdir -p "$WORK/$c"
        ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$WORK/backup" \
            RESUME_GATES_TEST=1 RESUME_GATES_TEST_OUT="$WORK/$c/result.txt" \
            processor_test_start pid "$BIN" >"$WORK/$c/app.log" 2>&1
        for _ in $(seq 1 400); do [ -f "$WORK/$c/result.txt" ] && break; sleep 1; done
        processor_test_stop "$pid"
        echo "── $c"; sed 's/^/  /' "$WORK/$c/result.txt" 2>/dev/null
        verdict "$c" "$(grep -E '^(PASS|FAIL|ALL PASS|[0-9]+ FAILED)' "$WORK/$c/result.txt" 2>/dev/null | tr '\n' ' ' || echo '(timed out)')";;
    s031-window)       # S-031: an OCR-marked enclosure through the window stage (SegmentationReviewTestDriver §9)
        mkdir -p "$WORK/$c"
        ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$WORK/backup" \
            SEGMENTATION_REVIEW_TEST=1 SEGMENTATION_REVIEW_TEST_OUT="$WORK/$c/result.txt" \
            processor_test_start pid "$BIN" >"$WORK/$c/app.log" 2>&1
        for _ in $(seq 1 120); do [ -f "$WORK/$c/result.txt" ] && break; sleep 1; done
        processor_test_stop "$pid"
        echo "── $c"; grep ' 9' "$WORK/$c/result.txt" | sed 's/^/  /'; tail -1 "$WORK/$c/result.txt" | sed 's/^/  /'
        verdict "$c" "$(grep -c '^PASS 9a' "$WORK/$c/result.txt") of 2 §9a checks pass; $(grep '^INFO 9b the' "$WORK/$c/result.txt" | cut -d: -f2-)";;
    *) echo "unknown case $c" >&2;;
    esac
done
