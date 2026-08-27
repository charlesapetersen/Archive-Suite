#!/usr/bin/env bash
# gui-vm-gate.sh — the GUI-UITest step of the periodic health gate (health-gate.sh), run inside a
# headless Tart VM so it NEVER touches the owner's screen and never hangs the host with the "Enable UI
# Automation" prompt.
#
# Covers EVERY app that ships a UITest bundle — Reader, Notes, and Processor. One app runs per health-gate
# invocation, selected round-robin from the configured pool, so three 20-minute caps cannot exceed the
# daemon's 50-minute whole-gate deadline. Set AUTONOMOUS_GUI_VM_APPS to a subset when diagnosing a lane.
#
# SAFETY POSTURE (Tier-2 autonomous infra — biased hard toward fail-open):
#   • ON by default. Set AUTONOMOUS_GUI_VM=0 to disable.
#   • A missing VM, a boot failure, a guest-agent timeout, or any non-test error → SKIP. Infra must
#     NEVER park the run.
#   • RED ONLY on a reproducible UITest failure — keyed on the definitive "** TEST FAILED **" marker
#     (not an exit code, so a VM/SPM/infra hiccup can't false-park) and only after ONE retry.
#   • Always leaves the VM stopped (trap).
#
# EXIT CODES — three, not two. This is the fix for the 2026-07-29 SILENT GREEN: the gate used to exit 0
# for "skipped" as well as "passed", so health-gate.sh printed a bare "✓ gui-vm" for a lane that had
# never executed a single test (the guest agent was down; the skip reason went to a temp log that is
# only shown on RED). A skipped GUI lane now reports itself as skipped, all the way up.
#   0 = GREEN   every selected app's UITests ran and passed
#   1 = RED     a reproducible UITest failure (park)
#   3 = SKIPPED nothing conclusive ran (infra) — caller must SAY SO, never print a checkmark
#   4 = WARN    a warn-tier app's UITests reproducibly FAILED (don't park, but never call this green)
#
# 4 exists because the first version of the warn tier reintroduced the very bug above through another
# door: warn-tier failures fell through to `exit 0`, so health-gate printed "✓ gui-vm" and a summary
# claiming "+ GUI-VM UITests" for a suite that had just failed twice — and the failure list, written to
# the gate's stdout, was captured into health-gate's $LOG, which is shown only on RED and deleted on exit.
# A failing suite must never be reported as a checkmark. Found by an adversarial audit, 2026-07-30.
#
# Knobs: AUTONOMOUS_GUI_VM_NAME (default archive-gui-runner), AUTONOMOUS_GUI_VM_MAXRUN (per-app, 1200s),
#        AUTONOMOUS_GUI_VM_APPS (default "reader notes processor"), AUTONOMOUS_GUI_VM_AGENTWAIT (default 240s),
#        AUTONOMOUS_GUI_VM_STATE (round-robin state; default $ROOT/.maintenance/gui-vm-next-app).
set -uo pipefail
# The normal Homebrew prefix is retained as belt-and-braces above tart-lib's shared resolver. The
# override is deliberately only a directory prefix, used by the mechanism proof's fake `tart`; production
# leaves it unset and therefore cannot change which system tools are used.
export PATH="${AUTONOMOUS_GUI_VM_BIN_DIR:-/opt/homebrew/bin}:$PATH"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VM="${AUTONOMOUS_GUI_VM_NAME:-archive-gui-runner}"
MAXRUN="${AUTONOMOUS_GUI_VM_MAXRUN:-1200}"
AGENTWAIT="${AUTONOMOUS_GUI_VM_AGENTWAIT:-240}"
APP_POOL="${AUTONOMOUS_GUI_VM_APPS:-reader notes processor}"
STATE="${AUTONOMOUS_GUI_VM_STATE:-$ROOT/.maintenance/gui-vm-next-app}"
# Apps whose UITest failures WARN instead of REDding the gate. The point of the warn tier is that a suite
# with known failures still RUNS and reports every gate — visibility without parking a multi-day run on a
# regression that is already tracked. An app graduates out of this list the moment its suite is green.
# EMPTY by default since 2026-08-01 (W21.vmgui-c): notes was the only entry, and its 4/12 VM failures are
# fixed — one harness/layout cause, not four bugs (the guest booted at 1024×768 and the browser understated
# its own minimum width, so ~92 pt of the right pane sat off-window). Notes is currently 21/21 in the VM; both apps
# now RED the gate on a failure, which is the point. Do not re-add an app here without a tracked item: a
# permanent warn tier is a disabled test with extra steps.
WARN_APPS="${AUTONOMOUS_GUI_VM_WARN_APPS:-}"
ART="${ART_DIR:-$HOME/.tart-mirror/vm-artifacts}"
GLOG="$ART/gui-vm-gate.log"
# Per-app table and the guest-agent wait are SHARED with ops/gui/vm-gui-runner.sh
# via ops/gui/tart-lib.sh. That sharing is deliberate and load-bearing: on 2026-07-30 the guest-agent race
# was fixed HERE and not in the runner, leaving the interactive entry point broken in exactly the way this
# one had just been fixed. One copy, so a fix cannot land in only half the lane.
. "$ROOT/ops/gui/tart-lib.sh"

