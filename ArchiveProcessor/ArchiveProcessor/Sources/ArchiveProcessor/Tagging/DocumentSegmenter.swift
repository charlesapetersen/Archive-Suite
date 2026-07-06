import Foundation

// MARK: - Document Segment

struct DocumentSegment {
    var pdfURLs: [URL]
    var isBox: Bool = false
    var isFolder: Bool = false
    var texts: [String] = []
    var combinedText: String { texts.joined(separator: "\n\n") }
}

// MARK: - Segmenter

struct DocumentSegmenter {

    /// Segment files using LLM-provided classifications.
    /// Falls back to text heuristics for files without classifications.
    func segment(
        files: [URL],
        classifications: [DocumentClassification?],
        texts: [String]
    ) -> [DocumentSegment] {
        guard !files.isEmpty else { return [] }

        var segments: [DocumentSegment] = []
        var currentFiles: [URL] = []
        var currentTexts: [String] = []

        for index in 0..<files.count {
            let file = files[index]
            let text = index < texts.count ? texts[index] : ""
            let classification = index < classifications.count ? classifications[index] : nil

            switch classification {
            case .boxLabel:
                if !currentFiles.isEmpty {
                    segments.append(DocumentSegment(pdfURLs: currentFiles, texts: currentTexts))
                    currentFiles = []
                    currentTexts = []
                }
                segments.append(DocumentSegment(pdfURLs: [file], isBox: true, texts: [text]))

            case .folderLabel:
                if !currentFiles.isEmpty {
                    segments.append(DocumentSegment(pdfURLs: currentFiles, texts: currentTexts))
                    currentFiles = []
                    currentTexts = []
                }
                segments.append(DocumentSegment(pdfURLs: [file], isFolder: true, texts: [text]))

            case .documentContinuation:
                // Add to current segment (or start new if nothing to continue)
                if currentFiles.isEmpty {
                    // Nothing to continue — treat as new segment start
                }
                currentFiles.append(file)
                currentTexts.append(text)

            case .documentStart, .none:
                // Flush current segment and start a new one
                if !currentFiles.isEmpty {
                    segments.append(DocumentSegment(pdfURLs: currentFiles, texts: currentTexts))
                    currentFiles = []
                    currentTexts = []
                }
                currentFiles.append(file)
                currentTexts.append(text)
            }
        }

        // Flush final segment
        if !currentFiles.isEmpty {
            segments.append(DocumentSegment(pdfURLs: currentFiles, texts: currentTexts))
        }

        return segments
    }
}
