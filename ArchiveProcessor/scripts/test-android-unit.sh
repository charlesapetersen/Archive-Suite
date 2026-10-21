#!/bin/bash
# test-android-unit.sh — the Android capture app's whole JVM test suite, screens included (W40.e8).
#
# Runs every test under app/src/test: the plain-JVM logic tests and the Robolectric screen tests
# (app/src/test/java/.../ui/), with each Roborazzi screenshot compared against its committed golden in
# app/src/test/screenshots/. No emulator, no device, no window, no network once Gradle's and Robolectric's
# caches are warm. Key-free, $0.
#
# A screen change that alters pixels on purpose re-records the goldens and commits them with the change:
#   (cd ArchiveCapture && ./gradlew :app:recordRoborazziDebug)
# then look at the new PNGs before committing them; the diff of a failed run lands in app/build/outputs/roborazzi/.
set -uo pipefail
. "$(dirname "$0")/../../ops/autonomous/heavy-enter.sh"
cd "$(dirname "$0")/.."
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
LOG=$(mktemp)
# --no-daemon: a Gradle daemon would outlive this command while holding the heavy lock (see android-ui-drive.sh).
if ( cd ArchiveCapture && ./gradlew --no-daemon -q :app:verifyRoborazziDebug --rerun-tasks ) >"$LOG" 2>&1; then
  n=$(cat ArchiveCapture/app/build/test-results/testDebugUnitTest/*.xml 2>/dev/null | grep -o '<testcase ' | wc -l | tr -d ' ')
  echo "ANDROID UNIT: PASS ✅ ($n tests, screenshots match their goldens)"
  exit 0
fi
tail -30 "$LOG"
grep -l '<failure' ArchiveCapture/app/build/test-results/testDebugUnitTest/*.xml 2>/dev/null | sed 's/^/  failing suite: /'
echo "ANDROID UNIT: FAIL ❌"
exit 1
