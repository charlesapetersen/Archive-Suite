import AppKit

/// Pure (nonisolated) bridge between Markdown strings and styled `NSAttributedString`.
///
/// - `parse(markdown:)` — Markdown → styled `NSAttributedString` (read path)
/// - `serialize(_:)` — styled `NSAttributedString` → CommonMark (write path, NET-NEW)
///
/// Round-trip policy (00-overview §6): the supported subset is idempotent —
/// `serialize(parse(md))` == `normalize(md)`, and a second round-trip is a no-op.
/// Unsupported visual styling is dropped on serialize; **text is never dropped**.
///
/// Block headers (`<!-- block: … -->`) are parsed into `BlockHeaderAttachment` chips
/// in styled mode and serialized back verbatim. Raw mode shows them as plain text.
enum MarkdownBridge {

    // MARK: - Image regex

    /// Matches `![alt](path)` inline image references in Markdown text.
    private static let imagePattern = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#
    )

    /// Placeholder prefix used to protect image refs from Apple's Markdown parser.
    private static let imageTokenPrefix = "\u{FFFC}IMG:"

    private struct ImageRef {
        let alt: String
        let path: String
        let token: String
    }

    // MARK: - Parse (Markdown → styled NSAttributedString)

    /// Parse a Markdown string into a styled `NSAttributedString` with our custom
    /// `noteBlockKind` / `noteInlineCode` / `noteImageRelPath` / `noteBlockSource`
    /// attributes stamped for the serializer.
    ///
    /// Block headers (`<!-- block: … -->`) become non-editable chip attachments.
    /// If `assetStore` is provided, inline images are loaded as thumbnails; otherwise
    /// they get a missing-asset placeholder (rel-path is always preserved).
    @MainActor
    static func parse(markdown: String, fontSize: CGFloat = 14,
                       assetStore: EditorAssetStore? = nil,
                       onRevealBlock: (@Sendable (SourceAnchor) -> Void)? = nil,
                       onPreviewBlock: ((SourceAnchor, NSView) -> Void)? = nil,
                       onJumpBlock: (@Sendable (SourceAnchor) -> Void)? = nil,
                       passageSummaries: [ItemSummary] = []) -> NSAttributedString {
        if markdown.isEmpty {
            return NSAttributedString(string: "")
        }

        // Split into blocks using the storage-layer BlockParser
        let (leadingText, blocks) = BlockParser.parse(markdown)

        // If no block headers, parse the whole thing as a single body
        if blocks.isEmpty {
            return parseSingleBody(markdown, fontSize: fontSize, assetStore: assetStore)
        }

        let result = NSMutableAttributedString()

        // Leading text before the first block header
        if let leading = leadingText, !leading.isEmpty {
            let parsed = parseSingleBody(leading, fontSize: fontSize, assetStore: assetStore)
            result.append(parsed)
        }

        // Each block: chip attachment + body
        for block in blocks {
            let chipStr = buildChipAttributedString(
                block: block, fontSize: fontSize, onReveal: onRevealBlock,
                onPreview: onPreviewBlock, onJump: onJumpBlock, passageSummaries: passageSummaries
            )
            result.append(chipStr)

            // Parse the block body (the markdown after the header)
            if !block.markdown.isEmpty {
                let bodyParsed = parseSingleBody(
                    block.markdown, fontSize: fontSize, assetStore: assetStore
                )
                result.append(bodyParsed)
            }
        }

        return result
    }

    /// Build an `NSAttributedString` containing a single chip attachment character
    /// for a block header.
    @MainActor
    private static func buildChipAttributedString(
        block: Block, fontSize: CGFloat,
        onReveal: (@Sendable (SourceAnchor) -> Void)?,
        onPreview: ((SourceAnchor, NSView) -> Void)? = nil,
        onJump: (@Sendable (SourceAnchor) -> Void)? = nil,
        passageSummaries: [ItemSummary] = []
    ) -> NSAttributedString {
        let anchor = block.source ?? SourceAnchor()
        let box = SourceAnchorBox(
            anchor: anchor,
            kind: block.kind,
            unknownHeaderFields: block.unknownHeaderFields,
            thumbRef: block.source?.thumbRef
        )
        let attachment = BlockHeaderAttachment(sourceBox: box)
        attachment.onReveal = onReveal
        attachment.onPreview = onPreview
        attachment.onJump = onJump
        // W7-S3: for a note-passage (extract) chip, resolve the source note's CURRENT title/date and
        // whether it still exists, so the chip prefers the live label and greys a removed source.
        if anchor.notePassageTarget != nil, !passageSummaries.isEmpty {
            attachment.passageLiveLabel = NotePassageResolve.chipLabel(anchor: anchor, among: passageSummaries)
            attachment.passageSourceMissing = NotePassageResolve.isSourceMissing(anchor: anchor, among: passageSummaries)
        }

        let attachStr = NSMutableAttributedString(attachment: attachment)
        let range = NSRange(location: 0, length: attachStr.length)
        attachStr.addAttribute(.noteBlockSource, value: box, range: range)
        // Stamp plain block kind so serializer doesn't try to interpret chip as formatted text
        attachStr.addAttribute(.noteBlockKind, value: BlockKind.plain, range: range)
        attachStr.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize), range: range)

        // Add newline after chip so body text starts on the next line
        let newline = NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.textColor,
            .noteBlockKind: BlockKind.plain
        ])
        let combined = NSMutableAttributedString()
        combined.append(attachStr)
        combined.append(newline)
        return combined
    }

    /// Parse a single body segment (no block headers) into styled attributed string.
    @MainActor
    private static func parseSingleBody(_ markdown: String, fontSize: CGFloat = 14,
                                         assetStore: EditorAssetStore? = nil) -> NSAttributedString {
        if markdown.isEmpty {
            return NSAttributedString(string: "")
        }

        // Pre-extract image references so Apple's parser doesn't strip them.
        let (cleaned, imageRefs) = extractImageReferences(markdown)

        // Use Apple's CommonMark parser (AttributedString API) for semantic attributes
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        let semantic: AttributedString
        if let parsed = try? AttributedString(markdown: cleaned, options: options) {
            semantic = parsed
        } else {
            return NSAttributedString(string: markdown, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor.textColor,
                .noteBlockKind: BlockKind.plain
            ])
        }

        let styled = MarkdownStyler.style(semantic, fontSize: fontSize)

        if !imageRefs.isEmpty {
            restoreImageAttachments(in: styled, refs: imageRefs, assetStore: assetStore)
        }

        return styled
    }

    // MARK: - Insert block (seam for W4)

    /// Insert a source block at the given location in the text storage.
    /// Returns the attributed string to insert (chip + newline).
    @MainActor
    static func buildInsertableBlock(
        kind: Block.Kind = .readerPage,
        anchor: SourceAnchor,
        unknownHeaderFields: [(String, String)] = [],
        fontSize: CGFloat = 14,
        onReveal: (@Sendable (SourceAnchor) -> Void)? = nil,
        onPreview: ((SourceAnchor, NSView) -> Void)? = nil,
        onJump: (@Sendable (SourceAnchor) -> Void)? = nil,
        passageSummaries: [ItemSummary] = []
    ) -> NSAttributedString {
        let block = Block(
            kind: kind, source: anchor, markdown: "",
            unknownHeaderFields: unknownHeaderFields
        )
        return buildChipAttributedString(
            block: block, fontSize: fontSize, onReveal: onReveal,
            onPreview: onPreview, onJump: onJump, passageSummaries: passageSummaries
        )
    }

    // MARK: - Image extraction (pre-parse)

    /// Replace `![alt](path)` with unique placeholder tokens, returning the cleaned
    /// text and an ordered list of image references.
    private static func extractImageReferences(_ markdown: String) -> (String, [ImageRef]) {
        let nsString = markdown as NSString
        let matches = imagePattern.matches(in: markdown,
                                           range: NSRange(location: 0, length: nsString.length))
        if matches.isEmpty { return (markdown, []) }

        var refs: [ImageRef] = []
        var result = ""
        var lastEnd = 0

        for match in matches {
            let fullRange = match.range
            let alt = nsString.substring(with: match.range(at: 1))
            let path = nsString.substring(with: match.range(at: 2))
            let token = "\(imageTokenPrefix)\(refs.count)\u{FFFC}"
            refs.append(ImageRef(alt: alt, path: path, token: token))

            result += nsString.substring(with: NSRange(location: lastEnd,
                                                        length: fullRange.location - lastEnd))
            result += token
            lastEnd = fullRange.location + fullRange.length
        }

        if lastEnd < nsString.length {
            result += nsString.substring(from: lastEnd)
        }

        return (result, refs)
    }

    /// Replace placeholder tokens in the styled result with actual image attachments.
    @MainActor
    private static func restoreImageAttachments(in styled: NSMutableAttributedString,
                                                 refs: [ImageRef],
                                                 assetStore: EditorAssetStore?) {
        // Process in reverse so ranges stay valid
        for ref in refs.reversed() {
            let tokenRange = (styled.string as NSString).range(of: ref.token)
            guard tokenRange.location != NSNotFound else { continue }

            let thumbnail: NSImage?
            if let store = assetStore, let url = store.resolveAsset(ref.path) {
                thumbnail = InlineImageAttachment.loadThumbnail(
                    from: url, cacheKey: ref.path
                )
            } else {
                thumbnail = nil
            }

            let attachment = InlineImageAttachment(
                relativePath: ref.path, altText: ref.alt, thumbnail: thumbnail
            )
            let attachStr = NSMutableAttributedString(attachment: attachment)
            attachStr.addAttribute(.noteImageRelPath, value: ref.path,
                                   range: NSRange(location: 0, length: attachStr.length))

            // Preserve block kind from surrounding context
            if tokenRange.location > 0,
               let kind = styled.attribute(.noteBlockKind, at: tokenRange.location - 1,
                                           effectiveRange: nil) {
                attachStr.addAttribute(.noteBlockKind, value: kind,
                                       range: NSRange(location: 0, length: attachStr.length))
            }

            styled.replaceCharacters(in: tokenRange, with: attachStr)
        }
    }

    // MARK: - Serialize (styled NSAttributedString → CommonMark)

    /// Serialize a styled `NSAttributedString` (with our custom attributes) back to CommonMark.
    /// Text is never dropped; only unmodeled visual styling is lost.
    ///
    /// Block-header chip characters (`noteBlockSource` attr) are serialized as
    /// `<!-- block: kind ... -->` headers with optional `![display](thumb)` lines.
    @MainActor
    static func serialize(_ attributed: NSAttributedString) -> String {
        if attributed.length == 0 { return "" }

        // Walk the attributed string, splitting on chip boundaries
        var result = ""
        var i = 0
        let fullLen = attributed.length

        while i < fullLen {
            // Check for a block-header chip at this position
            if let box = attributed.attribute(.noteBlockSource, at: i,
                                              effectiveRange: nil) as? SourceAnchorBox {
                // Emit the block header
                result += serializeBlockHeader(box)
                i += 1 // skip the chip attachment character

                // Skip the newline after chip if present
                if i < fullLen, (attributed.string as NSString).character(at: i) == 0x0A { // '\n'
                    i += 1
                }
                continue
            }

            // Find the extent of non-chip content
            var end = i + 1
            while end < fullLen {
                if attributed.attribute(.noteBlockSource, at: end,
                                        effectiveRange: nil) is SourceAnchorBox {
                    break
                }
                end += 1
            }

            // Serialize this body segment
            let bodyRange = NSRange(location: i, length: end - i)
            let bodyStr = serializeBodySegment(attributed, range: bodyRange)
            result += bodyStr
            i = end
        }

        return result
    }

    /// Serialize a `SourceAnchorBox` back to the `<!-- block: ... -->` header format.
    private static func serializeBlockHeader(_ box: SourceAnchorBox) -> String {
        let block = Block(
            kind: box.kind,
            source: box.anchor,
            markdown: "",
            unknownHeaderFields: box.unknownHeaderFields
        )
        // Reuse BlockParser.serialize for the header, then extract just the header
        // (it appends the empty markdown, which is fine).
        var header = BlockParser.serialize(leadingText: nil, blocks: [block])
        // BlockParser.serialize emits the header only (markdown is ""), no trailing content.
        // If there's a thumbRef, emit the thumb line after the header.
        if let thumb = box.thumbRef {
            let display = box.anchor.display ?? ""
            header += "![\(display)](\(thumb))\n"
        }
        return header
    }

    /// Serialize a body segment (no chips) using the existing paragraph/inline logic.
    private static func serializeBodySegment(_ attributed: NSAttributedString,
                                              range: NSRange) -> String {
        let sub = attributed.attributedSubstring(from: range)
        if sub.length == 0 { return "" }

        let paragraphs = collectParagraphs(sub)
        var lines: [String] = []

        for para in paragraphs {
            let line = serializeParagraph(sub, range: para.range, kind: para.kind)
            lines.append(line)
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

            // Skip block-header chip characters (already handled by the caller)
            if attrs[.noteBlockSource] is SourceAnchorBox {
                return
            }

            // Check for inline image attachment — emit ![alt](path)
            if let relPath = attrs[.noteImageRelPath] as? String {
                let alt: String
                if let attach = attrs[.attachment] as? InlineImageAttachment {
                    alt = attach.altText
                } else {
                    alt = ""
                }
                result += "![\(alt)](\(relPath))"
                return
            }

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
