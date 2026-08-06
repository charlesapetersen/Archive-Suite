#!/bin/bash
# test-tag-vocabulary.sh — W26.vocab Tier-2 functional gate for the subject-autocomplete vocabulary.
#
# WHAT IT PROVES, and why it exists rather than an XCTest: the Processor has no test bundle, so the
# suite's pattern for exercising real Processor sources is a standalone `swiftc` build
# (`test-drive-store.sh`, `test-controlled-vocabulary.sh`). This one compiles the REAL
# `MacOSTagger.swift` + `SystemTagsProvider.swift` + `DefaultsKeys.swift` against the REAL ArchiveCore
# and drives them on scratch files:
#
#   1. the vocabulary hook in `MacOSTagger.applyTags` does NOT change what lands on disk — the tag and
#      label expectations are copied verbatim from `MacOSTaggerParityTests`, which predates it;
#   2. what it ingests is the write's VERIFIED on-disk result, facet-filtered to subjects;
#   3. a REFUSED write contributes nothing (the hook is after the `try`);
#   4. the vocabulary survives a RELAUNCH — phase 2 is a genuinely new process with fresh statics;
#   5. a real filesystem harvest of a scratch archive root learns subjects and stamps the root;
#   6. no `$HOME` walk: pointing the output directory at a forbidden folder records no root, starts no
#      walk, and does not leave the "building tag suggestions…" spinner running.
#
# FILE SAFETY: everything happens under one `mktemp -d`. The vocabulary is redirected with
# `ARCHIVEPROC_TAGVOCAB_FILE` so it can never touch the operator's Application Support, and the archive
# root is passed in the **argument** domain (`-outputDirectory`), which UserDefaults treats as volatile
# — no persisted default is read or written, so the operator's real output directory is untouched.
# No real corpus path appears anywhere in this script.
#
# Usage: ./scripts/test-tag-vocabulary.sh      (~1 min, mostly the one-off ArchiveCore compile)
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
SUITE="$(cd "$REPO/.." && pwd)"
SRC="$REPO/macOS/Sources/ArchiveProcessor"

WORK=$(mktemp -d)
SCRATCH="$WORK/scratch"
ROOT="$WORK/archive-root"
VOCAB="$WORK/tag-vocabulary.json"
mkdir -p "$SCRATCH" "$ROOT/Box 3/Folder 7"
trap 'rm -rf "$WORK"' EXIT

echo "=== W26.vocab tag-vocabulary Tier-2 test ==="
echo "work: $WORK"

# --- 1. ArchiveCore as a module the driver can import -------------------------------------------
# Built with swiftc rather than SwiftPM: `swift build` emits no linkable archive for a library
# product nothing depends on, and a hand-rolled `ar` over its object files is a worse contract than
# one compiler invocation.
echo "── building ArchiveCore…"
mkdir -p "$WORK/core"
if ! xcrun swiftc -swift-version 6 -O -emit-module -emit-library -static \
      -module-name ArchiveCore \
      -emit-module-path "$WORK/core/ArchiveCore.swiftmodule" \
      -o "$WORK/core/libArchiveCore.a" \
      $(find "$SUITE/packages/ArchiveCore/Sources" -name '*.swift') 2>"$WORK/core.err"; then
  echo "  [FAIL] ArchiveCore build:"; head -25 "$WORK/core.err"; exit 1
fi

# --- 2. The driver, compiled with the real Processor sources ------------------------------------
echo "── building the driver against the real Processor sources…"
if ! xcrun swiftc -swift-version 6 \
      -I "$WORK/core" -L "$WORK/core" -lArchiveCore \
      "$SRC/Tagging/MacOSTagger.swift" \
      "$SRC/Tagging/SystemTagsProvider.swift" \
      "$SRC/Models/DefaultsKeys.swift" \
      "$SRC/Models/KeychainHelper.swift" \
      "$REPO/scripts/tag-vocabulary-driver.swift" \
      -o "$WORK/driver" 2>"$WORK/driver.err"; then
  echo "  [FAIL] driver build:"; head -40 "$WORK/driver.err"; exit 1
