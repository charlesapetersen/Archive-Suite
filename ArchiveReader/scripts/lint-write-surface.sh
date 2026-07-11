#!/usr/bin/env bash
# lint-write-surface.sh — enforce the Core Directive (CLAUDE.md) at the source level.
#
#   1) ONLY Core/TagWriter.swift may call a tag-write API (setResourceValue(s) / setxattr).
#   2) NO file in the app target may call a move / rename / delete / trash / content-write API.
#
# Run before every commit (also invoked by the autonomous build). Exit non-zero on violation.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="macOS/Sources/ArchiveReader"
fail=0

# 1) tag-write APIs must appear only in TagWriter.swift.
tagwrite=$(grep -rnE 'setResourceValue|setResourceValues|setxattr' "$SRC" --include='*.swift' \
            | grep -v '/TagWriter\.swift:' || true)
if [ -n "$tagwrite" ]; then
  echo "✗ tag-write API used outside Core/TagWriter.swift:"; echo "$tagwrite"; fail=1
fi

# 2) destructive / content-write APIs must not appear anywhere in the app target.
destructive=$(grep -rnE '\.(removeItem|moveItem|trashItem|replaceItem|replaceItemAt|createFile)\(|FileHandle[^)]*forWriting|PDFDocument[^)]*\.write\(|\.write\(to:' \
              "$SRC" --include='*.swift' || true)
if [ -n "$destructive" ]; then
  echo "✗ destructive / content-write API in the app target:"; echo "$destructive"; fail=1
fi

if [ "$fail" -eq 0 ]; then echo "✓ write-surface lint clean ($SRC)"; fi
exit $fail
