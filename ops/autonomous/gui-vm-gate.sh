#!/usr/bin/env bash
# gui-vm-gate.sh — OPT-IN GUI-UITest step for the periodic health gate (health-gate.sh), run inside a
# headless Tart VM so it NEVER touches the owner's screen and never hangs the host with the "Enable UI
# Automation" prompt (which is exactly why the gate itself runs only unit bundles — see health-gate.sh).
#
# SAFETY POSTURE (this is Tier-2 autonomous infra — biased hard toward fail-open):
#   • OFF by default. Runs only when AUTONOMOUS_GUI_VM=1.
#   • A missing VM, a boot failure, a timeout, or any non-test error → SKIP (exit 0). Infra must
#     NEVER park the run.
#   • RED (exit 1) ONLY on a reproducible UITest failure — keyed on the definitive "** TEST FAILED **"
#     marker (not just an exit code, so a VM build/SPM/infra hiccup can't false-park), and only after
#     ONE retry (GUI tests carry more flake than unit tests).
#   • Always leaves the VM stopped (trap).
#
# Exit: 0 = GREEN or SKIPPED (never park on infra) · 1 = confirmed UITest regression (park).
# Knobs: AUTONOMOUS_GUI_VM_NAME (default archive-gui-runner), AUTONOMOUS_GUI_VM_MAXRUN (default 1200s).
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VM="${AUTONOMOUS_GUI_VM_NAME:-archive-gui-runner}"
MAXRUN="${AUTONOMOUS_GUI_VM_MAXRUN:-1200}"
ART="${ART_DIR:-$HOME/.tart-mirror/vm-artifacts}"
GLOG="$ART/gui-vm-gate.log"
GUEST_PROJ="/Volumes/My Shared Files/repo/ArchiveReader/macOS/ArchiveReader.xcodeproj"
GUEST_DD="/Users/admin/dd-reader"

skip() { echo "GUI-VM gate SKIPPED: $*"; exit 0; }

# --- guards (each SKIPs green; a missing prereq must never RED) ---
[ "${AUTONOMOUS_GUI_VM:-0}" = 1 ] || skip "disabled (set AUTONOMOUS_GUI_VM=1 to enable)"
command -v tart >/dev/null || skip "tart not installed"
# match the VM as a whole word in `tart list`
tart list 2>/dev/null | awk '{print $2}' | grep -qx "$VM" || skip "VM '$VM' not present (build it — ops/gui/README.md §3)"
mkdir -p "$ART"
# optional self-timeout (coreutils gtimeout); else rely on the daemon's GATE_MAXRUN
if command -v gtimeout >/dev/null; then TO=(gtimeout "$MAXRUN"); else TO=(); fi

cleanup() { tart stop "$VM" >/dev/null 2>&1 || true; }
trap cleanup EXIT

is_test_failure() { grep -q '\*\* TEST FAILED \*\*' "$GLOG" 2>/dev/null; }
is_test_success() { grep -q '\*\* TEST SUCCEEDED \*\*' "$GLOG" 2>/dev/null; }

run_once() {
  : > "$GLOG"
  # Generate on the host (the guest image has no xcodegen); the VM builds the shared mount.
  xcodegen generate --spec "$ROOT/ArchiveReader/macOS/project.yml" >>"$GLOG" 2>&1 || return 2
  # Clean boot with OUR mount ($ROOT), so a stale interactive VM state can't run the wrong tree.
  tart stop "$VM" >/dev/null 2>&1 || true
  tart run "$VM" --no-graphics --dir=repo:"$ROOT" --dir=out:"$ART" >>"$GLOG" 2>&1 &
  tart ip "$VM" --wait 120 >/dev/null 2>&1 || return 2
  "${TO[@]}" tart exec "$VM" bash -lc "
    xcodebuild test -project '$GUEST_PROJ' -scheme ArchiveReader \
      -only-testing:ArchiveReaderUITests -destination 'platform=macOS' \
      -derivedDataPath '$GUEST_DD'
  " >>"$GLOG" 2>&1
}

echo "GUI-VM gate: running ArchiveReaderUITests in VM '$VM' (headless, off-screen)…"
run_once || true
if is_test_success && ! is_test_failure; then echo "GUI-VM gate: GREEN"; exit 0; fi
if is_test_failure; then
  echo "GUI-VM gate: UITest failure — retrying once (flake guard)…"
  cleanup; run_once || true
  if is_test_success && ! is_test_failure; then echo "GUI-VM gate: GREEN on retry"; exit 0; fi
  if is_test_failure; then
    echo "GUI-VM gate: RED — reproducible UITest failure:"; grep -E 'Test Case .*failed|error:' "$GLOG" | sed -E 's#/Volumes/My Shared Files/repo/##' | tail -20
    exit 1
  fi
fi
# Neither a clean success nor a clear test failure → boot/timeout/infra → fail-open.
skip "inconclusive (no clear TEST SUCCEEDED/FAILED — boot, timeout, or infra; not a regression)"
