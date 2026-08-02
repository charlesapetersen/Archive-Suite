import Foundation
import UserNotifications
import os

extension OCRProcessor {
    /// Resolve the settings used by PDF generation. Every production path injects its run's immutable
    /// snapshot; W16.cfg6 replaced the `pdfImageMB`/`textColumns` statics that used to answer otherwise
    /// with a fresh `runSizing()` read, so the no-snapshot case can be *current* but never *stale*.
    /// The read is lazy — an injected config short-circuits it, so the per-file loops never touch
    /// UserDefaults.
    nonisolated static func pdfGenerationSettings(
        for runConfig: SessionProcessingConfig?
    ) -> (imageMB: Double, textColumns: Int) {
        guard let runConfig else {
            let sizing = SessionProcessingConfig.runSizing()
            return (sizing.pdfImageMB, sizing.textColumns)
        }
        return (runConfig.pdfImageMB, runConfig.textColumns)
    }

    /// Resolve the bounded worker count for OCR scheduling. Same W16.cfg6 rule as above: injected
    /// snapshot first, then a pure defaults read — never a process-global left over from another run.
    nonisolated static func schedulingWorkerCount(for runConfig: SessionProcessingConfig?) -> Int {
        SessionProcessingConfig.clampOCRWorkers(
            runConfig?.ocrWorkerCount ?? SessionProcessingConfig.runSizing().ocrWorkerCount)
    }

