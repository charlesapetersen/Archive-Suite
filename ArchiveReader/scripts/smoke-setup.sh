#!/usr/bin/env bash
# smoke-setup.sh — (re)create a SCRATCH corpus of tagged-PDF COPIES for the interactive GUI smoke
# test, so tests never write to the real "Test files/" corpus. Copies preserve Finder tags (ditto),
# and we force Spotlight to index them (the app discovers via NSMetadataQuery). Idempotent.
#
# Usage: ./scripts/smoke-setup.sh [N]      (default N=30 files)
set -euo pipefail
SRC="$HOME/Desktop/Claude/Archive Reader/Test files/Brown Gemini"
# Off the Desktop (owner request): a less-visible, Spotlight-indexed location under Application Support.
DST="$HOME/Library/Application Support/ArchiveReader/AR-Smoke"
N="${1:-30}"

[ -d "$SRC" ] || { echo "source corpus not found: $SRC" >&2; exit 1; }
rm -rf "$DST"; mkdir -p "$DST"
count=0
while IFS= read -r f; do
  [ "$count" -ge "$N" ] && break
  ditto "$SRC/$f" "$DST/$f"          # ditto preserves the com.apple.metadata:_kMDItemUserTags xattr
  count=$((count + 1))
done < <(cd "$SRC" && ls *.pdf | sort)

mdimport "$DST" >/dev/null 2>&1       # force Spotlight indexing of the copies
# wait until Spotlight sees them (the app relies on it)
seen=0
for _ in $(seq 1 20); do
  seen=$(mdfind -onlyin "$DST" 'kMDItemUserTags == "Unread" || kMDItemUserTags == "Read"' 2>/dev/null | wc -l | tr -d ' ')
  [ "$seen" -ge "$count" ] && break
  sleep 2
done
echo "scratch corpus ready: $count copied, $seen indexed in $DST"
