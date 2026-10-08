#!/usr/bin/env bash
# The short, locked plan mutation seam. Usage: plan-edit.sh PLAN complete TAG SHA RESULT
# or plan-edit.sh PLAN block TAG PREREQUISITE QUESTION; complete marks an empty queue COMPLETE.
# or plan-edit.sh PLAN log TEXT / report TEXT / append '## SECTION' TEXT.
# or plan-edit.sh PLAN add TAG AFTER-TAG TEXT: file a new `- [ ] TEXT` queue line after AFTER-TAG's item.
set -euo pipefail
exec python3 "$(dirname "$0")/plan-edit.py" "$@"
