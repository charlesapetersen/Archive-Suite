#!/usr/bin/env bash
# The short, locked plan mutation seam. Usage: plan-edit.sh PLAN complete TAG SHA RESULT
# or plan-edit.sh PLAN block TAG PREREQUISITE QUESTION; complete marks an empty queue COMPLETE.
# or plan-edit.sh PLAN log TEXT / report TEXT / append '## SECTION' TEXT.
# or plan-edit.sh PLAN add TAG AFTER-TAG TEXT: file a new `- [ ] TEXT` queue line after AFTER-TAG's item.
# or plan-edit.sh PLAN approve GATE NOTE: tick a HOLD QUEUE gate the owner answered, which unblocks its items.
# or plan-edit.sh PLAN depend TAG PREREQUISITE NOTE: make a queue item or HOLD gate TAG wait on an existing item or gate (no new gate).
# or plan-edit.sh PLAN undepend TAG PREREQUISITE NOTE: drop one prerequisite from TAG (the others stay).
# or plan-edit.sh PLAN hold TAG NOTE: hand an open item to the owner (appends `(needs: owner)` and the note).
# or plan-edit.sh PLAN release TAG NOTE: lift that hold once the owner's part is done (removes `(needs: owner)`).
# or plan-edit.sh PLAN due|rearm GATE NOTE: tick or untick a machine gate in `## RECURRING` (W40.token-pass's W40.token-fix-due).
set -euo pipefail
exec python3 "$(dirname "$0")/plan-edit.py" "$@"
