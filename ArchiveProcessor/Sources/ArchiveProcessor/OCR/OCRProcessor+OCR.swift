import Foundation
import UserNotifications

extension OCRProcessor {
    /// Convert any PDF files in the input list to temporary JPEG images.
    /// Returns a new array where PDF URLs have been replaced with temp JPEG URLs.
    /// Non-PDF files are returned unchanged. The jobs array still references the
    /// original source URLs for display and output naming.
    func convertPDFInputs(_ files: [URL]) -> [URL] {
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
    func cleanupTempFiles() {
        for (_, tempURL) in pdfToImageMap {
            try? FileManager.default.removeItem(at: tempURL)
        }
        pdfToImageMap = [:]
    }
    func performPreOCRedProcessing(
        files: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        enableTagging: Bool,
        enableSegmentJSON: Bool = true,
        enableCollectionSegmentation: Bool,
        confirmCollectionIDs: Bool = false,
        reviewDocumentSegmentation: Bool = false,
        customPrompt: String? = nil
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
        let needsClassification = ((enableTagging && !passSourceTags) || enableCollectionSegmentation)
        let unclassifiedIndices = jobs.indices.filter {
            jobs[$0].result?.classification == nil && jobs[$0].result?.text != nil
        }

        if needsClassification && !unclassifiedIndices.isEmpty {
            statusMessage = "Classifying \(unclassifiedIndices.count) documents…"
            var previousText: String? = nil

            for (attempt, index) in unclassifiedIndices.enumerated() {
                guard !Task.isCancelled else { return }
                let text = jobs[index].result?.text ?? ""

                let prompt = OCRPrompt.buildClassificationOnly(text: text, previousText: previousText, customPrompt: customPrompt)
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

        // Interactive Review: document segmentation (rotation + classification) review. Manual
        // modes skip it — the combined segment+tag window owns rotation, box/folder, and segmentation.
        if taggingMode.usesManualSegmentationUI {
            // no-op: handled in the combined manual window
        } else if (enableTagging && !passSourceTags) || enableCollectionSegmentation {
            await showFullSegmentationReview(files: files)
            guard !Task.isCancelled else { return }

            // Final confirmation of box/folder identifications
            await showBoxFolderConfirmation(files: files)
            guard !Task.isCancelled else { return }

            // Rebuild segments from user-confirmed classifications (excluding removed files)
            rebuildSegments(files: files)
        }

        guard !Task.isCancelled else { return }

        // Step 3: Tagging (mode-dependent)
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
                    enableSegmentJSON: enableSegmentJSON, preOCRed: true, files: files
                )
            case .none, .copySource:
                break
            }
        } else if passSourceTags {
            // For pre-OCRed input, source tags are on the input PDFs themselves
            for (index, url) in files.enumerated() {
                let sourceTags = MacOSTagger.readTags(from: url)
                if !sourceTags.isEmpty, let outputURL = outputURLMap[url] {
                    try? MacOSTagger.applyTags(sourceTags, to: outputURL)
                    jobs[index].appliedTags = sourceTags
                }
            }
        }

        guard !Task.isCancelled else { return }

        // Step 4: Collection Segmentation + name review (last step before completion)
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

        // Organize into collection folders (after all processing)
        if enableCollectionSegmentation && !collectionSegments.isEmpty {
            let segmenter2 = CollectionSegmenter()
            statusMessage = "Organizing \(collectionSegments.count) collections into folders…"
            do {
                try segmenter2.organizeOutput(
                    collections: collectionSegments,
                    outputDirectory: outputDirectory,
                    outputURLMap: outputURLMap
                )
                statusMessage = "Collections organized into \(collectionSegments.count) folders."
            } catch {
                statusMessage = "Error organizing collections: \(error.localizedDescription)"
            }
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
            if let gateway = currentGateway {
                response = try await classifyCallGateway(prompt: prompt, gateway: gateway)
            } else {
                switch provider {
                case .anthropic:
                    response = try await classifyCallAnthropic(prompt: prompt, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey)
                case .gemini:
                    response = try await classifyCallGemini(prompt: prompt, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey)
                case .mistral:
                    response = try await classifyCallMistral(prompt: prompt, apiKey: apiKey)
                }
            }
            let (classification, _, _) = OCRPrompt.parseResponse(response)
            return classification
        } catch {
            return nil
        }
    }
    private nonisolated func classifyCallGateway(prompt: String, gateway: GatewayConfig) async throws -> String {
        let client = OpenAICompatibleClient(baseURL: gateway.baseURL, apiKey: gateway.apiKey, modelID: gateway.modelID)
        return try await client.textCompletion(prompt: prompt, maxTokens: 64)
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
    func performBatchOCR(
        fileURLs: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        sendPreviousImage: Bool,
        enableTagging: Bool,
        enableCollectionSegmentation: Bool = false,
        enableSegmentJSON: Bool = true,
        confirmCollectionIDs: Bool = false,
        reviewDocumentSegmentation: Bool = false,
        customPrompt: String? = nil,
        imageScale: Double = 1.0
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
                batchId = try await client.submitBatch(fileURLs: fileURLs, sendPreviousImage: sendPreviousImage, customPrompt: customPrompt, imageScale: imageScale)
            case .mistral:
                let client = MistralBatchClient(apiKey: apiKey, model: model)
                batchId = try await client.submitBatch(fileURLs: fileURLs, imageScale: imageScale)
            case .gemini:
                let client = GeminiBatchClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                batchId = try await client.submitBatch(fileURLs: fileURLs, sendPreviousImage: sendPreviousImage, customPrompt: customPrompt, imageScale: imageScale)
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
            sendPreviousImage: sendPreviousImage, submittedAt: Date(),
            enableSegmentJSON: enableSegmentJSON,
            confirmCollectionIDs: confirmCollectionIDs,
            reviewDocumentSegmentation: reviewDocumentSegmentation,
            customPrompt: customPrompt
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
    func pollBatchUntilComplete(
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

            // Poll every 30s for the first ~5 min (few batches finish faster), then back off to 60s.
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
                            await processBatchResults(results, fileURLs: fileURLs, model: model, apiKey: apiKey, outputDirectory: outputDirectory)
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
                            await processBatchResults(results, fileURLs: fileURLs, model: model, apiKey: apiKey, outputDirectory: outputDirectory)
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
                    // Gemini may have multiple batch IDs (comma-separated) for large batches
                    let geminiBatchIds = batchId.components(separatedBy: ",")
                    var allComplete = true
                    var anyFailed = false
                    var stateDisplays: [String] = []

                    for singleBatchId in geminiBatchIds {
                        let status = try await client.checkStatus(batchName: singleBatchId)
                        let stateDisplay = status.state
                            .replacingOccurrences(of: "BATCH_STATE_", with: "")
                            .replacingOccurrences(of: "JOB_STATE_", with: "")
                            .lowercased()
                        stateDisplays.append(stateDisplay)

                        if !status.isComplete {
                            allComplete = false
                        } else {
                            let succeeded = status.state == "BATCH_STATE_SUCCEEDED" || status.state == "JOB_STATE_SUCCEEDED"
                            if succeeded {
                                if let inlineResults = status.inlineResults {
                                    await processBatchResults(inlineResults, fileURLs: fileURLs, model: model, apiKey: apiKey, outputDirectory: outputDirectory)
                                } else if let fileName = status.resultFileName {
                                    let results = try await client.retrieveResults(resultFileName: fileName)
                                    await processBatchResults(results, fileURLs: fileURLs, model: model, apiKey: apiKey, outputDirectory: outputDirectory)
                                }
                            } else {
                                anyFailed = true
                            }
                        }
                    }

                    if geminiBatchIds.count > 1 {
                        let completedCount = stateDisplays.filter { $0 == "succeeded" || $0 == "failed" || $0 == "cancelled" || $0 == "expired" }.count
                        statusMessage = "Batch processing… \(completedCount)/\(geminiBatchIds.count) chunks (\(stateDisplays.first ?? "unknown"))"
                    } else {
                        statusMessage = "Batch processing… (\(stateDisplays.first ?? "unknown"))"
                    }

                    if allComplete {
                        if anyFailed {
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
        apiKey: String,
        outputDirectory: URL
    ) async {
        for (customId, result) in results {
            let indexStr = customId.replacingOccurrences(of: "file-", with: "")
            guard let index = Int(indexStr), index < fileURLs.count else { continue }
            let url = fileURLs[index]
            // The batch path has no live network call to overlap with, but rotation is still
            // detected per the run's mode and merged before applying.
            let correction = await Self.detectRotation(
                imageURL: url, provider: model.provider, apiKey: apiKey,
                mode: Self.rotationModeForRun, gatewayConfig: currentGateway
            )
            let resolved = Self.mergeRotation(into: result, correction: correction)
            handleOCRResult(resolved, index: index, url: url, model: model, outputDirectory: outputDirectory)
        }

        // Mark any remaining processing jobs as failed (no result returned for them).
        // Report the filename from the job itself (matches the sibling loop above) rather than
        // cross-indexing fileURLs, so this stays correct even if the arrays ever diverge.
        for i in jobs.indices where jobs[i].status == .processing {
            jobs[i].status = .failed
            failedFiles.append(jobs[i].sourceURL.lastPathComponent)
        }
    }
    func performOCRPhase(
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
                sendPreviousImage: segmentationContext.sendPreviousImage,
                customPrompt: segmentationContext.customPrompt,
                imageScale: segmentationContext.imageScale
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
        let gateway = currentGateway
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

            statusMessage = "OCR \(index + 1)/\(total)…" + Self.rateLimitSuffix
            var result = await Self.performOCRCall(
                imageURL: url,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                previousText: contextText,
                previousImageURL: contextImageURL,
                customPrompt: segmentationContext.customPrompt,
                imageScale: segmentationContext.imageScale,
                gatewayConfig: gateway
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
                    previousImageURL: nil,
                    customPrompt: segmentationContext.customPrompt,
                    imageScale: segmentationContext.imageScale,
                    gatewayConfig: gateway
                )
            }

            handleOCRResult(result, index: index, url: url, model: model, outputDirectory: outputDirectory)
            previousText = result.text
            previousImageURL = url

            progress = Double(index + 1) / Double(total) * 0.7
            statusMessage = "OCR \(index + 1)/\(total) complete"
        }
    }
    private func performOCRParallel(
        fileURLs: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        sendPreviousImage: Bool,
        customPrompt: String? = nil,
        imageScale: Double = 1.0
    ) async {
        let total = fileURLs.count
        let gateway = currentGateway
        let concurrency = max(1, Self.ocrWorkerCount)
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
                        previousText: nil, previousImageURL: prevImageURL,
                        customPrompt: customPrompt, imageScale: imageScale,
                        gatewayConfig: gateway
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
                statusMessage = "OCR \(completed)/\(total) complete (parallel)" + Self.rateLimitSuffix

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
                            previousText: nil, previousImageURL: prevImageURL,
                            customPrompt: customPrompt, imageScale: imageScale,
                            gatewayConfig: gateway
                        )
                        return (idx, result)
                    }
                }
            }
        }
    }
    func handleOCRResult(_ result: OCRResult, index: Int, url: URL, model: LLMModel, outputDirectory: URL) {
        guard index >= 0 && index < jobs.count else {
            print("handleOCRResult: index \(index) out of range (jobs.count = \(jobs.count))")
            return
        }
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
        try? pdfGen.generate(imageURL: url, result: result, model: model, outputURL: outputURL, originalFileName: sourceURL.lastPathComponent, gatewayDisplayName: currentGateway?.displayName, pdfImageMB: Self.pdfImageMB)
        // Map by original source URL so tagging/collection segmentation can find it
        outputURLMap[sourceURL] = outputURL
        // Copy source tags to output PDF if pass-through mode is enabled
        if passSourceTags {
            let sourceTags = MacOSTagger.readTags(from: sourceURL)
            if !sourceTags.isEmpty {
                try? MacOSTagger.applyTags(sourceTags, to: outputURL)
                jobs[index].appliedTags = sourceTags
            }
        }
        // Persist result for resume-after-restart
        saveResultToPendingRun(index: index, result: result)
    }
    static func isTimeoutError(_ result: OCRResult) -> Bool {
        if result.errorMessage?.lowercased().contains("timed out") == true
            || result.errorCode?.lowercased().contains("timeout") == true { return true }
        // Providers also surface timeouts as HTTP 408 (Request Timeout) / 504 (Gateway Timeout)
        // without those words. Excludes 503 (overload) — NetworkSession already retries/backs those off,
        // and this drives a bare one-shot retry (max one extra attempt per file), so no double-counting.
        if let code = result.errorCode, code == "408" || code == "504" { return true }
        return false
    }
    /// Single-image OCR + concurrent rotation detection, merged into one result. Reused by the
    /// Live Capture streaming coordinator (reads `rotationModeForRun`, set before the run).
    nonisolated static func performOCRCall(
        imageURL: URL,
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        previousText: String?,
        previousImageURL: URL?,
        customPrompt: String? = nil,
        imageScale: Double = 1.0,
        gatewayConfig: GatewayConfig? = nil
    ) async -> OCRResult {
        // Start rotation detection concurrently with the network OCR call. Both are async, so
        // the extra rotation work overlaps the OCR round-trip and adds little wall-clock time.
        // The detected correction overrides the OCR prompt's own rotation guess.
        async let rotationCorrection = detectRotation(
            imageURL: imageURL, provider: provider, apiKey: apiKey,
            mode: rotationModeForRun, gatewayConfig: gatewayConfig
        )

        // The incoming `imageScale` is the size-target slider fraction; convert to a per-file
        // dimension scale (larger files reduced more; average/small files left full-res).
        let scale = targetDimensionScale(forFileAt: imageURL, sizeFraction: imageScale)

        let networkResult: OCRResult
        do {
            if let gateway = gatewayConfig {
                let client = OpenAICompatibleClient(baseURL: gateway.baseURL, apiKey: gateway.apiKey, modelID: gateway.modelID)
                networkResult = try await client.ocr(imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL, customPrompt: customPrompt, imageScale: scale)
            } else {
                switch provider {
                case .anthropic:
                    let client = AnthropicClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                    networkResult = try await client.ocr(imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL, customPrompt: customPrompt, imageScale: scale)
                case .gemini:
                    let client = GeminiClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                    networkResult = try await client.ocr(imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL, customPrompt: customPrompt, imageScale: scale)
                case .mistral:
                    let client = MistralClient(apiKey: apiKey, model: model)
                    networkResult = try await client.ocr(imageURL: imageURL, previousText: previousText, imageScale: scale)
                }
            }
        } catch {
            _ = await rotationCorrection  // let the concurrent task finish
            return OCRResult(text: nil, classification: nil, errorMessage: error.localizedDescription, errorCode: nil)
        }

        // Override rotation with the detected correction when OCR produced text and a
        // correction was found; otherwise keep the LLM prompt's parsed rotation.
        return mergeRotation(into: networkResult, correction: await rotationCorrection)
    }
    /// Detect the clockwise correction for an image per the run's rotation mode, with LLM
    /// modes falling back to local Vision when unavailable. Runs off the main actor.
    nonisolated static func detectRotation(
        imageURL: URL,
        provider: LLMProvider,
        apiKey: String,
        mode: RotationMode,
        gatewayConfig: GatewayConfig?
    ) async -> Int? {
        switch mode {
        case .off:
            return nil
        case .localVision:
            return await RotationDetector.detectCorrection(imageURL: imageURL)
        case .llmSingle, .llmMajority:
            if let c = await LLMRotationDetector.detectCorrection(
                imageURL: imageURL, provider: provider, apiKey: apiKey,
                orderings: mode.orderings, gatewayConfig: gatewayConfig
            ) {
                return c
            }
            // Fall back to local Vision if the LLM path is unavailable or fails.
            return await RotationDetector.detectCorrection(imageURL: imageURL)
        }
    }
    /// Replace a result's rotation with the detected correction when the result has text and
    /// a correction was found; otherwise return the result unchanged.
    private nonisolated static func mergeRotation(into result: OCRResult, correction: Int?) -> OCRResult {
        guard result.text != nil, let rot = correction else { return result }
        return OCRResult(
            text: result.text,
            classification: result.classification,
            rotationDegrees: rot,
            errorMessage: result.errorMessage,
            errorCode: result.errorCode
        )
    }
    private func isRetryableError(_ result: OCRResult?) -> Bool {
        guard let result = result, result.text == nil else { return false }
        let code = result.errorCode ?? ""
        let msg = (result.errorMessage ?? "").lowercased()
        return code == "503" || code == "429" || code == "529"
            || msg.contains("high use") || msg.contains("high demand")
            || msg.contains("unavailable") || msg.contains("overloaded")
            || msg.contains("rate limit")
    }
    func retryHighUseFailures(
        fileURLs: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL
    ) async {
        let retryIndices = jobs.indices.filter { isRetryableError(jobs[$0].result) }
        guard !retryIndices.isEmpty else { return }
        let gateway = currentGateway

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
                previousImageURL: nil,
                gatewayConfig: gateway
            )

            // Update failed files list if retry succeeded
            if result.text != nil {
                let sourceFileName = jobs[index].sourceURL.lastPathComponent
                failedFiles.removeAll { $0 == sourceFileName }
            }
            handleOCRResult(result, index: index, url: url, model: model, outputDirectory: outputDirectory)
        }
    }
    /// Run a single OCR call at a given image scale for resolution testing. Public so the UI can call it.
    nonisolated static func performResolutionTestCall(
        imageURL: URL, provider: LLMProvider, model: LLMModel,
        thinkingLevel: ThinkingLevel?, apiKey: String,
        imageScale: Double,
        gatewayConfig: GatewayConfig? = nil
    ) async -> OCRResult {
        await performOCRCall(
            imageURL: imageURL, provider: provider, model: model,
            thinkingLevel: thinkingLevel, apiKey: apiKey,
            previousText: nil, previousImageURL: nil,
            imageScale: imageScale,
            gatewayConfig: gatewayConfig
        )
    }
}