fi

# --- 3. A scratch archive root with tags only the HARVEST can find ------------------------------
# Seeded by a separate throwaway binary rather than by the driver, so the harvest phase learns these
# subjects from the FILESYSTEM and could not have learned them from its own earlier writes. Tags are
# written through `.tagNamesKey`/`.labelNumberKey` — the same resource-value API the Finder uses —
# because the point is a real Finder tag, which `xattr(1)` would only approximate.
cat >"$WORK/seed.swift" <<'SWIFT'
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func seed(_ rel: String, _ tags: [String], _ label: Int?) {
    let u = root.appendingPathComponent(rel)
    FileManager.default.createFile(atPath: u.path, contents: Data("x".utf8))
    try? (u as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    if let label { try? (u as NSURL).setResourceValue(label, forKey: .labelNumberKey) }
}
seed("a.pdf", ["Purple", "Harvested Subject A", "1971", "Unread"], 3)
seed("Box 3/Folder 7/b.pdf", ["Harvested Subject B", "P8", "Read"], nil)
SWIFT
if ! xcrun swiftc -swift-version 6 "$WORK/seed.swift" -o "$WORK/seed" 2>"$WORK/seed.err"; then
  echo "  [FAIL] fixture seeder build:"; head -20 "$WORK/seed.err"; exit 1
fi
"$WORK/seed" "$ROOT" || { echo "  [FAIL] fixture seeding"; exit 1; }

# --- 4. The phases, each its own process --------------------------------------------------------
fail=0

echo ""
ARCHIVEPROC_TAGVOCAB_FILE="$VOCAB" "$WORK/driver" write "$SCRATCH" || fail=1
[ -s "$VOCAB" ] || { echo "  FAIL: nothing was persisted to $VOCAB"; fail=1; }

echo ""
# A NEW process: same vocabulary file, fresh statics. `-outputDirectory` lands in NSArgumentDomain.
ARCHIVEPROC_TAGVOCAB_FILE="$VOCAB" "$WORK/driver" harvest "$SCRATCH" "$ROOT" \
  -outputDirectory "$ROOT" || fail=1

echo ""
# A THIRD process against a SEPARATE vocabulary file, so "the vocabulary did not grow" is measured
# from a known-empty start rather than against the accumulated one.
for forbidden in "$HOME" "$HOME/Documents" "/"; do
  echo "  (forbidden root: $forbidden)"
  ARCHIVEPROC_TAGVOCAB_FILE="$WORK/forbidden.json" "$WORK/driver" forbidden "$SCRATCH" 0 \
    -outputDirectory "$forbidden" || fail=1
done

echo ""
# The store's own location, asserted without constructing the store. `PROCESSFILES_TESTMODE` rather
# than `ARCHIVEPROC_HEADLESS` on purpose: `test-tier2.sh` is the driver that runs the REAL tagging
# pipeline over the Ground Truth fixtures, and that is the variable it sets.
PROCESSFILES_TESTMODE=1 "$WORK/driver" store-path "$SCRATCH" scratch || fail=1
echo ""
# The negative control — no driver environment, so the redirection must NOT happen. Read-only: this
# phase resolves a path and prints it, and never opens, reads or writes the file it names.
"$WORK/driver" store-path "$SCRATCH" normal || fail=1

# --- 5. The vocabulary never learned anything about a real corpus -------------------------------
echo ""
if grep -qi "Archival Photos" "$VOCAB" 2>/dev/null; then
  echo "  FAIL: the vocabulary file mentions the real corpus"; fail=1
else
  echo "  PASS: no real-corpus path reached the vocabulary file"
fi

echo ""
if [ "$fail" -eq 0 ]; then echo "TAG VOCABULARY: PASS ✅"; else echo "TAG VOCABULARY: FAIL ❌"; fi
exit "$fail"
