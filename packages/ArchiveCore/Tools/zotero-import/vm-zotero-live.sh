#!/bin/bash
# Add to Zotero against a real Zotero, in the Tart GUI VM's scratch library (W47.ct-zotero-tags): boots the VM with
# this checkout shared, starts its Zotero (ArchiveNotes/scripts/vm-zotero.sh: a profile of its own with the local API
# on), copies ArchiveCore onto the guest disk and runs ZoteroExportTests/testLiveZoteroKeepsFieldsAndTags there with
# ARCHIVE_ZOTERO_LIVE=1. The test saves through ZoteroConnector and reads the items back through the local API.
# Never touches a Zotero on the host. Run it through the heavy lock:
#   python3 ops/autonomous/heavy-run.py run -- packages/ArchiveCore/Tools/zotero-import/vm-zotero-live.sh
# Prints the guest's test output; exit 0 when the test passed.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../../../.." && pwd)"
. "$REPO/ops/gui/tart-lib.sh"
VM="${VM:-archive-gui-runner}"
LOG="$(mktemp -t vm-zotero-live)"
tart_require
tart_lock_acquire "${LOCK_WAIT:-600}" || { echo "the GUI VM is in use by another run (pid ${TART_LOCK_OWNER:-?})" >&2; exit 1; }
booted=0
cleanup() {
  set +e
  [ "$booted" = 1 ] && { tart exec "$VM" bash "$GUEST_REPO/ArchiveNotes/scripts/vm-zotero.sh" stop; tart_stop_clean "$VM"; }
  tart_lock_release
  rm -f "$LOG"
}
trap cleanup EXIT
tart stop "$VM" >/dev/null 2>&1 || true
# --no-graphics: nothing is drawn on the host; --no-clipboard: the host's pasteboard stays out of the guest.
tart run "$VM" --no-graphics --no-clipboard --dir=repo:"$REPO":ro >"$LOG" 2>&1 &
booted=1
tart ip "$VM" --wait 120 >/dev/null || { cat "$LOG" >&2; exit 1; }
tart_wait_agent "$VM" 240 || { echo "the guest agent never answered" >&2; exit 1; }
tart exec "$VM" bash "$GUEST_REPO/ArchiveNotes/scripts/vm-zotero.sh" start
tart exec "$VM" bash -lc "defaults read \$HOME/Applications/Zotero.app/Contents/Info.plist CFBundleShortVersionString \
  | sed 's/^/guest Zotero /'"
tart exec "$VM" bash -lc "rm -rf /tmp/w47-live && ditto '$GUEST_REPO/packages/ArchiveCore' /tmp/w47-live \
  && rm -rf /tmp/w47-live/.build && cd /tmp/w47-live \
  && ARCHIVE_ZOTERO_LIVE=1 swift test --filter 'ZoteroExportTests/testLiveZoteroKeepsFieldsAndTags' 2>&1"
