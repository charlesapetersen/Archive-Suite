#!/usr/bin/env bash
# prove-gate-report.sh — lock health-gate.sh's RED verdict to the FAILING step's output (W27.gatetail).
#
# WHY THIS EXISTS. The gate's "--- failing output ---" block is the ONLY machine-written artifact that says
# what actually broke: the daemon quotes it into daemon.log, into the ntfy/banner alert, and into
# ~/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt. Until 2026-08-08 `step()` pooled every step's output into one shared
# $LOG and the verdict printed `tail -40` of it — i.e. the tail of whichever step ran LAST. That misreported
# the owner's parks THREE times: the 2026-08-06 context-budget park (it only looked right because
# context-budget runs last), the signing/TCC gui-vm RED (it showed status-proof's "36 passed, 0 failed"), and
# the 2026-08-08 tag-vocabulary park (same "36 passed, 0 failed", under the heading "failing output"). A gate
# that misreports what it did is worse than one that says less — and this regression is SILENT: it is only
# ever observed during an incident, which is the worst possible moment to discover it.
#
# HOW. health-gate.sh has no injection seam for a step list, and running the real gate takes ~20 minutes, so
# this extracts the REAL step() / step_skippable() / RED-branch text out of health-gate.sh and drives it
# against synthetic steps. That means it tests the shipped text, not a copy that can drift.
# ⚠️ The extraction is ASSERTED, not assumed: a harness whose sed quietly matched nothing would define no
# steps, fail no assertions and "pass" forever. That is exactly the W26.lint-fu failure mode ("harnesses that
# proved nothing because nothing ran them"), so an empty or unrecognisable extraction is a FATAL, not a skip.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/../health-gate.sh"
[ -f "$GATE" ] || { echo "FATAL: health-gate.sh not found at $GATE"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

echo "== health-gate.sh failing-output report =="

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# --- extract the real text, and PROVE we extracted it -------------------------------------------
step_def="$(sed -n '/^step() {/,/^}/p'            "$GATE")"
skip_def="$(sed -n '/^step_skippable() {/,/^}/p'  "$GATE")"
red_def="$(sed  -n '/^if \[ -n "\$fails" \]; then/,/^fi/p' "$GATE")"

[ -n "$step_def" ] || { echo "FATAL: could not extract step() from $GATE"; exit 1; }
[ -n "$skip_def" ] || { echo "FATAL: could not extract step_skippable() from $GATE"; exit 1; }
[ -n "$red_def"  ] || { echo "FATAL: could not extract the RED verdict block from $GATE"; exit 1; }
case "$step_def" in *'>>"$LOG"'*) ;; *) echo "FATAL: extracted step() never appends to \$LOG — extraction is stale"; exit 1 ;; esac
case "$red_def"  in *'$LOG'*)     ;; *) echo "FATAL: extracted RED block never reads \$LOG — extraction is stale"; exit 1 ;; esac
ok "extracted the real step(), step_skippable() and RED verdict block from health-gate.sh"

# drive <scenario-file> -> the harness's stdout
drive() {
  { echo 'set -uo pipefail'
    echo 'LOG="$(mktemp)"; fails=""; skips=""; warns=""'
    printf '%s\n' "$step_def"
    printf '%s\n' "$skip_def"
    cat "$1"
    printf '%s\n' "$red_def"
    echo 'exit 0'
  } > "$T/harness.sh"
  bash "$T/harness.sh" 2>&1
}
# Only the text BELOW the "failing output" heading is the report under test. Asserting against the whole
# transcript would let a step's inline ⊘/⚠ line satisfy a "the reason is present" check.
report(){ awk '/--- failing output/{f=1;next} f'; }

