import AppKit

// MARK: - Custom attribute keys

extension NSAttributedString.Key {
    /// Paragraph-level block kind: `BlockKind` value.
    static let noteBlockKind = NSAttributedString.Key("an.blockKind")
    /// Inline code run marker (Bool).
    static let noteInlineCode = NSAttributedString.Key("an.inlineCode")
    /// Relative asset path on an inline-image attachment char (String).
    static let noteImageRelPath = NSAttributedString.Key("an.imageRelPath")
    /// Source anchor on a block-header chip char (SourceAnchorBox).
    static let noteBlockSource = NSAttributedString.Key("an.blockSource")
    /// The whitespace the Styler inserts BETWEEN two blocks (Bool). Not the operator's text: the
    /// serializer reads it to tell a paragraph break from a newline someone typed
    /// (`W3.notes-editor-blankline-collapse`).
    static let noteBlockSeparator = NSAttributedString.Key("an.blockSeparator")
}

// MARK: - BlockKind (paragraph-level semantic)

/// Semantic paragraph kind stamped by the Styler, read by the serializer.
enum BlockKind: Sendable, Equatable {
    case plain
    case heading(Int)        // 1–6
    case blockquote
    case codeBlock(String?)  // optional language hint
    case listItem(ordered: Bool, depth: Int, ordinal: Int)
}

// MARK: - Styler (semantic → visual via AttributedString)

/// Converts an `AttributedString` (from Apple's Markdown parser, which carries
/// `presentationIntent` / `inlinePresentationIntent`) into a visually styled
/// `NSMutableAttributedString` stamped with our custom keys.
enum MarkdownStyler {

    /// Parse an `AttributedString` with Apple's semantic attributes into an
    /// `NSMutableAttributedString` with visual styles + our custom keys.
    ///
    /// **Block boundaries are re-materialised here as text** (`W3.notes-editor-blankline-collapse`).
    /// Apple's Markdown parser models them as `presentationIntent` identity ONLY — the parsed
    /// characters of `"A\n\nB"` are `"AB"`, with no separator at all — so concatenating the runs
    /// glued every note's paragraphs together, in the editor's own display AND in what the editor
    /// then serialized back to disk (measured end-to-end through `NotesModel.setBody`). Restoring
    /// the separator here fixes both faces at once, and is why the serializer can keep emitting a
    /// paragraph's text verbatim.
    @MainActor
    static func style(_ source: AttributedString, fontSize: CGFloat = 14) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: fontSize)
        var previous: (intent: PresentationIntent?, attrs: [NSAttributedString.Key: Any])?

        for run in source.runs {
            let runText = String(source[run.range].characters)
            let attrs = buildAttributes(run: run, fontSize: fontSize, bodyFont: bodyFont)

            if let previous, previous.intent != run.presentationIntent {
                let separator = blockSeparator(from: previous.intent, to: run.presentationIntent)
                result.append(NSAttributedString(string: separator,
                                                 attributes: separatorAttributes(after: previous.attrs,
                                                                                 bodyFont: bodyFont)))
            }

            result.append(NSAttributedString(string: runText, attributes: attrs))
            previous = (run.presentationIntent, attrs)
        }

        return result
    }

    /// The text that separates two adjacent blocks: a blank line, except between list items, which
    /// stay tight. (Any two list items count as "the same list" — a nested sublist or an
    /// immediately-following list of the other marker type both round-trip correctly without the
    /// blank line, and both would render wrong with one.)
    private static func blockSeparator(from previous: PresentationIntent?,
                                       to next: PresentationIntent?) -> String {
        isListItem(previous) && isListItem(next) ? "\n" : "\n\n"
    }

    private static func isListItem(_ intent: PresentationIntent?) -> Bool {
        guard let intent else { return false }
        return intent.components.contains { if case .listItem = $0.kind { return true } else { return false } }
    }

    /// Block-level attributes only. The separator belongs to the block it FOLLOWS (so it serializes
    /// as that paragraph's trailing newline), but it must not inherit that block's last INLINE run:
    /// a `\n\n` carrying `.link`, `.noteInlineCode` or a bold font would be serialized inside the
    /// construct — `"…**bold**"` would come back as `"**bold\n\n**"`.
    private static func separatorAttributes(after attrs: [NSAttributedString.Key: Any],
                                            bodyFont: NSFont) -> [NSAttributedString.Key: Any] {
        var separatorAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.textColor,
            .noteBlockSeparator: true
        ]
        separatorAttrs[.noteBlockKind] = attrs[.noteBlockKind]
        if let paragraphStyle = attrs[.paragraphStyle] { separatorAttrs[.paragraphStyle] = paragraphStyle }
        return separatorAttrs
    }

    private static func buildAttributes(
        run: AttributedString.Runs.Run,
        fontSize: CGFloat,
        bodyFont: NSFont
    ) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.textColor
        ]

        // Determine block kind from presentationIntent
        let kind: BlockKind
        if let intent = run.presentationIntent {
            kind = blockKind(from: intent)
        } else {
            kind = .plain
        }
        attrs[.noteBlockKind] = kind

        // Apply block-level visuals and determine base font
        var font = bodyFont
        switch kind {
        case .heading(let level):
            let sizes: [CGFloat] = [0, 28, 24, 20, 17, 15, 14]
            let size = level >= 1 && level <= 6 ? sizes[level] : fontSize
            font = NSFont.boldSystemFont(ofSize: size)

        case .blockquote:
            attrs[.foregroundColor] = NSColor.secondaryLabelColor
            let ps = NSMutableParagraphStyle()
            ps.headIndent = 20
            ps.firstLineHeadIndent = 20
            attrs[.paragraphStyle] = ps

        case .codeBlock:
            font = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
            attrs[.backgroundColor] = NSColor.quaternaryLabelColor

        case .listItem(_, let depth, _):
            let ps = NSMutableParagraphStyle()
            let indent = CGFloat(depth + 1) * 20
            ps.headIndent = indent
            ps.firstLineHeadIndent = max(indent - 16, 0)
            attrs[.paragraphStyle] = ps

        case .plain:
            break
        }

        // Apply inline styles from inlinePresentationIntent
        if let inlineIntent = run.inlinePresentationIntent {
            if inlineIntent.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if inlineIntent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            if inlineIntent.contains(.code) {
                font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                attrs[.noteInlineCode] = true
                attrs[.backgroundColor] = NSColor.quaternaryLabelColor
            }
        }

        attrs[.font] = font

        // Handle links
        if let link = run.link {
            attrs[.link] = link
        }

        return attrs
    }

    // MARK: - Block kind extraction

    private static func blockKind(from intent: PresentationIntent) -> BlockKind {
        for component in intent.components {
            switch component.kind {
            case .header(level: let level):
                return .heading(level)
            case .codeBlock(languageHint: let hint):
                return .codeBlock(hint)
            case .blockQuote:
                return .blockquote
            case .listItem(ordinal: let ordinal):
                let depth = listDepth(intent)
                let ordered = isOrdered(intent)
                return .listItem(ordered: ordered, depth: depth, ordinal: ordinal)
            default:
                continue
            }
        }
        return .plain
    }

    private static func listDepth(_ intent: PresentationIntent) -> Int {
        var depth = 0
        for component in intent.components {
            switch component.kind {
            case .orderedList, .unorderedList:
                depth += 1
            default:
                break
            }
        }
        return max(depth - 1, 0)
    }

    private static func isOrdered(_ intent: PresentationIntent) -> Bool {
        for component in intent.components {
            if case .orderedList = component.kind { return true }
            if case .unorderedList = component.kind { return false }
        }
        return false
    }
}
