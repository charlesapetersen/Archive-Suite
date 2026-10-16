#!/usr/bin/env bash
# sanitizer-runs.sh — run the unit suites and the Processor drivers under Thread or Address Sanitizer (W40.e1).
#
# USAGE:  ops/verify/sanitizer-runs.sh <tsan|asan> [core|reader|notes|processor ...]   (default: all four)
# ENV:    SAN_OUT (default /tmp/sanitizer-runs), ONLY_TESTING (narrow a suite: an -only-testing id, or core's --filter),
#         DRIVERS (space-separated driver script names, overriding the Processor list below)
# EXIT:   0 = every run finished green with no sanitizer report · 1 = a sanitizer report, or a failed run
#         2 = could not measure (build failed, no test summary) — never read as clean
#
# HOW, per suite — TSan and ASan are separate builds (they cannot be combined), each in its own build dir, so
# a sanitizer build never replaces the normal one a later plain run would reuse:
#   core       `swift test --sanitize=<thread|address>` with `--scratch-path .build/<san>`.
#   reader     `xcodebuild test -enable{Thread,Address}Sanitizer YES` on the app-hosted unit bundle, DerivedData
#   notes      ./build/<san>-DD. The runtime reports into the test log.
#   processor  (TSan only: the plan asks for the drivers under TSan) builds the app with TSan into the path the
#              driver scripts hardcode, macOS/build/DD, then runs each headless driver below with
#              TSAN_OPTIONS=log_path=… so every report lands in a file even when the driver's own log is a
#              mktemp it deletes. A plain build in this checkout afterwards replaces it.
# A report is any "WARNING: ThreadSanitizer" / "ERROR: AddressSanitizer" (or "SUMMARY: …Sanitizer") line. ASan
# stops the process at its first report, so one ASan finding can hide the next: fix it and re-run.
# The drivers left out need an API key or spend money (openrouter, segmentation-proof, smoke, tier2).
set -uo pipefail
. "$(dirname "$0")/../autonomous/heavy-enter.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
log() { printf '\033[36m[san]\033[0m %s\n' "$*"; }

san="${1:-}"; shift || true
case "$san" in
  tsan) swift_san=thread;  xc_flag=-enableThreadSanitizer ;;
  asan) swift_san=address; xc_flag=-enableAddressSanitizer ;;
  *) echo "usage: $0 <tsan|asan> [core|reader|notes|processor ...]" >&2; exit 2 ;;
esac
OUT="${SAN_OUT:-/tmp/sanitizer-runs}/$san"
mkdir -p "$OUT"
REPORT_RE='WARNING: ThreadSanitizer|ERROR: AddressSanitizer|SUMMARY: (Thread|Address|UndefinedBehavior)Sanitizer'

DEFAULT_DRIVERS="test-batch-resume.sh test-collection-organize.sh test-dual-date.sh test-farmshare-import.sh
test-filerelay.sh test-incremental-skip.sh test-local-models.sh test-localagent.sh test-manifest-persistence.sh
test-merge-safety.sh test-multipage-reocr.sh test-network-session.sh test-ocr-cascade.sh test-ocr-page-guidance.sh
test-ocr-page-kind.sh test-ocr-refusal.sh test-processfiles-tagwarn.sh test-processing-history.sh test-recovery.sh
test-retry-backend.sh test-segment-json.sh test-segmentation-chatgpt.sh test-segmentation-chooser.sh
test-segmentation-engine.sh test-segmentation-plan.sh test-segmentation-review.sh test-vision-hybrid.sh"

worst=0
verdict() {  # $1 = rc to fold in: 1 beats 2 beats 0
  case "$1" in 1) worst=1 ;; 2) [ "$worst" = 0 ] && worst=2 ;; esac
  return 0
}
count_reports() { grep -hcE "$REPORT_RE" "$@" 2>/dev/null | awk '{s+=$1} END {print s+0}'; }

run_core() {
  local dir="$ROOT/packages/ArchiveCore" tlog="$OUT/core.log" n
  log "core: swift test --sanitize=${swift_san}…"
  local only=()
  [ -n "${ONLY_TESTING:-}" ] && only=(--filter "$ONLY_TESTING")
  (cd "$dir" && swift test --sanitize="$swift_san" --scratch-path ".build/$san" ${only[@]+"${only[@]}"}) >"$tlog" 2>&1
  local rc=$?
  n="$(count_reports "$tlog")"
  grep -E "^[[:space:]]*Executed [0-9]+ tests?|Test run with [0-9]+ tests?" "$tlog" | tail -2 | sed 's/^[[:space:]]*/[san] core: /'
  log "core: $n sanitizer report line(s), swift test exit $rc — $tlog"
  if [ "$n" -gt 0 ]; then verdict 1
  elif ! grep -qE "Executed [0-9]+ tests?, with ([0-9]+ tests? skipped and )?0 failures" "$tlog"; then
    [ "$rc" = 0 ] && verdict 2 || verdict 1
  fi
}