skip() { echo "GUI-VM gate SKIPPED: $*"; exit 3; }

# ---- guards (each SKIPs; a missing prereq must never RED) --------------------------------------
[ "${AUTONOMOUS_GUI_VM:-1}" = 1 ] || skip "disabled (AUTONOMOUS_GUI_VM=0)"
# tart-vs-VM stays two distinct skips (W21.vmgui-path). The PATH fix now lives in tart-lib.sh so BOTH
# entry points get it; the prefix above is kept as belt-and-braces for the lines above the source.
tart_require || skip "tart not installed or not on PATH (details above) — the VM's existence is unknown"
tart list 2>/dev/null | awk '{print $2}' | grep -qx "$VM" || skip "tart is installed, but VM '$VM' does not exist (build it — ops/gui/README.md §3)"
command -v xcodegen >/dev/null || skip "xcodegen not on the host PATH (it generates the projects the VM builds)"
mkdir -p "$ART"
if command -v gtimeout >/dev/null; then TO=(gtimeout "$MAXRUN"); else TO=(); fi

# Only stop the VM if WE booted it, and always drop the lock. The old unconditional `tart stop` fired even
# on the pre-boot skips below, which on a shared machine means killing a VM another run legitimately owns.
VM_BOOTED=0
cleanup() {
  [ "$VM_BOOTED" = 1 ] && tart stop "$VM" >/dev/null 2>&1
  tart_lock_release
  return 0
}
trap cleanup EXIT

# One writer at a time (see tart_lock_acquire). Waiting a few minutes then SKIPping is the right posture:
# a busy VM is infra, and infra must never park the run.
tart_lock_acquire "${AUTONOMOUS_GUI_VM_LOCKWAIT:-300}" \
  || skip "the GUI VM is in use by another run (pid ${TART_LOCK_OWNER:-?}) — not competing for it"

# ---- round-robin selection ----------------------------------------------------------------------
# Advancing the state before boot is intentional: a missing VM or a full guest disk is an inconclusive
# attempt for THIS lane, not a reason to starve the other two on every later health gate. The lock above
# serializes the read/advance/write with the interactive runner's VM ownership.
select_app() {
  local candidate first="" last="" selected="" take_next=0 tmp
  for candidate in $APP_POOL; do
    archive_app_known "$candidate" || skip "unknown app '$candidate' in AUTONOMOUS_GUI_VM_APPS (known: reader notes processor)"
    [ -n "$first" ] || first="$candidate"
    if [ "$take_next" = 1 ]; then selected="$candidate"; break; fi
    [ "$candidate" = "$last" ] && take_next=1
  done
  [ -n "$first" ] || skip "AUTONOMOUS_GUI_VM_APPS is empty (need at least one of: reader notes processor)"
  [ -f "$STATE" ] && IFS= read -r last < "$STATE" || true
  # Re-run after loading state: the first walk validates the pool without coupling the state file to it.
  selected=""; take_next=0
  for candidate in $APP_POOL; do
    if [ "$take_next" = 1 ]; then selected="$candidate"; break; fi
    [ "$candidate" = "$last" ] && take_next=1
  done
  [ -n "$selected" ] || selected="$first"
  if mkdir -p "$(dirname "$STATE")" 2>/dev/null && tmp="$(mktemp "${STATE}.tmp.XXXXXX" 2>/dev/null)"; then
    printf '%s\n' "$selected" > "$tmp" && mv -f "$tmp" "$STATE" || rm -f "$tmp"
  else
    echo "WARN: GUI-VM round-robin state could not be updated at $STATE; this run is $selected, but later gates may repeat it." >&2
  fi
  APPS="$selected"
}
select_app

