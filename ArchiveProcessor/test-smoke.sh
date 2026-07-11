#!/bin/bash
# test-smoke.sh — Archive Processor Tier-1 smoke test (cheap, repeatable regression gate).
#
# Proves the load-bearing OCR pipeline end-to-end, headlessly, for a few cents:
#   1. reads the Gemini key from the Keychain (never printed / never written to disk);
#   2. builds the macOS app (Debug);
#   3. drives the REAL Process-Files pipeline (OCR -> segmentation -> tagging -> PDF) on exactly
#      2 tiny images via the env-gated ProcessFilesTestDriver (no clicking, no GUI review);
#   4. asserts the driver's TEST_DONE marker appears AND >=1 output PDF lands in a scratch dir.
#
# All I/O is isolated to a `mktemp -d` scratch workspace (its own INPUT + OUTPUT dirs) that is
# deleted on exit — it NEVER writes into `Test Files/` or any real corpus. Spend is tiny:
# 2 images x gemini-2.5-flash-lite. A persistent run log (no key) is kept under
# `.maintenance/test-results/` (gitignored) so a FAIL can be triaged after the scratch dir is gone.
#
# Usage: bash ArchiveProcessor/test-smoke.sh
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"

ROOT="$(cd "$(dirname "$0")" && pwd)"          # .../ArchiveProcessor  (outer app dir)
PROJ="$ROOT/macOS"                             # inner XcodeGen project dir
APP="$PROJ/build/DD/Build/Products/Debug/ArchiveProcessor.app"
BIN="$APP/Contents/MacOS/ArchiveProcessor"
KC_SERVICE="com.archiveprocessor.app"
LOGDIR="$ROOT/.maintenance/test-results"; mkdir -p "$LOGDIR"
TS=$(date +%Y%m%d-%H%M%S)
APPLOG="$LOGDIR/smoke-proc-app-$TS.log"
BUILDLOG="$LOGDIR/smoke-proc-build-$TS.log"

fail(){ echo "SMOKE (processor): FAIL — $1"; [ -n "${2:-}" ] && echo "  failure log: $2"; exit 1; }

# Scratch workspace (INPUT + OUTPUT) — deleted on exit; app killed on exit.
WORK=$(mktemp -d) || fail "could not create scratch dir"
cleanup(){ pkill -x ArchiveProcessor 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
IN="$WORK/in"; OUT="$WORK/out"; mkdir -p "$IN" "$OUT"

echo "=== Archive Processor smoke test · $TS ==="
echo "  scratch: $WORK"

# ---------- 1. Gemini key (from Keychain; never printed/persisted) ----------
KEY=$(security find-generic-password -s "$KC_SERVICE" -a Gemini -w 2>/dev/null || true)
[ -n "$KEY" ] || fail "no Gemini key in Keychain (service '$KC_SERVICE', account 'Gemini') — add it or approve the Keychain prompt"

# ---------- 2. Inputs: 2 small images (from Test Files if present, else generated) ----------
TF="$ROOT/Test Files"
imgs=()
if [ -d "$TF" ]; then
  # macOS bash 3.2 — no mapfile; build the array with a read loop.
  while IFS= read -r f; do imgs+=("$f"); done < <(find "$TF" \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) -type f 2>/dev/null | sort | head -2)
fi
if [ "${#imgs[@]}" -ge 2 ]; then
  n=0; for f in "${imgs[@]}"; do n=$((n+1)); ext="${f##*.}"; cp "$f" "$IN/input$n.$ext" || fail "could not copy test image"; done
  echo "  inputs: 2 images copied from Test Files"