run_hosted() {  # $1 = reader | notes
  local app="$1" dir scheme target tlog="$OUT/$1.log" n
  case "$app" in
    reader) dir="$ROOT/ArchiveReader/macOS"; scheme=ArchiveReader;    target=ArchiveReaderTests ;;
    notes)  dir="$ROOT/ArchiveNotes/macOS";  scheme=ArchiveNotesUnit; target=ArchiveNotesTests ;;
  esac
  (cd "$dir" && xcodegen generate >/dev/null 2>&1) || { log "$app: xcodegen failed"; verdict 2; return; }
  log "$app: xcodebuild test $xc_flag YES -only-testing:${ONLY_TESTING:-$target}…"
  (cd "$dir" && xcodebuild test -scheme "$scheme" -destination 'platform=macOS' "$xc_flag" YES \
      -only-testing:"${ONLY_TESTING:-$target}" -derivedDataPath "./build/$san-DD" -resultBundlePath "$OUT/$app.xcresult") \
      >"$tlog" 2>&1
  n="$(count_reports "$tlog")"
  grep -E "^[[:space:]]*Executed [0-9]+ tests?|Test run with [0-9]+ tests?" "$tlog" | tail -2 | sed "s/^[[:space:]]*/[san] $app: /"
  log "$app: $n sanitizer report line(s) — $tlog"
  if [ "$n" -gt 0 ]; then verdict 1
  elif grep -q '\*\* TEST SUCCEEDED \*\*' "$tlog"; then :
  elif grep -q '\*\* TEST FAILED \*\*' "$tlog"; then log "$app: TEST FAILED"; verdict 1
  else log "$app: no test verdict (build failure?)"; verdict 2
  fi
}

run_processor() {
  [ "$san" = tsan ] || { log "processor: drivers run under TSan only (plan §E); skipped for $san"; return; }
  local dir="$ROOT/ArchiveProcessor" rdir="$OUT/processor" d rc n total=0 failed=()
  rm -rf "$rdir"; mkdir -p "$rdir"
  (cd "$dir/macOS" && xcodegen generate >/dev/null 2>&1) || { log "processor: xcodegen failed"; verdict 2; return; }
  log "processor: Debug build with TSan into macOS/build/DD…"
  (cd "$dir/macOS" && xcodebuild -scheme ArchiveProcessor -configuration Debug -enableThreadSanitizer YES \
      -derivedDataPath ./build/DD build) >"$OUT/processor-build.log" 2>&1 \
    || { log "processor: build FAILED ($OUT/processor-build.log)"; verdict 2; return; }
  for d in ${DRIVERS:-$DEFAULT_DRIVERS}; do
    TSAN_OPTIONS="log_path=$rdir/${d%.sh}.tsan halt_on_error=0" bash "$dir/scripts/$d" >"$rdir/${d%.sh}.out" 2>&1
    rc=$?
    n="$(count_reports "$rdir/${d%.sh}".tsan* "$rdir/${d%.sh}.out")"
    total=$(( total + n ))
    log "processor: $d exit $rc, $n report line(s)"
    [ "$rc" = 0 ] || failed+=("$d")
  done
  log "processor: $total sanitizer report line(s) across the drivers; failed drivers: ${failed[*]:-none} — $rdir"
  [ "$total" -gt 0 ] && verdict 1
  [ ${#failed[@]} -gt 0 ] && verdict 1
  return 0
}

suites=("$@"); [ ${#suites[@]} -gt 0 ] || suites=(core reader notes processor)
for s in "${suites[@]}"; do
  case "$s" in
    core) run_core ;;
    reader|notes) run_hosted "$s" ;;
    processor) run_processor ;;
    *) echo "unknown suite '$s' (use: core | reader | notes | processor)" >&2; exit 2 ;;
  esac
done
case "$worst" in
  0) log "RESULT ($san): no sanitizer report and every run green across: ${suites[*]}" ;;
  1) log "RESULT ($san): a sanitizer report or a failed run — see above" ;;
  2) log "RESULT ($san): could not measure every suite — NOT a clean result" ;;
esac
exit "$worst"
