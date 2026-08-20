#!/usr/bin/env bash
# prove-vm-lane.sh — lock the VM GUI lane's CLASSIFICATION and its shared helpers.
#
# WHY THIS EXISTS. The same defect has now shipped twice: a GUI lane that ran ZERO (or failing) tests and
# was reported to the owner as a green checkmark.
#   1st (2026-07-28): the guest agent wasn't up, every `tart exec` failed, the gate fail-opened `exit 0`,
#                     and health-gate printed "✓ gui-vm". Two days of imaginary coverage.
#   2nd (2026-07-30): the fix added `exit 3 = SKIPPED` — and then the new warn tier collapsed reproducible
#                     failures back into `exit 0`, so a suite that failed twice printed "✓ gui-vm" and a
#                     summary claiming "+ GUI-VM UITests". Same bug, different door. Found by audit.
# The lesson is that the exit-code → owner-visible-text mapping is the load-bearing part, so it gets a
# test. Runs entirely against STUBS — no VM, no network, no Xcode, ~seconds, $0.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LIB="$ROOT/ops/gui/tart-lib.sh"
GATE="$ROOT/ops/autonomous/gui-vm-gate.sh"
HEALTH="$ROOT/ops/autonomous/health-gate.sh"
[ -f "$LIB" ] || { echo "FATAL: $LIB missing"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "== 1. per-app table (one source of truth for both entry points) =="
# shellcheck disable=SC1090
. "$LIB"
for app in reader notes; do
  miss=""
  for f in spec proj scheme tests dd appbundle procname fixture mkfixture launcharg; do
    [ -n "$(archive_app_field "$app" "$f")" ] || miss="$miss $f"
  done
  [ -z "$miss" ] && ok "$app: every field populated" || no "$app: empty field(s):$miss"
done
archive_app_known reader && ok "archive_app_known reader" || no "archive_app_known reader"
archive_app_known processor && no "processor must be UNKNOWN (no UITest target — an unknown app must be loud, not an empty run)" \
                            || ok "processor is unknown (loud, not a silent empty run)"
# The mkfixture strings are eval'd inside a REMOTE bash -lc; $GR/$GC must survive the host unexpanded.
case "$(archive_app_field notes mkfixture)" in
  *'$GC'*|*'$GR'*) ok "mkfixture keeps \$GR/\$GC unexpanded for the guest" ;;
  *) no "mkfixture expanded \$GR/\$GC on the host — the guest command will be wrong" ;;
esac

echo "== 2. VM lock (one writer for a single shared VM + artifact dir) =="
export TART_LOCK_DIR="$TMP/.vm.lock"
tart_lock_acquire 0 && ok "acquire on a free lock" || no "acquire on a free lock"
( . "$LIB"; TART_LOCK_DIR="$TMP/.vm.lock"; tart_lock_acquire 0 ) \
  && no "a second holder was allowed in" || ok "second acquire refused while held"
tart_lock_release && ok "release" || no "release"
( . "$LIB"; TART_LOCK_DIR="$TMP/.vm.lock"; tart_lock_acquire 0 ) && ok "re-acquire after release" || no "re-acquire after release"
rm -rf "$TART_LOCK_DIR"
mkdir -p "$TART_LOCK_DIR"; echo 999999 > "$TART_LOCK_DIR/pid"     # a pid that cannot exist
( . "$LIB"; TART_LOCK_DIR="$TMP/.vm.lock"; tart_lock_acquire 0 ) \
  && ok "reclaims a dead owner's lock (a killed run must not wedge the lane forever)" \
  || no "did not reclaim a dead owner's lock"
rm -rf "$TART_LOCK_DIR"
# release must be a no-op for a process that never held it, or one run frees another's lock
mkdir -p "$TART_LOCK_DIR"; echo $$ > "$TART_LOCK_DIR/pid"
( . "$LIB"; TART_LOCK_DIR="$TMP/.vm.lock"; TART_LOCK_HELD=0; tart_lock_release )
[ -d "$TART_LOCK_DIR" ] && ok "release is a no-op when the lock isn't held" || no "release freed a lock we never held"
rm -rf "$TART_LOCK_DIR"; unset TART_LOCK_DIR

echo "== 3. corpus resolution (gitignored corpus => must work from a worktree too) =="
mkdir -p "$TMP/fake/ArchiveProcessor/Test Files/DeaverLLM"
[ "$(archive_corpus_src "$TMP/fake")" = "$TMP/fake/ArchiveProcessor/Test Files/DeaverLLM" ] \
  && ok "prefers the corpus under the given root" || no "did not prefer the root's corpus"
