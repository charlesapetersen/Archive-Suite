import Foundation

// MARK: - Document Segment

struct DocumentSegment {
    /// The image files that comprise this document
    var imageURLs: [URL]
    /// Whether this is a box photograph
    var isBox: Bool = false
    /// Whether this is a folder photograph
    var isFolder: Bool = false
    /// OCR text for each page of the document
    var texts: [String] = []
    var combinedText: String { texts.joined(separator: "\n\n") }
}

// MARK: - Segmenter

struct DocumentSegmenter {
    /// Heuristic document segmentation based on OCR text and filenames.
    /// Assumes files are provided in sorted order.
    func segment(files: [URL], texts: [String]) -> [DocumentSegment] {
        guard !files.isEmpty else { return [] }

        var segments: [DocumentSegment] = []
        var currentImages: [URL] = []
        var currentTexts: [String] = []
        var currentIsBox = false
        var currentIsFolder = false

        for (index, (file, text)) in zip(files, texts).enumerated() {
            let textLower = text.lowercased()

            // Hard breaks: box/folder images always stand alone
            let isBox = detectBox(text: text)
            let isFolder = detectFolder(text: text)

            if isBox || isFolder {
                // Flush current segment
                if !currentImages.isEmpty {
                    segments.append(DocumentSegment(imageURLs: currentImages, isBox: currentIsBox, isFolder: currentIsFolder, texts: currentTexts))
                    currentImages = []
                    currentTexts = []
                }
                segments.append(DocumentSegment(imageURLs: [file], isBox: isBox, isFolder: isFolder, texts: [text]))
                currentIsBox = false
                currentIsFolder = false
                continue
            }

            // Detect document start heuristics
            let isNewDoc: Bool
            if index == 0 || currentImages.isEmpty {
                isNewDoc = true
            } else {
                isNewDoc = detectNewDocumentStart(text: text, previousText: currentTexts.last ?? "")
            }

            if isNewDoc && !currentImages.isEmpty {
                segments.append(DocumentSegment(imageURLs: currentImages, isBox: currentIsBox, isFolder: currentIsFolder, texts: currentTexts))
                currentImages = []
                currentTexts = []
                currentIsBox = false
                currentIsFolder = false
            }

            currentImages.append(file)
            currentTexts.append(text)
        }

        // Flush final segment
        if !currentImages.isEmpty {
            segments.append(DocumentSegment(imageURLs: currentImages, isBox: currentIsBox, isFolder: currentIsFolder, texts: currentTexts))
        }

        return segments
    }

    // MARK: - Heuristics

    private func detectBox(text: String) -> Bool {
        let lower = text.lowercased()
        let boxPatterns = ["box \\d", "record group", "rg \\d", "accession", "collection:"]
        return boxPatterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
            || (lower.contains("box") && lower.count < 200)
    }

    private func detectFolder(text: String) -> Bool {
        let lower = text.lowercased()
        let folderPatterns = ["folder \\d", "file \\d", "series \\d"]
        return folderPatterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
            || (lower.contains("folder") && lower.count < 200)
    }

    private func detectNewDocumentStart(text: String, previousText: String) -> Bool {
        // Strong signals that this is the beginning of a new document:

        // 1. All-caps headline (newspaper/magazine article)
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let firstLine = lines.first {
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            if trimmed.count > 5 && trimmed == trimmed.uppercased() && trimmed.filter({ $0.isLetter }).count > 3 {
                return true
            }
        }

        // 2. Letter/memo start: To: / From: / Dear
        let textLower = text.lowercased()
        let docStartPhrases = ["to:", "from:", "dear ", "memorandum", "memo to", "subject:", "re:", "date:"]
        if docStartPhrases.contains(where: { textLower.hasPrefix($0) || textLower.contains("\n\($0)") }) {
            return true
        }

        // 3. Previous page ended mid-paragraph (no clear ending) — continuation
        // If previous text does NOT end with sentence-terminating punctuation, likely continuing
        let prevTrimmed = previousText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentenceEnders: Set<Character> = [".", "!", "?", "\"", "\u{201D}"]
        if let lastChar = prevTrimmed.last, !sentenceEnders.contains(lastChar) {
            // Previous page ran out mid-sentence — this is a continuation, NOT a new doc
            return false
        }

        // 4. Signature line in previous text (end of letter)
        let prevLower = previousText.lowercased()
        let signaturePatterns = ["sincerely", "yours truly", "respectfully", "regards,", "faithfully"]
        if signaturePatterns.contains(where: { prevLower.contains($0) }) {
            return true
        }

        // 5. Report/article title pattern: short line followed by double newline
        if let firstLine = lines.first, firstLine.count < 80, lines.count > 1 {
            let second = lines[1]
            if second.count > 20 { return true }
        }

        // Default: assume continuation
        return false
    }
}
