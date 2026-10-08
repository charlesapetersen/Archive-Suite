#!/usr/bin/env bash
# completed hook: one integer, the items finished so far, for the engine's no-completion streak. The count of
# completed_items() in ops/autonomous/archive-suite-autonomous.sh: ticked boxes in the plan's WORK QUEUE, plus
# ticked boxes in SUITE_TODO.md and SUITE_TODO_DONE.md, each tracker read from the working copy and from
# origin/main and the larger taken (a completion lands in either, depending on where the session pushed).
# Read-only. Test: ops/agent/tests/test_hooks.py compares it with the daemon function on a fixture.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
re='^[[:space:]]*[-*][[:space:]]+\[[xX]\]'
tracker_ticks() {   # $1 = repo-relative path
  local w o body
  w=$(grep -cE "$re" "$REPO/$1" 2>/dev/null); case "$w" in ''|*[!0-9]*) w=0 ;; esac
  o=0
  if body="$(git -C "$REPO" show "origin/main:$1" 2>/dev/null)"; then
    o=$(printf '%s\n' "$body" | grep -cE "$re"); case "$o" in ''|*[!0-9]*) o=0 ;; esac
  fi
  [ "$o" -gt "$w" ] && w="$o"
  printf '%s\n' "$w"
}
q=$(awk '/^## WORK QUEUE/{f=1;next} f && /^## /{exit} f' "$PLAN" 2>/dev/null | grep -cE "$re")
t=$(tracker_ticks SUITE_TODO.md)
d=$(tracker_ticks SUITE_TODO_DONE.md)
case "$q" in ''|*[!0-9]*) q=0 ;; esac
case "$t" in ''|*[!0-9]*) t=0 ;; esac
case "$d" in ''|*[!0-9]*) d=0 ;; esac
echo $(( q + t + d ))
