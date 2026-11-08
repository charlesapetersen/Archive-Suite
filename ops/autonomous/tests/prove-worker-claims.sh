#!/usr/bin/env bash
# Scratch-only concurrency/lifecycle proof; no app, installed daemon or launchd.
set -euo pipefail
python3 "$(dirname "$0")/prove-worker-claims.py"
exec python3 "$(dirname "$0")/prove-plan-archive.py"
