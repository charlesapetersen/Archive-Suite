#!/usr/bin/env bash
# gui-vm-gate.sh — the GUI-UITest step of the periodic health gate (health-gate.sh), run inside a
# headless Tart VM so it NEVER touches the owner's screen and never hangs the host with the "Enable UI
# Automation" prompt.
#
# Covers EVERY app that ships a UITest bundle — currently Reader + Notes (Processor has no test target
# at all). Select a subset with AUTONOMOUS_GUI_VM_APPS="reader" / "notes" / "reader notes".
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
#        AUTONOMOUS_GUI_VM_APPS (default "reader notes"), AUTONOMOUS_GUI_VM_AGENTWAIT (default 240s).
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VM="${AUTONOMOUS_GUI_VM_NAME:-archive-gui-runner}"
MAXRUN="${AUTONOMOUS_GUI_VM_MAXRUN:-1200}"
AGENTWAIT="${AUTONOMOUS_GUI_VM_AGENTWAIT:-240}"
APPS="${AUTONOMOUS_GUI_VM_APPS:-reader notes}"
# Apps whose UITest failures WARN instead of REDding the gate. The point of the warn tier is that a suite
# with known failures still RUNS and reports every gate — visibility without parking a multi-day run on a
# regression that is already tracked. An app graduates out of this list the moment its suite is green.
#   notes: 4/12 fail in the VM as of 2026-07-30 — G3 raw-markdown toggle + G8 delete-last-instance
#   ("… is not hittable"), G6/G11 "seam must be drivable" (an.editor.test.reveal / .zoteroOpen). Identical
#   across both attempts, so deterministic. It read as 5/12 and "flaky" until the fixture was rebuilt per
#   run: G5 was this gate's own staleness bug, not a Notes defect. Tracked as W21.vmgui-c.
WARN_APPS="${AUTONOMOUS_GUI_VM_WARN_APPS:-notes}"
ART="${ART_DIR:-$HOME/.tart-mirror/vm-artifacts}"
GLOG="$ART/gui-vm-gate.log"
# Per-app table, the guest-agent wait and the corpus resolution are SHARED with ops/gui/vm-gui-runner.sh
# via ops/gui/tart-lib.sh. That sharing is deliberate and load-bearing: on 2026-07-30 the guest-agent race
# was fixed HERE and not in the runner, leaving the interactive entry point broken in exactly the way this
# one had just been fixed. One copy, so a fix cannot land in only half the lane.
. "$ROOT/ops/gui/tart-lib.sh"
CORPUS_SRC="$(archive_corpus_src "$ROOT")"

skip() { echo "GUI-VM gate SKIPPED: $*"; exit 3; }

# ---- guards (each SKIPs; a missing prereq must never RED) --------------------------------------
[ "${AUTONOMOUS_GUI_VM:-1}" = 1 ] || skip "disabled (AUTONOMOUS_GUI_VM=0)"
command -v tart >/dev/null || skip "tart not installed"
tart list 2>/dev/null | awk '{print $2}' | grep -qx "$VM" || skip "VM '$VM' not present (build it — ops/gui/README.md §3)"
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
  [ -n "$CORPUS_SRC" ] && mounts+=(--dir=corpus:"$CORPUS_SRC")
  VM_BOOTED=1
  tart run "$VM" --no-graphics "${mounts[@]}" >>"$GLOG" 2>&1 &
  tart ip "$VM" --wait 120 >/dev/null 2>&1 || return 1
  tart_wait_agent "$VM" "$AGENTWAIT" || return 2
  echo "guest agent ready after ${TART_AGENT_WAITED}s" >>"$GLOG"
  return 0
}

# ---- per-app run --------------------------------------------------------------------------------
# One log PER APP PER ATTEMPT. Per-app so one app's "** TEST FAILED **" is never read as another's;
# per-attempt because the retry used to truncate the first attempt's log and destroy the only record of
# what actually failed — the retry is a flake guard, not a reason to lose evidence.
applog()     { echo "$ART/gui-vm-$1-attempt$2.log"; }
is_fail()    { grep -q '\*\* TEST FAILED \*\*'    "$(applog "$1" "$2")" 2>/dev/null; }
is_success() { grep -q '\*\* TEST SUCCEEDED \*\*' "$(applog "$1" "$2")" 2>/dev/null; }