# --- 1. the exact 2026-08-08 shape: an early failure, a later PASS whose tail used to be quoted -----------
cat > "$T/s1.sh" <<'EOS'
step early-FAILING bash -c 'echo "REAL-FAILURE-MARKER: ArchiveCore build broke"; exit 1'
step late-PASSING  bash -c 'echo "=========== 36 passed, 0 failed ==========="; echo "DECOY-MARKER"'
EOS
out="$(drive "$T/s1.sh")"; rep="$(printf '%s' "$out" | report)"
case "$out" in *"HEALTH GATE: RED — early-FAILING"*) ok "verdict names the failing step" ;; *) no "verdict should name early-FAILING (got: $out)" ;; esac
case "$rep" in *"REAL-FAILURE-MARKER"*)   ok "the FAILING step's output is in the report" ;; *) no "failing step's output missing from the report (got: $rep)" ;; esac
case "$rep" in *"DECOY-MARKER"*)          no "a later PASSING step's output leaked into the report — the W27.gatetail regression is back" ;; *) ok "a later PASSING step's output stays OUT of the report" ;; esac
case "$rep" in *"36 passed, 0 failed"*)   no "the report quotes a passing step's summary — this is the exact text three parks misreported" ;; *) ok "the report does not quote a passing step's summary" ;; esac
case "$rep" in *"===== early-FAILING (rc=1) ====="*) ok "the failing step's tail is banner-attributed with its rc" ;; *) no "missing '===== early-FAILING (rc=1) =====' banner (got: $rep)" ;; esac

# --- 2. EVERY failing step is reported, not just the first or the last ----------------------------------
cat > "$T/s2.sh" <<'EOS'
step first-FAIL  bash -c 'echo "FIRST-MARKER";  exit 2'
step ok-middle   bash -c 'echo "MIDDLE-DECOY"'
step second-FAIL bash -c 'echo "SECOND-MARKER"; exit 5'
EOS
out="$(drive "$T/s2.sh")"; rep="$(printf '%s' "$out" | report)"
case "$rep" in *"FIRST-MARKER"*)  ok "first of two failing steps is reported" ;;  *) no "first failing step missing (got: $rep)" ;; esac
case "$rep" in *"SECOND-MARKER"*) ok "second of two failing steps is reported" ;; *) no "second failing step missing (got: $rep)" ;; esac
case "$rep" in *"MIDDLE-DECOY"*)  no "a passing step between two failures leaked into the report" ;; *) ok "the passing step between them stays out" ;; esac
case "$rep" in *"(rc=2)"*) ok "the first step's real rc is preserved" ;; *) no "rc=2 not reported (got: $rep)" ;; esac
case "$rep" in *"(rc=5)"*) ok "the second step's real rc is preserved" ;; *) no "rc=5 not reported (got: $rep)" ;; esac

# --- 3. step_skippable: a SKIP (3) and a KNOWN-FAILURE (4) are not RED; a hard failure still reports ------
# Both are reported inline by step_skippable itself, so they must NOT also appear in the failing-output
# block — otherwise "what failed" silently grows to include what merely did not run.
cat > "$T/s3.sh" <<'EOS'
step_skippable skipper bash -c 'echo "SKIPPED: SKIPDECOY prerequisite absent"; exit 3'
step_skippable warner  bash -c 'echo "GUI-VM gate: WARN WARNDECOY"; exit 4'
step_skippable breaker bash -c 'echo "BREAKER-MARKER"; exit 1'
EOS
out="$(drive "$T/s3.sh")"; rep="$(printf '%s' "$out" | report)"
case "$out" in *"HEALTH GATE: RED — breaker"*) ok "only the hard-failing skippable step REDs the gate" ;; *) no "verdict should name breaker alone (got: $out)" ;; esac
case "$rep" in *"BREAKER-MARKER"*) ok "a hard-failing step_skippable step reports its output" ;; *) no "breaker's output missing (got: $rep)" ;; esac
case "$rep" in *"SKIPDECOY"*) no "a SKIPPED step's reason leaked into the failing-output block" ;; *) ok "a SKIPPED step contributes nothing to the failing output" ;; esac
case "$rep" in *"WARNDECOY"*) no "a KNOWN-FAILURE step's output leaked into the failing-output block" ;; *) ok "a KNOWN-FAILURE step contributes nothing to the failing output" ;; esac

# --- 4. all green: no verdict, no report ----------------------------------------------------------------
cat > "$T/s4.sh" <<'EOS'
step all-good   bash -c 'echo "GREENDECOY"'
step also-good  bash -c 'echo "fine"'
EOS
out="$(drive "$T/s4.sh")"
case "$out" in *"HEALTH GATE: RED"*)   no "an all-green run printed a RED verdict (got: $out)" ;; *) ok "an all-green run prints no RED verdict" ;; esac
case "$out" in *"failing output"*)     no "an all-green run printed a failing-output block" ;;    *) ok "an all-green run prints no failing-output block" ;; esac
case "$out" in *"GREENDECOY"*)         no "a passing step's output leaked to the gate's stdout" ;; *) ok "passing steps stay quiet on stdout" ;; esac

