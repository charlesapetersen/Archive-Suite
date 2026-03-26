import Foundation

/// Shared prompt builder for all providers (except Mistral OCR which has a dedicated endpoint)
struct OCRPrompt {

    static func build(previousText: String?, previousImageIncluded: Bool) -> String {
        var prompt = """
        You are processing a photograph of a document from a historical archive.

        TASK 1 — CLASSIFY this image. On the VERY FIRST LINE of your response, write exactly one of these tags:
        [box_label] — A photograph of an archival box label, container, or accession record
        [folder_label] — A photograph of a folder divider, section separator, or filing label
        [document_start] — The beginning of a new document (article, letter, memo, report, etc.)
        [document_continuation] — A continuation page of the same document as the previous page

        TASK 2 — TRANSCRIBE all text visible in this document image exactly as it appears. Preserve the original formatting, line breaks, paragraph structure, and layout as closely as possible. Output only the transcribed text with no commentary.

        Your response format must be:
        [classification_tag]
        (transcribed text here)
        """

        if let prevText = previousText, !prevText.isEmpty {
            prompt += "\n\n"
            if previousImageIncluded {
                prompt += "The FIRST image is the previous page. The SECOND image is the page to classify and transcribe.\n\n"
            }
            prompt += "For context, the previous page's text ended with:\n\"\"\"\n\(prevText)\n\"\"\"\nUse this context to determine whether this page continues the same document or starts a new one."
        }

        return prompt
    }

    /// Parse the LLM response into classification + OCR text
    static func parseResponse(_ raw: String) -> (classification: DocumentClassification?, text: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }

        let lines = trimmed.components(separatedBy: .newlines)
        guard let firstLine = lines.first else { return (nil, trimmed) }

        // Try to extract classification tag from first line
        let classification = parseClassificationTag(firstLine)

        let text: String
        if classification != nil {
            // Remove the classification line, return the rest as OCR text
            text = lines.dropFirst()
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // No classification found — return all text as OCR
            text = trimmed
        }

        return (classification, text.isEmpty ? nil : text)
    }

    private static func parseClassificationTag(_ line: String) -> DocumentClassification? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.contains("[box_label]") || trimmed.contains("[box label]") {
            return .boxLabel
        } else if trimmed.contains("[folder_label]") || trimmed.contains("[folder label]") {
            return .folderLabel
        } else if trimmed.contains("[document_start]") || trimmed.contains("[document start]") {
            return .documentStart
        } else if trimmed.contains("[document_continuation]") || trimmed.contains("[document continuation]") {
            return .documentContinuation
        }
        return nil
    }
}
