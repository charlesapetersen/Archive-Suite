#!/bin/bash
# $0, key-free, no-network proof for W40.fix-processor-rotation-deadlock. It compiles the production
# RotationDetector with a tiny command-line host and queues 36 pages (the three e2e fixture pages, each rotated
# 0/90/180/270 and copied three times) through local Vision rotation detection at once. Every page must finish
# inside the time limit (after a one-page warm-up that absorbs the Neural Engine's first-run model compile),
# and each must come back with the exact correction: right text axis, right way up. Everything is in one temporary directory.
# ROTATION_LIMIT overrides the 120 s limit. ROTATION_DETECTOR_SRC compiles another RotationDetector.swift instead,
# for the mutation check: the pre-fix source (`git show 92ec5626:ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/
# RotationDetector.swift`) must FAIL on the time limit.
set -euo pipefail
. "$(dirname "$0")/../../ops/autonomous/heavy-enter.sh"
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/pages"

for src in scripts/e2e-fixtures/*.jpg; do
    base=$(basename "$src" .jpg)
    for copy in 1 2 3; do
        for deg in 0 90 180 270; do
            out="$work/pages/$base-c$copy-r$deg.jpg"
            cp "$src" "$out"
            [ "$deg" = 0 ] || sips -r "$deg" "$out" >/dev/null
        done
    done
done

swiftc -parse-as-library -O \
    "$PWD/macOS/Sources/ArchiveProcessor/OCR/VisionQueue.swift" \
    "${ROTATION_DETECTOR_SRC:-$PWD/macOS/Sources/ArchiveProcessor/OCR/RotationDetector.swift}" \
    "$PWD/scripts/rotation-deadlock-headless.swift" \
    -o "$work/rotation-deadlock-headless"
"$work/rotation-deadlock-headless" "$work/pages" "${ROTATION_LIMIT:-120}"
