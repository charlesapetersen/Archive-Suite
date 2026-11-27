import Foundation
import CryptoKit
import ArchiveCore

/// W49.proc-unified-pipeline-1 — everything a run does after its pages are read, in one place.
///
/// A fresh Process Files run (`startProcessing`), a resumed run (`resumeRun`), a resumed paid batch (`resumeBatch`) and
/// the pre-OCRed PDF route (`performPreOCRedProcessing`) each used to carry their own copy of this tail: reviews,
/// segmentation, tagging, collection segmentation, the late header and quality writes, the dual-output images, merge,
/// and then the filing and the run summary. The copies drifted (a resume never wrote the reviewed `Classification:`
/// line or the phone's Quality, and the pre-OCRed resume's summary dropped every warning). Now each route describes
/// what differs in a `PostOCRPlan` and calls `runPostOCRStages`, then `completeRun`.
/// `scripts/check-pipeline-seam.sh` fails a production call of these stages anywhere else.
extension OCRProcessor {
    /// The stages after OCR, through merge and the temporary-file cleanup. Returns false when the run stopped (Stop,
    /// a declined monthly read, a refused stage); the caller then returns without filing.
    func runPostOCRStages(_ plan: PostOCRPlan) async -> Bool {
        let files = plan.files
        let runConfig = plan.runConfig
        let mode = lateRunOutputSettings(for: runConfig).taggingMode
        let tagging = plan.enableTagging && !passSourceTags
        let preOCRed = plan.origin == .preOCRed
        func stop() -> Bool { cleanupTempFiles(); return false }

        // Dedicated rotation review (opt-in) — a fast, standalone pass, separate from and BEFORE the
        // segmentation/tagging review, and run in EVERY tagging mode. It bakes the corrected rotation into each
        // output PDF; the exported JPG then picks up the same value.
        if plan.reviewRotation {
            await showRotationReview(files: files, runConfig: runConfig)
            guard !Task.isCancelled else { return stop() }
        }

        // Segmentation: pre-grouped from Live Capture, else the window segmenter and its review, else the per-page
        // review (W36.seg-opt-review: `SegmentationPlan`). Every route, a resume included, shows the reviews that
        // apply: Resume skips only the whole-run review the user turned off (owner call 30,
        // W40.fix-processor-resume-reviews). A window approach reuses the answers a resumed manifest kept.
        let segPlan = segmentationPlan(tagging: mode, runConfig: runConfig)
        let preGrouped = plan.phoneGroupsApply && preGroupedBoundaries.count == files.count && !files.isEmpty
        if preGrouped {
            // Groups were defined on the phone — apply them directly, skip LLM segmentation.
            applyPreGroupedClassifications(files: files)
            rebuildSegments(files: files)
        } else if case .windows(let approach) = segPlan {
            guard await runWindowSegmentationStage(files: files, approach: approach,
                                                   runConfig: runConfig, outputDirectory: plan.outputDirectory,
                                                   settings: plan.settings,
                                                   reviewWholeRun: plan.reviewWholeRun) == .done else {
                return stop()
            }
        } else if case .manualWindow = segPlan {
            // Manual modes: the combined segment+tag window owns rotation, box/folder, and segmentation, so
            // skip the separate review here (it rebuilds segments itself).
        } else if tagging || plan.enableCollectionSegmentation {
            if plan.reviewWholeRun || segPlan == .noTagging {
                await showFullSegmentationReview(files: files, runConfig: runConfig)
                guard !Task.isCancelled else { return stop() }
                if !enclosureCoverChoices.isEmpty {
                    guard persistWindowSegmentationProgress(covers: enclosureCoverChoices) else { return stop() }
                }
            }
            // Final confirmation of box/folder identifications
            await showBoxFolderConfirmation(files: files, runConfig: runConfig)
            guard !Task.isCancelled else { return stop() }
            // Rebuild segments from user-confirmed classifications (excluding removed files)
            rebuildSegments(files: files)
        }
        guard !Task.isCancelled else { return stop() }

        if monthlySpend == nil, activePendingBatch?.usesWindowSegmentation == true {
            retirePaidBatchJournalIfPollCompleted()
        }

        // W49.proc-unified-pipeline-2 — the reviews above settled each page's rotation and class: write the outputs
        // held back since OCR, each once, before tagging writes their tags. Segment & Tag settles both in its own
        // window and writes them there.
        let combinedWindow = tagging && (mode == .autoDate || mode == .human)
            && segPlan.combinedWindow(tagging: mode, preGrouped: preGrouped) != nil
        if !combinedWindow {
            await materializeDeferredOutputs()
            guard !Task.isCancelled else { return stop() }
        }

        // Tagging (mode-dependent). The text backend is the run's separately selected LLM in a Vision hybrid and is
        // never passed to an image-OCR function.
        if tagging {
            let text = plan.text
            statusMessage = "Found \(segments.count) segments. Tagging…"
            switch mode {
            case .automatic:
                await performAutomaticTaggingWithReview(
                    provider: text.provider, model: text.model, thinkingLevel: text.thinkingLevel,
                    apiKey: text.apiKey, outputDirectory: plan.outputDirectory,
                    enableSegmentJSON: plan.enableSegmentJSON, files: files, runConfig: runConfig)
            case .autoDate, .human:
                if let autoDate = segPlan.combinedWindow(tagging: mode, preGrouped: preGrouped) {
                    await performManualSegmentAndTag(
                        autoDate: autoDate,
                        provider: text.provider, model: text.model, thinkingLevel: text.thinkingLevel,
                        apiKey: text.apiKey, outputDirectory: plan.outputDirectory,
                        enableSegmentJSON: plan.enableSegmentJSON, preOCRed: preOCRed, files: files,
                        runConfig: runConfig)
                } else {
                    // The window segmenter (or Live Capture) segmented: the user tags each document.
                    await performManualTaggingPhase(
                        mode: mode, provider: text.provider, model: text.model,
                        thinkingLevel: text.thinkingLevel, apiKey: text.apiKey,
                        outputDirectory: plan.outputDirectory, enableSegmentJSON: plan.enableSegmentJSON,
                        runConfig: runConfig)
                }
            case .none, .copySource:
                break
            }
            guard !Task.isCancelled else { return stop() }
        } else if passSourceTags && preOCRed {
            copySourceTagsFromInputPDFs(files)
        }

        guard !Task.isCancelled, !stopIfMonthlyReadDeclined() else { return stop() }
        // Anything Segment & Tag did not reach (it returns early with nothing to show).
        await materializeDeferredOutputs()
        guard !Task.isCancelled else { return stop() }

        // Collection segmentation + name review (after the tagging review, the last step before completion).
        // Collection identification is another text-only LLM path; keep Vision on the OCR side.
        if plan.enableCollectionSegmentation {
            await performCollectionSegmentation(
                files: files,
                provider: plan.text.provider, model: plan.text.model, thinkingLevel: plan.text.thinkingLevel,
                apiKey: plan.text.apiKey, outputDirectory: plan.outputDirectory,
                confirmBeforeOrganizing: plan.confirmCollectionIDs,
                runConfig: runConfig)
            applyBoxFolderLabelTags(enableTagging: plan.enableTagging, runConfig: runConfig)
        }

        // An input PDF keeps its own pages, text layer and images: none of the generated-output writes below apply.
        if preOCRed { return !Task.isCancelled }

        guard !Task.isCancelled, !stopIfMonthlyReadDeclined() else { return stop() }

        // Page 2's Classification: every review is done, and merge copies these pages next
        // (W40.fix-processor-review-classification-stale).
        await writeClassificationHeaders(runConfig: runConfig)
        guard !Task.isCancelled else { return stop() }

        // Live Capture: layer per-page phone Quality on top now that box/folder Red/Purple is final, and before merge
        // folds appliedTags into merged PDFs. The companion wire already carries only canonical Q tokens, with an
        // omitted field for Unrated.
        applyCaptureQualityTags(runConfig: runConfig)

        // Dual output: write each original image next to its PDF (same base + tags), before merge repoints
        // outputURLMap and before organization moves files. No-op unless the run exports originals.
        await exportOriginalImages(runConfig: runConfig)

        let mergeDocuments = lateRunOutputSettings(for: runConfig).mergeDocuments
        await recordLocalNameMentions(runConfig: runConfig, mode: mode, merging: mergeDocuments ? files : nil)
        guard !Task.isCancelled else { return stop() }

        // Merge multi-page documents (before collection organization moves files).
        if mergeDocuments {
            await performDocumentMerging(files: files, outputDirectory: plan.outputDirectory, runConfig: runConfig)
        }
        guard !Task.isCancelled else { return false }

        cleanupTempFiles()
        return true
    }

