# tart-lib.sh — shared Tart/VM helpers + the one per-app table for the GUI lane.
# SOURCE this (`. "$(dirname "$0")/tart-lib.sh"`), never execute it.
#
# WHY THIS FILE EXISTS. On 2026-07-30 the guest-agent race was fixed in ops/autonomous/gui-vm-gate.sh and
# NOT in ops/gui/vm-gui-runner.sh — so the interactive entry point, the one resume-prompt STEP 3.5,
# CLAUDE.md and AGENTS.md all tell a session to use, stayed silently broken in exactly the way the gate had
# just been un-broken. Two copies of the same knowledge is how that happens. Everything both scripts need
# lives here, so a fix cannot land in only one of them.
#
# Works under both `set -euo pipefail` (the runner) and `set -uo pipefail` (the gate) — keep it that way:
# no bare `[ ... ]` as the last statement of a function, no unguarded command substitution on failure.

GUEST_REPO="${GUEST_REPO:-/Volumes/My Shared Files/repo}"      # --dir=repo:<suite root>
GUEST_CORPUS="${GUEST_CORPUS:-/Volumes/My Shared Files/corpus}" # --dir=corpus:<fixture PDFs>
GUEST_HOME="${GUEST_HOME:-/Users/admin}"                        # the Cirrus image's user

# ---------------------------------------------------------------------------------------------------
# `tart` must be FINDABLE before any of the helpers below mean anything (SUITE_TODO W21.vmgui-path).
# A non-login shell — launchd, `claude -p`, a hook — does not inherit Homebrew's bin dir, so an
# unqualified `tart` is simply "command not found". Every downstream check then reads as *"VM
# 'archive-gui-runner' not found — create it first"*, which is a lie: the VM is present and healthy.
# That misdiagnosis cost three daemon sessions (W23.m14, W23.m15, W23.l4) before it was named.
# It bit only ops/gui/vm-gui-runner.sh because ops/autonomous/gui-vm-gate.sh happened to carry its own
# `export PATH=/opt/homebrew/bin:$PATH` — the exact two-copies-of-one-fact split this file exists to end.
# Resolve it HERE, once, so both scripts inherit it, and keep the two failure modes distinguishable.
# One list, used by BOTH the search and the failure message, so the message can never claim to have
# looked somewhere it didn't.
TART_SEARCH_DIRS="${TART_SEARCH_DIRS:-/opt/homebrew/bin /usr/local/bin $HOME/.local/bin}"
if ! command -v tart >/dev/null 2>&1; then
  for _tart_dir in $TART_SEARCH_DIRS; do
    if [ -x "$_tart_dir/tart" ]; then PATH="$_tart_dir:$PATH"; export PATH; break; fi
  done
  unset _tart_dir
fi

# tart_require — 0 if the `tart` binary is usable; else explain WHY on stderr and return 1. Callers turn
# that into their own kind of fatal (the runner dies, the gate skips), but they must not report it as a
# missing VM. Deliberately says nothing about the VM: it cannot know, since it cannot run `tart list`.
tart_require() {
  command -v tart >/dev/null 2>&1 && return 0
  printf '%s\n' \
    "tart is NOT INSTALLED or not on PATH — this is not the same as the VM being missing." \
    "  looked for it on PATH, then in: $TART_SEARCH_DIRS" \
    "  PATH was: $PATH" \
    "  install:  brew install cirruslabs/cli/tart      (setup: ops/gui/README.md §3)" >&2
  return 1
}

