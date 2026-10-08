#!/bin/bash
# archivecore-cache.sh — build ArchiveCore once per exact input, for the Processor's standalone swiftc harnesses.
#
# Usage: DIR="$(bash scripts/archivecore-cache.sh SUITE_ROOT [swiftc flags…])"
#   Prints a directory holding ArchiveCore.swiftmodule and libArchiveCore.a, built from SUITE_ROOT's
#   packages/ArchiveCore/Sources with `swiftc -swift-version 6 <flags> -emit-module -emit-library -static`.
#   Diagnostics go to stderr; exit 1 if the build fails (the compiler's first lines are printed).
#
# WHY (efficiency plan round 2, 2026-10-07): test-tag-vocabulary.sh rebuilt ArchiveCore with -O on every run,
# about two of its ~2.5 minutes in each health gate, under the Mac-wide heavy lock, even when no Core source had
# changed. The library is now reused when — and only when — everything that could change it is identical.
#
# THE KEY covers every input: each source file's path (relative to the package) and content, the flags, the
# `swiftc --version` text, the SDK path and version, and the macOS build. Any difference builds a new entry.
#
# SAFETY:
#   * The cache lives OUTSIDE every checkout: ${ARCHIVECORE_CACHE:-~/Library/Caches/ArchiveSuite/archivecore}.
#     Nothing is ever linked or copied into a worktree; callers pass the printed path to -I/-L. (A symlinked
#     build directory inside a worktree is how a `git add -A` once destroyed a 433 MB cache.)
#   * An entry is built in a private temporary directory and renamed into place only when complete; a rename
#     that loses a race to an identical build discards its own copy. A half-written entry is never visible.
#   * An entry is used only if both artifacts are present and a COMPLETE marker records its own key.
#   * The newest 6 entries are kept; older ones are removed (only directories named like an entry).
set -uo pipefail
SUITE="${1:?usage: archivecore-cache.sh SUITE_ROOT [swiftc flags…]}"; shift
FLAGS=("$@")
SRCROOT="$SUITE/packages/ArchiveCore/Sources"

SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$f"); done \
  < <(find "$SRCROOT" -name '*.swift' -print0 | sort -z)
if [ "${#SOURCES[@]}" -eq 0 ]; then
  echo "archivecore-cache: no ArchiveCore sources under $SRCROOT" >&2; exit 1
fi

build() {   # $1 = output directory
  mkdir -p "$1" || return 1
  if ! xcrun swiftc -swift-version 6 ${FLAGS[@]+"${FLAGS[@]}"} -emit-module -emit-library -static \
        -module-name ArchiveCore \
        -emit-module-path "$1/ArchiveCore.swiftmodule" \
        -o "$1/libArchiveCore.a" \
        "${SOURCES[@]}" 2>"$1/build.err"; then
    echo "archivecore-cache: ArchiveCore build failed:" >&2; head -25 "$1/build.err" >&2
    return 1
  fi
}

key="$(
  {
    printf 'flags:'; [ "${#FLAGS[@]}" -eq 0 ] || printf ' %s' "${FLAGS[@]}"; printf '\n'
    xcrun swiftc --version 2>&1
    xcrun --show-sdk-path 2>&1; xcrun --show-sdk-version 2>&1
    sw_vers -buildVersion 2>&1
    for f in "${SOURCES[@]}"; do
      printf 'file:%s\n' "${f#"$SRCROOT"/}"
      shasum -a 256 < "$f"
    done
  } | shasum -a 256 | cut -c1-32
)"
[ -n "$key" ] || { echo "archivecore-cache: could not compute a key" >&2; exit 1; }

CACHE="${ARCHIVECORE_CACHE:-$HOME/Library/Caches/ArchiveSuite/archivecore}"
entry="$CACHE/core-$key"
ready() { [ -f "$entry/ArchiveCore.swiftmodule" ] && [ -f "$entry/libArchiveCore.a" ] \
          && [ "$(cat "$entry/COMPLETE" 2>/dev/null)" = "$key" ]; }

if ready; then
  touch "$entry" "$entry/COMPLETE" 2>/dev/null || true   # recency for pruning: `ls -dt` reads the DIRECTORY mtime
  echo "archivecore-cache: reusing $entry" >&2
  echo "$entry"; exit 0
fi

mkdir -p "$CACHE" || exit 1
tmp="$(mktemp -d "$CACHE/.building.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
echo "archivecore-cache: building ArchiveCore (key $key)…" >&2
build "$tmp" || exit 1
printf '%s\n' "$key" > "$tmp/COMPLETE"
if [ -e "$entry" ] && ! ready; then
  # An incomplete entry under the final name (not something this script writes, since entries appear only by
  # rename): never reuse it. It is this cache's own directory, named core-<key>, so it is removed.
  case "$(basename "$entry")" in core-[0-9a-f]*) rm -rf "$entry" ;; esac
fi
# rename(2), not mv: mv onto an existing directory moves $tmp INSIDE it (core-<key>/.building.*) and succeeds.
# rename(2) fails on a non-empty target, so a loser to an identical, complete build leaves $tmp for the trap.
python3 -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$tmp" "$entry" 2>/dev/null || true
ready || { echo "archivecore-cache: entry $entry is not complete after the build" >&2; exit 1; }

# Prune: keep the newest 6 entries; remove stray build directories older than a day.
ls -1dt "$CACHE"/core-* 2>/dev/null | tail -n +7 | while IFS= read -r old; do
  case "$(basename "$old")" in core-[0-9a-f]*) rm -rf "$old" ;; esac
done
find "$CACHE" -maxdepth 1 -name '.building.*' -mtime +1 -exec rm -rf {} + 2>/dev/null || true
echo "$entry"
