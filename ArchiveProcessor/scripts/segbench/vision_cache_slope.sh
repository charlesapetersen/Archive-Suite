#!/bin/bash
# W49.proc-vision-page-cache: the straightening slope from the Vision reader's own pass against its separate pass.
# usage: vision_cache_slope.sh <list.tsv> <out.tsv>   ($0: Apple Vision on this Mac; inputs are only read)
set -euo pipefail
. "$(dirname "$0")/../../../ops/autonomous/heavy-enter.sh"
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
src="$PWD/macOS/Sources/ArchiveProcessor"
swiftc -parse-as-library -O "$src/Models/DefaultsKeys.swift" "$src/OCR/VisionQueue.swift" \
    "$src/OCR/PageVisionCache.swift" "$src/OCR/ImageEncoding.swift" "$src/OCR/VisionClient.swift" \
    "$src/OCR/ReadQualityFlag.swift" "$src/OCR/ReadingCopy.swift" "$PWD/scripts/segbench/vision_cache_slope.swift" \
    -o "$work/vision_cache_slope"
"$work/vision_cache_slope" "$1" "$2" "$work/pages"
