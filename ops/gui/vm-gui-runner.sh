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
# USAGE:  ops/gui/vm-gui-runner.sh [reader|notes|processor] [xcuitest|sighted|both] (default: reader both)
#         The app argument is optional, so the old call form still works: a bare
#         `vm-gui-runner.sh xcuitest` still means "reader, xcuitest".
# ENV overrides: VM_NAME, REPO_PATH, ART_DIR, VNCDOTOOL, ONLY_TESTING, TEST_ITERATIONS, AGENT_WAIT,
#                CORRUPT_INDEX_FIXTURE=1 (Reader/Notes focused W23.m9-fu3 test),
#                READER_JOURNEY=rehearsal (W40.d8 triage journey on the real-corpus sample).
#                NOTES_JOURNEY=integrations (W40.d10: Notes with the real Zotero and Reader in the VM).
#                PROCESSOR_JOURNEY=livecapture (W40.d5: hand-driven live capture against the real Android
#                companion on a headless AVD on the host; xcuitest lane only).
#                VISUAL_REVIEW=1 (W40.e10/e11 screenshot tour; pair with ONLY_TESTING=<App>UITests/VisualReviewUITests).
#                TRANSIENT_VIDEO=1 (W40.e13: record the guest screen across the run; scan with transient-frames.py).
#                VM_KEEP=1 (W40.vm-macos27-runtime (4)): leave the guest booted for the next call, for a run of
#                  targeted tests (its warm DerivedData makes an unchanged build a few seconds). A
#                  detached vm-keep-reaper.sh stops it after VM_KEEP_IDLE s (300) without a run, as soon as
#                  the Mac's memory pressure leaves normal, or when the calling session exits. A call without
#                  VM_KEEP=1 takes a kept guest over and stops it at the end; `vm-gui-runner.sh stop` stops it now.
#                VM_SPLIT=N (xcuitest only): run the selection as N chunks of whole test classes, each in a freshly
#                  booted guest (the macOS 27.2 guest slows down over a long lane; see README §"Long lanes").
#                VM_SAMPLE=S: sample host and guest load every S s into $ART/<app>/sampler*.tsv (default 60; 0 = off).
#
# The guest's `xcodebuild test` is ended if it outlives its own summary or goes silent (tart_run_test).
#
# PREREQS (one-time — ops/gui/README.md §3): tart + the `archive-gui-runner` VM; xcodegen on the HOST;
# for the sighted lane only, vncdotool at ~/.tart-mirror/vncenv/bin/vncdotool. Each is CHECKED, loudly.
set -euo pipefail
. "$(dirname "$0")/../autonomous/heavy-enter.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/tart-lib.sh"          # per-app table + tart_wait_agent (read its header)

VM="${VM_NAME:-archive-gui-runner}"
REPO="${REPO_PATH:-$(cd "$HERE/../.." && pwd)}"                  # suite root (this worktree)
ART="${ART_DIR:-$HOME/.tart-mirror/vm-artifacts}"
REHEARSAL="${REHEARSAL_DIR:-$HOME/Library/Caches/ArchiveSuiteRehearsal}"   # W40.c1 sets, shared read-only
VNCDOTOOL="${VNCDOTOOL:-$HOME/.tart-mirror/vncenv/bin/vncdotool}"
AGENT_WAIT="${AGENT_WAIT:-240}"

VM_KEEP="${VM_KEEP:-0}"
VM_SPLIT="${VM_SPLIT:-0}"
VM_SAMPLE="${VM_SAMPLE:-60}"
KEEP_STATE="${VM_KEEP_STATE:-$HOME/.tart-mirror/.vm-keep}"
[[ "$VM_SPLIT" =~ ^[0-9]+$ ]] || { echo "VM_SPLIT must be a whole number" >&2; exit 2; }
[[ "$VM_SAMPLE" =~ ^[0-9]+$ ]] || { echo "VM_SAMPLE must be a whole number of seconds" >&2; exit 2; }

# --- args: [app] [lane], app optional (old call sites pass only a lane) ---
APP="reader"; LANE="both"
case "${1:-}" in
  stop)
    # Stop a guest VM_KEEP=1 left running, now, under the VM lock (so never under a run).
    tart_lock_acquire "${LOCK_WAIT:-120}" || { echo "the GUI VM is in use by another run (pid ${TART_LOCK_OWNER:-?})" >&2; exit 1; }
    if [ -f "$KEEP_STATE" ]; then
      tart_stop_clean "$(sed -n 's/^vm=//p' "$KEEP_STATE" | tail -n 1)"; rm -f "$KEEP_STATE"; echo "kept guest stopped"
    else
      echo "no kept guest"
    fi
    tart_lock_release; exit 0 ;;
  xcuitest|sighted|both) LANE="$1" ;;
  "")                    : ;;
  *)                     APP="$1"; [ -n "${2:-}" ] && LANE="$2" ;;
esac

log() { printf '\033[36m[vm-gui]\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m[vm-gui] WARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[vm-gui] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

archive_app_known "$APP" || die "unknown app '$APP' (use: reader | notes | processor)."
case "$LANE" in xcuitest|sighted|both) : ;; *) die "unknown lane '$LANE' (use: xcuitest | sighted | both)" ;; esac
APP_ART="$ART/$APP"
mkdir -p "$APP_ART"

# One writer at a time: this script and the health gate share one VM name and one artifact dir, and each
# begins by stopping the VM and truncating logs. Without the lock a run started while the daemon's gate is
# mid-flight kills it, and the gate reports "inconclusive" for work it was about to complete.
VM_BOOTED=0
cleanup() {
  # An EXIT trap must reach the lock release: under the script's `set -e` one failing line in here would end
  # the trap early and leave the VM lock and the guest behind (it did, on a missing state file).
  set +e
  tart_sampler_stop
  if [ "$VM_BOOTED" = 1 ] && [ "$VM_KEEP" = 1 ] && [ "$LANE" = xcuitest ]; then
    keep_guest; VM_BOOTED=0
  fi
  [ "$VM_BOOTED" = 1 ] && tart_stop_clean "$VM" && rm -f "$KEEP_STATE"
  tart_lock_release
  return 0
}

