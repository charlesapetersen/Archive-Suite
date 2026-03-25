import Foundation

@MainActor
class TaggingProcessor: ObservableObject {
    @Published var jobs: [TaggingJob] = []
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    @Published var segments: [DocumentSegment] = []

    private let maxConcurrent = 3

    func startTagging(
        files: [URL],
        ocrTexts: [String],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String
    ) async {
        guard !files.isEmpty else { return }
        isProcessing = true
        progress = 0
        jobs = files.map { TaggingJob(sourceURL: $0) }
        statusMessage = "Segmenting documents…"

        // Segment documents
        let segmenter = DocumentSegmenter()
        segments = segmenter.segment(files: files, texts: ocrTexts)
        statusMessage = "Found \(segments.count) document segments. Generating tags…"

        let generator = TagGenerator()
        let total = segments.count
        var completed = 0

        for (segIndex, segment) in segments.enumerated() {
            let nearby = Array(segments[max(0, segIndex - 3)..<segIndex]
                             + segments[min(segIndex + 1, segments.count)..<min(segIndex + 4, segments.count)])

            let tags = await generator.generateTags(
                for: segment,
                nearbySegments: nearby,
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey
            )

            // Apply tags to each image file in the segment
            for fileURL in segment.imageURLs {
                try? MacOSTagger.applyTags(tags, to: fileURL)
                // Also apply to any associated PDF output
                let pdfURL = fileURL.deletingPathExtension().appendingPathExtension("pdf")
                if FileManager.default.fileExists(atPath: pdfURL.path) {
                    try? MacOSTagger.applyTags(tags, to: pdfURL)
                }
                // Update job status
                if let jobIndex = jobs.firstIndex(where: { $0.sourceURL == fileURL }) {
                    jobs[jobIndex].appliedTags = tags.allTags
                    jobs[jobIndex].status = .succeeded
                }
            }

            completed += 1
            progress = Double(completed) / Double(total)
            statusMessage = "Tagging segment \(completed)/\(total)…"
        }

        isProcessing = false
        statusMessage = "Tagging complete. \(segments.count) segments tagged."
    }
}
