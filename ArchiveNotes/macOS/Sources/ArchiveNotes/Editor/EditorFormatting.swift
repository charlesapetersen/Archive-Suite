import AppKit
import SwiftUI

// MARK: - Formatting state (reported to toolbar / commands)

struct FormattingState: Equatable {
    var isBold = false
    var isItalic = false
    var isCode = false
    var hasLink = false
    var blockKind: BlockKind = .plain

    var headingLevel: Int? {
        if case .heading(let level) = blockKind { return level }
        return nil
    }

    var isUnorderedList: Bool {
        if case .listItem(ordered: false, _, _) = blockKind { return true }
        return false
    }

    var isOrderedList: Bool {
        if case .listItem(ordered: true, _, _) = blockKind { return true }
        return false
    }

    var isBlockquote: Bool { blockKind == .blockquote }

    var isCodeBlock: Bool {
        if case .codeBlock = blockKind { return true }
        return false
    }
}

// MARK: - Formatting context (bridges editor ↔ toolbar / commands)

@MainActor
final class FormattingContext: ObservableObject {
    @Published var state = FormattingState()
    weak var textView: EditorTextView?
    var fontSize: CGFloat = 14

    func toggleBold() {
        guard let tv = textView else { return }
        EditorFormatting.toggleBold(tv, fontSize: fontSize)
        updateState()
    }

    func toggleItalic() {
        guard let tv = textView else { return }
        EditorFormatting.toggleItalic(tv, fontSize: fontSize)
        updateState()
    }

    func toggleInlineCode() {
        guard let tv = textView else { return }
        EditorFormatting.toggleInlineCode(tv, fontSize: fontSize)
        updateState()
    }

    func insertLink() {
        guard let tv = textView else { return }
        EditorFormatting.insertLink(tv)
        updateState()
    }

    func setHeading(_ level: Int) {
        guard let tv = textView else { return }
        EditorFormatting.setHeading(tv, level: level, fontSize: fontSize)
        updateState()
    }

    func setPlain() {
        guard let tv = textView else { return }
        EditorFormatting.setPlain(tv, fontSize: fontSize)
        updateState()
    }

    func toggleUnorderedList() {
        guard let tv = textView else { return }
        EditorFormatting.toggleUnorderedList(tv, fontSize: fontSize)
        updateState()
    }

    func toggleOrderedList() {
        guard let tv = textView else { return }
        EditorFormatting.toggleOrderedList(tv, fontSize: fontSize)
        updateState()
    }

    func toggleBlockquote() {
        guard let tv = textView else { return }
        EditorFormatting.toggleBlockquote(tv, fontSize: fontSize)
        updateState()
    }

    func toggleCodeBlock() {
        guard let tv = textView else { return }
        EditorFormatting.toggleCodeBlock(tv, fontSize: fontSize)
        updateState()
    }

    func updateState() {
        guard let tv = textView else { return }
        state = EditorFormatting.currentState(for: tv)
    }

    /// W3-S5 seam: the coordinator that owns the editor, used for `insertBlock`.
    weak var coordinator: MarkdownEditorView.Coordinator?

    /// Insert a test source-block chip at the caret (Debug menu).
    func insertTestBlock() {
        let anchor = SourceAnchor(
            link: "archivereader://reveal?root=TEST&rel=test.pdf&page=1",
            display: "Test Document - p. 1",
            page: 1
        )
        coordinator?.insertBlock(kind: .readerPage, anchor: anchor)
    }
}

// MARK: - FocusedValue key

struct FormattingContextKey: FocusedValueKey {
    typealias Value = FormattingContext
}

extension FocusedValues {
    var formattingContext: FormattingContext? {
        get { self[FormattingContextKey.self] }
        set { self[FormattingContextKey.self] = newValue }
    }
}

// MARK: - Formatting actions

@MainActor
enum EditorFormatting {

    // MARK: Inline formatting

    static func toggleBold(_ textView: NSTextView, fontSize: CGFloat) {
        toggleTrait(.boldFontMask, textView: textView, fontSize: fontSize)
    }

    static func toggleItalic(_ textView: NSTextView, fontSize: CGFloat) {
        toggleTrait(.italicFontMask, textView: textView, fontSize: fontSize)
    }

