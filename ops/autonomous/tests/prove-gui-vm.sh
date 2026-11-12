#!/usr/bin/env bash
# prove-gui-vm.sh — mechanism proof for gui-vm-gate.sh, with a fake Tart/XcodeGen on PATH.
#
# It executes the REAL gate, not a copy: proves the round-robin state selects exactly one of all three
# apps, preserves the fail-open infrastructure posture, retries a marker failure once, and files every
# app's evidence below its own artifact directory. No VM, GUI, Xcode, corpus, or network is involved.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/../gui-vm-gate.sh"
[ -f "$GATE" ] || { echo "cannot find gate: $GATE"; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/prove-gui-vm.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
# The Mac-wide lock is SCRATCH here (7 Oct 2026). The shim and the real gate this drives reach heavy-run.py, and
# with the real lock they queued behind real work — for hours, inside the gate's unlocked light block — then held
# the Mac-wide lock for a fake tool and wrote fake jobs into waits.log, holds.log and the manager's heavy-jobs.log.
export TART_TEST_POLL=1   # tart_run_test's guard poll: 10 s in real runs, 1 s against the fake
export AUTONOMOUS_HEAVY_STATE="$ROOT/heavy" MAC_HEAVY_LOCK="$ROOT/mac-heavy.lock" AGENT_MANAGER_HEAVY_LOCK="$ROOT/no manager installed"
unset AGENT_MANAGER_STATE HEAVY_LOCK_FILE ARCHIVE_HEAVY_TOKEN MAC_HEAVY_HELD AUTONOMOUS_WORKER_STATE
BIN="$ROOT/bin"; ART="$ROOT/artifacts"; STATE="$ROOT/state/next-app"; CALLS="$ROOT/calls.log"
mkdir -p "$BIN" "$ART"

cat > "$BIN/xcodegen" <<'EOF'
#!/usr/bin/env bash
printf 'xcodegen %s\n' "$*" >> "$GUI_VM_FAKE_CALLS"
exit 0
EOF

cat > "$BIN/tart" <<'EOF'
#!/usr/bin/env bash
set -u
calls="${GUI_VM_FAKE_CALLS:?}"; count="${GUI_VM_FAKE_COUNT:?}"
printf 'tart %s\n' "$*" >> "$calls"
case "${1:-}" in
  list)
    [ "${GUI_VM_FAKE_MODE:-pass}" = missing_vm ] && exit 0
    # tart_stop_clean polls `tart list --format json` until the guest reports stopped (W40.vm-macos27).
    # Answer it in JSON, or every simulated stop waits out its 60 s limit: on 2026-11-06 that made this
    # proof take 1,083 s and pushed the gate past its 3,000 s cap twice.
    case " $* " in
      *" --format json "*) printf '%s\n' '[{"Name":"archive-gui-runner","Running":false,"State":"stopped"}]'; exit 0 ;;
    esac
    printf '%s\n' 'Source Name Disk Size Accessed State' 'local archive-gui-runner 120 91 stopped'
    ;;
  stop|run|ip) exit 0 ;;
  exec)
    shift 2 # VM name, then `bash -lc <guest command>` in every gate path
    cmd="${*: -1}"
    printf 'guest %s\n' "$cmd" >> "$calls"
    case "$cmd" in
      *'xcodebuild test'*)
        n=0; [ -f "$count" ] && n="$(cat "$count")"; n=$(( n + 1 )); printf '%s\n' "$n" > "$count"
        app=unknown
        case "$cmd" in
          *ArchiveReader*) app=reader ;;
          *ArchiveNotes*) app=notes ;;
          *ArchiveProcessor*) app=processor ;;
        esac
        printf "Test Case '-[Fake.%s testRenderedSurface]' started.\n" "$app"
        case "${GUI_VM_FAKE_MODE:-pass}:$n" in
          fail:*|flaky:1|processor_no_window:*)
            printf "Test Case '-[Fake.%s testRenderedSurface]' failed (0.01 seconds).\n" "$app"
            [ "${GUI_VM_FAKE_MODE:-pass}" = processor_no_window ] && printf '%s\n' 'PROCESSOR_UI_NO_WINDOW'
            printf '%s\n' '** TEST FAILED **'
            ;;
          infra:*)
            printf '%s\n' 'guest transport ended before a test verdict'
            ;;
          hang_pass:*|hang_fail:*|stall:*)
            # W40.vm-macos27-runtime: the macOS 27.2 guest's xcodebuild that never exits. It prints XCTest's
            # summary (or, for stall, nothing more) and then waits until the guard's pkill arrives.
            if [ "${GUI_VM_FAKE_MODE}" = hang_fail ]; then
              printf "Test Case '-[Fake.%s testRenderedSurface]' failed (0.01 seconds).\n" "$app"
              printf '%s\n' "Test Suite 'Selected tests' failed at 2026-11-12 10:00:00.000." \
                '	 Executed 1 test, with 1 failure (0 unexpected) in 0.01 (0.01) seconds'
            elif [ "${GUI_VM_FAKE_MODE}" = hang_pass ]; then
              printf "Test Case '-[Fake.%s testRenderedSurface]' passed (0.01 seconds).\n" "$app"
              printf '%s\n' "Test Suite 'Selected tests' passed at 2026-11-12 10:00:00.000." \
                '	 Executed 1 test, with 0 failures (0 unexpected) in 0.01 (0.01) seconds'
            fi
            while [ ! -f "$count.killed" ]; do sleep 0.2; done
            rm -f "$count.killed"
            exit 143
            ;;
          *)
            printf "Test Case '-[Fake.%s testRenderedSurface]' passed (0.01 seconds).\n" "$app"
            printf '%s\n' '** TEST SUCCEEDED **'
            ;;
        esac
        ;;
      *'pkill -TERM -x xcodebuild'*) : > "$count.killed" ;;
      *'df -Pk'*)
        if [ "${GUI_VM_FAKE_MODE:-pass}" = full_disk ]; then
          printf '%s\n' 'storage: only 4 KiB free (need at least 6291456 KiB)'; exit 1
        fi
        printf '%s\n' 'storage: reusing fake DerivedData (99999999 KiB free)'
        ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/tart" "$BIN/xcodegen"

