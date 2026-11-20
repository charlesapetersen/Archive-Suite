#!/usr/bin/env bash
# vm-finder-open-check.sh — a library double-clicked in Finder opens in the SHIPPING sandbox
# (W49.notes-finder-open-check). Runs in the headless GUI VM, never on the host's screen.
#
# WHAT IT CHECKS. Finder hands an `.archivenotes` library to Notes through the open-documents Apple event
# (`NotesAppDelegate`), and the event carries the sandbox extension that lets Notes read the library and
# bookmark it. The UITest build cannot show that: its entitlements hold a read-write exception for all of
# /Users/, and XCUITest cannot query an instance LaunchServices started. So this builds Notes in Release (the
# production entitlements, checked on the built app, ad-hoc signed as every guest build is) and, on a freshly
# wiped container (a first launch):
#   1. makes an empty scratch library in the guest's ~/Documents and opens it the way Finder does (`open -a`);
#   2. presses "Restart and Switch" in the question the library raises, through the Accessibility API by pid
#      (vm-finder-open-ax.swift), failing if the first-launch Save panel shows beside it;
#   3. waits for the relaunched instance to resolve the bookmark and write the library's Notes marker, which
#      it can do only through the security-scoped bookmark made from the event's grant;
#   4. fails if the relaunched instance shows a dialog (a library it could not open asks for one again).
# Then the same for a first launch with no library: the Save panel's Make Library at its proposed place
# (~/Documents/Archive Notes.archivenotes), the question, the quit and the relaunch.
# Everything happens on the VM's own disk: the scratch libraries and the guest's Notes container are deleted at
# the end. Nothing on the host is read or written beyond the artifact folder.
#
# USAGE:  ArchiveNotes/scripts/vm-finder-open-check.sh       (exit 0 = passed)
# ENV:    VM_NAME, REPO_PATH (default: this checkout), ART_DIR, LOCK_WAIT (s to wait for the VM, 3600)
set -euo pipefail
. "$(dirname "$0")/../../ops/autonomous/heavy-enter.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../ops/gui/tart-lib.sh"

VM="${VM_NAME:-archive-gui-runner}"
REPO="${REPO_PATH:-$(cd "$HERE/../.." && pwd)}"
ART="${ART_DIR:-$HOME/.tart-mirror/vm-artifacts}/notes-finder-open"
BUNDLE_ID="com.archivenotes.app"
GUEST_DD="$GUEST_HOME/dd-notes-release"
GUEST_APP="$GUEST_DD/Build/Products/Release/ArchiveNotes.app"
GUEST_SCRATCH="$GUEST_HOME/Documents/W49-finder-open-check"
GUEST_LIB="$GUEST_SCRATCH/Finder Check.archivenotes"
GUEST_FIRST_LIB="$GUEST_HOME/Documents/Archive Notes.archivenotes"   # the first-launch Save panel's proposal
AX="swift '$GUEST_REPO/ArchiveNotes/scripts/vm-finder-open-ax.swift'"

log() { printf '[finder-open] %s\n' "$*"; }
die() { printf '[finder-open] FAIL: %s\n' "$*" >&2; exit 1; }
gx() { tart exec "$VM" bash -lc "$1"; }

