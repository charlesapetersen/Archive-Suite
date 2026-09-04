#!/bin/bash
# $0 functional proof of the real in-process Apple Vision OCR backend. It compiles the production
# VisionClient with a deliberately tiny command-line test host, then sends it two CoreGraphics-generated
# PNGs. No app window, key, network, selected input folder, or output directory is involved.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT

swiftc -parse-as-library \
    "$PWD/macOS/Sources/ArchiveProcessor/Models/DefaultsKeys.swift" \
    "$PWD/macOS/Sources/ArchiveProcessor/OCR/VisionClient.swift" \
    "$PWD/scripts/vision-ocr-headless.swift" \
    -o "$work/vision-ocr-headless"
"$work/vision-ocr-headless"
