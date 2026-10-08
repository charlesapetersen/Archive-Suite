#!/usr/bin/env bash
# upkeep hook: between sessions, never while a session of this project runs. What the daemon does between
# cycles: ops/autonomous/compact-plan.sh keeps the plan within its context budget (it takes the coordinator and
# plan locks itself through worker-state.py idle, so it cannot race a plan edit), then the two tracker checks
# the gate also runs warn-only. Exit nonzero only when the compactor truly aborted a pass (its own contract: a
# legitimate no-op is 0); the tracker checks never fail upkeep. Writes: the plan and its archives.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rc=0
if [ -x "$SCRIPTS/compact-plan.sh" ]; then
  "$SCRIPTS/compact-plan.sh" "$REPO" || { rc=$?; echo "upkeep: compact-plan ABORTED a pass (rc=$rc); the plan is not being kept within its budget"; }
fi
echo "--- tracker sync (warn-only)"
bash "$SCRIPTS/check-tracker-sync.sh" || true
echo "--- todo stubs (warn-only)"
bash "$SCRIPTS/check-todo-stubs.sh" || true
exit "$rc"
