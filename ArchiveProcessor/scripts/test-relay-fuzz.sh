#!/bin/bash
# test-relay-fuzz.sh — W40.e6 parser robustness for the relay object format (SPEC/relay-object-format.md).
#
# Compiles scripts/relay-fuzz/main.swift standalone against the Mac copy and, with -D IOS, the iOS copy of
# RelayObjectFormat (as test-relay-golden.sh does), runs the seeded fuzz and round-trip properties on each,
# then checks both platforms emit byte-identical canonical JSON for the same 4000 seeded objects (the golden
# check covers four fixed ones). Seeded, so a failure reproduces. Key-free, $0, no app build.
set -uo pipefail
. "$(dirname "$0")/../../ops/autonomous/heavy-enter.sh"
cd "$(dirname "$0")/.."
REPO="$PWD"; WORK=$(mktemp -d); fail=0
trap 'rm -rf "$WORK"' EXIT
MAC="$REPO/macOS/Sources/ArchiveProcessor/Net/RelayObjectFormat.swift"
IOS="$REPO/ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Net/RelayObjectFormat.swift"

for plat in mac ios; do
  src="$MAC"; flags=(); [ "$plat" = ios ] && { src="$IOS"; flags=(-D IOS); }
  echo "=== $plat RelayObjectFormat: fuzz + round trips ==="
  if ! swiftc -O ${flags[@]+"${flags[@]}"} "$src" "$REPO/scripts/relay-fuzz/main.swift" -o "$WORK/fuzz-$plat" 2>"$WORK/swiftc-$plat.err"; then
    echo "  [FAIL] swiftc:"; head -5 "$WORK/swiftc-$plat.err"; fail=1; continue
  fi
  "$WORK/fuzz-$plat" props || fail=1
  "$WORK/fuzz-$plat" bytes > "$WORK/bytes-$plat.txt" || fail=1
done

echo "=== Mac vs iOS canonical bytes, 4000 seeded objects ==="
if [ -s "$WORK/bytes-mac.txt" ] && cmp -s "$WORK/bytes-mac.txt" "$WORK/bytes-ios.txt"; then
  echo "  [PASS] identical"
else
  echo "  [FAIL] the platforms disagree:"; diff "$WORK/bytes-mac.txt" "$WORK/bytes-ios.txt" | head -4; fail=1
fi

echo ""; [ "$fail" = 0 ] && echo "RELAY FUZZ: PASS ✅" || echo "RELAY FUZZ: FAIL ❌"
exit "$fail"
