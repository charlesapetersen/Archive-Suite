#!/bin/bash
# W41.ocr-prompt-app: compile the real prompt builder/parser in a tiny command-line host.
# $0, no app launch, network, Keychain, or corpus; also run by the Processor smoke test.
set -euo pipefail
. "$(dirname "$0")/../../ops/autonomous/heavy-enter.sh"
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 6 -warnings-as-errors \
    "$PWD/macOS/Sources/ArchiveProcessor/OCR/OCRPrompt.swift" \
    "$PWD/scripts/ocr-prompt-headless.swift" -o "$work/ocr-prompt-check"
"$work/ocr-prompt-check"
