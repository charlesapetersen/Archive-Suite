#!/usr/bin/env bash
# make-gui-fixture.sh — build a SCRATCH tagged-PDF fixture for XCUITests.
#
# Copies a curated handful of real PDFs from the test corpus, strips all inherited
# tags, then applies a deliberate VARIETY of Finder tags via the `tag` CLI so that
# XCUITests can assert against known tag state. Also generates one image-only (no
# text layer) PDF and one non-PDF image for format-degrade tests.
#
# The fixture lands at ~/Library/Application Support/ArchiveReader/AR-GUI-Fixture
# (Route B — outside the sandbox container, which the UITest runner cannot see past;
# FixtureUITestCase resolves the same path via getpwuid). The path is emitted on
# stdout so callers (XCUITest setUp) can pass it as -ARUITestRootPath.
#
# NO SPOTLIGHT (W26.scripts). Reader discovery is a filesystem walk (ArchiveCore
# `CorpusWalker`) — an indexed fixture is neither required nor sufficient — so this
# script neither force-indexes nor waits for an index. It verifies the tags it wrote
# by READING THEM BACK off disk, which is deterministic and works on a volume with
# indexing disabled (a `mktemp` dir, or the guest VM's cold index).
#
# Idempotent: rm -rf + rebuild on every run. NEVER touches the real corpus.
#
# Usage:  ./scripts/make-gui-fixture.sh
# Env:    AR_FIXTURE_SRC — source corpus dir (default: the repo's Test files/Brown Gemini)
#         AR_FIXTURE_DST — where to build (default: the Application Support path above).
#                          Overriding it is how the test harness builds a throwaway
#                          fixture on an unindexed volume without clobbering the real one.
# Deps:   /opt/homebrew/bin/tag, sips
set -euo pipefail

TAG=/opt/homebrew/bin/tag
SRC="${AR_FIXTURE_SRC:-$HOME/Claude/Archive Suite/Test files/Brown Gemini}"
DST="${AR_FIXTURE_DST:-$HOME/Library/Application Support/ArchiveReader/AR-GUI-Fixture}"

# --- preflight ---
[ -d "$SRC" ] || { echo "error: source corpus not found: $SRC" >&2; exit 1; }
command -v "$TAG" >/dev/null || { echo "error: tag CLI not found ($TAG); brew install tag" >&2; exit 1; }

