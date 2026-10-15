#!/bin/bash
# test-smoke.sh — Archive Processor Tier-1 smoke test (cheap, repeatable regression gate).
#
# Proves the load-bearing OCR pipeline end-to-end, headlessly, for a few cents:
#   1. reads the Gemini key from the Keychain (never printed / never written to disk);
#   2. builds the macOS app (Debug);
#   3. drives the REAL Process-Files pipeline (OCR -> segmentation -> tagging -> PDF) on exactly
#      2 tiny images via the env-gated ProcessFilesTestDriver (no clicking, no GUI review);
#   4. asserts every input succeeded — the TEST_DONE marker, the driver's per-job manifest and one output PDF
#      per input all agree — then stops only its own child, bounded even when the caller blocks TERM.
#      Teardown and oracle proof: scripts/test-smoke-teardown.py.
#
# All I/O is isolated to a `mktemp -d` scratch workspace (its own INPUT + OUTPUT dirs) that is
# deleted on exit — it NEVER writes into `Test Files/` or any real corpus. Spend is tiny:
# 2 images x gemini-2.5-flash-lite. A persistent run log (no key) is kept under
# `.maintenance/test-results/` (gitignored) so a FAIL can be triaged after the scratch dir is gone.
#
# Usage: bash ArchiveProcessor/test-smoke.sh
set -uo pipefail
if [ -n "${CODEX_SANDBOX:-}" ]; then
  echo "This smoke launches an app; request execution outside the Codex sandbox." >&2
  exit 3
fi
. "$(dirname "$0")/../ops/autonomous/heavy-enter.sh"
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

# The launched driver is the only process this script may stop. Inspect only that captured direct child:
# a missing/zombie child can be reaped, while a live nonchild or an inspection failure never authorizes a
# signal. Never match apps by name — the owner's own Archive Processor may be running.
SMOKE_PID=""
smoke_child_state(){
  local row parent state
  if ! row="$(ps -p "$SMOKE_PID" -o ppid= -o stat= 2>/dev/null)"; then
    if kill -0 "$SMOKE_PID" 2>/dev/null; then return 1; fi
    printf '%s\n' exited; return 0
  fi
  read -r parent state <<< "$row"
  [ "$parent" = "$$" ] || return 1
  case "$state" in *Z*) printf '%s\n' exited ;; *) printf '%s\n' running ;; esac
}
# Bounded: TERM, ~5 s, then KILL for a child that ignores TERM, ~5 s, then reap. The driver idles after
# TEST_DONE rather than exiting, so stopping it is the normal path, not a failure.
stop_smoke_child(){
  [ -n "$SMOKE_PID" ] || return 0
  [[ "$SMOKE_PID" =~ ^[1-9][0-9]*$ ]] || return 1
  local state n
  state="$(smoke_child_state)" || { echo "  cannot verify ownership of smoke child $SMOKE_PID; not signalling it"; return 1; }
  if [ "$state" = running ]; then
    kill -TERM "$SMOKE_PID" 2>/dev/null || true
    for n in $(seq 1 50); do
      state="$(smoke_child_state)" || return 1
      [ "$state" = exited ] && break
      sleep 0.1
    done
    if [ "$state" = running ]; then
      echo "  smoke child did not stop after TERM; stopping the owned scratch child with KILL"
      kill -KILL "$SMOKE_PID" 2>/dev/null || true
      for n in $(seq 1 50); do
        state="$(smoke_child_state)" || return 1
        [ "$state" = exited ] && break
        sleep 0.1
      done
    fi
  fi
  [ "$state" = exited ] || { echo "  smoke child $SMOKE_PID survived shutdown"; return 1; }
  wait "$SMOKE_PID" 2>/dev/null || true
  SMOKE_PID=""
}

# Scratch workspace (INPUT + OUTPUT) — deleted on exit after the owned child has stopped. A child that
# could not be stopped keeps its scratch dir, and the run fails.
WORK=$(mktemp -d) || fail "could not create scratch dir"
finish_smoke(){
  local status=$?
  trap - EXIT
  if stop_smoke_child; then
    rm -rf "$WORK"
  else
    echo "SMOKE (processor): FAIL — smoke child could not be stopped; scratch kept at $WORK"
    [ "$status" != 0 ] || status=1
  fi
  exit "$status"
}
trap finish_smoke EXIT
IN="$WORK/in"; OUT="$WORK/out"; mkdir -p "$IN" "$OUT"

