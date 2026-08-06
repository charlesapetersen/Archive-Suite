#!/usr/bin/env bash
# prove-compact.sh — regression harness for compact-plan.sh (Session Log + Daemon Report rotation).
#
# Builds synthetic AUTONOMOUS_PLAN.md fixtures in a sandbox and runs the REAL compact-plan.sh against
# them, asserting: old entries archived / recent kept, every OTHER section byte-identical, live anchors
# survive, idempotency, under-trigger no-ops, and — the WS8 subshell contract — that Daemon Report
# rotates even when the Session Log pass no-ops. No network, no real plan, no daemon.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../compact-plan.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: compact-plan.sh not found at $SCRIPT"; exit 1; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
chk(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }

# ---- fixture builder: $1=#sessionlog entries  $2=#daemon-report entries  -> writes $SANDBOX/plan.md ----
make_plan(){
  local nlog="$1" nmr="$2" f="$SANDBOX/plan.md" i
  rm -f "$f" "$f.bak"   # fresh fixture — the path is reused across cases
  {
    echo "# AUTONOMOUS_PLAN"
    echo ""
    echo "RUN STATUS: IN_PROGRESS"
    echo ""
    echo "## PRIME DIRECTIVES"
    echo "- never work in the primary checkout"
    echo ""
    echo "## RESUME PROTOCOL"
    echo "1. read this plan"
    echo ""
    echo "## WORK QUEUE"
    echo "- [ ] WS8 rotate daemon report"
    echo "- [x] WS5 status digest"
    echo ""
    echo "## Session Log"
    # chronological: oldest first, newest last (matches real plan). (`seq 1 0` emits "1 0" on BSD — guard it.)
    [ "$nlog" -ge 1 ] && for i in $(seq 1 "$nlog"); do echo "- SLOG entry $i"; done
    echo ""
    echo "## Daemon Report"
    echo ""
    echo "(section preamble that must survive)"
    echo ""
    # newest-first: entry 1 = newest (top), entry $nmr = oldest (bottom) — matches real plan
    [ "$nmr" -ge 1 ] && for i in $(seq 1 "$nmr"); do
      echo "**[2026-07-$(printf '%02d' $i)] MR entry $i — headline.**"
      echo "- detail bullet for entry $i"
      echo "sub-line for entry $i"
      echo ""
    done
    # optional 3rd arg: append a section AFTER Daemon Report (exercises the after-region tail splice)
    if [ -n "${3:-}" ]; then
      echo "## E2E findings"
      echo "- trailing section line A"
      echo "- trailing section line B"
    fi
  } > "$f"
  echo "$f"
}

run(){ AUTONOMOUS_PLAN="$1" AUTONOMOUS_SESSION_ARCHIVE="$SANDBOX/slog-arch.md" \
       AUTONOMOUS_DR_ARCHIVE="${MRARCH:-$SANDBOX/mr-arch.md}" \
       KEEP="${KEEP:-12}" TRIGGER="${TRIGGER:-40}" DR_KEEP="${DR_KEEP:-15}" DR_TRIGGER="${DR_TRIGGER:-25}" \
       bash "$SCRIPT" "$SANDBOX" >"$SANDBOX/out.txt" 2>&1; }

section(){ # print lines of a '## X' section (exclusive of next '## ') from file $1, header $2
  awk -v hdr="$2" 'BEGIN{p=0} $0 ~ ("^## " hdr){p=1;next} p&&/^## /{p=0} p' "$1"; }

echo "== compact-plan.sh regression =="

# ---------- Case A: both sections over trigger ----------
PLAN="$(make_plan 60 40)"
cp "$PLAN" "$SANDBOX/pre.md"
run "$PLAN"

