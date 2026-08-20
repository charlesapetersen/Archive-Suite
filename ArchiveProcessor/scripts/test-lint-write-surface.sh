#!/usr/bin/env bash
# test-lint-write-surface.sh — mutation proof for the Processor write-surface lint.
# Every case copies only source code to mktemp, points the lint at that copy, and removes it on exit. No real
# corpus, output folder, Keychain, OCR provider, or live app is touched.
set -uo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="$APP_ROOT/scripts/lint-write-surface.sh"
GATE="$APP_ROOT/../ops/autonomous/health-gate.sh"
SRC="macOS/Sources/ArchiveProcessor"
[ -f "$LINT" ] && [ -f "$GATE" ] || { echo "FATAL: Processor lint or health gate missing" >&2; exit 1; }

PASS=0
FAIL=0
SCRATCH=""
ok() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
cleanup() { [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] && rm -rf "$SCRATCH"; }
trap cleanup EXIT

fresh_tree() {
  cleanup
  SCRATCH="$(mktemp -d)"
  mkdir -p "$SCRATCH/macOS/Sources"
  cp -R "$APP_ROOT/$SRC" "$SCRATCH/macOS/Sources/"
}

expect() { # <wanted rc> <label> <required output substring>
  local want="$1" label="$2" needle="$3" out rc
  out="$(PROCESSOR_LINT_ROOT="$SCRATCH" bash "$LINT" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    no "$label — expected rc=$want, got rc=$rc: $out"
  elif ! printf '%s' "$out" | grep -qF "$needle"; then
    no "$label — expected output to name '$needle': $out"
  else
    ok "$label"
  fi
}

echo '== Processor write-surface lint proof =='

fresh_tree
expect 0 'clean Processor source passes' 'Processor write-surface lint clean'

fresh_tree
mkdir -p "$SCRATCH/$SRC/Tagging"
cat > "$SCRATCH/$SRC/Tagging/PlantedDirectTagWrite.swift" <<'SWIFT'
import Foundation
func plantedTagWrite(_ url: URL) throws {
    try (url as NSURL).setResourceValue(["Read"], forKey: .tagNamesKey)
}
SWIFT
expect 1 'a planted direct setResourceValue fails' 'PlantedDirectTagWrite.swift'

fresh_tree
mkdir -p "$SCRATCH/$SRC/Tagging"
cat > "$SCRATCH/$SRC/Tagging/PlantedRawXattr.swift" <<'SWIFT'
import Foundation
func plantedRawXattr(_ path: String, _ data: Data) {
    _ = data.withUnsafeBytes { setxattr(path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, data.count, 0, 0) }
}
SWIFT
expect 1 'a planted raw setxattr fails' 'PlantedRawXattr.swift'

fresh_tree
cat >> "$SCRATCH/$SRC/OCR/PDFGenerator.swift" <<'SWIFT'

func plantedPDFWrite(_ outputURL: URL) {
    let rogue = PDFDocument()
    _ = rogue.write(to: outputURL)
}
SWIFT
expect 1 'an extra PDFDocument.write inside PDFGenerator fails (no file-level exemption)' 'PDFGenerator.swift'

fresh_tree
mkdir -p "$SCRATCH/$SRC/OCR"
cat > "$SCRATCH/$SRC/OCR/PlantedPDFWrite.swift" <<'SWIFT'
import PDFKit
func plantedPDFWriteElsewhere(_ outputURL: URL) {
    let rogue = PDFDocument()
    _ = rogue.write(to: outputURL)
}
SWIFT
expect 1 'a PDFDocument.write in a new source file fails' 'PlantedPDFWrite.swift'

fresh_tree
mkdir -p "$SCRATCH/$SRC/OCR"
cat > "$SCRATCH/$SRC/OCR/PlantedMultilinePDFWrite.swift" <<'SWIFT'
import PDFKit
func plantedMultilinePDFWrite(_ outputURL: URL) {
    let rogue = PDFDocument()
    _ = rogue.write(
        to: outputURL
    )
}
SWIFT
expect 1 'a multiline PDFDocument.write fails' 'PlantedMultilinePDFWrite.swift'

fresh_tree
mkdir -p "$SCRATCH/$SRC/OCR"
cat > "$SCRATCH/$SRC/OCR/PlantedDirectPDFWrite.swift" <<'SWIFT'
import PDFKit
func plantedDirectPDFWrite(_ outputURL: URL) {
    _ = PDFDocument().write(to: outputURL)
}
SWIFT
expect 1 'a direct PDFDocument(...).write fails' 'PlantedDirectPDFWrite.swift'

fresh_tree
mkdir -p "$SCRATCH/$SRC/OCR"
cat > "$SCRATCH/$SRC/OCR/PlantedOptionalPDFWrite.swift" <<'SWIFT'
import PDFKit
func plantedOptionalPDFWrite(_ inputURL: URL, _ outputURL: URL) {
    let rogue = PDFDocument(url: inputURL)
    _ = rogue?.write(to: outputURL)
}
SWIFT
expect 1 'an optional PDFDocument?.write fails' 'PlantedOptionalPDFWrite.swift'

fresh_tree
mv "$SCRATCH/$SRC" "$SCRATCH/macOS/Sources/ArchiveProcessorMoved"
expect 1 'a missing source root fails instead of passing vacuously' 'source root is missing'

lint_steps="$(grep -Ec '^step processor-write-surface-lint[[:space:]]+bash "\$ROOT/ArchiveProcessor/scripts/lint-write-surface.sh"$' "$GATE" || true)"
[ "$lint_steps" = 1 ] && ok 'the lint is wired exactly once into the health gate' || no "expected one Processor lint gate step, found $lint_steps"
proof_steps="$(grep -Ec '^step processor-write-surface-lint-proof[[:space:]]+bash "\$ROOT/ArchiveProcessor/scripts/test-lint-write-surface.sh"$' "$GATE" || true)"
[ "$proof_steps" = 1 ] && ok 'the mutation proof is wired exactly once into the health gate' || no "expected one Processor proof gate step, found $proof_steps"

echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" -eq 0 ]
