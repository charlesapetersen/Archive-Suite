#!/usr/bin/env bash
# vm-gui-runner.sh — run an Archive app's GUI tests inside a headless Tart macOS VM, entirely OFF the
# host's physical screen. This is the interactive GUI lane, and the one resume-prompt STEP 3.5,
# CLAUDE.md and AGENTS.md tell a session to use.
#
# WHY: macOS has no Xvfb — XCUITest and pixel capture need a real WindowServer, which on the host means
# taking over your screen. A Tart VM has its own virtual display, so real GUI tests run without touching
# your monitor. Background + full setup: ops/gui/README.md, ops/autonomous/README.md.
#
# TWO LANES (run either or both):
#   xcuitest — accessibility-driven UI tests via `xcodebuild test` inside the VM.
#   sighted  — real PIXELS: launch the app on its GUI fixture, grab the VM's framebuffer over VNC from
#              the host (vncdotool), optionally inject clicks/keys over VNC. VNC is used (not in-VM
#              screencapture/cliclick) on purpose — see README "Why VNC": a headless VM has no capturable
#              display until a viewer attaches, and VNC-injected input bypasses the guest's TCC entirely.
#
# USAGE:  ops/gui/vm-gui-runner.sh [reader|notes] [xcuitest|sighted|both]      (default: reader both)
#         The app argument is optional, so the old call form still works: a bare
#         `vm-gui-runner.sh xcuitest` still means "reader, xcuitest".
# ENV overrides: VM_NAME, REPO_PATH, ART_DIR, VNCDOTOOL, ONLY_TESTING, AGENT_WAIT.
#
# PREREQS (one-time — ops/gui/README.md §3): tart + the `archive-gui-runner` VM; xcodegen on the HOST;
# for the sighted lane only, vncdotool at ~/.tart-mirror/vncenv/bin/vncdotool. Each is CHECKED, loudly.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/tart-lib.sh"          # per-app table + tart_wait_agent + archive_corpus_src (read its header)

VM="${VM_NAME:-archive-gui-runner}"
REPO="${REPO_PATH:-$(cd "$HERE/../.." && pwd)}"                  # suite root (this worktree)
ART="${ART_DIR:-$HOME/.tart-mirror/vm-artifacts}"
VNCDOTOOL="${VNCDOTOOL:-$HOME/.tart-mirror/vncenv/bin/vncdotool}"
AGENT_WAIT="${AGENT_WAIT:-240}"

# --- args: [app] [lane], app optional (old call sites pass only a lane) ---
APP="reader"; LANE="both"
case "${1:-}" in
  xcuitest|sighted|both) LANE="$1" ;;
  "")                    : ;;
  *)                     APP="$1"; [ -n "${2:-}" ] && LANE="$2" ;;
esac

mkdir -p "$ART"
log() { printf '\033[36m[vm-gui]\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m[vm-gui] WARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[vm-gui] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

archive_app_known "$APP" || die "unknown app '$APP' (use: reader | notes). Processor has no UITest target yet — SUITE_TODO W21.vmgui-d."
case "$LANE" in xcuitest|sighted|both) : ;; *) die "unknown lane '$LANE' (use: xcuitest | sighted | both)" ;; esac

# One writer at a time: this script and the health gate share one VM name and one artifact dir, and each
# begins by stopping the VM and truncating logs. Without the lock a run started while the daemon's gate is
# mid-flight kills it, and the gate reports "inconclusive" for work it was about to complete.
VM_BOOTED=0
cleanup() {
  [ "$VM_BOOTED" = 1 ] && tart stop "$VM" >/dev/null 2>&1
  tart_lock_release
  return 0
}
trap cleanup EXIT
tart_lock_acquire "${LOCK_WAIT:-120}" \
  || die "the GUI VM is in use by another run (pid ${TART_LOCK_OWNER:-?}) — wait for it, or check: pgrep -fl gui-vm-gate"

SPEC_REL="$(archive_app_field "$APP" spec)";        PROJ_REL="$(archive_app_field "$APP" proj)"
SCHEME="$(archive_app_field "$APP" scheme)";        GUEST_DD="$(archive_app_field "$APP" dd)"
GUEST_APP="$(archive_app_field "$APP" appbundle)";  PROCNAME="$(archive_app_field "$APP" procname)"
GUEST_FIXTURE="$(archive_app_field "$APP" fixture)"; MKFIXTURE="$(archive_app_field "$APP" mkfixture)"
LAUNCHARG="$(archive_app_field "$APP" launcharg)";  PRERUN="$(archive_app_field "$APP" prerun)"
ONLY_TESTING="${ONLY_TESTING:-$(archive_app_field "$APP" tests)}"
CORPUS_SRC="$(archive_corpus_src "$REPO")"
VNC_HOST=""; VNC_PORT=""; VNC_PASS=""