# ---------------------------------------------------------------------------------------------------
# archive_app_field APP FIELD — the single per-app config table for the whole GUI lane.
# Adding an app is one block here, not a fork of either script.
#   spec/proj/scheme/tests : xcodegen spec (host, repo-relative), .xcodeproj (repo-relative), scheme,
#                            UITest bundle
#   dd                     : guest DerivedData (one per app, so they can't clobber each other)
#   appbundle              : built .app inside dd — the sighted lane launches this
#   procname               : `pkill -x` name
#   fixture                : guest scratch fixture dir the UITests XCTSkip without
#   mkfixture              : guest command to BUILD that fixture. Evaluated inside a remote `bash -lc`
#                            with $GR = the repo mount and $GC = the corpus mount — hence single quotes
#                            here: these must expand in the GUEST, not on the host.
#   launcharg              : DEBUG-only launch argument pointing the app at the scratch fixture
#   prerun                 : guest command to run before each attempt (blank = none)
# ---------------------------------------------------------------------------------------------------
archive_app_field() {
  case "$1:$2" in
    reader:spec)      echo "ArchiveReader/macOS/project.yml" ;;
    reader:proj)      echo "ArchiveReader/macOS/ArchiveReader.xcodeproj" ;;
    reader:scheme)    echo "ArchiveReader" ;;
    reader:tests)     echo "ArchiveReaderUITests" ;;
    reader:dd)        echo "$GUEST_HOME/dd-reader" ;;
    reader:appbundle) echo "$GUEST_HOME/dd-reader/Build/Products/Debug/ArchiveReader.app" ;;
    reader:procname)  echo "ArchiveReader" ;;
    reader:fixture)   echo "$GUEST_HOME/Library/Application Support/ArchiveReader/AR-GUI-Fixture" ;;
    reader:mkfixture) echo 'AR_FIXTURE_SRC="$GC" bash "$GR/ArchiveReader/scripts/make-gui-fixture.sh"' ;;
    reader:launcharg) echo "-ARUITestRootPath" ;;
    reader:prerun)    echo "" ;;

    notes:spec)       echo "ArchiveNotes/macOS/project.yml" ;;
    notes:proj)       echo "ArchiveNotes/macOS/ArchiveNotes.xcodeproj" ;;
    notes:scheme)     echo "ArchiveNotes" ;;
    notes:tests)      echo "ArchiveNotesUITests" ;;
    notes:dd)         echo "$GUEST_HOME/dd-notes" ;;
    notes:appbundle)  echo "$GUEST_HOME/dd-notes/Build/Products/Debug/ArchiveNotes.app" ;;
    notes:procname)   echo "ArchiveNotes" ;;
    notes:fixture)    echo "$GUEST_HOME/Library/Application Support/ArchiveNotes/AN-GUI-Fixture" ;;
    notes:mkfixture)  echo 'NOTES_FIXTURE_CORPUS="$GC" bash "$GR/ArchiveNotes/scripts/make-notes-fixture.sh"' ;;
    notes:launcharg)  echo "-ANUITestStorePath" ;;
    # Notes only: wipe the GUEST app container first. organization.json is loaded ONLY when the
    # container's index DB has no folders, so a container left from a previous run shadows the fixture's
    # folder graph and makes the folder-tree UITests (G7/G8) nondeterministic — the INDEX-DB CAVEAT in
    # make-notes-fixture.sh. This is the VM's throwaway container, never the owner's.
    notes:prerun)     echo 'rm -rf "$HOME/Library/Containers/com.archivenotes.app"' ;;

    # Processor has no test target of ANY kind yet (SUITE_TODO W21.vmgui-d), so it is deliberately absent:
    # an unknown app must be a loud error, not a silently-empty run.
    *) echo "" ;;
  esac
}

archive_app_known() { [ -n "$(archive_app_field "$1" scheme)" ]; }

# ---------------------------------------------------------------------------------------------------
# tart_wait_agent VM [SECONDS] — block until the Tart Guest Agent answers. 0 = ready, 1 = timed out.
# Sets $TART_AGENT_WAITED to the seconds spent.
#
# THE BUG THIS EXISTS FOR: `tart ip --wait` returns as soon as the guest has NETWORKING, but `tart exec`
# talks over a separate vsock control socket served by the guest agent, which comes up LATER. Calling
# `tart exec` right after the IP appears yields
#     "Failed to connect to the VM using its control socket … is the Tart Guest Agent running?"
# and — because callers tend to `|| true` their execs — every command in the run then no-ops silently.
# That is precisely how the health gate reported a green GUI lane that had run zero tests for two days.
# Never call `tart exec` after a boot without going through this first.
tart_wait_agent() {
  local vm="$1" limit="${2:-240}" waited=0
  TART_AGENT_WAITED=0
  until tart exec "$vm" true >/dev/null 2>&1; do
    if [ "$waited" -ge "$limit" ]; then TART_AGENT_WAITED="$waited"; return 1; fi
    sleep 5
    waited=$(( waited + 5 ))
  done
  TART_AGENT_WAITED="$waited"
  return 0
}

