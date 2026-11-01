#!/bin/bash
# Free, headless orientation regressions. Optional arg: frozen ocr-panel-cloud/images directory
# (96 upright *-original.jpg files, read-only), to measure all four turns. No paid calls or settings writes.
# ROTATION_DETECTOR_SRC can select a pre-fix detector for a same-input comparison/mutation check.
set -euo pipefail
if [ -n "${CODEX_SANDBOX:-}" ]; then
    echo "Vision recognition must run outside the Codex sandbox." >&2
    exit 3
fi
. "$(dirname "$0")/../../ops/autonomous/heavy-enter.sh"
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -parse-as-library -O \
    "$PWD/macOS/Sources/ArchiveProcessor/OCR/VisionQueue.swift" \
    "${ROTATION_DETECTOR_SRC:-$PWD/macOS/Sources/ArchiveProcessor/OCR/RotationDetector.swift}" \
    "$PWD/scripts/rotation-axis-headless.swift" -o "$work/rotation-axis-headless"
"$work/rotation-axis-headless" "$@"