# Belt-and-braces: close a Screen Sharing window if one appears anyway. With `--no-graphics
# --vnc-experimental` tart opens none (verified 2026-07-30), so this should be a no-op — it stays as a
# guard in case a future tart changes that behaviour back.
#
# ONLY if WE caused it. Screen Sharing is a single app process shared by every session, so an unconditional
# quit would tear down a screen-share the owner had open to another machine. So: snapshot whether it was
# already running BEFORE the boot (SS_WAS_RUNNING, set in ensure_vm) and leave it strictly alone if it was.
close_vm_viewer() {
  [ -n "${VNC_PORT:-}" ] || return 0
  if [ "${SS_WAS_RUNNING:-0}" = 1 ]; then
    warn "Screen Sharing was already running before this run — leaving it alone (it may be yours). tart may have added a window for the VM; close that one by hand."
    return 0
  fi
  pgrep -x "Screen Sharing" >/dev/null 2>&1 || return 0
  osascript -e 'tell application "Screen Sharing" to quit' >/dev/null 2>&1 || true
  log "closed the Screen Sharing viewer tart auto-opened (pixels are grabbed over VNC from the host instead)"
  return 0
}

# --- ensure the VM is running with a virtual display + shares ---
ensure_vm() {
  # Two DIFFERENT failures, never conflated (W21.vmgui-path): tart missing, vs tart present but no VM.
  tart_require || die "cannot reach the VM lane without tart — see above. The VM's existence is unknown, NOT ruled out."
  tart list 2>/dev/null | awk '{print $2}' | grep -qx "$VM" || die "tart is installed, but VM '$VM' does not exist — create it first (ops/gui/README.md §3)."
  # A VM this script did not start has no VNC endpoint we can read, and may hold the wrong mounts. That is
  # fatal for the sighted lane but harmless for xcuitest, so split rather than blanket-warning (the old
  # code warned and carried on, then failed obscurely inside vncdotool).
  if tart list 2>/dev/null | awk -v v="$VM" '$2==v && $NF=="running"{f=1} END{exit !f}'; then
    [ "$LANE" = "xcuitest" ] || die "VM '$VM' is already running and this script did not start it, so there is no VNC endpoint (and the mounts may be wrong). Stop it first:  tart stop $VM"
    log "VM already running — reusing it (xcuitest only needs the guest agent)."
    tart_wait_agent "$VM" "$AGENT_WAIT" || die "guest agent never answered within ${AGENT_WAIT}s on the already-running VM."
    ensure_display
    return 0
  fi
  local runlog="$ART/tart-run.log"; : > "$runlog"
  # Snapshot BEFORE the boot: if the owner already had Screen Sharing open, tart's auto-opened viewer is
  # not ours to close (see close_vm_viewer).
  SS_WAS_RUNNING=0; pgrep -x "Screen Sharing" >/dev/null 2>&1 && SS_WAS_RUNNING=1
  local mounts=(--dir=repo:"$REPO" --dir=out:"$ART")
  if [ -n "$CORPUS_SRC" ]; then
    mounts+=(--dir=corpus:"$CORPUS_SRC")
  else
    warn "no fixture corpus found on the host — the in-VM fixture build will be skipped and fixtured UITests will XCTSkip."
  fi

  # BOOT MODE IS PER LANE, and this is not cosmetic (owner reported a visible window, 2026-07-30).
  #   xcuitest — needs NO display at all: it only shells into the guest over the agent. `--no-graphics`
  #              ("Don't open a UI window") is genuinely silent, which is why the health gate, which has
  #              always used it, never put anything on screen.
  #   sighted  — needs a real framebuffer for the VNC pixel grab, so it must NOT be --no-graphics.
  #
  # `--vnc-experimental` ALONE is not headless. Per `tart run --help` it uses "Virtualization.Framework's
  # VNC server INSTEAD OF the built-in UI" — and tart then opens macOS **Screen Sharing.app** at that
  # endpoint, so a VM window appears on the owner's display. Harmless (it steals no input) but unasked-for,
  # and this script used to pass it for BOTH lanes, including the one that needs no pixels whatsoever.
  #
  # The two flags COMPOSE, which is the clean answer for the sighted lane — verified 2026-07-30:
  #   tart run … --no-graphics --vnc-experimental
  #   -> "VNC server is running at vnc://:***@127.0.0.1:54949", and NO viewer process.
  # So the framebuffer exists for vncdotool to grab while nothing is ever drawn on the owner's screen.
  # Better than opening a window and closing it, which flashes.
  local gfx=(--no-graphics)
  [ "$LANE" = "xcuitest" ] || gfx=(--no-graphics --vnc-experimental)
  log "booting $VM (${gfx[*]}) + repo/artifact shares…"
  VM_BOOTED=1
  tart run "$VM" "${gfx[@]}" "${mounts[@]}" >>"$runlog" 2>&1 &
  echo $! > "$ART/tart-run.pid"
  if [ "$LANE" != "xcuitest" ]; then
    # Parse the one-shot VNC endpoint tart prints: vnc://:PASSWORD@127.0.0.1:PORT
    local i; for i in $(seq 1 60); do grep -q 'vnc://' "$runlog" && break; sleep 1; done
    local url; url="$(grep -o 'vnc://[^ ]*' "$runlog" | head -1 || true)"
    [ -n "$url" ] || die "VM did not report a VNC endpoint — check $runlog"
    VNC_PASS="$(printf '%s' "$url" | sed -E 's#vnc://:([^@]+)@.*#\1#')"
    local hostport; hostport="$(printf '%s' "$url" | sed -E 's#vnc://:[^@]+@##')"
    VNC_HOST="${hostport%%:*}"; VNC_PORT="${hostport##*:}"
    # tart opens Screen Sharing.app at that endpoint. We grab the framebuffer with vncdotool from the
    # host, so the viewer is pure noise on the owner's display — close it. Only ever the VM's own window:
    # matched by the vnc://127.0.0.1:<our port> URL, never a screen-share the owner opened themselves.
    close_vm_viewer
  fi
  tart ip "$VM" --wait 120 >/dev/null || die "VM never got an IP — check $runlog"
  # `tart ip` returns on NETWORKING; `tart exec` needs the guest agent's vsock socket, which comes up
  # LATER. Omitting this wait is the bug that made the health gate silently run zero tests for two days —
  # see tart-lib.sh. Never exec after a boot without it.
  tart_wait_agent "$VM" "$AGENT_WAIT" || die "Tart Guest Agent never answered within ${AGENT_WAIT}s — check $runlog"
  log "VM up — guest agent ready after ${TART_AGENT_WAITED}s${VNC_PORT:+, VNC $VNC_HOST:$VNC_PORT}"
  ensure_display
}