chk "A slog archived down to KEEP=12"        "[ \"\$(grep -c '^- SLOG entry ' '$PLAN')\" = 12 ]"
chk "A slog kept the NEWEST (entry 60)"       "grep -q '^- SLOG entry 60$' '$PLAN'"
chk "A slog dropped the OLDEST (entry 1)"     "! grep -q '^- SLOG entry 1$' '$PLAN'"
chk "A slog oldest went to archive"           "grep -q '^- SLOG entry 1$' '$SANDBOX/slog-arch.md'"
chk "A MR archived down to DR_KEEP=15"         "[ \"\$(grep -c '^\\*\\*\\[' '$PLAN')\" = 15 ]"
chk "A MR kept the NEWEST (entry 1, top)"      "grep -q 'MR entry 1 —' '$PLAN'"
chk "A MR dropped an OLD entry (entry 40)"     "! grep -q 'MR entry 40 —' '$PLAN'"
chk "A MR old entry+sublines went to archive"  "grep -q 'MR entry 40 —' '$SANDBOX/mr-arch.md' && grep -q 'sub-line for entry 40' '$SANDBOX/mr-arch.md'"
chk "A MR preamble survived inline"            "grep -q 'section preamble that must survive' '$PLAN'"
# every non-log/non-MR section byte-identical to the pre-image
for s in "PRIME DIRECTIVES" "RESUME PROTOCOL" "WORK QUEUE"; do
  chk "A section '$s' byte-identical" "diff -q <(section '$SANDBOX/pre.md' '$s') <(section '$PLAN' '$s') >/dev/null"
done
chk "A RUN STATUS survived"                    "grep -q '^RUN STATUS: IN_PROGRESS' '$PLAN'"
chk "A .bak was written"                       "[ -f '$PLAN.bak' ]"

# idempotency: a second run is a no-op on both sections
cp "$PLAN" "$SANDBOX/after1.md"
run "$PLAN"
chk "A idempotent (plan unchanged on 2nd run)" "diff -q '$SANDBOX/after1.md' '$PLAN' >/dev/null"

# ---------- Case B: Session Log UNDER trigger, Daemon Report OVER — MR must still rotate ----------
PLAN="$(make_plan 5 40)"
run "$PLAN"
chk "B slog untouched (under trigger)"         "[ \"\$(grep -c '^- SLOG entry ' '$PLAN')\" = 5 ]"
chk "B MR still rotated to 15 (Pass 2 ran)"     "[ \"\$(grep -c '^\\*\\*\\[' '$PLAN')\" = 15 ]"
chk "B slog no-op logged"                      "grep -q 'Session Log entries <= trigger' '$SANDBOX/out.txt'"

# ---------- Case C: both UNDER trigger — total no-op ----------
PLAN="$(make_plan 5 5)"
cp "$PLAN" "$SANDBOX/preC.md"
run "$PLAN"
chk "C total no-op (plan unchanged)"           "diff -q '$SANDBOX/preC.md' '$PLAN' >/dev/null"
chk "C no MR .bak created"                      "[ ! -f '$PLAN.bak' ]"

# ---------- Case D: no Daemon Report header at all — Pass 2 skips cleanly ----------
PLAN="$(make_plan 60 0)"
# make_plan still emits the '## Daemon Report' header; strip it to simulate an old plan
grep -v '^## Daemon Report' "$PLAN" > "$PLAN.tmp" && mv "$PLAN.tmp" "$PLAN"
run "$PLAN"
chk "D slog still compacted without MR header"  "[ \"\$(grep -c '^- SLOG entry ' '$PLAN')\" = 12 ]"
chk "D MR skip logged"                          "grep -q 'no .## Daemon Report. header' '$SANDBOX/out.txt'"

