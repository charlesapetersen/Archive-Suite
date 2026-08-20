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
  : > "$T/done.md"
  OUT="$(AUTONOMOUS_PLAN="$T/plan.md" AUTONOMOUS_TODO="$T/todo.md" AUTONOMOUS_TODO_DONE="$T/done.md" bash "$CHECK" 2>&1)"; RC=$?
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

# ---- 4. asymmetry: todo-only is silent, plan-only ACTIONABLE is untracked work -------------------------
# A SUITE_TODO item the daemon never sees is normal (long tail). A plan item the daemon WILL offer with no
# tracker entry is not — that is the W16.cfg6-fu2 shape, filed in the plan on 2026-08-01 and missed here.
run '## WORK QUEUE
- [ ] **W3.a — in both**

## HOLD QUEUE' '- [ ] **W3.a — in both**
- [x] **W3.todo-only — long tail the daemon never sees**'
[ "$RC" = 0 ] && ok "a SUITE_TODO-only item is not drift (long tail)" || bad "todo-only wrongly flagged: $OUT"

run '## WORK QUEUE
- [ ] **W3.a — in both**
- [ ] **W3.plan-only — actionable, but absent from the tracker**

## HOLD QUEUE' '- [ ] **W3.a — in both**'
[ "$RC" = 1 ] && ok "a plan-only ACTIONABLE item is reported as untracked (W16.cfg6-fu2 shape)" \
              || bad "untracked actionable item not reported: rc=$RC $OUT"
case "$OUT" in *"W3.plan-only"*) ok "names the untracked item";; *) bad "not named: $OUT";; esac
case "$OUT" in *"NO entry in SUITE_TODO"*) ok "says what is wrong with it";; *) bad "no explanation: $OUT";; esac

# A DONE plan item that is absent from the tracker is history, not untracked work — must stay quiet.
run '## WORK QUEUE
- [x] **W3.oldwork — finished long ago, never mirrored**

## HOLD QUEUE' '- [ ] **W3.a — unrelated**'
[ "$RC" = 0 ] && ok "a DONE plan-only item is history, not untracked work" || bad "done plan-only flagged: $OUT"

# Milestone markers and prose bullets are legitimately plan-only — only tags shaped like item IDs count.
run '## WORK QUEUE
- [ ] **Waves 13-23 COMPLETE** — a milestone marker, not an item

## HOLD QUEUE' '- [ ] **W3.a — unrelated**'
[ "$RC" = 0 ] && ok "a dotless milestone marker is not treated as untracked work" || bad "marker flagged: $OUT"

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
OUT="$(TRACKER_SYNC_QUIET=1 AUTONOMOUS_PLAN="$T/plan.md" AUTONOMOUS_TODO="$T/todo.md" AUTONOMOUS_TODO_DONE="$T/done.md" bash "$CHECK" 2>&1)"; RC=$?
[ -z "$OUT" ] && [ "$RC" = 0 ] && ok "quiet mode prints nothing when in sync" || bad "quiet mode printed: '$OUT' rc=$RC"

printf '## WORK QUEUE\n- [ ] **W8.a**\n\n## HOLD QUEUE\n' > "$T/plan.md"
printf -- '- [x] **W8.a**\n' > "$T/todo.md"
OUT="$(TRACKER_SYNC_QUIET=1 AUTONOMOUS_PLAN="$T/plan.md" AUTONOMOUS_TODO="$T/todo.md" bash "$CHECK" 2>&1)"; RC=$?
[ -n "$OUT" ] && [ "$RC" = 1 ] && ok "quiet mode still reports DRIFT (quiet != silent about failure)" || bad "quiet mode swallowed a divergence"

# ---- 10. malformed open items must be LOUD, not absent from the comparison -----------------------------
# `**(later)**` was a real live entry in 2026-08-16. Its punctuation first character did not match the tag
# grammar, so neither side emitted it and a green equality check proved an empty set instead of the tracker.
run '## WORK QUEUE
- [ ] **W10.valid — visible work**

