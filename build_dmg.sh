#!/usr/bin/env bash
# build_dmg.sh — builds "Archive Processor.app" and packages it as a drag-to-install DMG.
#
# Usage:
#   bash build_dmg.sh
#
# Requirements (installed automatically if missing):
#   pip install py2app
#
# Output:
#   dist/Archive_Processor.dmg

set -euo pipefail

APP_NAME="Archive Processor"
BUNDLE="dist/Archive Processor.app"
DMG_OUT="dist/Archive_Processor.dmg"
STAGING="dist/_dmg_staging"

# ── 1. Install py2app if needed ──────────────────────────────────────────────
if ! python3 -c "import py2app" 2>/dev/null; then
    echo "==> Installing py2app…"
    pip3 install --break-system-packages py2app
fi

# ── 2. Install app dependencies if needed ────────────────────────────────────
echo "==> Checking app dependencies…"
pip3 install --break-system-packages anthropic google-genai reportlab Pillow beautifulsoup4 tkinterdnd2 httpx

# ── 3. Clean previous build artifacts ────────────────────────────────────────
echo "==> Cleaning previous build…"
# codesign sets immutable flags on some bundle files; clear them before deleting
chflags -R nouchg build dist 2>/dev/null || true
rm -rf build dist

# ── 4. Build the .app bundle ─────────────────────────────────────────────────
echo "==> Building .app bundle (this may take a minute)…"
python3 setup.py py2app

if [ ! -d "$BUNDLE" ]; then
    echo "ERROR: Expected bundle not found at $BUNDLE" >&2
    exit 1
fi

# ── 5. Ad-hoc code sign with entitlements ───────────────────────────────────
# Hardened runtime + entitlements are required for macOS TCC to grant the app
# access to Desktop / Documents / Downloads when the user picks files.
# Without them macOS hides protected files entirely (ENOENT instead of EACCES).
echo "==> Ad-hoc signing .app bundle with entitlements…"
codesign --force --deep --sign - \
    --entitlements entitlements.plist \
    "$BUNDLE"

# ── 6. Stage DMG contents (app + Applications symlink) ───────────────────────
echo "==> Staging DMG contents…"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -r "$BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# ── 7. Create the compressed DMG ─────────────────────────────────────────────
echo "==> Creating DMG…"
rm -f "$DMG_OUT"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_OUT"

# ── 8. Clean up staging area ─────────────────────────────────────────────────
rm -rf "$STAGING"

echo ""
echo "✓ Done!  Distributable disk image:"
echo "  $(pwd)/$DMG_OUT"
echo ""
echo "To install: open the DMG and drag '${APP_NAME}.app' → Applications."
