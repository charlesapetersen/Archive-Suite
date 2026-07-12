#!/bin/bash
# Fail if any Editor/ source references .layoutManager — accessing it silently
# downgrades NSTextView from TextKit 2 to TextKit 1 and breaks attachment view providers.
set -euo pipefail
cd "$(dirname "$0")/../macOS/Sources/ArchiveNotes/Editor"

if grep -rn '\.layoutManager' . --include='*.swift'; then
    echo "ERROR: .layoutManager reference found in Editor/ — use textLayoutManager instead."
    exit 1
fi

echo "lint-editor: OK (no .layoutManager references)"
