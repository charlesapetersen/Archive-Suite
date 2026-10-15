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
# tag xattr back and compares it with the share's. Only when that passes does it write the root marker the
# tests require, so a bad copy leaves a root no tag-writing test will accept.
#
# The next ordinary VM run rebuilds the synthetic fixture (ensure_fixture rebuilds every run), so this root
# never outlives the journey run that asked for it.
#
# Env: AR_JOURNEY_SRC     — the sample's "Archival Photos" tree (default: on the rehearsal share)
#      AR_JOURNEY_FOLDERS — newline-separated folders under it, relative, no ".." (default: the W40.d8 pick)
#      AR_FIXTURE_DST     — where to build; must end in /AR-GUI-Fixture (default: the generated fixture path)
set -euo pipefail

SRC="${AR_JOURNEY_SRC:-/Volumes/My Shared Files/rehearsal/reader-sample/Archival Photos}"
DST="${AR_FIXTURE_DST:-$HOME/Library/Application Support/ArchiveReader/AR-GUI-Fixture}"
# Picked 2026-10-14 from the c2 sample: 65 + 11 PDFs, 45 with a colour label, 48 Unread and 27 Read. The
# second name is spelled as on disk: an em dash followed by a NO-BREAK SPACE (U+00A0), not a plain space.
DEFAULT_FOLDERS=$'Stanford University Archives/J.E. Wallace Sterling, President of Stanford University papers, SC0216\nStanford University Archives/SC0308 \xe2\x80\x94\xc2\xa0Clebsch papers'
FOLDERS="${AR_JOURNEY_FOLDERS:-$DEFAULT_FOLDERS}"

die() { echo "error: $*" >&2; exit 1; }
[ -d "$SRC" ] || die "the rehearsal sample is not on the share: $SRC (build it: ArchiveReader/scripts/rehearsal-sample.py make)"

# Guard the rm -rf below. The destination must be a fixture root by name, absolute, at least three
# components deep, not $HOME, not the source or inside it, not a parent of it, and not under the corpus.
while [ "${DST%/}" != "$DST" ]; do DST="${DST%/}"; done
case "$DST" in /*/*/*/AR-GUI-Fixture) : ;; *) die "AR_FIXTURE_DST must be an absolute path ending in /AR-GUI-Fixture: $DST" ;; esac
case "$DST" in *//*|*/./*|*/../*) die "AR_FIXTURE_DST must be a plain path (no //, /./ or /../): $DST" ;; esac
[ "$DST" != "$HOME" ] || die "refusing to rebuild at \$HOME"
case "$SRC/" in "$DST"/*) die "refusing: the source is inside the destination: $SRC" ;; esac
case "$DST/" in "$SRC"/*) die "refusing to build inside the source: $DST" ;; esac
shopt -s nocasematch
case "$DST" in */Desktop/Google\ Drive*|*/Archival\ Photos*) die "refusing a path that looks like the real corpus: $DST" ;; esac
shopt -u nocasematch

# Every folder must be relative and free of ".." so neither its source nor its copy leaves its tree.
while IFS= read -r folder; do
  [ -n "$folder" ] || continue
  case "$folder" in /*) die "folder must be relative: $folder" ;; esac
  case "/$folder/" in */../*|*/./*) die "folder may not contain . or .. components: $folder" ;; esac
  [ -d "$SRC/$folder" ] || die "folder not in the sample: $folder"
done <<< "$FOLDERS"

rm -rf "$DST"
mkdir -p "$DST/Archival Photos"

n=0
while IFS= read -r folder; do
  [ -n "$folder" ] || continue
  mkdir -p "$DST/Archival Photos/$(dirname "$folder")"
  ditto "$SRC/$folder" "$DST/Archival Photos/$folder"
  n=$((n + 1))
done <<< "$FOLDERS"

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
[ "$bad" = 0 ] || die "$bad file(s) lost or changed their tags in the copy; no root marker written"
[ "$files" -gt 0 ] || die "nothing was copied"

# Last, and only after the check: the marker the tag-writing UITests require (make-gui-fixture.sh writes the
# same bytes; it names this scratch root, nothing in the corpus), and the journey's own note of what this is.
printf 'W40.d8 journey root: %s folder(s) of the W40.c2 sample, copied from %s\n%s\n' "$n" "$SRC" "$FOLDERS" \
  > "$DST/.w40-journey-set.txt"
cat > "$DST/.archive-suite-root.json" <<'JSON'
{"guid":"a4f1c2d8-0e3b-4a71-9c55-6d8e1f2a3b40","name":"AR-GUI-Fixture","kind":"reader","createdAt":"2026-07-30T00:00:00Z"}
JSON
echo "journey root: $DST — $files files ($tagged with Finder tags) from $n folder(s); tag xattrs identical to the share"
echo "$DST"
