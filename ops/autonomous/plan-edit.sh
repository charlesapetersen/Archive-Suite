#!/usr/bin/env bash
# The short, locked plan mutation seam. Usage: plan-edit.sh PLAN complete TAG SHA RESULT
# or plan-edit.sh PLAN block TAG PREREQUISITE QUESTION; complete marks an empty queue COMPLETE.
# or plan-edit.sh PLAN log TEXT / report TEXT / append '## SECTION' TEXT.
# or plan-edit.sh PLAN add TAG AFTER-TAG TEXT: file a new `- [ ] TEXT` queue line after AFTER-TAG's item.
# or plan-edit.sh PLAN approve GATE NOTE: tick a HOLD QUEUE gate the owner answered, which unblocks its items.
# or plan-edit.sh PLAN hold TAG NOTE: hand an open item to the owner (appends `(needs: owner)` and the note).
# or plan-edit.sh PLAN release TAG NOTE: lift that hold once the owner's part is done (removes `(needs: owner)`).
set -euo pipefail
exec python3 "$(dirname "$0")/plan-edit.py" "$@"
