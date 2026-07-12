import AppKit

/// Pure (nonisolated) bridge between Markdown strings and styled `NSAttributedString`.
///
/// - `parse(markdown:)` — Markdown → styled `NSAttributedString` (read path)
/// - `serialize(_:)` — styled `NSAttributedString` → CommonMark (write path, NET-NEW)
///
/// Round-trip policy (00-overview §6): the supported subset is idempotent —
/// `serialize(parse(md))` == `normalize(md)`, and a second round-trip is a no-op.
/// Unsupported visual styling is dropped on serialize; **text is never dropped**.
enum MarkdownBridge {

    // MARK: - Parse (Markdown → styled NSAttributedString)

    /// Parse a Markdown string into a styled `NSAttributedString` with our custom
    /// `noteBlockKind` / `noteInlineCode` attributes stamped for the serializer.
    @MainActor
    static func parse(markdown: String, fontSize: CGFloat = 14) -> NSAttributedString {
        if markdown.isEmpty {
            return NSAttributedString(string: "")
        }

        // Use Apple's CommonMark parser (AttributedString API) for semantic attributes
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        let semantic: AttributedString
        if let parsed = try? AttributedString(markdown: markdown, options: options) {
            semantic = parsed
        } else {
            // Fallback: plain text with no styling
            return NSAttributedString(string: markdown, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor.textColor,
                .noteBlockKind: BlockKind.plain
            ])
        }

        // Apply visual styling + stamp our custom keys
        return MarkdownStyler.style(semantic, fontSize: fontSize)
    }

    // MARK: - Serialize (styled NSAttributedString → CommonMark)

    /// Serialize a styled `NSAttributedString` (with our custom attributes) back to CommonMark.
    /// Text is never dropped; only unmodeled visual styling is lost.
    @MainActor
    static func serialize(_ attributed: NSAttributedString) -> String {
        if attributed.length == 0 { return "" }

        // Split into "paragraphs" by noteBlockKind attribute spans.
        // Apple's parser may concatenate list items without newlines, so we
        // can't rely on text lineRange — we split on attribute boundaries.
        let paragraphs = collectParagraphs(attributed)
        var lines: [String] = []
        var prevWasCodeBlock = false

        for para in paragraphs {
            let line = serializeParagraph(attributed, range: para.range, kind: para.kind)

            // Insert blank line between different block types for readability
            // (except between consecutive list items of the same kind)
            if !lines.isEmpty && !prevWasCodeBlock {
                let isListItem: Bool
                if case .listItem = para.kind { isListItem = true } else { isListItem = false }
                let prevIsListItem: Bool
                if case .listItem = paragraphs[lines.count - 1].kind { prevIsListItem = true }
                else { prevIsListItem = false }
                if !isListItem || !prevIsListItem {
                    // Only add blank separator between different types
                    // (paragraphs already get separated by \n from join)
                }
            }

            lines.append(line)
            if case .codeBlock = para.kind { prevWasCodeBlock = true } else { prevWasCodeBlock = false }
        }

        return lines.joined(separator: "\n")
    }

    /// A paragraph as determined by noteBlockKind attribute spans.
    private struct Para {
        let range: NSRange
        let kind: BlockKind
    }

    /// Collect contiguous runs that share the same noteBlockKind identity.
    /// Each list item with a different ordinal is a separate paragraph.
    private static func collectParagraphs(_ attributed: NSAttributedString) -> [Para] {
        var result: [Para] = []
        let fullRange = NSRange(location: 0, length: attributed.length)

        attributed.enumerateAttribute(.noteBlockKind, in: fullRange) { value, range, _ in
            let kind = (value as? BlockKind) ?? .plain
            result.append(Para(range: range, kind: kind))
        }

        return result
    }

    // MARK: - Paragraph serialization

    private static func serializeParagraph(_ storage: NSAttributedString,
                                           range: NSRange,
                                           kind: BlockKind) -> String {
        // Get the inline-serialized content for this paragraph
        let inlineContent = serializeInlineRuns(storage, range: range)
        // Strip trailing newline if present
        let trimmed = inlineContent.hasSuffix("\n")
            ? String(inlineContent.dropLast())
            : inlineContent

        switch kind {
        case .heading(let level):
            let prefix = String(repeating: "#", count: min(level, 6))
            return "\(prefix) \(trimmed)"

        case .blockquote:
            return "> \(trimmed)"

        case .codeBlock(let hint):
            // Code blocks: the whole paragraph is the code content.
            // We use fenced code blocks with ``` delimiters.
            let fence = "```"
            let lang = hint ?? ""
            return "\(fence)\(lang)\n\(trimmed)\n\(fence)"

        case .listItem(let ordered, let depth, let ordinal):
            let indent = String(repeating: "    ", count: depth)
            let bullet = ordered ? "\(ordinal). " : "- "
            return "\(indent)\(bullet)\(trimmed)"

        case .plain:
            return trimmed
        }
    }

    // MARK: - Inline run serialization

    private static func serializeInlineRuns(_ storage: NSAttributedString,
                                            range: NSRange) -> String {
        var result = ""
        storage.enumerateAttributes(in: range) { attrs, runRange, _ in
            let runText = (storage.string as NSString).substring(with: runRange)

            // Check for inline code (belt-and-suspenders: custom attr + mono font)
            let isCode = attrs[.noteInlineCode] as? Bool == true

            // Check for bold/italic from font traits
            let font = attrs[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let isBold = traits.contains(.boldFontMask)
            let isItalic = traits.contains(.italicFontMask)

            // Check for link
            let linkURL = attrs[.link]

            // Check block kind to avoid double-escaping code blocks
            let blockKind = attrs[.noteBlockKind] as? BlockKind
            let inCodeBlock: Bool
            if case .codeBlock = blockKind { inCodeBlock = true } else { inCodeBlock = false }

            if inCodeBlock {
                // Inside a code block, emit verbatim (no inline formatting)
                result += runText
                return
            }

            if isCode {
                let escaped = wrapInlineCode(runText)
                result += escaped
            } else {
                var inner = escapeMarkdown(runText)

                if let url = linkURL {
                    let urlStr: String
                    if let u = url as? URL {
                        urlStr = u.absoluteString
                    } else if let s = url as? String {
                        urlStr = s
                    } else {
                        urlStr = String(describing: url)
                    }
                    inner = "[\(inner)](\(urlStr))"
                } else {
                    if isBold && isItalic {
                        inner = "***\(inner)***"
                    } else if isBold {
                        // Don't wrap headings in ** (headings are already bold visually)
                        if case .heading = blockKind {
                            // heading text: no extra bold wrap
                        } else {
                            inner = "**\(inner)**"
                        }
                    } else if isItalic {
                        inner = "*\(inner)*"
                    }
                }

                result += inner
            }
        }
        return result
    }

    // MARK: - Escaping

    /// Escape CommonMark metacharacters in plain text runs.
    private static func escapeMarkdown(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for (i, ch) in text.enumerated() {
            switch ch {
            case "\\", "*", "_", "`", "[", "]":
                result.append("\\")
                result.append(ch)
            case "#":
                // Only escape # at line start
                if i == 0 {
                    result.append("\\")
                }
                result.append(ch)
            default:
                result.append(ch)
            }
        }
        return result
    }

    /// Wrap text in inline code delimiters, choosing `` over ` if the text contains backticks.
    private static func wrapInlineCode(_ text: String) -> String {
        if text.contains("`") {
            return "`` \(text) ``"
        }
        return "`\(text)`"
    }
}
