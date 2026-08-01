import Foundation

/// Shared HTTP error-body → message parsing for the batch clients. Checks a top-level `message`
/// first (Mistral's shape), then nested `error.message` (Anthropic/Gemini). Anthropic and Gemini
/// error bodies carry no top-level `message`, so this is behavior-identical to their prior
/// nested-only parsing — it simply also covers Mistral's top-level form.
///
/// Internal (not `private`) so the headless provider-contract driver can pin its shape — see
/// `BatchParseContract`.
func parseBatchErrorBody(data: Data, statusCode: Int) -> String {
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let message = json["message"] as? String { return message }
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String { return message }
    }
    return "API error (\(statusCode))"
}

/// URL-encodes a value for safe interpolation into a URL query/path component (RFC 3986 unreserved).
/// Used for the API key and model id so a pasted key with a stray space/newline (or an odd custom
/// model id) yields a clean thrown error instead of crashing on `URL(string:)!`.
private func urlComponentEncoded(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

/// Builds a URL or throws a clear error (never crashes) for batch requests.
private func makeBatchURL(_ string: String) throws -> URL {
    guard let url = URL(string: string) else {
        throw NSError(domain: "BatchOCR", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Invalid batch request URL (check the API key and model id for stray spaces)."])
    }
    return url
}

// MARK: - Anthropic Batch Client

struct AnthropicBatchClient: Sendable {
    let apiKey: String
    let model: LLMModel
    let thinkingLevel: ThinkingLevel?

    private var baseURL: String { "https://api.anthropic.com/v1/messages/batches" }

    /// Submit a batch of OCR requests. Returns the batch ID.
    func submitBatch(fileURLs: [URL], sendPreviousImage: Bool, customPrompt: String? = nil, imageScale: Double = 1.0) async throws -> String {
        // M5 perf fix: serialize each request to JSON Data immediately and append to the
        // body buffer, so only ONE image's base64 lives in the dict tree at a time. The old
        // approach held ALL base64 strings in the `requests` array simultaneously, then
        // serialized the whole tree — roughly 2× peak memory (all dicts + final Data).
        var bodyData = Data("{\"requests\":[".utf8)
        var count = 0
        // L4 perf: cache the previous iteration's JPEG so sendPreviousImage reuses it
        // instead of re-loading + re-encoding from disk each iteration.
        var previousJPEG: Data?

        for (index, url) in fileURLs.enumerated() {
            guard let jpegData = ImageEncoding.loadImageAsJPEG(url: url, scale: imageScale) else { continue }
            let base64 = jpegData.base64EncodedString()
            let prompt = OCRPrompt.build(
                previousText: nil,
                previousImageIncluded: sendPreviousImage && index > 0,
                customPrompt: customPrompt
            )

            var content: [[String: Any]] = []

            if sendPreviousImage && index > 0, let prevData = previousJPEG {
                content.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": prevData.base64EncodedString()
                    ]
                ])
            }

            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": base64
                ]
            ])
            content.append(["type": "text", "text": prompt])

            var params: [String: Any] = [
                "model": model.id,
                "max_tokens": 8192,
                "messages": [["role": "user", "content": content]]
            ]

            if let thinking = thinkingLevel {
                let budget = thinking == .low ? 1024 : 8000
                params["thinking"] = ["type": "enabled", "budget_tokens": budget]
                // Anthropic counts thinking tokens against max_tokens; raise the ceiling by the
                // budget so the transcription isn't silently truncated to the remainder.
                params["max_tokens"] = 8192 + budget
            }

            let requestObj: [String: Any] = [
                "custom_id": "file-\(index)",
                "params": params
            ]

            if count > 0 { bodyData.append(Data(",".utf8)) }
            bodyData.append(try JSONSerialization.data(withJSONObject: requestObj))
            count += 1
            previousJPEG = sendPreviousImage ? jpegData : nil
            // base64, content, params, requestObj released here — only bodyData grows
        }

        bodyData.append(Data("]}".utf8))

        guard count > 0 else {
            throw OCRError.networkError("No valid images to process")
        }

        let reqURL = try makeBatchURL(baseURL)
        var request = URLRequest(url: reqURL, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if thinkingLevel != nil {
            request.setValue("interleaved-thinking-2025-05-14", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = bodyData

        let (data, response) = try await NetworkSession.data(for: request, policy: .nonIdempotent)
        guard let http = response as? HTTPURLResponse else {
            throw OCRError.networkError("No HTTP response")
        }

        if http.statusCode != 200 {
            let errorMsg = parseBatchErrorBody(data: data, statusCode: http.statusCode)
            throw OCRError.networkError(errorMsg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let batchId = json["id"] as? String else {
            throw OCRError.networkError("No batch ID in response")
        }

        return batchId
    }

    struct StatusResult: Sendable {
        let isComplete: Bool
        let processing: Int
        let succeeded: Int
        let errored: Int
        let expired: Int
        let canceled: Int
        let resultsURL: String?

        var total: Int { processing + succeeded + errored + expired + canceled }
        var completed: Int { succeeded + errored + expired + canceled }
    }

    /// Check batch processing status.
    func checkStatus(batchId: String) async throws -> StatusResult {
        let reqURL = try makeBatchURL("\(baseURL)/\(batchId)")
        var request = URLRequest(url: reqURL, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let (data, _) = try await NetworkSession.data(for: request, policy: .idempotent)
        return try Self.parseStatusBody(data)
    }

    /// Pure parse of a `messages/batches/{id}` status body — no network, no state, no cost. Lifted
    /// verbatim out of `checkStatus` so the provider response contract is covered headlessly: a
    /// response-shape change here decides whether a *paid* batch is seen as finished at all.
    static func parseStatusBody(_ data: Data) throws -> StatusResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OCRError.networkError("Malformed status response")
        }

        let status = json["processing_status"] as? String ?? ""
        let counts = json["request_counts"] as? [String: Any] ?? [:]

        return StatusResult(
            isComplete: status == "ended",
            processing: counts["processing"] as? Int ?? 0,
            succeeded: counts["succeeded"] as? Int ?? 0,
            errored: counts["errored"] as? Int ?? 0,
            expired: counts["expired"] as? Int ?? 0,
            canceled: counts["canceled"] as? Int ?? 0,
            resultsURL: json["results_url"] as? String
        )
    }

    /// Retrieve batch results from the results URL.
    func retrieveResults(resultsURL: String) async throws -> [String: OCRResult] {
        guard let url = URL(string: resultsURL) else {
            throw OCRError.networkError("Invalid results URL")
        }

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let (data, _) = try await NetworkSession.data(for: request, policy: .idempotent)
        return Self.parseResultsJSONL(String(data: data, encoding: .utf8) ?? "")
    }

    /// Pure parse of the results JSONL body (one `{custom_id, result}` object per line) — no network,
    /// no cost. Lifted verbatim out of `retrieveResults`; a line the parser cannot read is a page of
    /// *paid* OCR silently missing from the run, so the shape is pinned headlessly.
    static func parseResultsJSONL(_ text: String) -> [String: OCRResult] {
        var results: [String: OCRResult] = [:]

        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let customId = json["custom_id"] as? String else { continue }

            let resultObj = json["result"] as? [String: Any] ?? [:]
            let resultType = resultObj["type"] as? String

            if resultType == "succeeded",
               let message = resultObj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                let rawText = content
                    .filter { ($0["type"] as? String) == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
                let (classification, rotationDegrees, ocrText) = OCRPrompt.parseResponse(rawText)
                results[customId] = OCRResult(text: ocrText, classification: classification, rotationDegrees: rotationDegrees, errorMessage: nil, errorCode: nil)
            } else {
                let errorJson = resultObj["error"] as? [String: Any]
                let errorMsg = errorJson?["message"] as? String ?? "Batch request failed"
                results[customId] = OCRResult(text: nil, classification: nil, errorMessage: errorMsg, errorCode: nil)
            }
        }

        return results
    }

    /// Cancel a running batch.
    func cancelBatch(batchId: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/\(batchId)/cancel") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            let (_, response) = try await NetworkSession.data(for: request, policy: .nonIdempotent)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch { return false }
    }
}

// MARK: - Gemini Batch Client

struct GeminiBatchClient: Sendable {
    let apiKey: String
    let model: LLMModel
    let thinkingLevel: ThinkingLevel?

    private var baseURL: String { "https://generativelanguage.googleapis.com/v1beta" }

    /// Maximum size for inline batch requests (20MB as per Gemini docs).
    private static let inlineMaxBytes = 20 * 1024 * 1024
    /// Maximum JSONL file size for file-based batch (2GB Gemini File API limit, with margin).
    private static let fileMaxBytes = 1_900_000_000

    /// Submit a batch of OCR requests. Uses inline requests when under 20MB, file upload otherwise.
    /// For very large batches (>2GB), splits into multiple batch jobs.
    /// Returns comma-separated batch names (e.g. "batches/123" or "batches/123,batches/456").
    /// `onJobCreated` runs immediately after each create response yields a server ID, before another paid
    /// chunk is submitted. The Processor uses it to durably journal that ID; throwing stops submission.
    func submitBatch(
        fileURLs: [URL],
        sendPreviousImage: Bool,
        customPrompt: String? = nil,
        imageScale: Double = 1.0,
        onJobCreated: (@Sendable (String) async throws -> Void)? = nil
    ) async throws -> String {
        // Build JSONL lines for each file, tracking sizes for chunking
        var jsonlLines: [String] = []
        // L4 perf: cache the previous iteration's JPEG so sendPreviousImage reuses it
        // instead of re-loading + re-encoding from disk each iteration.
        var previousJPEG: Data?

        for (index, url) in fileURLs.enumerated() {
            guard let jpegData = ImageEncoding.loadImageAsJPEG(url: url, scale: imageScale) else { continue }
            let base64 = jpegData.base64EncodedString()
            let prompt = OCRPrompt.build(
                previousText: nil,
                previousImageIncluded: sendPreviousImage && index > 0,
                customPrompt: customPrompt
            )

            var parts: [[String: Any]] = []

            if sendPreviousImage && index > 0, let prevData = previousJPEG {
                parts.append(["inlineData": ["mimeType": "image/jpeg", "data": prevData.base64EncodedString()]])
            }

            parts.append(["inlineData": ["mimeType": "image/jpeg", "data": base64]])
            parts.append(["text": prompt])

            var requestBody: [String: Any] = [
                "contents": [["parts": parts]]
            ]

            if let thinking = thinkingLevel {
                let budget = thinking == .low ? 1024 : 8000
                requestBody["generationConfig"] = ["thinkingConfig": ["thinkingBudget": budget]]
            }

            let lineObj: [String: Any] = [
                "key": "file-\(index)",
                "request": requestBody
            ]

            if let jsonData = try? JSONSerialization.data(withJSONObject: lineObj),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                jsonlLines.append(jsonString)
            }
            previousJPEG = sendPreviousImage ? jpegData : nil
        }

        guard !jsonlLines.isEmpty else {
            throw OCRError.networkError("No valid images to process")
        }

        // Calculate total size
        let totalSize = jsonlLines.reduce(0) { $0 + $1.utf8.count + 1 } // +1 for newline

        if totalSize < Self.inlineMaxBytes {
            // Small batch — use inline requests
            let batchName = try await submitInlineBatch(jsonlLines: jsonlLines)
            try await onJobCreated?(batchName)
            return batchName
        } else if totalSize < Self.fileMaxBytes {
            // Medium batch — single file upload
            let batchName = try await submitFileBatch(jsonlLines: jsonlLines)
            try await onJobCreated?(batchName)
            return batchName
        } else {
            // Large batch — split into chunks under the file size limit
            var chunks: [[String]] = []
            var currentChunk: [String] = []
            var currentSize = 0

            for line in jsonlLines {
                let lineSize = line.utf8.count + 1
                if currentSize + lineSize > Self.fileMaxBytes && !currentChunk.isEmpty {
                    chunks.append(currentChunk)
                    currentChunk = []
                    currentSize = 0
                }
                currentChunk.append(line)
                currentSize += lineSize
            }
            if !currentChunk.isEmpty {
                chunks.append(currentChunk)
            }

            var batchNames: [String] = []
            for chunk in chunks {
                let name = try await submitFileBatch(jsonlLines: chunk)
                try await onJobCreated?(name)
                batchNames.append(name)
            }
            return batchNames.joined(separator: ",")
        }
    }

    /// Submit a batch using inline requests (for small batches under 20MB).
    private func submitInlineBatch(jsonlLines: [String]) async throws -> String {
        // Parse JSONL lines back into request objects for inline format
        var inlinedRequests: [[String: Any]] = []
        for line in jsonlLines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let key = obj["key"] as? String ?? ""
            inlinedRequests.append([
                "request": obj["request"] as Any,
                "metadata": ["key": key]
            ])
        }

        let batchBody: [String: Any] = [
            "batch": [
                "displayName": "archive-processor-ocr",
                "inputConfig": [
                    "requests": [
                        "requests": inlinedRequests
                    ] as [String: Any]
                ] as [String: Any]
            ] as [String: Any]
        ]

        return try await createBatchJob(body: batchBody)
    }

    /// Submit a batch using file upload (for batches over 20MB).
    private func submitFileBatch(jsonlLines: [String]) async throws -> String {
        let jsonlContent = jsonlLines.joined(separator: "\n")
        guard let jsonlData = jsonlContent.data(using: .utf8) else {
            throw OCRError.networkError("Failed to create batch data")
        }

        let fileName = try await uploadFile(data: jsonlData)

        let batchBody: [String: Any] = [
            "batch": [
                "displayName": "archive-processor-ocr",
                "inputConfig": [
                    "fileName": fileName
                ] as [String: Any]
            ] as [String: Any]
        ]

        return try await createBatchJob(body: batchBody)
    }

    /// Create a batch job with the given request body. Returns the batch name.
    private func createBatchJob(body: [String: Any]) async throws -> String {
        let createURL = try makeBatchURL("\(baseURL)/models/\(urlComponentEncoded(model.id)):batchGenerateContent?key=\(urlComponentEncoded(apiKey))")
        var request = URLRequest(url: createURL, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await NetworkSession.data(for: request, policy: .nonIdempotent)
        guard let http = response as? HTTPURLResponse else {
            throw OCRError.networkError("No HTTP response")
        }

        if http.statusCode != 200 {
            let errorMsg = parseBatchErrorBody(data: data, statusCode: http.statusCode)
            throw OCRError.networkError(errorMsg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OCRError.networkError("No batch name in response")
        }

        let metadata = json["metadata"] as? [String: Any]
        guard let batchName = json["name"] as? String
                ?? metadata?["name"] as? String else {
            throw OCRError.networkError("No batch name in response")
        }

        return batchName
    }

    /// Upload JSONL file via Gemini File API (resumable upload protocol).
    private func uploadFile(data: Data) async throws -> String {
        let uploadBase = "https://generativelanguage.googleapis.com/upload/v1beta"

        // Step 1: Initialize resumable upload
        let initURL = try makeBatchURL("\(uploadBase)/files?key=\(urlComponentEncoded(apiKey))")
        var initRequest = URLRequest(url: initURL, timeoutInterval: 60)
        initRequest.httpMethod = "POST"
        initRequest.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        initRequest.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        initRequest.setValue("\(data.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        initRequest.setValue("application/jsonl", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        initRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let initBody: [String: Any] = ["file": ["display_name": "batch_ocr_requests"]]
        initRequest.httpBody = try JSONSerialization.data(withJSONObject: initBody)

        let (_, initResponse) = try await NetworkSession.data(for: initRequest, policy: .nonIdempotent)
        guard let httpInit = initResponse as? HTTPURLResponse,
              let uploadURLString = httpInit.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadURLString) else {
            throw OCRError.networkError("Failed to initialize file upload")
        }

        // Step 2: Upload file data
        var uploadRequest = URLRequest(url: uploadURL, timeoutInterval: 300)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        uploadRequest.httpBody = data

        let (uploadData, _) = try await NetworkSession.data(for: uploadRequest, policy: .nonIdempotent)
        guard let json = try? JSONSerialization.jsonObject(with: uploadData) as? [String: Any] else {
            throw OCRError.networkError("Malformed file upload response")
        }

        // Response may have file info at top level or nested under "file"
        let fileObj = json["file"] as? [String: Any] ?? json
        guard let fileName = fileObj["name"] as? String else {
            throw OCRError.networkError("No file name in upload response")
        }

        return fileName // e.g. "files/abc123"
    }

    struct StatusResult: Sendable {
        let isComplete: Bool
        let state: String
        /// Results returned inline in the status response (Gemini's default).
        let inlineResults: [String: OCRResult]?
        /// Result file for download-based retrieval (fallback).
        let resultFileName: String?
    }

    /// Where a finished chunk's pages are actually readable from.
    enum ResultsSource: Sendable {
        /// Pages arrived inline in the status body (never empty — an empty container is not a source).
        case inline([String: OCRResult])
        /// Pages must be downloaded from this result file (name is never empty).
        case file(String)
        /// The chunk reports SUCCEEDED but offers nothing to read. Paid pages are unaccounted for:
        /// the caller must NOT mark the chunk consumed.
        case noneAvailable
    }

    /// Decide where a terminal chunk's results come from — the one place that ranks the two
    /// retrieval arms. Pure: no network, no state, no cost.
    ///
    /// This exists because *emptiness* is the trap (W16.bat1-fu). `parseStatusBody` faithfully reports
    /// an empty `inlinedResponses` container as a **non-nil empty** dictionary, and the poll used to
    /// branch on `if let inlineResults = …` alone — so an empty container took the inline arm, the
    /// result file was never fetched, and the chunk was marked consumed with zero pages while the run
    /// reported success. An empty container (and an empty file name) are therefore *not* sources here.
    static func resultsSource(for status: StatusResult) -> ResultsSource {
        if let inline = status.inlineResults, !inline.isEmpty { return .inline(inline) }
        if let fileName = status.resultFileName, !fileName.isEmpty { return .file(fileName) }
        return .noneAvailable
    }

    /// How many consecutive polls a chunk may report SUCCEEDED-with-no-results before the poll stops
    /// and keeps the batch for resume (W16.bat1-fu).
    static let emptyResultCheckLimit = 3

    /// What the poll must do with a terminal SUCCEEDED chunk once it has tried to obtain its results.
    enum ChunkOutcome: Sendable, Equatable {
        /// Hand the results to the pipeline; the chunk may be marked consumed once they persist.
        case materialize
        /// Nothing came back. Do NOT consume — read the chunk again on the next poll.
        case recheck
        /// Still nothing after the grace window. Stop, keep the journal, let the operator resume.
        case keepForResume
    }

    /// The money decision, in one pure function: a chunk is consumable only if it actually produced
    /// pages. `processBatchResults` cannot enforce this — it returns `true` for an empty set on
    /// purpose, because a *resumed* chunk whose pages were all persisted already legitimately yields
    /// no new entries. So emptiness has to be judged here, on the raw provider results, before the
    /// pipeline ever sees them.
    ///
    /// Chunks are only ever submitted non-empty, so zero results from a finished chunk is anomalous by
    /// construction. The likeliest benign cause is the state flipping to SUCCEEDED a moment before the
    /// results are attached, which another poll resolves — hence the bounded grace rather than an
    /// immediate stop. `limit` tunes only that grace: no value of it can turn zero results into
    /// `.materialize`.
    static func chunkOutcome(resultCount: Int, emptyObservations: Int, limit: Int) -> ChunkOutcome {
        guard resultCount <= 0 else { return .materialize }
        return emptyObservations < max(1, limit) ? .recheck : .keepForResume
    }

    /// Check batch processing status.
    func checkStatus(batchName: String) async throws -> StatusResult {
        let statusURL = try makeBatchURL("\(baseURL)/\(batchName)?key=\(urlComponentEncoded(apiKey))")
        var request = URLRequest(url: statusURL, timeoutInterval: 30)
        request.httpMethod = "GET"

        let (data, _) = try await NetworkSession.data(for: request, policy: .idempotent)
        return try Self.parseStatusBody(data)
    }

    /// Pure parse of a `batches/{name}` status body — no network, no state, no cost. Lifted verbatim
    /// out of `checkStatus`. This is the widest response contract in the app: the state and the
    /// results may each arrive at the top level or under `metadata`, and the result-file location has
    /// **six** accepted spellings. Nothing else pins them, and getting one wrong reads a *finished,
    /// paid* batch as unfinished or empty — hence the headless contract driver.
    static func parseStatusBody(_ data: Data) throws -> StatusResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OCRError.networkError("Malformed status response")
        }

        // State and output may be at top level or nested under "metadata"
        let metadata = json["metadata"] as? [String: Any]
        let state = metadata?["state"] as? String
            ?? json["state"] as? String
            ?? ""

        let completedStates = [
            "BATCH_STATE_SUCCEEDED", "BATCH_STATE_FAILED", "BATCH_STATE_CANCELLED", "BATCH_STATE_EXPIRED",
            "JOB_STATE_SUCCEEDED", "JOB_STATE_FAILED", "JOB_STATE_CANCELLED", "JOB_STATE_EXPIRED"
        ]
        let isComplete = completedStates.contains(state)

        // Try to extract inline results from response or metadata
        var inlineResults: [String: OCRResult]? = nil
        if isComplete {
            // Results can be at response.inlinedResponses.inlinedResponses
            // or metadata.output.inlinedResponses.inlinedResponses
            let responseObj = json["response"] as? [String: Any]
            let metaOutput = metadata?["output"] as? [String: Any]

            let inlinedContainer = responseObj?["inlinedResponses"] as? [String: Any]
                ?? metaOutput?["inlinedResponses"] as? [String: Any]

            if let responses = inlinedContainer?["inlinedResponses"] as? [[String: Any]] {
                inlineResults = Self.parseInlinedResponses(responses)
            }
        }

        // Fallback: result file location for download-based retrieval
        let metaDest = metadata?["dest"] as? [String: Any]
        let metaOutputConfig = metadata?["outputConfig"] as? [String: Any]
        let dest = json["dest"] as? [String: Any]
        let resultFileName = metaDest?["file_name"] as? String
            ?? metaDest?["fileName"] as? String
            ?? metaOutputConfig?["file_name"] as? String
            ?? metaOutputConfig?["fileName"] as? String
            ?? dest?["file_name"] as? String
            ?? dest?["fileName"] as? String

        return StatusResult(
            isComplete: isComplete,
            state: state,
            inlineResults: inlineResults,
            resultFileName: resultFileName
        )
    }

    /// Parse inline batch responses into OCRResult dictionary.
    /// Each entry has: { "response": { "candidates": [...] }, "metadata": { "key": "0" } }
    ///
    /// Internal (not `private`) so the headless contract driver can reach it directly.
    static func parseInlinedResponses(_ responses: [[String: Any]]) -> [String: OCRResult] {
        var results: [String: OCRResult] = [:]

        for entry in responses {
            let entryMeta = entry["metadata"] as? [String: Any]
            let key = entryMeta?["key"] as? String ?? ""
            guard !key.isEmpty else { continue }

            // Normalize key: API returns "0", "1" etc. but app uses "file-0", "file-1"
            let normalizedKey = key.hasPrefix("file-") ? key : "file-\(key)"

            if let error = entry["error"] as? [String: Any] {
                let errorMsg = error["message"] as? String ?? "Batch request failed"
                results[normalizedKey] = OCRResult(text: nil, classification: nil, errorMessage: errorMsg, errorCode: (error["code"] as? Int).map { "\($0)" })
                continue
            }

            guard let response = entry["response"] as? [String: Any] else {
                results[normalizedKey] = OCRResult(text: nil, classification: nil, errorMessage: "No response in batch entry", errorCode: nil)
                continue
            }

            results[normalizedKey] = parseSingleResponse(response)
        }

        return results
    }

    /// Parse a single generateContent response object into an OCRResult.
    ///
    /// Internal (not `private`) so the headless contract driver can reach it directly.
    static func parseSingleResponse(_ response: [String: Any]) -> OCRResult {
        if let promptFeedback = response["promptFeedback"] as? [String: Any],
           let blockReason = promptFeedback["blockReason"] as? String {
            return OCRResult(text: nil, classification: nil, errorMessage: "Content blocked by Gemini: \(blockReason)", errorCode: blockReason)
        }

        guard let candidates = response["candidates"] as? [[String: Any]],
              let first = candidates.first else {
            return OCRResult(text: nil, classification: nil, errorMessage: "No candidates in response", errorCode: nil)
        }

        if let finishReason = first["finishReason"] as? String, finishReason == "RECITATION" {
            return OCRResult(text: nil, classification: nil, errorMessage: "Gemini refused to OCR this content (Recitation — likely copyrighted material).", errorCode: "Recitation")
        }

        guard let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return OCRResult(text: nil, classification: nil, errorMessage: "No content parts in response", errorCode: nil)
        }

        let rawText = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let (classification, rotationDegrees, ocrText) = OCRPrompt.parseResponse(rawText)
        return OCRResult(text: ocrText, classification: classification, rotationDegrees: rotationDegrees, errorMessage: nil, errorCode: nil)
    }

    /// Retrieve results from a batch output file (fallback if results aren't inlined).
    func retrieveResults(resultFileName: String) async throws -> [String: OCRResult] {
        let downloadBase = "https://generativelanguage.googleapis.com/download/v1beta"
        let downloadURL = try makeBatchURL("\(downloadBase)/\(resultFileName):download?alt=media&key=\(urlComponentEncoded(apiKey))")

        var request = URLRequest(url: downloadURL, timeoutInterval: 120)
        request.httpMethod = "GET"

        let (data, _) = try await NetworkSession.data(for: request, policy: .idempotent)
        return Self.parseResultsJSONL(String(data: data, encoding: .utf8) ?? "")
    }

    /// Pure parse of a downloaded batch output file (one `{key, response}` object per line) — no
    /// network, no cost. Lifted verbatim out of `retrieveResults`. This is the fallback path taken
    /// when the status response did *not* inline the results, so it is the only way those paid pages
    /// ever reach the run.
    static func parseResultsJSONL(_ text: String) -> [String: OCRResult] {
        var results: [String: OCRResult] = [:]

        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            let key = json["key"] as? String ?? ""
            guard !key.isEmpty else { continue }

            let normalizedKey = key.hasPrefix("file-") ? key : "file-\(key)"

            if let error = json["error"] as? [String: Any] {
                let errorMsg = error["message"] as? String ?? "Batch request failed"
                results[normalizedKey] = OCRResult(text: nil, classification: nil, errorMessage: errorMsg, errorCode: (error["code"] as? Int).map { "\($0)" })
                continue
            }

            let response = json["response"] as? [String: Any] ?? json
            results[normalizedKey] = Self.parseSingleResponse(response)
        }

        return results
    }

    /// Cancel a running batch.
    func cancelBatch(batchName: String) async -> Bool {
        guard let url = try? makeBatchURL("\(baseURL)/\(batchName):cancel?key=\(urlComponentEncoded(apiKey))") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        do {
            let (_, response) = try await NetworkSession.data(for: request, policy: .nonIdempotent)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch { return false }
    }
}

