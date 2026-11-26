#!/bin/bash
# $0, key-free, no-network proof for W49.proc-vision-page-cache. It compiles the production PageVisionCache,
# VisionClient and RotationDetector with a tiny command-line host and checks that a repeated Vision pass over an
# unchanged page is answered by the first (also while it runs), that a rewritten file, another turn or other request
# settings read again, and that the cached readings match an uncached request and the fixtures' known turns.
# Everything is in one temporary directory.
set -euo pipefail
if [ -n "${CODEX_SANDBOX:-}" ]; then
    echo "Vision recognition must run outside the Codex sandbox." >&2
    exit 3
fi
. "$(dirname "$0")/../../ops/autonomous/heavy-enter.sh"
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -parse-as-library \
    "$PWD/macOS/Sources/ArchiveProcessor/Models/DefaultsKeys.swift" \
    "$PWD/macOS/Sources/ArchiveProcessor/OCR/VisionQueue.swift" \
    "$PWD/macOS/Sources/ArchiveProcessor/OCR/PageVisionCache.swift" \
    "$PWD/macOS/Sources/ArchiveProcessor/OCR/ImageEncoding.swift" \
    "$PWD/macOS/Sources/ArchiveProcessor/OCR/VisionClient.swift" \
    "$PWD/macOS/Sources/ArchiveProcessor/OCR/ReadQualityFlag.swift" \
    "$PWD/macOS/Sources/ArchiveProcessor/OCR/RotationDetector.swift" \
    "$PWD/scripts/vision-page-cache-headless.swift" \
    -o "$work/vision-page-cache-headless"
"$work/vision-page-cache-headless" "$PWD/scripts/e2e-fixtures"