# --- VM_KEEP=1: leave the guest up for the next call, with a reaper that stops it (vm-keep-reaper.sh) ---
# The kept guest and its reaper run in a POSIX session of their own (detached): heavy-run.py holds the Mac's
# heavy lock until every process in the runner's session has ended, so a guest left in it would keep the
# runner's call from returning and hold the lock while nobody tests. Between calls the guest is outside the
# heavy lock by design (owner, 2026-11-12); the reaper's memory-pressure stop is what bounds it there.
# Call it as `detached CMD… &`: the `&` forks a subshell, and `exec` makes that subshell the command itself, so $!
# is the command's pid (the reaper checks its own pid against the state) and nothing is left waiting in our session.
detached() { exec python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"; }
# The session that keeps it: the nearest `claude` ancestor, so the guest goes when that session does.
keep_owner() {
  local p="$$" c
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    c="$(ps -o comm= -p "$p" 2>/dev/null || true)"
    case "${c##*/}" in claude) echo "$p"; return 0 ;; esac
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || true)"
  done
  return 0
}
keep_field() { sed -n "s/^$1=//p" "$KEEP_STATE" 2>/dev/null | tail -n 1 || true; }
# write_keep_state — (re)write the state and make sure a live reaper watches it. Called right after a kept
# boot (so a runner killed mid-run still leaves a guest the reaper stops after VM_KEEP_IDLE) and at the end.
write_keep_state() {
  local reaper
  reaper="$(keep_field reaper)"
  { echo "vm=$VM"; echo "repo=$REPO"; echo "art=$ART"; echo "rehearsal=$([ -d "$REHEARSAL" ] && echo 1 || echo 0)"
    echo "owner=$(keep_owner)"; echo "last=$(date +%s)"
    [ -n "$reaper" ] && kill -0 "$reaper" 2>/dev/null && echo "reaper=$reaper"
  } > "$KEEP_STATE.new" || true
  mv "$KEEP_STATE.new" "$KEEP_STATE"
  if [ -z "$(keep_field reaper)" ]; then
    VM_KEEP_STATE="$KEEP_STATE" detached bash "$HERE/vm-keep-reaper.sh" </dev/null >/dev/null 2>&1 &
    echo "reaper=$!" >> "$KEEP_STATE"
  fi
  return 0
}
keep_guest() {
  # tart stop is a hard power-off on this guest (tart_stop_clean); if the guest is ever powered off without
  # the reaper's clean stop, only what was synced survives. So sync after every kept run.
  tart exec "$VM" sync >/dev/null 2>&1 || true
  write_keep_state
  log "kept $VM up for the next call (stops after ${VM_KEEP_IDLE:-300} s idle, on memory pressure, or when this session ends; now: $0 stop)"
}

trap cleanup EXIT
tart_lock_acquire "${LOCK_WAIT:-120}" \
  || die "the GUI VM is in use by another run (pid ${TART_LOCK_OWNER:-?}) — wait for it, or check: pgrep -fl gui-vm-gate"

SPEC_REL="$(archive_app_field "$APP" spec)";        PROJ_REL="$(archive_app_field "$APP" proj)"
SCHEME="$(archive_app_field "$APP" scheme)";        GUEST_DD="$(archive_app_field "$APP" dd)"
GUEST_APP="$(archive_app_field "$APP" appbundle)"   # procname is read by tart_kill_app, not needed here
GUEST_FIXTURE="$(archive_app_field "$APP" fixture)"; MKFIXTURE="$(archive_app_field "$APP" mkfixture)"
LAUNCHCMD="$(archive_app_field "$APP" launchcmd)";  PRERUN="$(archive_app_field "$APP" prerun)"
CORRUPT_TEST_SELECTOR=""
if [ "${CORRUPT_INDEX_FIXTURE:-0}" = "1" ]; then
  case "$APP" in
    reader)
      MKFIXTURE="AR_GUI_CORRUPT_INDEX=1 $MKFIXTURE"
      CORRUPT_TEST_SELECTOR="ArchiveReaderUITests/ContentIndexFailureUITests/testCorruptIndexWarningRetractsAfterScratchRepairAndReindex"
      ;;
    notes)
      MKFIXTURE="AN_GUI_CORRUPT_INDEX=1 $MKFIXTURE"
      CORRUPT_TEST_SELECTOR="ArchiveNotesUITests/NotesGUITests/testCorruptIndexWarningRetractsAfterScratchRepairAndReindex"
      ;;
    *) die "CORRUPT_INDEX_FIXTURE is supported only for reader and notes." ;;
  esac
  if [ -n "${ONLY_TESTING:-}" ] && [ "$ONLY_TESTING" != "$CORRUPT_TEST_SELECTOR" ]; then
    die "corrupt-index fixtures require ONLY_TESTING=$CORRUPT_TEST_SELECTOR"
  fi
fi
# READER_JOURNEY=rehearsal (W40.d8): the Reader triage journey on folders of the W40.c2 real-corpus sample,
# copied from the read-only rehearsal share onto the guest disk at the fixture path (make-journey-fixture.sh).
# Only the journey runs: the other UITests assert on the synthetic fixture's files.
if [ "${READER_JOURNEY:-}" = "rehearsal" ]; then
  [ "$APP" = reader ] || die "READER_JOURNEY is supported only for reader."
  [ -n "$CORRUPT_TEST_SELECTOR" ] && die "READER_JOURNEY and CORRUPT_INDEX_FIXTURE cannot be combined."
  [ -d "$REHEARSAL/reader-sample" ] || die "no Reader rehearsal sample at $REHEARSAL/reader-sample (ArchiveReader/scripts/rehearsal-sample.py make)"
  MKFIXTURE='bash "$GR/ArchiveReader/scripts/make-journey-fixture.sh"'
  CORRUPT_TEST_SELECTOR="ArchiveReaderUITests/TriageJourneyUITests"
  # W40.fix-reader-viewer-switch: the read-only file-switch measurement runs on the same sample root.
  [ "${ONLY_TESTING:-}" = "ArchiveReaderUITests/ViewerSwitchUITests" ] && CORRUPT_TEST_SELECTOR="$ONLY_TESTING"
  if [ -n "${ONLY_TESTING:-}" ] && [ "$ONLY_TESTING" != "$CORRUPT_TEST_SELECTOR" ]; then
    die "READER_JOURNEY=rehearsal runs only ONLY_TESTING=$CORRUPT_TEST_SELECTOR (or ArchiveReaderUITests/ViewerSwitchUITests)"
  fi
elif [ -n "${READER_JOURNEY:-}" ]; then
  die "unknown READER_JOURNEY '$READER_JOURNEY' (use: rehearsal)"
