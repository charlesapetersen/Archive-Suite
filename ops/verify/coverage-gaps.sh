#!/usr/bin/env bash
# coverage-gaps.sh — run the suites with code coverage on and list the functions no run reached (W40.e4).
#
# USAGE:  ops/verify/coverage-gaps.sh [core|reader|notes|processor ...]   (default: all four), then
#         ops/verify/coverage_gaps.py report            (union of every run in $COV_OUT; see that file)
# ENV:    COV_OUT (default /tmp/coverage-gaps), DRIVERS (Processor driver scripts, overriding the list below)
# EXIT:   0 = every run produced coverage (failing tests are logged, not fatal: a failed test still executed
#             code) · 2 = a run produced no coverage — never read as "nothing reached"
#
# HOW, per run — each writes $COV_OUT/<run>.json, the normalised function list coverage_gaps.py unions:
#   core       `xcodebuild test -scheme ArchiveCore-Package -enableCodeCoverage YES` on the package → xcresult.
#   reader     the app-hosted unit bundles with -enableCodeCoverage YES, DerivedData ./build/cov-DD, so a
#   notes      coverage build never replaces the normal one. The xcresult carries the app AND ArchiveCore.
#   processor  it has no unit bundle: its tests are the headless drivers. The app is built with
#              -enableCodeCoverage YES into macOS/build/DD (the path the drivers hardcode), each driver below
#              runs with LLVM_PROFILE_FILE pointing into $COV_OUT, and llvm-cov exports the merged profile.
#              A plain build in this checkout afterwards replaces the instrumented one.
# The UI and journey runs happen in the VM (`VM_COVERAGE=1 ops/gui/vm-gui-runner.sh <app> xcuitest`); add each
# run's collected xcresult with `coverage_gaps.py xcresult <bundle> <run-name>`.
# The drivers left out need an API key or spend money (openrouter, segmentation-proof, smoke, tier2) — the same
# list as ops/verify/sanitizer-runs.sh.
set -uo pipefail
. "$(dirname "$0")/../autonomous/heavy-enter.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
log() { printf '\033[36m[cov]\033[0m %s\n' "$*"; }
OUT="${COV_OUT:-/tmp/coverage-gaps}"
mkdir -p "$OUT"
PY="$HERE/coverage_gaps.py"

DEFAULT_DRIVERS="test-batch-resume.sh test-collection-organize.sh test-dual-date.sh test-institutional-compute-import.sh
test-filerelay.sh test-incremental-skip.sh test-local-models.sh test-localagent.sh test-manifest-persistence.sh
test-merge-safety.sh test-multipage-reocr.sh test-network-session.sh test-ocr-cascade.sh test-ocr-page-guidance.sh
test-ocr-page-kind.sh test-ocr-refusal.sh test-processfiles-tagwarn.sh test-processing-history.sh test-recovery.sh
test-retry-backend.sh test-segment-json.sh test-segmentation-chatgpt.sh test-segmentation-chooser.sh
test-segmentation-engine.sh test-segmentation-plan.sh test-segmentation-review.sh test-vision-hybrid.sh
test-usbmux-bridge.sh"

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
  (cd "$dir/macOS" && xcodebuild -scheme ArchiveProcessor -configuration Debug -enableCodeCoverage YES \
      -derivedDataPath ./build/DD build) >"$OUT/processor-build.log" 2>&1 \
    || { log "processor: build FAILED ($OUT/processor-build.log)"; worst=2; return; }
  for d in ${DRIVERS:-$DEFAULT_DRIVERS}; do
    LLVM_PROFILE_FILE="$pdir/${d%.sh}-%p.profraw" bash "$dir/scripts/$d" >"$pdir/${d%.sh}.out" 2>&1
    rc=$?
    log "processor: $d exit $rc"
    [ "$rc" = 0 ] || failed+=("$d")
  done
  log "processor: failed drivers: ${failed[*]:-none}"
  local bin="$dir/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
  if ls "$pdir"/*.profraw >/dev/null 2>&1 \
     && xcrun llvm-profdata merge -sparse "$pdir"/*.profraw -o "$pdir/merged.profdata" \
     && xcrun llvm-cov export -format=text -skip-expansions -instr-profile "$pdir/merged.profdata" "$bin" \
        >"$pdir/export.json" \
     && python3 "$PY" llvm "$pdir/export.json" processor-drivers; then
    rm -f "$pdir"/*.profraw "$pdir/export.json"
  else
    log "processor: no driver coverage"; worst=2
  fi
}

suites=("$@"); [ ${#suites[@]} -gt 0 ] || suites=(core reader notes processor)
for s in "${suites[@]}"; do
  case "$s" in
    core)   run_xcode core-unit "$ROOT/packages/ArchiveCore" -scheme ArchiveCore-Package -only-testing:ArchiveCoreTests -derivedDataPath ./build/cov-DD ;;
    reader) (cd "$ROOT/ArchiveReader/macOS" && xcodegen generate >/dev/null 2>&1)
            run_xcode reader-unit "$ROOT/ArchiveReader/macOS" -scheme ArchiveReader -only-testing:ArchiveReaderTests \
              -skip-testing:ArchiveReaderTests/DeepLinkTests -derivedDataPath ./build/cov-DD ;;
    notes)  (cd "$ROOT/ArchiveNotes/macOS" && xcodegen generate >/dev/null 2>&1)
            run_xcode notes-unit "$ROOT/ArchiveNotes/macOS" -scheme ArchiveNotesUnit -only-testing:ArchiveNotesTests \
              -derivedDataPath ./build/cov-DD ;;
    processor) run_processor ;;
    *) echo "unknown suite '$s' (use: core | reader | notes | processor)" >&2; exit 2 ;;
  esac
done
log "runs in $OUT: $(cd "$OUT" && ls *.json 2>/dev/null | tr '\n' ' ')"
exit "$worst"