# The next step is `rm -rf "$DST"`, and DST is now settable from the environment (AR_FIXTURE_DST),
# so sanity-check it before deleting anything: absolute, at least two components deep, not $HOME,
# and not inside the source corpus. Prime Directive #1 — a fixture builder must never be one typo
# away from erasing something that matters.
# Strip trailing slashes FIRST: "$HOME/" is the same directory as "$HOME" but compares unequal, so
# without this the one path the guard most needs to refuse walks straight through it. "/" collapses
# to the empty string and is then refused by the depth check.
while [ "${DST%/}" != "$DST" ]; do DST="${DST%/}"; done
case "$DST" in
  /*/*) : ;;
  *) echo "error: AR_FIXTURE_DST must be an absolute path at least two components deep: $DST" >&2; exit 1 ;;
esac
[ "$DST" != "$HOME" ] || { echo "error: refusing to rebuild the fixture at \$HOME" >&2; exit 1; }
case "$DST" in
  "$SRC"|"$SRC"/*) echo "error: refusing to write the fixture inside the source corpus: $DST" >&2; exit 1 ;;
esac

# --- idempotent rebuild ---
rm -rf "$DST"
mkdir -p "$DST"

# --- copy a curated set of real PDFs (ditto preserves xattrs, but we strip below) ---
# The canonical fixture names the tag assignments + UITests expect. We copy the
# first 10 real PDFs the corpus provides into THESE names (see loop below), so the
# fixture is stable even when the corpus is slimmed to a strided sample.
FILES=(
  "00001 IMG — Brown.pdf"   # will be: year + month + subject + P9 + Read
  "00002 IMG — Brown.pdf"   # will be: year + subject + P8 + Unread
  "00003 IMG — Brown.pdf"   # will be: 3-digit year + subject + P7 + Read
  "00004 IMG — Brown.pdf"   # will be: decade (1970s) + subject + P10 + Unread
  "00005 IMG — Brown.pdf"   # will be: year + month + day + subjects + Read
  "00006 IMG — Brown.pdf"   # will be: year + facet-colliding subject "1984" + Unread
  "00007 IMG — Brown.pdf"   # will be: Box marker (Red) + Read
  "00008 IMG — Brown.pdf"   # will be: Folder marker (Purple) + Read
  "00009 IMG — Brown.pdf"   # will be: year + subject + NO read-state (tri-state neither)
  "00010 IMG — Brown.pdf"   # will be: year + subject + P8 + Unread (sort tie-breaker test)
)
# Don't require specific source names: the corpus may be SLIMMED to a strided
# sample (commit c07c98c removed the old consecutive 00002–00010). Take the first
# 10 real PDFs the corpus provides and rename them into the canonical fixture
# names above — the tag assignments below (and the UITests) key off the canonical
# names + applied tags, not the source identity, so the fixture stays stable.
SRCFILES=()   # portable (bash 3.2 has no `mapfile`)
while IFS= read -r pdf; do SRCFILES+=("$pdf"); done < <(ls "$SRC"/*.pdf 2>/dev/null | head -10)
[ "${#SRCFILES[@]}" -eq 10 ] || { echo "error: need >=10 source PDFs in $SRC, found ${#SRCFILES[@]}" >&2; exit 1; }
i=0
for name in "${FILES[@]}"; do
  ditto "${SRCFILES[$i]}" "$DST/$name"
  i=$((i+1))
done

# --- generate a single-page image-only PDF (no text layer) ---
# A minimal valid PDF: one page with a gray filled rectangle, no text objects at all.
# PDFKit will open it successfully; PDFFormatStatus will classify it as noTextLayer.
NOTEXT="$DST/IMG_NOTEXT — Fixture.pdf"
cat > "$NOTEXT" <<'RAWPDF'
%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Contents 4 0 R>>endobj
4 0 obj<</Length 44>>
stream
0.86 0.86 0.86 rg
50 100 500 600 re f
endstream
endobj
xref
0 5
0000000000 65535 f
0000000009 00000 n
0000000058 00000 n
0000000115 00000 n
0000000206 00000 n
trailer<</Size 5/Root 1 0 R>>
startxref
300
%%EOF
RAWPDF

# --- generate a non-PDF image (tagged JPEG for W5.d4 degrade test) ---
# Create a small solid-color PNG via raw bytes, then convert to JPEG via sips.
TMPPNG="$DST/_tmp_fixture.png"
# 2x2 blue PNG (minimal valid PNG)
printf '\x89PNG\r\n\x1a\n' > "$TMPPNG"
python3 -c "
import struct, zlib
width, height = 2, 2
raw = b''
for _ in range(height):
    raw += b'\x00' + b'\xb4\xa0\x8c' * width  # filter=None + RGB pixels
ihdr = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
def chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)
import sys
sys.stdout.buffer.write(b'\x89PNG\r\n\x1a\n')
sys.stdout.buffer.write(chunk(b'IHDR', ihdr))
sys.stdout.buffer.write(chunk(b'IDAT', zlib.compress(raw)))
sys.stdout.buffer.write(chunk(b'IEND', b''))
" > "$TMPPNG"
sips -s format jpeg "$TMPPNG" --out "$DST/IMG_PHOTO — Fixture.jpg" >/dev/null 2>&1
rm -f "$TMPPNG"

# --- strip ALL inherited Finder tags from every file ---
for f in "$DST"/*; do
  existing=$("$TAG" -lN "$f" 2>/dev/null || true)
  if [ -n "$existing" ]; then
    "$TAG" -r "$existing" "$f"
  fi
done

# --- apply the deliberate tag variety ---
# Helper: set tags on a file (strips first, then sets).
set_tags() {
  local file="$DST/$1"; shift
  # $@ = comma-separated tag list
  "$TAG" -s "$*" "$file"
}

# File 1: year + month + subject + P9 + Read
set_tags "00001 IMG — Brown.pdf" "1980,03 March,Jerry Brown,P9,Read"

# File 2: year + subject + P8 + Unread
set_tags "00002 IMG — Brown.pdf" "1975,Economics,P8,Unread"

# File 3: 3-digit (medieval) year + subject + P7 + Read
set_tags "00003 IMG — Brown.pdf" "842,Medieval Records,P7,Read"

# File 4: decade token + subject + P10 + Unread
set_tags "00004 IMG — Brown.pdf" "1970s,DP chapters,P10,Unread"

# File 5: year + month + day + multiple subjects + Read
set_tags "00005 IMG — Brown.pdf" "1981,06 June,Day 15,Jerry Brown,Economics,Read"

# File 6: year + facet-colliding subject "1984" + Unread
set_tags "00006 IMG — Brown.pdf" "1983,1984,Orwell Reference,Unread"

# File 7: Box marker (Red color) + Read
set_tags "00007 IMG — Brown.pdf" "Box,Red,Read"

# File 8: Folder marker (Purple color) + Read
set_tags "00008 IMG — Brown.pdf" "Folder,Purple,Read"

# File 9: year + subject + NO read-state (tri-state "neither" bucket)
set_tags "00009 IMG — Brown.pdf" "1979,Budget Policy"

# File 10: year + subject + P8 + Unread (sort tie-breaker)
set_tags "00010 IMG — Brown.pdf" "1975,Education Policy,P8,Unread"

# No-text-layer PDF: year + Unread (format-status test)
set_tags "IMG_NOTEXT — Fixture.pdf" "1990,OCR Failed,Unread"

# Non-PDF image: Folder marker (Purple) + Read (viewer degrade test)
set_tags "IMG_PHOTO — Fixture.jpg" "Folder,Purple,Read"

# --- set color labels for Box (Red=6) and Folder (Purple=3) ---
# The `tag` CLI writes color-name tokens; macOS resolves Red→labelNumber 6,
# Purple→labelNumber 3 automatically when the color name is in the tag array.
# No extra step needed — verified in the Reader's Verified Facts.

# --- root marker (W23.m4): give the fixture root a portable GUID ---
# Without `.archive-suite-root.json` the Reader's root store reads no marker, so no durable link can be
# built and every archive-link command stays disabled — which made the page-link commands untestable in
# the GUI lane. Format per ArchiveCore `RootMarker`: lowercased UUID + ISO-8601 `createdAt`. The GUID is
# FIXED so a UITest can assert the link it copies. Scratch fixture only; never written to a real corpus.
cat > "$DST/.archive-suite-root.json" <<'JSON'
{"guid":"a4f1c2d8-0e3b-4a71-9c55-6d8e1f2a3b40","name":"AR-GUI-Fixture","kind":"reader","createdAt":"2026-07-30T00:00:00Z"}
JSON

# --- verify the tags are ON DISK (W26.scripts: no mdimport, no mdfind poll) ---
# `tag -s` writes com.apple.metadata:_kMDItemUserTags with setxattr(2) and returns only once the
# xattr is set, so there is nothing to wait for — read it straight back. The old code force-indexed
# with `mdimport` and then polled `mdfind` for up to 60 s, which (a) could not be satisfied at all on
# an unindexed volume (a mktemp dir, or a guest VM with a cold index — exactly where the GUI lane
# runs) and (b) only ever WARNED, so a genuinely untagged fixture shipped silently and its UITests
# failed later for a reason the log did not name.
#
# Exact-token comparison: "Read" is a SUBSTRING of "Unread", so grep/case would over-match. Split the
# comma-separated list `tag -lN` prints (it sorts, and no fixture tag contains a comma) and compare
# each token whole.
has_read_state() {
  local tags token rc=1
  tags=$("$TAG" -lN "$1" 2>/dev/null || true)
  local saved_ifs=$IFS
  IFS=,
  set -o noglob
  for token in $tags; do
    if [ "$token" = "Read" ] || [ "$token" = "Unread" ]; then rc=0; break; fi
  done
  IFS=$saved_ifs
  set +o noglob
  return $rc
}

# The fixture is 12 files, 11 of them carrying Read or Unread. File 9 deliberately has NEITHER — it
# IS the tri-state "neither" bucket a UITest asserts on — so 11/12 is the exact truth, not a floor,
# and file 9's *absence* of a read state is itself an invariant worth pinning (a future edit that
# "helpfully" tags it would silently retire that test).
EXPECTED_TOTAL=12
EXPECTED_TAGGED=11
NEITHER="00009 IMG — Brown.pdf"
total=0
tagged=0
problems=""
for f in "$DST"/*; do
  [ -f "$f" ] || continue
  total=$((total + 1))
  base=$(basename "$f")
  if has_read_state "$f"; then
    tagged=$((tagged + 1))
    if [ "$base" = "$NEITHER" ]; then
      problems="$problems
  has a read state but must have NEITHER: $base"
    fi
  elif [ "$base" != "$NEITHER" ]; then
    problems="$problems
  no Read/Unread on disk: $base"
  fi
done

if [ "$total" -ne "$EXPECTED_TOTAL" ] || [ "$tagged" -ne "$EXPECTED_TAGGED" ] || [ -n "$problems" ]; then
  echo "error: fixture is wrong — $total files (want $EXPECTED_TOTAL), $tagged carry Read/Unread on disk (want $EXPECTED_TAGGED) in $DST${problems}" >&2
  exit 1
fi
echo "GUI fixture ready: $total files ($tagged tagged Read/Unread, verified on disk) in $DST" >&2

# Emit the fixture path on stdout (for -ARUITestRootPath)
echo "$DST"