out="$(HOME="$TMP/nohome" archive_corpus_src "$TMP/empty")"
[ -z "$out" ] && ok "returns empty when no corpus exists (caller must warn, not silently XCTSkip)" \
              || no "returned '$out' with no corpus present"

echo "== 4. THE REGRESSION THAT KEEPS COMING BACK: exit code -> owner-visible text =="
# Drive health-gate's real step_skippable with a stub gate per exit code. A FAILING or UNRUN lane must
# never render as "✓". Extracted rather than reimplemented, so the test tracks the real function.
eval "$(sed -n '/^step_skippable() {/,/^}/p' "$HEALTH")"
run_case() {  # $1 = stub exit code, $2 = stub stdout
  local rc="$1" body="$2" stub="$TMP/stub.sh"
  { echo '#!/usr/bin/env bash'; echo "$body"; echo "exit $rc"; } > "$stub"; chmod +x "$stub"
  LOG="$TMP/log"; : > "$LOG"; fails=""; skips=""; warns=""
  step_skippable gui-vm bash "$stub" 2>&1
}
o="$(run_case 0 'echo "GUI-VM gate: GREEN — reader notes"')"
case "$o" in *"✓ gui-vm"*) ok "exit 0 -> ✓ (a genuine pass)" ;; *) no "exit 0 should print ✓ (got: $o)" ;; esac

o="$(run_case 3 'echo "GUI-VM gate SKIPPED: guest agent never answered"')"
case "$o" in
  *"✓"*) no "exit 3 printed a CHECKMARK — this is the 2026-07-28 silent green" ;;
  *"SKIPPED"*"guest agent"*) ok "exit 3 -> ⊘ SKIPPED, with the reason" ;;
  *) no "exit 3 did not report a skip (got: $o)" ;;
esac

o="$(run_case 4 'echo "GUI-VM gate: WARN — reproducible UITest failures in warn-tier app(s): notes"
echo "NotesGUITests.swift:902: error: -[NotesGUITests testG6] : the reveal seam must be drivable"')"
case "$o" in
  *"✓"*) no "exit 4 printed a CHECKMARK — this is the 2026-07-30 warn-tier silent green" ;;
  *"KNOWN FAILURES"*) ok "exit 4 -> ⚠ KNOWN FAILURES, never a checkmark" ;;
  *) no "exit 4 did not report a warning (got: $o)" ;;
esac
case "$o" in
  *"testG6"*) ok "exit 4 surfaces the failing test NAMES to stdout (last-gate.log), not into a deleted \$LOG" ;;
  *) no "exit 4 hid the failure detail — the owner sees a summary with nothing actionable" ;;
esac

o="$(run_case 2 'echo "boom"')"
case "$o" in *"✗ gui-vm"*) ok "any other rc -> ✗ (a real failure still REDs)" ;; *) no "rc=2 should print ✗ (got: $o)" ;; esac

echo "== 5. the gate declares all four exit codes it can return =="
for code in "0 = GREEN" "1 = RED" "3 = SKIPPED" "4 = WARN"; do
  grep -q "$code" "$GATE" && ok "documents $code" || no "gate header does not document $code"
done
# The fixture must be rebuilt every run: the UITests mutate it, so build-if-absent lets G5/G8 pass once
# and then fail forever, which is how infra breakage got written up as Notes product bugs on 2026-07-30.
grep -q "\[ -d '\$fixture' \] ||" "$GATE" \
  && no "gate builds the fixture only when ABSENT — mutating UITests need a rebuild EVERY run" \
  || ok "fixture is rebuilt every run (not build-if-absent)"

echo "== 6. the xcodebuild PATH shim (catches a whole-scheme test at ANY nesting depth) =="
# The hook sees only the Bash command string, so a wrapper script hides the xcodebuild inside it. The shim
# sits on the child's PATH and intercepts the exec instead. Stub the real tool so nothing actually builds.
SHIM="$ROOT/ops/autonomous/bin/_gui-shim"
[ -x "$SHIM" ] || no "shim missing/not executable at $SHIM"
printf '#!/usr/bin/env bash\necho REAL_XCODEBUILD_RAN "$@"\n' > "$TMP/real"; chmod +x "$TMP/real"
shim() { ARCHIVE_UNATTENDED="$1" ARCHIVE_REAL_TOOL="$TMP/real" bash "$ROOT/ops/autonomous/bin/xcodebuild" "${@:2}" 2>&1; }

