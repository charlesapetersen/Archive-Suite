#!/bin/bash
# test-ios-capture-rotation.sh — host tests for the angle the iPhone sets on each shot (W40.fix-ios-landscape-orientation).
#
# Camera/CaptureRotation.swift is Foundation only, so it compiles standalone with swiftc against
# ArchiveCaptureiOS/HostTests/CaptureRotationTests.swift and runs on the Mac (test-ios-capture-queue.sh is the
# pattern). The RotationCoordinator needs a device; the owner's phone checks that half. Offline, $0, a few seconds.
set -uo pipefail
. "$(dirname "$0")/../../ops/autonomous/heavy-enter.sh"
cd "$(dirname "$0")/.."
REPO="$PWD"; CAM="$REPO/ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Camera"; W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cp "$REPO/ArchiveCaptureiOS/HostTests/CaptureRotationTests.swift" "$W/main.swift"

echo "=== iOS capture rotation host tests (swiftc standalone) ==="
if ! swiftc "$CAM/CaptureRotation.swift" "$W/main.swift" -o "$W/run" 2>"$W/swiftc.err"; then
  echo "  [FAIL] swiftc:"; head -20 "$W/swiftc.err"; echo ""; echo "IOS CAPTURE ROTATION: FAIL ❌"; exit 1
fi
if grep -q 'warning:' "$W/swiftc.err"; then echo "  [WARN] swiftc warnings:"; grep 'warning:' "$W/swiftc.err" | head; fi
if "$W/run"; then echo ""; echo "IOS CAPTURE ROTATION: PASS ✅"; exit 0
else echo ""; echo "IOS CAPTURE ROTATION: FAIL ❌"; exit 1; fi
