#!/bin/bash
# test-filerelay.sh — key-free, $0 offline test of the FileRelay relay contract.
#
# Launches the built Mac app with FILERELAY_TESTMODE=1 (the headless FileRelayTestDriver), which drives
# FileRelayReceiver.scanOnce() through the never-lose-a-photo invariants + the v2 amendments (A1–A11)
# against a temp relay dir — no OCR, no API key, no network. Waits for the driver's DONE.txt, then asserts
# results.json with relay_assert.py. Outputs under .maintenance/test-results/ (gitignored).
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
BIN="$REPO/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$BIN" ] || { echo "no built app at $BIN — run: (cd macOS && xcodegen generate && xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/DD build)"; exit 1; }

OUT="$REPO/.maintenance/test-results/filerelay-$(date +%Y%m%d-%H%M%S)"
ROOT="$OUT/relay"
mkdir -p "$OUT"
echo "=== FileRelay offline invariant test · $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "out: $OUT"

pkill -x ArchiveProcessor 2>/dev/null; sleep 1
FILERELAY_TESTMODE=1 \
FILERELAY_RELAYROOT="$ROOT" \
FILERELAY_TESTOUT="$OUT" \
FILERELAY_TESTDONE="$OUT/DONE.txt" \
  "$BIN" >"$OUT/app.log" 2>&1 &
pid=$!
# Up to ~180s: a freshly-built unsigned binary can take ~80s to clear XProtect on first launch before
# onAppear fires (the driver itself runs in <1s once started).
for i in $(seq 1 180); do [ -f "$OUT/DONE.txt" ] && break; sleep 1; done
kill "$pid" 2>/dev/null; pkill -x ArchiveProcessor 2>/dev/null; sleep 1

echo "driver: $(cat "$OUT/DONE.txt" 2>/dev/null || echo '(no marker — timed out; see app.log)')"
python3 "$REPO/scripts/relay_assert.py" "$OUT/results.json"
