import Foundation

// MARK: - Collection Review Item

/// Represents a single file's classification and collection assignment for user review.
struct CollectionReviewItem: Identifiable {
    let id = UUID()
    let fileIndex: Int
    let fileName: String
    let fileURL: URL
    var classification: DocumentClassification?
    var collectionName: String
    /// Whether this item was identified as a box label (and thus defines a collection boundary)
    var isBoxLabel: Bool
}

@MainActor
class OCRProcessor: ObservableObject {
    @Published var jobs: [OCRJob] = []
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    @Published var failedFiles: [String] = []
    @Published var segments: [DocumentSegment] = []
    @Published var collectionSegments: [CollectionSegment] = []

    @Published var pendingBatchInfo: String?

    /// Review state for collection confirmation flow
    @Published var collectionReviewItems: [CollectionReviewItem] = []
    @Published var awaitingCollectionConfirmation = false
    private var collectionConfirmationContinuation: CheckedContinuation<Void, Never>?

    /// Retry dialog state
    enum RetryAction {
        case retry(provider: LLMProvider, model: LLMModel, thinkingLevel: ThinkingLevel?, apiKey: String)
        case continueWithout
    }
    @Published var failedFileIndices: [Int] = []
    @Published var awaitingRetryDecision = false
    private var retryContinuation: CheckedContinuation<RetryAction, Never>?

    /// Maps source image URL → output PDF URL (for tagging the output, not the source)
    var outputURLMap: [URL: URL] = [:]
    /// Maps original PDF source URL → temporary JPEG URL (for cleanup)
    private var pdfToImageMap: [URL: URL] = [:]
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
        let enableCollectionSegmentation: Bool
        let sendPreviousImage: Bool
        let submittedAt: Date

