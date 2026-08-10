#!/usr/bin/env bash
# check-todo-stubs.sh — SUITE_TODO.md holds OPEN items only; a ticked item left here is counted twice.
#
# WHY THIS EXISTS (W26.donecount). `CLAUDE.md` §*Docs & backlog convention*: shipping an item MOVES its whole
# entry to `SUITE_TODO_DONE.md`. When a session ticks in place instead — or leaves a `[x]` pointer stub behind
# after moving the body — the item reads as done in BOTH files, and `status-digest.sh` sums ticked bullets
# across the two with no dedup. So it scores TWICE, permanently, and the drift only ever grows.
#
# The owner caught this from the outside on 2026-08-10: the digest went "237 finished" -> "246 finished"
# overnight when only 8 items had closed. Two stubs (`W26.fixturehang`, `W26.verify-fu1`) were being
# double-counted, so 244 was the defensible figure and the genuine delta was +8, not +9.
#
# ⚠️ WHY NOT IN `check-tracker-sync.sh`. It was tried there and reverted the same session. That script's whole
# job is COMPARING `[x]` state between the plan and SUITE_TODO, so it necessarily treats a `[x]` in SUITE_TODO
# as valid input; adding a rule that the same thing is invalid is self-contradictory, and it broke 5 of that
# harness's fixtures — including one whose premise is a deliberately-unmirrored HOLD QUEUE item. Two different
# assertions about the same file belong in two scripts.
#
# ⚠️ COLUMN 0 ONLY, and that is the whole trick. An INDENTED `- [x]` is a legitimate finished SUB-STEP inside
# an entry that is itself still `[ ]` — there are such lines in the tracker today and they are prose, not
# items. A ticked bullet at column 0 in this file is always the defect. That makes the rule exact rather than
# heuristic, so it can be a gate check without becoming noise.
#
# PARSING MIRRORS its siblings (`next-queue-item.sh`, `check-tracker-sync.sh`): code fences and blockquotes are
# commentary and are skipped. Without that, a fenced EXAMPLE of the very bug this reports would be reported.
#
# Read-only. Makes no edits and no commits. Safe to run anytime.
# Invoked WARN-ONLY by health-gate.sh (`|| true`), like tracker-sync and coherence: a docs-hygiene nit must
# never park an overnight run whose builds and suites are green.
#
# Exit: 0 = clean   1 = ticked item(s) found in SUITE_TODO   2 = bad input
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TODO="${AUTONOMOUS_TODO:-$ROOT/SUITE_TODO.md}"
TODO_DONE="${AUTONOMOUS_TODO_DONE:-$ROOT/SUITE_TODO_DONE.md}"
[ -f "$TODO_DONE" ] || TODO_DONE=/dev/null
QUIET="${TODO_STUBS_QUIET:-0}"

[ -f "$TODO" ] || { echo "check-todo-stubs: no todo at $TODO" >&2; exit 2; }

# Column-0 ticked bullets, skipping fences and blockquotes. Emits "<line>:<tag-or-->:<text>".
stubs="$(awk '
  /^[[:space:]]*(```|~~~)/ { infence = !infence; next }
  infence                  { next }
  /^[[:space:]]*>/         { next }
  /^- \[[xX]\][[:space:]]/ {
    t = $0
    sub(/^- \[[xX]\][[:space:]]*/, "", t)
    sub(/^\*+[[:space:]]*/, "", t)
    sub(/^`/, "", t)
    tag = "-"
    if (match(t, /^[A-Za-z0-9][A-Za-z0-9._-]*/)) tag = substr(t, 1, RLENGTH)
    print NR ":" tag ":" substr($0, 1, 96)
  }
' "$TODO")"

if [ -z "$stubs" ]; then
  [ "$QUIET" = 1 ] || echo "  ✓ todo-stubs: no ticked items left in SUITE_TODO.md (open items only)"
  exit 0
fi

n="$(printf '%s\n' "$stubs" | grep -c .)"
echo "  ⚠ todo-stubs: $n ticked item(s) still sitting in SUITE_TODO.md, which holds OPEN items only:"
printf '%s\n' "$stubs" | while IFS=: read -r ln tag text; do
  # Say whether it is CONFIRMED double-counted (its tag is also done in the archive) or merely misplaced —
  # different fixes, and the owner-facing count is only wrong in the first case.
  dup=""
  if [ "$tag" != "-" ] && grep -qE "^[[:space:]]*[-*][[:space:]]+\[[xX]\][[:space:]]*\*+${tag}([^A-Za-z0-9._-]|$)" "$TODO_DONE" 2>/dev/null; then
    dup=" — ALSO done in SUITE_TODO_DONE.md, so it is counted TWICE in \"N finished\""
  fi
  echo "      L${ln}: ${text}${dup}"
done
echo "      Fix: fold the line's prose into its SUITE_TODO_DONE.md entry, then delete it here."
echo "      (An INDENTED ticked sub-bullet is fine — only column 0 is the defect.)"
exit 1