# ---- boot ---------------------------------------------------------------------------------------
# WHY the guest-agent wait exists (the 2026-07-29 failure, root-caused 2026-07-30): `tart ip --wait`
# returns as soon as the guest has NETWORKING, but `tart exec` talks over a separate vsock control
# socket served by the Tart Guest Agent, which comes up LATER. The old gate called `tart exec`
# immediately after the IP appeared and got
#     "Failed to connect to the VM using its control socket … is the Tart Guest Agent running?"
# — every exec in that run then failed, including the fixture-presence probe (hence its bogus
# "GUI fixture absent" warning), and the gate fell through to its fail-open skip. Confirmed by hand:
# the identical `tart exec` succeeds seconds later. So poll the agent until it actually answers.
boot_vm() {
  tart stop "$VM" >/dev/null 2>&1 || true
  local mounts=(--dir=repo:"$ROOT" --dir=out:"$ART")
  VM_BOOTED=1
  tart run "$VM" --no-graphics "${mounts[@]}" >>"$GLOG" 2>&1 &
  tart ip "$VM" --wait 120 >/dev/null 2>&1 || return 1
  tart_wait_agent "$VM" "$AGENTWAIT" || return 2
  echo "guest agent ready after ${TART_AGENT_WAITED}s" >>"$GLOG"
  # The guest's SCREEN SIZE, not the VM's configured one: --no-graphics boots the WindowServer at
  # 1024×768, below the Notes browser's ~1084 pt minimum, which clips its right pane off-window and made
  # 4 UITests fail as "not hittable" (W21.vmgui-c). Never silent, never fatal — Reader is green either way.
  if tart_ensure_display "$VM"; then
    echo "${TART_DISPLAY_NOTE:-guest display OK}" >>"$GLOG"
  else
    echo "WARN: could not raise the guest display to ${TART_VM_DISPLAY:-1920x1200} — Notes UITests will likely fail as 'not hittable'. Guest said: ${TART_DISPLAY_NOTE:-(no output)}" >>"$GLOG"
  fi
  # Can the guest still SERVE the accessibility tree? XCUITest reads nothing else, so when the answer is
  # no, every window assertion in every bundle fails as "Main window should appear" — a sentence that
  # reads like a product regression and is not one. That is not a hypothetical: on 2026-08-10 the guest
  # agent's Accessibility grant stopped matching its own code requirement, all 37 UITests across BOTH apps
  # went red twice, and this gate parked the daemon citing "a reproducible build/test regression the
  # per-change reviews missed" while the apps were drawing their windows perfectly the whole time.
  # A lane that cannot see is INCONCLUSIVE, never RED — hence a skip (exit 3), like every other
  # infrastructure failure here. → ops/gui/vm-check-accessibility.swift, repaired by vm-seed-accessibility.sh
  if ! tart exec "$VM" bash -lc "swift '$GUEST_REPO/ops/gui/vm-check-accessibility.swift'" >>"$GLOG" 2>&1; then
    return 3
  fi
  return 0
}

# ---- per-app run --------------------------------------------------------------------------------
# One log PER APP PER ATTEMPT. Per-app so one app's "** TEST FAILED **" is never read as another's;
# per-attempt because the retry used to truncate the first attempt's log and destroy the only record of
# what actually failed — the retry is a flake guard, not a reason to lose evidence.
app_art()    { echo "$ART/$1"; }
applog()     { echo "$(app_art "$1")/xcuitest-attempt$2.log"; }
is_fail()    { grep -q '\*\* TEST FAILED \*\*'    "$(applog "$1" "$2")" 2>/dev/null; }
is_success() { grep -q '\*\* TEST SUCCEEDED \*\*' "$(applog "$1" "$2")" 2>/dev/null; }
# A missing Processor window can mean a guest keychain/unlock/modal failure, not an app regression. The
# test itself saves a rendered screenshot before emitting this marker; classify it as infrastructure.
is_processor_no_window() { [ "$1" = processor ] && grep -q '^PROCESSOR_UI_NO_WINDOW$' "$(applog "$1" "$2")" 2>/dev/null; }

