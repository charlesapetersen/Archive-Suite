#!/usr/bin/env bash
# build_dmg.sh — builds "OCR to PDF.app" and packages it as a drag-to-install DMG.
#
# Usage:
#   bash build_dmg.sh
#
# Requirements (installed automatically if missing):
#   pip install py2app
#
# Output:
#   dist/OCR_to_PDF.dmg

set -euo pipefail

APP_NAME="OCR to PDF"
BUNDLE="dist/OCR to PDF.app"
DMG_OUT="dist/OCR_to_PDF.dmg"
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
rm -rf build dist

# ── 4. Build the .app bundle ─────────────────────────────────────────────────
echo "==> Building .app bundle (this may take a minute)…"
python3 setup.py py2app

if [ ! -d "$BUNDLE" ]; then
    echo "ERROR: Expected bundle not found at $BUNDLE" >&2
    exit 1
fi

# ── 5. Patch tkdnd for Tcl 9.0+ ────────────────────────────────────────────
# The pip-installed tkinterdnd2 ships tkdnd binaries compiled for Tcl 8.x.
# We replace them with a locally-built Tcl 9-compatible copy.
echo "==> Patching tkdnd for Tcl 9.0 compatibility…"
TKDND9_DIR="/tmp/tkdnd"
if [ -d "$TKDND9_DIR/build" ] && [ -f "$TKDND9_DIR/build/libtkdnd2.9.5.dylib" ]; then
    # Find the osx-arm64 tkdnd directory inside the bundle
    BUNDLE_TKDND=$(find "$BUNDLE" -type d -name "osx-arm64" -path "*/tkdnd/*" | head -1)
    if [ -n "$BUNDLE_TKDND" ]; then
        # Remove old dylib
        rm -f "$BUNDLE_TKDND"/libtkdnd*.dylib
        # Copy Tcl 9 dylib and updated Tcl scripts
        cp "$TKDND9_DIR/build/libtkdnd2.9.5.dylib" "$BUNDLE_TKDND/"
        cp "$TKDND9_DIR/library/"*.tcl "$BUNDLE_TKDND/"
        cp "$TKDND9_DIR/build/library/pkgIndex.tcl" "$BUNDLE_TKDND/"
        echo "  Patched: $BUNDLE_TKDND"
    else
        echo "WARNING: Could not find osx-arm64 tkdnd directory in bundle" >&2
    fi
else
    echo "WARNING: Tcl 9 tkdnd build not found at $TKDND9_DIR/build/" >&2
    echo "  Run: cd /tmp && git clone https://github.com/petasis/tkdnd.git && cd tkdnd && mkdir build && cd build && cmake .. && make" >&2
fi

# ── 6. Ad-hoc code sign ─────────────────────────────────────────────────────
# Without signing, macOS silently denies file access (TCC) instead of
# prompting the user.  Ad-hoc signing is free — no Apple Developer account.
echo "==> Ad-hoc signing .app bundle…"
codesign --force --deep --sign - "$BUNDLE"

# ── 7. Stage DMG contents (app + Applications symlink) ───────────────────────
echo "==> Staging DMG contents…"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -r "$BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# ── 8. Create the compressed DMG ─────────────────────────────────────────────
echo "==> Creating DMG…"
rm -f "$DMG_OUT"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_OUT"

# ── 9. Clean up staging area ─────────────────────────────────────────────────
rm -rf "$STAGING"

echo ""
echo "✓ Done!  Distributable disk image:"
echo "  $(pwd)/$DMG_OUT"
echo ""
echo "To install: open the DMG and drag '${APP_NAME}.app' → Applications."