mkdir -p "$ART"; rm -f "$ART"/*.log "$ART"/*.txt "$ART"/*.json "$ART"/*.png
tart_require || die "tart is not installed"
command -v xcodegen >/dev/null || export PATH="/opt/homebrew/bin:$PATH"
command -v xcodegen >/dev/null || die "xcodegen is not on the host PATH"

tart_lock_acquire "${LOCK_WAIT:-3600}" || die "the GUI VM is in use by another run (pid ${TART_LOCK_OWNER:-?})"
BOOTED=0
START=""
cleanup() {
  local rc=$?
  if [ "$BOOTED" = 1 ] && [ -n "$START" ]; then
    # What the guest saw, for a failed run's diagnosis: Notes' windows, its log and sandbox reports, a shot of
    # the guest's own screen (never the host's).
    gx "$AX dialogs $BUNDLE_ID" > "$ART/windows.txt" 2>&1 || true
    gx "log show --style compact --start '$START' --predicate 'process == \"ArchiveNotes\" OR (sender == \"Sandbox\" AND eventMessage CONTAINS \"ArchiveNotes\")'" \
      > "$ART/guest.log" 2>&1 || true
    [ "$rc" = 0 ] || gx "screencapture -x '$TART_GUEST_OUT/screen.png'" >/dev/null 2>&1 || true
  fi
  if [ "$BOOTED" = 1 ]; then
    gx "pkill -x ArchiveNotes; sleep 1; rm -rf '$GUEST_SCRATCH' '$GUEST_FIRST_LIB' '$GUEST_HOME/Library/Containers/$BUNDLE_ID'; true" \
      >/dev/null 2>&1 || true
    tart_stop_clean "$VM"
  fi
  tart_lock_release
}
trap cleanup EXIT

log "xcodegen generate (notes)…"
xcodegen generate --spec "$REPO/$(archive_app_field notes spec)" >/dev/null

# A guest left running (a kept guest, or one booted with another checkout) is idle while we hold the lock.
if tart list 2>/dev/null | awk -v v="$VM" '$2==v && $NF=="running"{f=1} END{exit !f}'; then
  log "stopping the idle guest so it boots with this checkout"
  tart_stop_clean "$VM"; rm -f "$TART_KEEP_STATE"
fi
log "booting $VM (--no-graphics)…"
tart run "$VM" --no-graphics --no-clipboard --dir=repo:"$REPO" --dir=out:"$ART" >"$ART/tart-run.log" 2>&1 &
BOOTED=1
tart ip "$VM" --wait 120 >/dev/null || die "the VM never got an IP (log: $ART/tart-run.log)"
tart_wait_agent "$VM" 240 || die "the guest agent never answered"
tart_ensure_display "$VM" || log "display: ${TART_DISPLAY_NOTE:-unknown} (not needed for this check)"

log "building Notes (Release) in the VM…"
gx "pkill -x ArchiveNotes; sleep 1; rm -rf '$GUEST_HOME/Library/Containers/$BUNDLE_ID'; mkdir -p '$GUEST_DD'
    xcodebuild build -project '$GUEST_REPO/$(archive_app_field notes proj)' -scheme ArchiveNotes -configuration Release \
      -destination 'platform=macOS' -derivedDataPath '$GUEST_DD' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO" \
  > "$ART/build.log" 2>&1 || true
grep -q '\*\* BUILD SUCCEEDED \*\*' "$ART/build.log" || die "the Release build failed (log: $ART/build.log)"

# The point of the check: the built app carries the production entitlements and none of the UITest ones.
gx "codesign -d --entitlements - --xml '$GUEST_APP' 2>/dev/null" > "$ART/entitlements.plist" || true
grep -q 'com.apple.security.app-sandbox' "$ART/entitlements.plist" || die "the built app is not sandboxed"
grep -q 'com.apple.security.files.user-selected.read-write' "$ART/entitlements.plist" \
  || die "the built app lacks the production file entitlement"
if grep -Eq 'temporary-exception|get-task-allow|disable-library-validation' "$ART/entitlements.plist"; then
  die "the built app carries a debug or UITest entitlement (see $ART/entitlements.plist)"
fi
log "entitlements: production (sandbox, user-selected read-write, app-scope bookmarks), no exception"

gx "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f '$GUEST_APP'" \
  || die "could not register the built app with Launch Services"
# start_notes [DOCUMENT] — a first launch (container wiped, no library remembered), the way Finder starts it.
start_notes() {
  gx "pkill -x ArchiveNotes; sleep 1; rm -rf '$GUEST_HOME/Library/Containers/$BUNDLE_ID'; true" >/dev/null 2>&1 || true
  gx "open -a '$GUEST_APP' ${1:+'$1'}" || die "LaunchServices refused to start Notes${1:+ with $1}"
  FIRST_PID=""
  for _ in $(seq 1 30); do
    FIRST_PID="$(gx "pgrep -x ArchiveNotes | head -1" 2>/dev/null || true)"
    [ -n "$FIRST_PID" ] && break; sleep 1
  done
  [ -n "$FIRST_PID" ] || die "Notes did not start"
}

# confirm_switch LOG [--no-save-panel] — answer the switch question with Restart and Switch. "Is it inside an
# archive?" comes first only when a parent of ~/Documents cannot be looked at.
confirm_switch() {
  local out="$1" rc=0; shift
  gx "$AX press $* $BUNDLE_ID 60 'Restart and Switch' 'Not in an Archive'" | tee -a "$out" || rc=$?
  [ "$rc" = 0 ] || die "the question was not answered (exit $rc; $out)"
  if tail -1 "$out" | grep -q 'pressed “Not in an Archive”'; then
    gx "$AX press $BUNDLE_ID 30 'Restart and Switch'" | tee -a "$out" || die "no switch question after the archive question"
  fi
}

# expect_relaunch_in LIBRARY NAME — the quit went through (the first instance is gone), the relaunched instance
# wrote LIBRARY's Notes marker through the bookmark, and it shows no dialog.
expect_relaunch_in() {
  local library="$1" name="$2" ok=0 rc=0
  log "$name: waiting for the relaunched Notes to open the library…"
  for _ in $(seq 1 60); do
    if gx "[ -f '$library/.archive-suite-root.json' ] && ! kill -0 $FIRST_PID 2>/dev/null && pgrep -x ArchiveNotes >/dev/null" >/dev/null 2>&1; then
      ok=1; break
    fi
    sleep 1
  done
  gx "cat '$library/.archive-suite-root.json'" > "$ART/$name-marker.json" 2>/dev/null || true
  gx "pgrep -lx ArchiveNotes" > "$ART/$name-instances.txt" 2>/dev/null || true
  if [ "$ok" != 1 ]; then
    gx "kill -0 $FIRST_PID" >/dev/null 2>&1 && die "$name: the first Notes (pid $FIRST_PID) never quit after Restart and Switch (logs in $ART)"
    die "$name: the relaunched Notes did not write the library's marker within 60 s (instances: $(tr '\n' ' ' < "$ART/$name-instances.txt"); logs in $ART)"
  fi
  grep -q '"kind" *: *"notes"' "$ART/$name-marker.json" || die "$name: the marker is not a Notes marker: $(cat "$ART/$name-marker.json")"
  log "$name: the relaunched Notes (pid $(head -1 "$ART/$name-instances.txt" | awk '{print $1}')) wrote the library's marker through the bookmark"
  sleep 5
  gx "$AX dialogs $BUNDLE_ID" | tee "$ART/$name-after.log" || rc=$?
  [ "$rc" = 0 ] || die "$name: the relaunched Notes is showing a dialog (exit $rc; $ART/$name-after.log)"
}

gx "rm -rf '$GUEST_SCRATCH' '$GUEST_FIRST_LIB'; mkdir -p '$GUEST_LIB'" || die "could not make the scratch library"
START="$(gx 'date "+%Y-%m-%d %H:%M:%S"')"

# 1. A library double-clicked in Finder, at a first launch: asked about, no Save panel beside it.
log "finder: opening the library as Finder does…"
start_notes "$GUEST_LIB"
confirm_switch "$ART/finder-press.log" --no-save-panel
expect_relaunch_in "$GUEST_LIB" finder
log "finder: PASSED"

# 2. A first launch with no library: the Save panel's Make Library at its proposed place (~/Documents), then the
#    same question, quit and relaunch. The Save panel is the sandbox's own grant, so this covers the path a new
#    user takes first.
log "first-launch: starting Notes with no library…"
start_notes
rc=0
gx "$AX press $BUNDLE_ID 60 'Make Library'" | tee "$ART/first-launch-press.log" || rc=$?
[ "$rc" = 0 ] || die "first-launch: no Save panel to make a library with (exit $rc; $ART/first-launch-press.log)"
confirm_switch "$ART/first-launch-press.log"
expect_relaunch_in "$GUEST_FIRST_LIB" first-launch
log "first-launch: PASSED"

log "PASSED: a library opened from Finder, and one made at the first launch, open under the production sandbox"