# ---------- Case D2: the LEGACY '## Morning Review' header still rotates (renamed 2026-08-05) ----------
# arm.sh installs the compactor from the primary checkout while the plan lives on disk, so a new script
# meeting an old plan is an ordinary skew — and a compactor that cannot find its own section silently
# stops bounding the file. The header match is an alternation; this proves it stays one.
PLAN="$(make_plan 5 40)"
perl -pi -e 's/^## Daemon Report$/## Morning Review/' "$PLAN"
run "$PLAN"
chk "D2 legacy header rotated to DR_KEEP=15"    "[ \"\$(grep -c '^\\*\\*\\[' '$PLAN')\" = 15 ]"
chk "D2 legacy header itself survives"          "grep -q '^## Morning Review' '$PLAN'"
chk "D2 legacy rotation was not a skip"         "! grep -q 'header — skip DR' '$SANDBOX/out.txt'"

# ---------- Case E: plan with NO trailing newline — the last line must NOT be lost (HIGH-1 regression) ----------
# slog UNDER trigger so Pass 1 no-ops (its awk mv would otherwise re-terminate the file and mask the bug);
# then strip the file's trailing newline so its final content line ('sub-line for entry 30', the OLDEST entry,
# which belongs in the archived tail) is unterminated — the exact precondition of the wc/sed data-loss bug.
PLAN="$(make_plan 5 30)"
printf '%s' "$(cat "$PLAN")" > "$PLAN.nonl" && mv "$PLAN.nonl" "$PLAN"   # drop the single trailing newline
chk "E precondition: no trailing newline"       "[ \"\$(tail -c1 '$PLAN' | wc -l | tr -d ' ')\" = 0 ]"
run "$PLAN"
chk "E rotated to 15 real entries"              "[ \"\$(grep -c '^\\*\\*\\[2026' '$PLAN')\" = 15 ]"
chk "E last line SURVIVES in the archive"       "grep -q '^sub-line for entry 30\$' '$SANDBOX/mr-arch.md'"
chk "E last line removed from the plan"          "! grep -q '^sub-line for entry 30\$' '$PLAN'"
chk "E no conservation failure"                 "! grep -qi 'conservation FAIL' '$SANDBOX/out.txt'"
chk "E plan re-terminated (trailing newline)"    "[ \"\$(tail -c1 '$PLAN' | wc -l | tr -d ' ')\" = 1 ]"

# ---------- Case F: a section AFTER Daemon Report must survive byte-identical (tail-splice) ----------
PLAN="$(make_plan 5 40 trailing)"
section "$PLAN" "E2E findings" > "$SANDBOX/preF-e2e.txt"
run "$PLAN"
chk "F MR rotated to 15"                         "[ \"\$(grep -c '^\\*\\*\\[2026' '$PLAN')\" = 15 ]"
chk "F trailing section survived byte-identical" "diff -q '$SANDBOX/preF-e2e.txt' <(section '$PLAN' 'E2E findings') >/dev/null"
chk "F trailing section still present"           "grep -q 'trailing section line B' '$PLAN'"