    /// File the run (`finishCatalogueRun`), read its container labels, and say how it went. The one end of every
    /// Process Files route.
    func completeRun(_ c: RunCompletion) async {
        guard let organizedMoves = await finishCatalogueRun(organizing: c.enableCollectionSegmentation,
                                                            preOCRed: c.preOCRed,
                                                            exportingImages: c.exportingImages,
                                                            stampsUnread: c.stampsUnread) else { return }
        let containerProblem = await recordContainerLabels(   // W47.ct-processor-capture
            moves: organizedMoves, outputDirectory: c.outputDirectory, preOCRedInput: c.preOCRed)
        guard !Task.isCancelled else { return }
        if c.clearsPendingRun {
            activePendingRun = nil
            pendingRunInfo = nil
        }
        writeLogFile(outputDirectory: c.outputDirectory)
        isProcessing = false
        progress = 1.0   // fill the bar on completion (later phases don't drive the 0.7→1.0 band)
        let succeeded = jobs.filter { $0.status == .succeeded }.count
        recordRunHistory(succeeded: succeeded)
        statusMessage = runDoneMessage(succeeded: succeeded, failed: failedFiles.count)
        // W23.m5 / W23.h5-fu — say so when a written output went out untagged, or with a placeholder instead of the
        // scan. Both are silent failures otherwise: the file is there and looks processed, but tag search will not
        // find it / the scan is missing.
        statusMessage += Self.outputWarningSuffix(untagged: untaggedOutputs, placeholders: placeholderOutputs)
        statusMessage += treeFallbackSuffix   // W47.ct-processor-intake
        statusMessage += catalogueFilingWarning
        if let note = containerLabelSpendNote { statusMessage += " " + note }   // W47.ct-label-cost
        if let containerProblem { statusMessage += " ⚠️ " + containerProblem }
        if c.incrementalSkipped > 0 {
            statusMessage += " \(c.incrementalSkipped) already-processed skipped."
        }
        if c.enableTagging && !passSourceTags {
            statusMessage += Self.taggedSegmentsSuffix(segments: segments.count, failures: taggingFailureNames)
            if let checks = segmentationCheckSummary { statusMessage += " \(checks)."; segmentationCheckSummary = nil }
        }
        if passSourceTags {
            statusMessage += " Source tags copied."
        }
        if c.enableCollectionSegmentation && !collectionSegments.isEmpty {
            statusMessage += " \(collectionSegments.count) collections organized."
        }
        postCompletionNotification()
    }

