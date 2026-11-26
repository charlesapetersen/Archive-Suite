#!/usr/bin/env bash
# coverage-gaps.sh — run the suites with code coverage on and list the functions no run reached (W40.e4).
#
# USAGE:  ops/verify/coverage-gaps.sh [core|processor|vm-reader|vm-notes|vm-processor ...]   (default: all), then
#         ops/verify/coverage_gaps.py report            (union of every run in $COV_OUT; see that file)
# ENV:    COV_OUT (default ~/Library/Caches/ArchiveSuiteRehearsal/W40.e4, so a later session adds runs to it),
#         DRIVERS (Processor driver scripts, overriding the list below), VM_SELECT (override a vm-* selection) and VM_TAG (its
#         run-name part, default "all", so a narrower re-run does not overwrite the full one)
# EXIT:   0 = every run produced coverage (failing tests are logged, not fatal: a failed test still executed
#             code) · 2 = a run produced no coverage — never read as "nothing reached"
#
# HOW, per run — each writes $COV_OUT/<run>.json, the normalised function list coverage_gaps.py unions:
#   core       `xcodebuild test -scheme ArchiveCore-Package -enableCodeCoverage YES` on the package → xcresult.
#   processor  it has no unit bundle: its tests are the headless drivers. The app is built for testing with
#              coverage into macOS/build/DD (the path the drivers hardcode), each driver below runs with
#              LLVM_PROFILE_FILE pointing into $COV_OUT, and llvm-cov exports the merged profile.
#              A plain build in this checkout afterwards replaces the instrumented one.
#   vm-<app>   the app's unit bundle AND UITests in the VM, `VM_COVERAGE=1 VM_SPLIT=4 vm-gui-runner.sh <app>
#              xcuitest`; one run per collected chunk xcresult, named vm-<app>-<VM_TAG>-<chunk>. The Reader and Notes unit bundles run in the VM,
#              not on the host: on the host their app-hosted runs (the "Archive Suite Dev" signed, sandboxed
#              app) wrote no profile at all, so xccov found no coverage archive (measured 2026-11-26); the VM's
#              ad-hoc build writes it.
# Journeys need their own environment: run `VM_COVERAGE=1 <APP>_JOURNEY=… vm-gui-runner.sh …` (or its wrapper
# script with VM_COVERAGE=1 exported) and add the collected bundle with `coverage_gaps.py xcresult <bundle> <run>`.
# The list is every key-free script that runs the app's own driver (sanitizer-runs.sh's list, then the rest).
# Left out: those that need an API key, an account or a device or spend money (openrouter, segmentation-proof,
# local-segmentation-proof, smoke, tier2, drive-live, android/ios), and those that compile their own small host
# rather than run the app (relay-*, rotation-axis/-deadlock/-lcnet, vision-ocr, ocr-prompt, thinking-budgets, …),
# whose profile would not be the app's.
set -uo pipefail
. "$(dirname "$0")/../autonomous/heavy-enter.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
log() { printf '\033[36m[cov]\033[0m %s\n' "$*"; }
OUT="${COV_OUT:-$HOME/Library/Caches/ArchiveSuiteRehearsal/W40.e4}"; export COV_OUT="$OUT"
mkdir -p "$OUT"
PY="$HERE/coverage_gaps.py"

DEFAULT_DRIVERS="test-batch-resume.sh test-collection-organize.sh test-dual-date.sh test-institutional-compute-import.sh
test-filerelay.sh test-incremental-skip.sh test-local-models.sh test-localagent.sh test-manifest-persistence.sh
test-merge-safety.sh test-multipage-reocr.sh test-network-session.sh test-ocr-cascade.sh test-ocr-page-guidance.sh
test-ocr-page-kind.sh test-ocr-refusal.sh test-processfiles-tagwarn.sh test-processing-history.sh test-recovery.sh
test-retry-backend.sh test-segment-json.sh test-segmentation-chatgpt.sh test-segmentation-chooser.sh
test-segmentation-engine.sh test-segmentation-plan.sh test-segmentation-review.sh test-vision-hybrid.sh
test-usbmux-bridge.sh
test-date-route.sh test-deferred-output.sh test-entity-feature.sh test-flagged-check-timing.sh test-header-parity.sh
test-item-fields.sh test-newspaper-layout.sh test-page-reader.sh test-provider-errors.sh test-read-quality-flag.sh
test-reocr-filewriter.sh test-reocr-job.sh test-reocr-pairs.sh test-reocr-preservation.sh test-reocr-ranking.sh
test-reocr-request-store.sh test-reocr-writer.sh test-review-corrections.sh test-rotation-rule.sh
test-run-quit-resume.sh test-settings-interviews.sh test-settings-layers.sh test-settings-sheet.sh
test-settings-solver.sh test-settings-tabs.sh test-tagging-failure.sh test-text-layer.sh"

worst=0
extract() {  # $1 = xcresult, $2 = run name
  if [ -d "$1" ] && python3 "$PY" xcresult "$1" "$2"; then :; else log "$2: no coverage in $1"; worst=2; fi
}