run_app_once() {   # $1 = app, $2 = attempt number
  local app="$1" attempt="$2" log fixture mk prerun proj scheme tests dd bundle
  log="$(applog "$app" "$attempt")"; : > "$log"
  proj="$(archive_app_field "$app" proj)";   scheme="$(archive_app_field "$app" scheme)"
  tests="$(archive_app_field "$app" tests)"; dd="$(archive_app_field "$app" dd)"
  fixture="$(archive_app_field "$app" fixture)"; mk="$(archive_app_field "$app" mkfixture)"
  prerun="$(archive_app_field "$app" prerun)"
  [ -n "$prerun" ] && tart exec "$VM" bash -lc "$prerun" >>"$log" 2>&1

  # Fixtured UITests XCTSkip themselves when their scratch fixture is missing — which would let the
  # gate go GREEN on the few unfixtured tests and hide the real coverage. Build it if absent
  # (idempotent, scratch-only, persists on the VM disk between runs) and shout if it still isn't there.
  if [ -n "$mk" ]; then
    if [ -z "$CORPUS_SRC" ]; then
      echo "WARN[$app]: no source corpus found on the host — cannot build the GUI fixture; fixtured UITests will XCTSkip." | tee -a "$log"
    else
      # REBUILD EVERY ATTEMPT — not "only if absent". The UITests MUTATE the fixture and are written
      # against a fresh one: NotesGUITests.swift:81-88 says the fixture "is (re)built EXTERNALLY … before
      # each GUI run" and "the next pre-run rebuild returns the fixture to 4 items"; G8 trashes the Zotero
      # note ("the next pre-run fixture rebuild restores it") and G5 pastes a reader-page block into it.
      # With a build-if-absent guard those two can pass at most ONCE and then fail forever — which is
      # exactly what happened on 2026-07-30: two of the five "Notes UITest failures" were this bug, not
      # app defects, and they had already been written up as tracked product bugs. Both builders are
      # idempotent and rm -rf only their own scratch dir, so rebuilding is safe and cheap.
      tart exec "$VM" bash -lc "GR='$GUEST_REPO'; GC='$GUEST_CORPUS'; $mk" >>"$log" 2>&1 \
        || echo "WARN[$app]: GUI fixture rebuild FAILED (see $log) — fixtured UITests will XCTSkip." | tee -a "$log"
    fi
    tart exec "$VM" bash -lc "[ -d '$fixture' ]" >/dev/null 2>&1 \
      || echo "WARN[$app]: GUI fixture absent after the rebuild — fixtured UITests will XCTSkip, so a GREEN run would NOT mean what you think." | tee -a "$log"
  fi

  # xcodebuild REFUSES to overwrite an existing -resultBundlePath ("Existing file at …"), so a fixed path
  # makes every retry fail before it runs a single test — which reads as "inconclusive" and silently
  # downgrades a real RED to a skip. Per-attempt path, and remove it first in case a prior run was killed.
  bundle="$dd/uitest-attempt$attempt.xcresult"
  "${TO[@]}" tart exec "$VM" bash -lc "
    rm -rf '$bundle'
    xcodebuild test -project '$GUEST_REPO/$proj' -scheme '$scheme' \
      -only-testing:$tests -destination 'platform=macOS' \
      -derivedDataPath '$dd' -resultBundlePath '$bundle'
  " >>"$log" 2>&1
}

# ---- main ---------------------------------------------------------------------------------------
: > "$GLOG"
# Generate every selected app's .xcodeproj on the HOST — the guest image has no xcodegen.
for app in $APPS; do
  archive_app_known "$app" || skip "unknown app '$app' in AUTONOMOUS_GUI_VM_APPS (known: reader notes)"
  spec="$(archive_app_field "$app" spec)"
  xcodegen generate --spec "$ROOT/$spec" >>"$GLOG" 2>&1 || skip "xcodegen failed for '$app' (see $GLOG)"
done

echo "GUI-VM gate: running [$APPS] UITests in VM '$VM' (headless, off-screen)…"
boot_vm; case $? in
  1) skip "VM never got an IP (see $GLOG)" ;;
  2) skip "Tart Guest Agent never answered within ${AGENTWAIT}s (see $GLOG)" ;;
esac

is_warn_only() { case " $WARN_APPS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

red=""; skipped=""; green=""; warned=""
for app in $APPS; do
  run_app_once "$app" 1 || true
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

show_failures() {   # $1 = app — the failing test names from both attempts
  echo "  --- $1 ---"
  for n in 1 2; do
    [ -f "$(applog "$1" "$n")" ] || continue
    grep -E "Test Case .*failed|error:" "$(applog "$1" "$n")" | sed -E 's#/Volumes/My Shared Files/repo/##' | sort -u | head -12
  done
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
  echo "GUI-VM gate: WARN — reproducible UITest failures in warn-tier app(s):$warned (not parking; see W21.vmgui-c)"
  for app in $warned; do show_failures "$app"; done
  echo "GUI-VM gate: passed:${green:- none}  |  detail kept in $ART/gui-vm-<app>-LAST-FAILURE.log"
  exit 4
fi
[ -n "$skipped" ] && skip "inconclusive for:$skipped (boot, timeout, or infra — not a regression)"
echo "GUI-VM gate: GREEN —$green"
exit 0
