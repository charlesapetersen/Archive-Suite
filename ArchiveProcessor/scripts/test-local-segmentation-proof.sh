#!/bin/bash
# W41.app-local-seg-proof: one heavy-lock holder for the guarded mlx-vlm server AND the app proof.
# Build Debug first, then run this outside the Codex sandbox. No key, paid call or GUI.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"
set -euo pipefail
exec /usr/bin/python3 "$(dirname "$0")/segbench/local_segmentation_proof.py" "$@"
