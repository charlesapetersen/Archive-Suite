import Foundation

@MainActor
class OCRProcessor: ObservableObject {
    @Published var jobs: [OCRJob] = []
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    @Published var failedFiles: [String] = []

    private let maxConcurrent = 4

    func startProcessing(
        files: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        batchMode: Bool
    ) async {
        guard !files.isEmpty else { return }
        isProcessing = true
        failedFiles = []
        jobs = files.map { OCRJob(sourceURL: $0) }
        progress = 0
        statusMessage = "Starting OCR…"

        await processFiles(
            fileURLs: files,
            provider: provider,
            model: model,
            thinkingLevel: thinkingLevel,
            apiKey: apiKey,
            outputDirectory: outputDirectory
        )

        writeLogFile(outputDirectory: outputDirectory)
        isProcessing = false
        statusMessage = "Done. \(jobs.filter { $0.status == .succeeded }.count) succeeded, \(failedFiles.count) failed."
    }

    // MARK: - Core processing

    private func processFiles(
        fileURLs: [URL],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL
    ) async {
        let total = fileURLs.count
        var completed = 0

        // Process in batches of maxConcurrent
        var index = 0
        while index < total {
            let batchEnd = min(index + maxConcurrent, total)
            let batchURLs = Array(fileURLs[index..<batchEnd])
            let batchStart = index

            // Run this batch concurrently
            let results: [(Int, OCRResult)] = await withTaskGroup(of: (Int, OCRResult).self) { group in
                for (offset, url) in batchURLs.enumerated() {
                    let globalIndex = batchStart + offset
                    group.addTask {
                        let result = await Self.performOCR(imageURL: url, provider: provider, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey)
                        return (globalIndex, result)
                    }
                }
                var collected: [(Int, OCRResult)] = []
                for await item in group { collected.append(item) }
                return collected
            }

            // Back on main actor: update state and generate PDFs
            for (globalIndex, result) in results {
                jobs[globalIndex].result = result
                jobs[globalIndex].status = result.text != nil ? .succeeded : .failed
                if result.text == nil {
                    failedFiles.append(jobs[globalIndex].sourceURL.lastPathComponent)
                }
                let pdfGen = PDFGenerator()
                let srcURL = fileURLs[globalIndex]
                let outputURL = outputDirectory.appendingPathComponent(
                    srcURL.deletingPathExtension().lastPathComponent + ".pdf"
                )
                try? pdfGen.generate(imageURL: srcURL, result: result, model: model, outputURL: outputURL)
            }

            completed += batchURLs.count
            progress = Double(completed) / Double(total)
            statusMessage = "Processed \(completed)/\(total)…"
            index = batchEnd
        }
    }

    // nonisolated static so it can be called from task group without crossing actor boundary
    private static func performOCR(
        imageURL: URL,
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String
    ) async -> OCRResult {
        do {
            switch provider {
            case .anthropic:
                let client = AnthropicClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                return try await client.ocr(imageURL: imageURL)
            case .gemini:
                let client = GeminiClient(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
                return try await client.ocr(imageURL: imageURL)
            case .mistral:
                let client = MistralClient(apiKey: apiKey, model: model)
                return try await client.ocr(imageURL: imageURL)
            }
        } catch {
            return OCRResult(text: nil, errorMessage: error.localizedDescription, errorCode: nil)
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
        lines.append("")

        if failedFiles.isEmpty {
            lines.append("All files processed successfully.")
        } else {
            lines.append("Files that did not produce OCR text:")
            for f in failedFiles {
                let job = jobs.first { $0.sourceURL.lastPathComponent == f }
                let reason = job?.result?.errorMessage ?? "Unknown error"
                let code = job?.result?.errorCode.map { " [\($0)]" } ?? ""
                lines.append("  • \(f)\(code): \(reason)")
            }
        }

        let content = lines.joined(separator: "\n")
        let timestamp = Int(Date().timeIntervalSince1970)
        let logURL = outputDirectory.appendingPathComponent("OCR_Log_\(timestamp).txt")
        try? content.write(to: logURL, atomically: true, encoding: .utf8)
    }
}
