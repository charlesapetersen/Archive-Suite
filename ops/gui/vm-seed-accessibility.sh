#!/usr/bin/env bash
# vm-seed-accessibility.sh — repair the GUI VM's Accessibility grant so the xcuitest lane can see again.
#
# WHAT BROKE (2026-08-10, and what this exists to undo). Every XCUITest in BOTH apps started failing with
# "Main window should appear". The apps were fine — `CGWindowList` showed the Reader's navigation window at
# its usual 900×612 — but XCUITest drives the **accessibility tree**, and the guest had stopped serving it:
# `AXIsProcessTrusted()` was false and `kAXWindows` returned -25211 (`kAXErrorAPIDisabled`).
#
# Everything `tart exec` launches is attributed to the guest agent as its RESPONSIBLE process, so the lane
# borrows the agent's Accessibility grant. The grant row was still there and still read `auth_value = 2` —
# but TCC also stores the **code requirement** captured when the grant was made, and the installed binary
# no longer satisfies it:
#
#     Failed to match existing code requirement for subject …/tart-guest-agent
#         and service kTCCServiceAccessibility
#     AUTHREQ_RESULT: authValue=0, authReason=5
#
# The stored requirement pinned `cdhash H"2fbfa9cf…" or cdhash H"d52a3cc6…"` (the two slices of the fat
# binary as it was on 2026-07-28); the installed agent now hashes to `534ce9de…`. So the row says "allowed"
# and tccd ignores it — a failure mode with no symptom except that automation goes blind. This rewrites the
# requirement to match the binary that is actually installed.
#
# WHY IT IS SAFE TO DO THIS HERE, AND ONLY HERE. It writes the *guest's* TCC database — a throwaway Tart VM
# that exists to run GUI tests, boots from a Cirrus image, and ships with **SIP disabled** (checked below;
# the write is impossible otherwise). It never touches the host's TCC. The owner's own grants — the ones
# AGENTS.md §"GUI verification" describes — are a different machine and are not in scope.
#
# USAGE:  ops/gui/vm-seed-accessibility.sh [--check]
#   --check   report whether the grant is live and exit; change nothing.
# ENV: VM_NAME (default archive-gui-runner).
#
# Idempotent: if the probe already passes it does nothing. Backs the database up before every write.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/tart-lib.sh"

VM="${VM_NAME:-archive-gui-runner}"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

log()  { printf '\033[36m[vm-a11y]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[vm-a11y] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[vm-a11y] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# The binary path, the TCC path and the service list all live in the GUEST half
# (ops/gui/vm-seed-accessibility-guest.sh) — one definition, on the side of the boundary that uses them.
#
# Boot the VM ourselves when it is not already up, so this is genuinely one command. Only a VM we started
# gets stopped again on the way out — a VM the owner (or a mid-flight lane) already had running is left
# exactly as found. Same one-writer lock as both lanes, for the same reason: this stops and starts the VM.
BOOTED_BY_US=0
cleanup() {
  [ "$BOOTED_BY_US" = 1 ] && tart stop "$VM" >/dev/null 2>&1
  tart_lock_release
  return 0
}
trap cleanup EXIT
tart_lock_acquire "${LOCK_WAIT:-120}" \
  || die "the GUI VM is in use by another run (pid ${TART_LOCK_OWNER:-?}) — wait for it to finish"

if ! tart exec "$VM" true >/dev/null 2>&1; then
  log "booting '$VM' (headless)…"
  # --no-graphics: this never needs pixels, and it is the flag that keeps a VM window off the owner's
  # screen (ops/gui/README.md §3). The repo share is required — the probe is read from it.
  tart run "$VM" --no-graphics --dir=repo:"$(cd "$HERE/../.." && pwd)" >/dev/null 2>&1 &
  BOOTED_BY_US=1
fi

tart_wait_agent "$VM" "${AGENT_WAIT:-240}" \
  || die "guest agent never answered on '$VM' within ${AGENT_WAIT:-240}s"

# --- is the grant live? (the only question that matters; ask the API, never the database) ---
probe() {
  tart exec "$VM" bash -lc '
    swift "/Volumes/My Shared Files/repo/ops/gui/vm-check-accessibility.swift" 2>&1
  ' 2>&1
}

if probe | grep -q 'accessibility is live'; then
  log "accessibility already live in '$VM' — nothing to do"
  exit 0
fi
log "accessibility is NOT live in '$VM'"
[ "$CHECK_ONLY" = 1 ] && exit 1

# --- repair ---
log "re-seeding the guest agent's grant to match the installed binary…"
tart exec "$VM" bash -lc \
  'bash "/Volumes/My Shared Files/repo/ops/gui/vm-seed-accessibility-guest.sh"' \
  || die "the in-guest repair failed (see the output above)"

# --- verify by asking the API again, never by re-reading the database we just wrote ---
log "verifying…"
sleep 2
if probe | grep -q 'accessibility is live'; then
  log "accessibility is live in '$VM' — the xcuitest lane can see the UI again"
  exit 0
fi
die "still not live after re-seeding. A reboot of the guest (tart stop $VM; tart run $VM --no-graphics &)
     sometimes settles tccd; if it persists, the responsible-process attribution has changed and the
     grant subject needs to be re-identified from a fresh 'log show --predicate process == \"tccd\"'."
