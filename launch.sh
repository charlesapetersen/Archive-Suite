#!/bin/bash
# launch.sh — Archive Suite dispatcher.
# Delegates to one app's own launch.sh (build-if-stale, relaunch-if-stale, then launch).
#
# Usage:  ./launch.sh reader        # Archive Reader
#         ./launch.sh processor     # Archive Processor
#         ./launch.sh notes         # Archive Notes
# Run from anywhere; it cd's to its own directory = repo root.
set -uo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
  reader|r|ArchiveReader)        dir="ArchiveReader" ;;
  processor|p|ArchiveProcessor)  dir="ArchiveProcessor" ;;
  notes|n|ArchiveNotes)          dir="ArchiveNotes" ;;
  *)
    echo "Archive Suite launcher"
    echo "Usage: ./launch.sh reader|processor|notes"
    echo "  reader     → Archive Reader    (find · read · triage)"
    echo "  processor  → Archive Processor (capture · OCR · tag)"
    echo "  notes      → Archive Notes     (write · link · extract)"
    exit 2 ;;
esac

if [ ! -x "./$dir/launch.sh" ]; then
  echo "✗ ./$dir/launch.sh not found or not executable."
  exit 1
fi
echo "→ Archive Suite: launching $dir …"
exec "./$dir/launch.sh"
