#!/bin/bash
# Compile the production budget mapping against a tiny host and assert each request-purpose value.
# No app, key, network, fixture, or output folder is opened.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc "$PWD/macOS/Sources/ArchiveProcessor/OCR/ThinkingBudget.swift" \
  "$PWD/scripts/thinking-budget-headless.swift" -o "$work/thinking-budget-check"
"$work/thinking-budget-check"