fail=0
pass() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
want() { grep -Fq -- "$2" "$1" && pass "$3" || bad "$3 (missing: $2)"; }
want_not() { grep -Fq -- "$2" "$1" && bad "$3 (unexpected: $2)" || pass "$3"; }

run_gate() { # mode expected-exit label
  local mode="$1" expected="$2" label="$3" out rc
  out="$ROOT/$label.out"
  : > "$CALLS"; : > "$ROOT/count"
  GUI_VM_FAKE_MODE="$mode" GUI_VM_FAKE_CALLS="$CALLS" GUI_VM_FAKE_COUNT="$ROOT/count" \
    AUTONOMOUS_GUI_VM_PAUSED="${PAUSED-}" AUTONOMOUS_GUI_VM_BIN_DIR="$BIN" AUTONOMOUS_GUI_VM_APPS="reader notes processor" \
    AUTONOMOUS_GUI_VM_STATE="$STATE" ART_DIR="$ART" TART_LOCK_DIR="$ROOT/lock" \
    "$GATE" >"$out" 2>&1
  rc=$?
  [ "$rc" = "$expected" ] && pass "$label exits $expected" || bad "$label exits $rc (wanted $expected)"
}

# State begins empty, so the three executions must pick reader → notes → processor, one Xcode test each.
run_gate pass 0 round-reader
want "$CALLS" 'ArchiveReader/macOS/ArchiveReader.xcodeproj' 'first round selects Reader'
want_not "$CALLS" 'ArchiveNotes/macOS/ArchiveNotes.xcodeproj' 'first round does not also run Notes'
want "$CALLS" '-only-testing:ArchiveReaderUITests -only-testing:ArchiveReaderTests/SnapshotTests' \
  'Reader gate keeps both the UI suite and VM-only snapshot selector'
want "$STATE" 'reader' 'state records Reader'
[ -f "$ART/reader/xcuitest-attempt1.log" ] && pass 'Reader log is namespaced' || bad 'Reader log is namespaced'

run_gate pass 0 round-notes
want "$CALLS" 'ArchiveNotes/macOS/ArchiveNotes.xcodeproj' 'second round selects Notes'
want_not "$CALLS" 'ArchiveProcessor/macOS/ArchiveProcessor.xcodeproj' 'second round does not also run Processor'
want "$STATE" 'notes' 'state records Notes'

run_gate pass 0 round-processor
want "$CALLS" 'ArchiveProcessor/macOS/ArchiveProcessor.xcodeproj' 'third round selects Processor'
want_not "$CALLS" 'ArchiveReader/macOS/ArchiveReader.xcodeproj' 'third round does not restart Reader'
want "$STATE" 'processor' 'state records Processor'
[ -f "$ART/processor/xcuitest-attempt1.log" ] && pass 'Processor log is namespaced' || bad 'Processor log is namespaced'

# A decisive marker failure retries once then REDs; a no-marker infrastructure result and a full guest disk
# both SKIP. Reset state each time so the expected app and artifact assertions remain deterministic.
printf '%s\n' reader > "$STATE"
run_gate fail 1 reproducible-failure
want "$ROOT/reproducible-failure.out" 'RED — reproducible UITest failure in: notes' 'two failed markers RED the selected app'
[ "$(cat "$ROOT/count")" = 2 ] && pass 'marker failure retries exactly once' || bad 'marker failure retries exactly once'

