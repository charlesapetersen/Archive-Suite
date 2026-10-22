#!/bin/bash
# test-ios-capture-queue.sh — host tests for the iOS companion's queue and session logic (W40.i-fix-ios-testable-core).
#
# The iOS app has no test target and no simulator runtime to host one, so its UI-free core
# (Capture/CaptureQueue.swift, with CaptureModels.swift and SessionStore.swift) is compiled standalone with
# swiftc against ArchiveCaptureiOS/HostTests/CaptureQueueTests.swift and run on the Mac, as
# test-relay-golden.sh does for the network layer. Anything that imports UIKit, AVFoundation or Photos must
# stay out of those three files, or this stops compiling. Key-free, offline, $0, a few seconds.
set -uo pipefail
. "$(dirname "$0")/../../ops/autonomous/heavy-enter.sh"
cd "$(dirname "$0")/.."
REPO="$PWD"; CAP="$REPO/ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Capture"; W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cp "$REPO/ArchiveCaptureiOS/HostTests/CaptureQueueTests.swift" "$W/main.swift"

echo "=== iOS CaptureQueue host tests (swiftc standalone) ==="
if ! swiftc "$CAP/CaptureQueue.swift" "$CAP/CaptureModels.swift" "$CAP/SessionStore.swift" "$W/main.swift" \
     -o "$W/run" 2>"$W/swiftc.err"; then
  echo "  [FAIL] swiftc:"; head -20 "$W/swiftc.err"; echo ""; echo "IOS CAPTURE QUEUE: FAIL ❌"; exit 1
fi
if "$W/run"; then echo ""; echo "IOS CAPTURE QUEUE: PASS ✅"; exit 0
else echo ""; echo "IOS CAPTURE QUEUE: FAIL ❌"; exit 1; fi
