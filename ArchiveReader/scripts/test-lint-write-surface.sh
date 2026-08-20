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
# The rule-3 cases (W26.walk1) exist for the same reason: `grep 'enumerator(at:'` matches ZERO
# occurrences in this repo because the call is always written across lines, so the obvious spelling
# of that rule would have passed vacuously. One case plants the violation MULTI-LINE, one plants it
# on a single line, and one plants a handler-BEARING call that must still pass — a rule that just
# banned `.enumerator(` would fail that third case.
#
# Usage: ArchiveReader/scripts/test-lint-write-surface.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT="$REPO/ArchiveReader/scripts/lint-write-surface.sh"
READER_SRC="ArchiveReader/macOS/Sources/ArchiveReader"
CORE_SRC="packages/ArchiveCore/Sources/ArchiveCore"
# W26.lint-fu (2026-08-07): the lint's source lists are PER-RULE, and Notes is in two of the three.
# The fixture must therefore carry the Notes tree as well, or the missing-root guard fires on every
# case and the control stops meaning anything.
NOTES_SRC="ArchiveNotes/macOS/Sources/ArchiveNotes"

pass=0; failed=0
SCRATCH=""
cleanup() { [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] && rm -rf "$SCRATCH"; }
trap cleanup EXIT

# Fresh copy of every linted tree, at the same relative paths the lint (and its ALLOW list) expect.
fresh_tree() {
  cleanup
  SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/lint-write-surface-test.XXXXXX")"
  for s in "$READER_SRC" "$CORE_SRC" "$NOTES_SRC"; do
    mkdir -p "$SCRATCH/$(dirname "$s")"
    cp -R "$REPO/$s" "$SCRATCH/$(dirname "$s")/"
  done
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

echo "── rule 3: a MULTI-LINE errorHandler-less enumerator (a grep would miss this) ──"
fresh_tree
mkdir -p "$SCRATCH/$CORE_SRC/Corpus"
cat > "$SCRATCH/$CORE_SRC/Corpus/PlantedSilentWalk.swift" <<'SWIFT'
// The overload that silently skips any directory it cannot descend into — written the way Swift
// style actually writes it, across lines, which is why `grep 'enumerator(at:'` finds NOTHING.
import Foundation
func plantedSilentWalk(_ root: URL) -> Int {
    var n = 0
    let en = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    while en?.nextObject() != nil { n += 1 }
    return n
}
SWIFT
expect 1 "a multi-line enumerator with no errorHandler FAILS" "Corpus/PlantedSilentWalk.swift"

echo "── rule 3: the same call on ONE line is caught too ─────────────────────────"
fresh_tree
mkdir -p "$SCRATCH/$CORE_SRC/Corpus"
cat > "$SCRATCH/$CORE_SRC/Corpus/PlantedOneLine.swift" <<'SWIFT'
import Foundation
func plantedOneLine(_ root: URL) -> Bool {
    return FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: []) != nil
}
SWIFT
expect 1 "a single-line enumerator with no errorHandler FAILS" "Corpus/PlantedOneLine.swift"

echo "── rule 3 bans the OVERLOAD, not the API: with a handler it must pass ──────"
fresh_tree
mkdir -p "$SCRATCH/$CORE_SRC/Corpus"
cat > "$SCRATCH/$CORE_SRC/Corpus/PlantedHonestWalk.swift" <<'SWIFT'
import Foundation
func plantedHonestWalk(_ root: URL) -> Int {
    var n = 0
    let en = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles],
        errorHandler: { _, _ in true }
    )
    while en?.nextObject() != nil { n += 1 }
    return n
}
SWIFT
expect 0 "an enumerator WITH errorHandler passes (the rule is not a ban on walking)" "lint clean"

echo "── rule 3 reads CODE, not prose: the same text in a doc comment must pass ──"
fresh_tree
mkdir -p "$SCRATCH/$CORE_SRC/Corpus"
cat > "$SCRATCH/$CORE_SRC/Corpus/PlantedProse.swift" <<'SWIFT'
import Foundation

