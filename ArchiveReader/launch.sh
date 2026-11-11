#!/bin/bash
# launch.sh — Launch the Archive Reader macOS app. (Mirrors Archive Processor's launch.sh.)
#
# Always gets you the CURRENT build in front:
#   • builds first if the build is missing or older than the sources;
#   • relaunches if a stale earlier instance is running (started before the current build);
#   • if the up-to-date build is already running, just brings it to the front.
#
# Builds **Release** by default: optimized (-O), as the DMG ships, and signed with the production
# entitlements, so neither debug entitlement is in it. At corpus size the optimized build shows a tag change
# 1.5–4× sooner than Debug (W40.reader-scale-measure, verification/evidence/reader/W40.reader-scale-measure.md).
# `--debug` builds and runs the Debug build instead, for a developer who wants the debugger or the
# `#if DEBUG` test hooks; it has its own DerivedData, which the unit tests share.
#
# Usage: ./launch.sh [--debug]   (run from anywhere; it cd's to its own directory = repo root)
set -uo pipefail
cd "$(dirname "$0")"

CONFIG="Release"
DERIVED="./build/DD-Release"
case "${1:-}" in
  --debug) CONFIG="Debug"; DERIVED="./build/DD" ;;
  "") ;;
  *) echo "usage: $0 [--debug]" >&2; exit 2 ;;
esac

APPDIR="macOS"
APP="$APPDIR/${DERIVED#./}/Build/Products/$CONFIG/ArchiveReader.app"
EXE="$APP/Contents/MacOS/ArchiveReader"
BUILD_LOG="/tmp/ar-launch-build.log"

# Up to date = the built executable exists and is newer than every source input.
need_build=1
if [ -x "$EXE" ] && [ -z "$(find "$APPDIR/Sources" "$APPDIR/project.yml" -newer "$EXE" 2>/dev/null | head -1)" ]; then
  need_build=0
fi

if [ "$need_build" = 1 ]; then
  echo "→ $CONFIG build is missing or out of date — building…"
  ( cd "$APPDIR" \
      && xcodegen generate >/dev/null 2>&1 \
      && xcodebuild -scheme ArchiveReader -configuration "$CONFIG" -derivedDataPath "$DERIVED" build ) \
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

# Relaunch if we just built, if a running instance is stale (started before the current build's executable),
# or if the running instance is the other configuration's — so "launch" always shows the current build.
# Otherwise foreground the running one.
pid=$(pgrep -x ArchiveReader | head -1)
relaunch=$need_build
if [ "$relaunch" = 0 ] && [ -n "${pid:-}" ]; then
  exe_mtime=$(stat -f %m "$EXE" 2>/dev/null || echo 0)
  proc_start=$(date -j -f "%a %b %e %T %Y" "$(ps -o lstart= -p "$pid" 2>/dev/null)" +%s 2>/dev/null || echo 0)
  [ "$proc_start" -gt 0 ] && [ "$exe_mtime" -gt "$proc_start" ] && relaunch=1
  case "$(ps -o command= -p "$pid" 2>/dev/null)" in */Products/"$CONFIG"/*) ;; *) relaunch=1 ;; esac
fi

if [ -n "${pid:-}" ] && [ "$relaunch" = 0 ]; then
  osascript -e 'tell application "System Events" to set frontmost of (first process whose name is "ArchiveReader") to true' 2>/dev/null
  echo "✓ Already running the current build — brought to the front."
else
  [ -n "${pid:-}" ] && { pkill -x ArchiveReader 2>/dev/null; sleep 0.6; }
  open "$APP"
  echo "✓ Launched: $APP"
fi
