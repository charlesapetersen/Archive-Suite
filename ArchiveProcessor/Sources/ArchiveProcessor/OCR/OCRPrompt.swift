import Foundation

/// Shared prompt builder for all providers (except Mistral OCR which has a dedicated endpoint)
struct OCRPrompt {

    static func build(previousText: String?, previousImageIncluded: Bool, customPrompt: String? = nil) -> String {
        var prompt = """
        You are classifying and transcribing photographs from a historical archive collection.

        TASK 1 — CLASSIFY this image. On the VERY FIRST LINE write exactly one tag:

        [box_label] — A photograph of an archival STORAGE BOX or its label. Physical cues: cardboard box, printed or handwritten label affixed to the box, record group numbers, date ranges, collection identifiers. These are NOT documents — they are containers.

        [folder_label] — A photograph of a FILE FOLDER divider, tab, or separator label. Physical cues: folder tab or edge, handwritten or typed label identifying folder contents, often brief text like a name, topic, or date range. These are NOT documents — they are organizers within a box.

        [document_start] — The FIRST PAGE of a document. Signals include:
          • A letter salutation ("Dear ___")
          • A new date and/or new recipient/sender at the top
          • A memo header ("MEMORANDUM", "TO:", "FROM:", "SUBJECT:")
          • A title, headline, or report heading
          • Letterhead or institutional header from a different organization than the previous page
          • A printed form, table, or list that is clearly a new item
          • The previous page ended mid-page with blank space below (its document ended)
          Even if the topic is the same as the previous page, a new letter or memo is a NEW DOCUMENT.

        [document_continuation] — A later page of the SAME document as the previous page. Signals:
          • Text continues mid-sentence from where the previous page ended
          • Sequential page numbers from the same document (e.g., previous page was "- 3 -", this is "- 4 -")
          • Same formatting, letterhead, and layout as the previous page with text flowing continuously
          A page is ONLY a continuation if it is clearly part of the same single document. When uncertain, prefer [document_start].

        IMPORTANT: These photographs often show multiple papers stacked on top of each other. Other pages may be partially visible in the background. For classification and transcription, focus ONLY on the foreground page — ignore any background pages or partially visible documents.

        TASK 2 — ORIENTATION (CRITICAL). Many of these photographs are rotated sideways or upside down as displayed in the raw pixels. You MUST examine the actual pixel orientation of text in the image — do NOT assume the image is upright just because you can read the text. Look at whether text baselines are horizontal, vertical, or inverted relative to the image frame.
        On line 2, write the clockwise rotation needed to make the image upright:
        [rotate_0] — Text baselines are horizontal and text reads left-to-right normally. Image is already correctly oriented.
        [rotate_90] — Text baselines are vertical, reading bottom-to-top on the left side of the image. Needs 90° clockwise rotation.
        [rotate_180] — Text is upside down (baselines horizontal but text is inverted). Needs 180° rotation.
        [rotate_270] — Text baselines are vertical, reading top-to-bottom on the right side of the image. Needs 270° clockwise rotation.
        IMPORTANT: Examine the raw visual orientation of text carefully. If text appears sideways or upside down in the image, it IS rotated — even if you can still read it.
        When the image shows a folder with a tab, orient based on the folder tab and label, not fragments of documents visible inside the folder.

        TASK 3 — TRANSCRIBE all visible text exactly as it appears, preserving formatting and layout. No commentary.

        FORMAT — Your response MUST begin with the classification tag on line 1, rotation tag on line 2, then the transcribed text:
        [classification_tag]
        [rotate_N]
        (transcribed text)
        """

        if let custom = customPrompt, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\nADDITIONAL CONTEXT from the user:\n\(custom)"
        }

        if let prevText = previousText, !prevText.isEmpty {
            prompt += "\n\n"
            if previousImageIncluded {
                prompt += "The FIRST image is the previous page. The SECOND image is the page you must classify and transcribe.\n\n"
            }
            prompt += "Previous page's text ended with:\n\"\"\"\n\(prevText)\n\"\"\"\nUse this to decide: does the current page continue the SAME document, or is it a NEW document? Look for changes in sender, recipient, date, format, or letterhead. A new date + new recipient = new document, even if the topic is similar."
        }

        return prompt
    }

    /// Parse the LLM response into classification + rotation + OCR text.
    /// Checks the first few lines for classification and rotation tags to handle models that
    /// occasionally emit a blank line or preamble before the tags.
    static func parseResponse(_ raw: String) -> (classification: DocumentClassification?, rotationDegrees: Int, text: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, 0, nil) }

        let lines = trimmed.components(separatedBy: .newlines)

        // Search first 5 lines for classification and rotation tags
        let searchLimit = min(5, lines.count)
        var classification: DocumentClassification?
        var rotationDegrees = 0
        var contentStartLine = 0

        for i in 0..<searchLimit {
            if classification == nil, let cls = parseClassificationTag(lines[i]) {
                classification = cls
                contentStartLine = i + 1
                continue
            }
            if let rot = parseRotationTag(lines[i]) {
                rotationDegrees = rot
                contentStartLine = max(contentStartLine, i + 1)
                break
            }
            // Skip blank lines when searching for rotation tag after classification
            if classification != nil {
                let trimmedLine = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedLine.isEmpty { continue }
                // Non-blank, non-rotation line after classification — stop searching
                break
            }
        }

        if classification == nil {
            // No classification found — return all text as OCR
            return (nil, 0, trimmed)
        }

        let text = lines.dropFirst(contentStartLine)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (classification, rotationDegrees, text.isEmpty ? nil : text)
    }

    /// Build a text-only classification prompt for pre-OCRed text.
    /// Used when PDFs already contain OCR text and only classification is needed.
    static func buildClassificationOnly(text: String, previousText: String?, customPrompt: String? = nil) -> String {
        var prompt = """
        You are classifying a page from a historical archive collection based on its OCR text.

        Classify this text as exactly one of these categories. Respond with ONLY the tag on a single line:

        [box_label] — Text from a storage box label. Indicators: collection names, record group numbers, box numbers, date ranges, library/archive names, accession numbers. Typically short text with identifiers.

        [folder_label] — Text from a folder tab or divider. Indicators: brief label text like a name, topic, or date range, folder identifiers. Very short text.

        [document_start] — First page of a document. Indicators: letter salutation, date header, memo header, title, letterhead, new correspondence.

        [document_continuation] — A later page of the same document as the previous page. Indicators: text continuing mid-sentence, sequential page numbers, same formatting.

        OCR text of this page:
        \"\"\"
        \(text.prefix(2000))
        \"\"\"
        """

        if let prevText = previousText, !prevText.isEmpty {
            prompt += """

            Previous page's text ended with:
            \"\"\"
            \(prevText.suffix(500))
            \"\"\"
            Use this to decide: does the current page continue the same document, or is it new?
            """
        }

        if let custom = customPrompt, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\nADDITIONAL CONTEXT from the user:\n\(custom)"
        }

        prompt += "\n\nRespond with ONLY the classification tag (e.g., [document_start]). Nothing else."

        return prompt
    }

    private static func parseRotationTag(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.contains("[rotate_0]") || trimmed.contains("[rotate 0]") { return 0 }
        if trimmed.contains("[rotate_90]") || trimmed.contains("[rotate 90]") { return 90 }
        if trimmed.contains("[rotate_180]") || trimmed.contains("[rotate 180]") { return 180 }
        if trimmed.contains("[rotate_270]") || trimmed.contains("[rotate 270]") { return 270 }
        return nil
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