    // MARK: - The one output write (W49.proc-unified-pipeline-2)

#if DEBUG
    /// Test hook called in `writeHeldOutputs` right before the generation match check (S-056).
    nonisolated(unsafe) static var deferredWritePassHook: (@MainActor (OCRProcessor) -> Void)?
#endif

    /// Write every output held back since OCR (`handleOCRResult`), once, with the page's settled rotation and class
    /// (its job's current reading), then the last tags a review aimed at it. Called after the reviews and before
    /// tagging; a no-op when nothing is held. A stopped run leaves the rest unwritten: their readings are in the
    /// journal, and its resume holds them back again.
    func materializeDeferredOutputs() async {
        defersOutputWrites = false
        // A Retry that lands during a pass is held again (`handleOCRResult`), so pass until nothing new is held.
        var passes = 0
        while !deferredOutputs.isEmpty, !Task.isCancelled, passes < 3 {
            passes += 1
            await writeHeldOutputs()
        }
        guard !Task.isCancelled else { return }
        // Backstop: an output still held now is never written, so nothing may point at it and its job must fail (S-056).
        let stillHeld = deferredOutputs
        deferredOutputs = [:]
        for (url, held) in stillHeld where outputURLMap[held.request.source] == url
            && !FileManager.default.fileExists(atPath: url.path) {
            let jobIndex = jobs.firstIndex { $0.sourceURL == held.request.source && outputURLMap[$0.sourceURL] == url }
            recordOutputWrite(OutputWriteOutcome(success: false), request: held.request, jobIndex: jobIndex)
        }
    }

