#!/usr/bin/env bash
# upkeep hook: between sessions, never while a session of this project runs. What the daemon does between
# cycles: ops/autonomous/compact-plan.sh keeps the plan within its context budget (it takes the coordinator and
# plan locks itself through worker-state.py idle, so it cannot race a plan edit), then the two tracker checks
# the gate also runs warn-only. Exit nonzero only when the compactor truly aborted a pass (its own contract: a
# legitimate no-op is 0); the tracker checks never fail upkeep. Then cluster-reach.py's once-a-day login request
# (W46.engine-cluster), which never fails it either, the weekly token pass (W40.token-pass, token-audit.py), the
# measurement review cadence (W46.measure-review, measure-review.py) and
# the bench cache's size report (W40.cache-budget, cache-budget.py).
# Writes: the plan and its archives, $STATE/token-audit/, $STATE/measure-review/ and $STATE/cache-budget.txt.
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
# W46.measure-review: once 8 result commits have landed since the last measurement review, or a week and at least
# one, open the standing review (Fable, max effort) by ticking W46.measure-review-due. Never fails upkeep.
echo "--- measurement review cadence (warn-only)"
AGENT_REPO="$REPO" AGENT_STATE="$STATE" AUTONOMOUS_PLAN="$PLAN" /usr/bin/python3 "$AGENT_DIR/measure-review.py" upkeep \
  || echo "upkeep: the measurement review cadence failed; it runs again at the next upkeep"
# W40.cache-budget: at most every 6 hours, the bench cache's size per folder against its budget, into
# $STATE/cache-budget.txt. It measures and reports only; it never deletes. Never fails upkeep.
if [ -f "$SCRIPTS/cache-budget.py" ]; then
  echo "--- bench cache budget (warn-only)"
  AGENT_STATE="$STATE" /usr/bin/python3 "$SCRIPTS/cache-budget.py" || echo "upkeep: the cache report failed"
fi
exit "$rc"
