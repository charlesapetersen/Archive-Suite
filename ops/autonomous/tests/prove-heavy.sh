#!/usr/bin/env bash
# No app/VM/installed daemon: all contention and process trees are scratch.
set -euo pipefail
exec python3 "$(dirname "$0")/prove-heavy.py"