fi
# NOTES_JOURNEY=integrations (W40.d10): Notes against a REAL Zotero and the REAL Reader. The lane builds
# Reader at this commit in the guest (so Launch Services routes archivereader:// to it), starts Zotero with
# its local API on and a seeded item (ArchiveNotes/scripts/vm-zotero.sh), then runs only the journey class,
# which skips itself in every other run because nothing else prepares those apps.
NOTES_INTEGRATIONS=0
if [ "${NOTES_JOURNEY:-}" = "integrations" ]; then
  [ "$APP" = notes ] || die "NOTES_JOURNEY is supported only for notes."
  [ -n "$CORRUPT_TEST_SELECTOR" ] && die "NOTES_JOURNEY and CORRUPT_INDEX_FIXTURE cannot be combined."
  NOTES_INTEGRATIONS=1
  CORRUPT_TEST_SELECTOR="${ONLY_TESTING:-ArchiveNotesUITests/IntegrationJourneyUITests}"
  case "$CORRUPT_TEST_SELECTOR" in
    ArchiveNotesUITests/IntegrationJourneyUITests|ArchiveNotesUITests/IntegrationJourneyUITests/*) : ;;
    *) die "NOTES_JOURNEY=integrations runs only ArchiveNotesUITests/IntegrationJourneyUITests[/<test>]" ;;
  esac
elif [ -n "${NOTES_JOURNEY:-}" ]; then
  die "unknown NOTES_JOURNEY '$NOTES_JOURNEY' (use: integrations)"
fi
# PROCESSOR_JOURNEY=livecapture (W40.d5): live capture with the tag cards and Finish done by hand in the guest
# (LiveCaptureJourneyUITests) while the real Android companion on a headless AVD on the HOST sends real photos
# (ArchiveProcessor/scripts/live-capture-journey-phone.sh, started in the background below). The test reads
# TEST_RUNNER_W40D5_DIR and skips itself in every other run, because nothing else starts a phone.
PROCESSOR_LIVECAPTURE=0
LIVE_GDIR="$GUEST_HOME/w40d5-live-capture"
if [ "${PROCESSOR_JOURNEY:-}" = "livecapture" ]; then
  [ "$APP" = processor ] || die "PROCESSOR_JOURNEY is supported only for processor."
  [ "$LANE" = xcuitest ] || die "PROCESSOR_JOURNEY=livecapture runs on the xcuitest lane only."
  [ -n "$CORRUPT_TEST_SELECTOR" ] && die "PROCESSOR_JOURNEY and CORRUPT_INDEX_FIXTURE cannot be combined."
  PROCESSOR_LIVECAPTURE=1
  CORRUPT_TEST_SELECTOR="ArchiveProcessorUITests/LiveCaptureJourneyUITests"
  if [ -n "${ONLY_TESTING:-}" ] && [ "$ONLY_TESTING" != "$CORRUPT_TEST_SELECTOR" ]; then
    die "PROCESSOR_JOURNEY=livecapture runs only ONLY_TESTING=$CORRUPT_TEST_SELECTOR"
  fi
elif [ -n "${PROCESSOR_JOURNEY:-}" ]; then
  die "unknown PROCESSOR_JOURNEY '$PROCESSOR_JOURNEY' (use: livecapture)"
fi
ONLY_TESTING="${ONLY_TESTING:-${CORRUPT_TEST_SELECTOR:-$(archive_app_field "$APP" tests)}}"
TEST_ARGS="$(archive_xcode_test_args "$ONLY_TESTING")" \
  || die "invalid VM test selector list '$ONLY_TESTING' (comma-separated Xcode test identifiers only)"
# TEST_ITERATIONS=N reruns the selection up to N times and stops at the first failure — the way to
# chase an intermittent test (W9.g16-flake) without paying a VM boot and build per attempt.
if [ -n "${TEST_ITERATIONS:-}" ]; then
  [[ "$TEST_ITERATIONS" =~ ^[1-9][0-9]*$ ]] || die "TEST_ITERATIONS must be a positive integer"
  TEST_ARGS="$TEST_ARGS-test-iterations $TEST_ITERATIONS -run-tests-until-failure "
fi
if [ "$VM_SPLIT" -gt 0 ]; then
  [ "$LANE" = xcuitest ] || die "VM_SPLIT runs on the xcuitest lane only."
  [ -z "$CORRUPT_TEST_SELECTOR" ] && [ "${VISUAL_REVIEW:-0}" != 1 ] && [ "${TRANSIENT_VIDEO:-0}" != 1 ] \
    && [ -z "${TEST_ITERATIONS:-}" ] || die "VM_SPLIT cannot be combined with a journey, a fixture variant, VISUAL_REVIEW, TRANSIENT_VIDEO or TEST_ITERATIONS."
fi
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
  if tart list 2>/dev/null | awk -v v="$VM" '$2==v && $NF=="running"{f=1} END{exit !f}' && [ -f "$KEEP_STATE" ]; then
    # A guest VM_KEEP=1 left up. Take it over only if it was booted with THIS checkout and the same shares,
    # for the xcuitest lane, and this run's xcodegen did not rewrite the project under its mount (the
    # 2026-08-10 "missing its project.pbxproj file" read; see the GENERATE BEFORE BOOTING note). Else restart.
    local why=""
    [ "$(sed -n 's/^repo=//p' "$KEEP_STATE" | tail -n 1)" = "$REPO" ] || why="it mounts another checkout"
    [ "$(sed -n 's/^art=//p' "$KEEP_STATE" | tail -n 1)" = "$ART" ] || why="it mounts another artifact directory"
    [ "$(sed -n 's/^rehearsal=//p' "$KEEP_STATE" | tail -n 1)" = "$([ -d "$REHEARSAL" ] && echo 1 || echo 0)" ] || why="its shares differ"
    [ "$LANE" = xcuitest ] || why="the $LANE lane needs a guest this run boots"
    [ "${PROJ_REWRITTEN:-0}" = 0 ] || why="xcodegen rewrote the project"
    # The reaper stays alive: it never stops a guest while a live run holds the VM lock, and it re-reads the
    # state this run writes at its end.
    if [ -z "$why" ] && tart_wait_agent "$VM" 30; then
      VM_BOOTED=1
      log "reusing the kept guest (no boot)"
      return 0
    fi
    log "restarting the kept guest: ${why:-its agent did not answer}"
    tart_stop_clean "$VM"; rm -f "$KEEP_STATE"
  fi
  if tart list 2>/dev/null | awk -v v="$VM" '$2==v && $NF=="running"{f=1} END{exit !f}'; then
    [ "$LANE" = "xcuitest" ] || die "VM '$VM' is already running and this script did not start it, so there is no VNC endpoint (and the mounts may be wrong). Stop it first:  tart stop $VM"
    log "VM already running — reusing it (xcuitest only needs the guest agent)."
    tart_wait_agent "$VM" "$AGENT_WAIT" || die "guest agent never answered within ${AGENT_WAIT}s on the already-running VM."
    ensure_display
    return 0
  fi
  local runlog="$APP_ART/tart-run.log"; : > "$runlog"
  # Snapshot BEFORE the boot: if the owner already had Screen Sharing open, tart's auto-opened viewer is
  # not ours to close (see close_vm_viewer).
  SS_WAS_RUNNING=0; pgrep -x "Screen Sharing" >/dev/null 2>&1 && SS_WAS_RUNNING=1
  local mounts=(--dir=repo:"$REPO" --dir=out:"$ART")
  # W40.c1: the regenerable rehearsal sets, READ-ONLY, at /Volumes/My Shared Files/rehearsal. A journey
  # copies the set it needs onto the guest disk first (verification/rehearsal.md says how), so nothing the
  # app does in the guest can reach the host copy. Absent on a machine that never built a set; then no share.
  [ -d "$REHEARSAL" ] && mounts+=(--dir=rehearsal:"$REHEARSAL":ro)

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
  # --no-clipboard, every lane (W9.g4-flake, measured 2026-10-11). `tart run` SHARES THE CLIPBOARD by
  # default, and the guest runs tart-guest-agent, which serves it: a copy anywhere on the host replaced the
  # guest's general pasteboard within seconds. G4/G5/G13/G16 seed that pasteboard and read it back moments
  # later, so a host copy in between swapped G4's PNG for text, the paste declined, and no asset appeared.
  # Tests need a pasteboard nothing outside the guest can write.
  rm -f "$KEEP_STATE"   # a fresh boot: whatever kept guest the state named is gone (its reaper exits)
  log "booting $VM (${gfx[*]} --no-clipboard) + repo/artifact shares…"
  VM_BOOTED=1
  # VM_KEEP=1: the guest must outlive this script, so it must not die with its process group either.
  # VM_KEEP=1: the guest must outlive this script, in a session of its own (→ detached, above).
  if [ "$VM_KEEP" = 1 ] && [ "$LANE" = xcuitest ]; then
    detached tart run "$VM" "${gfx[@]}" --no-clipboard "${mounts[@]}" </dev/null >>"$runlog" 2>&1 &
  else
    tart run "$VM" "${gfx[@]}" --no-clipboard "${mounts[@]}" >>"$runlog" 2>&1 &
  fi
  echo $! > "$APP_ART/tart-run.pid"
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
  if [ "$VM_KEEP" = 1 ] && [ "$LANE" = xcuitest ]; then write_keep_state; fi
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
  if [ "$VM_KEEP" = 1 ]; then
    # A kept guest has this checkout mounted, and xcodegen rewrites the whole bundle (new inodes) even when
    # nothing changed. With its cache it writes only on a real change; PROJ_REWRITTEN then restarts the guest.
    local pbx="$REPO/$PROJ_REL/project.pbxproj" before after; mkdir -p "$REPO/build"
    before="$(stat -f %i "$pbx" 2>/dev/null || echo none)"
    xcodegen generate --use-cache --cache-path "$REPO/build/xcodegen-$APP.cache" --spec "$REPO/$SPEC_REL" >/dev/null
    after="$(stat -f %i "$pbx" 2>/dev/null || echo none)"
    [ "$before" = "$after" ] || PROJ_REWRITTEN=1
  else
    xcodegen generate --spec "$REPO/$SPEC_REL" >/dev/null
  fi
  if [ "$NOTES_INTEGRATIONS" = 1 ]; then
    log "xcodegen generate (reader, for the integration journey)…"
    xcodegen generate --spec "$REPO/$(archive_app_field reader spec)" >/dev/null
    PROJ_REWRITTEN=1   # uncached: a kept guest must not read it mid-rewrite
  fi
}

# --- NOTES_JOURNEY=integrations: the real Reader and the real Zotero, in the guest ---
prepare_integrations() {
  [ "$NOTES_INTEGRATIONS" = 1 ] || return 0
  local rdd rapp rc=0
  rdd="$(archive_app_field reader dd)"; rapp="$(archive_app_field reader appbundle)"
  tart_kill_app "$VM" reader
  tart_prepare_gui_dd "$VM" reader || rc=$?
  [ "$rc" = 0 ] || die "could not prepare the VM's Reader DerivedData — ${TART_GUI_DD_NOTE:-no report}"
  log "building Reader in the VM for the integration journey…"
  tart exec "$VM" bash -lc "
    xcodebuild build -project '$GUEST_REPO/$(archive_app_field reader proj)' -scheme ArchiveReader \
      -destination 'platform=macOS' -derivedDataPath '$rdd' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
  " > "$APP_ART/reader-build.log" 2>&1 || true
  grep -q '\*\* BUILD SUCCEEDED \*\*' "$APP_ART/reader-build.log" || die "the Reader build failed in the VM (log: $APP_ART/reader-build.log)"
  tart exec "$VM" bash -lc "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f '$rapp'" \
    || die "could not register the built Reader with Launch Services"
  log "starting Zotero in the VM…"
  tart exec "$VM" bash "$GUEST_REPO/ArchiveNotes/scripts/vm-zotero.sh" start | tee "$APP_ART/zotero.log" \
    | grep -q '^ZOTERO_KEY=' || die "Zotero did not start with its seeded item (log: $APP_ART/zotero.log)"
  # The journey class runs only where this marker is; the fixture restore copies it from the pristine copy.
  tart exec "$VM" bash -lc "touch '$GUEST_FIXTURE.pristine/.w40-d10-lane' '$GUEST_FIXTURE/.w40-d10-lane'" \
    || die "could not mark the fixture for the integration journey"
}

# --- the scratch GUI fixture, built INSIDE the guest (idempotent; persists on the VM disk) ---
ensure_fixture() {
  [ -n "$MKFIXTURE" ] || return 0
  # REBUILD every run, not "only if absent". The UITests mutate the fixture and are written against a
  # fresh one (NotesGUITests.swift:81-88: rebuilt "before each GUI run"; G8 trashes the Zotero note, G5
  # pastes a block into it). Build-if-absent lets those pass at most once, then fail forever and look
  # like app bugs. Both builders are idempotent and rm -rf only their own scratch dir.
  log "rebuilding the GUI fixture inside the VM…"
  # Deliberately NOT silenced. The previous version piped this to /dev/null with `|| true`, so when its
  # source path turned out to be unmounted the failure was invisible and the whole suite quietly XCTSkipped
  # while still reporting success.
  # …but the VERDICT comes from the GUEST's own exit status (tart_build_fixture), never from `tart exec`'s,
  # which fails on its own transport and cried wolf on half the runs — W26.fixwarn.
  local rc=0
  tart_build_fixture "$VM" "$MKFIXTURE" 5 || rc=$?
  if [ -n "$TART_FIXTURE_TAIL" ]; then printf '%s\n' "$TART_FIXTURE_TAIL"; fi
  case "$rc" in
    0) : ;;
    1) warn "fixture build FAILED inside the guest (exit $TART_FIXTURE_RC; output above)." ;;
    *) warn "could not read the fixture build's exit status back from the guest — that is tart's transport,
    NOT necessarily the build. The presence check below is the real verdict." ;;
  esac
  # A journey root is real-corpus sample material: never run the journey on a root whose copy check failed.
  # The builder writes its note last, after that check, so its absence is the verdict (W40.d8).
  if [ "${READER_JOURNEY:-}" = "rehearsal" ]; then
    tart exec "$VM" bash -lc "[ -f '$GUEST_FIXTURE/.w40-journey-set.txt' ]" >/dev/null 2>&1 \
      || die "the journey root was not built (make-journey-fixture.sh failed; output above) — not running the journey."
  fi
  tart exec "$VM" bash -lc "[ -d '$GUEST_FIXTURE' ]" >/dev/null 2>&1 \
    || warn "fixture STILL absent after the build attempt — fixtured UITests will FAIL in setUp (W40.a4: they no longer skip)."
}

# --- PREFLIGHT: is the guest's accessibility tree actually being served? -----------------------------
# XCUITest reads the accessibility tree, so if the guest's Accessibility grant is not honoured EVERY window
# assertion fails — with a message ("Main window should appear") that reads exactly like a product bug. On
# 2026-08-10 that cost a day of hunting a phantom regression in both apps and then parked the daemon: the
# apps were drawing correctly the whole time, and the real fault was a TCC row whose stored code
# requirement no longer matched the guest agent. Ask first, so the lane can name its own broken
# environment instead of blaming the change under test. → ops/gui/vm-check-accessibility.swift
assert_accessibility() {
  local out
  out="$(tart exec "$VM" bash -lc \
    "swift '$GUEST_REPO/ops/gui/vm-check-accessibility.swift'" 2>&1)" || {
    printf '%s\n' "$out" >&2
    die "the GUI VM is not serving the accessibility tree, so XCUITest cannot see any window and every
     test in this bundle would fail for a reason that has nothing to do with your change.
     Repair it:  ops/gui/vm-seed-accessibility.sh    (then re-run this lane)"
  }
  printf '%s\n' "$out" | sed 's/^/  /'
}

# --- TRANSIENT_VIDEO=1: record the guest's screen across the run (W40.e13, the confirmation instrument) ------
# The transient recorder reads the accessibility tree, so it cannot see a layer painted out of place; a video
# of the guest's display can. `screencapture -v` runs in the guest under the agent's Screen Recording grant
# (vm-seed-accessibility-guest.sh). It is a separate `tart exec` kept in the host's background, because a child
# left behind by a finished `tart exec` session is not guaranteed to live; SIGINT makes it finalize the movie.
# The app is built first so the movie holds the tests rather than minutes of compiling. TransientCheck prints
# each transition's guest epoch (`transient-mark:`), and ops/gui/transient-frames.py lines them up with the
# movie's own creation_time. Frame rate and what it can see: ops/gui/README.md §"Screen video".
TRANSIENT_VIDEO="${TRANSIENT_VIDEO:-0}"
VIDEO_PID=""
video_start() {
  [ "$TRANSIENT_VIDEO" = 1 ] || return 0
  log "TRANSIENT_VIDEO=1: building first, so the recording holds only the tests…"
  tart exec "$VM" bash -lc "xcodebuild build-for-testing -project '$GUEST_REPO/$PROJ_REL' -scheme '$SCHEME' \
    -destination 'platform=macOS' -derivedDataPath '$GUEST_DD' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO" \
    > "$APP_ART/video-build.log" 2>&1 || warn "build-for-testing failed before the recording (log: $APP_ART/video-build.log)"
  tart exec "$VM" bash -lc "pkill -x screencapture; rm -f /tmp/transient.mov /tmp/transient.start" >/dev/null 2>&1 || true
  tart exec "$VM" bash -lc "exec screencapture -v -x /tmp/transient.mov" > "$APP_ART/video-capture.log" 2>&1 &
  VIDEO_PID=$!
  if kill -0 "$VIDEO_PID" 2>/dev/null; then log "screen recording started in the guest"
  else warn "screencapture exited at once — no video this run: $(tr '\n' ' ' < "$APP_ART/video-capture.log")"; VIDEO_PID=""; fi
}
video_stop() {
  [ -n "$VIDEO_PID" ] || return 0
  tart exec "$VM" bash -lc "pkill -INT -x screencapture" >/dev/null 2>&1 || true
  local i; for i in $(seq 1 60); do kill -0 "$VIDEO_PID" 2>/dev/null || break; sleep 1; done
  kill "$VIDEO_PID" 2>/dev/null || true
  VIDEO_PID=""
  rm -f "$APP_ART/transient.mov" "$APP_ART/transient.start" "$APP_ART/transient-frames.txt"
  rm -rf "$APP_ART/transient-frames"
  if tart exec "$VM" bash -lc "cp /tmp/transient.mov '/Volumes/My Shared Files/out/$APP/'" >/dev/null 2>&1; then
    log "screen video: $APP_ART/transient.mov — scan it: ops/gui/transient-frames.py $APP_ART"
  else
    warn "the guest's screen video could not be collected (log: $APP_ART/video-capture.log)"
  fi
}

# --- LANE: XCUITest (accessibility) ---
# Per guest boot: kill the app, run the prerun, ready the DerivedData.
prepare_guest_for_tests() {
  # Before the prerun, which is a container wipe: the guest boots with whatever was running when it was
  # last stopped, the app-under-test included (→ tart_kill_app).
  tart_kill_app "$VM" "$APP"
  [ -n "$PRERUN" ] && tart exec "$VM" bash -lc "$PRERUN" >/dev/null 2>&1
  local ddrc=0
  tart_prepare_gui_dd "$VM" "$APP" || ddrc=$?
  case "$ddrc" in
    0) log "${TART_GUI_DD_NOTE:-storage: reusing DerivedData}" ;;
    1) die "the VM guest is too full for a safe $APP build — ${TART_GUI_DD_NOTE:-no free-space report}. Free space, then rerun." ;;
    *) die "could not prepare the VM's $APP DerivedData — ${TART_GUI_DD_NOTE:-guest transport failed}." ;;
  esac
}

# run_tests ACTION ARGS NAME — one guarded guest `xcodebuild ACTION` into $APP_ART/NAME.log, result bundle
# NAME.xcresult, with the load sampler beside it. Leaves its verdict in RUN_VERDICT (tart_test_verdict).
# xcodebuild REFUSES to overwrite an existing -resultBundlePath, so a fixed path makes every re-run fail
# before executing a single test. Remove it first.
# CODE_SIGN_IDENTITY=- : the guest has no keychain, so it cannot use the host's "Archive Suite Dev"
# cert (W28.cert). Same rationale as ops/autonomous/gui-vm-gate.sh — see the long note there.
# Note for anyone adding a flag here: xcodebuild's environment is NOT inherited by an app-hosted test
# process (measured — an env var set on this line reads as unset inside the test). SnapshotTests
# therefore detects this VM from `hw.model` rather than from anything passed in here.
run_tests() {
  local action="$1" args="$2" name="$3" glog="$APP_ART/$3.log" t0 bundle="$3"
  [ "$name" = xcuitest ] && bundle=uitest   # the single run's bundle keeps its long-standing name
  : > "$glog"
  [ "$VM_SAMPLE" -gt 0 ] && tart_sampler_start "$VM" "$APP_ART/sampler-$name.tsv" "$VM_SAMPLE" "$(archive_app_field "$APP" procname)"
  t0="$(date +%s)"
  tart_run_test "$VM" "$glog" "
    rm -rf '$GUEST_DD/$bundle.xcresult'
    $TEST_ENV xcodebuild $action \
      -project '$GUEST_REPO/$PROJ_REL' -scheme '$SCHEME' \
      $args -destination 'platform=macOS' \
      -derivedDataPath '$GUEST_DD' -resultBundlePath '$GUEST_DD/$bundle.xcresult' \
      CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
  " || true
  tart_sampler_stop
  grep -E "^Test Suite '[^']*' (passed|failed)|^[[:space:]]+Executed [0-9]+ test|\*\* TEST|^\[guard\]" "$glog" || true
  [ -n "$TART_TEST_GUARD" ] && warn "the guest's xcodebuild did not end by itself ($TART_TEST_GUARD guard; see the [guard] line in $glog)"
  RUN_VERDICT="$(tart_test_verdict "$glog")"
  log "$name: $RUN_VERDICT in $(( $(date +%s) - t0 )) s (log: $glog)"
}

run_xcuitest() {
  assert_accessibility
  prepare_guest_for_tests
  # W40.e10: the screen-by-screen visual review tour (`VisualReviewUITests`) runs only while this flag
  # file exists beside the app's fixture, because it is minutes long and writes hundreds of shots. Set or
  # clear it on every run so a previous VISUAL_REVIEW=1 run cannot leave it switched on.
  local vflag; vflag="$(dirname "$GUEST_FIXTURE")/.visual-review"
  # W40.e11: Notes' UITest runner is sandboxed to its fixture, and each test restores the fixture from its
  # pristine copy, so for Notes the flag also goes inside both.
  local vflags="\"$vflag\""
  [ "$APP" = notes ] && vflags="$vflags \"$GUEST_FIXTURE/.visual-review\" \"$GUEST_FIXTURE.pristine/.visual-review\""
  if [ "${VISUAL_REVIEW:-0}" = "1" ]; then
    tart exec "$VM" bash -lc "mkdir -p \"$(dirname "$vflag")\" && touch $vflags" >/dev/null 2>&1 \
      || die "could not set the visual-review flag in the guest"
    # Notes' volume pass opens the W40.c1 rehearsal store (400 items, many chips, odd titles), built in the
    # guest's own cache by its generator, which refuses a destination outside that cache.
    if [ "$APP" = notes ]; then
      log "building the Notes rehearsal store in the VM for the visual review…"
      tart exec "$VM" bash -lc "python3 '$GUEST_REPO/ArchiveNotes/scripts/make-notes-rehearsal.py'" \
        > "$APP_ART/rehearsal-store.log" 2>&1 || die "the rehearsal store build failed (log: $APP_ART/rehearsal-store.log)"
    fi
  else
    tart exec "$VM" bash -lc "rm -f $vflags" >/dev/null 2>&1 || true
  fi
  TEST_ENV=""
  if [ "$PROCESSOR_LIVECAPTURE" = 1 ]; then start_phone_leg; TEST_ENV="TEST_RUNNER_W40D5_DIR='$LIVE_GDIR'"; fi
  rm -f "$APP_ART"/sampler-*.tsv "$APP_ART"/chunk*.log
  if [ "$VM_SPLIT" -gt 0 ]; then
    run_split
  else
    # Always `test`: on a kept guest the DerivedData is warm, and Xcode's incremental build of unchanged
    # sources is the build reuse (measured 2026-11-12: 21 s for a whole Smoke call, as fast as
    # `test-without-building`, which would also test a stale build after an edit).
    log "test: $ONLY_TESTING for $APP in the VM…"
    video_start
    tart_crash_mark "$VM"
    run_tests test "$TEST_ARGS" xcuitest
    [ "$PROCESSOR_LIVECAPTURE" = 1 ] && stop_phone_leg
    video_stop
    # Clear the flag straight away: the health gate's gui-vm-gate.sh shares this VM but not this script.
    tart exec "$VM" bash -lc "rm -f $vflags" >/dev/null 2>&1 || true
    collect_shots
    collect_xcresult
    collect_crashes
    [ "$RUN_VERDICT" = succeeded ] || XCUITEST_FAILED=1
  fi
  if [ "$XCUITEST_FAILED" = 0 ]; then
    collect_snapshot_reference
  else
    # W35.vm-mem-fu1: this used to be a WARN and the script still exited 0, so anything wrapping the lane
    # (the W35.vm-mem measurement, a session's own `&& echo green`) read a red suite as a pass — Notes was
    # 21/31 red for days that way. Record the verdict; the script exits non-zero at the end, after the
    # artifacts (and, for `both`, the sighted lane) are collected. The health gate does not call this
    # script — gui-vm-gate.sh keys on the same marker itself — so the gate's verdict is unchanged.
    warn "the XCUITest run for $APP did not succeed (failed, or never finished); see the log."
  fi
}

# --- VM_SPLIT=N: the selection as N chunks of whole classes, each in a freshly booted guest ---
# W40.vm-macos27-runtime (1): on the macOS 27.2 guest a long lane slows down as it goes. One build, then
# `-enumerate-tests` names every selected test (so no class can be dropped by a source grep), the classes are
# dealt into N contiguous chunks in run order, and each chunk runs `test-without-building` after a clean
# restart and a fresh fixture. xcuitest.log is the chunks' logs in order, so collect_shots and a reader of
# the log see one run; each chunk keeps its own log, sampler, result bundle and crash harvest.
run_split() {
  local list="$APP_ART/enumerated-tests.txt" classes n k=0 per i chunk args total=0
  log "VM_SPLIT=$VM_SPLIT: building once, then enumerating the selection…"
  run_tests build-for-testing "" build
  grep -q '\*\* TEST BUILD SUCCEEDED \*\*' "$APP_ART/build.log" || die "the guest build failed (log: $APP_ART/build.log)"
  tart exec "$VM" bash -lc "xcodebuild test-without-building -project '$GUEST_REPO/$PROJ_REL' -scheme '$SCHEME' \
      $TEST_ARGS -destination 'platform=macOS' -derivedDataPath '$GUEST_DD' \
      -enumerate-tests -test-enumeration-style flat -test-enumeration-format text -test-enumeration-output-path - \
      CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO" > "$list.raw" 2>&1 || true
  # Selected tests are listed as Bundle/Class/test (disabled ones are not, so the chunks run what one run would).
  grep -oE '^[[:space:]]*[A-Za-z0-9_]+/[A-Za-z0-9_]+/[A-Za-z0-9_]+' "$list.raw" | tr -d ' \t' > "$list" || true
  classes="$(awk -F/ '!seen[$1"/"$2]++{print $1"/"$2}' "$list")"
  n="$(printf '%s\n' "$classes" | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "$n" -gt 0 ] || die "could not enumerate the selected tests (output: $list.raw)"
  log "$(wc -l < "$list" | tr -d ' ') tests in $n classes, in $VM_SPLIT chunk(s)"
  per=$(( (n + VM_SPLIT - 1) / VM_SPLIT ))
  : > "$APP_ART/xcuitest.log"
  rm -rf "$APP_ART/shots"
  for (( i = 0; i < n; i += per )); do
    k=$(( k + 1 )); chunk="chunk$k"
    args="$(printf '%s\n' "$classes" | sed -n "$(( i + 1 )),$(( i + per ))p" | sed 's/^/-only-testing:/' | tr '\n' ' ')"
    if [ "$k" -gt 1 ]; then
      log "$chunk: restarting the guest…"
      tart_stop_clean "$VM"; VM_BOOTED=0
      ensure_vm; ensure_fixture; assert_accessibility >/dev/null; prepare_guest_for_tests
    fi
    log "$chunk: $(printf '%s' "$args" | wc -w | tr -d ' ') classes"
    tart_crash_mark "$VM"
    run_tests test-without-building "$args" "$chunk"
    cat "$APP_ART/$chunk.log" >> "$APP_ART/xcuitest.log"
    collect_shots "$APP_ART/$chunk.log" keep
    collect_xcresult "$chunk"
    collect_crashes "crashes-$chunk"
    [ "$RUN_VERDICT" = succeeded ] || XCUITEST_FAILED=1
  done
}

# --- PROCESSOR_JOURNEY=livecapture: the phone leg on the host, and the guest-side file record afterwards ---
PHONE_PID=""
start_phone_leg() {
  local run="$APP_ART/live-capture"
  rm -rf "$run"; mkdir -p "$run"
  tart exec "$VM" bash -lc "rm -rf '$LIVE_GDIR' && mkdir -p '$LIVE_GDIR' && date +%s > '$LIVE_GDIR/started'" \
    || die "could not prepare $LIVE_GDIR in the guest"
  bash "$REPO/ArchiveProcessor/scripts/live-capture-journey-phone.sh" "$VM" "$LIVE_GDIR" "$run" \
    > "$run/phone-leg.out" 2>&1 &
  PHONE_PID=$!
  log "phone leg started (pid $PHONE_PID; log: $run/phone.log)"
}
stop_phone_leg() {
  local run="$APP_ART/live-capture" line out backup
  # `|| true`: under set -e, the killed leg's 143 from `wait` would end this script before its record and cleanup.
  if [ -n "$PHONE_PID" ]; then kill "$PHONE_PID" 2>/dev/null || true; wait "$PHONE_PID" 2>/dev/null || true; fi
  PHONE_PID=""
  # The AVD the leg booted (headless): stop it, as e2e-phone-mac.sh does.
  "${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}/platform-tools/adb" emu kill >/dev/null 2>&1 || true
  grep -q PHONE_LEG_DONE "$run/phone.log" 2>/dev/null || warn "the phone leg did not finish every phase (log: $run/phone.log)"
  # Outside the runner's sandbox: the filed PDFs' times and tags, and the Trash (live-capture-journey-record.sh).
  line="$(grep -o '\[w40d5\] live out=[^ ]* backup=[^ ]*' "$APP_ART/xcuitest.log" | head -1)"
  out="$(printf '%s' "$line" | sed -n 's/.* out=\([^ ]*\) .*/\1/p')"
  backup="$(printf '%s' "$line" | sed -n 's/.* backup=\([^ ]*\).*/\1/p')"
  [ -n "$out" ] || { warn "no live-phase paths in the xcuitest log; no file record"; return 0; }
  tart exec "$VM" bash "$GUEST_REPO/ArchiveProcessor/scripts/live-capture-journey-record.sh" \
    "$LIVE_GDIR/started" "$out" "$backup" > "$run/mac-files.txt" 2>&1 \
    || warn "guest file record incomplete (see $run/mac-files.txt)"
  log "guest file record: $run/mac-files.txt"
}

