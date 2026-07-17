#!/usr/bin/env bash
# prove-review-cadence.sh — prove next-review-unit.sh (WS11) picks the right unit, resets on record, honors
# the cooldown, covers never-reviewed units, and never picks iOS. Runs the REAL helper against a throwaway
# git repo (AUTONOMOUS_REPO), $0, no network.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; HELPER="$HERE/../next-review-unit.sh"
[ -f "$HELPER" ] || { echo "no helper at $HELPER"; exit 2; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
R="$T/repo with space"; mkdir -p "$R"    # space: mirrors the real repo path
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
run() { AUTONOMOUS_REPO="$R" AUTONOMOUS_REVIEW_EVERY="${EVERY:-3}" bash "$HELPER" "$@"; }

git -C "$R" init -q; git -C "$R" config user.email t@t; git -C "$R" config user.name t
echo neutral > "$R/README"; git -C "$R" add -A; git -C "$R" commit -qm seed   # seed touches NO unit path
cm() {  # cm <unit-path> <n>  — make n commits each touching a file under that path
  local p="$1" n="$2" i; mkdir -p "$R/$p"
  for i in $(seq 1 "$n"); do echo "c$i-$(date +%s%N)" > "$R/$p/f"; git -C "$R" add -A; git -C "$R" commit -qm "touch $p $i"; done
}
NET=ArchiveProcessor/macOS/Sources/ArchiveProcessor/Net
CAP=ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture
MOD=ArchiveProcessor/macOS/Sources/ArchiveProcessor/Models

echo "[1] --status lists the 9 units and NOT iOS"
cm "$NET" 2; cm "$CAP" 1
S="$(run --status 2>&1)"
[ "$(printf '%s' "$S" | grep -cE 'Processor/(Capture|Net|OCR|Tagging|Views)|Reader/(Core|Search|Views)|Android')" -ge 9 ] && ok "9 units listed" || bad "unit count off: $(printf '%s' "$S" | grep -c 'unreviewed')"
printf '%s' "$S" | grep -qi 'iOS' && bad "iOS present (should be skipped)" || ok "iOS absent (ON HOLD)"

echo "[2] fresh (all never-reviewed) -> DUE, picks the FIRST unit in table/RISK order (Capture #1), not the highest-churn"
# Net has more commits (2 vs Capture's 1) but Capture is unit #1 — never-reviewed coverage is risk-ordered,
# not churn-ordered (the anti-starvation fix). This is the corrected behavior vs the pre-fix churn ranking.
OUT="$(run)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$OUT" | grep -q 'UNIT=Processor/Capture' && ok "picked Capture (table order) ($OUT)" || bad "expected Capture (table order); got rc=$rc '$OUT'"

echo "[3] --record resets that unit + starts the cooldown"
run --record "Processor/Net" >/dev/null
OUT="$(run)"; rc=$?
[ "$rc" = 3 ] && printf '%s' "$OUT" | grep -q 'none due' && ok "cooldown active right after record ($OUT)" || bad "expected 'none due' rc3; got rc=$rc '$OUT'"

echo "[4] after >= EVERY commits, DUE again and picks the newly-stale unit (Capture)"
cm "$CAP" 3        # 3 commits since the record -> cooldown (EVERY=3) satisfied; Capture now most-stale
OUT="$(run)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$OUT" | grep -q 'UNIT=Processor/Capture' && ok "picked Capture ($OUT)" || bad "expected Capture due; got rc=$rc '$OUT'"

echo "[5] multi-path unit: a Models commit counts toward Processor/Tagging+Models"
run --record "Processor/Capture" >/dev/null   # reset + restart cooldown
cm "$MOD" 3
OUT="$(run)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$OUT" | grep -q 'UNIT=Processor/Tagging+Models' && ok "picked Tagging+Models via a Models/ commit ($OUT)" || bad "expected Tagging+Models; got rc=$rc '$OUT'"

echo "[6] record is exact-match + rejects unknown units (no regex pitfalls on +/ )"
run --record "Processor/Tagging+Models" >/dev/null && ok "recorded the +-containing unit name" || bad "failed to record Tagging+Models"
run --record "Bogus/Unit" >/dev/null 2>&1 && bad "accepted an unknown unit" || ok "rejected an unknown unit"

echo "[7] ANTI-STARVATION (review HIGH #1): a NEVER-reviewed unit outranks a high-churn REVIEWED one"
# Fresh state. Review Net once, then churn it hard; a never-reviewed low-churn unit (OCR, 1 commit) must
# still be picked over the heavily-churned already-reviewed Net.
rm -f "$R/.maintenance/review/last-reviewed.tsv"
OCR=ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR
cm "$OCR" 1                       # OCR: 1 commit, never reviewed
run --record "Processor/Net" >/dev/null       # Net reviewed (its churn resets to 0)
cm "$NET" 8                       # Net: 8 fresh commits (>> OCR's 1); cooldown (8>=EVERY 3) satisfied
OUT="$(run)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$OUT" | grep -qE 'UNIT=Processor/(OCR|Capture)' \
  && ok "never-reviewed unit picked over high-churn reviewed Net ($OUT)" \
  || bad "STARVATION: picked a reviewed unit over a never-reviewed one; got '$OUT'"

echo "[8] never-reviewed taken in TABLE/RISK order (Capture before OCR)"
rm -f "$R/.maintenance/review/last-reviewed.tsv"
cm "$CAP" 1; cm "$OCR" 5          # OCR has more commits, but Capture is earlier in the risk order
OUT="$(EVERY=1 run)"; rc=$?
printf '%s' "$OUT" | grep -q 'UNIT=Processor/Capture' && ok "Capture (earlier in table) picked before higher-churn OCR ($OUT)" || bad "table-order not honored; got '$OUT'"

echo "[9] FAIL-OPEN on a bad sha (review HIGH #2): a stale/invalid recorded sha => never-reviewed, not silent-0"
rm -f "$R/.maintenance/review/last-reviewed.tsv"; mkdir -p "$R/.maintenance/review"
printf 'Processor/Net\tdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\t2020-01-01 00:00:00\n' > "$R/.maintenance/review/last-reviewed.tsv"
printf '__any__\tdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\t2020-01-01 00:00:00\n' >> "$R/.maintenance/review/last-reviewed.tsv"
cm "$NET" 1
OUT="$(run --status 2>&1)"
printf '%s' "$OUT" | grep -qE 'Processor/Net .* last=never' && ok "bad unit sha treated as never-reviewed (not 0)" || bad "bad sha not failing open: $(printf '%s' "$OUT" | grep Net)"
OUT="$(run)"; rc=$?
[ "$rc" = 0 ] && ok "bad __any__ sha fails open -> a review is due (cadence not silently stalled)" || bad "bad __any__ sha stalled the cadence (rc=$rc: $OUT)"

echo
echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" = 0 ]
