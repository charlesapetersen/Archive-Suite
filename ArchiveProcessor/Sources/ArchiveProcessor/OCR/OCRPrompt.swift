import Foundation

/// Shared prompt builder for all providers (except Mistral OCR which has a dedicated endpoint)
struct OCRPrompt {

    static func build(previousText: String?, previousImageIncluded: Bool) -> String {
        var prompt = """
        You are classifying and transcribing photographs from a historical archive.

        TASK 1 — CLASSIFY this image. Write exactly one tag on the VERY FIRST LINE:

        [box_label] — An archival STORAGE BOX or its label. Look for: cardboard box, printed/handwritten label with record group numbers, date ranges, or collection identifiers. These are containers, not documents.

        [folder_label] — A FILE FOLDER tab, divider, or separator label. Look for: folder tab or edge, brief handwritten/typed label with a name, topic, or date range. These organize documents within a box.

        [document_start] — The FIRST PAGE of a new document. Strong signals:
          • Letter salutation ("Dear ___") not seen on the previous page
          • A NEW sender/recipient pair (different from the previous document)
          • Memo header ("MEMORANDUM", "TO:", "FROM:") with a new subject or date
          • A distinct title or headline for a new report, article, or form
          • Previous page ended with blank space or a signature (that document ended)
          NOTE: A page with the SAME recipient name and a page number ("Page 2", "- 2 -", "-3-") is a CONTINUATION, not a new document.

        [document_continuation] — A LATER PAGE of the same document. Strong signals:
          • Text continues mid-sentence from the previous page
          • Page number indicators: "Page 2", "- 2 -", "-3-", "p. 4", etc.
          • Recipient name repeated at top with a page number (standard letter format for page 2+)
          • Same letterhead and formatting as the previous page
          • "Continued from..." or "(continued)" text
          • Tables, figures, or appendices belonging to the same document

        When uncertain between [document_start] and [document_continuation], consider: does this page share the same sender, recipient, date, AND format as the previous page? If yes → continuation. If any of these clearly change → new document.

        TASK 2 — TRANSCRIBE all visible text exactly as written. Preserve formatting, line breaks, and layout. No commentary.

        Response format:
        [classification_tag]
        (transcribed text)
        """

        if let prevText = previousText, !prevText.isEmpty {
            prompt += "\n\n"
            if previousImageIncluded {
                prompt += "The FIRST image is the previous page. The SECOND image is the page to classify and transcribe.\n\n"
            }
            prompt += "Previous page ended with:\n\"\"\"\n\(prevText)\n\"\"\"\nDecide: is this the SAME document continuing, or a NEW document? Check for changes in sender, recipient, date, or format. Pages with \"Page 2\" or the same recipient + page number are continuations."
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
