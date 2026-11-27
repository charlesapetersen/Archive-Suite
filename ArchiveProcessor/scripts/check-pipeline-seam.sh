#!/bin/bash
# W49.proc-unified-pipeline-1: everything a Process Files run does after its pages are read goes through
# OCRProcessor+PostOCRFinalizer.swift (`runPostOCRStages`, then `completeRun`). Fails, naming the line, when a production
# source calls one of those stages anywhere else, which is how the fresh, resumed, batch and pre-OCRed tails drifted
# apart (a resume never wrote the reviewed Classification line or the phone's Quality). The few callers that are
# stages themselves are listed below with the reason. Also fails when a route stops calling the shared functions.
# Test drivers and contracts (DEBUG-only, SegmentationProofDriver.swift too) call stages directly on purpose and are
# skipped. startProcessing's own recordLocalNameMentions is the rebuilt PDFs' (they bypass tagging), not a tail copy.
# Pure shell, $0, instant. Also run by scripts/test-tagging-failure.sh.
set -uo pipefail
cd "$(dirname "$0")/../macOS/Sources/ArchiveProcessor"
seam="OCR/OCRProcessor+PostOCRFinalizer.swift"
stages='runWindowSegmentationStage|applyBoxFolderLabelTags|copySourceTagsFromInputPDFs|recordLocalNameMentions|recordRunHistory|writeLogFile|showRotationReview|showFullSegmentationReview|showBoxFolderConfirmation|performAutomaticTaggingWithReview|performTaggingPhase|performManualSegmentAndTag|performManualTaggingPhase|performCollectionSegmentation|writeClassificationHeaders|applyCaptureQualityTags|exportOriginalImages|performDocumentMerging|finishCatalogueRun|materializeDeferredOutputs|recordContainerLabels|runDoneMessage|postCompletionNotification'
# file:enclosing function:stage — a stage that calls another stage, or a route that is not a run's tail.
allowed='
OCR/OCRProcessor+WindowSegmentation.swift:runWindowSegmentationStage:showBoxFolderConfirmation
OCR/OCRProcessor+WindowSegmentation.swift:runWindowSegmentationStage:showFullSegmentationReview
OCR/OCRProcessor+Tagging.swift:performAutomaticTaggingWithReview:performTaggingPhase
OCR/OCRProcessor+Tagging.swift:performManualSegmentAndTag:materializeDeferredOutputs
OCR/OCRProcessor+Pipeline.swift:retryOne:finishCatalogueRun
OCR/OCRProcessor+Pipeline.swift:startProcessing:recordLocalNameMentions
'
files=()
while IFS= read -r -d '' f; do files+=("${f#./}"); done < <(find . -name '*.swift' ! -name '*TestDriver.swift' \
    ! -name '*Contract.swift' ! -name 'SegmentationProofDriver.swift' ! -path "./$seam" -print0 | sort -z)
hits=$(awk -v stages="$stages" '
    FNR == 1 { fn = "" }
    # The enclosing member: a func at the type level (exactly four spaces in), not a local func inside a body
    # (the eight-space local restoredQualities inside startProcessing once read as the member holding its tail).
    /^    ([@A-Za-z][@A-Za-z ]*)?func [A-Za-z_]+/ { match($0, /func [A-Za-z_]+/); fn = substr($0, RSTART + 5, RLENGTH - 5) }
    /^[ \t]*(\/\/|\*|\/\*)/ { next }
    {
        line = $0
        sub(/[ \t]\/\/ .*$/, "", line)   # a trailing comment
        while (match(line, "(^|[^A-Za-z0-9_])(" stages ")\\(")) {
            call = substr(line, RSTART, RLENGTH); sub(/^[^A-Za-z]/, "", call); sub(/\($/, "", call)
            if (line !~ ("func " call "[(<]")) print FILENAME ":" fn ":" call ":" FNR
            line = substr(line, RSTART + RLENGTH)
        }
    }' "${files[@]}")
status=0
while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    key="${hit%:*}"
    grep -qxF "$key" <<<"$allowed" && continue
    echo "FAIL a post-OCR stage is called outside $seam (route it through runPostOCRStages/completeRun):"
    echo "  $hit"
    status=1
done <<<"$hits"
# Every route calls the shared functions: the stages, and (except the pre-OCRed stage, whose caller files it) the end.
body_of() { awk -v fn="$2" '/^    ([@A-Za-z][@A-Za-z ]*)?func [A-Za-z_]+/ { match($0, /func [A-Za-z_]+/); cur = substr($0, RSTART + 5, RLENGTH - 5) } cur == fn' "$1"; }
for route in "OCR/OCRProcessor+Pipeline.swift startProcessing completeRun" "OCR/OCRProcessor+Pipeline.swift resumeRun completeRun" \
             "OCR/OCRProcessor+Pipeline.swift resumeBatch completeRun" "OCR/OCRProcessor+OCR.swift performPreOCRedProcessing"; do
    read -r file fn end <<<"$route"
    body=$(body_of "$file" "$fn")
    for want in runPostOCRStages $end; do
        grep -qE "$want\(" <<<"$body" || { echo "FAIL $fn no longer calls $want"; status=1; }
    done
done
[ $status = 0 ] && echo "PASS every Process Files route ends through $seam"
exit $status
