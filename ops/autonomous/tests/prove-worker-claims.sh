#!/usr/bin/env bash
# Scratch-only concurrency/lifecycle proof; no app, installed daemon or launchd.
set -euo pipefail
exec python3 "$(dirname "$0")/prove-worker-claims.py"