    /// The two values `performOCRCall` requires, resolved once from the run's injected snapshot.
    ///
    /// W16.cfg6 made those parameters non-optional, so this is the single place the no-snapshot case is
    /// decided — one seam to audit instead of eleven `?? someStatic` expressions scattered across the
    /// call sites. `nonisolated` so the detached OCR workers can resolve it without hopping actors.
    nonisolated static func ocrCallValues(
        for runConfig: SessionProcessingConfig?
    ) -> (rotationMode: RotationMode, standardImageMB: Double) {
        guard let runConfig else {
            return (SessionProcessingConfig.defaultRotationMode(),
                    SessionProcessingConfig.runSizing().standardImageMB)
        }
        return (runConfig.rotationMode, runConfig.standardImageMB)
    }

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
        customPrompt: String? = nil,
        runConfig: SessionProcessingConfig? = nil
    ) async {
        let total = files.count
        let runOutputSettings = lateRunOutputSettings(for: runConfig)
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
        if runOutputSettings.taggingMode.usesManualSegmentationUI {
            // no-op: handled in the combined manual window
        } else if (enableTagging && !passSourceTags) || enableCollectionSegmentation {
            await showFullSegmentationReview(files: files, runConfig: runConfig)
            guard !Task.isCancelled else { return }

            // Final confirmation of box/folder identifications
            await showBoxFolderConfirmation(files: files, runConfig: runConfig)
            guard !Task.isCancelled else { return }

            // Rebuild segments from user-confirmed classifications (excluding removed files)
            rebuildSegments(files: files)
        }

        guard !Task.isCancelled else { return }

        // Step 3: Tagging (mode-dependent)
        if enableTagging && !passSourceTags {
            switch runOutputSettings.taggingMode {
            case .automatic:
                await performAutomaticTaggingWithReview(
                    provider: provider, model: model, thinkingLevel: thinkingLevel,
                    apiKey: apiKey, outputDirectory: outputDirectory,
                    enableSegmentJSON: enableSegmentJSON, files: files,
                    runConfig: runConfig
                )
            case .autoDate:
                await performManualTaggingPhase(
                    mode: runOutputSettings.taggingMode, provider: provider, model: model,
                    thinkingLevel: thinkingLevel, apiKey: apiKey,
                    outputDirectory: outputDirectory, enableSegmentJSON: enableSegmentJSON,
                    runConfig: runConfig
                )
            case .human, .autoDateManualSeg:
                await performManualSegmentAndTag(
                    autoDate: runOutputSettings.taggingMode.autoFillsDate,
                    provider: provider, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey,
                    outputDirectory: outputDirectory,
                    enableSegmentJSON: enableSegmentJSON, preOCRed: true, files: files,
                    runConfig: runConfig
                )
            case .none, .copySource:
                break
            }
        } else if passSourceTags {
            // For pre-OCRed input, source tags are on the input PDFs themselves
            for (index, url) in files.enumerated() {
                guard let sourceTags = try? MacOSTagger.readTags(from: url), !sourceTags.isEmpty,
                      let outputURL = outputURLMap[url] else { continue }
                // Copy-source pass-through: write the source's tags VERBATIM and leave the Finder
                // label untouched. `false` is unconditional here, not `taggingMode.stampsUnread` —
                // `passSourceTags` implies `.copySource` (OCRView.swift:27), so they agree today, but
                // the verbatim semantics are what this path requires regardless of the run's mode.
                tagOutput(sourceTags, at: outputURL, source: url, stampUnread: false)
                jobs[index].appliedTags = sourceTags
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
                reviewDocumentSegmentation: false,
                runConfig: runConfig
            )

            applyBoxFolderLabelTags(enableTagging: enableTagging, runConfig: runConfig)
        }

        // Organize into collection folders (after all processing)
        if enableCollectionSegmentation && !collectionSegments.isEmpty {
            let segmenter2 = CollectionSegmenter()
            statusMessage = "Organizing \(collectionSegments.count) collections into folders…"
            do {
                try segmenter2.organizeOutput(
                    collections: collectionSegments,
                    outputDirectory: outputDirectory,
                    outputURLMap: outputURLMap,
                    moveSiblingImages: runOutputSettings.exportOriginals
                )
                statusMessage = "Collections organized into \(collectionSegments.count) folders."
            } catch {
                statusMessage = "Error organizing collections: \(error.localizedDescription)"
            }
        }
    }

    /// The "re-OCR multi-page PDF" mode: for each input PDF, render EVERY page to an image, OCR each
    /// page image with the LLM, then rebuild ONE output PDF whose pages alternate image, OCR-text,
    /// image, OCR-text, … (each source page → its image page + a selectable OCR-text page). Distinct
    /// from `preOCRedInput`, which extracts the existing embedded text layer instead of re-OCRing the
    /// rendered page. This mode is a pure document transform: it writes only the output PDF and applies
    /// NO Finder tags (tagging/segmentation integration is a deliberate follow-up). The output never
    /// overwrites the input — `uniqueOutputURL` reserves a non-colliding path (`name (2).pdf` when the
    /// output directory coincides with the input's).
    ///
    /// `ocrOverride` is a $0/key-free TEST SEAM (mirrors `MergeSafetyTestDriver`'s injected writer):
    /// when set, it supplies each page's `OCRResult` in place of the live network call, so the whole
    /// render→generate→merge assembly is covered headlessly. Production passes nil.
    func performMultiPagePDFReOCR(
        files: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        customPrompt: String? = nil,
        gatewayConfig: GatewayConfig? = nil,
        localAgent: LocalAgentConfig? = nil,
        runConfig: SessionProcessingConfig? = nil,
        ocrOverride: (@Sendable (URL) async -> OCRResult)? = nil
    ) async {
        let total = files.count
        guard total > 0 else { return }
        let ocrRun = Self.ocrCallValues(for: runConfig)
        let pdfSettings = Self.pdfGenerationSettings(for: runConfig)
        let pdfMB = pdfSettings.imageMB
        let txtCols = pdfSettings.textColumns
        let gatewayName = currentGateway?.displayName

        for (index, pdfURL) in files.enumerated() {
            guard !Task.isCancelled else { cleanupTempFiles(); return }
            jobs[index].status = .processing
            statusMessage = "Rendering \(pdfURL.lastPathComponent)…"

            // 1. Render every page to a temp JPEG. nil = render failure; renderAllPages fails loud
            //    (no partial set) so we never silently drop an archival page.
            guard let pageImages = PDFToImageConverter.renderAllPages(of: pdfURL), !pageImages.isEmpty else {
                // WHY THIS SETS AN errorMessage (2026-07-29 bug fix). This route is chosen when the run
                // contains ANY multi-page PDF (`OCRProcessor+Pipeline.swift` `autoReOCR`), so a non-PDF
                // sibling — an ordinary .jpg — lands here too and `renderAllPages` returns nil for it
                // (`PDFDocument(url:)` is nil for a JPEG). The route's comment says such a sibling "fails
                // render loudly", but it did NOT: leaving `result.errorMessage` nil makes the UI render
                // `ItemState.ocrEmpty` -> **"No OCR text"** (`OCRView+FileRowView.swift:99`), which blames
                // the model for what is actually a routing skip, and no output file is written. An owner hit
                // exactly this: two .jpg files dropped alongside one 3-page PDF vanished with "No OCR text".
                // Setting a precise, actionable reason is what makes the documented "loudly" true.
                let isPDF = pdfURL.pathExtension.lowercased() == "pdf"
                let reason = isPDF
                    ? "This PDF could not be rendered, so it was not re-OCR'd. The file may be corrupt, "
                      + "encrypted, or password-protected."
                    : "Skipped: not a PDF. This run also contained a multi-page PDF, which routes the whole "
                      + "run through the multi-page re-OCR transform — a path that can only process PDFs. "
                      + "Process images in a separate run (or remove the multi-page PDF from this one)."
                jobs[index].result = OCRResult(text: nil, classification: nil,
                                               errorMessage: reason,
                                               errorCode: isPDF ? "pdf_render_failed" : "not_a_pdf_in_reocr_run")
                jobs[index].status = .failed
                if !failedFiles.contains(pdfURL.lastPathComponent) { failedFiles.append(pdfURL.lastPathComponent) }
                statusMessage = isPDF
                    ? "Could not render \(pdfURL.lastPathComponent)."
                    : "Skipped \(pdfURL.lastPathComponent) — not a PDF (multi-page re-OCR run)."
                progress = Double(index + 1) / Double(total)
                continue
            }

            // 2. OCR each page image in order (sequential; the prior page's text is carried as light
            //    continuation context, matching the single-image pipeline).
            var pageResults: [OCRResult] = []
            pageResults.reserveCapacity(pageImages.count)
            for (p, img) in pageImages.enumerated() {
                if Task.isCancelled {
                    for u in pageImages { try? FileManager.default.removeItem(at: u) }
                    cleanupTempFiles()
                    return
                }
                statusMessage = "OCR \(pdfURL.lastPathComponent) — page \(p + 1)/\(pageImages.count)…"
                let result: OCRResult
                if let ocrOverride {
                    result = await ocrOverride(img)
                } else {
                    result = await Self.performOCRCall(
                        imageURL: img, provider: provider, model: model,
                        thinkingLevel: thinkingLevel, apiKey: apiKey,
                        previousText: pageResults.last?.text, previousImageURL: nil,
                        customPrompt: customPrompt, gatewayConfig: gatewayConfig, localAgent: localAgent,
                        rotationMode: ocrRun.rotationMode,
                        standardImageMB: ocrRun.standardImageMB
                    )
                }
                pageResults.append(result)
                progress = (Double(index) + Double(p + 1) / Double(pageImages.count)) / Double(total)
            }

            // 3+4. Build a per-page (image + text) PDF for each page, then merge them into ONE
            //    alternating output PDF — off the main actor (CPU-heavy; matches the standard path's
            //    M3 detach). mergeDocumentPDFs interleaves each source's [image, text] pages, so the
            //    result is image1, text1, image2, text2, …. uniqueOutputURL guards against clobbering
            //    the input PDF or another output from this run.
            let baseName = pdfURL.deletingPathExtension().lastPathComponent
            let outputURL = uniqueOutputURL(baseName: baseName, ext: "pdf", in: outputDirectory, for: pdfURL)
            let originalName = pdfURL.lastPathComponent
            let pageWork: [(image: URL, result: OCRResult)] = Array(zip(pageImages, pageResults))
            let genModel = model
            // W23.h5-fu — also report whether ANY page fell back to the placeholder image page; the
            // merge copies those pages verbatim, so one undecodable page makes the merged output a
            // partially scan-less PDF and the operator has to be told.
            let assembly: (ok: Bool, anyPlaceholder: Bool) = await Task.detached(priority: .utility) {
                let gen = PDFGenerator()
                let fm = FileManager.default
                var perPagePDFs: [URL] = []
                var anyPlaceholder = false
                defer { for u in perPagePDFs { try? fm.removeItem(at: u) } }
                do {
                    for page in pageWork {
                        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                        let outcome = try gen.generate(imageURL: page.image, result: page.result, model: genModel,
                                                       outputURL: tmp, originalFileName: originalName,
                                                       gatewayDisplayName: gatewayName, pdfImageMB: pdfMB,
                                                       textColumns: txtCols)
                        if outcome.isPlaceholder { anyPlaceholder = true }
                        perPagePDFs.append(tmp)
                    }
                    try gen.mergeDocumentPDFs(sourcePDFs: perPagePDFs, outputURL: outputURL)
                    return (true, anyPlaceholder)
                } catch {
                    os_log(.error, "multi-page re-OCR PDF write failed for %{public}@: %{public}@",
                           originalName, error.localizedDescription)
                    return (false, false)
                }
            }.value
            let ok = assembly.ok

            // Page-image temps are consumed either way.
            for u in pageImages { try? FileManager.default.removeItem(at: u) }

            if ok {
                // Map by the original source URL so downstream consumers (log, view-text) find it. Only
                // set on a confirmed write — never a phantom entry pointing at a nonexistent file.
                outputURLMap[pdfURL] = outputURL
                recordImagePage(assembly.anyPlaceholder ? .placeholder : .embedded, forSource: pdfURL)
                let combinedText = pageResults.compactMap { $0.text }.joined(separator: "\n\n")
                jobs[index].result = OCRResult(
                    text: combinedText.isEmpty ? nil : combinedText,
                    classification: pageResults.first?.classification,
                    errorMessage: combinedText.isEmpty ? "No text returned by model." : nil,
                    errorCode: nil
                )
                jobs[index].classification = pageResults.first?.classification
                jobs[index].status = .succeeded
                failedFiles.removeAll { $0 == pdfURL.lastPathComponent }
            } else {
                // The generate/merge threw; the only record used to be an os_log (which is not reliably
                // retrievable) plus a nil errorMessage that the UI mislabels as "No OCR text". Give the
                // operator the real reason — this is an OUTPUT-write failure, not an empty OCR result.
                jobs[index].result = OCRResult(
                    text: nil, classification: nil,
                    errorMessage: "OCR succeeded but the output PDF could not be written or merged. "
                                + "Check that the output folder exists and is writable, and that there is free disk space.",
                    errorCode: "pdf_write_failed")
                jobs[index].status = .failed
                if !failedFiles.contains(pdfURL.lastPathComponent) { failedFiles.append(pdfURL.lastPathComponent) }
            }
            progress = Double(index + 1) / Double(total)
            statusMessage = "Processed \(index + 1)/\(total) PDF\(total == 1 ? "" : "s")…"
        }
        cleanupTempFiles()
    }

    /// A per-run output URL for `sourceURL` that never silently overwrites a DIFFERENT source's output.
    /// Two inputs sharing a base filename (common with per-folder archive numbering — e.g. two 00001.jpg
    /// from different boxes) would otherwise both map to <dir>/<base>.pdf and clobber each other, losing
    /// one archival page's OCR with no error. Re-processing the SAME source reuses its already-assigned
    /// path (idempotent on retry). @MainActor-serial (handleOCRResult runs on the collection loop), so the
    /// read-then-reserve needs no locking.
    func uniqueOutputURL(baseName: String, ext: String, in dir: URL, for sourceURL: URL) -> URL {
        if let existing = outputURLMap[sourceURL] { return existing }
        // Lazy rebuild after a reset (outputURLMap populated by resume-restore but cache was cleared).
        if _takenOutputPaths.isEmpty && !outputURLMap.isEmpty {
            _takenOutputPaths = Set(outputURLMap.values.map(OutputFileSafety.pathKey))
        }
        let preferred = dir.appendingPathComponent(baseName + "." + ext)
        return OutputFileSafety.reserveUniqueDestination(
            preferred: preferred,
            reservedPaths: &_takenOutputPaths
        )
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
            // Backend precedence (mirrors the OCR / text seams): the Local Agent CLI wins, then the
            // gateway, then the direct provider path.
            if let localAgent = currentLocalAgent {
                response = try await classifyCallLocalAgent(prompt: prompt, config: localAgent)
            } else if let gateway = currentGateway {
                response = try await classifyCallGateway(prompt: prompt, gateway: gateway)
            } else {
                switch provider {
                case .anthropic:
                    response = try await classifyCallAnthropic(prompt: prompt, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey)
                case .gemini:
                    response = try await classifyCallGemini(prompt: prompt, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey)
                case .mistral:
                    response = try await classifyCallMistral(prompt: prompt, apiKey: apiKey)
                case .openai:
                    response = try await classifyCallOpenAI(prompt: prompt, model: model, apiKey: apiKey)
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
    private nonisolated func classifyCallLocalAgent(prompt: String, config: LocalAgentConfig) async throws -> String {
        try await LocalAgentClient(config: config).textCompletion(prompt: prompt, maxTokens: 64)
    }
    private nonisolated func classifyCallAnthropic(prompt: String, model: LLMModel, thinkingLevel: ThinkingLevel?, apiKey: String) async throws -> String {
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        let body: [String: Any] = [
            "model": model.id, "max_tokens": 64,
            "messages": [["role": "user", "content": prompt]]
        ]
        // No extended thinking on the tiny classification call: a one-word label needs no
        // reasoning, and Anthropic rejects any request where max_tokens (64) <= budget_tokens
        // (which silently disabled all Anthropic classification when thinking was on). This
        // matches the tagging/date calls, which also omit thinking. thinkingLevel is unused here.
        _ = thinkingLevel
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await NetworkSession.data(for: request, policy: .nonIdempotent)
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
        let (data, _) = try await NetworkSession.data(for: request, policy: .nonIdempotent)
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
        let (data, _) = try await NetworkSession.data(for: request, policy: .nonIdempotent)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return "" }
        return content
    }
    private nonisolated func classifyCallOpenAI(prompt: String, model: LLMModel, apiKey: String) async throws -> String {
        let client = OpenAICompatibleClient.openAI(model: model, apiKey: apiKey)
        return try await client.textCompletion(prompt: prompt, maxTokens: 64)
    }
    func performBatchOCR(
        fileURLs: [URL],
        originalFiles: [URL],
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
        imageScale: Double = 1.0,
        runConfig: SessionProcessingConfig? = nil
    ) async {
        let total = fileURLs.count

        // This submission's own money count and cause, cleared before the first create (W16.bat3-fu2).
        // `batchPollInterrupted` is the standing warning about what happens when paid-batch state is left
        // to carry over between runs — a stale total here would put a PREVIOUS batch's jobs into this one's
        // interruption message, which is the same class of lie in the other direction.
        paidJobsCreatedThisSubmission = []
        lastPaidBatchInterruptionReport = nil

        // Mark all as processing
        for i in 0..<total { jobs[i].status = .processing }

        // Submit batch
        statusMessage = "Submitting batch (\(total) files)…"

        // Write a complete recovery journal BEFORE the first irreversible provider request. The server ID
        // list starts empty and is advanced immediately after each create response. If a response is lost,
        // the retained `submissionComplete == false` journal makes that ambiguity visible instead of
        // silently starting a second paid run.
        let submittedAt = Date()
        let immutableFingerprint = Self.runFingerprint(
            files: originalFiles, outputDirectory: outputDirectory, taggingMode: taggingMode,
            enableTagging: enableTagging, batchMode: true, preserveInputOrder: true)
        let initialPendingBatch = PendingBatch(
            batchId: "", provider: provider, model: model,
            thinkingLevel: thinkingLevel, fileURLs: originalFiles,
            outputDirectory: outputDirectory, enableTagging: enableTagging,
            enableCollectionSegmentation: enableCollectionSegmentation,
            sendPreviousImage: sendPreviousImage, submittedAt: submittedAt,
            enableSegmentJSON: enableSegmentJSON,
            confirmCollectionIDs: confirmCollectionIDs,
            reviewDocumentSegmentation: reviewDocumentSegmentation,
            customPrompt: customPrompt,
            taggingMode: taggingMode,
            runFingerprint: immutableFingerprint,
            exportOriginals: exportOriginals,
            lifecycleVersion: PendingBatch.currentLifecycleVersion,
            submittedChunkIds: [], consumedChunkIds: [],
            submissionComplete: false, completedResults: [:], completedOutputPaths: [:]
        )
        guard let persistedInitialBatch = Self.savePendingBatch(initialPendingBatch) else {
            statusMessage = "Could not create a safe paid-batch journal. No batch requests were sent."
            batchPollInterrupted = true
            isProcessing = false
            return
        }
        activePendingBatch = persistedInitialBatch
        activeBatch = BatchContext(
            batchId: "", apiKey: apiKey, model: model,
            thinkingLevel: thinkingLevel, provider: provider)

        let batchId: String
        do {
            switch provider {
            case .anthropic:
                let client = AnthropicBatchClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                batchId = try await client.submitBatch(fileURLs: fileURLs, sendPreviousImage: sendPreviousImage, customPrompt: customPrompt, imageScale: imageScale)
                guard recordSubmittedBatchChunk(batchId) else {
                    throw OCRError.networkError("Could not persist the submitted Anthropic batch ID")
                }
            case .mistral:
                let client = MistralBatchClient(apiKey: apiKey, model: model)
                batchId = try await client.submitBatch(fileURLs: fileURLs, imageScale: imageScale)
                guard recordSubmittedBatchChunk(batchId) else {
                    throw OCRError.networkError("Could not persist the submitted Mistral batch ID")
                }
            case .gemini:
                let client = GeminiBatchClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                batchId = try await client.submitBatch(
                    fileURLs: fileURLs, sendPreviousImage: sendPreviousImage,
                    customPrompt: customPrompt, imageScale: imageScale
                ) { [weak self] chunkId in
                    guard let self else {
                        throw OCRError.networkError("Batch owner was released during submission")
                    }
                    guard await self.recordSubmittedBatchChunk(chunkId) else {
                        throw OCRError.networkError("Could not persist a submitted Gemini chunk ID")
                    }
                }
            case .openai:
                // Unreachable: `supportsBatch == false` gates OpenAI out of the batch path (Pipeline
                // `batchMode && provider.supportsBatch`). Defensive arm keeps the switch exhaustive;
                // Phase 4 adds a real OpenAIBatchClient. The throw is caught below → jobs marked failed.
                throw OCRError.networkError("OpenAI batch is not supported in this version")
            }
            // `performBatchOCR`'s FIFTH interrupted exit (W16.bat3-fu). The batch is PAID by the time
            // control reaches here and every acknowledged chunk ID is already journaled — only the
            // "submission finished" marker failed to persist, or Stop closed the journal out from under it.
            // Back in `processFiles` this exit is judged purely on `batchPollInterrupted`, so say so
            // explicitly rather than inheriting the flag a PREVIOUS run left set (nothing resets it at the
            // start of a run). `markBatchSubmissionComplete()` now reports itself on both of its failure
            // paths; this is the belt that keeps the exit correct if a future edit adds a quiet third.
            guard markBatchSubmissionComplete() else {
                batchPollInterrupted = true
                isProcessing = false
                return
            }
        } catch {
            // A non-idempotent create can be accepted server-side even when its response is lost. Keep
            // the pre-submit journal in every failure case; acknowledged IDs remain resumable, while an
            // empty ID list explicitly records an unknown outcome and prevents an automatic duplicate.
            //
            // What the operator is told is composed from measurements rather than from `activePendingBatch`
            // (W16.bat3-fu2). This catch's commonest cause is a Stop pressed mid-submit — the chunk callback
            // throws as soon as `recordSubmittedBatchChunk` finds the journal closed — and `cancel()` has
            // nil'd that journal by then, so reading the count out of it said "no server ID was received"
            // about a batch already billed for several, and "the journal was kept" without looking.
            NSLog("[ArchiveProcessor] paid-batch submission interrupted: %@", error.localizedDescription)
            reportInterruptedBatchSubmission()
            return
        }

        // `batchId` is retained as the provider client's compatibility return value. The authoritative ID
        // list is the just-persisted journal (and must agree unless a future provider normalizes its ID).
        guard activePendingBatch?.batchId == batchId else {
            statusMessage = "Submitted batch IDs did not match the recovery journal. The journal was kept for review."
            batchPollInterrupted = true
            isProcessing = false
            return
        }
        statusMessage = "Batch submitted. Waiting for results…"

        // Poll for completion
        await pollBatchUntilComplete(
            batchId: batchId, provider: provider, model: model,
            thinkingLevel: thinkingLevel, apiKey: apiKey,
            fileURLs: fileURLs, outputDirectory: outputDirectory,
            runConfig: runConfig
        )

        // Keep the pending batch if polling was interrupted transiently, so it stays resumable.
        retirePaidBatchJournalIfPollCompleted()
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
        outputDirectory: URL,
        runConfig: SessionProcessingConfig? = nil
    ) async {
        var pollCount = 0
        var consecutiveErrors = 0
        var batchComplete = false
        batchPollInterrupted = false
        var consumedChunkIds = Set(activePendingBatch?.consumedChunkIds ?? [])
        // How many times a chunk has come back terminal-but-empty, and the chunks already given up on
        // (W16.bat1-fu). Poll-session state, deliberately not journaled: the give-up is terminal within
        // the run, so it never has to survive one — and a resume is the operator asking to look again.
        var emptyResultChecks: [String: Int] = [:]
        var emptyChunkIds: Set<String> = []
        let maxPolls = 1500   // safety backstop (~24h at these intervals) so a stuck/unknown state can't poll forever
        while !batchComplete {
            // Stop was pressed. The server-side job is PAID and may still be running, so this exit must
            // report itself INTERRUPTED like every other one: both callers decide the fate of the recovery
            // journal — the only local record of that job — from `batchPollInterrupted`, and a silent
            // `return` here had them delete it while `cancel()` told the operator it was kept (W16.bat3).
            guard !Task.isCancelled else { batchPollInterrupted = true; return }
            if pollCount >= maxPolls {
                statusMessage = "Batch timed out after \(pollCount) status checks — it's kept so you can resume it."
                batchPollInterrupted = true
                break
            }

            // Poll every 30s for the first ~5 min (few batches finish faster), then back off to 60s.
            let interval: Duration = pollCount < 10 ? .seconds(30) : .seconds(60)
            try? await Task.sleep(for: interval)
            pollCount += 1

            // The Stop that arrives during the wait, which is where nearly all of them land: `Task.sleep`
            // returns early on cancellation, so this is the guard a cancelled poll normally leaves through.
            // Same rule as the one at the top of the loop — the journal survives an interruption (W16.bat3).
            guard !Task.isCancelled else { batchPollInterrupted = true; return }

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
                            guard await processBatchResults(
                                results, fileURLs: fileURLs, model: model, apiKey: apiKey,
                                outputDirectory: outputDirectory, runConfig: runConfig) else { return }
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
                            guard await processBatchResults(
                                results, fileURLs: fileURLs, model: model, apiKey: apiKey,
                                outputDirectory: outputDirectory, runConfig: runConfig) else { return }
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
                    // New journals carry ordered IDs; legacy manifests retain their comma-separated IDs.
                    let geminiBatchIds = activePendingBatch?.effectiveChunkIds
                        ?? PendingBatch.parseChunkIDs(batchId)
                    var allComplete = true
                    var anyFailed = false
                    var stateDisplays: [String] = []

                    for singleBatchId in geminiBatchIds {
                        // Skip chunks whose results were already fetched + turned into PDFs on an earlier
                        // poll — otherwise every ~1-min poll re-downloads and re-processes (re-rotates,
                        // re-PDFs) every finished chunk until the slowest lands, multiplying cost + time.
                        // Count them as complete so allComplete still reflects the whole batch.
                        if consumedChunkIds.contains(singleBatchId) { stateDisplays.append("succeeded"); continue }
                        // Likewise for a chunk already given up on as empty (W16.bat1-fu): re-reading it
                        // every poll while slower chunks finish would just re-download nothing. It counts
                        // as terminal — its files fail in the completion sweep.
                        if emptyChunkIds.contains(singleBatchId) { stateDisplays.append("failed"); continue }
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
                                // Which arm the pages come from is decided in one pure place, because
                                // *emptiness* is the trap: an empty inline container used to take the
                                // inline arm, suppress the result-file fetch, and mark a paid chunk
                                // consumed with zero pages (W16.bat1-fu).
                                let results: [String: OCRResult]
                                switch GeminiBatchClient.resultsSource(for: status) {
                                case .inline(let inlineResults):
                                    results = inlineResults
                                case .file(let fileName):
                                    results = try await client.retrieveResults(resultFileName: fileName)
                                case .noneAvailable:
                                    results = [:]
                                }

                                // A finished chunk that hands back nothing is never consumed — the
                                // outcome is decided by a pure, pinned rule rather than inline here.
                                let emptyObservations: Int
                                if results.isEmpty {
                                    emptyObservations = (emptyResultChecks[singleBatchId] ?? 0) + 1
                                    emptyResultChecks[singleBatchId] = emptyObservations
                                } else {
                                    emptyObservations = 0
                                }

                                switch GeminiBatchClient.chunkOutcome(
                                    resultCount: results.count,
                                    emptyObservations: emptyObservations,
                                    limit: GeminiBatchClient.emptyResultCheckLimit
                                ) {
                                case .recheck:
                                    allComplete = false
                                    if !stateDisplays.isEmpty {
                                        stateDisplays[stateDisplays.count - 1] = "succeeded (awaiting results)"
                                    }
                                    continue

                                case .reportEmpty:
                                    // The grace is spent. This chunk is NOT marked consumed — nothing
                                    // was materialized from it — but the batch is still allowed to
                                    // complete: blocking it would strand every page that DID arrive,
                                    // and a chunk that produces nothing has to be terminal rather than
                                    // a run that can never end. The completion sweep below then gives
                                    // each of this chunk's files an explicit `no_result` failure with an
                                    // output record, which the retry pass can act on. Remembered so the
                                    // remaining polls don't re-fetch it while slower chunks finish.
                                    emptyChunkIds.insert(singleBatchId)
                                    statusMessage = "A finished batch chunk returned no pages after \(emptyObservations) checks. Its files are reported as failed; nothing was marked complete for it."
                                    NSLog("[ArchiveProcessor] paid-batch chunk %@ reported %@ with no readable results after %d checks; not consumed, its files fail",
                                          singleBatchId, status.state, emptyObservations)
                                    continue

                                case .materialize:
                                    let materialized = await processBatchResults(
                                        results, fileURLs: fileURLs, model: model, apiKey: apiKey,
                                        outputDirectory: outputDirectory, runConfig: runConfig)
                                    guard materialized, markBatchChunkConsumed(singleBatchId) else { return }
                                    consumedChunkIds.insert(singleBatchId)
                                    emptyResultChecks[singleBatchId] = nil
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

                case .openai:
                    // Unreachable: OpenAI never enters the batch path (`supportsBatch == false`, and
                    // submitBatch throws for it). Keeps the switch exhaustive; Phase 4 adds a real poll.
                    batchComplete = true
                }
                consecutiveErrors = 0   // this poll cycle completed without throwing
            } catch {
                consecutiveErrors += 1
                statusMessage = "Error checking batch: \(error.localizedDescription). Retrying… (attempt \(consecutiveErrors))"
                // A persistently-failing status check (e.g. 404 after the batch expired/was deleted,
                // or an unrecognized terminal state) must not poll forever.
                if consecutiveErrors >= 10 {
                    // Likely a transient network outage, not a dead batch — keep it resumable rather than
                    // marking every file failed and letting the caller delete the pending batch (which
                    // would strand a completed, already-paid-for server-side batch with no way back).
                    statusMessage = "Lost the connection while checking the batch (\(consecutiveErrors) tries). It's kept — use Resume pending batch when you're back online."
                    batchPollInterrupted = true
                    break
                }
            }
        }

        // If polling was interrupted transiently (network streak / timeout), leave still-processing jobs
        // as-is (do NOT mark them failed) and return with the pending batch preserved — the caller keeps
        // it resumable. Only sweep to failure on a genuine terminal completion.
        guard !batchPollInterrupted else { return }
        // The whole batch is complete: any job still `.processing` got no result.
        // Done ONCE here (not per-chunk in processBatchResults) so multi-chunk Gemini batches don't
        // falsely fail files whose chunk finished on a later poll. Give each a proper failure output
        // with a specific reason — in particular, distinguish a locally-unreadable source image
        // (silently skipped at submit time) from "the provider returned no result for this file".
        for i in jobs.indices where jobs[i].status == .processing {
            let url = jobs[i].sourceURL
            let readable = ImageEncoding.loadImageAsJPEG(url: url, scale: 1.0) != nil
            let synthetic = OCRResult(
                text: nil, classification: nil, rotationDegrees: 0,
                errorMessage: readable ? "No result was returned for this file by the batch."
                                       : "Could not read the source image (unsupported or corrupt file).",
                errorCode: readable ? "no_result" : "image_unreadable"
            )
            guard await handleOCRResult(
                synthetic, index: i, url: url, model: model,
                outputDirectory: outputDirectory, runConfig: runConfig) else { return }
        }
    }
    private func processBatchResults(
        _ results: [String: OCRResult],
        fileURLs: [URL],
        model: LLMModel,
        apiKey: String,
        outputDirectory: URL,
        runConfig: SessionProcessingConfig? = nil
    ) async -> Bool {
        // Parse valid entries upfront so the task group doesn't need to touch fileURLs.
        // A resumed paid batch restores these keys from disk. Skip them before output-path allocation so
        // re-fetching an incompletely acknowledged chunk cannot create duplicate "(2)" PDFs.
        let alreadyCompleted = Set(activePendingBatch?.completedResults.keys.map { $0 } ?? [])
        let entries: [(index: Int, url: URL, result: OCRResult)] = results.compactMap { (customId, result) in
            let indexStr = customId.replacingOccurrences(of: "file-", with: "")
            guard !alreadyCompleted.contains(indexStr),
                  let index = Int(indexStr), index >= 0, index < fileURLs.count else { return nil }
            return (index, fileURLs[index], result)
        }
        guard !entries.isEmpty else { return true }

        // M4 perf fix: detect rotation concurrently (bounded) instead of serially.
        // handleOCRResult runs back on MainActor (serialized) for state updates;
        // its PDF gen is off-MainActor via M3.
        let rotationMode = Self.ocrCallValues(for: runConfig).rotationMode
        let gateway = currentGateway
        let localAgent = currentLocalAgent
        let maxConcurrent = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
        var allPersisted = true
        await withTaskGroup(of: (Int, URL, OCRResult).self) { group in
            var iter = entries.makeIterator()

            func addNext() -> Bool {
                guard let entry = iter.next() else { return false }
                group.addTask {
                    let correction = await Self.detectRotation(
                        imageURL: entry.url, provider: model.provider, apiKey: apiKey,
                        mode: rotationMode, gatewayConfig: gateway, localAgent: localAgent
                    )
                    return (entry.index, entry.url, Self.mergeRotation(into: entry.result, correction: correction))
                }
                return true
            }

            for _ in 0..<min(maxConcurrent, entries.count) { _ = addNext() }

            for await (index, url, resolved) in group {
                guard await handleOCRResult(
                    resolved, index: index, url: url, model: model,
                    outputDirectory: outputDirectory, runConfig: runConfig) else {
                    allPersisted = false
                    group.cancelAll()
                    return
                }
                _ = addNext()
            }
        }
        // NOTE: do NOT sweep remaining `.processing` jobs to `.failed` here. For multi-chunk Gemini
        // batches this runs while OTHER chunks are still processing, so it would falsely fail files
        // whose chunk hasn't finished yet. The sweep is done once in pollBatchUntilComplete after the
        // whole batch is complete.
        return allPersisted
    }
    func performOCRPhase(
        fileURLs: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        segmentationContext: SegmentationContext,
        runConfig: SessionProcessingConfig? = nil
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
                imageScale: segmentationContext.imageScale,
                runConfig: runConfig
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
                segmentationContext: segmentationContext,
                runConfig: runConfig
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
        segmentationContext: SegmentationContext,
        runConfig: SessionProcessingConfig?
    ) async {
        let total = fileURLs.count
        let gateway = currentGateway
        let localAgent = currentLocalAgent
        let ocrRun = Self.ocrCallValues(for: runConfig)
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
                gatewayConfig: gateway, localAgent: localAgent,
                rotationMode: ocrRun.rotationMode,
                standardImageMB: ocrRun.standardImageMB
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
                    gatewayConfig: gateway, localAgent: localAgent,
                    rotationMode: ocrRun.rotationMode,
                    standardImageMB: ocrRun.standardImageMB
                )
            }

            guard await handleOCRResult(
                result, index: index, url: url, model: model,
                outputDirectory: outputDirectory, runConfig: runConfig) else { return }
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
        imageScale: Double = 1.0,
        runConfig: SessionProcessingConfig?
    ) async {
        let total = fileURLs.count
        let gateway = currentGateway
        let localAgent = currentLocalAgent
        let ocrRun = Self.ocrCallValues(for: runConfig)
        let concurrency = Self.schedulingWorkerCount(for: runConfig)
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
                        gatewayConfig: gateway, localAgent: localAgent,
                        rotationMode: ocrRun.rotationMode,
                        standardImageMB: ocrRun.standardImageMB
                    )
                    return (index, result)
                }
            }

            // Collect results and feed new tasks
            for await (index, result) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                let url = fileURLs[index]
                guard await handleOCRResult(
                    result, index: index, url: url, model: model,
                    outputDirectory: outputDirectory, runConfig: runConfig) else {
                    group.cancelAll()
                    return
                }

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
                            gatewayConfig: gateway, localAgent: localAgent,
                            rotationMode: ocrRun.rotationMode,
                            standardImageMB: ocrRun.standardImageMB
                        )
                        return (idx, result)
                    }
                }
            }
        }
    }
    func handleOCRResult(
        _ result: OCRResult, index: Int, url: URL, model: LLMModel, outputDirectory: URL,
        runConfig: SessionProcessingConfig? = nil
    ) async -> Bool {
        guard index >= 0 && index < jobs.count else { return false }
        let sourceURL = jobs[index].sourceURL
        jobs[index].result = result
        jobs[index].classification = result.classification
        jobs[index].status = result.text != nil ? .succeeded : .failed
        if result.text == nil {
            // Dedup: a file that fails again on a retry is already in failedFiles. Without this the
            // "N failed" summary and the .txt log over-count (the same filename listed 2–3×).
            let name = sourceURL.lastPathComponent
            if !failedFiles.contains(name) { failedFiles.append(name) }
        } else {
            // Succeeded (possibly on retry): make sure a prior failure entry is cleared.
            failedFiles.removeAll { $0 == sourceURL.lastPathComponent }
        }
        // Use original source name for output PDF naming
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let outputURL = uniqueOutputURL(baseName: baseName, ext: "pdf", in: outputDirectory, for: sourceURL)
        // Move heavy PDF generation + tag I/O off the main actor (M3 perf fix). The MainActor
        // suspends at the await but is free to service UI events while the work runs on .utility.
        let originalFileName = sourceURL.lastPathComponent
        let gatewayName = currentGateway?.displayName
        let pdfSettings = Self.pdfGenerationSettings(for: runConfig)
        let pdfMB = pdfSettings.imageMB
        let txtCols = pdfSettings.textColumns
        let shouldPassTags = passSourceTags
        // W23.m5 / W23.h5-fu — the detached worker also reports whether the tag write landed and
        // whether the PDF's image page holds the real scan, so the main actor can record both instead
        // of the old "didn't throw ⇒ everything worked".
        // `tagWriteOK` is OPTIONAL on purpose: nil means no tag write was ATTEMPTED here (every mode but
        // copy-source tags later, in the tagging phase). Recording those as successes would let a post-run
        // `retryOne` — which regenerates the PDF and does not re-tag it — silently clear a real warning.
        let pdfResult: (success: Bool, tags: [String]?, tagWriteOK: Bool?,
                        imagePage: PDFGenerator.ImagePageOutcome?)
            = await Task.detached(priority: .utility) {
            let pdfGen = PDFGenerator()
            do {
                let imagePage = try pdfGen.generate(imageURL: url, result: result, model: model,
                                                    outputURL: outputURL,
                                                    originalFileName: originalFileName,
                                                    gatewayDisplayName: gatewayName,
                                                    pdfImageMB: pdfMB, textColumns: txtCols)
                var appliedTags: [String]? = nil
                var tagWriteOK: Bool? = nil
                if shouldPassTags {
                    if let sourceTags = try? MacOSTagger.readTags(from: sourceURL), !sourceTags.isEmpty {
                        // Copy-source pass-through (verbatim, label untouched) — see the note at the
                        // sibling pre-OCRed site. `shouldPassTags` implies `.copySource`.
                        tagWriteOK = OCRProcessor.writeOutputTags(sourceTags, to: outputURL,
                                                                  stampUnread: false)
                        appliedTags = sourceTags
                    }
                }
                return (true, appliedTags, tagWriteOK, imagePage)
            } catch {
                os_log(.error, "PDF write failed for %{public}@: %{public}@",
                       originalFileName, error.localizedDescription)
                return (false, nil, nil, nil)
            }
        }.value
        if pdfResult.success {
            // Map by original source URL so tagging/collection segmentation can find it.
            // Only set when the PDF was actually written — a failed write must not leave a
            // phantom entry pointing downstream consumers at a nonexistent file (M1 fix).
            outputURLMap[sourceURL] = outputURL
            if let tags = pdfResult.tags {
                jobs[index].appliedTags = tags
            }
            if let tagWriteOK = pdfResult.tagWriteOK {
                recordTagWrite(succeeded: tagWriteOK, forSource: sourceURL)
            }
            if let imagePage = pdfResult.imagePage { recordImagePage(imagePage, forSource: sourceURL) }
        } else {
            // The OCR itself SUCCEEDED here — only `PDFGenerator.generate` threw (it throws solely on
            // `PDFDocument.write(to:)` returning false; a bad image yields a placeholder page instead).
            // Previously the reason went only to `os_log`, leaving `result.errorMessage` nil, which the UI
            // renders as "No OCR text" — blaming the model for a failed output WRITE. Keep the OCR text and
            // `rotationDegrees` (all `OCRResult` fields are `let`, so this must be rebuilt, not mutated —
            // dropping rotationDegrees here would silently lose the detected rotation) and add the reason.
            jobs[index].result = OCRResult(
                text: result.text,
                classification: result.classification,
                rotationDegrees: result.rotationDegrees,
                errorMessage: "OCR succeeded but the output PDF could not be written. Check that the output "
                            + "folder exists and is writable, and that there is free disk space.",
                errorCode: "pdf_write_failed")
            jobs[index].status = .failed
            let name = sourceURL.lastPathComponent
            if !failedFiles.contains(name) { failedFiles.append(name) }
        }
        // Persist result AND its assigned output path for resume-after-restart. Records the intended
        // output path even on failure so resume can attempt to regenerate the PDF (B7). NOTE: the ORIGINAL
        // `result` is persisted deliberately — the pending-run snapshot records what the model returned, so
        // a resume regenerates the PDF from the real OCR text rather than inheriting this write-failure note.
        return saveResultToPendingRun(index: index, result: result, outputURL: outputURL)
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
    /// Single-image OCR + concurrent rotation detection, merged into one result. Live Capture, Process
    /// Files, resumes, retries, and Tools diagnostics pass immutable run values explicitly — and since
    /// W16.cfg6 `rotationMode` and `standardImageMB` are **required**, so the compiler, not a code
    /// review, is what guarantees no call site silently falls back to a process-global.
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
        gatewayConfig: GatewayConfig? = nil,
        localAgent: LocalAgentConfig? = nil,
        rotationMode: RotationMode,
        standardImageMB: Double
    ) async -> OCRResult {
        // Start rotation detection concurrently with the network OCR call. Both are async, so
        // the extra rotation work overlaps the OCR round-trip and adds little wall-clock time.
        // The detected correction overrides the OCR prompt's own rotation guess.
        async let rotationCorrection = detectRotation(
            imageURL: imageURL, provider: provider, apiKey: apiKey,
            mode: rotationMode,
            gatewayConfig: gatewayConfig, localAgent: localAgent
        )

        // The incoming `imageScale` is the size-target slider fraction; convert to a per-file
        // dimension scale (larger files reduced more; average/small files left full-res).
        let scale = targetDimensionScale(
            forFileAt: imageURL,
            sizeFraction: imageScale,
            standardImageMB: standardImageMB)

        let networkResult: OCRResult
        do {
            // Backend precedence: the Local Agent CLI wins, then the gateway, then the direct provider
            // path (Settings makes useLocalAgent/useGateway mutually exclusive; the order is defensive).
            if let localAgent {
                networkResult = try await LocalAgentClient(config: localAgent).ocr(imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL, customPrompt: customPrompt, imageScale: scale)
            } else if let gateway = gatewayConfig {
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
                case .openai:
                    let client = OpenAICompatibleClient.openAI(model: model, apiKey: apiKey, thinkingLevel: thinkingLevel)
                    networkResult = try await client.ocr(imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL, customPrompt: customPrompt, imageScale: scale)
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
        gatewayConfig: GatewayConfig?,
        localAgent: LocalAgentConfig? = nil
    ) async -> Int? {
        switch mode {
        case .off:
            return nil
        case .localVision:
            return await RotationDetector.detectCorrection(imageURL: imageURL)
        case .llmSingle, .llmMajority:
            // The Local Agent CLI backend has no multi-image comparative-rotation path (same as the
            // gateway, which LLMRotationDetector already gates out), so skip straight to local Vision.
            if localAgent == nil,
               let c = await LLMRotationDetector.detectCorrection(
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
        return result.with(classification: result.classification, rotationDegrees: rot)
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
        outputDirectory: URL,
        runConfig: SessionProcessingConfig? = nil
    ) async {
        let retryIndices = jobs.indices.filter { isRetryableError(jobs[$0].result) }
        guard !retryIndices.isEmpty else { return }
        let gateway = currentGateway
        let localAgent = currentLocalAgent
        let ocrRun = Self.ocrCallValues(for: runConfig)

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
                gatewayConfig: gateway, localAgent: localAgent,
                rotationMode: ocrRun.rotationMode,
                standardImageMB: ocrRun.standardImageMB
            )

            // Update failed files list if retry succeeded
            if result.text != nil {
                let sourceFileName = jobs[index].sourceURL.lastPathComponent
                failedFiles.removeAll { $0 == sourceFileName }
            }
            guard await handleOCRResult(
                result, index: index, url: url, model: model,
                outputDirectory: outputDirectory, runConfig: runConfig) else { return }
        }
    }
    /// Run a single OCR call at a given image scale for resolution testing. Public so the UI can call it.
    nonisolated static func performResolutionTestCall(
        imageURL: URL, provider: LLMProvider, model: LLMModel,
        thinkingLevel: ThinkingLevel?, apiKey: String,
        imageScale: Double,
        gatewayConfig: GatewayConfig? = nil,
        localAgent: LocalAgentConfig? = nil,
        rotationMode: RotationMode,
        standardImageMB: Double
    ) async -> OCRResult {
        await performOCRCall(
            imageURL: imageURL, provider: provider, model: model,
            thinkingLevel: thinkingLevel, apiKey: apiKey,
            previousText: nil, previousImageURL: nil,
            imageScale: imageScale,
            gatewayConfig: gatewayConfig,
            localAgent: localAgent,
            rotationMode: rotationMode,
            standardImageMB: standardImageMB
        )
    }
}