// MARK: - Mistral Batch Client

struct MistralBatchClient: Sendable {
    let apiKey: String
    let model: LLMModel

    private var batchURL: String { "https://api.mistral.ai/v1/batch/jobs" }
    private var filesURL: String { "https://api.mistral.ai/v1/files" }

    /// Submit a batch of OCR requests. Uploads a JSONL file then creates a batch job. Returns the batch job ID.
    func submitBatch(fileURLs: [URL], imageScale: Double = 1.0) async throws -> String {
        // Build JSONL content — one request per line
        var jsonlLines: [String] = []

        for (index, url) in fileURLs.enumerated() {
            guard let jpegData = ImageEncoding.loadImageAsJPEG(url: url, scale: imageScale) else { continue }
            let base64 = jpegData.base64EncodedString()
            let dataURI = "data:image/jpeg;base64,\(base64)"

            let requestObj: [String: Any] = [
                "custom_id": "file-\(index)",
                "body": [
                    "model": model.id,
                    "document": [
                        "type": "image_url",
                        "image_url": dataURI
                    ] as [String: Any]
                ] as [String: Any]
            ]

            if let jsonData = try? JSONSerialization.data(withJSONObject: requestObj),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                jsonlLines.append(jsonString)
            }
        }

        guard !jsonlLines.isEmpty else {
            throw OCRError.networkError("No valid images to process")
        }

