#!/usr/bin/env bash
# prove-context-budget.sh — lock context-budget.sh's CONTRACT WITH THE DAEMON (WS13, 2026-08-12).
#
# WHY THIS EXISTS. As of 2026-08-12 the daemon's doc pre-gate (doc_pregate() in archive-suite-autonomous.sh)
# decides what to repair by PARSING this script's output. Before that, the output was for a human to read and a
# drifting format cost nothing; now a silently-renamed field means the pre-gate sees no over-budget file, queues
# no trim, and the run parks for a document problem it was built to fix — which is exactly the class of silent
# failure the budget guard itself was written for (see this script's sibling, context-budget.sh's header).
#
# It also locks the ONE INVARIANT that makes the total meaningful: $ORIENT_TOTAL must stay TIGHTER than the sum
# of the per-file budgets for the same set. Nothing else enforces that, and it is trivially broken by raising a
# per-file budget "just a little" — after which aggregate creep has no guard at all and the total is decoration.
#
# Fixtures only: builds a synthetic ROOT with files of controlled sizes and runs the REAL script against it.
# No daemon, no network, no repo state. Instant.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../context-budget.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: context-budget.sh not found at $SCRIPT"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# fill <path> <bytes> — a file of EXACTLY n bytes.
fill() {
  local p="$1" n="$2"
  mkdir -p "$(dirname "$p")"
  : > "$p"
  [ "$n" -gt 0 ] && head -c "$n" /dev/zero | tr '\0' 'x' > "$p"
  return 0
}

# The per-file budgets live in the script, so read them back rather than duplicating the numbers here — a
# harness that hardcodes them would pass while the script and the daemon disagreed.
budget_of() { sed -n '/^BUDGETS=\$(cat <<.EOF./,/^EOF/p' "$SCRIPT" | awk -F'\t' -v k="$1" '$1==k{print $2; exit}'; }

CLAUDE_B="$(budget_of CLAUDE.md)"
AGENTS_B="$(budget_of AGENTS.md)"
case "$CLAUDE_B" in ''|*[!0-9]*) echo "FATAL: could not read CLAUDE.md's budget out of $SCRIPT — the BUDGETS block moved, so every assertion below would be vacuous"; exit 1 ;; esac
case "$AGENTS_B" in ''|*[!0-9]*) echo "FATAL: could not read AGENTS.md's budget out of $SCRIPT"; exit 1 ;; esac
ok "read the real per-file budgets out of the script (CLAUDE.md=$CLAUDE_B, AGENTS.md=$AGENTS_B)"

# run <root> -> stdout+stderr; sets RC
run() { OUT="$(bash "$SCRIPT" "$1" 2>&1)"; RC=$?; }

echo "== 1. a file OVER budget: exit 1 + a machine-readable OVER line the daemon can parse =="
R="$T/r1"; mkdir -p "$R"
fill "$R/CLAUDE.md" $(( CLAUDE_B + 500 ))
run "$R"
[ "$RC" = 1 ] && ok "exit 1 when a document is over budget" || no "expected exit 1, got $RC"
# The pre-gate's parser: $1=="context-budget:" && $2=="OVER" -> $3 is the path. Assert that exact shape.
got="$(printf '%s\n' "$OUT" | awk '$1=="context-budget:" && $2=="OVER"{print $3}')"
[ "$got" = "CLAUDE.md" ] && ok "emits 'context-budget: OVER CLAUDE.md …' in the field order doc_pregate parses" \
  || no "the OVER line does not parse to the path (got '$got')"
printf '%s\n' "$OUT" | grep -q "^context-budget: OVER CLAUDE.md $(( CLAUDE_B + 500 )) $CLAUDE_B$" \
  && ok "the OVER line carries bytes and budget too" || no "OVER line is missing the bytes/budget fields"
# the human line the health gate quotes into the park note must survive alongside it
printf '%s\n' "$OUT" | grep -q '✗ context-budget: OVER budget: CLAUDE.md' \
  && ok "the human 'OVER budget:' line is unchanged (the gate report and park note quote it)" \
  || no "the human OVER line changed — health-gate.sh's report and the park note both quote it verbatim"

echo
echo "== 2. the NEAR tier (>=ACT_PCT) — what the daemon trims PRE-EMPTIVELY so nothing ever parks =="
R="$T/r2"; mkdir -p "$R"
fill "$R/CLAUDE.md" $(( CLAUDE_B * 95 / 100 ))     # 95% -> above the default ACT_PCT of 93
run "$R"
[ "$RC" = 0 ] && ok "a NEAR file is NOT a failure (exit 0)" || no "NEAR must not fail the gate, got exit $RC"
printf '%s\n' "$OUT" | grep -q "^context-budget: NEAR CLAUDE.md " \
  && ok "emits a NEAR line at 95% of budget" || no "no NEAR line at 95% (got: $(printf '%s' "$OUT" | tail -4))"
printf '%s\n' "$OUT" | grep -q "^context-budget: OVER " \
  && no "a NEAR file was also reported OVER" || ok "NEAR is not also reported as OVER"

echo
echo "== 3. the WARN tier (>=WARN_PCT, <ACT_PCT) is visible but NOT actioned =="
R="$T/r3"; mkdir -p "$R"
fill "$R/CLAUDE.md" $(( CLAUDE_B * 88 / 100 ))     # 88% -> warn band, below ACT_PCT
run "$R"
[ "$RC" = 0 ] && ok "a WARN file is not a failure" || no "WARN must not fail the gate, got exit $RC"
printf '%s\n' "$OUT" | grep -q "^context-budget: WARN CLAUDE.md " \
  && ok "emits WARN at 88%" || no "no WARN line at 88%"