# ---------------------------------------------------------------------------------------------------
# tart_build_fixture VM MKFIXTURE [TAIL_LINES] — rebuild the GUI fixture inside the guest and report the
# GUEST COMMAND's own exit status, never `tart exec`'s.
#   returns 0 — the guest build exited 0
#           1 — the guest build exited non-zero (the code is in $TART_FIXTURE_RC)
#           2 — UNKNOWN: the status could not be read back. That is tart/agent trouble, and it is NOT
#               evidence of a failed build — the caller's fixture-presence probe is the real verdict.
# The tail of the guest's build output is left in $TART_FIXTURE_TAIL in all three cases.
#
# THE BUG THIS EXISTS FOR (SUITE_TODO W26.fixwarn; seen on 2 of the 4 VM runs of 2026-08-09/10). Both
# entry points used to infer the build's fate from `tart exec`'s exit status. tart's control channel fails
# INDEPENDENTLY of the command it carries — observed as `Error: StreamClosed(streamID: …
# HTTP2ErrorCode<0x5 Stream Closed>)` and `Error: internal error (13): transport: SendHeader called
# multiple times` — while the fixture built perfectly both times (right mtime, `IMG_PHOTO — Fixture.jpg`
# present, tagged, and discovered by the tests). So the lane cried *"fixture build reported a failure"*
# over a build that had just succeeded. That is worse than silence: `W26.walk1` de-silenced this step
# precisely so a REAL fixture failure could not hide, and a warning that fires on a healthy run trains the
# next session to read past the one signal it was added to give. It is INTERMITTENT, so a green run is not
# evidence that the transport behaved — which is why the fix is structural rather than a retry.
#
# The fix is to stop asking the transport a question only the guest can answer: the guest records its own
# `$?` to a file, and a second, tiny exec reads it back (a few bytes, not a build's worth of output).
# The RUN-UNIQUE token is load-bearing, not decoration — with a fixed path a previous run's status could
# be read as this one's, turning a cried-wolf warning into a silently-swallowed real failure, which is the
# strictly worse direction to fail in.
TART_FIXTURE_TMP="${TART_FIXTURE_TMP:-/tmp/archive-gui-fixture}"

tart_build_fixture() {
  local vm="$1" mk="$2" lines="${3:-5}" tok raw glog grc
  tok="fixrc-$$-$(date +%s)-${RANDOM:-0}"
  glog="$TART_FIXTURE_TMP/$tok.log"; grc="$TART_FIXTURE_TMP/$tok.rc"
  TART_FIXTURE_TAIL=""; TART_FIXTURE_RC=""
  # `|| true` on purpose: THIS exec's status is the exact thing we have learned not to trust.
  # $GR/$GC are assigned in the guest so the mkfixture strings (which keep them unexpanded) resolve there.
  # A SUBSHELL around $mk, not a brace group: a builder that ends in `exit N` would otherwise take the
  # guest shell down with it and the status line below would never be written — i.e. a real failure would
  # arrive as "unknown", which is the one classification that must stay reserved for transport trouble.
  tart exec "$vm" bash -lc "
    mkdir -p '$TART_FIXTURE_TMP'
    GR='$GUEST_REPO'; GC='$GUEST_CORPUS'
    ( $mk ) > '$glog' 2>&1
    echo '$tok' \$? > '$grc'
  " >/dev/null 2>&1 || true
  raw="$(tart exec "$vm" bash -lc "cat '$grc' 2>/dev/null" 2>/dev/null || true)"
  TART_FIXTURE_TAIL="$(tart exec "$vm" bash -lc "tail -n $lines '$glog' 2>/dev/null" 2>/dev/null || true)"
  tart exec "$vm" bash -lc "rm -f '$glog' '$grc'" >/dev/null 2>&1 || true
  # Only a line carrying THIS run's token counts; anything else is stale or truncated, i.e. unknown.
  case "$raw" in "$tok "*) TART_FIXTURE_RC="${raw#"$tok" }" ;; *) TART_FIXTURE_RC="" ;; esac
  case "$TART_FIXTURE_RC" in ''|*[!0-9]*) TART_FIXTURE_RC=""; return 2 ;; esac
  if [ "$TART_FIXTURE_RC" = 0 ]; then return 0; fi
  return 1
}