        let jsonlContent = jsonlLines.joined(separator: "\n")
        guard let jsonlData = jsonlContent.data(using: .utf8) else {
            throw OCRError.networkError("Failed to create batch data")
        }

        // Upload JSONL file via Files API
        let fileId = try await uploadFile(data: jsonlData)

        // Create batch job referencing the uploaded file
        let body: [String: Any] = [
            "input_files": [fileId],
            "endpoint": "/v1/ocr",
            "model": model.id
        ]

        let reqURL = try makeBatchURL(batchURL)
        var request = URLRequest(url: reqURL, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await NetworkSession.data(for: request, policy: .nonIdempotent)
        guard let http = response as? HTTPURLResponse else {
            throw OCRError.networkError("No HTTP response")
        }

        if http.statusCode != 200 {
            let errorMsg = parseBatchErrorBody(data: data, statusCode: http.statusCode)
            throw OCRError.networkError(errorMsg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let batchId = json["id"] as? String else {
            throw OCRError.networkError("No batch ID in response")
        }

        return batchId
    }

    private func uploadFile(data: Data) async throws -> String {
        let boundary = UUID().uuidString
        let reqURL = try makeBatchURL(filesURL)
        var request = URLRequest(url: reqURL, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"purpose\"\r\n\r\nbatch\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"batch_ocr.jsonl\"\r\nContent-Type: application/jsonl\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (responseData, response) = try await NetworkSession.data(for: request, policy: .nonIdempotent)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OCRError.networkError("Failed to upload batch file (status \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let fileId = json["id"] as? String else {
            throw OCRError.networkError("No file ID in upload response")
        }

        return fileId
    }

    struct StatusResult: Sendable {
        let isComplete: Bool
        let status: String
        let totalRequests: Int
        let completedRequests: Int
        let succeededRequests: Int
        let failedRequests: Int
        let outputFileId: String?
    }

    /// Check batch job status.
    func checkStatus(batchId: String) async throws -> StatusResult {
        let reqURL = try makeBatchURL("\(batchURL)/\(batchId)")
        var request = URLRequest(url: reqURL, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await NetworkSession.data(for: request, policy: .idempotent)
        return try Self.parseStatusBody(data)
    }

    /// Pure parse of a `batch/jobs/{id}` status body — no network, no state, no cost. Lifted verbatim
    /// out of `checkStatus`; the completion vocabulary and the `output_file` key are provider contract,
    /// and misreading either strands a *paid* batch.
    static func parseStatusBody(_ data: Data) throws -> StatusResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OCRError.networkError("Malformed status response")
        }

        let status = json["status"] as? String ?? ""
        let isComplete = ["SUCCESS", "FAILED", "TIMEOUT_EXCEEDED", "CANCELLATION_REQUESTED", "CANCELLED"].contains(status)

        return StatusResult(
            isComplete: isComplete,
            status: status,
            totalRequests: json["total_requests"] as? Int ?? 0,
            completedRequests: json["completed_requests"] as? Int ?? 0,
            succeededRequests: json["succeeded_requests"] as? Int ?? 0,
            failedRequests: json["failed_requests"] as? Int ?? 0,
            outputFileId: json["output_file"] as? String
        )
    }

    /// Retrieve results from the batch output file.
    func retrieveResults(outputFileId: String) async throws -> [String: OCRResult] {
        let reqURL = try makeBatchURL("\(filesURL)/\(outputFileId)/content")
        var request = URLRequest(url: reqURL, timeoutInterval: 120)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await NetworkSession.data(for: request, policy: .idempotent)
        return Self.parseResultsJSONL(String(data: data, encoding: .utf8) ?? "")
    }

    /// Pure parse of the batch output file (one `{custom_id, response}` object per line) — no network,
    /// no cost. Lifted verbatim out of `retrieveResults`; Mistral's OCR body carries `pages[].markdown`
    /// (with a `text` fallback), and a shape change there is a page of *paid* OCR read as empty.
    static func parseResultsJSONL(_ text: String) -> [String: OCRResult] {
        var results: [String: OCRResult] = [:]

        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let customId = json["custom_id"] as? String else { continue }

            let response = json["response"] as? [String: Any]
            let statusCode = response?["status_code"] as? Int
            let body = response?["body"] as? [String: Any]

            if statusCode == 200 {
                var ocrText: String? = nil
                if let pages = body?["pages"] as? [[String: Any]] {
                    let pageText = pages.compactMap { $0["markdown"] as? String }.joined(separator: "\n\n")
                    ocrText = pageText.isEmpty ? nil : pageText
                } else if let t = body?["text"] as? String {
                    ocrText = t.isEmpty ? nil : t
                }
                let classification = MistralClient.heuristicClassify(text: ocrText, previousText: nil)
                results[customId] = OCRResult(text: ocrText, classification: classification, rotationDegrees: 0, errorMessage: nil, errorCode: nil)
            } else {
                let errorMsg = (body?["message"] as? String)
                    ?? ((body?["error"] as? [String: Any])?["message"] as? String)
                    ?? "Batch request failed"
                results[customId] = OCRResult(text: nil, classification: nil, errorMessage: errorMsg, errorCode: statusCode.map { "\($0)" })
            }
        }

        return results
    }

    /// Cancel a running batch job.
    func cancelBatch(batchId: String) async -> Bool {
        guard let url = URL(string: "\(batchURL)/\(batchId)/cancel") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await NetworkSession.data(for: request, policy: .nonIdempotent)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch { return false }
    }
}
