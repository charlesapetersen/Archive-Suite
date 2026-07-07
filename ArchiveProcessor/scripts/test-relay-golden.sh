#!/bin/bash
# test-relay-golden.sh — cross-platform format guard (A7/A8).
#
# Each platform's RelayObjectFormat MUST emit byte-identical canonical JSON to the committed golden
# (SPEC/relay-golden/, generated from the Mac writer). This checks iOS (swiftc standalone) and Android
# (plain-JVM JUnit). Catches any Swift<->Kotlin escaping / key-order / hex-case divergence. Key-free, $0.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"; GOLD="$REPO/SPEC/relay-golden"; fail=0
WORK=$(mktemp -d); mkdir -p "$WORK/out"

echo "=== iOS RelayObjectFormat vs golden (swiftc standalone) ==="
cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
let dir = CommandLine.arguments[1]
func w(_ n: String, _ d: Data) { try! d.write(to: URL(fileURLWithPath: dir).appendingPathComponent(n)) }
let t = "TESTTK", e = "EP1"
w("g1__7.json", RelayObjectFormat.encodeSidecar(token: t, epoch: e, group: "g1", seq: 7, type: "document", priority: "P8", year: "1968", month: "3", replaces: nil, device: "X"))
w("g1.segment.json", RelayObjectFormat.encodeSegment(token: t, epoch: e, group: "g1", priority: "P8", year: "1968", month: "3", seqs: "6,7"))
w("_session.complete.json", RelayObjectFormat.encodeSessionComplete(token: t, epoch: e))
w("nasty__0.json", RelayObjectFormat.encodeSidecar(token: t, epoch: e, group: "nasty", seq: 0, type: "document", priority: nil, year: nil, month: nil, replaces: nil, device: "X\u{2019}\u{1F600}\u{01}"))
SWIFT
if swiftc "$REPO/ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Net/RelayObjectFormat.swift" "$WORK/main.swift" -o "$WORK/emit" 2>"$WORK/swiftc.err"; then
  "$WORK/emit" "$WORK/out"
  for f in g1__7.json g1.segment.json _session.complete.json nasty__0.json; do
    if diff -q "$GOLD/$f" "$WORK/out/$f" >/dev/null 2>&1; then echo "  [PASS] iOS $f"; else echo "  [FAIL] iOS $f"; diff "$GOLD/$f" "$WORK/out/$f" | head -3; fail=1; fi
  done
else echo "  [FAIL] iOS swiftc:"; head -5 "$WORK/swiftc.err"; fail=1; fi

echo "=== Android RelayObjectFormat vs golden (plain-JVM JUnit) ==="
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
if ( cd "$REPO/ArchiveCapture" && ./gradlew -q testDebugUnitTest --tests 'com.archiveprocessor.capture.net.RelayObjectFormatTest' --rerun-tasks ) >"$WORK/agradle.log" 2>&1; then
  echo "  [PASS] Android RelayObjectFormatTest (4 fixtures: sidecar, nasty-unicode, segment, session)"
else echo "  [FAIL] Android RelayObjectFormatTest:"; tail -15 "$WORK/agradle.log"; fail=1; fi

echo ""; [ "$fail" = 0 ] && echo "RELAY GOLDEN: PASS ✅" || echo "RELAY GOLDEN: FAIL ❌"
exit "$fail"
