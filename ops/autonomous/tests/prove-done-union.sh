#!/usr/bin/env bash
# prove-done-union.sh — prove SUITE_TODO_DONE.md's append-only + `merge=union` rule merges two workers'
# completions with no conflict and no interleaved entry, and that the readers still find an appended entry.
#
# WHY THIS EXISTS (W35.done-union). Two workers finishing at once both used to insert into the middle of a
# 1 MB file, under their sections, and met in a rebase conflict. Appending at the end plus `merge=union` turns
# that collision into "keep both". Union has one trap, found while building this: before taking both sides it
# trims lines COMMON to both — so two entries that END with the same sentence ("No real corpus was touched.")
# lose that line from one of them and the other entry swallows it. Hence the rule that every entry ends with
# its own `<!-- /TAG -->` line: a unique last line leaves nothing to trim. Case 3 below is the trap, kept as a
# regression; case 1 is the rule holding.
#
# Fully sandboxed: scratch repos in a temp dir, the REAL .gitattributes copied in. Touches no real tracker.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
[ -f "$ROOT/.gitattributes" ] || { echo "no .gitattributes at $ROOT" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; FAIL=$((FAIL+1)); }

# entry <tag> <specific-line> [terminate=1] — an entry whose middle AND (without a terminator) last lines are
# identical to every other entry's: the worst case for union's common-line trimming.
entry() {
  printf '\n- [x] **%s — title** · §Some section · SHIPPED 2026-10-08 (abc1234)\n' "$1"
  printf '  - Verification: clean build; no new warnings.\n  - %s\n  - No real corpus was touched.\n' "$2"
  [ "${3:-1}" = 1 ] && printf '  <!-- /%s -->\n' "$1"
}

# scratch <dir> — a repo with the real attributes and a done file that already has an appended entry.
scratch() {
  git init -q "$1" && cd "$1" || exit 1
  git config user.email t@t; git config user.name t; git config commit.gpgsign false
  cp "$ROOT/.gitattributes" .
  { printf '# done\n\n## Old section\n\n- [x] **OLD.1 — legacy** SHIPPED\n\n## Appended\n'; entry A.0 base-specific; } > SUITE_TODO_DONE.md
  git add -A && git commit -qm base
  BASE="$(git branch --show-current)"
}

# block <file> <tag> — the entry's lines, header through terminator, if they are contiguous and in order.
block() { awk -v t="$2" 'index($0, "**" t " ")==7 {on=1} on {print} on && $0 == "  <!-- /" t " -->" {exit}' "$1"; }

# twoway <mode> <terminate> — B.1 and B.2 append on separate branches; join them by merge or rebase.
twoway() {
  local d="$T/$1-$2"; ( scratch "$d"
    git checkout -qb b1; entry B.1 one-specific "$2" >> SUITE_TODO_DONE.md; git commit -qam b1
    git checkout -q "$BASE"; git checkout -qb b2; entry B.2 two-specific "$2" >> SUITE_TODO_DONE.md; git commit -qam b2
    if [ "$1" = merge ]; then git merge -q --no-edit b1 >/dev/null 2>&1; else git checkout -q b1; git rebase -q b2 >/dev/null 2>&1; fi
    echo "rc=$?"; cat SUITE_TODO_DONE.md ) > "$T/out" 2>&1
  RC="$(sed -n 1p "$T/out" | cut -d= -f2)"; sed 1d "$T/out" > "$T/merged.md"
}

echo "prove-done-union — two appended completions must union-merge whole, and readers must find them"

# ---- 0. the attribute is really in force ----------------------------------------------------------------
( cd "$ROOT" && git check-attr merge -- SUITE_TODO_DONE.md ) | grep -q 'merge: union' \
  && ok "SUITE_TODO_DONE.md has merge=union in the repo's .gitattributes" || bad "attribute not set"

