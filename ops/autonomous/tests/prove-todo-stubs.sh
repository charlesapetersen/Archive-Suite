#!/usr/bin/env bash
# prove-todo-stubs.sh — prove the ticked-stub lint fires on the real defect and stays silent otherwise.
#
# WHY THIS EXISTS. The lint's value depends entirely on it being EXACT: it must catch the column-0 `[x]` that
# double-counts an item in the owner-facing "N finished", and it must never flag the indented ticked
# sub-bullets that legitimately exist inside still-open entries. A noisy docs lint gets ignored, and an
# ignored lint is worse than none — that is the stated failure mode of every guard in this directory.
#
# Fully sandboxed: builds its own fixture trackers in a temp dir. Touches no real tracker. Safe anytime.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/../check-todo-stubs.sh"
[ -f "$CHECK" ] || { echo "cannot find checker at $CHECK" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# run <todo-body> [done-body] -> sets RC and OUT
run() {
  printf '%s\n' "$1" > "$T/todo.md"
  printf '%s\n' "${2:-}" > "$T/done.md"
  OUT="$(AUTONOMOUS_TODO="$T/todo.md" AUTONOMOUS_TODO_DONE="$T/done.md" bash "$CHECK" 2>&1)"; RC=$?
}

echo "prove-todo-stubs — a ticked item in SUITE_TODO must be loud; an indented sub-step must be silent"

# ---- 1. the happy path ---------------------------------------------------------------------------------
run '- [ ] **W1.a — open work**
- [ ] **W1.b — more open work**'
[ "$RC" = 0 ] && ok "open items only -> exit 0" || bad "clean tracker: expected 0, got $RC ($OUT)"
case "$OUT" in *"no ticked items left"*) ok "says so explicitly";; *) bad "no success line: $OUT";; esac

# ---- 2. THE DEFECT: a column-0 ticked item ------------------------------------------------------------
run '- [ ] **W2.a — open**
- [x] **W2.shipped — ticked in place instead of moved**'
[ "$RC" = 1 ] && ok "a column-0 ticked item -> exit 1" || bad "expected 1, got $RC ($OUT)"
case "$OUT" in *"W2.shipped"*) ok "names the offending line";; *) bad "not named: $OUT";; esac
case "$OUT" in *"L2:"*) ok "gives its line number";; *) bad "no line number: $OUT";; esac

# ---- 3. the DOUBLE-COUNT distinction ------------------------------------------------------------------
# The owner-facing count is only wrong when the same tag is ALSO done in the archive. Merely-misplaced and
# actually-double-counted need different fixes, so the report must distinguish them.
run '- [x] **W3.dup — stub left behind after the body was moved**' '- [x] **W3.dup — the full archived entry**'
case "$OUT" in *"counted TWICE"*) ok "flags a confirmed double-count when the tag is also in the archive";; *) bad "double-count not flagged: $OUT";; esac
run '- [x] **W3.lonely — ticked here, not in the archive at all**' '- [x] **W3.other — unrelated**'
[ "$RC" = 1 ] && ok "a misplaced tick is still reported" || bad "misplaced tick not reported: rc=$RC"
case "$OUT" in *"counted TWICE"*) bad "claimed a double-count that does not exist: $OUT";; *) ok "does NOT claim a double-count when the archive lacks it";; esac

# ---- 4. NO FALSE POSITIVE on an indented sub-step ----------------------------------------------------
# This is the case that makes the rule usable. Such lines exist in the real tracker (W21.vmgui-c, G5) as
# finished sub-steps of entries that are themselves still open.
run '- [ ] **W4.parent — still open**
  - [x] **W4.substep — a finished sub-step inside it**
    - [x] deeper still'
[ "$RC" = 0 ] && ok "indented ticked sub-bullets are NOT flagged" || bad "flagged a legitimate sub-step: $OUT"

# ---- 5. fences and blockquotes are commentary --------------------------------------------------------
# Without this the lint would report a fenced EXAMPLE of the very bug it documents — which is exactly what
# W26.donecount's own entry contains.
run '- [ ] **W5.a — open**
```
- [x] **W5.fenced — an example of the bug, must be ignored**
```
> - [x] **W5.quoted — a quoted example, must be ignored**'
[ "$RC" = 0 ] && ok "fenced and blockquoted ticked bullets are ignored (mirrors the resolver)" || bad "fence/quote flagged: $OUT"

# ---- 6. multiple stubs are all reported --------------------------------------------------------------
run '- [x] **W6.a — one**
- [ ] **W6.b — open**
- [x] **W6.c — two**'
case "$OUT" in *"2 ticked item(s)"*) ok "counts all of them";; *) bad "bad count line: $OUT";; esac
case "$OUT" in *"W6.a"*) case "$OUT" in *"W6.c"*) ok "names each one";; *) bad "second not named: $OUT";; esac;; *) bad "first not named: $OUT";; esac

# ---- 7. quiet mode, and bad input ------------------------------------------------------------------
run '- [ ] **W7.a — open**'
OUT="$(TODO_STUBS_QUIET=1 AUTONOMOUS_TODO="$T/todo.md" AUTONOMOUS_TODO_DONE="$T/done.md" bash "$CHECK" 2>&1)"; RC=$?
[ -z "$OUT" ] && [ "$RC" = 0 ] && ok "quiet mode prints nothing when clean" || bad "quiet mode printed: '$OUT' rc=$RC"
printf -- '- [x] **W7.stub**\n' > "$T/todo.md"
OUT="$(TODO_STUBS_QUIET=1 AUTONOMOUS_TODO="$T/todo.md" AUTONOMOUS_TODO_DONE="$T/done.md" bash "$CHECK" 2>&1)"; RC=$?
[ -n "$OUT" ] && [ "$RC" = 1 ] && ok "quiet mode still reports a stub (quiet != silent about failure)" || bad "quiet mode swallowed a stub"

OUT="$(AUTONOMOUS_TODO="$T/nope.md" bash "$CHECK" 2>&1)"; RC=$?
[ "$RC" = 2 ] && ok "missing tracker -> exit 2 (not a silent pass)" || bad "missing tracker: expected 2, got $RC"

# A missing archive must degrade to "cannot confirm a double-count", not error out.
printf -- '- [x] **W8.stub**\n' > "$T/todo.md"
OUT="$(AUTONOMOUS_TODO="$T/todo.md" AUTONOMOUS_TODO_DONE="$T/nonexistent.md" bash "$CHECK" 2>&1)"; RC=$?
[ "$RC" = 1 ] && ok "a missing archive still reports the stub" || bad "missing archive broke it: rc=$RC $OUT"
case "$OUT" in *"counted TWICE"*) bad "claimed a double-count with no archive to check: $OUT";; *) ok "and makes no double-count claim it cannot support";; esac

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
