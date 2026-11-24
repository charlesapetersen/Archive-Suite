#!/bin/bash
# Build one macOS app in Release configuration for local use.
set -euo pipefail

usage="Usage: ./build.sh processor|reader|notes"
if [ "$#" -ne 1 ]; then
  echo "$usage" >&2
  exit 2
fi

case "$1" in
  processor) scheme="ArchiveProcessor" ;;
  reader)    scheme="ArchiveReader" ;;
  notes)     scheme="ArchiveNotes" ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "$0")" && pwd)"
project="$root/$scheme/macOS"
app="$project/build/rel/Build/Products/Release/$scheme.app"
echo "Building $scheme (Release)…"
(
  cd "$project"
  xcodegen generate
  mkdir -p build
  if ! xcodebuild -scheme "$scheme" -configuration Release -derivedDataPath ./build/rel build \
    >build/release-build.log 2>&1; then
    tail -30 build/release-build.log >&2
    echo "Build log: $project/build/release-build.log" >&2
    exit 1
  fi
)
[ -d "$app" ] || { echo "Missing Release app: $app" >&2; exit 1; }

# Xcode can inject debug entitlements into the signature even when absent from the project file.
entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null | tr -d '[:space:]')" \
  || { echo "Cannot read entitlements for $app" >&2; exit 1; }
for key in com.apple.security.get-task-allow com.apple.security.cs.disable-library-validation; do
  if grep -qF "<key>$key</key><true/>" <<<"$entitlements"; then
    echo "$scheme carries the debug entitlement $key" >&2
    exit 1
  fi
done
echo "$app"