# ---- 1. the rule: terminated entries, merge and rebase --------------------------------------------------
for mode in merge rebase; do
  twoway "$mode" 1
  [ "$RC" = 0 ] && ! grep -q '^<<<<<<<\|^>>>>>>>' "$T/merged.md" \
    && ok "$mode: two appended entries join with no conflict" || bad "$mode: conflict (rc=$RC)" "$(cat "$T/merged.md")"
  for t in B.1 B.2 A.0; do
    want="$(entry "$t" "$( [ $t = B.1 ] && echo one || { [ $t = B.2 ] && echo two || echo base; }; )-specific" | sed 1d)"
    [ "$(block "$T/merged.md" "$t")" = "$want" ] && ok "$mode: $t is whole, contiguous and in order" \
      || bad "$mode: $t interleaved or damaged" "$(cat "$T/merged.md")"
  done
  grep -q '^- \[x\] \*\*OLD.1 — legacy' "$T/merged.md" && ok "$mode: the pre-existing entries are untouched" \
    || bad "$mode: old content lost"
done

# ---- 2. readers find an appended entry by tag, wherever it sits ------------------------------------------
twoway merge 1; cp "$T/merged.md" "$T/done.md"
printf '## WORK QUEUE\n- [ ] **W.dep — needs B.2** (blocked-on: B.2)\n- [x] **B.1 — one**\n## HOLD QUEUE\n' > "$T/plan.md"
printf '# todo\n- [ ] **W.dep — needs B.2** (blocked-on: B.2)\n' > "$T/todo.md"
out="$(AUTONOMOUS_PLAN="$T/plan.md" AUTONOMOUS_SUITE_TODO="$T/todo.md" AUTONOMOUS_SUITE_TODO_DONE="$T/done.md" \
  bash "$ROOT/ops/autonomous/next-queue-item.sh" "$T" 2>&1)"
printf '%s\n' "$out" | awk -F'\t' '$1=="ok" && $2=="W.dep"' | grep -q . && ok "next-queue-item: a prerequisite appended at EOF resolves as done" \
  || bad "next-queue-item did not resolve B.2" "$out"
out="$(AUTONOMOUS_PLAN="$T/plan.md" AUTONOMOUS_TODO="$T/todo.md" AUTONOMOUS_TODO_DONE="$T/done.md" \
  bash "$ROOT/ops/autonomous/check-tracker-sync.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "check-tracker-sync: an appended [x] agrees with the plan's [x]" || bad "check-tracker-sync rc=$rc" "$out"
printf '## WORK QUEUE\n- [ ] **B.1 — one**\n## HOLD QUEUE\n' > "$T/plan2.md"
AUTONOMOUS_PLAN="$T/plan2.md" AUTONOMOUS_TODO="$T/todo.md" AUTONOMOUS_TODO_DONE="$T/done.md" \
  bash "$ROOT/ops/autonomous/check-tracker-sync.sh" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "check-tracker-sync: an appended [x] is still compared (drift caught)" || bad "drift not caught, rc=$rc"
n="$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[[xX]\]' "$T/done.md")"
[ "$n" = 4 ] && ok "completion count sees all four entries (archive-suite-autonomous.sh's pattern)" || bad "count=$n, want 4"
n="$(grep -cE '^- \[x\] \*\*[A-Za-z][A-Za-z0-9.-]*[0-9][A-Za-z0-9.-]*[[:space:]*`]' "$T/done.md")"
[ "$n" = 4 ] && ok "measure-workers' entry pattern matches every appended header" || bad "measure-workers pattern matched $n, want 4"

# ---- 3. regression: WITHOUT the unique last line, union trims the shared tail into one entry -------------
twoway merge 0
b2="$(awk '/\*\*B.2 /{on=1;next} on && /^- \[x\]/{exit} on' "$T/merged.md")"
printf '%s\n' "$b2" | grep -q 'No real corpus' \
  && bad "unterminated entries merged whole — the trap this rule guards is gone; re-check the rule's wording" \
  || ok "unterminated entries DO lose a shared last line (why every entry ends with <!-- /TAG -->)"

echo "prove-done-union: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
