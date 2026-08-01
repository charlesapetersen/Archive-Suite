#!/usr/bin/env bash
# check-tracker-sync.sh — the two item lists must agree about what is done.
#
# WHY THIS EXISTS. The same work item is tracked in two places: the daemon's WORK QUEUE in
# `.maintenance/AUTONOMOUS_PLAN.md` (gitignored runtime state, what `next-queue-item.sh` actually offers)
# and `SUITE_TODO.md` (committed, the tracker of record). Nothing enforced that they agree, and on
# 2026-08-01 they didn't: `W21.vmgui-path` had been fixed and ticked in SUITE_TODO on 07-31 but left `[ ]`
# in the plan, so the resolver was offering already-shipped work as the next task. It was caught by hand.
# The harm from duplicated state is that drift is SILENT — this makes it loud.
#
# It is also the equivalence check for the tracker consolidation: "do both sources report the same item
# state?" is exactly the assertion a strangler migration needs while both lists still exist. Both paths are
# overridable so it can outlive the specific files it was written for.
#
# PARSING MIRRORS `next-queue-item.sh` DELIBERATELY — same bullet forms, same code-fence and blockquote
# skipping, same first-occurrence-wins, same region scoping. If this file and the resolver disagree about
# what counts as an item, this check reports phantom drift and becomes noise, which is the exact failure
# mode it exists to prevent. Portable POSIX awk only (macOS /usr/bin/awk has no 3-arg match()).
#
# Read-only. Makes no edits and no commits. Safe to run anytime.
#
# Exit: 0 = in sync (or nothing to compare)   1 = divergence found   2 = bad input
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLAN="${AUTONOMOUS_PLAN:-$ROOT/.maintenance/AUTONOMOUS_PLAN.md}"
TODO="${AUTONOMOUS_TODO:-$ROOT/SUITE_TODO.md}"
# The completed-item archive is part of the SAME logical tracker and MUST be scanned with it. Splitting the
# done items out (2026-08-01, consolidation phase 2) dropped coverage from 100 shared items to 34 and made the
# very failure this guard was written for invisible: W21.vmgui-path was `[ ]` in the plan and `[x]` in the
# tracker, and once "[x] in the tracker" means "lives in the archive", comparing only SUITE_TODO can never see
# it again. Optional: absent = no-op, so this works before or after the split.
TODO_DONE="${AUTONOMOUS_TODO_DONE:-$ROOT/SUITE_TODO_DONE.md}"
[ -f "$TODO_DONE" ] || TODO_DONE=/dev/null
QUIET="${TRACKER_SYNC_QUIET:-0}"

[ -f "$PLAN" ] || { echo "check-tracker-sync: no plan at $PLAN" >&2; exit 2; }
[ -f "$TODO" ] || { echo "check-tracker-sync: no todo at $TODO" >&2; exit 2; }
grep -qE '^## WORK QUEUE' "$PLAN" || { echo "check-tracker-sync: no '## WORK QUEUE' section in $PLAN — bad plan" >&2; exit 2; }

# $1 = file, $2 = 1 to restrict to the plan's WORK QUEUE region (an item parked in the HOLD QUEUE is not
# offered as work, so it is not the same assertion and must not be compared), 0 to scan the whole file.
items() {
  awk -v region="$2" '
    function emit(  st, t, id) {
      st = (tolower($0) ~ /\[x\]/) ? "x" : " "
      match($0, /^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]*/)
      t = substr($0, RLENGTH + 1)
      sub(/^\*+[[:space:]]*/, "", t)          # strip bold markers, as the resolver does
      sub(/^`/, "", t)                        # ...and an optional leading backtick
      if (match(t, /^[A-Za-z0-9][A-Za-z0-9._-]*/)) {
        id = substr(t, 1, RLENGTH)
        if (!(id in seen)) { seen[id] = 1; print id "\t" st }
      }
    }
    region && /^## WORK QUEUE/ { inq = 1; next }
    region && inq && /^## /    { inq = 0 }
    region && !inq             { next }
    /^[[:space:]]*(```|~~~)/   { infence = !infence; next }   # backtick OR tilde code fence
    infence                    { next }
    /^[[:space:]]*>/           { next }                       # blockquote: commentary, not an item
    /^[[:space:]]*[-*][[:space:]]+\[[ xX]\]/ { emit() }
  ' "$1"
}

P="$(mktemp)"; T="$(mktemp)"; trap 'rm -f "$P" "$T"' EXIT
items "$PLAN" 1 | sort > "$P"
# SUITE_TODO first so a live entry wins over a stale archived twin (first-occurrence-wins, as in the resolver).
{ items "$TODO" 0; items "$TODO_DONE" 0; } | awk -F'\t' '!seen[$1]++' | sort > "$T"

TAB="$(printf '\t')"
# Compare only items present in BOTH. An item in one file and not the other is NOT drift: the plan mirrors a
# subset of SUITE_TODO on purpose, and SUITE_TODO carries long-tail items the daemon never sees. Flagging
# those would make this noisy enough to ignore — the failure mode this exists to prevent.
both="$(join -t"$TAB" "$P" "$T" 2>/dev/null)"
overlap="$(printf '%s' "$both" | grep -c . || true)"
report="$(printf '%s\n' "$both" | awk -F"$TAB" 'NF==3 && $2 != $3')"

if [ -z "$report" ]; then
  [ "$QUIET" = 1 ] || echo "  ✓ tracker-sync: plan WORK QUEUE and SUITE_TODO agree on all $overlap shared items"
  exit 0
fi

n="$(printf '%s\n' "$report" | grep -c .)"
echo "  ⚠ tracker-sync: $n of $overlap shared items DISAGREE between the plan and SUITE_TODO:"
printf '%s\n' "$report" | while IFS="$TAB" read -r id ps ts; do
  if [ "$ps" = " " ] && [ "$ts" = "x" ]; then
    echo "      $id — plan says OPEN, SUITE_TODO says DONE  →  the daemon would REDO shipped work"
  elif [ "$ps" = "x" ] && [ "$ts" = " " ]; then
    echo "      $id — plan says DONE, SUITE_TODO says OPEN  →  work looks finished but the record disagrees"
  else
    echo "      $id — plan '[$ps]' vs SUITE_TODO '[$ts]'"
  fi
done
echo "      Fix BOTH files. An item fixed interactively must flip the plan mirror too, not just SUITE_TODO."
exit 1