o="$(shim 1 test -scheme ArchiveNotes -destination platform=macOS)"
case "$o" in *BLOCKED*) ok "unattended: whole-scheme 'test' refused" ;; *) no "unattended whole-scheme test was ALLOWED (got: ${o:0:80})" ;; esac
case "$o" in *REAL_XCODEBUILD_RAN*) no "the real xcodebuild still ran after a refusal" ;; *) ok "the real xcodebuild never ran" ;; esac

o="$(shim 1 test -scheme ArchiveNotes -only-testing:ArchiveNotesTests)"
case "$o" in *REAL_XCODEBUILD_RAN*) ok "unattended: -only-testing unit run passes through" ;; *) no "unit run was blocked (got: ${o:0:80})" ;; esac

o="$(shim 1 -scheme ArchiveProcessor build)"
case "$o" in *REAL_XCODEBUILD_RAN*) ok "unattended: plain build passes through" ;; *) no "a plain build was blocked" ;; esac

o="$(shim 1 build-for-testing -scheme ArchiveReader)"
case "$o" in *REAL_XCODEBUILD_RAN*) ok "unattended: build-for-testing passes through" ;; *) no "build-for-testing was blocked" ;; esac

o="$(shim 0 test -scheme ArchiveNotes)"
case "$o" in *REAL_XCODEBUILD_RAN*) ok "INTERACTIVE: whole-scheme test passes through untouched" ;; *) no "the shim interfered with an interactive run" ;; esac

echo "== 7. the smoke scripts guard themselves (the documented entry point must be correct, not just blocked) =="
for f in ArchiveNotes/test-smoke.sh ArchiveReader/test-smoke.sh; do
  grep -q 'only-testing' "$ROOT/$f" \
    && ok "$f selects its unit bundle (Notes unconditionally; Reader when unattended)" \
    || no "$f has no unit-target selector — it can run the scheme's UITest bundle on the host"
done
grep -q 'ArchiveNotesUnit' "$ROOT/ArchiveNotes/test-smoke.sh" \
  && ok "Notes smoke uses the unit-only scheme (it cannot build ArchiveNotesUITests)" \
  || no "Notes smoke still uses the mixed ArchiveNotes scheme"

echo "== 8. VM boot mode never puts a window on the owner's display =="
RUNNER="$ROOT/ops/gui/vm-gui-runner.sh"
GATEF="$ROOT/ops/autonomous/gui-vm-gate.sh"
# `--vnc-experimental` is NOT headless: per `tart run --help` it swaps tart's own UI for a VNC server, and
# tart then opens Screen Sharing.app at it — a visible VM window (owner-reported 2026-07-30). The xcuitest
# lane needs no pixels at all, so it must boot --no-graphics; only the sighted lane may use VNC.
grep -q 'gfx=(--no-graphics)' "$RUNNER" && ok "runner defaults to --no-graphics" || no "runner does not default to --no-graphics"
grep -q 'gfx=(--no-graphics --vnc-experimental)' "$RUNNER" \
  && ok "sighted lane keeps --no-graphics alongside VNC (framebuffer, but no viewer ever opens)" \
  || no "sighted lane drops --no-graphics — tart will auto-open Screen Sharing on the owner's display"
grep -q 'close_vm_viewer' "$RUNNER" && ok "runner closes the auto-opened viewer" || no "runner leaves the Screen Sharing viewer open"
grep -q 'SS_WAS_RUNNING' "$RUNNER" \
  && ok "…but only if it did not exist before the boot (never kills the owner's own session)" \
  || no "viewer close is unscoped — it would quit a screen-share the owner had open"
grep -q 'tart run "\$VM" --no-graphics' "$GATEF" && ok "gate boots --no-graphics (always silent)" || no "gate is not booting --no-graphics"

