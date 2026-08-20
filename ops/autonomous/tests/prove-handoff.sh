#!/usr/bin/env bash
# prove-handoff.sh — W31.handoff-gate proof for the health-gate-safe handoff visibility check.
# The full handoff rightly rejects uncommitted worktrees and verifies publication. A health gate runs while a
# daemon session is active, so it needs only the mechanism that stops a newly filed tracker item being invisible
# to `next-queue-item.sh`: every open tag must have a primary-plan checkbox. This drives the shipped checker
# against scratch plan/tracker fixtures and blocks `git fetch` to prove the gate mode is local and deterministic.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CHECK="$ROOT/ops/autonomous/check-handoff.sh"
GATE="$ROOT/ops/autonomous/health-gate.sh"
[ -x "$CHECK" ] && [ -f "$GATE" ] || { echo "FATAL: handoff checker or health gate missing" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PLAN="$T/plan.md"
TODO="$T/todo.md"
mkdir -p "$T/bin"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

# Visibility mode must neither use the network nor enumerate worktrees. Permit every real git operation except
# those two full-handoff-only commands; a sentinel makes a mistaken call unmistakable without changing this
# checkout or its remotes.
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "${1:-}" = fetch ]; then echo FETCH-MUST-NOT-RUN >&2; exit 97; fi' \
  'if [ "${1:-}" = worktree ]; then echo WORKTREE-MUST-NOT-RUN >&2; exit 98; fi' \
  'exec /usr/bin/git "$@"' > "$T/bin/git"
chmod +x "$T/bin/git"

run() {
    set +e
    OUT="$(PATH="$T/bin:$PATH" HANDOFF_MODE=visibility AUTONOMOUS_PLAN="$PLAN" AUTONOMOUS_TODO="$TODO" bash "$CHECK" 2>&1)"
    RC=$?
    set -e
}

echo "== handoff visibility gate =="

printf '## WORK QUEUE\n- [ ] **W31.visible — mirrored work**\n\n## HOLD QUEUE\n' > "$PLAN"
printf -- '- [ ] **W31.visible — mirrored work**\n' > "$TODO"
run
[ "$RC" = 0 ] && ok "a mirrored open tracker item passes" || no "mirrored item failed: rc=$RC $OUT"
case "$OUT" in *'HANDOFF VISIBILITY: CLEAN'*) ok "success names the limited visibility mode";; *) no "missing visibility success: $OUT";; esac
case "$OUT" in *FETCH-MUST-NOT-RUN*) no "visibility mode attempted a network fetch";; *) ok "visibility mode does not fetch origin";; esac
case "$OUT" in *WORKTREE-MUST-NOT-RUN*) no "visibility mode inspected worktrees";; *) ok "visibility mode leaves active worktrees to the final handoff";; esac

printf '## WORK QUEUE\n\n## HOLD QUEUE\n' > "$PLAN"
printf -- '- [ ] **W31.missing — filed but unmirrored**\n' > "$TODO"
run
[ "$RC" = 1 ] && ok "an unmirrored tracker item fails the gate" || no "unmirrored item rc=$RC: $OUT"
case "$OUT" in *'NO checkbox line in the plan'*W31.missing*) ok "the failure names the invisible tag";; *) no "missing-plan diagnostic lost its tag: $OUT";; esac

rm -f "$PLAN"
run
[ "$RC" = 1 ] && ok "a missing primary plan fails visibility mode" || no "missing plan rc=$RC: $OUT"
case "$OUT" in *'the daemon has nowhere to see newly filed work'*) ok "missing-plan failure explains the daemon impact";; *) no "missing-plan reason absent: $OUT";; esac

printf '## WORK QUEUE\n\n## HOLD QUEUE\n' > "$PLAN"
printf -- '- [ ] **(later) unnamed work**\n' > "$TODO"
run
[ "$RC" = 1 ] && ok "an unparseable open tracker item fails visibility mode" || no "unparseable item rc=$RC: $OUT"
case "$OUT" in *'UNPARSEABLE OPEN ITEM'*) ok "unparseable item is named rather than silently skipped";; *) no "unparseable diagnostic absent: $OUT";; esac

set +e
OUT="$(HANDOFF_MODE=not-a-mode bash "$CHECK" 2>&1)"
RC=$?
set -e
[ "$RC" = 2 ] && ok "an invalid handoff mode is rejected" || no "invalid mode rc=$RC: $OUT"

handoff_steps="$(grep -Ec '^step handoff[[:space:]]+env HANDOFF_MODE=visibility bash "\$ROOT/ops/autonomous/check-handoff.sh"$' "$GATE" || true)"
[ "$handoff_steps" = 1 ] && ok "health gate wires exactly one visibility-only handoff step" || no "expected one visibility handoff step, found $handoff_steps"
proof_steps="$(grep -Ec '^step handoff-proof[[:space:]]+bash "\$ROOT/ops/autonomous/tests/prove-handoff.sh"$' "$GATE" || true)"
[ "$proof_steps" = 1 ] && ok "the proof is itself wired into the health gate" || no "prove-handoff is not a unique gate step"

echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" -eq 0 ]
