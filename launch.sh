#!/bin/bash
# launch.sh — Launch the Archive Processor macOS app.
#
# Uses the current Debug build if it is up to date; otherwise builds it, then launches.
# Idempotent: if the up-to-date app is already running, it just brings it to the front.
# "Up to date" = the built executable exists and is newer than every source input
# (everything under ArchiveProcessor/Sources plus project.yml).
#
# Usage: ./launch.sh          (run from anywhere; it cd's to its own directory = repo root)
set -uo pipefail
cd "$(dirname "$0")"

APPDIR="ArchiveProcessor"
APP="$APPDIR/build/DD/Build/Products/Debug/ArchiveProcessor.app"
EXE="$APP/Contents/MacOS/ArchiveProcessor"
BUILD_LOG="/tmp/ap-launch-build.log"

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
  # A fresh binary exists — stop any stale running instance so the new build is what launches.
  pkill -x ArchiveProcessor 2>/dev/null && sleep 0.6
else
  echo "✓ Build is up to date."
fi

if pgrep -x ArchiveProcessor >/dev/null 2>&1; then
  osascript -e 'tell application "System Events" to set frontmost of (first process whose name is "ArchiveProcessor") to true' 2>/dev/null
  echo "✓ Already running the current build — brought to the front."
else
  open "$APP"
  echo "✓ Launched: $APP"
fi
