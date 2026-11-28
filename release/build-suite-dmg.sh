#!/bin/bash
# build-suite-dmg.sh — build all three Archive Suite apps (Release), stamp consistent versions + git SHA,
# verify signatures and entitlements, and package them into ONE combined DMG.
#
# Usage:  release/build-suite-dmg.sh <version> [--no-build]
#   <version>    e.g. 1.0.0  → produces /tmp/ArchiveSuite-1.0.0.dmg, volume "Archive Suite 1.0.0"
#   --no-build   reuse the existing Release .app bundles instead of rebuilding (faster for re-packaging)
#
# Optional environment variables:
#   BUILD_NUMBER     CFBundleVersion integer/string (default: git rev-list --count HEAD)
#   SIGN_IDENTITY    Override CODE_SIGN_IDENTITY (e.g. "Developer ID Application: Name (TEAMID)")
#   TEAM_ID          Optional DEVELOPMENT_TEAM when signing with a Developer ID certificate
#   NOTARY_PROFILE   Keychain profile for `xcrun notarytool submit --wait` + `xcrun stapler staple`
#                    (requires a Developer ID Application SIGN_IDENTITY)
#
# The DMG is a build artifact — never commit it. Without SIGN_IDENTITY/NOTARY_PROFILE, builds use
# the local self-signed certificate and are not notarized: on macOS 15+ Sequoia and later, users
# approve first launch via System Settings ▸ Privacy & Security ▸ Open Anyway.
set -uo pipefail

VER="${1:-}"
[ -z "$VER" ] && { echo "Usage: release/build-suite-dmg.sh <version> [--no-build]"; exit 2; }
NO_BUILD=0; [ "${2:-}" = "--no-build" ] && NO_BUILD=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"        # repo root
REL="Release"
DMG="/tmp/ArchiveSuite-${VER}.dmg"
VOL="Archive Suite ${VER}"
GIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
TEAM_ID="${TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

IS_DEV_ID=0
case "$SIGN_IDENTITY" in
  "Developer ID Application"*) IS_DEV_ID=1 ;;
esac
if [ -n "$NOTARY_PROFILE" ] && [ "$IS_DEV_ID" != 1 ]; then
  echo "✗ NOTARY_PROFILE requires SIGN_IDENTITY starting with 'Developer ID Application'" >&2
  exit 2
fi

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
  echo "  → building $scheme ($REL, v$VER build $BUILD_NUMBER, $GIT_SHA)…"
  local xcargs=(
    -scheme "$scheme"
    -configuration "$REL"
    -derivedDataPath ./build/rel
    "MARKETING_VERSION=$VER"
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
    "ARCHIVE_GIT_SHA=$GIT_SHA"
  )
  if [ -n "$SIGN_IDENTITY" ]; then
    xcargs+=("CODE_SIGN_IDENTITY=$SIGN_IDENTITY")
    if [ "$IS_DEV_ID" = 1 ]; then
      xcargs+=("OTHER_CODE_SIGN_FLAGS=--timestamp")
    fi
  fi
  if [ -n "$TEAM_ID" ]; then
    xcargs+=("DEVELOPMENT_TEAM=$TEAM_ID")
  fi
  ( cd "$abs" \
      && xcodegen generate >/dev/null 2>&1 \
      && xcodebuild "${xcargs[@]}" build >"/tmp/suite-dmg-build-$scheme.log" 2>&1 )
  if ! grep -q "BUILD SUCCEEDED" "/tmp/suite-dmg-build-$scheme.log"; then
    echo "  ✗ BUILD FAILED ($scheme) — see /tmp/suite-dmg-build-$scheme.log"; tail -20 "/tmp/suite-dmg-build-$scheme.log"; return 1
  fi
  echo "  ✓ $appname built"
}

echo "▸ Archive Suite $VER (build $BUILD_NUMBER, sha $GIT_SHA) — building all apps"
for a in "${APPS[@]}"; do build_one "$a" || exit 1; done