/// Explains the rule, and must not trip it: `FileManager.enumerator(at:)` without an errorHandler
/// silently skips what it cannot read. Measured — `FileManager.default.enumerator(at: root,
/// includingPropertiesForKeys: nil, options: [])` still returns a live enumerator for a root it
/// cannot open.
//  FileManager.default.enumerator(at: someRoot, includingPropertiesForKeys: nil, options: [])
/*
 * FileManager.default.enumerator(at: someRoot, includingPropertiesForKeys: nil, options: [])
 */
func plantedProse() -> Int { 0 }
SWIFT
expect 0 "an errorHandler-less enumerator in a COMMENT passes (the rule is about calls)" "lint clean"

echo "── …and the SAME text as real code still FAILS (the relaxation is not blanket) ──"
fresh_tree
mkdir -p "$SCRATCH/$CORE_SRC/Corpus"
cat > "$SCRATCH/$CORE_SRC/Corpus/PlantedProseAndCode.swift" <<'SWIFT'
import Foundation

/// `FileManager.enumerator(at:)` without an errorHandler silently skips what it cannot read.
func plantedProseAndCode(_ root: URL) -> Bool {
    let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: []) // documented above
    return e != nil
}
SWIFT
expect 1 "a real call is caught even when an identical line appears in a comment" \
  "Corpus/PlantedProseAndCode.swift"

echo "── per-rule lists: rule 3 now reaches Archive Notes (W26.lint-fu) ──────────"
fresh_tree
mkdir -p "$SCRATCH/$NOTES_SRC/Index"
cat > "$SCRATCH/$NOTES_SRC/Index/PlantedNotesWalk.swift" <<'SWIFT'
// The exact shape W26.notesabsence fixed in this tree — a walk that reports nothing and cannot say
// it was denied. Rule 3 exists to stop it coming back.
import Foundation
func plantedNotesWalk(_ root: URL) -> Int {
    var n = 0
    let en = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    while en?.nextObject() != nil { n += 1 }
    return n
}
SWIFT
expect 1 "an errorHandler-less enumerator in the NOTES tree FAILS" "Index/PlantedNotesWalk.swift"

echo "── per-rule lists: rule 1 reaches Notes too ────────────────────────────────"
fresh_tree
mkdir -p "$SCRATCH/$NOTES_SRC/Store"
cat > "$SCRATCH/$NOTES_SRC/Store/PlantedNotesTagWrite.swift" <<'SWIFT'
import Foundation
func plantedNotesTagWrite(_ url: URL, _ tags: [String]) throws {
    try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
}
SWIFT
expect 1 "a tag write in the NOTES tree FAILS (the choke-point rule is suite-wide)" \
  "Store/PlantedNotesTagWrite.swift"

echo "── W9.c3: ArchiveCore has no AppKit or SwiftUI imports ─────────────────────"
fresh_tree
mkdir -p "$SCRATCH/$CORE_SRC/Boundary"
cat > "$SCRATCH/$CORE_SRC/Boundary/PlantedAppKitImport.swift" <<'SWIFT'
import Foundation
import AppKit
SWIFT
expect 1 "an AppKit import in ArchiveCore FAILS" "Boundary/PlantedAppKitImport.swift"

fresh_tree
mkdir -p "$SCRATCH/$CORE_SRC/Boundary"
cat > "$SCRATCH/$CORE_SRC/Boundary/PlantedSwiftUIImport.swift" <<'SWIFT'
import SwiftUI
SWIFT
expect 1 "a SwiftUI import in ArchiveCore FAILS" "Boundary/PlantedSwiftUIImport.swift"

fresh_tree
mkdir -p "$SCRATCH/$CORE_SRC/Boundary"
cat > "$SCRATCH/$CORE_SRC/Boundary/PlantedAttributedImport.swift" <<'SWIFT'
@preconcurrency import AppKit
SWIFT
expect 1 "an attributed AppKit import in ArchiveCore FAILS" "Boundary/PlantedAttributedImport.swift"

