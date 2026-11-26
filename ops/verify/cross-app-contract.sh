#!/usr/bin/env bash
# cross-app-contract.sh — W40.d11: a folder the Processor wrote must read in the Reader and Notes as written.
#
# USAGE:  ops/verify/cross-app-contract.sh <Processor output folder> [core|reader|notes ...]   (default: all three)
#         The folder is a Process Files run's output, e.g. the W40.d1 journey's
#         ~/.tart-mirror/vm-artifacts/processor/bulk-ocr/run-<n> (ArchiveProcessor/scripts/journey-bulk-ocr.sh).
# STEPS:  stage   the folder's Processor output (PDFs, JSON sidecars, Preservation/; not the journey driver's own
#                 .txt/.tsv bookkeeping) is copied with ditto, xattrs kept, to the rehearsal share:
#                 $REHEARSAL/processor-output/Archival Photos/<folder name>, and
#                 ops/verify/cross_app_contract.py writes what it holds, read without the suite's parsers, to
#                 $REHEARSAL/processor-output/expected.json.
#         core    ArchiveCore's parsers on the staged copy (ProcessorOutputContractTests, swift test, heavy lock).
#         reader  the real Reader in the Tart VM on a guest copy (READER_JOURNEY=processed, ContractJourneyUITests).
#         notes   a Notes source block from one of the PDFs, in the integration lane (NOTES_JOURNEY=integrations,
#                 IntegrationJourneyUITests/testD11_ProcessorOutputSourceBlock).
# ENV:    REHEARSAL_DIR (default ~/Library/Caches/ArchiveSuiteRehearsal), CONTRACT_FOLDER (the staged folder's
#         name; default "RG 165 — War Department"), ART_DIR (passed to the VM runner).
# EXIT:   0 = every step asked for passed · 1 = a step failed · 2 = usage.
# The staged copy is bench-cache scratch: the item that runs this deletes it when it is done (CLAUDE.md, "The
# bench cache"). Nothing here reads or writes the corpus; the folder given is already a copy.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${1:-}"; shift || true
[ -n "$SRC" ] && [ -d "$SRC" ] || { sed -n '2,20p' "$0"; exit 2; }
STEPS=("$@"); [ ${#STEPS[@]} -gt 0 ] || STEPS=(core reader notes)
REHEARSAL="${REHEARSAL_DIR:-$HOME/Library/Caches/ArchiveSuiteRehearsal}"
FOLDER="${CONTRACT_FOLDER:-RG 165 — War Department}"
STAGE="$REHEARSAL/processor-output"
shopt -s nocasematch
case "$SRC" in */Desktop/Google\ Drive*|*/Archival\ Photos*) echo "refusing a path that looks like the real corpus: $SRC" >&2; exit 2 ;; esac
shopt -u nocasematch
# The names reach guest shell strings (vm-gui-runner.sh): refuse the characters a shell would read.
unsafe() { case "$1" in *[\'\"\$\`\\]*) return 0 ;; *) return 1 ;; esac; }
unsafe "$FOLDER" && { echo "CONTRACT_FOLDER may not contain quotes, \$, a backtick or a backslash" >&2; exit 2; }

log() { printf '[d11] %s\n' "$*"; }

# --- stage ---------------------------------------------------------------------------------------------------
if [ -d "$STAGE" ]; then   # never rm -r a bench folder
  mv "$STAGE" "$HOME/.Trash/w40d11-processor-output-$(date +%s)" || { log "could not clear the old stage"; exit 1; }
fi
mkdir -p "$STAGE/Archival Photos/$FOLDER" || exit 1
while IFS= read -r -d '' f; do
  ditto "$f" "$STAGE/Archival Photos/$FOLDER/$(basename "$f")" || { log "copy failed: $f"; exit 1; }
done < <(find "$SRC" -mindepth 1 -maxdepth 1 ! -name '*.txt' ! -name '*.tsv' -print0)
printf '%s' "$FOLDER" > "$STAGE/folder.txt" || exit 1
DIR="$STAGE/Archival Photos/$FOLDER"
python3 "$ROOT/ops/verify/cross_app_contract.py" expect "$DIR" "$STAGE/expected.json" || { log "expectation FAILED"; exit 1; }
# The Notes source: the first dated Document Start with subjects, by name (deterministic for a given run).
python3 - "$STAGE/expected.json" > "$STAGE/notes-source.txt" <<'PY' || { log "no dated Document Start to make a source block from"; exit 1; }
import json, sys
files = json.load(open(sys.argv[1], encoding="utf-8"))["files"]
pick = [n for n, v in sorted(files.items()) if v["classification"] == "Document Start" and v["facets"]["day"]
        and len(v["facets"]["subjects"]) >= 2 and not any(c in n for c in "'\"$`\\")]
sys.stdout.write(pick[0]) if pick else sys.exit(1)
PY
log "staged $(find "$DIR" -maxdepth 1 -name '*.pdf' | wc -l | tr -d ' ') PDFs at $DIR"

COUNT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["count"])' "$STAGE/expected.json")"
ART="${ART_DIR:-$HOME/.tart-mirror/vm-artifacts}"
# A UITest that skipped leaves xcodebuild green, so a VM step passes only on its test's own "passed" line.
passed() { grep -aq "Test Case '-\[$1\]' passed" "$2" && ! grep -aq "Test Case '-\[$1\]' skipped" "$2"; }

rc=0
for step in "${STEPS[@]}"; do
  case "$step" in
    core)
      log "core: ArchiveCore's parsers on the staged copy…"
      out="$(cd "$ROOT/packages/ArchiveCore" && ARCHIVE_CONTRACT_DIR="$DIR" ARCHIVE_CONTRACT_EXPECTED="$STAGE/expected.json" \
        python3 "$ROOT/ops/autonomous/heavy-run.py" run -- swift test --filter ProcessorOutputContractTests 2>&1)"; src=$?
      printf '%s\n' "$out" | grep -E '\[d11\]|error:|Executed' | head -40
      # The test's own count line, for every staged file: a filter that matched nothing also "passes".
      if [ "$src" = 0 ] && printf '%s\n' "$out" | grep -q "\[d11\] ArchiveCore read $COUNT Processor PDFs as written"; then
        log "core: PASS"
      else log "core: FAIL"; rc=1; fi ;;
    reader)
      log "reader: the real Reader in the VM…"
      READER_JOURNEY=processed "$ROOT/ops/gui/vm-gui-runner.sh" reader xcuitest; vrc=$?
      if [ "$vrc" = 0 ] && passed "ArchiveReaderUITests.ContractJourneyUITests testProcessorOutputReadsAsWrittenInTheList" \
           "$ART/reader/xcuitest.log" && grep -aq "\[d11\] read $COUNT of $COUNT rows; 0 with a mismatch" "$ART/reader/xcuitest.log"; then
        log "reader: PASS"
      else log "reader: FAIL"; rc=1; fi ;;
    notes)
      log "notes: a source block from one of the PDFs, in the integration lane…"
      W40D11_NOTES=1 NOTES_JOURNEY=integrations ONLY_TESTING=ArchiveNotesUITests/IntegrationJourneyUITests/testD11_ProcessorOutputSourceBlock \
        "$ROOT/ops/gui/vm-gui-runner.sh" notes xcuitest; vrc=$?
      if [ "$vrc" = 0 ] && passed "ArchiveNotesUITests.IntegrationJourneyUITests testD11_ProcessorOutputSourceBlock" \
           "$ART/notes/xcuitest.log"; then
        log "notes: PASS"
      else log "notes: FAIL"; rc=1; fi ;;
    *) echo "unknown step: $step (core|reader|notes)" >&2; exit 2 ;;
  esac
done
exit "$rc"