        // Backward compatibility: default enableCollectionSegmentation to false
        init(batchId: String, provider: LLMProvider, model: LLMModel, thinkingLevel: ThinkingLevel?,
             fileURLs: [URL], outputDirectory: URL, enableTagging: Bool,
             enableCollectionSegmentation: Bool = false, sendPreviousImage: Bool, submittedAt: Date) {
            self.batchId = batchId; self.provider = provider; self.model = model
            self.thinkingLevel = thinkingLevel; self.fileURLs = fileURLs
            self.outputDirectory = outputDirectory; self.enableTagging = enableTagging
            self.enableCollectionSegmentation = enableCollectionSegmentation
            self.sendPreviousImage = sendPreviousImage; self.submittedAt = submittedAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            batchId = try c.decode(String.self, forKey: .batchId)
            provider = try c.decode(LLMProvider.self, forKey: .provider)
            model = try c.decode(LLMModel.self, forKey: .model)
            thinkingLevel = try c.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevel)
            fileURLs = try c.decode([URL].self, forKey: .fileURLs)
            outputDirectory = try c.decode(URL.self, forKey: .outputDirectory)
            enableTagging = try c.decode(Bool.self, forKey: .enableTagging)
            enableCollectionSegmentation = try c.decodeIfPresent(Bool.self, forKey: .enableCollectionSegmentation) ?? false
            sendPreviousImage = try c.decode(Bool.self, forKey: .sendPreviousImage)
            submittedAt = try c.decode(Date.self, forKey: .submittedAt)
        }
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
        collectionSegments = []
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

        await retryLoopForFailedFiles(
            imageURLs: pending.fileURLs,
            outputDirectory: pending.outputDirectory
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
                thinkingLevel: pending.thinkingLevel, apiKey: apiKey,
                outputDirectory: pending.outputDirectory
            )
        }

        guard !Task.isCancelled else { return }

        if pending.enableCollectionSegmentation {
            await performCollectionSegmentation(
                files: pending.fileURLs,
                provider: pending.provider,
                model: pending.model,
                thinkingLevel: pending.thinkingLevel,
                apiKey: apiKey,
                outputDirectory: pending.outputDirectory
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
        if pending.enableCollectionSegmentation && !collectionSegments.isEmpty {
            statusMessage += " \(collectionSegments.count) collections organized."
        }
    }

    func cancel() {
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
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
        enableSegmentJSON: Bool = true,
        enableCollectionSegmentation: Bool = false,
        confirmCollectionIDs: Bool = false,
        preOCRedInput: Bool = false,
        segmentationContext: SegmentationContext
    ) async {
        guard !files.isEmpty else { return }
        isProcessing = true
        failedFiles = []
        segments = []
        collectionSegments = []
        outputURLMap = [:]
        pdfToImageMap = [:]
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
                confirmCollectionIDs: confirmCollectionIDs
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
                    enableCollectionSegmentation: enableCollectionSegmentation
                )
            } else {
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

            // Phase 2: Segmentation + Tagging
            if enableTagging {
                statusMessage = "Segmenting documents…"
                let segmenter = DocumentSegmenter()
                let classifications = jobs.map { $0.result?.classification }
                let texts = jobs.map { $0.result?.text ?? "" }
                segments = segmenter.segment(files: files, classifications: classifications, texts: texts)
                statusMessage = "Found \(segments.count) segments. Generating tags…"

                await performTaggingPhase(
                    provider: provider,
                    model: model,
                    thinkingLevel: thinkingLevel,
                    apiKey: apiKey,
                    outputDirectory: outputDirectory,
                    enableSegmentJSON: enableSegmentJSON
                )
            }

            guard !Task.isCancelled else { cleanupTempFiles(); return }

            // Phase 4: Collection Segmentation
            if enableCollectionSegmentation {
                await performCollectionSegmentation(
                    files: files,
                    provider: provider,
                    model: model,
                    thinkingLevel: thinkingLevel,
                    apiKey: apiKey,
                    outputDirectory: outputDirectory,
                    confirmBeforeOrganizing: confirmCollectionIDs
                )
            }

            cleanupTempFiles()
        }

        guard !Task.isCancelled else { return }
        writeLogFile(outputDirectory: outputDirectory)
        isProcessing = false
        let succeeded = jobs.filter { $0.status == .succeeded }.count
        statusMessage = "Done. \(succeeded) succeeded, \(failedFiles.count) failed."
        if enableTagging {
            statusMessage += " \(segments.count) segments tagged."
        }
        if enableCollectionSegmentation && !collectionSegments.isEmpty {
            statusMessage += " \(collectionSegments.count) collections organized."
        }
    }

    // MARK: - PDF Input Conversion

    /// Convert any PDF files in the input list to temporary JPEG images.
    /// Returns a new array where PDF URLs have been replaced with temp JPEG URLs.
    /// Non-PDF files are returned unchanged. The jobs array still references the
    /// original source URLs for display and output naming.
    private func convertPDFInputs(_ files: [URL]) -> [URL] {
        var imageURLs = files
        var converted = 0
        for (i, url) in files.enumerated() {
            guard url.pathExtension.lowercased() == "pdf" else { continue }
            let imageURL = PDFToImageConverter.imageURL(for: url)
            if imageURL != url {
                pdfToImageMap[url] = imageURL
                imageURLs[i] = imageURL
                // Update the job's source to the temp image for API calls,
                // but keep the original URL in outputURLMap keyed by temp URL
                converted += 1
            }
        }
        if converted > 0 {
            statusMessage = "Converted \(converted) PDF\(converted == 1 ? "" : "s") to images…"
        }
        return imageURLs
    }

    /// Clean up temporary JPEG files created from PDF inputs.
    private func cleanupTempFiles() {
        for (_, tempURL) in pdfToImageMap {
            try? FileManager.default.removeItem(at: tempURL)
        }
        pdfToImageMap = [:]
    }

    // MARK: - Pre-OCRed PDF Processing

    private func performPreOCRedProcessing(
        files: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        enableTagging: Bool,
        enableSegmentJSON: Bool = true,
        enableCollectionSegmentation: Bool,
        confirmCollectionIDs: Bool = false
    ) async {
        let total = files.count
        statusMessage = "Extracting text from \(total) PDFs…"

        // Step 1: Extract text from PDFs (no API calls)
        for (index, url) in files.enumerated() {
            guard !Task.isCancelled else { return }
            jobs[index].status = .processing

            let extraction = PDFTextExtractor.extract(from: url)
            let result = OCRResult(
                text: extraction.text,
                classification: extraction.classification,
                errorMessage: extraction.text == nil ? "No text found in PDF" : nil,
                errorCode: nil
            )
            jobs[index].result = result
            jobs[index].classification = extraction.classification
            jobs[index].status = extraction.text != nil ? .succeeded : .failed
            if extraction.text == nil {
                failedFiles.append(url.lastPathComponent)
            }

            // Map the input PDF as the output (no new PDF generated)
            outputURLMap[url] = url

            progress = Double(index + 1) / Double(total) * 0.3
            statusMessage = "Extracted text \(index + 1)/\(total)"
        }

        guard !Task.isCancelled else { return }

        // Step 2: Classify files that lack classification (text-only LLM calls)
        let needsClassification = (enableTagging || enableCollectionSegmentation)
        let unclassifiedIndices = jobs.indices.filter {
            jobs[$0].result?.classification == nil && jobs[$0].result?.text != nil
        }

        if needsClassification && !unclassifiedIndices.isEmpty {
            statusMessage = "Classifying \(unclassifiedIndices.count) documents…"
            var previousText: String? = nil

            for (attempt, index) in unclassifiedIndices.enumerated() {
                guard !Task.isCancelled else { return }
                let text = jobs[index].result?.text ?? ""

                let prompt = OCRPrompt.buildClassificationOnly(text: text, previousText: previousText)
                let classification = await classifyViaLLM(
                    prompt: prompt, provider: provider, model: model,
                    thinkingLevel: thinkingLevel, apiKey: apiKey
                )

                jobs[index].classification = classification
                jobs[index].result = OCRResult(
                    text: jobs[index].result?.text,
                    classification: classification,
                    errorMessage: jobs[index].result?.errorMessage,
                    errorCode: nil
                )

                // Use this file's text as context for the next
                previousText = String(text.suffix(500))

                progress = 0.3 + Double(attempt + 1) / Double(unclassifiedIndices.count) * 0.2
                statusMessage = "Classified \(attempt + 1)/\(unclassifiedIndices.count)"
            }
        }

        guard !Task.isCancelled else { return }
        progress = 0.5

        // Step 3: Segmentation + Tagging
        if enableTagging {
            statusMessage = "Segmenting documents…"
            let segmenter = DocumentSegmenter()
            let classifications = jobs.map { $0.result?.classification }
            let texts = jobs.map { $0.result?.text ?? "" }
            segments = segmenter.segment(files: files, classifications: classifications, texts: texts)
            statusMessage = "Found \(segments.count) segments. Generating tags…"

            await performTaggingPhase(
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                outputDirectory: outputDirectory,
                enableSegmentJSON: enableSegmentJSON
            )
        }

        guard !Task.isCancelled else { return }

        // Step 4: Collection Segmentation
        if enableCollectionSegmentation {
            await performCollectionSegmentation(
                files: files,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                outputDirectory: outputDirectory,
                confirmBeforeOrganizing: confirmCollectionIDs
            )
        }
    }

    /// Classify a document using a text-only LLM call (no image).
    private func classifyViaLLM(
        prompt: String,
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String
    ) async -> DocumentClassification? {
        do {
            let response: String
            switch provider {
            case .anthropic:
                response = try await classifyCallAnthropic(prompt: prompt, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey)
            case .gemini:
                response = try await classifyCallGemini(prompt: prompt, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey)
            case .mistral:
                response = try await classifyCallMistral(prompt: prompt, apiKey: apiKey)
            }
            let (classification, _, _) = OCRPrompt.parseResponse(response)
            return classification
        } catch {
            return nil
        }
    }

    private nonisolated func classifyCallAnthropic(prompt: String, model: LLMModel, thinkingLevel: ThinkingLevel?, apiKey: String) async throws -> String {
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        var body: [String: Any] = [
            "model": model.id, "max_tokens": 64,
            "messages": [["role": "user", "content": prompt]]
        ]
        if let thinking = thinkingLevel {
            body["thinking"] = ["type": "enabled", "budget_tokens": thinking == .low ? 512 : 2000]
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await NetworkSession.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { return "" }
        return content.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
    }

    private nonisolated func classifyCallGemini(prompt: String, model: LLMModel, thinkingLevel: ThinkingLevel?, apiKey: String) async throws -> String {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model.id):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { return "" }
        var body: [String: Any] = ["contents": [["parts": [["text": prompt]]]]]
        if let thinking = thinkingLevel {
            body["generationConfig"] = ["thinkingConfig": ["thinkingBudget": thinking == .low ? 512 : 2000]]
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await NetworkSession.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    private nonisolated func classifyCallMistral(prompt: String, apiKey: String) async throws -> String {
        let endpoint = URL(string: "https://api.mistral.ai/v1/chat/completions")!
        let body: [String: Any] = [
            "model": "mistral-small-latest",
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 64
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await NetworkSession.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return "" }
        return content
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
        enableTagging: Bool,
        enableCollectionSegmentation: Bool = false
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
                failedFiles.append(jobs[i].sourceURL.lastPathComponent)
            }
            return
        }

        // Store for cancellation + persist to disk for resume after relaunch
        activeBatch = BatchContext(batchId: batchId, apiKey: apiKey, model: model, thinkingLevel: thinkingLevel, provider: provider)
        Self.savePendingBatch(PendingBatch(
            batchId: batchId, provider: provider, model: model,
            thinkingLevel: thinkingLevel, fileURLs: fileURLs,
            outputDirectory: outputDirectory, enableTagging: enableTagging,
            enableCollectionSegmentation: enableCollectionSegmentation,
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
                                failedFiles.append(jobs[i].sourceURL.lastPathComponent)
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
                                failedFiles.append(jobs[i].sourceURL.lastPathComponent)
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
                                failedFiles.append(jobs[i].sourceURL.lastPathComponent)
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
        let sourceURL = jobs[index].sourceURL
        jobs[index].result = result
        jobs[index].classification = result.classification
        jobs[index].status = result.text != nil ? .succeeded : .failed
        if result.text == nil {
            failedFiles.append(sourceURL.lastPathComponent)
        }
        let pdfGen = PDFGenerator()
        // Use original source name for output PDF naming
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let outputURL = outputDirectory.appendingPathComponent(baseName + ".pdf")
        // Use the provided url (may be temp JPEG) for the image page
        try? pdfGen.generate(imageURL: url, result: result, model: model, outputURL: outputURL)
        // Map by original source URL so tagging/collection segmentation can find it
        outputURLMap[sourceURL] = outputURL
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
        apiKey: String,
        outputDirectory: URL,
        enableSegmentJSON: Bool = true
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

            // Write segment JSON metadata file (skip boxes and folders)
            if enableSegmentJSON && !segment.isBox && !segment.isFolder {
                writeSegmentJSON(segment: segment, tags: tags, outputDirectory: outputDirectory)
            }

            let completed = segIndex + 1
            progress = 0.7 + (Double(completed) / Double(total)) * 0.3
            statusMessage = "Tagging segment \(completed)/\(total)…"
        }
    }

    // MARK: - Segment JSON

    private func writeSegmentJSON(segment: DocumentSegment, tags: GeneratedTags, outputDirectory: URL) {
        guard let firstFile = segment.pdfURLs.first else { return }
        let baseName = firstFile.deletingPathExtension().lastPathComponent
        let jsonURL = outputDirectory.appendingPathComponent(baseName + ".json")

        // Build body text with image markers
        var bodyParts: [String] = []
        for (i, url) in segment.pdfURLs.enumerated() {
            let text = i < segment.texts.count ? segment.texts[i] : ""
            bodyParts.append("[Image: \(url.lastPathComponent)]")
            if !text.isEmpty {
                bodyParts.append(text)
            }
        }
        let bodyText = bodyParts.joined(separator: "\n\n")

        // Build JSON dictionary
        var dict: [String: Any] = [:]
        if let date = tags.machineDate {
            dict["date"] = date
        }
        dict["date_uncertain"] = tags.dateUncertain
        dict["subjects"] = tags.subjectTags

        if let v = tags.format { dict["format"] = v }
        if let v = tags.authorName { dict["author_name"] = v }
        if let v = tags.recipientName { dict["recipient_name"] = v }
        if let v = tags.authorLocation { dict["author_location"] = v }
        if let v = tags.recipientLocation { dict["recipient_location"] = v }
        if let v = tags.publicationName { dict["publication_name"] = v }

        if segment.isBox { dict["format"] = "box_label" }
        if segment.isFolder { dict["format"] = "folder_label" }

        dict["files"] = segment.pdfURLs.map { $0.lastPathComponent }
        dict["body"] = bodyText

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: jsonURL, options: .atomic)
    }

    // MARK: - Phase 4: Collection Segmentation

    private func performCollectionSegmentation(
        files: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        confirmBeforeOrganizing: Bool = false
    ) async {
        statusMessage = "Identifying collections from box labels…"

        let classifications = jobs.map { $0.result?.classification }
        let texts = jobs.map { $0.result?.text ?? "" }

        let segmenter = CollectionSegmenter()
        collectionSegments = await segmenter.segment(
            files: files,
            classifications: classifications,
            texts: texts,
            provider: provider,
            model: model,
            thinkingLevel: thinkingLevel,
            apiKey: apiKey,
            onStatus: { [weak self] msg in
                self?.statusMessage = msg
            }
        )

        guard !collectionSegments.isEmpty, !Task.isCancelled else { return }

        // If confirmation is requested, build review items and wait for user
        if confirmBeforeOrganizing {
            buildReviewItems(files: files, classifications: classifications)
            statusMessage = "Review collection identifications before proceeding."
            awaitingCollectionConfirmation = true

            // Suspend until the user confirms
            await withCheckedContinuation { continuation in
                collectionConfirmationContinuation = continuation
            }

            guard !Task.isCancelled else { return }

            // Apply user edits: rebuild collectionSegments from reviewItems
            applyReviewEdits(files: files)
        }

        guard !collectionSegments.isEmpty, !Task.isCancelled else { return }

        statusMessage = "Organizing \(collectionSegments.count) collections into folders…"
        do {
            try segmenter.organizeOutput(
                collections: collectionSegments,
                outputDirectory: outputDirectory,
                outputURLMap: outputURLMap
            )
            statusMessage = "Collections organized into \(collectionSegments.count) folders."
        } catch {
            statusMessage = "Error organizing collections: \(error.localizedDescription)"
        }
    }

    /// Build review items from current classifications and collection segments.
    private func buildReviewItems(files: [URL], classifications: [DocumentClassification?]) {
        // Build a map from file URL to collection name using the current segments
        var fileToCollection: [URL: String] = [:]
        for segment in collectionSegments {
            for url in segment.fileURLs {
                fileToCollection[url] = segment.collectionName
            }
        }

        // Only include box and folder labels for review
        collectionReviewItems = files.enumerated().compactMap { (index, url) in
            let cls = index < classifications.count ? classifications[index] : nil
            guard cls == .boxLabel || cls == .folderLabel else { return nil }
            let isBox = cls == .boxLabel
            let collection = fileToCollection[url] ?? "Uncategorized"
            return CollectionReviewItem(
                fileIndex: index,
                fileName: url.lastPathComponent,
                fileURL: url,
                classification: cls,
                collectionName: collection,
                isBoxLabel: isBox
            )
        }
    }

    /// Apply user edits from review items back into collectionSegments.
    /// Rebuilds segmentation from scratch using the confirmed box/folder identifications.
    private func applyReviewEdits(files: [URL]) {
        // Build a lookup from file index to the reviewed item
        var reviewByIndex: [Int: CollectionReviewItem] = [:]
        for item in collectionReviewItems {
            reviewByIndex[item.fileIndex] = item
        }

        // Update job classifications from review items
        for item in collectionReviewItems {
            if item.fileIndex < jobs.count {
                jobs[item.fileIndex].classification = item.classification
                if let existingResult = jobs[item.fileIndex].result {
                    jobs[item.fileIndex].result = OCRResult(
                        text: existingResult.text,
                        classification: item.classification,
                        errorMessage: existingResult.errorMessage,
                        errorCode: nil
                    )
                }
            }
        }

        // Find box labels in order (user may have reclassified some)
        let boxIndices = collectionReviewItems
            .filter { $0.classification == .boxLabel }
            .sorted { $0.fileIndex < $1.fileIndex }

        guard !boxIndices.isEmpty else {
            // No boxes left — put everything in one collection
            collectionSegments = [CollectionSegment(collectionName: "Uncategorized", fileURLs: files)]
            return
        }

        // Walk all files, assigning each to the collection of the preceding box label
        var currentCollection = boxIndices[0].collectionName
        var collectionOrder: [String] = []
        var collectionFiles: [String: [URL]] = [:]

        for i in 0..<files.count {
            if let reviewed = reviewByIndex[i], reviewed.classification == .boxLabel {
                currentCollection = reviewed.collectionName
            }
            if collectionFiles[currentCollection] == nil {
                collectionOrder.append(currentCollection)
                collectionFiles[currentCollection] = []
            }
            collectionFiles[currentCollection]!.append(files[i])
        }

        collectionSegments = collectionOrder.map { name in
            CollectionSegment(collectionName: name, fileURLs: collectionFiles[name] ?? [])
        }
    }

    /// Called by the UI when the user confirms the collection review.
    func confirmCollectionReview() {
        awaitingCollectionConfirmation = false
        collectionConfirmationContinuation?.resume()
        collectionConfirmationContinuation = nil
    }

    // MARK: - Failed OCR Retry

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
                        previousImageURL: nil
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
        let logURL = outputDirectory.appendingPathComponent("ArchiveProcessor_Log_\(timestamp).txt")
        try? content.write(to: logURL, atomically: true, encoding: .utf8)
    }
}
