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
    @MainActor
    static func style(_ source: AttributedString, fontSize: CGFloat = 14) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: fontSize)

        for run in source.runs {
            let runText = String(source[run.range].characters)
            let attrs = buildAttributes(run: run, fontSize: fontSize, bodyFont: bodyFont)
            result.append(NSAttributedString(string: runText, attributes: attrs))
        }

        return result
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