run_app_once() {   # $1 = app, $2 = attempt number
  local app="$1" attempt="$2" log fixture mk prerun proj scheme tests dd bundle frc ddrc result_art
  mkdir -p "$(app_art "$app")"
  log="$(applog "$app" "$attempt")"; : > "$log"
  proj="$(archive_app_field "$app" proj)";   scheme="$(archive_app_field "$app" scheme)"
  tests="$(archive_app_field "$app" tests)"; dd="$(archive_app_field "$app" dd)"
  fixture="$(archive_app_field "$app" fixture)"; mk="$(archive_app_field "$app" mkfixture)"
  prerun="$(archive_app_field "$app" prerun)"
  # CHECKED, not fire-and-forget (W21.vmgui-g14-leak). This used to be a bare
  # `[ -n "$prerun" ] && tart exec …` whose exit status nothing read, and the command it runs is a container
  # wipe — i.e. it decides whether the app starts from a FRESH container or an inherited one. Those are
  # different tests: on a fresh container `ArchiveNotesApp`'s two auto-opening `Window` scenes both open,
  # which is what the 2026-08-04 cascade turned out to be. A wipe that silently failed left "Extracts closed"
  # remembered from an earlier run and the suite passed for the wrong reason. Never fatal — the run is still
  # worth doing — but it must SAY so, because "which state did we start from" is now known to change the
  # result. (The suite no longer depends on it: `closeExtractsWindowIfOpen()` in setUp makes one window a
  # precondition either way. This warning exists so a silent change of premise can't happen again unseen.)
  # Kill any stale instance BEFORE the prerun wipes its container — the guest boots with whatever was
  # running when it was last stopped, app-under-test included (→ tart_kill_app, which carries the
  # measurement). Ordering: kill, wipe, build the fixture, test.
  tart_kill_app "$VM" "$app"
  echo "pre-kill[$app]: any stale instance terminated" >>"$log"
  if [ -n "$prerun" ]; then
    if tart exec "$VM" bash -lc "$prerun" >>"$log" 2>&1; then
      echo "prerun[$app]: ok" >>"$log"
    else
      echo "WARN[$app]: prerun FAILED (exit $?) — the app may start from an INHERITED container, which is a different test than a fresh one. See $log." | tee -a "$log"
    fi
  fi

  # Reuse the app's incremental build products but prune old result bundles and decline a near-full guest
  # before starting a build. Storage/agent trouble is infrastructure, so leaving no TEST marker makes the
  # main classifier report SKIPPED rather than inventing a product regression.
  ddrc=0
  tart_prepare_gui_dd "$VM" "$app" || ddrc=$?
  case "$ddrc" in
    0) printf '%s\n' "${TART_GUI_DD_NOTE:-storage: reused DerivedData}" >>"$log" ;;
    1) echo "SKIP[$app]: guest disk is too full for a safe Xcode build — ${TART_GUI_DD_NOTE:-no free-space report}" | tee -a "$log"; return 0 ;;
    *) echo "SKIP[$app]: could not prepare the guest DerivedData — ${TART_GUI_DD_NOTE:-guest transport failed}" | tee -a "$log"; return 0 ;;
  esac

  # Fixtured UITests XCTSkip themselves when their scratch fixture is missing — which would let the
  # gate go GREEN on the few unfixtured tests and hide the real coverage. Build it if absent
  # (idempotent, scratch-only, persists on the VM disk between runs) and shout if it still isn't there.
  if [ -n "$mk" ]; then
      # REBUILD EVERY ATTEMPT — not "only if absent". The UITests MUTATE the fixture and are written
      # against a fresh one: NotesGUITests.swift:81-88 says the fixture "is (re)built EXTERNALLY … before
      # each GUI run" and "the next pre-run rebuild returns the fixture to 4 items"; G8 trashes the Zotero
      # note ("the next pre-run fixture rebuild restores it") and G5 pastes a reader-page block into it.
      # With a build-if-absent guard those two can pass at most ONCE and then fail forever — which is
      # exactly what happened on 2026-07-30: two of the five "Notes UITest failures" were this bug, not
      # app defects, and they had already been written up as tracked product bugs. Both builders are
      # idempotent and rm -rf only their own scratch dir, so rebuilding is safe and cheap.
      # The verdict is the GUEST's own exit status, never `tart exec`'s: tart's control channel fails
      # independently of the command it carries, and this warn fired over builds that had just succeeded
      # (W26.fixwarn — the full account is on tart_build_fixture in ops/gui/tart-lib.sh).
      frc=0
      tart_build_fixture "$VM" "$mk" 200 || frc=$?
      printf '%s\n' "$TART_FIXTURE_TAIL" >>"$log"
      case "$frc" in
        0) echo "fixture[$app]: rebuilt ok (guest exit 0)" >>"$log" ;;
        1) echo "WARN[$app]: GUI fixture rebuild FAILED in the guest (exit $TART_FIXTURE_RC; see $log) — fixtured UITests will XCTSkip." | tee -a "$log" ;;
        *) echo "WARN[$app]: could not read the GUI fixture build's exit status back from the guest — tart's transport, NOT necessarily the build (see $log). The presence check below is the real verdict." | tee -a "$log" ;;
      esac
    tart exec "$VM" bash -lc "[ -d '$fixture' ]" >/dev/null 2>&1 \
      || echo "WARN[$app]: GUI fixture absent after the rebuild — fixtured UITests will XCTSkip, so a GREEN run would NOT mean what you think." | tee -a "$log"
  fi

  # xcodebuild REFUSES to overwrite an existing -resultBundlePath ("Existing file at …"), so a fixed path
  # makes every retry fail before it runs a single test — which reads as "inconclusive" and silently
  # downgrades a real RED to a skip. Per-attempt path, and remove it first in case a prior run was killed.
  bundle="$dd/uitest-attempt$attempt.xcresult"
  # CODE_SIGN_IDENTITY=- OVERRIDES project.yml's "Archive Suite Dev" FOR THE GUEST ONLY.
  # The repo moved to certificate signing on 2026-08-07 (W28.cert) so TCC grants survive a rebuild on
  # the HOST. That cert lives in the host's login keychain; the guest builds the app itself and has no
  # keychain material, so every target failed with "No certificate matching 'Archive Suite Dev' found"
  # — a build error the lane reported as a reproducible UITest failure, i.e. a RED that would park the
  # daemon. The VM is a disposable off-screen test environment: nothing there needs a durable TCC grant,
  # which is the ONLY reason the cert exists. So the guest stays ad-hoc — exactly the configuration this
  # lane was green on before — and the host keeps the cert. Do NOT "fix" this by provisioning the cert
  # into the VM: that couples a throwaway image to host secrets and breaks again on every VM rebuild.
  "${TO[@]}" tart exec "$VM" bash -lc "
    rm -rf '$bundle'
    xcodebuild test -project '$GUEST_REPO/$proj' -scheme '$scheme' \
      -only-testing:$tests -destination 'platform=macOS' \
      -derivedDataPath '$dd' -resultBundlePath '$bundle' \
      CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
  " >>"$log" 2>&1
  collect_shots "$app" "$attempt" "$log"
  # Preserve the finalized result bundle beside this attempt's log. A failed/interrupted Xcode run may
  # not finalize one; that is evidence about the infrastructure, never a reason to replace the log.
  result_art="$(app_art "$app")/uitest-attempt$attempt.xcresult"
  rm -rf "$result_art"
  if tart exec "$VM" bash -lc "[ -d '$bundle' ] && cp -R '$bundle' '/Volumes/My Shared Files/out/$app/'" >/dev/null 2>&1; then
    echo "artifact[$app]: $result_art" >>"$log"
  else
    echo "WARN[$app]: no finalized result bundle could be copied for attempt $attempt" >>"$log"
  fi
}