printf '%s\n' "$OUT" | grep -q "^context-budget: NEAR " \
  && no "88% was escalated to NEAR — the daemon would spend a session on a file that is fine" \
  || ok "88% is NOT escalated to NEAR (no pre-emptive session for a file with real headroom)"

echo
echo "== 4. a missing document is skipped, not an error (budgets outlive the files they name) =="
R="$T/r4"; mkdir -p "$R"
fill "$R/AGENTS.md" 100
run "$R"
[ "$RC" = 0 ] && ok "absent documents are skipped" || no "an absent document broke the check (exit $RC)"
printf '%s\n' "$OUT" | grep -q "CLAUDE.md" \
  && no "reported a document that does not exist" || ok "does not report a document that is not there"

echo
echo "== 5. the TOTAL is checked, and reported in a parseable line =="
R="$T/r5"; mkdir -p "$R"
fill "$R/CLAUDE.md" 1000
run "$R"
printf '%s\n' "$OUT" | grep -qE "^context-budget: TOTAL (OK|WARN|OVER) [0-9]+ [0-9]+$" \
  && ok "emits 'context-budget: TOTAL <state> <sum> <budget>'" || no "no parseable TOTAL line"
tstate="$(printf '%s\n' "$OUT" | awk '$1=="context-budget:" && $2=="TOTAL"{print $3; exit}')"
[ "$tstate" = "OK" ] && ok "a tiny tree reports TOTAL OK" || no "expected TOTAL OK, got '$tstate'"
# …and a total blowout fails even when every individual file is within its own budget.
R="$T/r6"; mkdir -p "$R"
fill "$R/CLAUDE.md" $(( CLAUDE_B - 100 ))
fill "$R/AGENTS.md" $(( AGENTS_B - 100 ))
ORIENT_TOTAL=1000 run_out="$(ORIENT_TOTAL=1000 bash "$SCRIPT" "$R" 2>&1)"; rc6=$?
[ "$rc6" = 1 ] && ok "a TOTAL overage fails even with every file inside its own budget" \
  || no "the total did not fail when exceeded (exit $rc6) — rule 1 is not enforced"
printf '%s\n' "$run_out" | grep -q "^context-budget: TOTAL OVER " \
  && ok "emits TOTAL OVER so the daemon can name the cause" || no "no TOTAL OVER line on a total overage"
printf '%s\n' "$run_out" | grep -q "Shrink a TRACKER" \
  && ok "the total's remedy points at the trackers, not the prose guides" || no "no tracker remedy on a total overage"

echo
echo "== 6. RULE 1 INVARIANT: ORIENT_TOTAL must stay TIGHTER than the sum of the same set's per-file budgets =="
# This is the assertion that keeps the total honest. Raise a per-file budget without re-checking the total and
# the gap closes silently; once the sum drops below the total, NOTHING guards aggregate creep and rule 1 is a
# comment. It is checked statically, against the shipped numbers, so it fails on the commit that breaks it.
always="$(grep -m1 '^ORIENT_ALWAYS=' "$SCRIPT" | sed 's/^ORIENT_ALWAYS="//; s/"$//')"
guides="$(grep -m1 '^ORIENT_APP_GUIDES=' "$SCRIPT" | sed 's/^ORIENT_APP_GUIDES="//; s/"$//')"
otot="$(grep -m1 '^ORIENT_TOTAL=' "$SCRIPT" | sed 's/.*:-\([0-9]*\)}.*/\1/')"
[ -n "$always" ] && [ -n "$guides" ] || { echo "FATAL: could not read ORIENT_ALWAYS/ORIENT_APP_GUIDES out of $SCRIPT"; exit 1; }
case "$otot" in ''|*[!0-9]*) echo "FATAL: could not read ORIENT_TOTAL out of $SCRIPT"; exit 1 ;; esac
sum=0; n_always=0
for f in $always; do
  b="$(budget_of "$f")"
  case "$b" in ''|*[!0-9]*) no "ORIENT_ALWAYS names '$f', which has no per-file budget — the total would silently undercount it"; continue ;; esac
  sum=$(( sum + b )); n_always=$(( n_always + 1 ))
done
[ "$n_always" -gt 0 ] && ok "every ORIENT_ALWAYS document has a per-file budget ($n_always of them)" || no "ORIENT_ALWAYS resolved to nothing"
big=0
for f in $guides; do
  b="$(budget_of "$f")"
  case "$b" in ''|*[!0-9]*) no "ORIENT_APP_GUIDES names '$f', which has no per-file budget"; continue ;; esac
  [ "$b" -gt "$big" ] && big="$b"
done
sum=$(( sum + big ))
if [ "$otot" -lt "$sum" ]; then
  ok "ORIENT_TOTAL ($otot) is tighter than the sum of the set's budgets ($sum) — aggregate creep still fails"
else
  no "ORIENT_TOTAL ($otot) is >= the sum of the per-file budgets ($sum): every file could be maxed and the total would still pass, so rule 1 guards nothing. Lower ORIENT_TOTAL or lower a per-file budget."
fi

echo
echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" -eq 0 ]
