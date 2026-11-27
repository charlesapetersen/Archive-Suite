#!/bin/bash
# The pre-app archive's adoption tool (W49.corpus-adoption-tool, owner call 31): one step per run, headless, in the
# Debug Processor (AdoptionCommand). Reads the source only and writes a separate derived archive. Contract and the
# meaning of each reason code: SPEC/adoption.md. The real corpus is refused until the owner approves a real run.
#
#   adopt-archive.sh inventory STATE SOURCE [ORIGINALS|none] [red-box-purple-folder|none]
#   adopt-archive.sh decide    STATE accept|skip|review REASON[,REASON...] [drop-original]
#   adopt-archive.sh convert   STATE DEST
#   adopt-archive.sh verify    STATE
#   adopt-archive.sh labels    STATE [apply] [raster-fallback]
#
# STATE is a folder outside both archives; it keeps the manifest, the ledger and each step's report.
# The labels step reads label photos with Vision on this Mac ($0), under the heavy lock.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
bin="$here/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
usage() { sed -n '6,10p' "$0" | sed 's/^# *//' >&2; exit 2; }
[ -x "$bin" ] || { echo "ArchiveProcessor is not built; run the documented Debug build first." >&2; exit 1; }
[ $# -ge 2 ] || usage
step="$1" state="$2"
shift 2
export ARCHIVEPROC_HEADLESS=1 ARCHIVE_ADOPT="$step" ARCHIVE_ADOPT_STATE="$state"
case "$step" in
    inventory)
        [ $# -ge 1 ] || usage
        export ARCHIVE_ADOPT_SOURCE="$1"
        [ $# -lt 2 ] || export ARCHIVE_ADOPT_ORIGINALS="$2"
        [ $# -lt 3 ] || export ARCHIVE_ADOPT_COLOURS="$3" ;;
    decide)
        [ $# -ge 2 ] || usage
        export ARCHIVE_ADOPT_DECISION="$1" ARCHIVE_ADOPT_REASONS="$2"
        [ "${3:-}" != drop-original ] || export ARCHIVE_ADOPT_KEEP_ORIGINAL=0 ;;
    convert)
        [ $# -ge 1 ] || usage
        export ARCHIVE_ADOPT_DEST="$1" ;;
    verify) ;;
    labels)
        for flag in "$@"; do
            case "$flag" in
                apply) export ARCHIVE_ADOPT_APPLY=1 ;;
                raster-fallback) export ARCHIVE_ADOPT_RASTER_FALLBACK=1 ;;
                *) usage ;;
            esac
        done
        exec python3 "$here/../ops/autonomous/heavy-run.py" run -- "$bin" ;;
    *) usage ;;
esac
exec "$bin"
