#!/bin/bash
# test-tier2.sh — Tier-2 GUI/pipeline functional test, fully automated.
#
# Drives the REAL Process Files pipeline (OCR -> segmentation -> tagging -> PDF) with no clicking,
# via the headless ProcessFilesTestDriver (PROCESSFILES_TESTMODE hook in the app). For each case it
# launches the built app with env config, waits for the driver's TEST_DONE marker, kills the app,
# and asserts the produced results.json with tier2_assert.py.
#
# Keys come from the Keychain (account "Gemini"), like the smoke test; AP_GEMINI_KEY overrides.
# Outputs go under .maintenance/test-results/ (gitignored); Test Files are never written to.
# Cost: cheap models + small image caps => a few cents total.
#
# Usage: ./scripts/test-tier2.sh            (runs the representative set)
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
BIN="$REPO/ArchiveProcessor/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
GT="$REPO/Test Files/Ground Truth Segmentation"
OUTBASE="$REPO/.maintenance/test-results/tier2-$(date +%Y%m%d-%H%M%S)"
LOG="$OUTBASE/tier2.log"
mkdir -p "$OUTBASE"
say(){ echo "$@" | tee -a "$LOG"; }

[ -x "$BIN" ] || { say "no built app at $BIN — run: (cd ArchiveProcessor && xcodegen generate && xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/DD build)"; exit 1; }
GKEY="${AP_GEMINI_KEY:-$(security find-generic-password -s com.archiveprocessor.app -a Gemini -w 2>/dev/null)}"
[ -n "$GKEY" ] || { say "no Gemini key (Keychain acct 'Gemini' or AP_GEMINI_KEY) — approve the Keychain prompt"; exit 1; }

say "=== Archive Processor Tier-2 pipeline test · $(date '+%Y-%m-%d %H:%M:%S') ==="
say "out: $OUTBASE"
pass=0; fail=0

# run_case NAME  INPUT_DIR  MODE  MAXIMAGES  EXPORT(0|1)  [GT_CSV]
run_case(){
  local name="$1" indir="$2" mode="$3" max="$4" export="$5" gtcsv="${6:-}"
  local out="$OUTBASE/$name"
  mkdir -p "$out"
  say ""; say "── case: $name  (mode=$mode, max=$max, export=$export)"
  pkill -x ArchiveProcessor 2>/dev/null; sleep 1
  PROCESSFILES_TESTMODE=1 \
  PROCESSFILES_TESTKEY="$GKEY" \
  PROCESSFILES_TESTIN="$indir" \
  PROCESSFILES_TESTOUT="$out" \
  PROCESSFILES_TAGGING="$mode" \
  PROCESSFILES_MAXIMAGES="$max" \
  PROCESSFILES_EXPORTORIGINALS="$export" \
  PROCESSFILES_TESTDONE="$out/DONE.txt" \
    "$BIN" >"$out/app.log" 2>&1 &
  local pid=$!
  local i
  for i in $(seq 1 150); do [ -f "$out/DONE.txt" ] && break; sleep 2; done   # up to ~5 min
  kill "$pid" 2>/dev/null; pkill -x ArchiveProcessor 2>/dev/null; sleep 1
  # Teardown: remove the pipeline's resume-state so a crash/kill can't leave a stale, paid
  # "Resume Run" prompt for a later NORMAL launch (the driver also clears it on a clean exit).
  rm -f "$HOME/Library/Application Support/ArchiveProcessor/pending_run.json" \
        "$HOME/Library/Application Support/ArchiveProcessor/pending_batch.json" 2>/dev/null
  local marker; marker=$(cat "$out/DONE.txt" 2>/dev/null || echo "(no marker — timed out)")
  say "  driver: $marker"
  local rd; rd=$(ls -d "$out"/run-* 2>/dev/null | head -1)
  if [ -z "$rd" ] || [ ! -f "$rd/manifest.tsv" ]; then say "  ✗ FAIL  no run dir / manifest.tsv (driver hang/crash?) — see $out/app.log"; fail=$((fail+1)); return; fi
  local args=("$rd" "$mode")
  [ -n "$gtcsv" ] && args+=(--gt "$gtcsv")
  [ "$export" = 1 ] && args+=(--check-exports)
  if python3 "$REPO/scripts/tier2_assert.py" "${args[@]}" | tee -a "$LOG" | grep -q "RESULT: PASS"; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
  fi
}

# Representative set (cheap). Larger confidence runs (Stanton/Herrnstein 200+) can be added by
# appending run_case lines with a higher MAXIMAGES when running unattended.
run_case "01-none-plumbing"     "$GT/Dean"                  none        3 0
run_case "02-copysource"        "$GT/Deaver"                copySource  4 0
run_case "03-automatic-dean"    "$GT/Dean"                  automatic   8 0 "$GT/Dean/Dean Ground Truth.csv"
run_case "04-automatic-rg165"   "$GT/RG 165 — War Department" automatic 8 0 "$GT/RG 165 — War Department/Ground Truth.csv"
run_case "05-automatic-export"  "$GT/Dean"                  automatic   3 1

say ""; say "=== Tier-2 result: $pass passed, $fail failed ==="
say "Full log: $LOG"
[ "$fail" -eq 0 ] && say "TIER 2: PASS ✅" || say "TIER 2: FAIL ❌ ($fail)"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