## HOLD QUEUE' '- [ ] **W10.valid — visible work**
- [ ] **(later)** behavior/data follow-on with no tag'
[ "$RC" = 1 ] && ok "punctuation-led open item -> exit 1 (not a silent equality)" || bad "unparseable item expected rc=1, got $RC"
case "$OUT" in *"UNPARSEABLE ITEM"*) ok "names the malformed-item condition";; *) bad "unparseable condition missing: $OUT";; esac
case "$OUT" in *"**(later)** behavior/data follow-on with no tag"*) ok "prints the offending source line";; *) bad "offending line missing: $OUT";; esac

# A pre-consolidation DONE archive entry can be historically malformed but cannot be offered by the daemon;
# only OPEN items are a current handoff defect. This prevents a stale archival shape from drowning out one live
# error (the two have opposite remedies).
printf '## WORK QUEUE\n- [ ] **W10.valid — visible work**\n\n## HOLD QUEUE\n' > "$T/plan.md"
printf -- '- [ ] **W10.valid — visible work**\n' > "$T/todo.md"
printf -- '- [x] **⌘0 = historical done notation**\n' > "$T/done.md"
OUT="$(AUTONOMOUS_PLAN="$T/plan.md" AUTONOMOUS_TODO="$T/todo.md" AUTONOMOUS_TODO_DONE="$T/done.md" bash "$CHECK" 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "historical DONE punctuation remains out of the open-item guard" || bad "done archive item incorrectly failed: $OUT"

# ---- 11. THE ARCHIVE IS PART OF THE SAME TRACKER ------------------------------------------------------
# Regression: splitting done items into SUITE_TODO_DONE.md (consolidation phase 2) dropped coverage from 100
# shared items to 34 and made the guard's founding case invisible — "[x] in the tracker" now often means
# "lives in the archive", so comparing SUITE_TODO alone can never see it.
printf '## WORK QUEUE\n- [ ] **W9.archived — shipped, then archived**\n\n## HOLD QUEUE\n' > "$T/plan.md"
printf -- '- [ ] **W9.other — unrelated live item**\n' > "$T/todo.md"
printf -- '- [x] **W9.archived — shipped, then archived**\n' > "$T/done.md"
OUT="$(AUTONOMOUS_PLAN="$T/plan.md" AUTONOMOUS_TODO="$T/todo.md" AUTONOMOUS_TODO_DONE="$T/done.md" bash "$CHECK" 2>&1)"; RC=$?
[ "$RC" = 1 ] && ok "an item archived in SUITE_TODO_DONE is still compared (phase-2 regression)" \
              || bad "archived item invisible to the guard: rc=$RC $OUT"
case "$OUT" in *"W9.archived"*) ok "names the archived item";; *) bad "archived item not named: $OUT";; esac

# ...and a live entry must win over a stale archived twin, so re-opened work isn't judged by its old state.
printf -- '- [ ] **W9.reopened — re-opened after shipping**\n' > "$T/todo.md"
printf -- '- [x] **W9.reopened — the stale archived twin**\n' > "$T/done.md"
printf '## WORK QUEUE\n- [ ] **W9.reopened — re-opened after shipping**\n\n## HOLD QUEUE\n' > "$T/plan.md"
OUT="$(AUTONOMOUS_PLAN="$T/plan.md" AUTONOMOUS_TODO="$T/todo.md" AUTONOMOUS_TODO_DONE="$T/done.md" bash "$CHECK" 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "a live entry outranks a stale archived twin (no false drift)" \
              || bad "stale archive twin caused false drift: $OUT"

# ...and the archive being absent must be a no-op, so this works before the split too.
printf '## WORK QUEUE\n- [ ] **W9.plain**\n\n## HOLD QUEUE\n' > "$T/plan.md"
printf -- '- [ ] **W9.plain**\n' > "$T/todo.md"
OUT="$(AUTONOMOUS_PLAN="$T/plan.md" AUTONOMOUS_TODO="$T/todo.md" AUTONOMOUS_TODO_DONE="$T/nonexistent.md" bash "$CHECK" 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "a missing archive is a no-op, not an error" || bad "missing archive broke it: rc=$RC $OUT"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