# ---- stage ---------------------------------------------------------------
STAGE_PARENT="$(mktemp -d)"
STAGE="$STAGE_PARENT/Archive Suite"
mkdir -p "$STAGE/.background"
for a in "${APPS[@]}"; do
  IFS=: read -r projdir scheme appname <<<"$a"
  src="$ROOT/$projdir/build/rel/Build/Products/$REL/$appname"
  [ -d "$src" ] || { echo "✗ missing built app: $src"; exit 1; }
  # Verify code signature integrity (deep + strict).
  if ! codesign --verify --deep --strict "$src" >/dev/null 2>&1; then
    echo "✗ codesign --verify --deep --strict failed for $appname"
    codesign --verify --deep --strict --verbose=2 "$src" || true
    exit 1
  fi
  # A Release product must carry neither debug entitlement (root CLAUDE.md, Signing): Xcode injects
  # get-task-allow unless CODE_SIGN_INJECT_BASE_ENTITLEMENTS is NO (W40.release-no-debug-entitlements).
  ents="$(codesign -d --entitlements - --xml "$src" 2>/dev/null | tr -d '[:space:]')" \
    || { echo "✗ cannot read the entitlements of $appname"; exit 1; }
  for bad in com.apple.security.get-task-allow com.apple.security.cs.disable-library-validation; do
    if grep -qF "<key>$bad</key><true/>" <<<"$ents"; then
      echo "✗ $appname carries the debug entitlement $bad — refusing to package it"; exit 1
    fi
  done
  if [ "$NO_BUILD" != 1 ]; then
    plist="$src/Contents/Info.plist"
    got_ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
    got_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"
    got_sha="$(/usr/libexec/PlistBuddy -c 'Print :ArchiveGitSHA' "$plist" 2>/dev/null || true)"
    if [ "$got_ver" != "$VER" ] || [ "$got_build" != "$BUILD_NUMBER" ] || [ "$got_sha" != "$GIT_SHA" ]; then
      echo "✗ $appname version mismatch: got ($got_ver, $got_build, $got_sha), expected ($VER, $BUILD_NUMBER, $GIT_SHA)"
      exit 1
    fi
  fi
  echo "  ⤷ staging $appname (signed & verified)"
  cp -R "$src" "$STAGE/"
done
ln -s /Applications "$STAGE/Applications"
if [ -n "$NOTARY_PROFILE" ]; then
  swift "$ROOT/release/make-dmg-background.swift" --notarized "$STAGE/.background/dmg-background.png" >/dev/null \
    || cp "$ROOT/release/dmg-background.png" "$STAGE/.background/dmg-background.png"
else
  cp "$ROOT/release/dmg-background.png" "$STAGE/.background/dmg-background.png"
fi

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
rm -rf "$STAGE_PARENT"

# ---- optional Developer ID DMG signing & notarization --------------------
if [ "$IS_DEV_ID" = 1 ]; then
  echo "▸ Signing DMG with $SIGN_IDENTITY"
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG" || { echo "✗ DMG codesign failed"; exit 1; }
  codesign --verify --strict "$DMG" || { echo "✗ DMG codesign verify failed"; exit 1; }
  if [ -n "$NOTARY_PROFILE" ]; then
    echo "▸ Submitting DMG to Apple notary service (profile: $NOTARY_PROFILE)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait || { echo "✗ notarytool submit failed"; exit 1; }
    xcrun stapler staple "$DMG" || { echo "✗ stapler staple failed"; exit 1; }
    xcrun stapler validate "$DMG" || { echo "✗ stapler validate failed"; exit 1; }
    echo "  ✓ notarized and stapled"
  fi
fi

echo "✓ Built: $DMG"
hdiutil imageinfo "$DMG" >/dev/null 2>&1 && echo "  (image verified)"
ls -lh "$DMG" | awk '{print "  size:", $5}'