    /// One pass of `materializeDeferredOutputs`.
    private func writeHeldOutputs() async {
        // In job order, each still mapped from its own source.
        var work: [(output: URL, jobID: OCRJob.ID)] = []
        for job in jobs where job.status != .removed {
            guard let output = outputURLMap[job.sourceURL], deferredOutputs[output]?.request.source == job.sourceURL
            else { continue }
            work.append((output, job.id))
        }
        // A held output no job maps any more (a page removed in a review) is never written.
        let wanted = Set(work.map(\.output))
        for url in deferredOutputs.keys where !wanted.contains(url) { deferredOutputs[url] = nil }
        guard !work.isEmpty else { return }
        statusMessage = "Writing \(work.count) PDF\(work.count == 1 ? "" : "s")…"
        // Taken as each write starts, not before the first. The reading is the one held (a review rebuilds some
        // fields it does not keep), with the rotation and class the reviews settled.
        func request(_ w: (output: URL, jobID: OCRJob.ID)) -> (OutputWriteRequest, UUID)? {
            guard let held = deferredOutputs[w.output], let job = jobs.first(where: { $0.id == w.jobID }),
                  job.status != .removed, outputURLMap[job.sourceURL] == w.output else { return nil }
            var request = held.request
            if let current = job.result {
                request.result = request.result.with(classification: current.classification,
                                                     rotationDegrees: current.rotationDegrees)
            }
            return (request, held.generation)
        }
        // A few at a time, as the OCR workers wrote them: each page's layer and compression are CPU-bound.
        let lanes = max(1, min(3, ProcessInfo.processInfo.activeProcessorCount / 2))
        await withTaskGroup(of: (OutputWriteRequest, UUID, OutputWriteOutcome).self) { group in
            var next = 0
            var running = 0
            while true {
                while running < lanes, next < work.count, !Task.isCancelled {
                    let w = work[next]
                    next += 1
                    guard let (r, generation) = request(w) else { continue }
                    group.addTask {
                        (r, generation, await PDFGenerator.runWorker(priority: .utility) { Self.writeOutput(r) })
                    }
                    running += 1
                }
                guard running > 0, let (request, generation, written) = await group.next() else { break }
                running -= 1
                // Stopped mid-write: nothing is recorded, and the reading stays in the journal for the resume.
                if Task.isCancelled && !written.success { continue }
#if DEBUG
                Self.deferredWritePassHook?(self)
#endif
                // A newer reading was held meanwhile: the next pass writes it over this one.
                guard deferredOutputs[request.outputURL]?.generation == generation else { continue }
                let jobIndex = jobs.firstIndex { $0.sourceURL == request.source && outputURLMap[$0.sourceURL] == request.outputURL }
                // Clears the held entry and puts on the tags a review held for it.
                recordOutputWrite(written, request: request, jobIndex: jobIndex)
                deferredOutputs[request.outputURL] = nil   // a failed write is not tried again
            }
        }
    }

    /// A review turned a page whose output is held back: journal the turned reading now, so a Stop before the write
    /// and the resume after it (which shows no rotation review) still write the page as the user turned it.
    func journalHeldRotation(at index: Int) {
        guard jobs.indices.contains(index), let rotation = jobs[index].result?.rotationDegrees, activePendingRun != nil,
              let output = outputURLMap[jobs[index].sourceURL], let held = deferredOutputs[output]?.request.result
        else { return }
        // The held reading with only its rotation changed: a review rebuilds some fields it does not keep.
        var turned = held.with(classification: held.classification, rotationDegrees: rotation)
        turned.rotationUnsure = jobs[index].result?.rotationUnsure   // the user turned it: settled
        deferredOutputs[output]?.request.result = turned
        _ = saveResultToPendingRun(index: index, result: turned, outputURL: output)
    }

    // MARK: - Tagging progress (W49.proc-resume-tagging-progress, absorbed here)

    /// What identifies one segment's tagging answers: its pages, their text and kind, the neighbours' text its calls
    /// read (`context`: the tagging call's nearby segments and the dating route's neighbours) and the backend that
    /// answered. A resume whose segment differs in any of these asks again.
    nonisolated static func taggingProgressKey(segment: DocumentSegment, context: [String],
                                               provider: LLMProvider, model: LLMModel) -> String {
        var parts = ["v1", provider.rawValue, model.id, segment.isBox ? "box" : segment.isFolder ? "folder" : "doc"]
        parts += segment.pdfURLs.map { $0.standardizedFileURL.path }
        parts.append(segment.combinedText)
        parts.append("context")
        parts += context
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
