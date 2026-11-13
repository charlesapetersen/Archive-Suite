#!/bin/bash
# bootstrap-pdfium.sh — puts the pinned static PDFium build the Processor links into ArchiveProcessor/macOS/Vendor/pdfium
# (gitignored), for the byte-preserving Improve OCR writer (W44.reocr-processor; owner, 2026-11-12: "Link a pinned
# static PDFium ... fetched once by a bootstrap script that checks a pinned SHA-256 into a gitignored vendor folder").
#
# WHY STATIC: a dynamic libpdfium cannot load in the Processor. Its hardened runtime is signed with the self-signed
# "Archive Suite Dev" certificate, which has no Team ID, so library validation rejects any separate dylib (the same
# reason as ENABLE_DEBUG_DYLIB: NO in project.yml), and Release may not carry disable-library-validation.
#
# Source, in order: $PDFIUM_ZIP; the machine's cached copy (~/Library/Caches/ArchiveSuiteRehearsal/vendor/...); with
# --download only, the release URL into that cache. Both the zip and the extracted libpdfium.a are checked against
# pinned SHA-256s, so a substituted file never reaches the link. Idempotent: an installed copy whose stamp and library
# hash match is left alone, which is what the Xcode pre-build phase relies on (it runs this with no arguments and
# never downloads).
#
# Usage: bootstrap-pdfium.sh [--download]     exit 0 installed or already current, 1 missing/mismatch
set -euo pipefail

VERSION="8046d"
URL="https://github.com/paulocoutinhox/pdfium-lib/releases/download/$VERSION/macos.zip"
ZIP_SHA="1f718f8aeee279c8021de5d61ea9a604613fbfa2d83d79172d9086d711778554"
LIB_SHA="d77bab92473a7572eab592e14bbf156c3c68c939a07d8fe79c60bf7a0ba295c9"
# Every header, hashed in name order (inc_sha below), so an edited or missing header is caught as well as the library.
INC_SHA="c3a723a1db24d4d066a53fb51c91053d563bc75766ee612ad955d5a45c726ed4"
CACHE="$HOME/Library/Caches/ArchiveSuiteRehearsal/vendor/pdfium-lib-$VERSION/macos.zip"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="$here/../macOS/Vendor/pdfium"
stamp="$dest/STAMP"
want_stamp="pdfium-lib $VERSION zip $ZIP_SHA lib $LIB_SHA include $INC_SHA"

sha() { shasum -a 256 "$1" | awk '{print $1}'; }
inc_sha() { (cd "$1" && find include -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | awk '{print $1}'); }
die() { echo "bootstrap-pdfium: $*" >&2; exit 1; }
current() {
    [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want_stamp" ] && [ -f "$dest/lib/libpdfium.a" ] \
        && [ "$(sha "$dest/lib/libpdfium.a")" = "$LIB_SHA" ] && [ -d "$dest/include" ] && [ "$(inc_sha "$dest")" = "$INC_SHA" ]
}

current && exit 0

# One install at a time per checkout (a host bootstrap beside a build, two schemes building at once): the loser waits,
# then finds the winner's copy current. A lock left by a killed run is taken over after two minutes.
lock="$dest.lock"
mkdir -p "$(dirname "$dest")"
for _ in $(seq 1 120); do
    mkdir "$lock" 2>/dev/null && break
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null || true; continue; fi
    sleep 1
done
[ -d "$lock" ] || die "could not take the install lock $lock"
work="$(mktemp -d)"
new=""
trap 'rm -rf "$work"; [ -z "$new" ] || rm -rf "$new"; rmdir "$lock" 2>/dev/null || true' EXIT
current && exit 0

zip="${PDFIUM_ZIP:-$CACHE}"
if [ ! -f "$zip" ]; then
    [ "${1:-}" = "--download" ] || die "no PDFium $VERSION zip at $zip. Run $here/bootstrap-pdfium.sh --download (fetches $URL), or set PDFIUM_ZIP."
    mkdir -p "$(dirname "$CACHE")"
    part="$CACHE.part.$$"
    curl -fsSL --proto '=https' -o "$part" "$URL" || { rm -f "$part"; die "download failed: $URL"; }
    [ "$(sha "$part")" = "$ZIP_SHA" ] || { rm -f "$part"; die "the download does not match the pinned SHA-256 $ZIP_SHA; refusing it."; }
    mv "$part" "$CACHE"
    zip="$CACHE"
fi
[ "$(sha "$zip")" = "$ZIP_SHA" ] || die "$zip does not match the pinned SHA-256 $ZIP_SHA; refusing it."

unzip -q "$zip" 'release/include/*' 'release/lib/libpdfium.a' -d "$work"
[ "$(sha "$work/release/lib/libpdfium.a")" = "$LIB_SHA" ] || die "the zip's libpdfium.a does not match the pinned SHA-256 $LIB_SHA."
[ "$(inc_sha "$work/release")" = "$INC_SHA" ] || die "the zip's headers do not match the pinned SHA-256 $INC_SHA."

# Build the new copy beside the old one, then swap, so an interrupted run never leaves a half-installed library.
new="$dest.new.$$"
mkdir "$new"
mv "$work/release/include" "$new/include"
mkdir "$new/lib"
mv "$work/release/lib/libpdfium.a" "$new/lib/libpdfium.a"
printf '%s\n' "$want_stamp" > "$new/STAMP"
if [ -e "$dest" ]; then mv "$dest" "$work/old"; fi
mv "$new" "$dest"
new=""
echo "bootstrap-pdfium: installed pdfium-lib $VERSION into $dest"
