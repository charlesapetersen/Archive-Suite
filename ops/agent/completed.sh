#!/usr/bin/env bash
# completed hook: one integer, the items finished so far, for the engine's no-completion streak and the
# walkthrough's "items finished". The count of completed_items() in ops/autonomous/archive-suite-autonomous.sh,
# whose comments say how: each finished item once, each tracker read from the working copy and from origin/main
# and the copy with more ticks taken (a completion lands in either, depending on where the session pushed).
# Read-only. Test: ops/agent/tests/test_hooks.py compares it with the daemon function on a fixture.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
_tracker_body() {   # $1 = repo-relative path, $2 = the checkbox regex
  local w o body
  w=$(grep -cE "$2" "$REPO/$1" 2>/dev/null); case "$w" in ''|*[!0-9]*) w=0 ;; esac
  o=0
  if body="$(git -C "$REPO" show "origin/main:$1" 2>/dev/null)"; then
    o=$(printf '%s\n' "$body" | grep -cE "$2"); case "$o" in ''|*[!0-9]*) o=0 ;; esac
  fi
  # The copy with MORE ticks, for the same reason the fingerprint hashes both refs: a completion lands in the
  # working copy or in origin/main depending on whether the session pushed from a worktree or committed here,
  # and MISSING one false-parks a healthy run (the confirmed-HIGH failure this counter already had once).
  if [ "$o" -gt "$w" ]; then printf '%s\n' "$body"; else cat "$REPO/$1" 2>/dev/null; fi
}
completed_items() {
  # Each finished item counted ONCE: every ticked entry in SUITE_TODO_DONE.md, plus a tick in the plan's WORK
  # QUEUE or SUITE_TODO.md whose item is not in the archive yet. Since 2026-08-01 a finished item is MOVED to
  # SUITE_TODO_DONE.md, and its WORK QUEUE box is ticked in the same commit, so adding the trackers' tick counts
  # counted it twice (the walkthrough's "items finished" doubled; found 2026-11-17). An item is keyed by its tag
  # (W46.foo), or by its title where it has none. A missing file adds nothing, fail-safe.
  local re='^[[:space:]]*[-*][[:space:]]+\[[xX]\]'
  { _tracker_body SUITE_TODO_DONE.md "$re" | sed 's/^/D|/'
    awk '/^## WORK QUEUE/{f=1;next} f && /^## /{exit} f' "$PLAN" 2>/dev/null | sed 's/^/Q|/'
    _tracker_body SUITE_TODO.md "$re" | sed 's/^/T|/'; } | awk '
    function key(s,  t) {
      sub(/^[[:space:]]*[-*][[:space:]]+\[[xX]\][[:space:]]*/, "", s); gsub(/`/, "", s); sub(/^\*\*/, "", s)
      if (match(s, /^[A-Z][A-Za-z0-9]*\.[A-Za-z0-9._-]*[A-Za-z0-9]/)) return substr(s, 1, RLENGTH)
      t = s; sub(/\*\*.*/, "", t); sub(/ — .*/, "", t); return t
    }
    { src = substr($0, 1, 1); line = substr($0, 3) }
    line ~ /^[[:space:]]*[-*][[:space:]]+\[[xX]\]/ { k = key(line); if (src == "D") { n++; seen[k] = 1 } else if (!(k in seen)) { seen[k] = 1; n++ } }
    END { print n + 0 }'
}
completed_items
