#!/bin/bash
# PAID live check of the one way to read a page (W42.int-s2), well under a cent: the app reads OpenRouter's endpoints
# listing (free), states the cost of two pages at the pinned upstream's listed price, then Qwen3-VL 235B (deepinfra
# fp8) reads the two smoke pages through PageReaders.reader, and the run reports each reading's text, seconds and
# dollars and what OpenRouter's key counter says was spent. The key is read from the Keychain (com.archiveprocessor.app
# / OpenRouter), passed in the app's environment only, never printed or written. Pages are drawn in a mktemp scratch;
# nothing touches Test Files or a real corpus. Headless (ARCHIVEPROC_HEADLESS=1): no window.
#
#   scripts/live-page-reader.sh [--paid]    (without --paid it prints the bound and stops)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"
set -uo pipefail
cd "$(dirname "$0")/.."
echo "Bound: 2 pages at Qwen3-VL 235B's listed price, about \$0.003; the app states the exact estimate before calling."
[ "${1:-}" = --paid ] || { echo "Not run: pass --paid to spend it."; exit 0; }

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$bin" ] || { echo "ArchiveProcessor is not built; run the documented Debug build first." >&2; exit 1; }
KEY=$(security find-generic-password -s com.archiveprocessor.app -a OpenRouter -w 2>/dev/null || true)
[ -n "$KEY" ] || { echo "no OpenRouter key in the Keychain (com.archiveprocessor.app / OpenRouter)" >&2; exit 1; }

work=$(mktemp -d); pid=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -rf "$work"' EXIT
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
# The texts are PageReaderTestDriver.smokePages, which the app compares the readings with.
"$work/gen" "$work/memo.png" $'MEMORANDUM\nTo: The Secretary\nFrom: Budget Office\nSubject: Fiscal year 1958 estimates\nThe attached tables show the revised figures.' || exit 1
"$work/gen" "$work/letter.png" $'Dear Mr. Hughes,\nThank you for your letter of March 3.\nWe will reply in full next week.\nSincerely yours,\nA. Smith' || exit 1

report="$work/result.txt"
PAGEREADER_LIVE=1 PAGEREADER_LIVE_KEY="$KEY" PAGEREADER_LIVE_DIR="$work" PAGEREADER_LIVE_OUT="$report" \
    ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" "$bin" >"$work/app.log" 2>&1 &
pid=$!
for _ in $(seq 1 120); do [ -f "$report" ] && break; sleep 1; done
[ -f "$report" ] || { echo "live page reader check timed out" >&2; tail -30 "$work/app.log" >&2; exit 1; }
cat "$report"
grep -q '^ALL PASS$' "$report"
