#!/usr/bin/env bash
# vm-gui-runner.sh — run Archive Reader GUI tests inside a headless Tart macOS VM,
# entirely OFF the host's physical screen. This is the unattended/daemon-safe GUI lane.
#
# WHY: macOS has no Xvfb — XCUITest and pixel capture need a real WindowServer, which on
# the host means taking over your screen. A Tart VM gives its own virtual display, so the
# daemon can run real GUI tests without touching your monitor. Background + full setup:
# ops/gui/README.md  and  ops/autonomous/README.md.
#
# TWO LANES (run either or both):
#   xcuitest — accessibility-driven UI tests via `xcodebuild test` inside the VM.
#   sighted  — real PIXELS: launch the app on the GUI fixture, grab the VM's framebuffer
#              over VNC from the host (vncdotool), optionally inject clicks/keys over VNC.
#              VNC is used (not in-VM screencapture/cliclick) on purpose — see README
#              "Why VNC": a headless VM has no capturable display until a viewer attaches,
#              and VNC-injected input bypasses the guest's Accessibility TCC entirely.
#
# PREREQS (one-time — see ops/gui/README.md): tart, crane, vncdotool; the VM
# `archive-gui-runner` cloned from macos-tahoe-xcode; xcodegen on the host.
#
# USAGE:  ops/gui/vm-gui-runner.sh [xcuitest|sighted|both]     (default: both)
# ENV overrides: VM_NAME, REPO_PATH, ART_DIR, VNCDOTOOL, ONLY_TESTING.
set -euo pipefail

VM="${VM_NAME:-archive-gui-runner}"
REPO="${REPO_PATH:-$(cd "$(dirname "$0")/../.." && pwd)}"        # suite root (this worktree)
ART="${ART_DIR:-$HOME/.tart-mirror/vm-artifacts}"
VNCDOTOOL="${VNCDOTOOL:-$HOME/.tart-mirror/vncenv/bin/vncdotool}"
PROJ_REL="ArchiveReader/macOS/ArchiveReader.xcodeproj"
SPEC_REL="ArchiveReader/macOS/project.yml"
SCHEME="ArchiveReader"
ONLY_TESTING="${ONLY_TESTING:-ArchiveReaderUITests}"
GUEST_REPO="/Volumes/My Shared Files/repo"
GUEST_DD="/Users/admin/dd-reader"
GUEST_APP="$GUEST_DD/Build/Products/Debug/ArchiveReader.app"
GUEST_FIXTURE="/Users/admin/Library/Application Support/ArchiveReader/AR-GUI-Fixture"
LANE="${1:-both}"

mkdir -p "$ART"
log() { printf '\033[36m[vm-gui]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[vm-gui] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- ensure the VM is running with a virtual display (--vnc-experimental) + shares ---
ensure_vm() {
  if ! tart list 2>/dev/null | grep -q "$VM"; then die "VM '$VM' not found — create it first (see ops/gui/README.md)."; fi
  if tart get "$VM" 2>/dev/null | grep -q running; then
    log "VM already running (VNC creds only known if this script started it; sighted lane may need a restart)."
    return
  fi
  local runlog="$ART/tart-run.log"; : > "$runlog"
  log "booting $VM headless with a virtual display (VNC) + repo/artifacts shares…"
  # No --no-graphics: we WANT a display so pixels exist. --vnc-experimental keeps it OFF
  # the host's physical screen (served to a VNC framebuffer we grab locally).
  tart run "$VM" --vnc-experimental \
    --dir=repo:"$REPO" --dir=out:"$ART" >>"$runlog" 2>&1 &
  echo $! > "$ART/tart-run.pid"
  # Parse the one-shot VNC endpoint tart prints: vnc://:PASSWORD@127.0.0.1:PORT
  for _ in $(seq 1 60); do
    if grep -q 'vnc://' "$runlog"; then break; fi; sleep 1
  done
  local url; url="$(grep -o 'vnc://[^ ]*' "$runlog" | head -1)"
  [ -n "$url" ] || die "VM did not report a VNC endpoint — check $runlog"
  VNC_PASS="$(printf '%s' "$url" | sed -E 's#vnc://:([^@]+)@.*#\1#')"
  VNC_HOSTPORT="$(printf '%s' "$url" | sed -E 's#vnc://:[^@]+@##')"
  VNC_HOST="${VNC_HOSTPORT%%:*}"; VNC_PORT="${VNC_HOSTPORT##*:}"
  tart ip "$VM" --wait 120 >/dev/null || die "VM never got an IP"
  log "VM up — VNC $VNC_HOST:$VNC_PORT"
}

# --- generate the Xcode project on the host (VM builds the shared mount) ---
gen_project() {
  command -v xcodegen >/dev/null || die "xcodegen not on host PATH"
  log "xcodegen generate…"
  xcodegen generate --spec "$REPO/$SPEC_REL" >/dev/null
}

# --- LANE: XCUITest (accessibility) ---
run_xcuitest() {
  log "building + running $ONLY_TESTING in the VM…"
  tart exec "$VM" bash -lc "
    xcodebuild test \
      -project '$GUEST_REPO/$PROJ_REL' -scheme '$SCHEME' \
      -only-testing:'$ONLY_TESTING' -destination 'platform=macOS' \
      -derivedDataPath '$GUEST_DD' -resultBundlePath '$GUEST_DD/uitest.xcresult'
  " | tee "$ART/xcuitest.log" | grep -E 'Test Suite|Executed [0-9]+ test|\*\* TEST' || true
  log "XCUITest log: $ART/xcuitest.log"
}

# --- LANE: sighted (real pixels over VNC) ---
run_sighted() {
  [ -x "$VNCDOTOOL" ] || die "vncdotool not found at $VNCDOTOOL (see README)"
  [ -n "${VNC_PORT:-}" ] || die "no VNC endpoint — this script must have started the VM for the sighted lane"
  log "ensuring the GUI fixture exists in the VM…"
  tart exec "$VM" bash -lc "
    [ -d '$GUEST_FIXTURE' ] || AR_FIXTURE_SRC='$GUEST_REPO/../fixture-src' \
      bash '$GUEST_REPO/ArchiveReader/scripts/make-gui-fixture.sh' >/dev/null 2>&1 || true
    pkill -x ArchiveReader 2>/dev/null || true
    open '$GUEST_APP' --args -ARUITestRootPath '$GUEST_FIXTURE'
    sleep 9
  "
  local vnc=( "$VNCDOTOOL" -s "$VNC_HOST::$VNC_PORT" -p "$VNC_PASS" )
  log "capturing the Reader off-screen over VNC…"
  "${vnc[@]}" capture "$ART/sighted-launch.png"
  log "artifact: $ART/sighted-launch.png  (Read it to eyeball the render)"
  # Example off-screen interaction (framebuffer coords): uncomment/adapt as needed.
  # "${vnc[@]}" move 765 269 click 1 pause 1 capture "$ART/sighted-after-click.png"
}

case "$LANE" in
  xcuitest) ensure_vm; gen_project; run_xcuitest ;;
  sighted)  ensure_vm; gen_project; tart exec "$VM" bash -lc "xcodebuild build-for-testing -project '$GUEST_REPO/$PROJ_REL' -scheme '$SCHEME' -destination 'platform=macOS' -derivedDataPath '$GUEST_DD' >/dev/null" ; run_sighted ;;
  both)     ensure_vm; gen_project; run_xcuitest; run_sighted ;;
  *) die "unknown lane '$LANE' (use: xcuitest | sighted | both)" ;;
esac
log "done. Artifacts in $ART"
