#!/bin/bash
# test-ios-usb-relay.sh — host tests for the iPhone's cable relay (W40.i-usb-app; execution-plans/iphone-usb.md §5).
#
# Net/USBRelay.swift is Network and CryptoKit only, so it compiles standalone with swiftc, with Net/MacEndpoint.swift
# and Net/MacClient.swift, against ArchiveCaptureiOS/HostTests/USBRelayTests.swift, and runs on the Mac
# (test-ios-capture-queue.sh is the pattern). A fake Mac answers the AC1 handshake over real 127.0.0.1 sockets on
# system-chosen ports, so it never collides with a running app or simulator. Key-free, offline, $0, ~15 s.
set -uo pipefail
. "$(dirname "$0")/../../ops/autonomous/heavy-enter.sh"
cd "$(dirname "$0")/.."
REPO="$PWD"; NET="$REPO/ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Net"; W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cp "$REPO/ArchiveCaptureiOS/HostTests/USBRelayTests.swift" "$W/main.swift"

echo "=== iOS cable relay host tests (swiftc standalone) ==="
if ! swiftc "$NET/USBRelay.swift" "$NET/MacEndpoint.swift" "$NET/MacClient.swift" "$W/main.swift" \
     -o "$W/run" 2>"$W/swiftc.err"; then
  echo "  [FAIL] swiftc:"; head -20 "$W/swiftc.err"; echo ""; echo "IOS USB RELAY: FAIL ❌"; exit 1
fi
if grep -q 'warning:' "$W/swiftc.err"; then echo "  [WARN] swiftc warnings:"; grep 'warning:' "$W/swiftc.err" | head; fi
if "$W/run"; then echo ""; echo "IOS USB RELAY: PASS ✅"; exit 0
else echo ""; echo "IOS USB RELAY: FAIL ❌"; exit 1; fi