# --- bring the tests' screenshots back to the host (STEP 3.5's "READ the screenshot") ---------------
# A test CANNOT write to the artifact share itself: the XCUITest runner is sandboxed, so
# /Volumes/My Shared Files/out is not writable from inside it (measured 2026-08-09 — all five shots of a
# run reported "no writable artifact dir"). The test writes to its own temporary directory and prints
# `[shot] <name>: wrote <path>`; `tart exec` is NOT sandboxed, so the copy happens out here.
#
# The result bundle is deliberately not the channel: `xcresulttool` refuses a bundle that was never
# finalized, and that is exactly the state a failed or killed run leaves behind — recovering the shots
# then means classifying `…xcresult/Data` blobs by magic bytes.
collect_shots() {   # [LOG] [keep: add to this run's shots, for a VM_SPLIT chunk]
  local dest="$APP_ART/shots" n=0 p paths glog="${1:-$APP_ART/xcuitest.log}"
  # Clear the directory FIRST, unconditionally. If this run took no shots, an absent dir has to mean
  # "no shots this run" — leaving the previous run's PNGs there is worse than having none, because the
  # next session reads them as evidence about a run that never produced them. (A split run clears it once.)
  [ "${2:-}" = keep ] || rm -rf "$dest"
  # Greedy `.*` so a shot name containing a colon still resolves (the last ": wrote " wins), and `|| true`
  # because a missing log is not a reason to abort the run under `set -e`.
  paths="$(sed -nE 's/^\[shot\] .*: wrote (.+)$/\1/p' "$glog" 2>/dev/null | sort -u || true)"
  [ -n "$paths" ] || return 0
  mkdir -p "$dest"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # The guest paths contain spaces but no quotes, so double-quoting inside the -lc string is enough.
    if tart exec "$VM" bash -lc "cp \"$p\" '/Volumes/My Shared Files/out/$APP/shots/'" >/dev/null 2>&1; then
      n=$(( n + 1 ))
    else
      warn "a test wrote a screenshot at $p but it could not be collected"
    fi
  done <<< "$paths"
  log "$n screenshot(s) collected into $dest — READ them; pixels are the point of a GUI check."
}

