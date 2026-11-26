#!/bin/bash
# $0 functional proof of the real in-process Apple Vision OCR backend. It compiles the production
# VisionClient with a deliberately tiny command-line test host, then sends it two CoreGraphics-generated
# PNGs (or, given image paths, reads those real photos and prints what came back; W40.d3). No app window, key, network, selected input folder, or output directory is involved.
set -euo pipefail
. "$(dirname "$0")/../../ops/autonomous/heavy-enter.sh"
cd "$(dirname "$0")/.."

work=$(mktemp -d)
cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT

swiftc -parse-as-library \
    "$PWD/macOS/Sources/ArchiveProcessor/Models/DefaultsKeys.swift" \
    "$PWD/macOS/Sources/ArchiveProcessor/OCR/VisionQueue.swift" \
    "$PWD/macOS/Sources/ArchiveProcessor/OCR/PageVisionCache.swift" \
    "$PWD/macOS/Sources/ArchiveProcessor/OCR/ImageEncoding.swift" \
    "$PWD/macOS/Sources/ArchiveProcessor/OCR/VisionClient.swift" \
    "$PWD/macOS/Sources/ArchiveProcessor/OCR/ReadQualityFlag.swift" \
    "$PWD/scripts/vision-ocr-headless.swift" \
    -o "$work/vision-ocr-headless"
"$work/vision-ocr-headless" "$@"