echo "=== Archive Processor smoke test · $TS ==="
echo "  scratch: $WORK"

# Keep the shared transcription instruction and response parser under the normal OCR smoke gate.
bash "$ROOT/scripts/test-ocr-prompt.sh" || fail "OCR prompt contract failed"

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

# Optional W22 functional case: one two-page PDF alongside the two image inputs. All sources
# and outputs remain inside this run's scratch tree.
if [ "${PROCESSFILES_TEST_MIXED:-0}" = "1" ]; then
  first_image=$(find "$IN" -type f | sort | head -1)
  sips -s format pdf "$first_image" --out "$WORK/page.pdf" >/dev/null 2>&1 \
    || fail "could not make a synthetic PDF page"
  pdfunite "$WORK/page.pdf" "$WORK/page.pdf" "$IN/mixed.pdf" \
    || fail "could not make the two-page test PDF"
  echo "  inputs: two images plus one synthetic two-page PDF"
fi

# ---------- 3. Build (Debug) ----------
echo "  building (Debug)…"
( cd "$PROJ" && xcodegen generate >/dev/null 2>&1 \
   && xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/DD build ) \
   >"$BUILDLOG" 2>&1
grep -q "BUILD SUCCEEDED" "$BUILDLOG" || fail "Debug build failed" "$BUILDLOG"
[ -x "$BIN" ] || fail "built app binary missing at $BIN" "$BUILDLOG"

# ---------- 4. Drive the headless Process-Files pipeline ----------
EXPECTED=$([ "${PROCESSFILES_TEST_MIXED:-0}" = "1" ] && echo 3 || echo 2)
echo "  running headless OCR driver ($EXPECTED inputs · gemini-2.5-flash-lite)…"
DONE="$OUT/TEST_DONE.txt"
# The calling engine may block TERM, and a blocked mask survives exec. Unblock it only in this captured
# child; exec keeps its PID, so SMOKE_PID is the app itself.
PROCESSFILES_TESTMODE=1 \
PROCESSFILES_TESTKEY="$KEY" \
PROCESSFILES_MODEL="gemini-2.5-flash-lite" \
PROCESSFILES_MAXIMAGES="$EXPECTED" \
PROCESSFILES_TEST_MIXED="${PROCESSFILES_TEST_MIXED:-0}" \
PROCESSFILES_TESTIN="$IN" \
PROCESSFILES_TESTOUT="$OUT" \
PROCESSFILES_TESTDONE="$DONE" \
ARCHIVEPROC_HEADLESS=1 \
python3 -c 'import os, signal, sys; signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM}); os.execv(sys.argv[1], sys.argv[1:])' \
  "$BIN" >"$APPLOG" 2>&1 &
SMOKE_PID=$!
for _ in $(seq 1 90); do [ -f "$DONE" ] && break; sleep 2; done    # ~180s timeout
# The driver writes TEST_DONE then idles (it does not exit itself), so stop the owned child.
stop_smoke_child || fail "smoke child could not be stopped" "$APPLOG"
# Clear the pipeline's durable resume-state so a killed test never leaves a stale, paid
# "Resume Run" prompt for a later normal launch (the driver also clears it on a clean exit).
rm -f "$HOME/Library/Application Support/ArchiveProcessor/pending_run.json" \
      "$HOME/Library/Application Support/ArchiveProcessor/pending_batch.json" 2>/dev/null