# An intentional Reader snapshot re-record is not an ordinary diagnostic shot. The sandboxed test writes the
# reference into its own tmp directory and names exactly one `[shot] reader-snapshot-reference` line; only a
# green VM test may promote that artifact into the shared, guest-rendered reference. The Tart guest agent is
# unsandboxed and can write the repo share even though the app-hosted test process cannot.
collect_snapshot_reference() {
  [ "$APP" = reader ] || return 0
  local path target paths count
  paths="$(sed -nE 's/^\[shot\] reader-snapshot-reference: wrote (.+)$/\1/p' "$APP_ART/xcuitest.log" \
    | sort -u || true)"
  [ -n "$paths" ] || return 0
  count="$(printf '%s\n' "$paths" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$count" -ne 1 ]; then
    warn "refusing to promote multiple Reader snapshot recordings from one VM run"
    return 0
  fi
  path="$paths"
  case "$path" in
    "$GUEST_HOME"/Library/Containers/com.archivereader.app/Data/tmp/ArchiveReaderSnapshotTests-*/testDeterministicViewMatchesReference.1.png) ;;
    *)
      warn "refusing Reader snapshot recording outside the test host's expected temporary directory"
      return 0
      ;;
  esac
  target="$GUEST_REPO/ArchiveReader/macOS/Tests/ArchiveReaderTests/__Snapshots__/SnapshotTests/testDeterministicViewMatchesReference.1.png"
  if tart exec "$VM" bash -lc "cp \"$path\" \"$target\"" >/dev/null 2>&1; then
    log "Reader VM reference updated at ArchiveReader/macOS/Tests/ArchiveReaderTests/__Snapshots__/SnapshotTests/testDeterministicViewMatchesReference.1.png"
  else
    warn "Reader snapshot recording was not copied back to the committed reference"
  fi
}