echo "== 9. FORWARD tripwire: any app-hosted test bundle must suppress its window =="
# The window-suppression fix is per-app opt-in (each App calls ArchiveTestHost in init()), so it does NOT
# automatically cover an app that GAINS a test target later — and SUITE_TODO W21.vmgui-d plans exactly that
# for the Processor. Rather than trust a future author to remember, assert the invariant: if a generated
# project has a TEST_HOST, that app must adopt ArchiveTestHost and ship the suppression test. Skips apps
# whose .xcodeproj isn't generated in this checkout (it's gitignored) — those are covered on any machine
# that has built them.
hosted_test_bundle() {   # $1 = project.yml — 0 if it declares an app-hosted unit-test target
  python3 -c 'import re,sys
t=open(sys.argv[1]).read()
i=t.find("targets:")
blocks=re.split(r"\n  (?=\S)", t[i:]) if i>=0 else []
sys.exit(0 if any("bundle.unit-test" in b and "- target:" in b for b in blocks) else 1)' "$1"
}
for app in ArchiveReader ArchiveNotes ArchiveProcessor; do
  spec="$ROOT/$app/macOS/project.yml"
  [ -f "$spec" ] || { no "$app: no project.yml"; continue; }
  # project.yml is authoritative and TRACKED. Reading the generated .xcodeproj instead would make this
  # tripwire silently pass in a fresh clone — precisely where it must not.
  if ! hosted_test_bundle "$spec"; then
    ok "$app: no app-hosted unit-test bundle (nothing to suppress)"; continue
  fi
  grep -rq "ArchiveTestHost" "$ROOT/$app/macOS/Sources" 2>/dev/null \
    && ok "$app: app-hosted -> adopts ArchiveTestHost" \
    || no "$app has an app-hosted test bundle but never calls ArchiveTestHost — its unit suite will open a window on the owner's screen"
  [ -f "$ROOT/$app/macOS/Tests/${app}Tests/TestHostWindowSuppressionTests.swift" ] \
    && ok "$app: ships TestHostWindowSuppressionTests" \
    || no "$app is app-hosted but has no TestHostWindowSuppressionTests — the suppression is unpinned"
done

echo "== 10. every host-GUI mechanism has a PATH shim (not just xcodebuild) =="
BIN="$ROOT/ops/autonomous/bin"
for t in xcodebuild open osascript cliclick emulator; do
  [ -e "$BIN/$t" ] && ok "shim present: $t" || no "no shim for '$t' — a wrapper script can reach the screen through it"
done
# The health gate runs in the daemon LOOP, where no PreToolUse hook applies; it must declare itself.
grep -q 'export ARCHIVE_UNATTENDED=1' "$ROOT/ops/autonomous/health-gate.sh" \
  && ok "health-gate declares ARCHIVE_UNATTENDED (script self-guards apply to it)" \
  || no "health-gate does not set ARCHIVE_UNATTENDED — AUTONOMOUS_GATE_OCR=1 would open the Processor on screen"
grep -q 'ARCHIVE_UNATTENDED' "$ROOT/ArchiveProcessor/scripts/test-smoke.sh" \
  && ok "Processor smoke skips its host launch step when unattended" \
  || no "Processor smoke still runs 'open \$APP' + osascript unattended"

echo "== 11. the fixture build's verdict comes from the GUEST, not from tart's transport (W26.fixwarn) =="
# `tart exec` fails independently of the command it carries: on 2 of the 4 VM runs of 2026-08-09/10 it
# returned StreamClosed / "SendHeader called multiple times" while the fixture built perfectly, and both
# entry points cried "fixture build reported a failure". A warning that fires on a healthy run destroys the
# de-silencing (W26.walk1) it was added for. Stub `tart` so the exec shapes run on the host, and pin all
# three classifications — including that a REAL failure still fails.
STUB_BIN="$TMP/bin"; mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/tart" <<'STUB'
#!/usr/bin/env bash
# `tart exec VM bash -lc BODY` -> run BODY here. STUB_TRANSPORT_MATCH: run it, then fail the way tart does
# (the W26.fixwarn shape). STUB_SKIP_MATCH: the exec never lands at all.
[ "${1:-}" = exec ] || exit 0
body="${5:-}"
if [ -n "${STUB_SKIP_MATCH:-}" ]; then
  case "$body" in *"$STUB_SKIP_MATCH"*)
    echo "Failed to connect to the VM using its control socket" >&2; exit 1 ;;
  esac
fi
bash -c "$body"; rc=$?
if [ -n "${STUB_TRANSPORT_MATCH:-}" ]; then
  case "$body" in *"$STUB_TRANSPORT_MATCH"*)
    echo "Error: internal error (13): transport: SendHeader called multiple times" >&2; exit 1 ;;
  esac
fi
exit "$rc"
STUB
chmod +x "$STUB_BIN/tart"
PATH="$STUB_BIN:$PATH"; export PATH
TART_FIXTURE_TMP="$TMP/guest-tmp"; mkdir -p "$TART_FIXTURE_TMP"