else
  # No corpus present (Test Files is gitignored) — generate 2 tiny text PNGs headlessly.
  # Pure CoreGraphics + CoreText + ImageIO: no window server, no AppKit dependency.
  GEN="$WORK/gen.swift"
  cat > "$GEN" <<'SWIFT'
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
guard a.count >= 3 else { FileHandle.standardError.write(Data("usage: gen <out.png> <text>\n".utf8)); exit(2) }
let outPath = a[1]
let lines = a[2].components(separatedBy: "\n")
let w = 700, h = 900
guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(3) }
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))   // CTLineDraw uses the context fill color
let font = CTFontCreateWithName("Helvetica" as CFString, 30, nil)
var y = h - 70
for line in lines {
    let attr = CFAttributedStringCreate(nil, line as CFString,
                                        [kCTFontAttributeName: font] as CFDictionary)!
    let ctline = CTLineCreateWithAttributedString(attr)
    ctx.textPosition = CGPoint(x: 50, y: CGFloat(y))
    CTLineDraw(ctline, ctx)
    y -= 46
}
guard let img = ctx.makeImage() else { exit(4) }
guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else { exit(5) }
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { exit(6) }
SWIFT
  swiftc -O "$GEN" -o "$WORK/gen" 2>"$BUILDLOG" || fail "could not compile the test-image generator" "$BUILDLOG"
  "$WORK/gen" "$IN/input1.png" "ARCHIVE PROCESSOR SMOKE TEST
Page one of a synthetic test document.
Memorandum
To: Test Harness
From: Smoke Script
Subject: OCR pipeline verification
This line exists to give the OCR model some text to transcribe." \
    || fail "generated image 1 failed"
  "$WORK/gen" "$IN/input2.png" "ARCHIVE PROCESSOR SMOKE TEST
Page two of a synthetic test document.
Letter
Dear Reader,
This is a second generated page so the pipeline
segments and tags more than one input.
Sincerely, the Smoke Script." \
    || fail "generated image 2 failed"
  echo "  inputs: 2 synthetic text images generated (Test Files not present in this checkout)"
fi

# ---------- 3. Build (Debug) ----------
echo "  building (Debug)…"
( cd "$PROJ" && xcodegen generate >/dev/null 2>&1 \
   && xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/DD build ) \
   >"$BUILDLOG" 2>&1
grep -q "BUILD SUCCEEDED" "$BUILDLOG" || fail "Debug build failed" "$BUILDLOG"
[ -x "$BIN" ] || fail "built app binary missing at $BIN" "$BUILDLOG"

# ---------- 4. Drive the headless Process-Files pipeline ----------
echo "  running headless OCR driver (2 images · gemini-2.5-flash-lite)…"
pkill -x ArchiveProcessor 2>/dev/null; sleep 1
DONE="$OUT/TEST_DONE.txt"
PROCESSFILES_TESTMODE=1 \
PROCESSFILES_TESTKEY="$KEY" \
PROCESSFILES_MODEL="gemini-2.5-flash-lite" \
PROCESSFILES_MAXIMAGES=2 \
PROCESSFILES_TESTIN="$IN" \
PROCESSFILES_TESTOUT="$OUT" \
PROCESSFILES_TESTDONE="$DONE" \
ARCHIVEPROC_HEADLESS=1 \
  "$BIN" >"$APPLOG" 2>&1 &
pid=$!
for _ in $(seq 1 90); do [ -f "$DONE" ] && break; sleep 2; done    # ~180s timeout
# The driver writes TEST_DONE then idles (it does not exit itself), so we kill it. Swallow the
# shell's "Terminated" job-control notice via wait — it is expected, not a failure.
{ kill "$pid"; wait "$pid"; } 2>/dev/null; pkill -x ArchiveProcessor 2>/dev/null; sleep 1
# Clear the pipeline's durable resume-state so a killed test never leaves a stale, paid
# "Resume Run" prompt for a later normal launch (the driver also clears it on a clean exit).
rm -f "$HOME/Library/Application Support/ArchiveProcessor/pending_run.json" \
      "$HOME/Library/Application Support/ArchiveProcessor/pending_batch.json" 2>/dev/null

# ---------- 5. Assert ----------
[ -f "$DONE" ] || fail "no TEST_DONE marker — driver hung or timed out (~180s)" "$APPLOG"
marker=$(cat "$DONE" 2>/dev/null || echo "")
case "$marker" in ERROR:*) fail "driver reported: $marker" "$APPLOG";; esac
pdfcount=$(find "$OUT" -type f -iname '*.pdf' 2>/dev/null | wc -l | tr -d ' ')
[ "${pdfcount:-0}" -ge 1 ] || fail "driver finished but produced 0 output PDFs" "$APPLOG"

echo "SMOKE (processor): PASS — marker='$marker', ${pdfcount} output PDF(s) in scratch"
echo "  run log: $APPLOG"
exit 0