# W40.e2: copy out every crash/hang report the run left in the guest (→ tart_crash_harvest). A crash or
# hang of one of OUR processes fails the run even when xcodebuild printed TEST SUCCEEDED — that is the
# case it exists for: an app that dies after its last assertion. Other processes' reports are kept and
# named, never fatal.
collect_crashes() {   # $1 = artifact subdir name under $APP_ART (default: crashes)
  local sub="${1:-crashes}" rc=0 f
  tart_crash_harvest "$VM" "$APP/$sub" "$APP" || rc=$?
  case "$rc" in
    0) log "crash harvest: no new crash or hang report from a suite process${TART_CRASH_FOREIGN:+ (reports from other processes kept in $APP_ART/$sub)}" ;;
    1) while IFS= read -r f; do [ -n "$f" ] && warn "CRASH REPORT from a suite process: $APP_ART/$sub/$f"; done <<< "$TART_CRASH_SUITE"
       CRASH_FOUND=1 ;;
    *) warn "crash harvest UNKNOWN — the guest's report listing did not come back intact (tart transport), so this run says nothing about crashes either way." ;;
  esac
  if [ -n "$TART_CRASH_FOREIGN" ]; then
    while IFS= read -r f; do [ -n "$f" ] && log "  report from another process (not fatal): $f"; done <<< "$TART_CRASH_FOREIGN"
  fi
  return 0
}

