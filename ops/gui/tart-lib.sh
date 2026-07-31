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