# --- the guest's SCREEN SIZE (W21.vmgui-c) -----------------------------------------------------------
# `--no-graphics` boots the guest at 1024×768, which is BELOW the Notes browser's ~1084 pt minimum, so its
# right pane is clipped off-window and four UITests fail as "not hittable". Raise it, and say what
# actually happened — never silently. Not fatal: Reader is green at 1024×768, so a failure here degrades
# one lane rather than breaking the run. See tart_ensure_display in tart-lib.sh for the full measurement.
ensure_display() {
  if tart_ensure_display "$VM"; then
    log "${TART_DISPLAY_NOTE:-guest display OK}"
  else
    warn "could not raise the guest display to ${TART_VM_DISPLAY:-1920x1200} — it may still be at the
    1024×768 headless default, which clips the Notes browser's right pane off-window and fails 4
    ArchiveNotesUITests as 'not hittable' / 'seam must be drivable'. Guest said: ${TART_DISPLAY_NOTE:-(no output)}"
  fi
}

# --- generate the Xcode project on the host (the guest image has no xcodegen) ---
gen_project() {
  command -v xcodegen >/dev/null || die "xcodegen not on the host PATH (brew install xcodegen) — the VM builds the project it generates."
  log "xcodegen generate ($APP)…"
  xcodegen generate --spec "$REPO/$SPEC_REL" >/dev/null
}