# ---------------------------------------------------------------------------------------------------
# tart_ensure_display VM — raise the guest's screen to $TART_VM_DISPLAY (default 1920x1200). Returns 0
# when the display now meets the target, 1 when it does not; either way the guest helper's own report is
# left in $TART_DISPLAY_NOTE so the caller can print what ACTUALLY took effect rather than what it asked
# for. Needs the guest agent (tart_wait_agent) first, like every other exec.
#
# THE BUG THIS EXISTS FOR (measured 2026-08-01, W21.vmgui-c). `tart run --no-graphics` attaches no
# display, so the guest's WindowServer boots at **1024×768** no matter what the VM's `Display` field says
# (`tart get` reported 1920x1200 while the guest ran 1024×768). The Notes browser shell needs ~1084 pt of
# width for tree+list+detail, so at 1024 it overflowed its window and ~92 pt was clipped off EACH side —
# the sidebar's Add button landed at x = −19, the editor's raw toggle at x = 1033 — and FOUR
# ArchiveNotesUITests failed as "not hittable" / "seam must be drivable". Those were tracked as product
# bugs for two days. The guest advertises modes up to 3840×2400; nobody had asked for one.
# Lives here, not in either script, for the reason at the top of this file.
tart_ensure_display() {
  local vm="$1" target="${TART_VM_DISPLAY:-1920x1200}" w h rc=0
  w="${target%%x*}"; h="${target##*x}"
  TART_DISPLAY_NOTE="$(tart exec "$vm" bash -lc \
    "swift '$GUEST_REPO/ops/gui/vm-set-display.swift' $w $h" 2>&1)" || rc=1
  return "$rc"
}

# ---------------------------------------------------------------------------------------------------
# tart_lock_acquire [WAIT_SECONDS] / tart_lock_release — one writer at a time for the shared VM.
#
# There is ONE VM name and ONE artifact dir, and both entry points (the health gate and the interactive
# runner) begin by `tart stop`-ing the VM and truncating $ART/gui-vm-<app>-attempt<n>.log. Two runs at
# once — the daemon's gate plus an agent or the owner, which this repo's own worktree/multi-agent doctrine
# makes routine — therefore kill each other's VM mid-xcodebuild and overwrite the very logs the pass/fail
# decision is read from. The loser sees neither TEST marker and reports "inconclusive", laundering away
# whatever it was about to find. mkdir is the atomic primitive here (no flock on stock macOS).
TART_LOCK_DIR="${TART_LOCK_DIR:-$HOME/.tart-mirror/.vm.lock}"
TART_LOCK_STALE="${TART_LOCK_STALE:-5400}"   # 90 min — longer than any legitimate full run

tart_lock_acquire() {
  local limit="${1:-0}" waited=0 age owner
  mkdir -p "$(dirname "$TART_LOCK_DIR")" 2>/dev/null || true
  while ! mkdir "$TART_LOCK_DIR" 2>/dev/null; do
    # Break a lock left behind by a killed run: either its pid is gone, or it is older than the stale bound.
    owner="$(cat "$TART_LOCK_DIR/pid" 2>/dev/null || echo '')"
    age=$(( $(date +%s) - $(stat -f %m "$TART_LOCK_DIR" 2>/dev/null || echo 0) ))
    if { [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; } || [ "$age" -gt "$TART_LOCK_STALE" ]; then
      rm -rf "$TART_LOCK_DIR" 2>/dev/null || true
      continue
    fi
    if [ "$waited" -ge "$limit" ]; then TART_LOCK_OWNER="${owner:-unknown}"; return 1; fi
    sleep 10; waited=$(( waited + 10 ))
  done
  echo $$ > "$TART_LOCK_DIR/pid" 2>/dev/null || true
  TART_LOCK_HELD=1
  return 0
}

tart_lock_release() {
  [ "${TART_LOCK_HELD:-0}" = 1 ] || return 0     # never release a lock we don't hold
  rm -rf "$TART_LOCK_DIR" 2>/dev/null || true
  TART_LOCK_HELD=0
  return 0
}

# ---------------------------------------------------------------------------------------------------
# archive_corpus_src ROOT — the host dir of real PDFs the fixture builders copy from, or "" if none.
#
# This corpus is GITIGNORED, so it exists only in the primary checkout — never in a worktree. Mounting it
# as its own `corpus:` share (instead of reaching for it under the repo mount) is what lets the VM lane run
# identically from either. The old `$GUEST_REPO/../fixture-src` guess resolved to an unmounted path, so the
# in-VM fixture build could never succeed — and `|| true` hid it.
archive_corpus_src() {
  local root="${1:-}" c
  for c in "$root/ArchiveProcessor/Test Files/DeaverLLM" \
           "$HOME/Claude/Archive Suite/ArchiveProcessor/Test Files/DeaverLLM" \
           "$HOME/.tart-mirror/fixture-src"; do
    if [ -d "$c" ]; then echo "$c"; return 0; fi
  done
  echo ""
  return 0
}