printf '%s\n' notes > "$STATE"
run_gate flaky 0 retry-green
want "$ROOT/retry-green.out" 'GREEN on retry' 'a passing retry is reported as a flake, not RED'
[ "$(cat "$ROOT/count")" = 2 ] && pass 'flaky marker failure retries exactly once' || bad 'flaky marker failure retries exactly once'

# A Processor launch-state marker is a distinct, screenshot-bearing infrastructure outcome. It must not
# retry or RED, otherwise a guest keychain/unlock panel could park the daemon for a product it never ran.
printf '%s\n' notes > "$STATE"
run_gate processor_no_window 3 processor-no-window-skip
want "$ROOT/processor-no-window-skip.out" 'Processor did not expose a window' 'missing Processor window is fail-open SKIPPED'
[ "$(cat "$ROOT/count")" = 1 ] && pass 'missing Processor window does not retry into a false RED' || bad 'missing Processor window does not retry into a false RED'

printf '%s\n' processor > "$STATE"
run_gate infra 3 infra-skip
want "$ROOT/infra-skip.out" 'SKIPPED: inconclusive for: reader' 'no verdict marker is fail-open SKIPPED'

printf '%s\n' reader > "$STATE"
run_gate full_disk 3 full-disk-skip
want "$ROOT/full-disk-skip.out" 'SKIPPED: inconclusive for: notes' 'full guest disk is fail-open SKIPPED'
want_not "$CALLS" 'xcodebuild test' 'full guest disk never starts an Xcode build'

# The build tool that stays up after its summary (W40.vm-macos27-runtime (2)): the guard ends it, and the
# verdict is XCTest's own summary line — passed is GREEN on the first attempt, failed retries and REDs.
printf '%s\n' reader > "$STATE"
TART_TEST_GRACE=2 run_gate hang_pass 0 hang-after-pass
want "$ART/notes/xcuitest-attempt1.log" '[guard] summary:' 'a build tool idle after a passed summary is ended by the guard'
[ "$(cat "$ROOT/count")" = 1 ] && pass 'a guard-ended passed run is not retried' || bad 'a guard-ended passed run is not retried'
printf '%s\n' reader > "$STATE"
TART_TEST_GRACE=2 run_gate hang_fail 1 hang-after-fail
want "$ROOT/hang-after-fail.out" 'RED — reproducible UITest failure in: notes' 'a guard-ended failed summary still REDs'
# A run that goes silent before any summary is ended too, and says nothing either way: SKIPPED.
printf '%s\n' reader > "$STATE"
TART_TEST_STALL=3 run_gate stall 3 stalled-skip
want "$ART/notes/xcuitest-attempt1.log" '[guard] stalled:' 'a silent run is ended by the stall guard'
want "$ROOT/stalled-skip.out" 'SKIPPED: inconclusive for: notes' 'a stalled run is fail-open SKIPPED, never GREEN'

run_gate missing_vm 3 missing-vm-skip
want "$ROOT/missing-vm-skip.out" "VM 'archive-gui-runner' does not exist" 'missing VM is fail-open SKIPPED'

# The pause (W40.vm-gate-unpause): a skip that names its reason, before any boot or Xcode run.
PAUSED='a test reason' run_gate pass 3 paused-skip
want "$ROOT/paused-skip.out" 'SKIPPED: paused: a test reason' 'the pause is a SKIPPED that names its reason'
want_not "$CALLS" 'tart run' 'the pause never boots the VM'
# Unset (not empty) means the gate's own default pause, which names the item that owns it.
( unset PAUSED; : > "$CALLS"; GUI_VM_FAKE_MODE=pass GUI_VM_FAKE_CALLS="$CALLS" GUI_VM_FAKE_COUNT="$ROOT/count" \
    AUTONOMOUS_GUI_VM_BIN_DIR="$BIN" AUTONOMOUS_GUI_VM_STATE="$STATE" ART_DIR="$ART" TART_LOCK_DIR="$ROOT/lock" \
    env -u AUTONOMOUS_GUI_VM_PAUSED "$GATE" >"$ROOT/default-pause.out" 2>&1; echo "rc=$?" >>"$ROOT/default-pause.out" )
want "$ROOT/default-pause.out" 'W40.vm-gate-unpause' 'the default pause names W40.vm-gate-unpause'
want "$ROOT/default-pause.out" 'rc=3' 'the default pause exits 3 (SKIPPED)'

# A whole run of this proof must stay short: the gate's 50-minute cap has to leave room for the real VM lane.
[ "$SECONDS" -lt 300 ] && pass "proof ran in ${SECONDS}s (under 300 s)" || bad "proof took ${SECONDS}s (300 s is the most it should take)"

echo
[ "$fail" = 0 ] && echo 'prove-gui-vm: ALL PASSED' || echo 'prove-gui-vm: FAILURES'
exit "$fail"
