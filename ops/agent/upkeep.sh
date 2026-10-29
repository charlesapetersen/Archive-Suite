#!/usr/bin/env bash
# upkeep hook: between sessions, never while a session of this project runs. What the daemon does between
# cycles: ops/autonomous/compact-plan.sh keeps the plan within its context budget (it takes the coordinator and
# plan locks itself through worker-state.py idle, so it cannot race a plan edit), then the two tracker checks
# the gate also runs warn-only. Exit nonzero only when the compactor truly aborted a pass (its own contract: a
# legitimate no-op is 0); the tracker checks never fail upkeep. Then cluster-reach.py's once-a-day login request
# (W46.engine-cluster), which never fails it either, and the weekly token pass (W40.token-pass, token-audit.py).
# Writes: the plan and its archives, and $STATE/token-audit/.
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
# W46.engine-cluster: at most once a day, ask the owner to log in when cluster items wait on the login. Never fails upkeep.
echo "--- cluster login request (warn-only)"
/usr/bin/python3 "$SCRIPTS/cluster-reach.py" ask || echo "upkeep: the cluster login request was not written"
# W40.token-pass: at most weekly, after 20+ engine sessions, the token-efficiency pass; it opens W40.token-fix when a
# budget is passed or a figure is 10% worse. Its report goes to $STATE/token-audit/. Never fails upkeep.
echo "--- token pass (warn-only)"
AGENT_REPO="$REPO" AGENT_STATE="$STATE" AUTONOMOUS_PLAN="$PLAN" /usr/bin/python3 "$AGENT_DIR/token-audit.py" upkeep \
  || echo "upkeep: the token pass failed; it runs again at the next upkeep"
exit "$rc"