fixcase() {  # $1 = mkfixture text -> sets $frc + $TART_FIXTURE_RC + $TART_FIXTURE_TAIL
  frc=0; tart_build_fixture stub-vm "$1" 5 || frc=$?
}

STUB_TRANSPORT_MATCH=MKFIXOK; export STUB_TRANSPORT_MATCH
fixcase 'echo MKFIXOK'
[ "$frc" = 0 ] && ok "a tart transport error over a SUCCEEDING guest build is NOT reported as a failure" \
               || no "the transport error was reported as a build failure again (rc=$frc) — W26.fixwarn is back"
case "$TART_FIXTURE_TAIL" in
  *MKFIXOK*) ok "…and the build's output still comes back (the step stays de-silenced)" ;;
  *) no "the build output was lost — W26.walk1's de-silencing is undone (tail='$TART_FIXTURE_TAIL')" ;;
esac
unset STUB_TRANSPORT_MATCH

fixcase 'echo MKFIXBAD >&2; exit 3'
{ [ "$frc" = 1 ] && [ "${TART_FIXTURE_RC:-}" = 3 ]; } \
  && ok "a genuinely failing build still FAILS, carrying the guest's own exit code (3)" \
  || no "a failing build was not caught (rc=$frc, guest rc='${TART_FIXTURE_RC:-}')"
case "$TART_FIXTURE_TAIL" in
  *MKFIXBAD*) ok "…and its stderr is in the tail the caller prints" ;;
  *) no "the failing build's stderr never reached the caller (tail='$TART_FIXTURE_TAIL')" ;;
esac

STUB_TRANSPORT_MATCH=MKFIXBAD; export STUB_TRANSPORT_MATCH
fixcase 'echo MKFIXBAD >&2; exit 3'
[ "$frc" = 1 ] && ok "a failing build PLUS a transport error is still a failure (the fix cannot mute a real one)" \
               || no "a real failure was swallowed when the transport also failed (rc=$frc) — strictly worse than crying wolf"
unset STUB_TRANSPORT_MATCH

# UNKNOWN must be its own tier. It is not "failed" (that is the cried-wolf bug) and it is emphatically not
# "passed" — the caller's fixture-presence probe is what settles it.
STUB_SKIP_MATCH=MKFIXOK; export STUB_SKIP_MATCH
fixcase 'echo MKFIXOK'
[ "$frc" = 2 ] && ok "an exec that never lands is UNKNOWN (rc=2), not a failure and not a pass" \
               || no "a non-landing exec classified as $frc — the three tiers have collapsed"

# The run-unique token is load-bearing, not decoration. Stage the real hazard: a run whose CLEANUP exec is
# dropped (as droppable as any other) leaves its status file on the guest; the NEXT run must not read it.
# With a fixed path that leftover reports success for a build that never ran — silently swallowing a real
# failure, which is strictly worse than the cried-wolf warning this item is about.
STUB_SKIP_MATCH='rm -f '
fixcase 'echo MKFIXOK'
[ "$frc" = 0 ] && ok "a run whose cleanup exec is dropped still passes (leaving its .rc behind)" \
               || no "the dropped-cleanup run misreported itself (rc=$frc)"
STUB_SKIP_MATCH=MKFIXOK
fixcase 'echo MKFIXOK'
[ "$frc" = 2 ] \
  && ok "…and the NEXT run does not read that leftover as its own status (run-unique token)" \
  || no "read the PREVIOUS run's status as this run's (rc=$frc) — a real failure could be silently swallowed"
unset STUB_SKIP_MATCH
PATH="${PATH#"$STUB_BIN":}"

# Both entry points must go through the helper — the whole point of tart-lib.sh is that a fix cannot land
# in only one of them, and this bug shipped in BOTH.
for f in ops/gui/vm-gui-runner.sh ops/autonomous/gui-vm-gate.sh; do
  grep -q 'tart_build_fixture' "$ROOT/$f" \
    && ok "$f builds the fixture through tart_build_fixture" \
    || no "$f still infers the fixture build's fate from tart exec's own status"
  grep -qE 'tart exec .*(MKFIXTURE|\$mk)' "$ROOT/$f" \
    && no "$f still has a raw 'tart exec … \$mk' — the transport verdict is back" \
    || ok "$f has no raw mkfixture exec left"
done

echo
echo "prove-vm-lane: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