# Keep the result bundle beside the textual log and screenshots. It is useful when Xcode finalized it,
# but never the only screenshot channel: an interrupted test leaves its bundle unreadable.
collect_xcresult() {   # [NAME] (default uitest; the guest bundle is $GUEST_DD/NAME.xcresult)
  local name="${1:-uitest}" dest
  dest="$APP_ART/$name.xcresult"
  rm -rf "$dest"
  if tart exec "$VM" bash -lc "[ -d '$GUEST_DD/$name.xcresult' ] && cp -R '$GUEST_DD/$name.xcresult' '/Volumes/My Shared Files/out/$APP/'" >/dev/null 2>&1; then
    log "XCUITest result bundle: $dest"
  else
    warn "no finalized XCUITest result bundle could be collected for $APP"
  fi
}

build_for_sighted() {
  local ddrc=0
  tart_prepare_gui_dd "$VM" "$APP" || ddrc=$?
  case "$ddrc" in
    0) log "${TART_GUI_DD_NOTE:-storage: reusing DerivedData}" ;;
    1) die "the VM guest is too full for a safe $APP build — ${TART_GUI_DD_NOTE:-no free-space report}. Free space, then rerun." ;;
    *) die "could not prepare the VM's $APP DerivedData — ${TART_GUI_DD_NOTE:-guest transport failed}." ;;
  esac
  log "building $SCHEME in the VM (for the sighted lane)…"
  # CODE_SIGN_IDENTITY=- : guest has no keychain for the host's cert (W28.cert; see gui-vm-gate.sh).
  tart exec "$VM" bash -lc "xcodebuild build-for-testing -project '$GUEST_REPO/$PROJ_REL' -scheme '$SCHEME' -destination 'platform=macOS' -derivedDataPath '$GUEST_DD' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO" >/dev/null
}