# --- the scratch GUI fixture, built INSIDE the guest (idempotent; persists on the VM disk) ---
ensure_fixture() {
  [ -n "$MKFIXTURE" ] || return 0
  [ -n "$CORPUS_SRC" ] || { warn "no corpus mounted — cannot build the GUI fixture; fixtured UITests will XCTSkip."; return 0; }
  # REBUILD every run, not "only if absent". The UITests mutate the fixture and are written against a
  # fresh one (NotesGUITests.swift:81-88: rebuilt "before each GUI run"; G8 trashes the Zotero note, G5
  # pastes a block into it). Build-if-absent lets those pass at most once, then fail forever and look
  # like app bugs. Both builders are idempotent and rm -rf only their own scratch dir.
  log "rebuilding the GUI fixture inside the VM…"
  # Deliberately NOT silenced. The previous version piped this to /dev/null with `|| true`, so when its
  # source path turned out to be unmounted the failure was invisible and the whole suite quietly XCTSkipped
  # while still reporting success.
  tart exec "$VM" bash -lc "GR='$GUEST_REPO'; GC='$GUEST_CORPUS'; $MKFIXTURE" 2>&1 | tail -5 \
    || warn "fixture build reported a failure (output above)."
  tart exec "$VM" bash -lc "[ -d '$GUEST_FIXTURE' ]" >/dev/null 2>&1 \
    || warn "fixture STILL absent after the build attempt — fixtured UITests will XCTSkip, so a green run would not mean what you think."
}

# --- LANE: XCUITest (accessibility) ---
run_xcuitest() {
  [ -n "$PRERUN" ] && tart exec "$VM" bash -lc "$PRERUN" >/dev/null 2>&1
  log "building + running $ONLY_TESTING for $APP in the VM…"
  # xcodebuild REFUSES to overwrite an existing -resultBundlePath, so a fixed path makes every re-run fail
  # before executing a single test. Remove it first.
  # CODE_SIGN_IDENTITY=- : the guest has no keychain, so it cannot use the host's "Archive Suite Dev"
  # cert (W28.cert). Same rationale as ops/autonomous/gui-vm-gate.sh — see the long note there.
  tart exec "$VM" bash -lc "
    rm -rf '$GUEST_DD/uitest.xcresult'
    xcodebuild test \
      -project '$GUEST_REPO/$PROJ_REL' -scheme '$SCHEME' \
      -only-testing:'$ONLY_TESTING' -destination 'platform=macOS' \
      -derivedDataPath '$GUEST_DD' -resultBundlePath '$GUEST_DD/uitest.xcresult' \
      CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
  " 2>&1 | tee "$ART/xcuitest-$APP.log" | grep -E 'Test Suite|Executed [0-9]+ test|\*\* TEST' || true
  log "XCUITest log: $ART/xcuitest-$APP.log"
  grep -q '\*\* TEST SUCCEEDED \*\*' "$ART/xcuitest-$APP.log" 2>/dev/null \
    || warn "no '** TEST SUCCEEDED **' marker for $APP — read the log before believing this run passed."
}

build_for_sighted() {
  log "building $SCHEME in the VM (for the sighted lane)…"
  # CODE_SIGN_IDENTITY=- : guest has no keychain for the host's cert (W28.cert; see gui-vm-gate.sh).
  tart exec "$VM" bash -lc "xcodebuild build-for-testing -project '$GUEST_REPO/$PROJ_REL' -scheme '$SCHEME' -destination 'platform=macOS' -derivedDataPath '$GUEST_DD' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO" >/dev/null
}

# --- LANE: sighted (real pixels over VNC) ---
run_sighted() {
  [ -x "$VNCDOTOOL" ] || die "vncdotool not found at $VNCDOTOOL — recreate it:
    python3 -m venv ~/.tart-mirror/vncenv && ~/.tart-mirror/vncenv/bin/pip install vncdotool"
  [ -n "$VNC_PORT" ] || die "no VNC endpoint — this script must have started the VM for the sighted lane"
  [ -n "$PRERUN" ] && tart exec "$VM" bash -lc "$PRERUN" >/dev/null 2>&1
  log "launching $APP in the VM against its scratch fixture…"
  tart exec "$VM" bash -lc "
    pkill -x '$PROCNAME' 2>/dev/null || true
    open '$GUEST_APP' --args $LAUNCHARG '$GUEST_FIXTURE'
    sleep 9
  "
  local vnc=( "$VNCDOTOOL" -s "$VNC_HOST::$VNC_PORT" -p "$VNC_PASS" )
  log "capturing $APP off-screen over VNC…"
  "${vnc[@]}" capture "$ART/sighted-$APP.png"
  log "artifact: $ART/sighted-$APP.png  (Read it to eyeball the render)"
  # Example off-screen interaction (framebuffer coords): adapt as needed.
  # "${vnc[@]}" move 765 269 click 1 pause 1 capture "$ART/sighted-$APP-after-click.png"
}

log "app=$APP  lane=$LANE  vm=$VM"
ensure_vm
gen_project
ensure_fixture
case "$LANE" in
  xcuitest) run_xcuitest ;;
  sighted)  build_for_sighted; run_sighted ;;
  both)     run_xcuitest; build_for_sighted; run_sighted ;;
esac
log "done. Artifacts in $ART"
