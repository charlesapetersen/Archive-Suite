#!/bin/bash
# Key-free ($0) self-test of the local open-weight model route (W41.app-local-models): runs LocalModelsTestDriver headless.
# Every request goes to the app's no-wire seam (NetworkSession.testTransport); the driver checks the memory-based pick,
# the local request (token cap, temperature 0, stand-in key, timeout), the loop and reasoning guards, escalation of a
# looped page, one worker at a time and the $0 estimate, and (W41.app-local-models-fu1) the streamed reply, its loop stop and the second reading, and (fu2) the reasoning-off switch and the no-answer text reply; (W49.proc-local-model-supervisor) the supervisor's arbitration with a stand-in worker, and its seam lint; (W49.proc-managed-local-ocr, the `M` lines) the managed page readers' install, removal, Reader and reads through the app's client, and (W49.proc-managed-mac-image-calls) the date search and item-field image calls through it. No model call, no network, no Keychain read, no window, never
# the corpus.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox
set -euo pipefail
cd "$(dirname "$0")/.."

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
if [ ! -x "$bin" ]; then
    echo "ArchiveProcessor is not built; run the documented Debug build first." >&2
    exit 1
fi

work=$(mktemp -d)
source "$PWD/scripts/test-child.sh"
processor_test_init "$work"
report="$work/result.txt"
log="$work/app.log"
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    LOCALMODELS_TEST=1 LOCALMODELS_TEST_OUT="$report" \
    processor_test_start pid "$bin" >"$log" 2>&1

# The physical-Mac proofs (LOCALMODELS_SCRATCH_GEMMA_ROOT, LOCALMODELS_SCRATCH_OCR_ROOT, under the heavy lock) install and
# load real models: the OCR proof's fresh install fetches the runtime from the network.
limit=120
[ -n "${LOCALMODELS_SCRATCH_OCR_ROOT:-}" ] && limit=2400
for _ in $(seq 1 "$limit"); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Local-models test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report" || exit 1
"$PWD/scripts/check-local-model-seam.sh"