# --- 5. Reader's no-root deep-link regression must remain in the unit lane (W20.deeplink-isolation) -------
# The environmental exclusion once made this test invisible on machines with a saved archive bookmark. Its
# fixture-defaults seam is now safe, but deleting the skip alone is fragile: a later gate edit could quietly
# restore it. Inspect the executable `step reader` line rather than comments, then the real gate run proves
# the named XCTest executes.
echo
echo "== Reader no-root deep-link coverage is active =="
reader_step="$(grep -E '^[[:space:]]*step[[:space:]]+reader[[:space:]]' "$GATE")"
[ -n "$reader_step" ] || { echo "FATAL: could not find the executable reader step in $GATE"; exit 1; }
case "$reader_step" in
  *'-only-testing:ArchiveReaderTests'*) ok "Reader gate selects ArchiveReaderTests" ;;
  *) no "Reader gate no longer selects ArchiveReaderTests (got: $reader_step)" ;;
esac
case "$reader_step" in
  *'-skip-testing:ArchiveReaderTests/DeepLinkTests/testRevealAndSelectNoRoot'*)
    no "Reader gate excludes DeepLinkTests.testRevealAndSelectNoRoot — W20 regression coverage is disabled" ;;
  *) ok "Reader gate does not exclude DeepLinkTests.testRevealAndSelectNoRoot" ;;
esac

# --- 6. EVERY prove-*.sh is either a gate step or an explicit, honest exclusion (W26.fixwarn-fu1) ---------
#
# WHY THIS LIVES HERE. Five separate hand-sweeps wired harnesses into the gate and each one found the
# previous sweep had missed some: `f64649b` took four, W26.fixwarn a fifth, and counting them to justify the
# word "fifth" found SEVEN more that nothing ran (prove-compact.sh had been RED *and* unwatched for weeks).
# An unrun test is worse than none: it reads as coverage in review and asserts nothing at runtime. The class
# only closes if something ASSERTS the property, so harness #14 cannot land unwatched.
#
# It has to live in a step that is independently wired. Putting it in the harness it is asserting about is
# circular and inert — unwire that step and the assertion stops running too, which is precisely the failure
# being closed. This file is wired for its own unrelated reason (W27.gatetail), so it is the natural home.
echo
echo "== every prove-*.sh is watched or explicitly excluded =="

TESTS_DIR="$HERE"

# wired <gate-file> <harness-basename> — true iff the gate INVOKES it via step/step_skippable.
# A COMMENT mentioning it does not count. That is not hypothetical: on 2026-08-10 three of the seven
# unwatched harnesses had a reference a `grep -l` would have scored as wired, and all three were prose
# (archive-suite-autonomous.sh:875, prove-daemon-dispatch.sh:5, next-review-unit.sh:45).
# Conservative by construction: a step whose path is assembled from a variable reads as UNWIRED and REDs.
# That is the right direction — the RED lands on whoever just edited the gate, loudly, not on an incident.
wired() {
  local esc; esc="$(printf '%s' "$2" | sed 's/[].[^$*\\]/\\&/g')"
  grep -Eq "^[^#]*[[:space:]]*step(_skippable)?[[:space:]]+.*tests/$esc" "$1"
}

