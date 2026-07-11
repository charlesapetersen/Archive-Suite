#!/bin/bash
# build-suite-dmg.sh — build BOTH Archive Suite apps (Release) and package them into ONE combined DMG
# that guides the user to drag both apps into /Applications.
#
# Usage:  release/build-suite-dmg.sh <version> [--no-build]
#   <version>    e.g. 1.0.0  → produces /tmp/ArchiveSuite-1.0.0.dmg, volume "Archive Suite 1.0.0"
#   --no-build   reuse the existing Release .app bundles instead of rebuilding (faster for re-packaging)
#
# The DMG is a build artifact — never commit it. Both apps are ad-hoc signed, not notarized
# (first launch needs Control-click → Open; that note is baked into the background art).
set -uo pipefail

VER="${1:-}"
[ -z "$VER" ] && { echo "Usage: release/build-suite-dmg.sh <version> [--no-build]"; exit 2; }
NO_BUILD=0; [ "${2:-}" = "--no-build" ] && NO_BUILD=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"        # repo root
REL="Release"
DMG="/tmp/ArchiveSuite-${VER}.dmg"
VOL="Archive Suite ${VER}"

# app-key : project-dir : scheme : built-app-name
APPS=(
  "ArchiveProcessor/macOS:ArchiveProcessor:ArchiveProcessor.app"
  "ArchiveReader/macOS:ArchiveReader:ArchiveReader.app"
  "ArchiveNotes/macOS:ArchiveNotes:ArchiveNotes.app"
)

build_one() {  # $1 = "projDir:scheme:appName"
  local projdir scheme appname; IFS=: read -r projdir scheme appname <<<"$1"
  local abs="$ROOT/$projdir"
  if [ "$NO_BUILD" = 1 ] && [ -d "$abs/build/rel/Build/Products/$REL/$appname" ]; then
    echo "  ↺ reusing existing $appname"; return 0
  fi
  echo "  → building $scheme ($REL)…"
  ( cd "$abs" \
      && xcodegen generate >/dev/null 2>&1 \
      && xcodebuild -scheme "$scheme" -configuration "$REL" -derivedDataPath ./build/rel build \
         >"/tmp/suite-dmg-build-$scheme.log" 2>&1 )
  if ! grep -q "BUILD SUCCEEDED" "/tmp/suite-dmg-build-$scheme.log"; then
    echo "  ✗ BUILD FAILED ($scheme) — see /tmp/suite-dmg-build-$scheme.log"; tail -20 "/tmp/suite-dmg-build-$scheme.log"; return 1
  fi
  echo "  ✓ $appname built"
}

echo "▸ Archive Suite $VER — building all apps"
for a in "${APPS[@]}"; do build_one "$a" || exit 1; done

# ---- stage ---------------------------------------------------------------
STAGE="$(mktemp -d)/Archive Suite"
mkdir -p "$STAGE/.background"
for a in "${APPS[@]}"; do
  IFS=: read -r projdir scheme appname <<<"$a"
  src="$ROOT/$projdir/build/rel/Build/Products/$REL/$appname"
  [ -d "$src" ] || { echo "✗ missing built app: $src"; exit 1; }
  echo "  ⤷ staging $appname"
  cp -R "$src" "$STAGE/"
done
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/release/dmg-background.png" "$STAGE/.background/dmg-background.png"

# ---- create writable DMG, style it in Finder, then compress --------------
rm -f "$DMG" /tmp/ArchiveSuite-rw.dmg
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov /tmp/ArchiveSuite-rw.dmg >/dev/null || { echo "✗ hdiutil create failed"; exit 1; }

DEV="$(hdiutil attach -readwrite -noverify -noautoopen /tmp/ArchiveSuite-rw.dmg | egrep '^/dev/' | head -1 | awk '{print $1}')"
MNT="/Volumes/$VOL"
sleep 1

style_ok=1
osascript <<EOF 2>/dev/null || style_ok=0
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 960, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set background picture of opts to file ".background:dmg-background.png"
    set position of item "ArchiveProcessor.app" of container window to {150, 230}
    set position of item "ArchiveReader.app" of container window to {300, 230}
    set position of item "ArchiveNotes.app" of container window to {450, 230}
    set position of item "Applications" of container window to {640, 230}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
[ "$style_ok" = 1 ] && echo "  ✓ window styled" || echo "  ⚠ Finder styling skipped (headless?) — DMG is still functional (all apps + Applications)."

sync; sleep 1
hdiutil detach "$DEV" >/dev/null 2>&1 || hdiutil detach "$MNT" -force >/dev/null 2>&1
hdiutil convert /tmp/ArchiveSuite-rw.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null || { echo "✗ hdiutil convert failed"; exit 1; }
rm -f /tmp/ArchiveSuite-rw.dmg
rm -rf "$(dirname "$STAGE")"

echo "✓ Built: $DMG"
hdiutil imageinfo "$DMG" >/dev/null 2>&1 && echo "  (image verified)"
ls -lh "$DMG" | awk '{print "  size:", $5}'