fresh_tree
mkdir -p "$SCRATCH/$CORE_SRC/Boundary"
cat > "$SCRATCH/$CORE_SRC/Boundary/PlantedImportProse.swift" <<'SWIFT'
// import AppKit belongs in an app target; this is documentation, not an import.
struct PlantedImportProse {}
SWIFT
expect 0 "AppKit spelling in ArchiveCore prose still passes" "lint clean"

echo "── …and rule 2 deliberately does NOT: Notes writes .md files for a living ──"
fresh_tree
mkdir -p "$SCRATCH/$NOTES_SRC/Store"
# Pins the W26.lint-fu decision as a behaviour rather than a header paragraph. If someone later adds
# the Notes tree to SRC_DESTRUCTIVE, this case fails and points them at the audit it requires — the
# real lint would also go RED on eleven pre-existing writes the same moment.
cat > "$SCRATCH/$NOTES_SRC/Store/PlantedNotesContentWrite.swift" <<'SWIFT'
import Foundation
func plantedNotesContentWrite(_ text: String, _ url: URL) throws {
    try Data(text.utf8).write(to: url, options: [.atomic])
    try FileManager.default.removeItem(at: url)
}
SWIFT
expect 0 "a content write in the NOTES tree still passes (rule 2 excludes it by decision)" "lint clean"

echo "── the union guard: a rule list may not name a tree SRCS omits ─────────────"
fresh_tree
# Guard (a2) has no reachable trigger from a fixture alone — it is about the lint's own configuration
# — so mutate the lint instead. Dropping Notes from the union while two rules still read it is the
# drift it exists to catch: without the guard, renaming the Notes tree would silently narrow rules 1
# and 3 back to nothing and the lint would print "✓ clean".
MUT="$SCRATCH/mutant-lint.sh"
/usr/bin/sed 's|^SRCS=( "\$SRC_READER" "\$SRC_CORE" "\$SRC_NOTES" )$|SRCS=( "$SRC_READER" "$SRC_CORE" )|' \
  "$LINT" > "$MUT"
if cmp -s "$MUT" "$LINT"; then
  echo "✗ union-guard mutant changed NOTHING — the sed no longer matches, so this case is vacuous"
  failed=$((failed+1))
else
  out="$(LINT_WRITE_SURFACE_ROOT="$SCRATCH" bash "$MUT" 2>&1)"; rc=$?
  if [ "$rc" -ne 1 ]; then
    echo "✗ a rule root missing from the union PASSED — guard (a2) is decorative"; echo "$out" | sed 's/^/    /'
    failed=$((failed+1))
  elif ! printf '%s' "$out" | grep -qF "missing from the union SRCS"; then
    echo "✗ the union mutant failed, but not for the union reason"; echo "$out" | sed 's/^/    /'
    failed=$((failed+1))
  else
    echo "✓ a rule root missing from the union SRCS FAILS (guard a2)"; pass=$((pass+1))
  fi
fi

# RETIRED by `W26.walk2` (2026-08-05): this case simulated walk2 deleting the allowed
# `ArchiveLibrary.swift` enumerator call, and asserted the allowance then went STALE. walk2 has
# happened — the call and its allowance are both gone — so the sed matched nothing and the case
# started asserting the opposite of its own name (lint clean, `expect 1` failing). It was never a
# rule-3-specific behaviour: the STALE-allowance guard is generic and is still covered above, by the
# PDFThumbnailer case. Deleted rather than re-pointed at another allowance, which would have been the
# same test twice.

echo
if [ "$failed" -eq 0 ]; then
  echo "✓ lint-write-surface self-test: $pass/$pass checks passed"
  exit 0
fi
echo "✗ lint-write-surface self-test: $failed failed, $pass passed"
exit 1
