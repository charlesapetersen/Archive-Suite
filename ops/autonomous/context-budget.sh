#!/usr/bin/env bash
# context-budget.sh — guard the SIZE of every document a fresh session reads to orient.
#
# WHY (owner, 2026-08-04: "token use is the real bottleneck for development, not build speed"):
# a daemon session's dominant fixed cost is the orientation read — the plan, the tracker, the app guide,
# the resume prompt. That cost is invisible: nothing fails, nothing warns, the docs just get bigger and
# every session silently pays more. On 2026-08-04 `AUTONOMOUS_PLAN.md` had reached 462 KB (~117k tokens)
# with its compactor reporting "no-op" every cycle for weeks (three bugs — see compact-plan.sh's header).
# Two separate silent failures compounded: the compactor could not see the entries, and NOTHING was
# watching the number that mattered. This script is the second half of that fix.
#
# It costs ZERO tokens (pure shell, run by the health gate), which is the entire point: the expensive
# thing to measure is context, and the cheap place to measure it is a gate.
#
# BUDGETS are deliberately set ABOVE today's sizes, so this fails on CREEP rather than on the status quo.
# When one trips, the fix is almost never "raise the budget" — it is:
#   * AUTONOMOUS_PLAN.md      -> let `compact-plan.sh` run (or find out why it no-op'd, again)
#   * SUITE_TODO.md           -> move shipped entries to SUITE_TODO_DONE.md (the convention already says so)
#   * execution-plans/*.md    -> the plan shipped; delete it (git keeps the history)
#   * an app's CLAUDE.md      -> fold detail into the app's KNOWN_ISSUES / README, keep the map tight
# Raise a budget only with a reason recorded in the commit.
#
# EXIT: 0 = every file within budget (warnings still printed) · 1 = at least one OVER budget.
set -u

ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT" || { echo "context-budget: cannot cd to $ROOT"; exit 1; }

WARN_PCT="${WARN_PCT:-85}"   # print a ⚠ at this % of budget so drift is visible BEFORE it fails

# file<TAB>budget-bytes. Keep this list to what a session actually READS to orient.
BUDGETS=$(cat <<'EOF'
.maintenance/AUTONOMOUS_PLAN.md	180000
SUITE_TODO.md	200000
CLAUDE.md	24000
AGENTS.md	20000
REVIEW.md	20000
ArchiveReader/CLAUDE.md	64000
ArchiveProcessor/CLAUDE.md	64000
ArchiveNotes/CLAUDE.md	64000
ops/autonomous/resume-prompt.txt	28000
EOF
)
# Every in-flight execution plan shares one per-file budget (they are read whole when their wave is worked).
PLAN_BUDGET="${PLAN_BUDGET:-96000}"

over=""; warned=""; total=0
printf '%-46s %9s %9s %6s\n' "document" "bytes" "budget" "used"
printf '%-46s %9s %9s %6s\n' "----------------------------------------------" "---------" "---------" "------"

check() {  # $1=path $2=budget
  local f="$1" b="$2" s pct
  [ -f "$f" ] || return 0
  s=$(wc -c < "$f" | tr -d ' ')
  total=$((total + s))
  pct=$(( s * 100 / b ))
  if [ "$s" -gt "$b" ]; then
    printf '%-46s %9d %9d %5d%% ✗ OVER\n' "$f" "$s" "$b" "$pct"; over="$over $f"
  elif [ "$pct" -ge "$WARN_PCT" ]; then
    printf '%-46s %9d %9d %5d%% ⚠\n' "$f" "$s" "$b" "$pct"; warned="$warned $f"
  else
    printf '%-46s %9d %9d %5d%%\n' "$f" "$s" "$b" "$pct"
  fi
}

while IFS=$'\t' read -r f b; do
  [ -n "${f:-}" ] || continue
  check "$f" "$b"
done <<< "$BUDGETS"

# execution-plans/**.md — one budget each; a shipped plan should be DELETED, not trimmed.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  check "$f" "$PLAN_BUDGET"
done < <(find execution-plans -name '*.md' -type f 2>/dev/null | sort)

printf '\n  orientation total: %d bytes (~%dk tokens)\n' "$total" "$(( total / 4000 ))"

if [ -n "$over" ]; then
  echo "✗ context-budget: OVER budget:$over"
  echo "  Fix the DOCUMENT, not the budget (see this script's header for the per-file remedy)."
  exit 1
fi
[ -n "$warned" ] && echo "⚠ context-budget: approaching budget (>=${WARN_PCT}%):$warned"
echo "✓ context-budget: all orientation documents within budget"
exit 0