# --- 5a. the predicate has teeth: prove it before trusting its verdict on the real files ---
cat > "$T/gate-pos.sh" <<'EOG'
step synth-proof bash "$ROOT/ops/autonomous/tests/prove-synthetic.sh"
EOG
cat > "$T/gate-pos2.sh" <<'EOG'
[ "${SOME_FLAG:-1}" = 1 ] && step_skippable synth bash "$ROOT/ops/autonomous/tests/prove-synthetic.sh"
EOG
cat > "$T/gate-neg.sh" <<'EOG'
#   * prove-synthetic.sh — a real harness, described here in prose and run by nothing.
# step synth-proof bash "$ROOT/ops/autonomous/tests/prove-synthetic.sh"   <- commented out, i.e. not wired
EOG
cat > "$T/gate-neighbour.sh" <<'EOG'
step other-proof bash "$ROOT/ops/autonomous/tests/prove-synthetic-extra.sh"
EOG
if wired "$T/gate-pos.sh"  prove-synthetic.sh; then ok "predicate: a real \`step\` invocation counts as wired"; else no "predicate: missed a plain step invocation"; fi
if wired "$T/gate-pos2.sh" prove-synthetic.sh; then ok "predicate: a conditional \`step_skippable\` counts as wired"; else no "predicate: missed a conditional step_skippable"; fi
if wired "$T/gate-neg.sh"  prove-synthetic.sh; then no "predicate: a COMMENT-ONLY mention was counted as wired — the exact 2026-08-10 near-miss"; else ok "predicate: a comment-only mention does NOT count as wired"; fi
if wired "$T/gate-neighbour.sh" prove-synthetic.sh; then no "predicate: prove-synthetic-extra.sh was mistaken for prove-synthetic.sh"; else ok "predicate: a longer neighbour name is not mistaken for a shorter one"; fi

# --- 5b. the exclusion list must exist, be unique, and be machine-readable ---
MARK='# GATE-UNWATCHED-BY-DESIGN:'
n_mark="$(grep -cF "$MARK" "$GATE")"
[ "$n_mark" -ge 1 ] || { echo "FATAL: no '$MARK' line in health-gate.sh — the exclusion list is the other half of this assertion; without it every unwired harness would look like an error and the gate could not express a legitimate exclusion at all"; exit 1; }
if [ "$n_mark" = 1 ]; then ok "exactly one '$MARK' line in health-gate.sh"; else no "$n_mark '$MARK' lines — only the first is read, so the others silently exempt nothing"; fi
EXCLUDED="$(grep -F "$MARK" "$GATE" | head -1 | sed "s|^.*$MARK||")"
[ -n "$(printf '%s' "$EXCLUDED" | tr -d '[:space:]')" ] || { echo "FATAL: the '$MARK' line is empty — prove-daemon.sh at minimum belongs there"; exit 1; }

# --- 5c. the list may not lie: every name on it must exist and must NOT be wired ---
for h in $EXCLUDED; do
  if [ -f "$TESTS_DIR/$h" ]; then ok "excluded harness exists on disk: $h"
  else no "the exclusion list names $h, which is not in ops/autonomous/tests/ — a stale entry silently exempts nothing, and would hide a renamed harness"; fi
  if wired "$GATE" "$h"; then no "$h is BOTH a gate step and on the exclusion list — one of the two is wrong, and the list is what reviewers read"; else ok "excluded harness is genuinely not a step: $h"; fi
done

# --- 5d. the real property ---
# Vacuity guard first: a glob that matched nothing would pass every assertion below and prove nothing —
# the failure mode this whole harness family exists to catch. This file must be in its own enumeration.
SELF="$(basename "$0")"
n_h=0; saw_self=0; unwatched=""
for f in "$TESTS_DIR"/prove-*.sh; do
  [ -f "$f" ] || continue
  n_h=$((n_h+1)); b="$(basename "$f")"
  [ "$b" = "$SELF" ] && saw_self=1
  wired "$GATE" "$b" && continue
  case " $EXCLUDED " in *" $b "*) continue ;; esac
  unwatched="$unwatched $b"
done
[ "$n_h" -gt 0 ] || { echo "FATAL: found no prove-*.sh in $TESTS_DIR — the enumeration is broken, so section 5 proved nothing"; exit 1; }
if [ "$saw_self" = 1 ]; then ok "the enumeration reached the right directory ($n_h harnesses, including this one)"
else no "the enumeration ($n_h files) does not contain $SELF — it is looking at the wrong directory, so its verdict is meaningless"; fi
if [ -z "$unwatched" ]; then
  ok "all $n_h prove-*.sh harnesses are either a gate step or an explicitly-listed exclusion"
else
  no "harness(es) run by NOTHING and not on the exclusion list:$unwatched — wire each as a \`step\` in health-gate.sh, or add it to the '$MARK' line WITH its reason in the prose above that line. An unrun test reads as coverage and asserts nothing."
fi

echo
echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" -eq 0 ]
