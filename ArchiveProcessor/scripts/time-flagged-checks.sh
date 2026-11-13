#!/bin/bash
# W46.seg-check-time — the owner's timing session: check the 92 gaps the app's Gemini route flags on Stanton and RG165
# on the app's own Check Flagged Boundaries sheet, while the Debug-only FlaggedCheckTimingTestDriver logs how long each
# takes. Interactive, on the owner's screen; about half an hour at the 20 s the settings sheet assumes. $0: no model
# call, no key, no network; nothing is written but the log below (no run, manifest, tag or output).
#
#   ArchiveProcessor/scripts/time-flagged-checks.sh           # build if stale, open the sheet, score when done
#
# Answer each gap as you would in a real run: does the right page start a new document (S = Split) or continue the
# left one (J = Join)? The sheet does not show the model's proposal. At your normal pace; Done when all are answered. Take a break by leaving the sheet as it is: a stay over 120 s on one gap is reported as a pause.
# Notes for the scoring session go in the notes file the script names. Cancel Run (Escape) stops with the log kept.
set -euo pipefail
cd "$(dirname "$0")/.."
here="$PWD"

if [ "${ARCHIVE_UNATTENDED:-}" = "1" ]; then
    echo "This is the owner's session: it draws on the screen. Not for an unattended run." >&2
    exit 1
fi

py="$HOME/Library/Caches/ArchiveSuiteRehearsal/torch-env/bin/python"
[ -x "$py" ] || py="$(bash scripts/segbench/torch-env.sh | tail -1)"
cache="$HOME/Library/Caches/ArchiveSuiteRehearsal/seg-check-time"
[ -f "$cache/pack.json" ] || "$py" scripts/segbench/check_time.py pack

bin="$here/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
# Build when the app is missing or older than any of its sources: on 2026-11-12 the primary checkout's app dated from
# 31 October, had no timing driver, and would have opened with no log (W46.seg-check-blind).
if [ ! -x "$bin" ] || [ -n "$(find macOS/Sources macOS/project.yml ../packages/ArchiveCore/Sources ../packages/ArchiveCore/Package.swift \
        -newer "$bin" -type f -print -quit 2>/dev/null)" ]; then
    echo "Building the Debug app (missing or older than its sources)..."
    (cd macOS && xcodegen generate >/dev/null && \
     xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/DD build -quiet)
fi

stamp=$(date +%Y%m%d-%H%M%S)
run="$cache/run-$stamp.json"
notes="$cache/notes-$stamp.txt"
: > "$notes"
echo "Opening the sheet. The log is $run"
echo "Notes for the scoring session (optional): $notes"
FLAGGED_CHECK_TIMING_PACK="$cache/pack.json" FLAGGED_CHECK_TIMING_OUT="$run" "$bin" >"$cache/app-$stamp.log" 2>&1 || true

if [ ! -f "$run" ]; then
    echo "No log was written; see $cache/app-$stamp.log" >&2
    exit 1
fi
if /usr/bin/python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("done") else 1)' "$run"; then
    "$py" scripts/segbench/check_time.py score "$run" --notes "$notes" --preview
    echo "That is a preview; an engine session writes the result. Add any notes to $notes, then hand the log back:"
    echo "  ops/autonomous/plan-edit.sh .maintenance/AUTONOMOUS_PLAN.md release W46.seg-check-time 'results in $run'"
else
    echo "Stopped before Done; the log so far is $run (run the script again for a full session)."
fi
