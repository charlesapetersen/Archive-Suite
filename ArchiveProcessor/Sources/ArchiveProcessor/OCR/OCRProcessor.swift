import Foundation

@MainActor
class OCRProcessor: ObservableObject {
    @Published var jobs: [OCRJob] = []
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    @Published var failedFiles: [String] = []
    @Published var segments: [DocumentSegment] = []

    @Published var pendingBatchInfo: String?

    /// Maps source image URL → output PDF URL (for tagging the output, not the source)
    private var outputURLMap: [URL: URL] = [:]
    var processingTask: Task<Void, Never>?

    /// Stored batch context for cancellation
    private struct BatchContext: Sendable {
        let batchId: String
        let apiKey: String
        let model: LLMModel
        let thinkingLevel: ThinkingLevel?
        let provider: LLMProvider
    }
    private var activeBatch: BatchContext?

    // MARK: - Batch Persistence

    struct PendingBatch: Codable {
        let batchId: String
        let provider: LLMProvider
        let model: LLMModel
        let thinkingLevel: ThinkingLevel?
        let fileURLs: [URL]
        let outputDirectory: URL
        let enableTagging: Bool
        let sendPreviousImage: Bool
        let submittedAt: Date
    }

    private static var pendingBatchURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ArchiveProcessor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending_batch.json")
    }

    private static func savePendingBatch(_ batch: PendingBatch) {
        guard let data = try? JSONEncoder().encode(batch) else { return }
        try? data.write(to: pendingBatchURL)
    }

    private static func loadPendingBatch() -> PendingBatch? {
        guard let data = try? Data(contentsOf: pendingBatchURL) else { return nil }
        return try? JSONDecoder().decode(PendingBatch.self, from: data)
    }

    private static func deletePendingBatch() {
        try? FileManager.default.removeItem(at: pendingBatchURL)
    }

    /// File URLs from a pending batch (for populating the file list on resume).
    var pendingBatchFileURLs: [URL]? {
        Self.loadPendingBatch()?.fileURLs
    }

    /// Check for a persisted pending batch on launch.
    func checkForPendingBatch() {
        guard let pending = Self.loadPendingBatch() else {
            pendingBatchInfo = nil
            return
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let dateStr = formatter.string(from: pending.submittedAt)
        pendingBatchInfo = "Pending batch from \(dateStr): \(pending.fileURLs.count) files via \(pending.provider.rawValue) \(pending.model.displayName)."
    }

    /// Dismiss a pending batch notification (deletes local state only — server-side batch continues).
    func dismissPendingBatch() {
        Self.deletePendingBatch()
        pendingBatchInfo = nil
    }

    /// Resume polling a previously submitted batch.
    func resumeBatch(apiKey: String) async {
        guard let pending = Self.loadPendingBatch() else { return }

        isProcessing = true
        pendingBatchInfo = nil
        failedFiles = []
        segments = []
        outputURLMap = [:]
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

        Self.deletePendingBatch()
        activeBatch = nil

        guard !Task.isCancelled else { return }

        await retryHighUseFailures(
            fileURLs: pending.fileURLs, provider: pending.provider,
            model: pending.model, thinkingLevel: pending.thinkingLevel,
            apiKey: apiKey, outputDirectory: pending.outputDirectory
        )

        guard !Task.isCancelled else { return }

        if pending.enableTagging {
            statusMessage = "Segmenting documents…"
            let segmenter = DocumentSegmenter()
            let classifications = jobs.map { $0.result?.classification }
            let texts = jobs.map { $0.result?.text ?? "" }
            segments = segmenter.segment(files: pending.fileURLs, classifications: classifications, texts: texts)
            statusMessage = "Found \(segments.count) segments. Generating tags…"

            await performTaggingPhase(
                provider: pending.provider, model: pending.model,
                thinkingLevel: pending.thinkingLevel, apiKey: apiKey
            )
        }

        guard !Task.isCancelled else { return }
        writeLogFile(outputDirectory: pending.outputDirectory)
        isProcessing = false
        let succeeded = jobs.filter { $0.status == .succeeded }.count
        statusMessage = "Done. \(succeeded) succeeded, \(failedFiles.count) failed."
        if pending.enableTagging {
            statusMessage += " \(segments.count) segments tagged."
        }
    }

    func cancel() {
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false

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
                    await client.cancelBatch(batchName: batch.batchId)
                }
            }
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
        segmentationContext: SegmentationContext
    ) async {
        guard !files.isEmpty else { return }
        isProcessing = true
        failedFiles = []
        segments = []
        outputURLMap = [:]
        jobs = files.map { OCRJob(sourceURL: $0) }
        progress = 0
        statusMessage = "Starting OCR…"

        // --- Phase 1: OCR + Classification ---
        if batchMode && provider.supportsBatch {
            await performBatchOCR(
                fileURLs: files,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                outputDirectory: outputDirectory,
                sendPreviousImage: segmentationContext.sendPreviousImage,
                enableTagging: enableTagging
            )
        } else {
            await performOCRPhase(
                fileURLs: files,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                outputDirectory: outputDirectory,
                segmentationContext: segmentationContext
            )
        }

        guard !Task.isCancelled else { return }

        // --- Phase 1b: Retry files that failed due to high use ---
        await retryHighUseFailures(
            fileURLs: files,
            provider: provider,
            model: model,
            thinkingLevel: thinkingLevel,
            apiKey: apiKey,
            outputDirectory: outputDirectory
        )

        guard !Task.isCancelled else { return }

        // --- Phase 2: Segmentation + Tagging ---
        if enableTagging {
            statusMessage = "Segmenting documents…"
            let segmenter = DocumentSegmenter()
            let classifications = jobs.map { $0.result?.classification }
            let texts = jobs.map { $0.result?.text ?? "" }
            // Pass source URLs for segmentation; we'll map to output PDFs when tagging
            segments = segmenter.segment(files: files, classifications: classifications, texts: texts)
            statusMessage = "Found \(segments.count) segments. Generating tags…"

            await performTaggingPhase(
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey
            )
        }

        guard !Task.isCancelled else { return }
        writeLogFile(outputDirectory: outputDirectory)
        isProcessing = false
        let succeeded = jobs.filter { $0.status == .succeeded }.count
        statusMessage = "Done. \(succeeded) succeeded, \(failedFiles.count) failed."
        if enableTagging {
            statusMessage += " \(segments.count) segments tagged."
        }
    }

    // MARK: - Phase 1 (Batch): Batch OCR

    private func performBatchOCR(
        fileURLs: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        sendPreviousImage: Bool,
        enableTagging: Bool
    ) async {
        let total = fileURLs.count

        // Mark all as processing
        for i in 0..<total { jobs[i].status = .processing }

        // Submit batch
        statusMessage = "Submitting batch (\(total) files)…"

        let batchId: String
        do {
            switch provider {
            case .anthropic:
                let client = AnthropicBatchClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                batchId = try await client.submitBatch(fileURLs: fileURLs, sendPreviousImage: sendPreviousImage)
            case .mistral:
                let client = MistralBatchClient(apiKey: apiKey, model: model)
                batchId = try await client.submitBatch(fileURLs: fileURLs)
            case .gemini:
                let client = GeminiBatchClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                batchId = try await client.submitBatch(fileURLs: fileURLs, sendPreviousImage: sendPreviousImage)
            }
        } catch {
            statusMessage = "Batch submission failed: \(error.localizedDescription)"
            for i in jobs.indices where jobs[i].status == .processing {
                jobs[i].status = .failed
                failedFiles.append(fileURLs[i].lastPathComponent)
            }
            return
        }

        // Store for cancellation + persist to disk for resume after relaunch
        activeBatch = BatchContext(batchId: batchId, apiKey: apiKey, model: model, thinkingLevel: thinkingLevel, provider: provider)
        Self.savePendingBatch(PendingBatch(
            batchId: batchId, provider: provider, model: model,
            thinkingLevel: thinkingLevel, fileURLs: fileURLs,
            outputDirectory: outputDirectory, enableTagging: enableTagging,
            sendPreviousImage: sendPreviousImage, submittedAt: Date()
        ))
        statusMessage = "Batch submitted. Waiting for results…"

        // Poll for completion
        await pollBatchUntilComplete(
            batchId: batchId, provider: provider, model: model,
            thinkingLevel: thinkingLevel, apiKey: apiKey,
            fileURLs: fileURLs, outputDirectory: outputDirectory
        )

        Self.deletePendingBatch()
        activeBatch = nil
        progress = 0.7
    }

    /// Shared polling loop used by both initial batch processing and resume.
    private func pollBatchUntilComplete(
        batchId: String,
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        fileURLs: [URL],
        outputDirectory: URL
    ) async {
        var pollCount = 0
        var batchComplete = false
        while !batchComplete {
            guard !Task.isCancelled else { return }

            let interval: Duration = pollCount < 10 ? .seconds(30) : .seconds(60)
            try? await Task.sleep(for: interval)
            pollCount += 1

            guard !Task.isCancelled else { return }

            do {
                switch provider {
                case .anthropic:
                    let client = AnthropicBatchClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                    let status = try await client.checkStatus(batchId: batchId)
                    progress = Double(status.completed) / Double(max(1, status.total)) * 0.7
                    statusMessage = "Batch processing… \(status.completed)/\(status.total) complete"

                    if status.isComplete {
                        if let url = status.resultsURL {
                            statusMessage = "Retrieving batch results…"
                            let results = try await client.retrieveResults(resultsURL: url)
                            processBatchResults(results, fileURLs: fileURLs, model: model, outputDirectory: outputDirectory)
                        } else {
                            statusMessage = "Batch completed but no results available"
                            for i in jobs.indices where jobs[i].status == .processing {
                                jobs[i].status = .failed
                                failedFiles.append(fileURLs[i].lastPathComponent)
                            }
                        }
                        batchComplete = true
                    }

                case .mistral:
                    let client = MistralBatchClient(apiKey: apiKey, model: model)
                    let status = try await client.checkStatus(batchId: batchId)
                    progress = Double(status.completedRequests) / Double(max(1, status.totalRequests)) * 0.7
                    statusMessage = "Batch processing… \(status.completedRequests)/\(status.totalRequests) complete"

                    if status.isComplete {
                        if status.status == "SUCCESS", let fileId = status.outputFileId {
                            statusMessage = "Retrieving batch results…"
                            let results = try await client.retrieveResults(outputFileId: fileId)
                            processBatchResults(results, fileURLs: fileURLs, model: model, outputDirectory: outputDirectory)
                        } else {
                            statusMessage = "Batch \(status.status.lowercased())"
                            for i in jobs.indices where jobs[i].status == .processing {
                                jobs[i].status = .failed
                                failedFiles.append(fileURLs[i].lastPathComponent)
                            }
                        }
                        batchComplete = true
                    }

                case .gemini:
                    let client = GeminiBatchClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                    let status = try await client.checkStatus(batchName: batchId)
                    statusMessage = "Batch processing… (\(status.state.replacingOccurrences(of: "JOB_STATE_", with: "").lowercased()))"

                    if status.isComplete {
                        if status.state == "JOB_STATE_SUCCEEDED", let fileName = status.resultFileName {
                            statusMessage = "Retrieving batch results…"
                            let results = try await client.retrieveResults(resultFileName: fileName)
                            processBatchResults(results, fileURLs: fileURLs, model: model, outputDirectory: outputDirectory)
                        } else {
                            statusMessage = "Batch \(status.state.replacingOccurrences(of: "JOB_STATE_", with: "").lowercased())"
                            for i in jobs.indices where jobs[i].status == .processing {
                                jobs[i].status = .failed
                                failedFiles.append(fileURLs[i].lastPathComponent)
                            }
                        }
                        batchComplete = true
                    }
                }
            } catch {
                statusMessage = "Error checking batch: \(error.localizedDescription). Retrying…"
            }
        }
    }

    private func processBatchResults(
        _ results: [String: OCRResult],
        fileURLs: [URL],
        model: LLMModel,
        outputDirectory: URL
    ) {
        for (customId, result) in results {
            let indexStr = customId.replacingOccurrences(of: "file-", with: "")
            guard let index = Int(indexStr), index < fileURLs.count else { continue }
            let url = fileURLs[index]
            handleOCRResult(result, index: index, url: url, model: model, outputDirectory: outputDirectory)
        }

        // Mark any remaining processing jobs as failed (no result returned for them)
        for i in jobs.indices where jobs[i].status == .processing {
            jobs[i].status = .failed
            failedFiles.append(fileURLs[i].lastPathComponent)
        }
    }

    // MARK: - Phase 1: OCR

    private func performOCRPhase(
        fileURLs: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        segmentationContext: SegmentationContext
    ) async {
        if segmentationContext.previousTextCharCount == 0 {
            // No dependency on prior OCR text — can run in parallel
            await performOCRParallel(
                fileURLs: fileURLs,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                outputDirectory: outputDirectory,
                sendPreviousImage: segmentationContext.sendPreviousImage
            )
        } else {
            // Need prior page's OCR text — must be sequential
            await performOCRSequential(
                fileURLs: fileURLs,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                outputDirectory: outputDirectory,
                segmentationContext: segmentationContext
            )
        }
    }

    // MARK: Sequential OCR (when previous text context is needed)

    private func performOCRSequential(
        fileURLs: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        segmentationContext: SegmentationContext
    ) async {
        let total = fileURLs.count
        var previousText: String? = nil
        var previousImageURL: URL? = nil

        for index in 0..<total {
            guard !Task.isCancelled else { return }
            let url = fileURLs[index]
            jobs[index].status = .processing

            let contextText: String?
            if let prev = previousText, segmentationContext.previousTextCharCount > 0 {
                let charCount = segmentationContext.previousTextCharCount
                contextText = String(prev.suffix(charCount))
            } else {
                contextText = nil
            }
            let contextImageURL = segmentationContext.sendPreviousImage ? previousImageURL : nil

            statusMessage = "OCR \(index + 1)/\(total)…"
            var result = await Self.performOCRCall(
                imageURL: url,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                previousText: contextText,
                previousImageURL: contextImageURL
            )

            // If timed out, retry once without context
            if Self.isTimeoutError(result) {
                statusMessage = "OCR \(index + 1)/\(total)… retrying after timeout"
                result = await Self.performOCRCall(
                    imageURL: url,
                    provider: provider,
                    model: model,
                    thinkingLevel: thinkingLevel,
                    apiKey: apiKey,
                    previousText: nil,
                    previousImageURL: nil
                )
            }

            handleOCRResult(result, index: index, url: url, model: model, outputDirectory: outputDirectory)
            previousText = result.text
            previousImageURL = url

            progress = Double(index + 1) / Double(total) * 0.7
            statusMessage = "OCR \(index + 1)/\(total) complete"
        }
    }

    // MARK: Parallel OCR (when no previous text context is needed)

    private func performOCRParallel(
        fileURLs: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        sendPreviousImage: Bool
    ) async {
        let total = fileURLs.count
        let concurrency = 4
        var completed = 0

        // Mark all as processing
        for i in 0..<total { jobs[i].status = .processing }
        statusMessage = "OCR 0/\(total)… (parallel, \(concurrency) workers)"

        await withTaskGroup(of: (Int, OCRResult).self) { group in
            var nextIndex = 0

            // Seed initial batch
            for _ in 0..<min(concurrency, total) {
                let index = nextIndex
                let url = fileURLs[index]
                let prevImageURL = (sendPreviousImage && index > 0) ? fileURLs[index - 1] : nil
                nextIndex += 1
                group.addTask {
                    let result = await Self.performOCRCall(
                        imageURL: url, provider: provider, model: model,
                        thinkingLevel: thinkingLevel, apiKey: apiKey,
                        previousText: nil, previousImageURL: prevImageURL
                    )
                    return (index, result)
                }
            }

            // Collect results and feed new tasks
            for await (index, result) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                let url = fileURLs[index]
                handleOCRResult(result, index: index, url: url, model: model, outputDirectory: outputDirectory)

                completed += 1
                progress = Double(completed) / Double(total) * 0.7
                statusMessage = "OCR \(completed)/\(total) complete (parallel)"

                // Add next task if available
                if nextIndex < total {
                    let idx = nextIndex
                    let nextURL = fileURLs[idx]
                    let prevImageURL = (sendPreviousImage && idx > 0) ? fileURLs[idx - 1] : nil
                    nextIndex += 1
                    group.addTask {
                        let result = await Self.performOCRCall(
                            imageURL: nextURL, provider: provider, model: model,
                            thinkingLevel: thinkingLevel, apiKey: apiKey,
                            previousText: nil, previousImageURL: prevImageURL
                        )
                        return (idx, result)
                    }
                }
            }
        }
    }

    // MARK: Shared OCR helpers

    private func handleOCRResult(_ result: OCRResult, index: Int, url: URL, model: LLMModel, outputDirectory: URL) {
        jobs[index].result = result
        jobs[index].classification = result.classification
        jobs[index].status = result.text != nil ? .succeeded : .failed
        if result.text == nil {
            failedFiles.append(url.lastPathComponent)
        }
        let pdfGen = PDFGenerator()
        let outputURL = outputDirectory.appendingPathComponent(
            url.deletingPathExtension().lastPathComponent + ".pdf"
        )
        try? pdfGen.generate(imageURL: url, result: result, model: model, outputURL: outputURL)
        outputURLMap[url] = outputURL
    }

    private static func isTimeoutError(_ result: OCRResult) -> Bool {
        result.errorMessage?.lowercased().contains("timed out") == true
            || result.errorCode?.lowercased().contains("timeout") == true
    }

    private nonisolated static func performOCRCall(
        imageURL: URL,
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        previousText: String?,
        previousImageURL: URL?
    ) async -> OCRResult {
        do {
            switch provider {
            case .anthropic:
                let client = AnthropicClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                return try await client.ocr(imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL)
            case .gemini:
                let client = GeminiClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                return try await client.ocr(imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL)
            case .mistral:
                let client = MistralClient(apiKey: apiKey, model: model)
                return try await client.ocr(imageURL: imageURL, previousText: previousText)
            }
        } catch {
            return OCRResult(text: nil, classification: nil, errorMessage: error.localizedDescription, errorCode: nil)
        }
    }

    // MARK: - Retry High-Use Failures

    private func isRetryableError(_ result: OCRResult?) -> Bool {
        guard let result = result, result.text == nil else { return false }
        let code = result.errorCode ?? ""
        let msg = (result.errorMessage ?? "").lowercased()
        return code == "503" || code == "429" || code == "529"
            || msg.contains("high use") || msg.contains("high demand")
            || msg.contains("unavailable") || msg.contains("overloaded")
            || msg.contains("rate limit")
    }

    private func retryHighUseFailures(
        fileURLs: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL
    ) async {
        let retryIndices = jobs.indices.filter { isRetryableError(jobs[$0].result) }
        guard !retryIndices.isEmpty else { return }

        statusMessage = "Waiting to retry \(retryIndices.count) file\(retryIndices.count == 1 ? "" : "s") (model was busy)…"
        try? await Task.sleep(for: .seconds(10))
        guard !Task.isCancelled else { return }

        for (attempt, index) in retryIndices.enumerated() {
            guard !Task.isCancelled else { return }
            let url = fileURLs[index]
            jobs[index].status = .processing
            statusMessage = "Retrying \(attempt + 1)/\(retryIndices.count): \(url.lastPathComponent)…"

            let result = await Self.performOCRCall(
                imageURL: url,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                previousText: nil,
                previousImageURL: nil
            )

            // Update failed files list if retry succeeded
            if result.text != nil {
                failedFiles.removeAll { $0 == url.lastPathComponent }
            }
            handleOCRResult(result, index: index, url: url, model: model, outputDirectory: outputDirectory)
        }
    }

    // MARK: - Phase 3: Tagging

    private func performTaggingPhase(
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String
    ) async {
        let generator = TagGenerator()
        let total = segments.count

        for (segIndex, segment) in segments.enumerated() {
            guard !Task.isCancelled else { return }
            let nearby = Array(
                segments[max(0, segIndex - 3)..<segIndex]
                + segments[min(segIndex + 1, segments.count)..<min(segIndex + 4, segments.count)]
            )

            let tags = await generator.generateTags(
                for: segment,
                nearbySegments: nearby,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey
            )

            // Apply tags to the OUTPUT PDF files, not the source images
            for sourceURL in segment.pdfURLs {
                if let outputPDF = outputURLMap[sourceURL] {
                    try? MacOSTagger.applyTags(tags, to: outputPDF)
                }
                if let jobIndex = jobs.firstIndex(where: { $0.sourceURL == sourceURL }) {
                    jobs[jobIndex].appliedTags = tags.allTags
                }
            }

            let completed = segIndex + 1
            progress = 0.7 + (Double(completed) / Double(total)) * 0.3
            statusMessage = "Tagging segment \(completed)/\(total)…"
        }
    }

    // MARK: - Log

    private func writeLogFile(outputDirectory: URL) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "d MMMM yyyy HH:mm"
        let dateStr = dateFormatter.string(from: Date())

        var lines = ["Archive Processor — OCR Log", "Date: \(dateStr)", ""]
        lines.append("Total files: \(jobs.count)")
        lines.append("Succeeded: \(jobs.filter { $0.status == .succeeded }.count)")
        lines.append("Failed: \(failedFiles.count)")
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
        let logURL = outputDirectory.appendingPathComponent("OCR_Log_\(timestamp).txt")
        try? content.write(to: logURL, atomically: true, encoding: .utf8)
    }
}
