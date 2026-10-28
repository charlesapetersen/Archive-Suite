#!/bin/bash
# W46.sherlock-batch: submit and collect a batch of ready packs in one owner-started Sherlock session.
#   bash batch.sh check|submit|collect BATCH [--dry-run]
# sh.env first, for $FS_ROOT, $FS_PY and the image; batch.py has the rest. Never run by the engine.
set -euo pipefail
SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SH_DIR/sh.env"
exec python3 "$SH_DIR/batch.py" "$@"
