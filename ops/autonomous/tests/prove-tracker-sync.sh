#!/usr/bin/env bash
# prove-tracker-sync.sh — prove the tracker-sync guard catches real drift and stays quiet otherwise.
#
# WHY THIS EXISTS. check-tracker-sync.sh exists because on 2026-08-01 the plan and SUITE_TODO disagreed
# about W21.vmgui-path and the daemon would have redone shipped work. A guard is only worth having if it
# fires on the case that actually happened AND does not fire on the many legitimate asymmetries between
# the two files — a noisy guard gets ignored, which is exactly the failure it was written to prevent.
#
# Fully sandboxed: builds its own fixture plan/todo pairs in a temp dir. Touches no real tracker.
# Read-only with respect to the repo. Safe to run anytime.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/../check-tracker-sync.sh"
[ -f "$CHECK" ] || { echo "cannot find checker at $CHECK" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# run <plan-body> <todo-body>  -> sets RC and OUT
run() {
  printf '%s\n' "$1" > "$T/plan.md"
  printf '%s\n' "$2" > "$T/todo.md"
  OUT="$(AUTONOMOUS_PLAN="$T/plan.md" AUTONOMOUS_TODO="$T/todo.md" bash "$CHECK" 2>&1)"; RC=$?
}

echo "prove-tracker-sync — drift must be loud, asymmetry must be silent"

# ---- 1. the happy path -------------------------------------------------------------------------------
run '## WORK QUEUE
- [ ] **W1.a — thing**
- [x] **W1.b — done thing**

## HOLD QUEUE' '- [ ] **W1.a — thing**
- [x] **W1.b — done thing**'
[ "$RC" = 0 ] && ok "identical trackers -> exit 0" || bad "identical trackers: expected 0, got $RC ($OUT)"
case "$OUT" in *"agree on all 2 shared items"*) ok "reports the shared-item count";; *) bad "count line missing: $OUT";; esac

# ---- 2. THE REGRESSION: the W21.vmgui-path shape (plan open, tracker done) ----------------------------
run '## WORK QUEUE
- [ ] **W21.vmgui-path — fixed interactively, never mirrored**

## HOLD QUEUE' '- [x] **W21.vmgui-path — fixed interactively, never mirrored**'
[ "$RC" = 1 ] && ok "plan OPEN + tracker DONE -> exit 1 (the 2026-08-01 regression)" || bad "expected 1, got $RC"
case "$OUT" in *"W21.vmgui-path"*) ok "names the offending item";; *) bad "item not named: $OUT";; esac
case "$OUT" in *"REDO shipped work"*) ok "says the daemon would redo shipped work";; *) bad "consequence not stated: $OUT";; esac

# ---- 3. the opposite direction ------------------------------------------------------------------------
run '## WORK QUEUE
- [x] **W2.a — thing**

## HOLD QUEUE' '- [ ] **W2.a — thing**'
[ "$RC" = 1 ] && ok "plan DONE + tracker OPEN -> exit 1" || bad "expected 1, got $RC"
case "$OUT" in *"record disagrees"*) ok "describes the reverse direction distinctly";; *) bad "reverse wording missing: $OUT";; esac

# ---- 4. legitimate asymmetry must NOT fire -------------------------------------------------------------
run '## WORK QUEUE
- [ ] **W3.a — in both**
- [ ] **W3.plan-only — daemon-side only**

## HOLD QUEUE' '- [ ] **W3.a — in both**
- [x] **W3.todo-only — long tail the daemon never sees**'
[ "$RC" = 0 ] && ok "items present in only ONE file are not drift" || bad "asymmetry wrongly flagged: $OUT"

# ---- 5. HOLD QUEUE is out of scope ---------------------------------------------------------------------
# An item parked in the hold queue is not offered as work, so its state is not the same assertion.
run '## WORK QUEUE
- [ ] **W4.a — real work**

## HOLD QUEUE
- [ ] **W4.held — owner-gated, deliberately not mirrored as done**' '- [ ] **W4.a — real work**
- [x] **W4.held — owner-gated, deliberately not mirrored as done**'
[ "$RC" = 0 ] && ok "HOLD QUEUE items are excluded from the comparison" || bad "hold-queue item wrongly compared: $OUT"

# ---- 6. code fences and blockquotes are commentary, not items ------------------------------------------
run '## WORK QUEUE
- [ ] **W5.a — real**
> - [x] **W5.a — a quoted example, must be ignored**

## HOLD QUEUE' '- [ ] **W5.a — real**
```
- [x] **W5.a — a fenced example, must be ignored**
```'
[ "$RC" = 0 ] && ok "blockquoted and fenced checkboxes are ignored (matches the resolver)" || bad "fence/quote parsed as an item: $OUT"

# ---- 7. multiple divergences are all reported ----------------------------------------------------------
run '## WORK QUEUE
- [ ] **W6.a — one**
- [ ] **W6.b — two**
- [ ] **W6.c — agrees**

## HOLD QUEUE' '- [x] **W6.a — one**
- [x] **W6.b — two**
- [ ] **W6.c — agrees**'
[ "$RC" = 1 ] && ok "multiple divergences -> exit 1" || bad "expected 1, got $RC"
case "$OUT" in *"2 of 3 shared items"*) ok "counts divergences and overlap correctly";; *) bad "bad count line: $OUT";; esac

# ---- 8. bad input is surfaced, not silently passed -----------------------------------------------------
OUT="$(AUTONOMOUS_PLAN="$T/nope.md" AUTONOMOUS_TODO="$T/todo.md" bash "$CHECK" 2>&1)"; RC=$?
[ "$RC" = 2 ] && ok "missing plan -> exit 2 (not a silent pass)" || bad "missing plan: expected 2, got $RC"

printf 'RUN STATUS: x\n- [ ] **W7.a**\n' > "$T/noqueue.md"
OUT="$(AUTONOMOUS_PLAN="$T/noqueue.md" AUTONOMOUS_TODO="$T/todo.md" bash "$CHECK" 2>&1)"; RC=$?
[ "$RC" = 2 ] && ok "plan with no '## WORK QUEUE' -> exit 2" || bad "no-queue plan: expected 2, got $RC"

# ---- 9. quiet mode stays quiet on success, loud on failure ---------------------------------------------
run '## WORK QUEUE
- [ ] **W8.a**

## HOLD QUEUE' '- [ ] **W8.a**'
OUT="$(TRACKER_SYNC_QUIET=1 AUTONOMOUS_PLAN="$T/plan.md" AUTONOMOUS_TODO="$T/todo.md" bash "$CHECK" 2>&1)"; RC=$?
[ -z "$OUT" ] && [ "$RC" = 0 ] && ok "quiet mode prints nothing when in sync" || bad "quiet mode printed: '$OUT' rc=$RC"

printf '## WORK QUEUE\n- [ ] **W8.a**\n\n## HOLD QUEUE\n' > "$T/plan.md"
printf -- '- [x] **W8.a**\n' > "$T/todo.md"
OUT="$(TRACKER_SYNC_QUIET=1 AUTONOMOUS_PLAN="$T/plan.md" AUTONOMOUS_TODO="$T/todo.md" bash "$CHECK" 2>&1)"; RC=$?
[ -n "$OUT" ] && [ "$RC" = 1 ] && ok "quiet mode still reports DRIFT (quiet != silent about failure)" || bad "quiet mode swallowed a divergence"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
