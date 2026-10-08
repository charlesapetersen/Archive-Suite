#!/usr/bin/env bash
# W35.session-policy — the daemon asks the Agent Manager for each Claude session's model, effort and limits.
# Scratch-only: real daemon + real claims helper, stub grant helper, stub claude, stub heavy lock. No app,
# installed daemon, launchd, network or money. Details and every case: prove-session-policy.py.
set -euo pipefail
exec python3 "$(dirname "$0")/prove-session-policy.py" "$@"
