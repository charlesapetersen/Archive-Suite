#!/usr/bin/env bash
# test-lint-write-surface.sh — prove lint-write-surface.sh actually FAILS on a planted violation.
#
# The lint is the automated half of the Reader's Core Directive, so a lint that passes vacuously is
# worse than no lint: it reads as "the write surface is clean". Before W26.lint the tag-write rule
# was exactly that — the Reader's `TagWriter` had delegated its writes to ArchiveCore, which the
# lint did not look at, so rule 1 had nothing left to catch.
#
# Everything runs against a COPY of the two linted trees in a mktemp dir, via the lint's TEST-ONLY
# `LINT_WRITE_SURFACE_ROOT` override. Nothing is ever planted in the real repo.
#
# Usage: ArchiveReader/scripts/test-lint-write-surface.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT="$REPO/ArchiveReader/scripts/lint-write-surface.sh"
READER_SRC="ArchiveReader/macOS/Sources/ArchiveReader"
CORE_SRC="packages/ArchiveCore/Sources/ArchiveCore"

pass=0; failed=0
SCRATCH=""
cleanup() { [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] && rm -rf "$SCRATCH"; }
trap cleanup EXIT

# Fresh copy of both linted trees, at the same relative paths the lint (and its ALLOW list) expect.
fresh_tree() {
  cleanup
  SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/lint-write-surface-test.XXXXXX")"
  mkdir -p "$SCRATCH/$(dirname "$READER_SRC")" "$SCRATCH/$(dirname "$CORE_SRC")"
  cp -R "$REPO/$READER_SRC" "$SCRATCH/$(dirname "$READER_SRC")/"
  cp -R "$REPO/$CORE_SRC" "$SCRATCH/$(dirname "$CORE_SRC")/"
}

# expect <expected-rc> <name> [substring the output must contain]
expect() {
  local want="$1" name="$2" needle="${3:-}" out rc
  out="$(LINT_WRITE_SURFACE_ROOT="$SCRATCH" bash "$LINT" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "✗ $name — expected rc=$want, got rc=$rc"; echo "$out" | sed 's/^/    /'; failed=$((failed+1)); return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF "$needle"; then
    echo "✗ $name — rc ok but output never mentioned '$needle'"; echo "$out" | sed 's/^/    /'
    failed=$((failed+1)); return
  fi
  echo "✓ $name"; pass=$((pass+1))
}

echo "── control ─────────────────────────────────────────────────────────────────"
fresh_tree
expect 0 "clean copy of both trees passes" "write-surface lint clean"

echo "── the item's own gate: a planted tag write in a NEW ArchiveCore file ───────"
fresh_tree
mkdir -p "$SCRATCH/$CORE_SRC/Corpus"
cat > "$SCRATCH/$CORE_SRC/Corpus/PlantedWalker.swift" <<'SWIFT'
// A pretend corpus walker that writes tags — exactly what W26.walk1 must not be able to land.
import Foundation
func plantedWrite(_ url: URL, _ tags: [String]) throws {
    try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
}
SWIFT
expect 1 "planted setResourceValue in a new ArchiveCore file FAILS" "Corpus/PlantedWalker.swift"

echo "── the same plant in the Reader app target (rule 1 still covers it) ─────────"
fresh_tree
cat > "$SCRATCH/$READER_SRC/Core/PlantedTagWrite.swift" <<'SWIFT'
import Foundation
func plantedWrite(_ url: URL, _ tags: [String]) throws {
    try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
}
SWIFT
expect 1 "planted setResourceValue in the Reader target FAILS" "PlantedTagWrite.swift"

echo "── no file-level exemption: a NEW write inside the audited writer itself ────"
fresh_tree
# TagWrite.swift is the one allowed file, but only for its three audited lines. A fourth,
# differently-spelled write there must still be caught — a file-level allowlist would miss it.
printf '\nfunc smuggled(_ url: URL) throws {\n    try (url as NSURL).setResourceValue(["Read"], forKey: .tagNamesKey)\n}\n' \
  >> "$SCRATCH/$CORE_SRC/Tags/TagWrite.swift"
expect 1 "an extra write inside TagWrite.swift itself FAILS" "Tags/TagWrite.swift"

echo "── an allowed line that CHANGED is not silently still allowed ───────────────"
fresh_tree
# Repoint RootMarker's allowed write at a different URL. Same file, same API, different target —
# the (file, exact line) pair must stop matching so the new target gets re-audited.
/usr/bin/sed -i '' 's/try data\.write(to: coordURL, options: \.atomic)/try data.write(to: fileURL, options: .atomic)/' \
  "$SCRATCH/$CORE_SRC/Links/RootMarker.swift"
expect 1 "an edited allowed write line FAILS (allowance is exact, not per-file)" "Links/RootMarker.swift"

echo "── planted destructive APIs in ArchiveCore ─────────────────────────────────"
fresh_tree
mkdir -p "$SCRATCH/$CORE_SRC/Corpus"
cat > "$SCRATCH/$CORE_SRC/Corpus/PlantedDelete.swift" <<'SWIFT'
import Foundation
func plantedDelete(_ url: URL) throws {
    try FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: url, to: url)
    try Data().write(to: url)
}
SWIFT
expect 1 "planted removeItem/moveItem/write(to:) in ArchiveCore FAILS" "Corpus/PlantedDelete.swift"

echo "── a plant the OLD lint would have missed, in an unlinted-until-now tree ────"
fresh_tree
# Before this change SRCS was Reader-only, so this exact plant produced a green lint.
cat > "$SCRATCH/$CORE_SRC/Tags/PlantedRawXattr.swift" <<'SWIFT'
import Foundation
func plantedRaw(_ path: String, _ value: Data) {
    _ = value.withUnsafeBytes { setxattr(path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, value.count, 0, 0) }
}
SWIFT
expect 1 "planted raw setxattr in ArchiveCore FAILS" "PlantedRawXattr.swift"

echo "── vacuous-pass guards: a renamed source root must not read as clean ────────"
fresh_tree
mv "$SCRATCH/$CORE_SRC" "$SCRATCH/$(dirname "$CORE_SRC")/ArchiveCoreRenamed"
expect 1 "a missing linted source root FAILS (not silently skipped)" "source root is missing"

echo "── vacuous-pass guards: an allowance protecting nothing is reported STALE ───"
fresh_tree
# Delete the allowed eviction call outright: no violation remains, but the allowance now guards
# nothing — a pre-approved hole for the next write to slip into.
/usr/bin/sed -i '' 's|try? FileManager\.default\.removeItem(at: url)|// removed for the test|' \
  "$SCRATCH/$CORE_SRC/Thumbnails/PDFThumbnailer.swift"
expect 1 "an allowance whose line vanished FAILS as STALE" "STALE allowance"

echo
if [ "$failed" -eq 0 ]; then
  echo "✓ lint-write-surface self-test: $pass/$pass checks passed"
  exit 0
fi
echo "✗ lint-write-surface self-test: $failed failed, $pass passed"
exit 1
