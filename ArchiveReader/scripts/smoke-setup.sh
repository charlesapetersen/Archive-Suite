#!/usr/bin/env bash
# smoke-setup.sh — (re)create a SCRATCH corpus of tagged-PDF COPIES for the interactive GUI smoke
# test, so tests never write to the real "Test files/" corpus. Copies preserve Finder tags (ditto).
# Idempotent.
#
# NO SPOTLIGHT (W26.scripts). The Reader discovers by walking the filesystem (ArchiveCore
# `CorpusWalker`), so there is nothing to force-index and nothing to wait for. What this script
# verifies instead is the claim that actually matters and that the old `mdfind` poll never checked:
# that `ditto` really carried com.apple.metadata:_kMDItemUserTags across, byte for byte.
#
# Usage: ./scripts/smoke-setup.sh [N]      (default N=30 files)
# Env:   AR_SMOKE_DST — where to build (default: the Application Support path below). Overriding it
#                       is how the test harness builds a throwaway corpus on an unindexed volume.
set -euo pipefail
SRC="$HOME/Claude/Archive Suite/Test files/Brown Gemini"
# Off the Desktop (owner request): a less-visible location under Application Support.
DST="${AR_SMOKE_DST:-$HOME/Library/Application Support/ArchiveReader/AR-Smoke}"
N="${1:-30}"
XATTR_TAGS=com.apple.metadata:_kMDItemUserTags

[ -d "$SRC" ] || { echo "source corpus not found: $SRC" >&2; exit 1; }

# `rm -rf "$DST"` follows, and DST is settable from the environment now (AR_SMOKE_DST), so check it
# first: absolute, at least two components deep, not $HOME, not inside the source corpus. Prime
# Directive #1 — the scratch-corpus builder must never be one typo away from erasing the real one.
# Strip trailing slashes FIRST: "$HOME/" is the same directory as "$HOME" but compares unequal, so
# without this the one path the guard most needs to refuse walks straight through it. "/" collapses
# to the empty string and is then refused by the depth check.
while [ "${DST%/}" != "$DST" ]; do DST="${DST%/}"; done
case "$DST" in
  /*/*) : ;;
  *) echo "error: AR_SMOKE_DST must be an absolute path at least two components deep: $DST" >&2; exit 1 ;;
esac
[ "$DST" != "$HOME" ] || { echo "error: refusing to rebuild the scratch corpus at \$HOME" >&2; exit 1; }
case "$DST" in
  "$SRC"|"$SRC"/*) echo "error: refusing to write the scratch corpus inside the source corpus: $DST" >&2; exit 1 ;;
esac

rm -rf "$DST"; mkdir -p "$DST"
count=0
while IFS= read -r f; do
  [ "$count" -ge "$N" ] && break
  ditto "$SRC/$f" "$DST/$f"          # ditto preserves the com.apple.metadata:_kMDItemUserTags xattr
  count=$((count + 1))
done < <(cd "$SRC" && ls *.pdf | sort)

[ "$count" -gt 0 ] || { echo "error: copied 0 files from $SRC" >&2; exit 1; }

# --- verify the tag xattr survived the copy (deterministic; no index, no wait) ---
# Read the RAW xattr on both sides rather than a parsed tag list: this is exactly the byte-for-byte
# preservation the ditto comment above claims, and `xattr` is in the base macOS install, so the
# smoke setup gains no new dependency. A file with no tags at all reads empty on both sides and
# still compares equal — the assertion is "same as the source", not "has tags".
copied=0
tagged=0
mismatched=""
# Bound by `count`, not `N`: if the corpus holds fewer than N PDFs, the extra names were never
# copied, and re-deriving the list from N would compare a tagged source against an absent
# destination and report a mismatch the copy loop never made.
while IFS= read -r f; do
  [ "$copied" -ge "$count" ] && break
  copied=$((copied + 1))
  src_tags=$(xattr -px "$XATTR_TAGS" "$SRC/$f" 2>/dev/null || true)
  dst_tags=$(xattr -px "$XATTR_TAGS" "$DST/$f" 2>/dev/null || true)
  if [ "$src_tags" != "$dst_tags" ]; then
    mismatched="$mismatched
  tags did not survive the copy: $f"
  fi
  if [ -n "$dst_tags" ]; then tagged=$((tagged + 1)); fi
done < <(cd "$SRC" && ls *.pdf | sort)

if [ -n "$mismatched" ]; then
  echo "error: scratch corpus is not a faithful copy in $DST${mismatched}" >&2
  exit 1
fi
echo "scratch corpus ready: $count copied, $tagged carry Finder tags (verified on disk) in $DST"