run_xcode() {  # $1 = run name, $2 = dir, $3.. = xcodebuild args
  local name="$1" dir="$2"; shift 2
  local bundle="$OUT/$name.xcresult"
  rm -rf "$bundle"
  log "$name: xcodebuild test -enableCodeCoverage YES $*…"
  (cd "$dir" && xcodebuild test -destination 'platform=macOS' -enableCodeCoverage YES "$@" \
      -resultBundlePath "$bundle") >"$OUT/$name.log" 2>&1
  grep -E "^[[:space:]]*Executed [0-9]+ tests?|\*\* TEST (SUCCEEDED|FAILED)" "$OUT/$name.log" | tail -2 | sed "s/^[[:space:]]*/[cov] $name: /"
  extract "$bundle" "$name"
}

run_processor() {
  local dir="$ROOT/ArchiveProcessor" pdir="$OUT/processor-profraw" d rc failed=()
  rm -rf "$pdir"; mkdir -p "$pdir"
  (cd "$dir/macOS" && xcodegen generate >/dev/null 2>&1) || { log "processor: xcodegen failed"; worst=2; return; }
  log "processor: Debug build with coverage into macOS/build/DD…"
  # build-for-testing, because -enableCodeCoverage is accepted only by test actions; a plain `build` with
  # CLANG_COVERAGE_MAPPING=YES ran but wrote profiles llvm-profdata refused ("number of counters is zero").
  (cd "$dir/macOS" && xcodebuild build-for-testing -scheme ArchiveProcessor -configuration Debug \
      -destination 'platform=macOS' -enableCodeCoverage YES -derivedDataPath ./build/DD) >"$OUT/processor-build.log" 2>&1 \
    || { log "processor: build FAILED ($OUT/processor-build.log)"; worst=2; return; }
  for d in ${DRIVERS:-$DEFAULT_DRIVERS}; do
    # %c = continuous mode: counters are mapped into the file as they change. Without it the app writes its
    # profile only at exit, and test-child.sh TERMs it as soon as the script has its report: 15 of 28 drivers
    # left no profile in the first run (measured 2026-11-26; merge-safety alone wrote none).
    LLVM_PROFILE_FILE="$pdir/${d%.sh}-%c%p.profraw" bash "$dir/scripts/$d" >"$pdir/${d%.sh}.out" 2>&1
    rc=$?
    log "processor: $d exit $rc"
    [ "$rc" = 0 ] || failed+=("$d")
  done
  log "processor: failed drivers: ${failed[*]:-none}"
  local bin="$dir/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
  # A driver that kills the app leaves an empty profile; merge only the written ones.
  local raws=(); while IFS= read -r -d '' f; do raws+=("$f"); done < <(find "$pdir" -name '*.profraw' -size +0 -print0)
  if [ ${#raws[@]} -gt 0 ] \
     && xcrun llvm-profdata merge -sparse --failure-mode=all "${raws[@]}" -o "$pdir/merged.profdata" \
     && xcrun llvm-cov export -format=text -skip-expansions -instr-profile "$pdir/merged.profdata" "$bin" \
        >"$pdir/export.json" \
     && python3 "$PY" llvm "$pdir/export.json" processor-drivers; then
    rm -f "$pdir"/*.profraw "$pdir/export.json"
  else
    log "processor: no driver coverage"; worst=2
  fi
}

run_vm() {  # $1 = reader | notes | processor
  local app="$1" sel stamp="$OUT/.vm-$1.stamp" b n
  case "$app" in
    reader)    sel="ArchiveReaderTests,ArchiveReaderUITests" ;;
    notes)     sel="ArchiveNotesTests,ArchiveNotesUITests" ;;
    processor) sel="ArchiveProcessorUITests" ;;
  esac
  touch "$stamp"
  log "vm-$app: ${VM_SELECT:-$sel} with coverage in the VM (VM_SPLIT=4)…"
  VM_COVERAGE=1 VM_SPLIT=4 ONLY_TESTING="${VM_SELECT:-$sel}" "$ROOT/ops/gui/vm-gui-runner.sh" "$app" xcuitest \
    >"$OUT/vm-$app.log" 2>&1
  log "vm-$app: runner exit $? (log: $OUT/vm-$app.log)"
  n=0
  for b in "$HOME/.tart-mirror/vm-artifacts/$app"/chunk*.xcresult "$HOME/.tart-mirror/vm-artifacts/$app"/uitest.xcresult; do
    [ -d "$b" ] && [ "$b" -nt "$stamp" ] || continue
    extract "$b" "vm-$app-${VM_TAG:-all}-$(basename "$b" .xcresult)"; n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { log "vm-$app: no result bundle collected"; worst=2; }
}

suites=("$@"); [ ${#suites[@]} -gt 0 ] || suites=(core processor vm-reader vm-notes vm-processor)
for s in "${suites[@]}"; do
  case "$s" in
    core)   run_xcode core-unit "$ROOT/packages/ArchiveCore" -scheme ArchiveCore-Package -only-testing:ArchiveCoreTests -derivedDataPath ./build/cov-DD ;;
    processor) run_processor ;;
    vm-reader|vm-notes|vm-processor) run_vm "${s#vm-}" ;;
    *) echo "unknown suite '$s' (use: core | processor | vm-reader | vm-notes | vm-processor)" >&2; exit 2 ;;
  esac
done
log "runs in $OUT: $(cd "$OUT" && ls *.json 2>/dev/null | tr '\n' ' ')"
exit "$worst"
