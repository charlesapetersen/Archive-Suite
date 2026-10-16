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
#                VISUAL_REVIEW=1 (W40.e10/e11 screenshot tour; pair with ONLY_TESTING=<App>UITests/VisualReviewUITests).
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

# --- args: [app] [lane], app optional (old call sites pass only a lane) ---
APP="reader"; LANE="both"
case "${1:-}" in
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
  [ "$VM_BOOTED" = 1 ] && tart stop "$VM" >/dev/null 2>&1
  tart_lock_release
  return 0
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
  if [ -n "${ONLY_TESTING:-}" ] && [ "$ONLY_TESTING" != "$CORRUPT_TEST_SELECTOR" ]; then
    die "READER_JOURNEY=rehearsal runs only ONLY_TESTING=$CORRUPT_TEST_SELECTOR"
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
ONLY_TESTING="${ONLY_TESTING:-${CORRUPT_TEST_SELECTOR:-$(archive_app_field "$APP" tests)}}"
TEST_ARGS="$(archive_xcode_test_args "$ONLY_TESTING")" \
  || die "invalid VM test selector list '$ONLY_TESTING' (comma-separated Xcode test identifiers only)"
# TEST_ITERATIONS=N reruns the selection up to N times and stops at the first failure — the way to
# chase an intermittent test (W9.g16-flake) without paying a VM boot and build per attempt.
if [ -n "${TEST_ITERATIONS:-}" ]; then
  [[ "$TEST_ITERATIONS" =~ ^[1-9][0-9]*$ ]] || die "TEST_ITERATIONS must be a positive integer"
  TEST_ARGS="$TEST_ARGS-test-iterations $TEST_ITERATIONS -run-tests-until-failure "
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
  log "booting $VM (${gfx[*]} --no-clipboard) + repo/artifact shares…"
  VM_BOOTED=1
  tart run "$VM" "${gfx[@]}" --no-clipboard "${mounts[@]}" >>"$runlog" 2>&1 &
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
  if [ "$NOTES_INTEGRATIONS" = 1 ]; then
    log "xcodegen generate (reader, for the integration journey)…"
    xcodegen generate --spec "$REPO/$(archive_app_field reader spec)" >/dev/null
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

# --- LANE: XCUITest (accessibility) ---
run_xcuitest() {
  assert_accessibility
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
  tart_crash_mark "$VM"
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
  log "building + running $ONLY_TESTING for $APP in the VM…"
  # xcodebuild REFUSES to overwrite an existing -resultBundlePath, so a fixed path makes every re-run fail
  # before executing a single test. Remove it first.
  # CODE_SIGN_IDENTITY=- : the guest has no keychain, so it cannot use the host's "Archive Suite Dev"
  # cert (W28.cert). Same rationale as ops/autonomous/gui-vm-gate.sh — see the long note there.
  # Note for anyone adding a flag here: xcodebuild's environment is NOT inherited by an app-hosted test
  # process (measured — an env var set on this line reads as unset inside the test). SnapshotTests
  # therefore detects this VM from `hw.model` rather than from anything passed in here.
  tart exec "$VM" bash -lc "
    rm -rf '$GUEST_DD/uitest.xcresult'
    xcodebuild test \
      -project '$GUEST_REPO/$PROJ_REL' -scheme '$SCHEME' \
      $TEST_ARGS -destination 'platform=macOS' \
      -derivedDataPath '$GUEST_DD' -resultBundlePath '$GUEST_DD/uitest.xcresult' \
      CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
  " 2>&1 | tee "$APP_ART/xcuitest.log" | grep -E 'Test Suite|Executed [0-9]+ test|\*\* TEST' || true
  log "XCUITest log: $APP_ART/xcuitest.log"
  # Clear the flag straight away: the health gate's gui-vm-gate.sh shares this VM but not this script.
  tart exec "$VM" bash -lc "rm -f $vflags" >/dev/null 2>&1 || true
  collect_shots
  collect_xcresult
  collect_crashes
  if grep -q '\*\* TEST SUCCEEDED \*\*' "$APP_ART/xcuitest.log" 2>/dev/null; then
    collect_snapshot_reference
  else
    # W35.vm-mem-fu1: this used to be a WARN and the script still exited 0, so anything wrapping the lane
    # (the W35.vm-mem measurement, a session's own `&& echo green`) read a red suite as a pass — Notes was
    # 21/31 red for days that way. Record the verdict; the script exits non-zero at the end, after the
    # artifacts (and, for `both`, the sighted lane) are collected. The health gate does not call this
    # script — gui-vm-gate.sh keys on the same marker itself — so the gate's verdict is unchanged.
    warn "no '** TEST SUCCEEDED **' marker for $APP — the XCUITest run FAILED (or never finished); see the log."
    XCUITEST_FAILED=1
  fi
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
collect_shots() {
  local dest="$APP_ART/shots" n=0 p paths
  # Clear the directory FIRST, unconditionally. If this run took no shots, an absent dir has to mean
  # "no shots this run" — leaving the previous run's PNGs there is worse than having none, because the
  # next session reads them as evidence about a run that never produced them.
  rm -rf "$dest"
  # Greedy `.*` so a shot name containing a colon still resolves (the last ": wrote " wins), and `|| true`
  # because a missing log is not a reason to abort the run under `set -e`.
  paths="$(sed -nE 's/^\[shot\] .*: wrote (.+)$/\1/p' "$APP_ART/xcuitest.log" 2>/dev/null | sort -u || true)"
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
collect_xcresult() {
  local dest="$APP_ART/uitest.xcresult"
  rm -rf "$dest"
  if tart exec "$VM" bash -lc "[ -d '$GUEST_DD/uitest.xcresult' ] && cp -R '$GUEST_DD/uitest.xcresult' '/Volumes/My Shared Files/out/$APP/'" >/dev/null 2>&1; then
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
log "done. Artifacts in $APP_ART"
[ "$CRASH_FOUND" = 0 ] || die "$APP left a crash or hang report in the guest — exiting non-zero (reports: $APP_ART/crashes*)"
[ "$XCUITEST_FAILED" = 0 ] || die "$APP XCUITest run did not succeed — exiting non-zero (log: $APP_ART/xcuitest.log)"