# UI-test runners are sandboxed, so they print their scratch screenshot paths and the unsandboxed guest
# agent copies them to the per-app artifact directory. This is deliberately separate from `.xcresult`:
# a launch failure can leave that bundle unfinalized, exactly when its screenshot is most useful.
collect_shots() { # $1 = app, $2 = attempt, $3 = host log
  local app="$1" attempt="$2" log="$3" dest paths p copied=0
  dest="$(app_art "$app")/shots-attempt$attempt"
  rm -rf "$dest"
  paths="$(sed -nE 's/^\[shot\] .*: wrote (.+)$/\1/p' "$log" 2>/dev/null | sort -u || true)"
  [ -n "$paths" ] || return 0
  mkdir -p "$dest"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if tart exec "$VM" bash -lc "cp \"$p\" '/Volumes/My Shared Files/out/$app/shots-attempt$attempt/'" >/dev/null 2>&1; then
      copied=$(( copied + 1 ))
    else
      echo "WARN[$app]: could not copy UI-test screenshot $p" >>"$log"
    fi
  done <<< "$paths"
  echo "artifact[$app]: $copied UI-test screenshot(s) in $dest" >>"$log"
}

# ---- main ---------------------------------------------------------------------------------------
: > "$GLOG"
# Generate every selected app's .xcodeproj on the HOST — the guest image has no xcodegen.
for app in $APPS; do
  archive_app_known "$app" || skip "unknown app '$app' in AUTONOMOUS_GUI_VM_APPS (known: reader notes processor)"
  spec="$(archive_app_field "$app" spec)"
  xcodegen generate --spec "$ROOT/$spec" >>"$GLOG" 2>&1 || skip "xcodegen failed for '$app' (see $GLOG)"
