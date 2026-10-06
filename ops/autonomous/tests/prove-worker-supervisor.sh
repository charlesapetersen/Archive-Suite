#!/usr/bin/env bash
# Scratch-only scheduler proof. No real CLIs, apps, installed state or daemon.
set -euo pipefail
exec python3 "$(dirname "$0")/prove-worker-supervisor.py" "$@"