# ---------- Case G: STRUCTURAL header detection (blank-preceded '**[') on the real header zoo ----------
# A purpose-built plan whose newest (kept) entries exercise every case the WS8 reviews raised:
#   * entry 1's body has TWO column-0 '**[' lines that are NOT blank-preceded — a non-date '**[note] …' and a
#     date-SHAPED '**[2026-05-09] …' — both must be treated as body (not counted, not torn from the entry);
#   * entry 2 is a date+QUALIFIER header '**[2026-08-31, GUI-ON session] …' (must count as a real entry);
#   * entry 3 is a NON-date header '**[HISTORICAL — …]' (must count as a real entry).
# 30 real (blank-preceded) headers total, so the cut runs. keep 15 -> entries 1-3 + plain 4-15 inline, plain
# 16-30 archived. If either mid-body line were miscounted, the ordinal would shift and the plain-15/16 boundary
# would move — the boundary assertions pin it exactly.
gplan="$SANDBOX/plan.md"; rm -f "$gplan" "$gplan.bak"
{
  printf '# P\n\nRUN STATUS: IN_PROGRESS\n\n## PRIME DIRECTIVES\n- x\n\n## RESUME PROTOCOL\n1. y\n\n'
  printf '## WORK QUEUE\n- [ ] z\n\n## Session Log\n- SLOG entry 1\n\n## Daemon Report\n\n(preamble)\n\n'
  printf '**[2026-09-01] NEWEST real entry.**\n- normal bullet\n'
  printf '**[note] mid-body not-a-header**\n**[2026-05-09] mid-body date-shaped not-a-header**\nsub A of newest\n\n'
  printf '**[2026-08-31, GUI-ON session] qualifier header entry.**\n- bullet\n\n'
  printf '**[HISTORICAL — superseded] non-date header entry.**\n- bullet\n\n'
  for i in $(seq 4 30); do printf '**[2026-08-%02d] plain entry %d.**\n- bullet for plain entry %d\n\n' "$((i-3))" "$i" "$i"; done
} > "$gplan"
PLAN="$gplan"; run "$PLAN"
chk "G non-date mid-body line kept inline (not torn)"   "grep -q '^\\*\\*\\[note\\] mid-body' '$PLAN'"
chk "G date-shaped mid-body line kept inline (not torn)" "grep -q '^\\*\\*\\[2026-05-09\\] mid-body' '$PLAN'"
chk "G mid-body lines NOT archived"                     "! grep -q 'mid-body' '$SANDBOX/mr-arch.md'"
chk "G date+qualifier header counted+kept"              "grep -q 'qualifier header entry' '$PLAN'"
chk "G non-date header counted+kept"                    "grep -q 'non-date header entry' '$PLAN'"
chk "G boundary: plain entry 15 kept inline"            "grep -q 'plain entry 15\\.' '$PLAN'"
chk "G boundary: plain entry 16 archived"               "grep -q 'plain entry 16\\.' '$SANDBOX/mr-arch.md' && ! grep -q 'plain entry 16\\.' '$PLAN'"
chk "G oldest plain entry 30 archived"                  "grep -q 'plain entry 30\\.' '$SANDBOX/mr-arch.md'"
chk "G no conservation failure"                         "! grep -qi 'conservation FAIL' '$SANDBOX/out.txt'"

# ---------- Case H: archive-write failure aborts BEFORE the mv — plan untouched (MEDIUM-3 + rollback) ----------
PLAN="$(make_plan 5 40)"
cp "$PLAN" "$SANDBOX/preH.md"
mkdir -p "$SANDBOX/mrarch-is-a-dir"   # '>>' onto a directory fails -> archive write cannot succeed
MRARCH="$SANDBOX/mrarch-is-a-dir" run "$PLAN"
chk "H plan UNTOUCHED after archive failure"     "diff -q '$SANDBOX/preH.md' '$PLAN' >/dev/null"
chk "H archive-failure logged"                   "grep -q 'archive write failed' '$SANDBOX/out.txt'"

# ---------- Case I: a mid-body (NON-blank-preceded) '## ' must NOT truncate the region ----------
# Inject a column-0 '## ' into the newest entry's body right after a bullet (so it is NOT blank-preceded). With
# the old "any '## ' ends the region" rule this truncated the count to 1 -> total no-op (30 entries left). The
# blank-preceded region-end rule ignores it, so the rotation proceeds and keeps exactly 15.
PLAN="$(make_plan 5 30)"
perl -0pi -e 's/(^- detail bullet for entry 1\n)/$1## fake heading pasted in a body\n/m' "$PLAN"
run "$PLAN"
chk "I mid-body '## ' did not truncate (kept 15)"  "[ \"\$(grep -c '^\\*\\*\\[2026' '$PLAN')\" = 15 ]"
chk "I mid-body '## ' kept inline with its entry"  "grep -q '^## fake heading pasted' '$PLAN'"
chk "I rotation happened (oldest entry archived)"  "grep -q 'MR entry 30 ' '$SANDBOX/mr-arch.md'"
chk "I no conservation failure"                    "! grep -qi 'conservation FAIL' '$SANDBOX/out.txt'"

echo ""
echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" = 0 ]
