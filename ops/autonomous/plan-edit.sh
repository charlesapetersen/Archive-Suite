#!/usr/bin/env bash
# The short, locked plan mutation seam. Usage: plan-edit.sh PLAN complete TAG SHA RESULT
# or plan-edit.sh PLAN block TAG PREREQUISITE QUESTION; complete marks an empty queue COMPLETE.
# or plan-edit.sh PLAN log TEXT / report TEXT / append '## SECTION' TEXT.
set -euo pipefail
exec python3 "$(dirname "$0")/plan-edit.py" "$@"
