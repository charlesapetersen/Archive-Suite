import Foundation

@MainActor
class OCRProcessor: ObservableObject {
    @Published var jobs: [OCRJob] = []
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    @Published var failedFiles: [String] = []
    @Published var segments: [DocumentSegment] = []

    /// Maps source image URL → output PDF URL (for tagging the output, not the source)
    private var outputURLMap: [URL: URL] = [:]
    var processingTask: Task<Void, Never>?

    func cancel() {
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
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

        // --- Phase 1: OCR + Classification (sequential for context) ---
        await performOCRPhase(
            fileURLs: files,
            provider: provider,
            model: model,
            thinkingLevel: thinkingLevel,
            apiKey: apiKey,
            outputDirectory: outputDirectory,
            segmentationContext: segmentationContext
        )

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