done

echo "GUI-VM gate: running [$APPS] UITests in VM '$VM' (headless, off-screen)…"
boot_vm; case $? in
  1) skip "VM never got an IP (see $GLOG)" ;;
  2) skip "Tart Guest Agent never answered within ${AGENTWAIT}s (see $GLOG)" ;;
  3) skip "the guest is not serving the accessibility tree, so XCUITest can see no windows and every
     UITest would fail for a reason unrelated to the code. Repair: ops/gui/vm-seed-accessibility.sh
     (see $GLOG)" ;;
esac

is_warn_only() { case " $WARN_APPS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

red=""; skipped=""; green=""; warned=""
for app in $APPS; do
  run_app_once "$app" 1 || true
  if is_processor_no_window "$app" 1; then
    echo "GUI-VM gate: Processor did not expose a window; screenshot kept in $(app_art "$app")/shots-attempt1. Treating guest launch state as SKIPPED, not a product RED."
    skipped="$skipped $app"; continue
  fi
  if is_success "$app" 1 && ! is_fail "$app" 1; then green="$green $app"; continue; fi
  if is_fail "$app" 1; then
    echo "GUI-VM gate: $app UITest failure — retrying once (flake guard)…"
    run_app_once "$app" 2 || true
    if is_success "$app" 2 && ! is_fail "$app" 2; then
      echo "GUI-VM gate: $app GREEN on retry — attempt 1 was a flake (evidence: $(applog "$app" 1))."
      green="$green $app"; continue
    fi
    # A retry that produced NEITHER marker cannot clear a failure that DID reproduce as a marker on
    # attempt 1 — that would let an infra hiccup on the retry launder a real RED into a skip.
    if is_fail "$app" 2 || ! is_success "$app" 2; then
      if is_warn_only "$app"; then warned="$warned $app"; else red="$red $app"; fi
      continue
    fi
  fi
  # Attempt 1 produced neither marker: boot / timeout / infra for this app — inconclusive, not a regression.
  skipped="$skipped $app"
done

# Did this attempt actually execute tests? (A boot/build failure produces a log with no test cases, and
# nothing can be concluded from comparing against it.)
ran_tests()    { grep -q "^Test Case " "$(applog "$1" "$2")" 2>/dev/null; }
# The failing test NAMES for one attempt, one per line, sorted — the unit the retry's answer is about.
failed_tests() {   # $1 = app, $2 = attempt
  [ -f "$(applog "$1" "$2")" ] || return 0
  grep -E "^Test Case .* failed \(" "$(applog "$1" "$2")" \
    | sed -E "s/^Test Case '-\[[^ ]+ ([^]]+)\]' failed.*/\1/" | sort -u
}

# The failing tests, PARTITIONED by what the retry actually proved about each one.
#
# ⚠️ This used to concatenate both attempts and `sort -u` them, and print the union directly beneath
# "RED — reproducible UITest failure in: <app>". The app-level flake guard above is right — it only clears
# an app when the whole retry is green — but at the TEST level the union throws the retry's answer away, so
# a test that failed on attempt 1 and PASSED on attempt 2 was reported as evidence for a reproducible
# failure, indistinguishable from one that failed twice. Found 2026-08-04 the expensive way: the notes lane
# reported G13 *and* G5 as the reproducible failure, and the per-attempt logs showed G5 failing once at
# 46.25 s and then PASSING on retry in 18.15 s. A reader (human or agent) who trusts the summary
# investigates a bug that is not there — the mirror image of this file's own "a gate that says ✓ for work
# it did not do is worse than no gate".
#
# The retry exists to answer exactly one question per test, so the report must state its answer. Evidence
# for both attempts is still preserved in full (the per-attempt logs, referenced below) — this only stops
# the SUMMARY from laundering a flake into a reproducible failure.
show_failures() {   # $1 = app
  echo "  --- $1 ---"
  local a1 a2 repro flaked
  a1="$(failed_tests "$1" 1)"
  if ran_tests "$1" 2; then
    a2="$(failed_tests "$1" 2)"
    repro="$(comm -12 <(printf '%s\n' "$a1" | grep -v '^$') <(printf '%s\n' "$a2" | grep -v '^$'))"
    flaked="$(comm -23 <(printf '%s\n' "$a1" | grep -v '^$') <(printf '%s\n' "$a2" | grep -v '^$'))"
    if [ -n "$repro" ]; then
      echo "  REPRODUCIBLE (failed on BOTH attempts) — this is what the RED is about:"
      printf '%s\n' "$repro" | sed 's/^/      /'
    else
      echo "  REPRODUCIBLE: none — no single test failed on both attempts."
    fi
    if [ -n "$flaked" ]; then
      echo "  FLAKED (failed attempt 1, PASSED on retry) — NOT evidence of a regression; do not chase these:"
      printf '%s\n' "$flaked" | sed 's/^/      /'
    fi
    # Attempt-2-only failures: a test that passed first and failed on the retry is also a flake, but the
    # other way round, and it is worth naming rather than hiding — it means the suite is order/timing
    # sensitive somewhere.
    local newly; newly="$(comm -13 <(printf '%s\n' "$a1" | grep -v '^$') <(printf '%s\n' "$a2" | grep -v '^$'))"
    [ -n "$newly" ] && { echo "  FLAKED THE OTHER WAY (passed attempt 1, failed on retry):";
                         printf '%s\n' "$newly" | sed 's/^/      /'; }
  else
    echo "  (attempt 2 ran no tests — cannot separate flake from reproducible; showing attempt 1 only)"
    printf '%s\n' "$a1" | grep -v '^$' | sed 's/^/      /'
  fi
  # The assertion messages, for whichever tests are above — the "why", kept unpartitioned on purpose.
  echo "  --- assertion detail (both attempts) ---"
  for n in 1 2; do
    [ -f "$(applog "$1" "$n")" ] || continue
    grep -E "error:" "$(applog "$1" "$n")" | sed -E 's#/Volumes/My Shared Files/repo/##' | sort -u | head -12
  done
  echo "  --- evidence: $(applog "$1" 1) · $(applog "$1" 2) ---"
}

echo "GUI-VM gate: passed[${green:- none} ] warned[${warned:- none} ] skipped[${skipped:- none} ] failed[${red:- none} ]"

# Preserve the evidence. Each attempt log is truncated at the start of the next run, so without this the
# only record of WHY a suite failed is gone by the following gate — and the owner is left with a summary
# line and nothing to act on.
for app in $red $warned; do
  keep="$ART/gui-vm-$app-LAST-FAILURE.log"
  { echo "=== $app — failing run captured $(date '+%F %T') ==="; show_failures "$app"; } > "$keep" 2>/dev/null || true
done

if [ -n "$red" ]; then
  echo "GUI-VM gate: RED — reproducible UITest failure in:$red"
  for app in $red; do show_failures "$app"; done
  exit 1
fi
if [ -n "$warned" ]; then
  # NOT green. Exit 4 so the caller prints a warning, not a checkmark (see the exit-code note in the header).
  echo "GUI-VM gate: WARN — reproducible UITest failures in warn-tier app(s):$warned (not parking; the tracked item that put them in AUTONOMOUS_GUI_VM_WARN_APPS owns the fix)"
  for app in $warned; do show_failures "$app"; done
  echo "GUI-VM gate: passed:${green:- none}  |  detail kept in $ART/gui-vm-<app>-LAST-FAILURE.log"
  exit 4
fi
[ -n "$skipped" ] && skip "inconclusive for:$skipped (boot, timeout, or infra — not a regression)"
echo "GUI-VM gate: GREEN —$green"
exit 0
