#!/bin/bash
# launch.sh — Launch the Archive Processor macOS app.
#
# Always gets you the CURRENT build in front:
#   • builds first if the Debug build is missing or older than the sources;
#   • relaunches if a stale earlier instance is running (started before the current build);
#   • if the up-to-date build is already running, just brings it to the front.
#
# Usage: ./launch.sh   (run from anywhere; it cd's to its own directory = repo root)
set -uo pipefail
cd "$(dirname "$0")"

APPDIR="ArchiveProcessor"
APP="$APPDIR/build/DD/Build/Products/Debug/ArchiveProcessor.app"
EXE="$APP/Contents/MacOS/ArchiveProcessor"
BUILD_LOG="/tmp/ap-launch-build.log"

# Up to date = the built executable exists and is newer than every source input.
need_build=1
if [ -x "$EXE" ] && [ -z "$(find "$APPDIR/Sources" "$APPDIR/project.yml" -newer "$EXE" 2>/dev/null | head -1)" ]; then
  need_build=0
fi

if [ "$need_build" = 1 ]; then
  echo "→ Debug build is missing or out of date — building…"
  ( cd "$APPDIR" \
      && xcodegen generate >/dev/null 2>&1 \
      && xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/DD build ) \
    >"$BUILD_LOG" 2>&1
  if ! grep -q "BUILD SUCCEEDED" "$BUILD_LOG"; then
    echo "✗ BUILD FAILED — last lines of $BUILD_LOG:"
    tail -25 "$BUILD_LOG"
    exit 1
  fi
  echo "✓ Build succeeded."
else
  echo "✓ Build is up to date."
fi

# Relaunch if we just built, or if a running instance is stale (started before the current build's
# executable) — so "launch" always shows the current build, never an old process that predates a rebuild.
# Otherwise, if the current build is already running, just bring it to the front.
pid=$(pgrep -x ArchiveProcessor | head -1)
relaunch=$need_build
if [ "$relaunch" = 0 ] && [ -n "${pid:-}" ]; then
  exe_mtime=$(stat -f %m "$EXE" 2>/dev/null || echo 0)
  proc_start=$(date -j -f "%a %b %e %T %Y" "$(ps -o lstart= -p "$pid" 2>/dev/null)" +%s 2>/dev/null || echo 0)
  [ "$proc_start" -gt 0 ] && [ "$exe_mtime" -gt "$proc_start" ] && relaunch=1
fi

if [ -n "${pid:-}" ] && [ "$relaunch" = 0 ]; then
  osascript -e 'tell application "System Events" to set frontmost of (first process whose name is "ArchiveProcessor") to true' 2>/dev/null
  echo "✓ Already running the current build — brought to the front."
else
  [ -n "${pid:-}" ] && { pkill -x ArchiveProcessor 2>/dev/null; sleep 0.6; }
  open "$APP"
  echo "✓ Launched: $APP"
fi
