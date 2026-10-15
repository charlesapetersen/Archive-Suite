#!/usr/bin/env bash
# leaks-harvest.sh — run a unit suite under `leaks` and fail on a leak in OUR code (W40.e2).
#
# USAGE:  ops/verify/leaks-harvest.sh [core|reader|notes ...]     (default: all three)
# ENV:    LEAKS_OUT (default /tmp/leaks-harvest), ONLY_TESTING (narrow the suite, e.g. a single class)
# EXIT:   0 = every suite ran green with no leak of ours · 1 = a leak of ours, or a failed test run
#         2 = could not measure (no report, the hold never appeared) — never read as clean
#
# HOW, per suite — two mechanisms, because one does not work for the app-hosted bundles:
#   core            `leaks -atExit -- xctest ArchiveCoreTests.xctest`: plain, xctest is the process.
#   reader / notes  the bundles are hosted by the app, and `-atExit` injects itself with
#                   DYLD_INSERT_LIBRARIES, which replaces Xcode's own injector: the runner never connects
#                   (measured 2026-10-15). Instead the bundle's principal class, LeakHarvestHold.swift,
#                   pauses after the last test when TEST_RUNNER_AS_LEAKS_HOLD=1 and prints its pid; this
#                   script runs `leaks <pid>` on it and releases it with SIGUSR1.
# MallocStackLogging=lite is on for every suite so each leak carries its allocation stack, which is what
# leaks-classify.py uses to tell our leaks from Apple's (its header has the numbers: a clean Notes run
# reports 210 framework leaks). Reports land in $LEAKS_OUT/<suite>-leaks.txt for reading.
set -uo pipefail
. "$(dirname "$0")/../autonomous/heavy-enter.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${LEAKS_OUT:-/tmp/leaks-harvest}"
CLASSIFY="$HERE/leaks-classify.py"
HOLD_WAIT="${HOLD_WAIT:-2400}"   # seconds to wait for the suite to reach its hold (Reader's bundle is long)
export PATH="/opt/homebrew/bin:$PATH"
mkdir -p "$OUT"
log() { printf '\033[36m[leaks]\033[0m %s\n' "$*"; }

worst=0
verdict() {  # $1 = rc to fold in: 1 beats 2 beats 0
  case "$1" in 1) worst=1 ;; 2) [ "$worst" = 0 ] && worst=2 ;; esac
  return 0
}

run_core() {
  local dir="$ROOT/packages/ArchiveCore" bundle rep="$OUT/core-leaks.txt" tlog="$OUT/core-tests.log"
  log "core: swift build --build-tests…"
  (cd "$dir" && swift build --build-tests >"$OUT/core-build.log" 2>&1) || { log "core: build FAILED ($OUT/core-build.log)"; verdict 1; return; }
  bundle="$(ls -d "$dir"/.build/debug/*Tests.xctest 2>/dev/null | head -1)"
  [ -n "$bundle" ] || { log "core: no test bundle found"; verdict 2; return; }
  log "core: leaks -atExit -- xctest $(basename "$bundle")…"
  local only=()
  [ -n "${ONLY_TESTING:-}" ] && only=(-XCTest "$ONLY_TESTING")
  (cd "$dir" && leaks -atExit -- "$(xcrun --find xctest)" ${only[@]+"${only[@]}"} "$bundle") >"$rep" 2>&1
  grep -E "^[[:space:]]*Executed [0-9]+ tests?" "$rep" | tail -1 | sed 's/^[[:space:]]*/[leaks] core: /'
  # leaks' own exit status says only "leaks or not", so the TESTS' verdict is read from their summary.
  if ! grep -qE "Executed [0-9]+ tests?, with ([0-9]+ tests? skipped and )?0 failures" "$rep"; then
    log "core: the test run FAILED or never finished (see $rep)"; verdict 1
  fi
  classify core "$rep"
}

run_hosted() {  # $1 = reader | notes
  local app="$1" dir scheme bundle_target rep="$OUT/$1-leaks.txt" tlog="$OUT/$1-tests.log" pid="" waited=0 xpid
  case "$app" in
    reader) dir="$ROOT/ArchiveReader/macOS"; scheme=ArchiveReader;     bundle_target=ArchiveReaderTests ;;
    notes)  dir="$ROOT/ArchiveNotes/macOS";  scheme=ArchiveNotesUnit;  bundle_target=ArchiveNotesTests ;;
  esac
  (cd "$dir" && xcodegen generate >/dev/null 2>&1) || { log "$app: xcodegen failed"; verdict 2; return; }
  : >"$tlog"; rm -f "$rep"
  log "$app: xcodebuild test -only-testing:${ONLY_TESTING:-$bundle_target} with the leak hold on…"
  ( cd "$dir" && TEST_RUNNER_AS_LEAKS_HOLD=1 TEST_RUNNER_MallocStackLogging=lite \
      xcodebuild test -scheme "$scheme" -destination 'platform=macOS' \
      -only-testing:"${ONLY_TESTING:-$bundle_target}" -derivedDataPath ./build/DD >"$tlog" 2>&1 ) &
  xpid=$!
  while [ "$waited" -lt "$HOLD_WAIT" ]; do
    pid="$(sed -n 's/.*\[leaks-hold\] pid=\([0-9][0-9]*\).*/\1/p' "$tlog" | head -1)"
    [ -n "$pid" ] && break
    kill -0 "$xpid" 2>/dev/null || break
    sleep 5; waited=$(( waited + 5 ))
  done
  if [ -n "$pid" ]; then
    log "$app: suite reached its hold (pid $pid) — running leaks…"
    leaks "$pid" >"$rep" 2>&1
    kill -USR1 "$pid" 2>/dev/null
  else
    log "$app: the hold never appeared (build or test-host failure, or HOLD_WAIT=${HOLD_WAIT}s passed) — see $tlog"
  fi
  wait "$xpid"
  grep -E "^[[:space:]]*Executed [0-9]+ tests?" "$tlog" | tail -1 | sed "s/^[[:space:]]*/[leaks] $app: /"
  if ! grep -q '\*\* TEST SUCCEEDED \*\*' "$tlog"; then
    log "$app: the test run FAILED or never finished (see $tlog)"; verdict 1
  fi
  [ -n "$pid" ] || { verdict 2; return; }
  classify "$app" "$rep"
}

classify() {  # $1 = suite, $2 = report
  local rc=0
  /usr/bin/python3 "$CLASSIFY" "$2" | sed "s/^/[leaks] $1: /" || true
  /usr/bin/python3 "$CLASSIFY" "$2" >/dev/null || rc=$?
  verdict "$rc"
  log "$1: full report $2"
}

suites=("$@"); [ ${#suites[@]} -gt 0 ] || suites=(core reader notes)
for s in "${suites[@]}"; do
  case "$s" in
    core) run_core ;;
    reader|notes) run_hosted "$s" ;;
    *) echo "unknown suite '$s' (use: core | reader | notes)" >&2; exit 2 ;;
  esac
done
case "$worst" in
  0) log "RESULT: no leak in our code across: ${suites[*]}" ;;
  1) log "RESULT: a leak in our code or a failed test run — see above" ;;
  2) log "RESULT: could not measure every suite — NOT a clean result" ;;
esac
exit "$worst"
