#!/usr/bin/env bash
# make-journey-fixture.sh — W40.d8: stage real-corpus SAMPLE folders as the Reader's scratch UI-test root.
#
# Runs INSIDE the Tart guest (ops/gui/vm-gui-runner.sh calls it when READER_JOURNEY=rehearsal). It copies a
# few folders of the W40.c2 sample (verification/rehearsal.md) from the read-only rehearsal share onto the
# guest disk, at the generated GUI-fixture path: the one path the XCUITest runner's sandbox may write, and the
# one `FixtureUITestCase.requireGeneratedScratchFixtureForTagWrites` accepts. The sample is itself a copy of
# the corpus (APFS clones on the host); this is a copy of that copy on another machine's disk, so nothing a
# journey writes can reach either.
#
# `ditto` keeps every xattr, the Finder tags and colour labels included. The script reads every copied file's
# tag xattr back and compares it with the share's, and fails if any differs or a folder is missing.
#
# The next ordinary VM run rebuilds the synthetic fixture (ensure_fixture rebuilds every run), so this root
# never outlives the journey run that asked for it.
#
# Env: AR_JOURNEY_SRC     — the sample's "Archival Photos" tree (default: on the rehearsal share)
#      AR_JOURNEY_FOLDERS — newline-separated folders under it (default: the two picked for W40.d8)
#      AR_FIXTURE_DST     — where to build (default: the generated GUI-fixture path)
set -euo pipefail

SRC="${AR_JOURNEY_SRC:-/Volumes/My Shared Files/rehearsal/reader-sample/Archival Photos}"
DST="${AR_FIXTURE_DST:-$HOME/Library/Application Support/ArchiveReader/AR-GUI-Fixture}"
# Picked 2026-10-14 from the c2 sample: 65 + 11 PDFs, 45 with a colour label, 48 Unread and 27 Read,
# folder names with an em dash and commas.
FOLDERS="${AR_JOURNEY_FOLDERS:-Stanford University Archives/J.E. Wallace Sterling, President of Stanford University papers, SC0216
Stanford University Archives/SC0308 — Clebsch papers}"

[ -d "$SRC" ] || { echo "error: the rehearsal sample is not on the share: $SRC (build it: ArchiveReader/scripts/rehearsal-sample.py make)" >&2; exit 1; }

# The same guard as make-gui-fixture.sh before its rm -rf: absolute, two components deep, not $HOME, not
# inside the source.
while [ "${DST%/}" != "$DST" ]; do DST="${DST%/}"; done
case "$DST" in /*/*) : ;; *) echo "error: AR_FIXTURE_DST must be absolute and two components deep: $DST" >&2; exit 1 ;; esac
[ "$DST" != "$HOME" ] || { echo "error: refusing to rebuild at \$HOME" >&2; exit 1; }
case "$DST" in "$SRC"|"$SRC"/*) echo "error: refusing to build inside the source: $DST" >&2; exit 1 ;; esac
case "$DST" in "$HOME/Desktop/Google Drive"*) echo "error: refusing a path under the real corpus: $DST" >&2; exit 1 ;; esac

rm -rf "$DST"
mkdir -p "$DST/Archival Photos"

n=0
while IFS= read -r folder; do
  [ -n "$folder" ] || continue
  [ -d "$SRC/$folder" ] || { echo "error: folder not in the sample: $folder" >&2; exit 1; }
  mkdir -p "$DST/Archival Photos/$(dirname "$folder")"
  ditto "$SRC/$folder" "$DST/Archival Photos/$folder"
  n=$((n + 1))
done <<< "$FOLDERS"

# The marker the tag-writing UITests require (make-gui-fixture.sh writes the same bytes). It names the
# scratch root, nothing in the corpus.
cat > "$DST/.archive-suite-root.json" <<'JSON'
{"guid":"a4f1c2d8-0e3b-4a71-9c55-6d8e1f2a3b40","name":"AR-GUI-Fixture","kind":"reader","createdAt":"2026-07-30T00:00:00Z"}
JSON
printf 'W40.d8 journey root: %s folder(s) of the W40.c2 sample, copied from %s\n%s\n' "$n" "$SRC" "$FOLDERS" \
  > "$DST/.w40-journey-set.txt"

# Read every copied file's tag xattr back and compare with the share.
files=0; tagged=0; bad=0
while IFS= read -r -d '' f; do
  rel="${f#"$DST/Archival Photos/"}"
  files=$((files + 1))
  a="$(xattr -px com.apple.metadata:_kMDItemUserTags "$SRC/$rel" 2>/dev/null || true)"
  b="$(xattr -px com.apple.metadata:_kMDItemUserTags "$f" 2>/dev/null || true)"
  [ -n "$a" ] && tagged=$((tagged + 1))
  [ "$a" = "$b" ] || { echo "error: tag xattr differs after the copy: $rel" >&2; bad=$((bad + 1)); }
done < <(find "$DST/Archival Photos" -type f -print0)
[ "$bad" = 0 ] || exit 1
[ "$files" -gt 0 ] || { echo "error: nothing was copied" >&2; exit 1; }
echo "journey root: $DST — $files files ($tagged with Finder tags) from $n folder(s); tag xattrs identical to the share"
echo "$DST"