# --- LANE: sighted (real pixels over VNC) ---
run_sighted() {
  [ -x "$VNCDOTOOL" ] || die "vncdotool not found at $VNCDOTOOL — recreate it:
    python3 -m venv ~/.tart-mirror/vncenv && ~/.tart-mirror/vncenv/bin/pip install vncdotool"
  [ -n "$VNC_PORT" ] || die "no VNC endpoint — this script must have started the VM for the sighted lane"
  # Same kill-then-wipe order as the xcuitest lane, through the shared helper rather than an inline
  # `pkill` (this lane's inline copy was the only one that ever did it — → tart_kill_app).
  tart_kill_app "$VM" "$APP"
  [ -n "$PRERUN" ] && tart exec "$VM" bash -lc "$PRERUN" >/dev/null 2>&1
  tart_crash_mark "$VM"
  log "launching $APP in the VM against its scratch fixture…"
  tart exec "$VM" bash -lc "
    GUEST_APP_PATH='$GUEST_APP'
    GUEST_FIXTURE_PATH='$GUEST_FIXTURE'
    $LAUNCHCMD
    sleep 9
  "
  local vnc=( "$VNCDOTOOL" -s "$VNC_HOST::$VNC_PORT" -p "$VNC_PASS" )
  log "capturing $APP off-screen over VNC…"
  "${vnc[@]}" capture "$APP_ART/sighted.png"
  log "artifact: $APP_ART/sighted.png  (Read it to eyeball the render)"
  collect_crashes crashes-sighted
  # Example off-screen interaction (framebuffer coords): adapt as needed.
  # "${vnc[@]}" move 765 269 click 1 pause 1 capture "$APP_ART/sighted-after-click.png"
}

log "app=$APP  lane=$LANE  vm=$VM"
# GENERATE BEFORE BOOTING — never the other way round. `gen_project` rewrites the `.xcodeproj` bundle on
# the HOST, and the guest builds it through the `--dir=repo:` share. Regenerating it while that share is
# already mounted lets the guest observe the directory mid-rewrite:
#     xcodebuild: error: Unable to read project 'ArchiveNotes.xcodeproj' … Reason: … cannot be opened
#     because it is missing its project.pbxproj file.
# Measured 2026-08-10: three back-to-back `notes xcuitest` runs, the 1st green and the 2nd and 3rd both
# dead on that error, with the pbxproj present and correct on the host the whole time. The health gate
# has always generated every app's project before `boot_vm`, which is why this only ever bit the
# interactive lane — the same one-entry-point-fixed asymmetry `tart-lib.sh`'s header exists to prevent.
XCUITEST_FAILED=0
CRASH_FOUND=0
gen_project
ensure_vm
ensure_fixture
prepare_integrations
case "$LANE" in
  xcuitest) run_xcuitest ;;
  sighted)  build_for_sighted; run_sighted ;;
  both)     run_xcuitest; build_for_sighted; run_sighted ;;
esac
log "done in $SECONDS s (after the heavy lock). Artifacts in $APP_ART"
[ "$CRASH_FOUND" = 0 ] || die "$APP left a crash or hang report in the guest — exiting non-zero (reports: $APP_ART/crashes*)"
[ "$XCUITEST_FAILED" = 0 ] || die "$APP XCUITest run did not succeed — exiting non-zero (log: $APP_ART/xcuitest.log)"
