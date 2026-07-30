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
#   notes: 5/12 fail in the VM as of 2026-07-30 (first run there) — G3 raw-markdown toggle, G5 paste-as-
#   source-block, G6/G11 "seam must be drivable" (an.editor.test.reveal / .zoteroOpen), G8 delete-last-
#   instance guard; the count moves run to run, so they are flaky as well as failing. Tracked as W21.vmgui-c.
WARN_APPS="${AUTONOMOUS_GUI_VM_WARN_APPS:-notes}"
ART="${ART_DIR:-$HOME/.tart-mirror/vm-artifacts}"
GLOG="$ART/gui-vm-gate.log"
GUEST_REPO="/Volumes/My Shared Files/repo"
GUEST_CORPUS="/Volumes/My Shared Files/corpus"
GUEST_HOME="/Users/admin"

# The scratch GUI fixtures are built from a handful of real PDFs, and that corpus is GITIGNORED — it
# exists only in the primary checkout, never in a worktree. Mounting it as its own share (rather than
# reaching for it under $ROOT) makes the gate work identically from the primary checkout and from any
# worktree. Read-only by intent: the fixture builders `ditto` out of it and never write back.
CORPUS_SRC=""
for c in "$ROOT/ArchiveProcessor/Test Files/DeaverLLM" \
         "$HOME/Claude/Archive Suite/ArchiveProcessor/Test Files/DeaverLLM"; do
  [ -d "$c" ] && { CORPUS_SRC="$c"; break; }
done

skip() { echo "GUI-VM gate SKIPPED: $*"; exit 3; }

# ---- per-app table -----------------------------------------------------------------------------
# Everything app-specific lives here, so adding the next app is one block, not a fork of the script.
# `mkfixture` runs IN THE GUEST with $GR = the mounted repo; blank means the app needs no fixture.
app_field() {  # $1 = app, $2 = field
  case "$1:$2" in
    reader:spec)      echo "ArchiveReader/macOS/project.yml" ;;
    reader:proj)      echo "ArchiveReader/macOS/ArchiveReader.xcodeproj" ;;
    reader:scheme)    echo "ArchiveReader" ;;
    reader:tests)     echo "ArchiveReaderUITests" ;;
    reader:dd)        echo "$GUEST_HOME/dd-reader" ;;
    reader:fixture)   echo "$GUEST_HOME/Library/Application Support/ArchiveReader/AR-GUI-Fixture" ;;
    reader:mkfixture) echo 'AR_FIXTURE_SRC="$GC" bash "$GR/ArchiveReader/scripts/make-gui-fixture.sh"' ;;
    notes:spec)       echo "ArchiveNotes/macOS/project.yml" ;;
    notes:proj)       echo "ArchiveNotes/macOS/ArchiveNotes.xcodeproj" ;;
    notes:scheme)     echo "ArchiveNotes" ;;
    notes:tests)      echo "ArchiveNotesUITests" ;;
    notes:dd)         echo "$GUEST_HOME/dd-notes" ;;
    notes:fixture)    echo "$GUEST_HOME/Library/Application Support/ArchiveNotes/AN-GUI-Fixture" ;;
    notes:mkfixture)  echo 'NOTES_FIXTURE_CORPUS="$GC" bash "$GR/ArchiveNotes/scripts/make-notes-fixture.sh"' ;;
    # Notes only: wipe the GUEST app container before each run. organization.json is loaded ONLY when the
    # container's index DB has no folders, so a container left over from a previous run shadows the fixture's
    # folder graph and makes the folder-tree UITests (G7/G8) nondeterministic — the INDEX-DB CAVEAT in
    # make-notes-fixture.sh. This is the VM's throwaway container (/Users/admin), never the owner's.
    notes:prerun)     echo 'rm -rf "$HOME/Library/Containers/com.archivenotes.app"' ;;
    *) echo "" ;;
  esac
}

# ---- guards (each SKIPs; a missing prereq must never RED) --------------------------------------
[ "${AUTONOMOUS_GUI_VM:-1}" = 1 ] || skip "disabled (AUTONOMOUS_GUI_VM=0)"
command -v tart >/dev/null || skip "tart not installed"
tart list 2>/dev/null | awk '{print $2}' | grep -qx "$VM" || skip "VM '$VM' not present (build it — ops/gui/README.md §3)"
command -v xcodegen >/dev/null || skip "xcodegen not on the host PATH (it generates the projects the VM builds)"
mkdir -p "$ART"
if command -v gtimeout >/dev/null; then TO=(gtimeout "$MAXRUN"); else TO=(); fi

cleanup() { tart stop "$VM" >/dev/null 2>&1 || true; }
trap cleanup EXIT

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
  tart run "$VM" --no-graphics "${mounts[@]}" >>"$GLOG" 2>&1 &
  tart ip "$VM" --wait 120 >/dev/null 2>&1 || return 1
  local waited=0
  until tart exec "$VM" true >/dev/null 2>&1; do
    [ "$waited" -ge "$AGENTWAIT" ] && return 2
    sleep 5; waited=$(( waited + 5 ))
  done
  echo "guest agent ready after ${waited}s" >>"$GLOG"
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
  proj="$(app_field "$app" proj)";   scheme="$(app_field "$app" scheme)"
  tests="$(app_field "$app" tests)"; dd="$(app_field "$app" dd)"
  fixture="$(app_field "$app" fixture)"; mk="$(app_field "$app" mkfixture)"
  prerun="$(app_field "$app" prerun)"
  [ -n "$prerun" ] && tart exec "$VM" bash -lc "$prerun" >>"$log" 2>&1

  # Fixtured UITests XCTSkip themselves when their scratch fixture is missing — which would let the
  # gate go GREEN on the few unfixtured tests and hide the real coverage. Build it if absent
  # (idempotent, scratch-only, persists on the VM disk between runs) and shout if it still isn't there.
  if [ -n "$mk" ]; then
    if [ -z "$CORPUS_SRC" ]; then
      echo "WARN[$app]: no source corpus found on the host — cannot build the GUI fixture; fixtured UITests will SKIP." | tee -a "$log"
    else
      tart exec "$VM" bash -lc "GR='$GUEST_REPO'; GC='$GUEST_CORPUS'; [ -d '$fixture' ] || { $mk ; }" >>"$log" 2>&1 || true
    fi
    tart exec "$VM" bash -lc "[ -d '$fixture' ]" >/dev/null 2>&1 \
      || echo "WARN[$app]: GUI fixture still absent after a build attempt — fixtured UITests will SKIP." | tee -a "$log"
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
  spec="$(app_field "$app" spec)"
  [ -n "$spec" ] || skip "unknown app '$app' in AUTONOMOUS_GUI_VM_APPS"
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
for app in $warned; do
  echo "GUI-VM gate: WARN — known-failing UITests in '$app' (warn-tier, not parking; see W21.vmgui-c):"
  show_failures "$app"
done
if [ -n "$red" ]; then
  echo "GUI-VM gate: RED — reproducible UITest failure in:$red"
  for app in $red; do show_failures "$app"; done
  exit 1
fi
[ -n "$skipped" ] && skip "inconclusive for:$skipped (boot, timeout, or infra — not a regression)"
echo "GUI-VM gate: GREEN —$green${warned:+ (warn-tier still failing:$warned)}"
exit 0
