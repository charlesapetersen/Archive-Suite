#!/usr/bin/env bash
# W35.pace: scratch-only proof of pace-aware slot sizing. No real CLI, daemon, ~/.codex or installed state.
set -euo pipefail
exec python3 "$(dirname "$0")/prove-usage-pace.py" "$@"
