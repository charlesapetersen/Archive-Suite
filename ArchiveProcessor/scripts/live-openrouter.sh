#!/bin/bash
# PAID live check of the OpenRouter provider (W41.app-openrouter), a few cents: each catalog model reads two
# synthetic pages through the REAL Process Files pipeline (OCR, classification, automatic tagging, PDF output) via
# the headless ProcessFilesTestDriver, and every output PDF must name OpenRouter and the model with its pinned
# provider and precision. The key is read from the Keychain (service com.archiveprocessor.app, account OpenRouter),
# passed to the app in its environment only, never printed or written. Inputs are generated in a mktemp scratch;
# nothing touches Test Files or a real corpus. Headless (ARCHIVEPROC_HEADLESS=1): no window.
#
# Cost: about $0.002 a page and its tagging call per model, so about $0.02 for the default three models.
# Without --paid it prints the estimate and stops.
#
#   scripts/live-openrouter.sh [--paid] [model-id ...]
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"
set -uo pipefail
cd "$(dirname "$0")/.."

paid=0; models=()
for a in "$@"; do [ "$a" = --paid ] && paid=1 || models+=("$a"); done
[ "${#models[@]}" -gt 0 ] || models=(qwen/qwen3-vl-235b-a22b-instruct qwen/qwen3.6-27b z-ai/glm-5.3-flash)
declare -a names
for m in "${models[@]}"; do
  case "$m" in
    qwen/qwen3-vl-235b-a22b-instruct) names+=("OpenRouter · Qwen3-VL 235B (deepinfra fp8)") ;;
    qwen/qwen3.6-27b) names+=("OpenRouter · Qwen3.6 27B (chutes fp8)") ;;
    z-ai/glm-5.3-flash) names+=("OpenRouter · GLM-5.3 Flash (z-ai fp8)") ;;
    *) echo "not a catalog model: $m" >&2; exit 2 ;;
  esac
done
echo "Estimated: ${#models[@]} models x 2 pages, about \$$(python3 -c "print(f'{0.0065 * ${#models[@]}:.2f}')") at most"
[ "$paid" = 1 ] || { echo "Not run: pass --paid to spend it."; exit 0; }

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$bin" ] || { echo "ArchiveProcessor is not built; run the documented Debug build first." >&2; exit 1; }
KEY=$(security find-generic-password -s com.archiveprocessor.app -a OpenRouter -w 2>/dev/null || true)
[ -n "$KEY" ] || { echo "no OpenRouter key in the Keychain (com.archiveprocessor.app / OpenRouter)" >&2; exit 1; }

work=$(mktemp -d); pid=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -rf "$work"; rm -f "$HOME/Library/Application Support/ArchiveProcessor/pending_run.json"' EXIT
cat > "$work/gen.swift" <<'SWIFT'
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
let a = CommandLine.arguments
let w = 700, h = 900
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
let font = CTFontCreateWithName("Helvetica" as CFString, 30, nil)
var y = h - 70
for line in a[2].components(separatedBy: "\n") {
    let s = CFAttributedStringCreate(nil, line as CFString, [kCTFontAttributeName: font] as CFDictionary)!
    ctx.textPosition = CGPoint(x: 50, y: CGFloat(y)); CTLineDraw(CTLineCreateWithAttributedString(s), ctx); y -= 46
}
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); exit(CGImageDestinationFinalize(dest) ? 0 : 1)
SWIFT
swiftc -O "$work/gen.swift" -o "$work/gen" 2>/dev/null || { echo "could not build the page generator" >&2; exit 1; }
mkdir -p "$work/in"
"$work/gen" "$work/in/input1.png" $'MEMORANDUM\nTo: The Secretary\nFrom: Budget Office\nSubject: Fiscal year 1958 estimates\nThe attached tables show the revised figures.' || exit 1
"$work/gen" "$work/in/input2.png" $'Dear Mr. Hughes,\nThank you for your letter of March 3.\nWe will reply in full next week.\nSincerely yours,\nA. Smith' || exit 1

bad=0
for i in "${!models[@]}"; do
  m="${models[$i]}"; out="$work/out-$i"; mkdir -p "$out"; done_file="$out/TEST_DONE.txt"
  PROCESSFILES_TESTMODE=1 PROCESSFILES_TESTKEY="$KEY" PROCESSFILES_PROVIDER=OpenRouter PROCESSFILES_MODEL="$m" \
    PROCESSFILES_MAXIMAGES=2 PROCESSFILES_TESTIN="$work/in" PROCESSFILES_TESTOUT="$out" PROCESSFILES_TESTDONE="$done_file" \
    ARCHIVEPROC_HEADLESS=1 "$bin" >"$work/app-$i.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 90); do [ -f "$done_file" ] && break; sleep 2; done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; pid=""
  rm -f "$HOME/Library/Application Support/ArchiveProcessor/pending_run.json"
  marker=$(cat "$done_file" 2>/dev/null || echo "no marker (timed out)")
  pdfs=$(find "$out" -type f -iname '*.pdf' | wc -l | tr -d ' ')
  header_ok=1
  while IFS= read -r -d '' pdf; do
    pdftotext "$pdf" - 2>/dev/null | grep -qF "${names[$i]}" || header_ok=0
  done < <(find "$out" -type f -iname '*.pdf' -print0)
  # Finder tags from the xattr itself (Spotlight does not index the scratch dir), via the asserter's reader.
  tags=$(find "$out" -type f -iname '*.pdf' -print0 | xargs -0 python3 -c 'import sys; sys.path.insert(0, "scripts")
from finder_tags import read_tags
print("; ".join(str(read_tags(p)[0]) for p in sys.argv[1:]))' 2>&1 | head -c 300)
  case "$tags" in *"[]"*|*None*|"") echo "  a PDF has no Finder tags: $tags"; header_ok=0 ;; esac
  text=$(find "$out" -type f -iname 'input1*.pdf' -exec pdftotext {} - \; 2>/dev/null | sed -n '1,12p' | tr '\n' '|' | head -c 300)
  case "$marker" in "Done. 2 succeeded, 0 failed."*) ok=1 ;; *) ok=0 ;; esac
  if [ "$ok" = 1 ] && [ "$pdfs" = 2 ] && [ "$header_ok" = 1 ]; then
    echo "PASS $m: $marker; header '${names[$i]}'"
  else
    echo "FAIL $m: marker '$marker', $pdfs PDFs, header_ok=$header_ok"; bad=1
    grep -iE "error|openrouter|OCR\]" "$work/app-$i.log" | tail -8
  fi
  echo "  page 1 text: $text"
  echo "  tags: $tags"
done
[ "$bad" = 0 ] && echo "ALL PASS" || exit 1
