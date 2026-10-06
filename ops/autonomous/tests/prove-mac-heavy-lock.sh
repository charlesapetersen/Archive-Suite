#!/usr/bin/env bash
# W35.machine-lock: scratch lock path only; never touches ~/.local/state/mac-heavy.lock.
set -euo pipefail
exec python3 "$(dirname "$0")/prove-mac-heavy-lock.py"
