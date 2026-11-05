import AppKit

/// W40.fix-notes-editor-lines — the bullets and numbers of the styled editor's lists. A list item is stored as
/// its text alone (`BlockKind.listItem` on the paragraph; the serializer writes the `- ` or `1. `), and nothing
/// drew a marker for it, so Bulleted List and Numbered List seemed to do nothing: the paragraph moved 4 points.
/// `EditorTextView` draws these in the indent `MarkdownStyler.listParagraphStyle` leaves before the text.
enum ListMarkers {
    /// The indent of one list level, and the width the marker is drawn in.
    static let levelWidth: CGFloat = 24

    struct Marker: Equatable {
        /// The UTF-16 offset of the item's first character.
        let location: Int
        let text: String
        let depth: Int
    }

    static func text(ordered: Bool, depth: Int, ordinal: Int) -> String {
        ordered ? "\(ordinal)." : ["•", "◦", "▪"][min(depth, 2)]
    }

    /// The markers of the list items that start inside `range`, numbered as `MarkdownBridge.serialize` writes
    /// them: from the first item's number, each later item of that level one more, a deeper level numbered on
    /// its own. Scans back to the start of the list `range` begins in, so the numbers are right mid-list.
    static func markers(in storage: NSAttributedString, range: NSRange) -> [Marker] {
        let text = storage.string as NSString
        guard storage.length > 0, range.location <= storage.length else { return [] }
        func kind(_ paragraph: NSRange) -> BlockKind? {
            guard paragraph.location < storage.length else { return nil }
            return storage.attribute(.noteBlockKind, at: paragraph.location, effectiveRange: nil) as? BlockKind
        }
        func isItem(_ kind: BlockKind?) -> Bool { if case .listItem = kind { return true } else { return false } }

        var paragraph = text.paragraphRange(for: NSRange(location: min(range.location, storage.length - 1), length: 0))
        while paragraph.location > 0 {
            let previous = text.paragraphRange(for: NSRange(location: paragraph.location - 1, length: 0))
            guard isItem(kind(previous)) else { break }
            paragraph = previous
        }

        var markers: [Marker] = []
        var levels: [Int: (ordered: Bool, ordinal: Int)] = [:]
        var previousKind: BlockKind?
        let end = NSMaxRange(range)
        while paragraph.location < storage.length, paragraph.location <= end {
            let current = kind(paragraph)
            if case .listItem(let ordered, let depth, let ordinal)? = current {
                // A paragraph read from the file after a separator, with its item's own kind, is that item's
                // second paragraph (the Styler keeps them one newline apart), not a new item.
                let continues = paragraph.location > 0 && current == previousKind
                    && storage.attribute(.noteBlockSeparator, at: paragraph.location - 1, effectiveRange: nil) as? Bool == true
                if !continues {
                    levels = levels.filter { $0.key <= depth }
                    let before = levels[depth]
                    let number = ordered && before?.ordered == true ? before!.ordinal + 1 : ordinal
                    levels[depth] = (ordered, number)
                    if paragraph.location >= range.location {
                        markers.append(Marker(location: paragraph.location,
                                              text: Self.text(ordered: ordered, depth: depth, ordinal: number),
                                              depth: depth))
                    }
                }
            } else {
                levels.removeAll()
            }
            previousKind = current
            let next = NSMaxRange(paragraph)
            guard next > paragraph.location, next < storage.length else { break }
            paragraph = text.paragraphRange(for: NSRange(location: next, length: 0))
        }
        return markers
    }

    /// The marker an empty last line would show, when the caret sits on it with list typing attributes (the
    /// line has no character to carry the kind, so a toggled-on empty line would otherwise show nothing).
    static func trailingMarker(in storage: NSAttributedString, typingAttributes: [NSAttributedString.Key: Any],
                               caret: NSRange) -> Marker? {
        let length = storage.length
        guard caret.length == 0, caret.location == length,
              case .listItem(let ordered, let depth, let ordinal)? = typingAttributes[.noteBlockKind] as? BlockKind
        else { return nil }
        if length > 0 {
            let last = (storage.string as NSString).character(at: length - 1)
            guard last == 0x0A || last == 0x0D else { return nil }
        }
        var number = ordinal
        if ordered, length > 0 {
            // One more than the item above it, when that is an item of the same list and level.
            let lastLine = (storage.string as NSString).paragraphRange(for: NSRange(location: length - 1, length: 0))
            let above = markers(in: storage, range: NSRange(location: lastLine.location, length: 0)).last
            if let above, above.location == lastLine.location, above.depth == depth, let n = Int(above.text.dropLast()),
               case .listItem(true, _, _)? = storage.attribute(.noteBlockKind, at: above.location,
                                                                effectiveRange: nil) as? BlockKind {
                number = n + 1
            }
        }
        return Marker(location: length, text: text(ordered: ordered, depth: depth, ordinal: number), depth: depth)
    }
}
