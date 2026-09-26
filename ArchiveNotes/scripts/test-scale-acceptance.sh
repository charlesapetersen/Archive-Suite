#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export ARCHIVE_NOTES_SCALE_ACCEPTANCE=1
export PATH="$REPO_ROOT/ops/autonomous/bin:$PATH"
export ARCHIVE_UNATTENDED=1
(cd "$REPO_ROOT/ArchiveNotes/macOS" && xcodegen generate)
"$REPO_ROOT/test-smoke.sh" notes
