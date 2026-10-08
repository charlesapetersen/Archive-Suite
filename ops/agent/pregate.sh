#!/usr/bin/env bash
# pregate hook: the daemon's doc pre-gate decision, made by ops/autonomous/context-budget.sh. Only the
# per-session ORIENTATION TOTAL dispatches a doc-fix (owner decision 2026-08-13; per-file budgets are advisory),
# so: exit 10 with the reason when the total is OVER, else exit 0. Missing script: exit 0 (fail open, as the
# daemon does). Read-only. The compactor-first remedy for the plan is the upkeep hook's.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -x "$SCRIPTS/context-budget.sh" ] || exit 0
out="$("$SCRIPTS/context-budget.sh" "$REPO" 2>&1)"
total="$(printf '%s\n' "$out" | awk '$1=="context-budget:" && $2=="TOTAL" {print $3; exit}')"
[ "$total" = OVER ] || exit 0
files="$(printf '%s\n' "$out" | awk '$1=="context-budget:" && $2=="OVER" {
  p=$3; for (i=4; i<=NF-2; i++) p=p" "$i; print p }' | paste -sd, - | sed 's/,/, /g')"
sizes="$(printf '%s\n' "$out" | awk '$1=="context-budget:" && $2=="TOTAL" {print $4 " of " $5 " bytes"; exit}')"
echo "the per-session orientation total is over its budget (${sizes:-sizes unknown}); files over their own budget: ${files:-none (shrink a tracker: .maintenance/AUTONOMOUS_PLAN.md or SUITE_TODO.md)}"
exit 10
