#!/bin/bash
# test-finder-mirror.sh — W49.storage-finder: filed PDFs carry Finder tags only when "Mirror archive fields to Finder
# tags" is on (owner, 2026-11-27: off everywhere by default). Two real Process Files runs through `startProcessing`
# (PROCESSFILES_TESTMODE) on synthetic scratch photos carrying a source tag, against the stand-in gateway
# (scripts/fake_gateway.py) on 127.0.0.1 — $0, no network, nothing outside a fresh mktemp directory.
#
#   off: no filed PDF has a Finder tag or label; each has its catalogue companion, which holds the read state.
#   on:  (ARCHIVEPROC_TEST_MIRROR_FINDER_TAGS=1, a Debug-only switch) every filed PDF carries Unread as today.
# Prints ALL PASS on success.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
BIN="$REPO/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$BIN" ] || { echo "ArchiveProcessor is not built (macOS/build/DD)" >&2; exit 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ap-finder-mirror.XXXXXX")
echo "scratch: $WORK"
source "$REPO/scripts/test-child.sh"
processor_test_init "$WORK"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
fail=0

make_photos() {   # dir
    mkdir -p "$1"
    local i
    for i in 1 2 3; do
        magick -size 600x400 xc:white -fill black -draw "rectangle 40,40 $((100 + i * 60)),$((80 + i * 30))" "$1/p$i.jpg"
        python3 - "$1/p$i.jpg" <<'EOF'
import plistlib, subprocess, sys
data = plistlib.dumps(["Source Tag A"], fmt=plistlib.FMT_BINARY)
subprocess.run(['xattr', '-wx', 'com.apple.metadata:_kMDItemUserTags', data.hex(), sys.argv[1]], check=True)
EOF
    done
}

run_case() {   # name outdir env...
    local name="$1" out="$2"; shift 2
    mkdir -p "$out"
    python3 "$REPO/scripts/fake_gateway.py" "$PORT" "$out/gateway.log" 500 stand-in-key &
    local gw=$!
    sleep 1
    local kv vars=(ARCHIVEPROC_HEADLESS=1 "ARCHIVEPROC_TEST_BACKUP_ROOT=$WORK/backup"
        PROCESSFILES_TESTMODE=1 PROCESSFILES_TESTKEY=stand-in-key
        "PROCESSFILES_GATEWAY_URL=http://127.0.0.1:$PORT/v1" PROCESSFILES_GATEWAY_MODEL=stand-in
        PROCESSFILES_METER=1 PROCESSFILES_CAP_USD=100 PROCESSFILES_TAGGING=automatic
        "PROCESSFILES_TESTIN=$WORK/in" "PROCESSFILES_TESTOUT=$out" "PROCESSFILES_TESTDONE=$out/DONE.txt"
        PROCESSFILES_MAXIMAGES=3 PROCESSFILES_EXPORTORIGINALS=1 "$@")
    for kv in "${vars[@]}"; do export "$kv"; done
    processor_test_start pid "$BIN" >"$out/app.log" 2>&1
    for kv in "${vars[@]}"; do unset "${kv%%=*}"; done
    local i
    for i in $(seq 1 120); do [ -f "$out/DONE.txt" ] && break; sleep 1; done
    processor_test_stop "$pid"
    kill "$gw" 2>/dev/null; wait "$gw" 2>/dev/null
    rm -f "$HOME/Library/Application Support/ArchiveProcessor/pending_run.json"
    echo "── $name   driver: $(cat "$out/DONE.txt" 2>/dev/null || echo '(timed out)')"
}

# Every filed PDF (one with a catalogue companion beside it), its Finder tags, label and the companion's read state.
check() {   # root expect(off|on)
    python3 - "$1" "$2" <<'EOF'
import json, os, sys
sys.path.insert(0, os.path.join(os.getcwd(), 'scripts'))
from finder_tags import read_tags
root, expect = sys.argv[1], sys.argv[2]
filed, images, bad = 0, 0, []
for d, _, fs in sorted(os.walk(root)):
    if any(part.startswith('.') for part in os.path.relpath(d, root).split(os.sep) if part != '.'):
        continue   # the run's hidden working copies are tagged before filing
    for f in sorted(fs):
        if f.lower().endswith(('.jpg', '.jpeg')) and not f.startswith('.'):
            images += 1
            names, label, _ = read_tags(os.path.join(d, f))
            print(f'  image {os.path.relpath(os.path.join(d, f), root)}\ttags={names}\tlabel={label}')
            if expect == 'off' and (names or label):
                bad.append(f'{f}: an exported image carries Finder tags or a label with mirroring off')
            if expect == 'on' and 'Unread' not in (names or []):
                bad.append(f'{f}: an exported image has no Unread tag with mirroring on')
        if not f.lower().endswith('.pdf'):
            continue
        p = os.path.join(d, f)
        companion = p + '.archivesuite.json'
        if not os.path.exists(companion):
            continue
        filed += 1
        names, label, status = read_tags(p)
        state = json.load(open(companion)).get('fileFields', {}).get('readState')
        print(f'  pdf  {os.path.relpath(p, root)}\ttags={names}\tlabel={label}\treadState={state}')
        if 'unread' not in json.dumps(state).lower():
            bad.append(f'{f}: the companion does not hold Unread ({state})')
        if expect == 'off' and (names or label):
            bad.append(f'{f}: carries Finder tags or a label with mirroring off')
        if expect == 'on' and 'Unread' not in (names or []):
            bad.append(f'{f}: no Unread tag with mirroring on')
if filed == 0:
    bad.append('no filed PDF with a companion')
if images == 0:
    bad.append('no exported image')
for b in bad:
    print('  FAIL ' + b)
print('PASS' if not bad else 'FAIL', expect, filed, 'filed PDFs', images, 'exported images')
EOF
}

make_photos "$WORK/in"
run_case off "$WORK/off"
check "$WORK/off" off | tee "$WORK/off.txt"; grep -q '^PASS' "$WORK/off.txt" || fail=1
run_case on "$WORK/on" ARCHIVEPROC_TEST_MIRROR_FINDER_TAGS=1
check "$WORK/on" on | tee "$WORK/on.txt"; grep -q '^PASS' "$WORK/on.txt" || fail=1
python3 - "$WORK/in" <<'EOF' || fail=1
import os, sys
sys.path.insert(0, os.path.join(os.getcwd(), 'scripts'))
from finder_tags import read_tags
for f in sorted(os.listdir(sys.argv[1])):
    names, _, _ = read_tags(os.path.join(sys.argv[1], f))
    if names != ['Source Tag A']:
        print(f'  FAIL source {f} lost its own tag: {names}'); sys.exit(1)
print('PASS the source photos keep their own tags')
EOF
[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "FAILED (see the output above)"; exit 1; }
