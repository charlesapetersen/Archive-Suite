#!/usr/bin/env bash
# W35.live: scratch-only proof of the multi-worker measurement report. No daemon, installed state or real repo.
set -euo pipefail
exec python3 "$(dirname "$0")/prove-measure-workers.py" "$@"
