#!/bin/bash
# journey-review-dialogs.sh — W40.d2: the Processor's review dialogs driven by hand, in the Tart VM (never on this
# Mac's screen), on six photos of a rehearsal box read by the stand-in CLI (scripts/fake_local_agent.py) — $0.
#
#   ./scripts/journey-review-dialogs.sh
#
# ReviewDialogsJourneyUITests presses Start in the real Process Files window and answers Review rotation, the
# per-page segmentation review, the box/folder confirmation and the final review (run A), then Segment & Tag with
# typed tags (run B), and reads every PDF and Finder tag back against the choices it made. Its `[w40d2]` lines and
# the screenshots land in ~/.tart-mirror/vm-artifacts/processor/ (xcuitest.log, shots/).
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(cd .. && pwd)"
COLLECTION="${W40D2_COLLECTION:-RG 165 — War Department}"
SET="${REHEARSAL_DIR:-$HOME/Library/Caches/ArchiveSuiteRehearsal}/processor-set/$COLLECTION"
[ -d "$SET" ] || { echo "no rehearsal box at $SET (python3 ArchiveProcessor/scripts/make-processor-rehearsal.py)"; exit 1; }
export PROCESSOR_JOURNEY=reviews W40D2_COLLECTION="$COLLECTION"
echo "route: the stand-in Local Agent CLI in the guest, six photos of $COLLECTION — \$0"
"$REPO/ops/gui/vm-gui-runner.sh" processor xcuitest
rc=$?
LOG="${ART_DIR:-$HOME/.tart-mirror/vm-artifacts}/processor/xcuitest.log"
[ -f "$LOG" ] && grep -E '^\[w40d2\]|error:|Executed ' "$LOG" | grep -v '^\[w40d2\] .*tree:$' | head -80
exit $rc
