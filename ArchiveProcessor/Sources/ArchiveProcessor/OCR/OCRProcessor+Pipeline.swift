import Foundation
import UserNotifications

extension OCRProcessor {
    private static var pendingBatchURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("ArchiveProcessor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending_batch.json")
    }
    static func savePendingBatch(_ batch: PendingBatch) {
        guard let data = try? JSONEncoder().encode(batch) else { return }
        try? data.write(to: pendingBatchURL)
    }
    private static func loadPendingBatch() -> PendingBatch? {
        guard let data = try? Data(contentsOf: pendingBatchURL) else { return nil }
        return try? JSONDecoder().decode(PendingBatch.self, from: data)
    }
    static func deletePendingBatch() {
        try? FileManager.default.removeItem(at: pendingBatchURL)
    }
    /// File URLs from a pending batch (for populating the file list on resume).
    var pendingBatchFileURLs: [URL]? {
        Self.loadPendingBatch()?.fileURLs
    }
    private static var pendingRunURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("ArchiveProcessor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending_run.json")
    }
    private static func savePendingRun(_ run: PendingRun) {
        guard let data = try? JSONEncoder().encode(run) else { return }
        try? data.write(to: pendingRunURL)
    }
    private static func loadPendingRun() -> PendingRun? {
        guard let data = try? Data(contentsOf: pendingRunURL) else { return nil }
        return try? JSONDecoder().decode(PendingRun.self, from: data)
    }
    private static func deletePendingRun() {
        try? FileManager.default.removeItem(at: pendingRunURL)
    }
    /// Save a completed OCR result to the pending run on disk.
    func saveResultToPendingRun(index: Int, result: OCRResult) {
        guard var run = activePendingRun else { return }
        run.completedResults["\(index)"] = result
        activePendingRun = run
        Self.savePendingRun(run)
    }
    /// File URLs from a pending run (for populating the file list on resume).
    var pendingRunFileURLs: [URL]? {
        Self.loadPendingRun()?.fileURLs
    }
    /// Check for persisted pending batch or run on launch.
    func checkForPendingBatch() {
        // Check for pending batch
        if let pending = Self.loadPendingBatch() {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let dateStr = formatter.string(from: pending.submittedAt)
            pendingBatchInfo = "Pending batch from \(dateStr): \(pending.fileURLs.count) files via \(pending.provider.rawValue) \(pending.model.displayName)."
        } else {
            pendingBatchInfo = nil
        }

        // Check for pending run
        if let pending = Self.loadPendingRun() {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let dateStr = formatter.string(from: pending.startedAt)
            let completed = pending.completedResults.count
            let total = pending.fileURLs.count
            pendingRunInfo = "Interrupted run from \(dateStr): \(completed)/\(total) files completed via \(pending.provider.rawValue) \(pending.model.displayName)."
        } else {
            pendingRunInfo = nil
        }
    }
    /// Dismiss a pending batch notification (deletes local state only — server-side batch continues).
    func dismissPendingBatch() {
        Self.deletePendingBatch()
        pendingBatchInfo = nil
    }
    /// Dismiss a pending run notification.
    func dismissPendingRun() {
        Self.deletePendingRun()
        pendingRunInfo = nil
    }
    /// Resume polling a previously submitted batch.
    func resumeBatch(apiKey: String) async {
        guard let pending = Self.loadPendingBatch() else { return }

        isProcessing = true
        pendingBatchInfo = nil
        failedFiles = []
        segments = []
        collectionSegments = []
        outputURLMap = [:]
        currentModel = pending.model
        taggingMode = pending.taggingMode   // restore the mode used at submit (may differ from the live default after relaunch)
        jobs = pending.fileURLs.map { OCRJob(sourceURL: $0) }
        for i in jobs.indices { jobs[i].status = .processing }
        progress = 0
        statusMessage = "Resuming batch…"

        activeBatch = BatchContext(
            batchId: pending.batchId, apiKey: apiKey,
            model: pending.model, thinkingLevel: pending.thinkingLevel,
            provider: pending.provider
        )

        await pollBatchUntilComplete(
            batchId: pending.batchId, provider: pending.provider,
            model: pending.model, thinkingLevel: pending.thinkingLevel,
            apiKey: apiKey, fileURLs: pending.fileURLs,
            outputDirectory: pending.outputDirectory
        )

        // A transient interruption (network streak / timeout) leaves the batch resumable — don't delete
        // the pending batch or continue into tagging/finalize on incomplete results; let the user Resume.
        if batchPollInterrupted { activeBatch = nil; return }
        Self.deletePendingBatch()
        activeBatch = nil

        guard !Task.isCancelled else { return }

        await retryHighUseFailures(
            fileURLs: pending.fileURLs, provider: pending.provider,
            model: pending.model, thinkingLevel: pending.thinkingLevel,
            apiKey: apiKey, outputDirectory: pending.outputDirectory
        )

        guard !Task.isCancelled else { return }

        await retryLoopForFailedFiles(
            imageURLs: pending.fileURLs,
            outputDirectory: pending.outputDirectory
        )

        guard !Task.isCancelled else { return }

        // Tagging (before collection segmentation, matching main workflow order).
        // Switch on the persisted taggingMode so a batch submitted in Human / Auto-date / manual-seg
        // mode isn't silently downgraded to automatic tagging after a relaunch (and .none/.copySource
        // correctly skip LLM tagging).
        if pending.enableTagging && !passSourceTags {
            statusMessage = "Segmenting documents…"
            let segmenter = DocumentSegmenter()
            let classifications = jobs.map { $0.result?.classification }
            let texts = jobs.map { $0.result?.text ?? "" }
            segments = segmenter.segment(files: pending.fileURLs, classifications: classifications, texts: texts)
            statusMessage = "Found \(segments.count) segments. Generating tags…"

            switch pending.taggingMode {
            case .automatic:
                await performTaggingPhase(
                    provider: pending.provider, model: pending.model,
                    thinkingLevel: pending.thinkingLevel, apiKey: apiKey,
                    outputDirectory: pending.outputDirectory,
                    enableSegmentJSON: pending.enableSegmentJSON
                )
            case .autoDate:
                await performManualTaggingPhase(
                    mode: pending.taggingMode, provider: pending.provider, model: pending.model,
                    thinkingLevel: pending.thinkingLevel, apiKey: apiKey,
                    outputDirectory: pending.outputDirectory, enableSegmentJSON: pending.enableSegmentJSON
                )
            case .human, .autoDateManualSeg:
                await performManualSegmentAndTag(
                    autoDate: pending.taggingMode.autoFillsDate,
                    provider: pending.provider, model: pending.model, thinkingLevel: pending.thinkingLevel,
                    apiKey: apiKey, outputDirectory: pending.outputDirectory,
                    enableSegmentJSON: pending.enableSegmentJSON, preOCRed: false, files: pending.fileURLs
                )
            case .none, .copySource:
                break
            }
        }

        guard !Task.isCancelled else { return }

        // Collection segmentation (after tagging)
        if pending.enableCollectionSegmentation {
            await performCollectionSegmentation(
                files: pending.fileURLs,
                provider: pending.provider,
                model: pending.model,
                thinkingLevel: pending.thinkingLevel,
                apiKey: apiKey,
                outputDirectory: pending.outputDirectory,
                confirmBeforeOrganizing: pending.confirmCollectionIDs,
                reviewDocumentSegmentation: pending.reviewDocumentSegmentation
            )

            applyBoxFolderLabelTags(enableTagging: pending.enableTagging)
        }

        guard !Task.isCancelled else { return }

        if mergeDocuments {
            performDocumentMerging(files: pending.fileURLs, outputDirectory: pending.outputDirectory)
        }

        // Organize into collection folders (after merge so merged PDFs get moved)
        if pending.enableCollectionSegmentation && !collectionSegments.isEmpty {
            let segmenter = CollectionSegmenter()
            statusMessage = "Organizing \(collectionSegments.count) collections into folders…"
            do {
                try segmenter.organizeOutput(
                    collections: collectionSegments,
                    outputDirectory: pending.outputDirectory,
                    outputURLMap: outputURLMap,
                    moveSiblingImages: exportOriginals
                )
                statusMessage = "Collections organized into \(collectionSegments.count) folders."
            } catch {
                statusMessage = "Error organizing collections: \(error.localizedDescription)"
            }
        }

        guard !Task.isCancelled else { return }
        writeLogFile(outputDirectory: pending.outputDirectory)
        isProcessing = false
        progress = 1.0
        let succeeded = jobs.filter { $0.status == .succeeded }.count
        statusMessage = "Done. \(succeeded) succeeded, \(failedFiles.count) failed."
        if pending.enableTagging && !passSourceTags {
            statusMessage += " \(segments.count) segments tagged."
        }
        if passSourceTags {
            statusMessage += " Source tags copied."
        }
        if pending.enableCollectionSegmentation && !collectionSegments.isEmpty {
            statusMessage += " \(collectionSegments.count) collections organized."
        }
        postCompletionNotification()
    }
    /// Resume an interrupted non-batch run.
    func resumeRun(apiKey: String) async {
        guard let pending = Self.loadPendingRun() else { return }

        isProcessing = true
        pendingRunInfo = nil
        failedFiles = []
        segments = []
        collectionSegments = []
        outputURLMap = [:]
        pdfToImageMap = [:]
        currentModel = pending.model
        currentGateway = pending.gatewayConfig
        // Restore the run-time knobs the OCR call reads (startProcessing sets these; resume must too,
        // or OCR falls back to the default Local Vision rotation — which stalls the parallel workers).
        Self.rotationModeForRun = rotationMode
        Self.loadStandardImageMB()
        removedSourceURLs = []
        jobs = pending.fileURLs.map { OCRJob(sourceURL: $0) }
        progress = 0

        // Restore the pending run tracker for incremental saves
        activePendingRun = pending

        let segmentationContext = SegmentationContext(
            previousTextCharCount: pending.previousTextCharCount,
            sendPreviousImage: pending.sendPreviousImage,
            customPrompt: pending.customPrompt
        )

        // Convert any PDF inputs
        let imageURLs = convertPDFInputs(pending.fileURLs)

        // Restore already-completed results. The original run already wrote these PDFs, so reuse
        // them when present and only regenerate genuinely-missing ones — off the main actor, since
        // embedding full-resolution images is heavy (this was causing a beachball on resume).
        let completedCount = pending.completedResults.count
        if completedCount > 0 {
            statusMessage = "Restoring \(completedCount) previously completed results…"
            let fm = FileManager.default
            // Gather on the main actor.
            var restores: [(index: Int, result: OCRResult, sourceURL: URL, outputURL: URL)] = []
            var toGenerate: [(imageURL: URL, outputURL: URL, fileName: String, result: OCRResult)] = []
            // Iterate in job-index order and disambiguate colliding base names deterministically, so a
            // resumed batch reproduces the same unique output paths and never overwrites a sibling whose
            // source shares its base filename (e.g. two 00001.jpg from different boxes).
            var takenOutputs = Set(outputURLMap.values.map { $0.standardizedFileURL.path.lowercased() })
            for (key, result) in pending.completedResults.sorted(by: { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }) {
                guard let index = Int(key), index < jobs.count, index < imageURLs.count else { continue }
                let sourceURL = jobs[index].sourceURL
                let baseName = sourceURL.deletingPathExtension().lastPathComponent
                var outputURL = pending.outputDirectory.appendingPathComponent(baseName + ".pdf")
                var n = 2
                while takenOutputs.contains(outputURL.standardizedFileURL.path.lowercased()) {
                    outputURL = pending.outputDirectory.appendingPathComponent("\(baseName) (\(n)).pdf"); n += 1
                }
                takenOutputs.insert(outputURL.standardizedFileURL.path.lowercased())
                restores.append((index, result, sourceURL, outputURL))
                if !fm.fileExists(atPath: outputURL.path) {
                    toGenerate.append((imageURLs[index], outputURL, sourceURL.lastPathComponent, result))
                }
            }
            // Regenerate only missing PDFs, off the main thread.
            if !toGenerate.isEmpty {
                let model = pending.model
                let gatewayName = currentGateway?.displayName
                let pdfMB = Self.pdfImageMB
                statusMessage = "Rebuilding \(toGenerate.count) missing PDF\(toGenerate.count == 1 ? "" : "s")…"
                await Task.detached(priority: .utility) {
                    let gen = PDFGenerator()
                    for g in toGenerate {
                        try? gen.generate(imageURL: g.imageURL, result: g.result, model: model,
                                          outputURL: g.outputURL, originalFileName: g.fileName,
                                          gatewayDisplayName: gatewayName, pdfImageMB: pdfMB)
                    }
                }.value
            }
            // Apply the (cheap) state updates back on the main actor.
            for r in restores {
                jobs[r.index].result = r.result
                jobs[r.index].classification = r.result.classification
                jobs[r.index].status = r.result.text != nil ? .succeeded : .failed
                if r.result.text == nil { failedFiles.append(r.sourceURL.lastPathComponent) }
                outputURLMap[r.sourceURL] = r.outputURL
                if passSourceTags {
                    let sourceTags = MacOSTagger.readTags(from: r.sourceURL)
                    if !sourceTags.isEmpty {
                        try? MacOSTagger.applyTags(sourceTags, to: r.outputURL)
                        jobs[r.index].appliedTags = sourceTags
                    }
                }
            }
            let total = pending.fileURLs.count
            progress = Double(completedCount) / Double(total) * 0.7
            statusMessage = "Restored \(completedCount)/\(total). Resuming OCR…"
        }

        // Run OCR only on files that were NOT already completed
        let remainingIndices = (0..<pending.fileURLs.count).filter {
            pending.completedResults["\($0)"] == nil
        }

        if !remainingIndices.isEmpty {
            if pending.preOCRedInput {
                // For pre-OCRed, run the full pipeline (it's text extraction + classification, cheap)
                await performPreOCRedProcessing(
                    files: pending.fileURLs,
                    provider: pending.provider,
                    model: pending.model,
                    thinkingLevel: pending.thinkingLevel,
                    apiKey: apiKey,
                    outputDirectory: pending.outputDirectory,
                    enableTagging: pending.enableTagging,
                    enableSegmentJSON: pending.enableSegmentJSON,
                    enableCollectionSegmentation: pending.enableCollectionSegmentation,
                    confirmCollectionIDs: pending.confirmCollectionIDs,
                    reviewDocumentSegmentation: pending.reviewDocumentSegmentation,
                    customPrompt: pending.customPrompt
                )
                // Pre-OCRed path handles its own post-processing; skip to finalization
                activePendingRun = nil
                Self.deletePendingRun()
                pendingRunInfo = nil
                guard !Task.isCancelled else { return }
                writeLogFile(outputDirectory: pending.outputDirectory)
                isProcessing = false
                progress = 1.0
                let succeeded = jobs.filter { $0.status == .succeeded }.count
                statusMessage = "Done. \(succeeded) succeeded, \(failedFiles.count) failed."
                postCompletionNotification()
                return
            }

            // Resume OCR for remaining files
            await performOCRPhaseForIndices(
                indices: remainingIndices,
                fileURLs: imageURLs,
                provider: pending.provider,
                model: pending.model,
                thinkingLevel: pending.thinkingLevel,
                apiKey: apiKey,
                outputDirectory: pending.outputDirectory,
                segmentationContext: segmentationContext,
                totalFiles: pending.fileURLs.count,
                alreadyCompleted: completedCount
            )
        }

        guard !Task.isCancelled else { cleanupTempFiles(); return }

        // Retry high-use failures
        await retryHighUseFailures(
            fileURLs: imageURLs,
            provider: pending.provider,
            model: pending.model,
            thinkingLevel: pending.thinkingLevel,
            apiKey: apiKey,
            outputDirectory: pending.outputDirectory
        )

        guard !Task.isCancelled else { cleanupTempFiles(); return }

        // Interactive retry
        await retryLoopForFailedFiles(
            imageURLs: imageURLs,
            outputDirectory: pending.outputDirectory
        )

        guard !Task.isCancelled else { cleanupTempFiles(); return }

        // Tagging (mode-dependent), matching the main workflow — not always automatic.
        if pending.enableTagging && !passSourceTags {
            statusMessage = "Segmenting documents…"
            let segmenter = DocumentSegmenter()
            let classifications = jobs.map { $0.result?.classification }
            let texts = jobs.map { $0.result?.text ?? "" }
            segments = segmenter.segment(files: pending.fileURLs, classifications: classifications, texts: texts)
            statusMessage = "Found \(segments.count) segments. Tagging…"

            switch taggingMode {
            case .automatic:
                await performAutomaticTaggingWithReview(
                    provider: pending.provider, model: pending.model, thinkingLevel: pending.thinkingLevel,
                    apiKey: apiKey, outputDirectory: pending.outputDirectory,
                    enableSegmentJSON: pending.enableSegmentJSON, files: pending.fileURLs
                )
            case .autoDate:
                await performManualTaggingPhase(
                    mode: taggingMode, provider: pending.provider, model: pending.model,
                    thinkingLevel: pending.thinkingLevel, apiKey: apiKey,
                    outputDirectory: pending.outputDirectory, enableSegmentJSON: pending.enableSegmentJSON
                )
            case .human, .autoDateManualSeg:
                await performManualSegmentAndTag(
                    autoDate: taggingMode.autoFillsDate,
                    provider: pending.provider, model: pending.model, thinkingLevel: pending.thinkingLevel,
                    apiKey: apiKey, outputDirectory: pending.outputDirectory,
                    enableSegmentJSON: pending.enableSegmentJSON,
                    preOCRed: pending.preOCRedInput, files: pending.fileURLs
                )
            case .none, .copySource:
                break
            }
        }

        guard !Task.isCancelled else { cleanupTempFiles(); return }

        // Collection segmentation (after tagging)
        if pending.enableCollectionSegmentation {
            await performCollectionSegmentation(
                files: pending.fileURLs,
                provider: pending.provider,
                model: pending.model,
                thinkingLevel: pending.thinkingLevel,
                apiKey: apiKey,
                outputDirectory: pending.outputDirectory,
                confirmBeforeOrganizing: pending.confirmCollectionIDs,
                reviewDocumentSegmentation: pending.reviewDocumentSegmentation
            )

            applyBoxFolderLabelTags(enableTagging: pending.enableTagging)
        }

        guard !Task.isCancelled else { cleanupTempFiles(); return }

        if mergeDocuments {
            performDocumentMerging(files: pending.fileURLs, outputDirectory: pending.outputDirectory)
        }

        // Organize into collection folders (after merge so merged PDFs get moved)
        if pending.enableCollectionSegmentation && !collectionSegments.isEmpty {
            let segmenter = CollectionSegmenter()
            statusMessage = "Organizing \(collectionSegments.count) collections into folders…"
            do {
                try segmenter.organizeOutput(
                    collections: collectionSegments,
                    outputDirectory: pending.outputDirectory,
                    outputURLMap: outputURLMap,
                    moveSiblingImages: exportOriginals
                )
                statusMessage = "Collections organized into \(collectionSegments.count) folders."
            } catch {
                statusMessage = "Error organizing collections: \(error.localizedDescription)"
            }
        }

        cleanupTempFiles()

        guard !Task.isCancelled else { return }

        activePendingRun = nil
        Self.deletePendingRun()
        pendingRunInfo = nil

        writeLogFile(outputDirectory: pending.outputDirectory)
        isProcessing = false
        progress = 1.0
        let succeeded = jobs.filter { $0.status == .succeeded }.count
        statusMessage = "Done. \(succeeded) succeeded, \(failedFiles.count) failed."
        if pending.enableTagging && !passSourceTags {
            statusMessage += " \(segments.count) segments tagged."
        }
        if passSourceTags {
            statusMessage += " Source tags copied."
        }
        if pending.enableCollectionSegmentation && !collectionSegments.isEmpty {
            statusMessage += " \(collectionSegments.count) collections organized."
        }
        postCompletionNotification()
    }
    /// OCR only specific file indices (for resuming interrupted runs).
    private func performOCRPhaseForIndices(
        indices: [Int],
        fileURLs: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        segmentationContext: SegmentationContext,
        totalFiles: Int,
        alreadyCompleted: Int
    ) async {
        let remaining = indices.count
        let gateway = currentGateway

        if segmentationContext.previousTextCharCount == 0 {
            // Parallel: OCR only the remaining indices
            var completed = 0
            let concurrency = max(1, Self.ocrWorkerCount)
            for i in indices { jobs[i].status = .processing }
            statusMessage = "OCR 0/\(remaining) remaining… (parallel)"

            await withTaskGroup(of: (Int, OCRResult).self) { group in
                var nextSlot = 0

                for _ in 0..<min(concurrency, remaining) {
                    let index = indices[nextSlot]
                    let url = fileURLs[index]
                    let prevImageURL = (segmentationContext.sendPreviousImage && index > 0) ? fileURLs[index - 1] : nil
                    nextSlot += 1
                    let scale = segmentationContext.imageScale
                    group.addTask {
                        let result = await Self.performOCRCall(
                            imageURL: url, provider: provider, model: model,
                            thinkingLevel: thinkingLevel, apiKey: apiKey,
                            previousText: nil, previousImageURL: prevImageURL,
                            customPrompt: segmentationContext.customPrompt,
                            imageScale: scale,
                            gatewayConfig: gateway
                        )
                        return (index, result)
                    }
                }

                for await (index, result) in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    handleOCRResult(result, index: index, url: fileURLs[index], model: model, outputDirectory: outputDirectory)
                    completed += 1
                    progress = Double(alreadyCompleted + completed) / Double(totalFiles) * 0.7
                    statusMessage = "OCR \(alreadyCompleted + completed)/\(totalFiles) complete (parallel)" + Self.rateLimitSuffix

                    if nextSlot < remaining {
                        let idx = indices[nextSlot]
                        let url = fileURLs[idx]
                        let prevImageURL = (segmentationContext.sendPreviousImage && idx > 0) ? fileURLs[idx - 1] : nil
                        nextSlot += 1
                        let scale = segmentationContext.imageScale
                        group.addTask {
                            let result = await Self.performOCRCall(
                                imageURL: url, provider: provider, model: model,
                                thinkingLevel: thinkingLevel, apiKey: apiKey,
                                previousText: nil, previousImageURL: prevImageURL,
                                customPrompt: segmentationContext.customPrompt,
                                imageScale: scale,
                                gatewayConfig: gateway
                            )
                            return (idx, result)
                        }
                    }
                }
            }
        } else {
            // Sequential: OCR remaining indices, using previous results for context
            for (attempt, index) in indices.enumerated() {
                guard !Task.isCancelled else { return }
                let url = fileURLs[index]
                jobs[index].status = .processing

                let previousText: String?
                if index > 0, let prevResult = jobs[index - 1].result, segmentationContext.previousTextCharCount > 0 {
                    previousText = prevResult.text.flatMap { String($0.suffix(segmentationContext.previousTextCharCount)) }
                } else {
                    previousText = nil
                }
                let contextImageURL = segmentationContext.sendPreviousImage && index > 0 ? fileURLs[index - 1] : nil

                statusMessage = "OCR \(alreadyCompleted + attempt + 1)/\(totalFiles)…" + Self.rateLimitSuffix
                var result = await Self.performOCRCall(
                    imageURL: url, provider: provider, model: model,
                    thinkingLevel: thinkingLevel, apiKey: apiKey,
                    previousText: previousText, previousImageURL: contextImageURL,
                    customPrompt: segmentationContext.customPrompt,
                    imageScale: segmentationContext.imageScale,
                    gatewayConfig: gateway
                )

                if Self.isTimeoutError(result) {
                    statusMessage = "OCR \(alreadyCompleted + attempt + 1)/\(totalFiles)… retrying after timeout"
                    result = await Self.performOCRCall(
                        imageURL: url, provider: provider, model: model,
                        thinkingLevel: thinkingLevel, apiKey: apiKey,
                        previousText: nil, previousImageURL: nil,
                        customPrompt: segmentationContext.customPrompt,
                        imageScale: segmentationContext.imageScale,
                        gatewayConfig: gateway
                    )
                }

                handleOCRResult(result, index: index, url: url, model: model, outputDirectory: outputDirectory)
                progress = Double(alreadyCompleted + attempt + 1) / Double(totalFiles) * 0.7
                statusMessage = "OCR \(alreadyCompleted + attempt + 1)/\(totalFiles) complete"
            }
        }
    }
    func cancel() {
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        awaitingFinalReview = false
        awaitingDocumentReview = false
        awaitingCollectionConfirmation = false
        awaitingRetryDecision = false
        documentReviewContinuation?.resume()
        documentReviewContinuation = nil
        finalReviewContinuation?.resume(returning: .complete)
        finalReviewContinuation = nil
        collectionConfirmationContinuation?.resume()
        collectionConfirmationContinuation = nil
        retryContinuation?.resume(returning: .continueWithout)
        retryContinuation = nil
        // Manual segmentation/tagging + box-folder review continuations (so escaping those dialogs
        // aborts cleanly without leaking a continuation or leaving the review window open).
        awaitingManualTagging = false
        manualTaggingContinuation?.resume()
        manualTaggingContinuation = nil
        awaitingManualSegTag = false
        manualSegTaggingRange = nil
        manualSegContinuation?.resume()
        manualSegContinuation = nil
        awaitingBoxFolderConfirmation = false
        boxFolderConfirmContinuation?.resume()
        boxFolderConfirmContinuation = nil
        cleanupTempFiles()

        // Cancel server-side batch if active
        if let batch = activeBatch {
            activeBatch = nil
            Self.deletePendingBatch()
            Task {
                switch batch.provider {
                case .anthropic:
                    let client = AnthropicBatchClient(apiKey: batch.apiKey, model: batch.model, thinkingLevel: batch.thinkingLevel)
                    await client.cancelBatch(batchId: batch.batchId)
                case .mistral:
                    let client = MistralBatchClient(apiKey: batch.apiKey, model: batch.model)
                    await client.cancelBatch(batchId: batch.batchId)
                case .gemini:
                    let client = GeminiBatchClient(apiKey: batch.apiKey, model: batch.model, thinkingLevel: batch.thinkingLevel)
                    for singleId in batch.batchId.components(separatedBy: ",") {
                        await client.cancelBatch(batchName: singleId)
                    }
                }
            }
        }

        // If a non-batch run was active, keep the pending run file for resume
        if activePendingRun != nil {
            activePendingRun = nil
            // Refresh the pending run info banner
            checkForPendingBatch()
        }

        let succeeded = jobs.filter { $0.status == .succeeded }.count
        let pending = jobs.filter { $0.status == .processing || $0.status == .pending }.count
        statusMessage = "Cancelled. \(succeeded) succeeded, \(failedFiles.count) failed, \(pending) skipped."
        // Mark any still-processing jobs as failed
        for i in jobs.indices where jobs[i].status == .processing {
            jobs[i].status = .failed
        }
    }
    func startProcessing(
        files: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        batchMode: Bool,
        enableTagging: Bool,
        enableSegmentJSON: Bool = true,
        enableCollectionSegmentation: Bool = false,
        confirmCollectionIDs: Bool = false,
        reviewDocumentSegmentation: Bool = false,
        preOCRedInput: Bool = false,
        segmentationContext: SegmentationContext,
        gatewayConfig: GatewayConfig? = nil
    ) async {
        guard !files.isEmpty else { return }
        isProcessing = true
        failedFiles = []
        segments = []
        collectionSegments = []
        outputURLMap = [:]
        pdfToImageMap = [:]
        removedSourceURLs = []
        Self.rotationModeForRun = rotationMode
        Self.loadStandardImageMB()
        currentModel = model
        currentGateway = gatewayConfig
        jobs = files.map { OCRJob(sourceURL: $0) }
        progress = 0

        if preOCRedInput {
            // --- Pre-OCRed PDF path: extract text, classify, skip PDF generation ---
            await performPreOCRedProcessing(
                files: files,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                outputDirectory: outputDirectory,
                enableTagging: enableTagging,
                enableSegmentJSON: enableSegmentJSON,
                enableCollectionSegmentation: enableCollectionSegmentation,
                confirmCollectionIDs: confirmCollectionIDs,
                reviewDocumentSegmentation: reviewDocumentSegmentation,
                customPrompt: segmentationContext.customPrompt
            )
        } else {
            // --- Standard image OCR path ---
            statusMessage = "Starting OCR…"

            // Convert any PDF inputs to temporary JPEG images
            let imageURLs = convertPDFInputs(files)

            // Phase 1: OCR + Classification
            if batchMode && provider.supportsBatch {
                await performBatchOCR(
                    fileURLs: imageURLs,
                    provider: provider,
                    model: model,
                    thinkingLevel: thinkingLevel,
                    apiKey: apiKey,
                    outputDirectory: outputDirectory,
                    sendPreviousImage: segmentationContext.sendPreviousImage,
                    enableTagging: enableTagging,
                    enableCollectionSegmentation: enableCollectionSegmentation,
                    enableSegmentJSON: enableSegmentJSON,
                    confirmCollectionIDs: confirmCollectionIDs,
                    reviewDocumentSegmentation: reviewDocumentSegmentation,
                    customPrompt: segmentationContext.customPrompt,
                    imageScale: segmentationContext.imageScale
                )
                // Transient interruption during batch polling: the batch is preserved (resumable) and
                // no file was falsely failed. Stop cleanly rather than tagging/finalizing partial results;
                // reset isProcessing so the UI isn't stuck, and let the user Resume pending batch.
                if batchPollInterrupted { isProcessing = false; return }
            } else {
                // Create pending run for resume-after-restart
                activePendingRun = PendingRun(
                    provider: provider, model: model, thinkingLevel: thinkingLevel,
                    fileURLs: files, outputDirectory: outputDirectory,
                    enableTagging: enableTagging, enableSegmentJSON: enableSegmentJSON,
                    enableCollectionSegmentation: enableCollectionSegmentation,
                    confirmCollectionIDs: confirmCollectionIDs,
                    reviewDocumentSegmentation: reviewDocumentSegmentation,
                    preOCRedInput: false,
                    previousTextCharCount: segmentationContext.previousTextCharCount,
                    sendPreviousImage: segmentationContext.sendPreviousImage,
                    customPrompt: segmentationContext.customPrompt,
                    startedAt: Date(), gatewayConfig: gatewayConfig,
                    completedResults: [:]
                )
                Self.savePendingRun(activePendingRun!)

                await performOCRPhase(
                    fileURLs: imageURLs,
                    provider: provider,
                    model: model,
                    thinkingLevel: thinkingLevel,
                    apiKey: apiKey,
                    outputDirectory: outputDirectory,
                    segmentationContext: segmentationContext
                )
            }

            guard !Task.isCancelled else { cleanupTempFiles(); return }

            // Phase 1b: Retry files that failed due to high use
            await retryHighUseFailures(
                fileURLs: imageURLs,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                outputDirectory: outputDirectory
            )

            guard !Task.isCancelled else { cleanupTempFiles(); return }

            // Phase 1c: Prompt user to retry remaining failures with different provider/model
            await retryLoopForFailedFiles(
                imageURLs: imageURLs,
                outputDirectory: outputDirectory
            )

            guard !Task.isCancelled else { cleanupTempFiles(); return }

            // Dedicated rotation review (opt-in) — a fast, standalone pass, separate from and BEFORE
            // the segmentation/tagging review, and run in EVERY tagging mode. It bakes the corrected
            // rotation into each output PDF; the exported JPG then picks up the same value.
            if reviewRotation && rotationMode != .off {
                await showRotationReview(files: files)
                guard !Task.isCancelled else { cleanupTempFiles(); return }
            }

            // Segmentation: pre-grouped from Live Capture, else the interactive LLM review.
            if preGroupedBoundaries.count == files.count && !files.isEmpty {
                // Groups were defined on the phone — apply them directly, skip LLM segmentation.
                applyPreGroupedClassifications(files: files)
                rebuildSegments(files: files)
            } else if taggingMode.usesManualSegmentationUI {
                // Manual modes: the combined segment+tag window owns rotation, box/folder, and
                // segmentation, so skip the separate review here (it rebuilds segments itself).
            } else if (enableTagging && !passSourceTags) || enableCollectionSegmentation {
                await showFullSegmentationReview(files: files)
                guard !Task.isCancelled else { cleanupTempFiles(); return }

                // Final confirmation of box/folder identifications
                await showBoxFolderConfirmation(files: files)
                guard !Task.isCancelled else { cleanupTempFiles(); return }

                // Rebuild segments from user-confirmed classifications (excluding removed files)
                rebuildSegments(files: files)
            }

            guard !Task.isCancelled else { cleanupTempFiles(); return }

            // Phase 2: Tagging (mode-dependent)
            if enableTagging && !passSourceTags {
                switch taggingMode {
                case .automatic:
                    await performAutomaticTaggingWithReview(
                        provider: provider, model: model, thinkingLevel: thinkingLevel,
                        apiKey: apiKey, outputDirectory: outputDirectory,
                        enableSegmentJSON: enableSegmentJSON, files: files
                    )
                case .autoDate:
                    await performManualTaggingPhase(
                        mode: taggingMode, provider: provider, model: model,
                        thinkingLevel: thinkingLevel, apiKey: apiKey,
                        outputDirectory: outputDirectory, enableSegmentJSON: enableSegmentJSON
                    )
                case .human, .autoDateManualSeg:
                    await performManualSegmentAndTag(
                        autoDate: taggingMode.autoFillsDate,
                        provider: provider, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey,
                        outputDirectory: outputDirectory,
                        enableSegmentJSON: enableSegmentJSON, preOCRed: false, files: files
                    )
                case .none, .copySource:
                    break
                }
                guard !Task.isCancelled else { cleanupTempFiles(); return }
            }

            guard !Task.isCancelled else { cleanupTempFiles(); return }

            // Phase 3: Collection Segmentation + name review (after tagging review, last step before completion)
            if enableCollectionSegmentation {
                await performCollectionSegmentation(
                    files: files,
                    provider: provider,
                    model: model,
                    thinkingLevel: thinkingLevel,
                    apiKey: apiKey,
                    outputDirectory: outputDirectory,
                    confirmBeforeOrganizing: confirmCollectionIDs,
                    reviewDocumentSegmentation: false
                )

                applyBoxFolderLabelTags(enableTagging: enableTagging)
            }

            guard !Task.isCancelled else { cleanupTempFiles(); return }

            // Live Capture: layer per-page phone priority on top now that box/folder Red/Purple is
            // final, and before merge folds appliedTags into merged PDFs.
            applyCapturePriorityTags()

            // Live Capture dual output: write each original image next to its PDF (same base + tags),
            // before merge repoints outputURLMap and before organization moves files.
            await exportOriginalImages()

            // Phase 4: Merge multi-page documents (before collection organization moves files)
            if mergeDocuments {
                performDocumentMerging(files: files, outputDirectory: outputDirectory)
            }

            // Phase 5: Organize into collection folders (after merge so merged PDFs get moved)
            if enableCollectionSegmentation && !collectionSegments.isEmpty {
                let segmenter2 = CollectionSegmenter()
                statusMessage = "Organizing \(collectionSegments.count) collections into folders…"
                do {
                    try segmenter2.organizeOutput(
                        collections: collectionSegments,
                        outputDirectory: outputDirectory,
                        outputURLMap: outputURLMap,
                        moveSiblingImages: exportOriginals
                    )
                    statusMessage = "Collections organized into \(collectionSegments.count) folders."
                } catch {
                    statusMessage = "Error organizing collections: \(error.localizedDescription)"
                }
            }

            cleanupTempFiles()
        }

        guard !Task.isCancelled else { return }

        // Clear pending run on successful completion
        activePendingRun = nil
        Self.deletePendingRun()
        pendingRunInfo = nil

        writeLogFile(outputDirectory: outputDirectory)
        isProcessing = false
        progress = 1.0   // fill the bar on completion (later phases don't drive the 0.7→1.0 band)
        let succeeded = jobs.filter { $0.status == .succeeded }.count
        statusMessage = "Done. \(succeeded) succeeded, \(failedFiles.count) failed."
        if enableTagging && !passSourceTags {
            statusMessage += " \(segments.count) segments tagged."
        }
        if passSourceTags {
            statusMessage += " Source tags copied."
        }
        if enableCollectionSegmentation && !collectionSegments.isEmpty {
            statusMessage += " \(collectionSegments.count) collections organized."
        }
        postCompletionNotification()
    }
    /// Called by UI when user chooses to retry failed files with a different provider/model.
    func retryFailedFiles(provider: LLMProvider, model: LLMModel, thinkingLevel: ThinkingLevel?, apiKey: String) {
        awaitingRetryDecision = false
        retryContinuation?.resume(returning: .retry(provider: provider, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey))
        retryContinuation = nil
    }
    /// Called by UI when user chooses to continue without retrying.
    func continueWithoutRetry() {
        awaitingRetryDecision = false
        retryContinuation?.resume(returning: .continueWithout)
        retryContinuation = nil
    }
    /// Present retry dialog and wait for user decision. Returns the action chosen.
    private func promptRetryForFailedFiles() async -> RetryAction {
        guard !Task.isCancelled else { return .continueWithout }   // don't install a continuation for a cancelled run
        failedFileIndices = jobs.indices.filter { jobs[$0].status == .failed }.sorted()
        guard !failedFileIndices.isEmpty else { return .continueWithout }

        statusMessage = "\(failedFileIndices.count) file(s) failed OCR. Review and retry or continue."
        awaitingRetryDecision = true

        return await withCheckedContinuation { continuation in
            retryContinuation = continuation
        }
    }
    /// Retry loop: keeps presenting the retry dialog until all files succeed or user continues.
    private func retryLoopForFailedFiles(
        imageURLs: [URL],
        outputDirectory: URL
    ) async {
        while true {
            guard !Task.isCancelled else { return }

            let failedCount = jobs.filter { $0.status == .failed }.count
            guard failedCount > 0 else { return }

            let action = await promptRetryForFailedFiles()

            switch action {
            case .continueWithout:
                return
            case .retry(let provider, let model, let thinkingLevel, let apiKey):
                let indicesToRetry = failedFileIndices
                statusMessage = "Retrying \(indicesToRetry.count) files with \(provider.rawValue) \(model.displayName)…"

                for (attempt, index) in indicesToRetry.enumerated() {
                    guard !Task.isCancelled else { return }
                    jobs[index].status = .processing

                    let url = imageURLs[index]
                    let result = await Self.performOCRCall(
                        imageURL: url,
                        provider: provider,
                        model: model,
                        thinkingLevel: thinkingLevel,
                        apiKey: apiKey,
                        previousText: nil,
                        previousImageURL: nil,
                        gatewayConfig: currentGateway
                    )

                    handleOCRResult(result, index: index, url: url, model: model, outputDirectory: outputDirectory)

                    if result.text != nil {
                        failedFiles.removeAll { $0 == jobs[index].sourceURL.lastPathComponent }
                    }

                    progress = Double(attempt + 1) / Double(indicesToRetry.count)
                    statusMessage = "Retried \(attempt + 1)/\(indicesToRetry.count)"
                }
            }
            // Loop back — if there are still failures, the dialog will appear again
        }
    }
    /// Request notification permission (call once at app launch).
    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    /// Post a local notification summarizing the completed run.
    private func postCompletionNotification() {
        let succeeded = jobs.filter { $0.status == .succeeded }.count
        let failed = failedFiles.count
        let content = UNMutableNotificationContent()
        content.title = "Processing Complete"
        content.body = "\(succeeded) succeeded, \(failed) failed."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    private func writeLogFile(outputDirectory: URL) {
        // Opt-in: only write the log when the user has enabled it (default off).
        guard UserDefaults.standard.bool(forKey: "writeLogFile") else { return }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "d MMMM yyyy HH:mm"
        let dateStr = dateFormatter.string(from: Date())

        var lines = ["Archive Processor — OCR Log", "Date: \(dateStr)", ""]
        let removedCount = jobs.filter { $0.status == .removed }.count
        lines.append("Total files: \(jobs.count)")
        lines.append("Succeeded: \(jobs.filter { $0.status == .succeeded }.count)")
        lines.append("Failed: \(failedFiles.count)")
        if removedCount > 0 { lines.append("Removed during review: \(removedCount)") }
        if !segments.isEmpty {
            lines.append("Document segments: \(segments.count)")
        }
        lines.append("")

        if failedFiles.isEmpty {
            lines.append("All files processed successfully.")
        } else {
            lines.append("Files that did not produce OCR text:")
            for f in failedFiles {
                let job = jobs.first { $0.sourceURL.lastPathComponent == f }
                let reason = job?.result?.errorMessage ?? "Unknown error"
                let code = job?.result?.errorCode.map { " [\($0)]" } ?? ""
                lines.append("  \u{2022} \(f)\(code): \(reason)")
            }
        }

        let content = lines.joined(separator: "\n")
        let timestamp = Int(Date().timeIntervalSince1970)
        let logURL = outputDirectory.appendingPathComponent("ArchiveProcessor_Log_\(timestamp).txt")
        try? content.write(to: logURL, atomically: true, encoding: .utf8)
    }
}