    static func toggleInlineCode(_ textView: NSTextView, fontSize: CGFloat) {
        guard let storage = textView.textStorage else { return }
        let range = textView.selectedRange()

        if range.length == 0 {
            var attrs = textView.typingAttributes
            if attrs[.noteInlineCode] as? Bool == true {
                attrs.removeValue(forKey: .noteInlineCode)
                attrs.removeValue(forKey: .backgroundColor)
                attrs[.font] = NSFont.systemFont(ofSize: fontSize)
            } else {
                attrs[.noteInlineCode] = true
                attrs[.backgroundColor] = NSColor.quaternaryLabelColor
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            }
            textView.typingAttributes = attrs
            return
        }

        let allCode = isEntireRange(storage, range: range, attribute: .noteInlineCode)

        textView.undoManager?.beginUndoGrouping()
        storage.beginEditing()
        if allCode {
            storage.removeAttribute(.noteInlineCode, range: range)
            storage.removeAttribute(.backgroundColor, range: range)
            storage.enumerateAttribute(.font, in: range) { val, r, _ in
                if let font = val as? NSFont,
                   NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask) {
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize), range: r)
                }
            }
        } else {
            storage.addAttribute(.noteInlineCode, value: true, range: range)
            storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: range)
            storage.addAttribute(.font,
                                 value: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                                 range: range)
        }
        storage.endEditing()
        textView.undoManager?.endUndoGrouping()
    }

    // MARK: Block formatting

    static func setHeading(_ textView: NSTextView, level: Int, fontSize: CGFloat) {
        applyBlockKind(.heading(level), textView: textView, fontSize: fontSize)
    }

    static func setPlain(_ textView: NSTextView, fontSize: CGFloat) {
        applyBlockKind(.plain, textView: textView, fontSize: fontSize)
    }

    static func toggleUnorderedList(_ textView: NSTextView, fontSize: CGFloat) {
        toggleList(ordered: false, textView: textView, fontSize: fontSize)
    }

    static func toggleOrderedList(_ textView: NSTextView, fontSize: CGFloat) {
        toggleList(ordered: true, textView: textView, fontSize: fontSize)
    }

    static func toggleBlockquote(_ textView: NSTextView, fontSize: CGFloat) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let paraRange = paragraphRange(for: textView.selectedRange(), in: storage)
        let current = storage.attribute(.noteBlockKind, at: paraRange.location, effectiveRange: nil) as? BlockKind
        if case .blockquote = current {
            applyBlockKind(.plain, textView: textView, fontSize: fontSize)
        } else {
            applyBlockKind(.blockquote, textView: textView, fontSize: fontSize)
        }
    }

    static func toggleCodeBlock(_ textView: NSTextView, fontSize: CGFloat) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let paraRange = paragraphRange(for: textView.selectedRange(), in: storage)
        let current = storage.attribute(.noteBlockKind, at: paraRange.location, effectiveRange: nil) as? BlockKind
        if case .codeBlock = current {
            applyBlockKind(.plain, textView: textView, fontSize: fontSize)
        } else {
            applyBlockKind(.codeBlock(nil), textView: textView, fontSize: fontSize)
        }
    }

    // MARK: Link

    static func insertLink(_ textView: NSTextView) {
        let range = textView.selectedRange()

        // If selection already has a link, remove it
        if range.length > 0,
           let storage = textView.textStorage,
           storage.attribute(.link, at: range.location, effectiveRange: nil) != nil {
            removeLink(textView)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Insert Link"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "https://"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let url = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }

        applyLink(textView, url: url)
    }

    /// Apply a link attribute (testable, no dialog).
    static func applyLink(_ textView: NSTextView, url: String) {
        guard let storage = textView.textStorage else { return }
        let range = textView.selectedRange()

        textView.undoManager?.beginUndoGrouping()
        storage.beginEditing()
        if range.length > 0 {
            storage.addAttribute(.link, value: url, range: range)
        } else {
            var attrs = textView.typingAttributes
            attrs[.link] = url
            let linkText = NSAttributedString(string: url, attributes: attrs)
            storage.insert(linkText, at: range.location)
            textView.setSelectedRange(NSRange(location: range.location + url.count, length: 0))
        }
        storage.endEditing()
        textView.undoManager?.endUndoGrouping()
    }

    static func removeLink(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }

        textView.undoManager?.beginUndoGrouping()
        storage.beginEditing()
        storage.removeAttribute(.link, range: range)
        storage.endEditing()
        textView.undoManager?.endUndoGrouping()
    }

    // MARK: List indent / outdent

    static func indentList(_ textView: NSTextView, fontSize: CGFloat) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let paraRange = paragraphRange(for: textView.selectedRange(), in: storage)
        guard let kind = storage.attribute(.noteBlockKind, at: paraRange.location,
                                           effectiveRange: nil) as? BlockKind,
              case .listItem(let ordered, let depth, let ordinal) = kind else { return }
        let newKind = BlockKind.listItem(ordered: ordered, depth: depth + 1, ordinal: ordinal)
        textView.undoManager?.beginUndoGrouping()
        storage.beginEditing()
        applyBlockKindAndVisuals(storage: storage, range: paraRange, kind: newKind, fontSize: fontSize)
        storage.endEditing()
        textView.undoManager?.endUndoGrouping()
    }

    static func outdentList(_ textView: NSTextView, fontSize: CGFloat) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let paraRange = paragraphRange(for: textView.selectedRange(), in: storage)
        guard let kind = storage.attribute(.noteBlockKind, at: paraRange.location,
                                           effectiveRange: nil) as? BlockKind,
              case .listItem(let ordered, let depth, let ordinal) = kind else { return }
        if depth > 0 {
            let newKind = BlockKind.listItem(ordered: ordered, depth: depth - 1, ordinal: ordinal)
            textView.undoManager?.beginUndoGrouping()
            storage.beginEditing()
            applyBlockKindAndVisuals(storage: storage, range: paraRange, kind: newKind, fontSize: fontSize)
            storage.endEditing()
            textView.undoManager?.endUndoGrouping()
        } else {
            applyBlockKind(.plain, textView: textView, fontSize: fontSize)
        }
    }

    // MARK: State query

    static func currentState(for textView: NSTextView) -> FormattingState {
        guard let storage = textView.textStorage, storage.length > 0 else {
            return FormattingState()
        }
        let range = textView.selectedRange()
        let attrs: [NSAttributedString.Key: Any]
        if range.length == 0 {
            attrs = textView.typingAttributes
        } else if range.location < storage.length {
            attrs = storage.attributes(at: range.location, effectiveRange: nil)
        } else {
            attrs = textView.typingAttributes
        }
        return stateFromAttrs(attrs)
    }

    // MARK: - Private helpers

    private static func stateFromAttrs(_ attrs: [NSAttributedString.Key: Any]) -> FormattingState {
        let font = attrs[.font] as? NSFont
        let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
        let blockKind = attrs[.noteBlockKind] as? BlockKind ?? .plain
        // Headings are structurally bold; don't report as user-toggled bold
        let isBold: Bool
        if case .heading = blockKind {
            isBold = false
        } else {
            isBold = traits.contains(.boldFontMask)
        }
        return FormattingState(
            isBold: isBold,
            isItalic: traits.contains(.italicFontMask),
            isCode: attrs[.noteInlineCode] as? Bool == true,
            hasLink: attrs[.link] != nil,
            blockKind: blockKind
        )
    }

    private static func toggleTrait(_ trait: NSFontTraitMask,
                                    textView: NSTextView,
                                    fontSize: CGFloat) {
        guard let storage = textView.textStorage else { return }
        let range = textView.selectedRange()

        if range.length == 0 {
            var attrs = textView.typingAttributes
            let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: fontSize)
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(trait) {
                attrs[.font] = NSFontManager.shared.convert(font, toNotHaveTrait: trait)
            } else {
                attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: trait)
            }
            textView.typingAttributes = attrs
            return
        }

        let allHave = isEntireRangeTrait(storage, range: range, trait: trait)

        textView.undoManager?.beginUndoGrouping()
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { val, r, _ in
            let font = val as? NSFont ?? .systemFont(ofSize: fontSize)
            let newFont: NSFont
            if allHave {
                newFont = NSFontManager.shared.convert(font, toNotHaveTrait: trait)
            } else {
                newFont = NSFontManager.shared.convert(font, toHaveTrait: trait)
            }
            storage.addAttribute(.font, value: newFont, range: r)
        }
        storage.endEditing()
        textView.undoManager?.endUndoGrouping()
    }

    private static func toggleList(ordered: Bool, textView: NSTextView, fontSize: CGFloat) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let paraRange = paragraphRange(for: textView.selectedRange(), in: storage)
        let current = storage.attribute(.noteBlockKind, at: paraRange.location,
                                        effectiveRange: nil) as? BlockKind
        if case .listItem(let ord, _, _) = current, ord == ordered {
            applyBlockKind(.plain, textView: textView, fontSize: fontSize)
        } else {
            applyBlockKind(.listItem(ordered: ordered, depth: 0, ordinal: 1),
                          textView: textView, fontSize: fontSize)
        }
    }

    private static func applyBlockKind(_ kind: BlockKind,
                                       textView: NSTextView,
                                       fontSize: CGFloat) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let paraRange = paragraphRange(for: textView.selectedRange(), in: storage)

        // Detect heading→non-heading: strip structural bold that headings add.
        // User-applied bold within headings has no Markdown representation (the
        // serializer skips ** for heading text), so nothing is lost.
        let oldKind = storage.attribute(.noteBlockKind, at: paraRange.location,
                                        effectiveRange: nil) as? BlockKind
        let wasHeading: Bool
        if case .heading = oldKind { wasHeading = true } else { wasHeading = false }
        let isHeading: Bool
        if case .heading = kind { isHeading = true } else { isHeading = false }

        textView.undoManager?.beginUndoGrouping()
        storage.beginEditing()
        if wasHeading && !isHeading {
            storage.enumerateAttribute(.font, in: paraRange) { val, r, _ in
                if let font = val as? NSFont {
                    storage.addAttribute(.font,
                                         value: NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask),
                                         range: r)
                }
            }
        }
        applyBlockKindAndVisuals(storage: storage, range: paraRange, kind: kind, fontSize: fontSize)
        storage.endEditing()
        textView.undoManager?.endUndoGrouping()
    }

    private static func applyBlockKindAndVisuals(storage: NSTextStorage,
                                                  range: NSRange,
                                                  kind: BlockKind,
                                                  fontSize: CGFloat) {
        storage.addAttribute(.noteBlockKind, value: kind, range: range)

        switch kind {
        case .heading(let level):
            let sizes: [CGFloat] = [0, 28, 24, 20, 17, 15, 14]
            let size = (1...6).contains(level) ? sizes[level] : fontSize
            storage.enumerateAttribute(.font, in: range) { val, r, _ in
                var font = NSFont.boldSystemFont(ofSize: size)
                if let existing = val as? NSFont,
                   NSFontManager.shared.traits(of: existing).contains(.italicFontMask) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
                storage.addAttribute(.font, value: font, range: r)
            }
            storage.removeAttribute(.paragraphStyle, range: range)
            storage.removeAttribute(.backgroundColor, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)

        case .blockquote:
            let ps = NSMutableParagraphStyle()
            ps.headIndent = 20
            ps.firstLineHeadIndent = 20
            storage.addAttribute(.paragraphStyle, value: ps, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            storage.removeAttribute(.backgroundColor, range: range)
            restoreBodyFont(storage: storage, range: range, fontSize: fontSize)

        case .codeBlock:
            let font = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
            storage.addAttribute(.font, value: font, range: range)
            storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
            storage.removeAttribute(.paragraphStyle, range: range)

        case .listItem(_, let depth, _):
            let ps = NSMutableParagraphStyle()
            let indent = CGFloat(depth + 1) * 20
            ps.headIndent = indent
            ps.firstLineHeadIndent = max(indent - 16, 0)
            storage.addAttribute(.paragraphStyle, value: ps, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
            storage.removeAttribute(.backgroundColor, range: range)
            restoreBodyFont(storage: storage, range: range, fontSize: fontSize)

        case .plain:
            storage.removeAttribute(.paragraphStyle, range: range)
            storage.removeAttribute(.backgroundColor, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
            restoreBodyFont(storage: storage, range: range, fontSize: fontSize)
        }
    }

    /// Restore body-size fonts while preserving inline bold/italic/code traits.
    private static func restoreBodyFont(storage: NSTextStorage,
                                         range: NSRange,
                                         fontSize: CGFloat) {
        storage.enumerateAttribute(.font, in: range) { val, r, _ in
            guard let font = val as? NSFont else { return }
            // Preserve inline code
            if storage.attribute(.noteInlineCode, at: r.location, effectiveRange: nil) as? Bool == true {
                storage.addAttribute(.font,
                                     value: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                                     range: r)
                return
            }
            let traits = NSFontManager.shared.traits(of: font)
            var newFont = NSFont.systemFont(ofSize: fontSize)
            if traits.contains(.boldFontMask) {
                newFont = NSFontManager.shared.convert(newFont, toHaveTrait: .boldFontMask)
            }
            if traits.contains(.italicFontMask) {
                newFont = NSFontManager.shared.convert(newFont, toHaveTrait: .italicFontMask)
            }
            storage.addAttribute(.font, value: newFont, range: r)
        }
    }

    private static func isEntireRangeTrait(_ storage: NSTextStorage,
                                           range: NSRange,
                                           trait: NSFontTraitMask) -> Bool {
        var all = true
        storage.enumerateAttribute(.font, in: range) { val, _, stop in
            let font = val as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            if !traits.contains(trait) { all = false; stop.pointee = true }
        }
        return all
    }

    private static func isEntireRange(_ storage: NSTextStorage,
                                      range: NSRange,
                                      attribute: NSAttributedString.Key) -> Bool {
        var all = true
        storage.enumerateAttribute(attribute, in: range) { val, _, stop in
            if val == nil || (val as? Bool) != true { all = false; stop.pointee = true }
        }
        return all
    }

    static func paragraphRange(for selectedRange: NSRange,
                                in storage: NSAttributedString) -> NSRange {
        (storage.string as NSString).paragraphRange(for: selectedRange)
    }
}