# ---------- 5. Assert ----------
# Every input must succeed. A failed job can still leave a placeholder PDF (an API 502 did), so neither the
# marker's prefix nor a PDF count proves success: read the driver's per-job manifest too.
# Prints the marker on success, the reason on failure.
check_smoke_result(){
  local done="$1" out="$2" want="$3" marker manifest header rows=0 row pdf status runs count
  [ -f "$done" ] || { echo "no TEST_DONE marker — driver hung or timed out (~180s)"; return 1; }
  marker=$(cat "$done" 2>/dev/null || echo "")
  case "$marker" in
    ERROR:*) echo "driver reported: $marker"; return 1 ;;
    "Done. $want succeeded, 0 failed."*) ;;
    *) echo "marker '$marker' is not 'Done. $want succeeded, 0 failed.'"; return 1 ;;
  esac
  runs=$(find "$out" -mindepth 2 -maxdepth 2 -name manifest.tsv 2>/dev/null | wc -l | tr -d ' ')
  [ "$runs" = 1 ] || { echo "expected one run manifest, found $runs"; return 1; }
  manifest=$(find "$out" -mindepth 2 -maxdepth 2 -name manifest.tsv)
  header=$(head -1 "$manifest")
  case "$header" in
    *$'\t'"inputs=$want"$'\t'"succeeded=$want"$'\t'"failed=0"$'\t'*) ;;
    *) echo "manifest header is not $want inputs, $want succeeded, 0 failed: $header"; return 1 ;;
  esac
  # Rows are pdf<TAB>classification<TAB>status, and classification may be empty. Split by expansion:
  # `read` with a tab IFS would merge the empty field. The driver writes no final newline, so
  # `|| [ -n … ]` keeps the last row.
  while IFS= read -r row || [ -n "$row" ]; do
    case "$row" in '#'*) continue ;; esac
    pdf="${row%%$'\t'*}"; status="${row##*$'\t'}"
    rows=$((rows + 1))
    [ "$status" = succeeded ] || { echo "job for '$pdf' has status '$status'"; return 1; }
    [ -n "$pdf" ] && [ -f "$(dirname "$manifest")/$pdf" ] \
      || { echo "succeeded job's output '$pdf' is missing"; return 1; }
  done < "$manifest"
  [ "$rows" = "$want" ] || { echo "manifest lists $rows jobs; expected $want"; return 1; }
  count=$(find "$out" -type f -iname '*.pdf' 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" = "$want" ] || { echo "run produced $count PDFs; expected $want"; return 1; }
  printf '%s\n' "$marker"
}
result=$(check_smoke_result "$DONE" "$OUT" "$EXPECTED") || fail "$result" "$APPLOG"
marker="$result"
pdfcount="$EXPECTED"

if [ "${PROCESSFILES_TEST_MIXED:-0}" = "1" ]; then
  [ "$pdfcount" -eq 3 ] || fail "mixed run produced $pdfcount PDFs; expected three" "$APPLOG"
  mixed_out=$(find "$OUT" -type f -name 'mixed.pdf' -print -quit)
  [ -n "$mixed_out" ] || fail "mixed run did not produce the rebuilt PDF" "$APPLOG"
  pages=$(pdfinfo "$mixed_out" | awk '/^Pages:/ {print $2}')
  [ "$pages" = 4 ] || fail "rebuilt two-page PDF has $pages pages; expected four" "$APPLOG"
  if xattr -p 'com.apple.metadata:_kMDItemUserTags' "$mixed_out" >/dev/null 2>&1; then
    fail "rebuilt multi-page PDF was tagged; tagging applies to images only" "$APPLOG"
  fi
  image_pdfs=0
  while IFS= read -r -d '' image_pdf; do
    pages=$(pdfinfo "$image_pdf" | awk '/^Pages:/ {print $2}')
    [ "$pages" = 2 ] || fail "image output $image_pdf has $pages pages; expected two" "$APPLOG"
    xattr -p 'com.apple.metadata:_kMDItemUserTags' "$image_pdf" >/dev/null 2>&1 \
      || fail "image output $image_pdf has no Finder tags" "$APPLOG"
    image_pdfs=$((image_pdfs + 1))
  done < <(find "$OUT" -type f -name 'input*.pdf' -print0)
  [ "$image_pdfs" -eq 2 ] || fail "mixed run produced $image_pdfs image PDFs; expected two" "$APPLOG"
fi

echo "SMOKE (processor): PASS — marker='$marker', ${pdfcount} output PDF(s) in scratch"
echo "  run log: $APPLOG"
exit 0
