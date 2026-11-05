import Testing
import Foundation
import AppKit
@testable import ArchiveNotes

@Suite("FormattingActionTests — W3-S3 formatting toolbar actions")
struct FormattingActionTests {

    // MARK: - Inline formatting

    @Test @MainActor
    func toggleBoldProducesBoldMarkdown() {
        let result = applyToAll("Hello") { tv, fs in
            EditorFormatting.toggleBold(tv, fontSize: fs)
        }
        #expect(result.trimmed == "**Hello**")
    }

    @Test @MainActor
    func toggleBoldTwiceIsNoOp() {
        let result = applyToAll("Hello") { tv, fs in
            EditorFormatting.toggleBold(tv, fontSize: fs)
            EditorFormatting.toggleBold(tv, fontSize: fs)
        }
        #expect(result.trimmed == "Hello")
    }

    @Test @MainActor
    func toggleItalicProducesItalicMarkdown() {
        let result = applyToAll("Hello") { tv, fs in
            EditorFormatting.toggleItalic(tv, fontSize: fs)
        }
        #expect(result.trimmed == "*Hello*")
    }

    @Test @MainActor
    func toggleItalicTwiceIsNoOp() {
        let result = applyToAll("Hello") { tv, fs in
            EditorFormatting.toggleItalic(tv, fontSize: fs)
            EditorFormatting.toggleItalic(tv, fontSize: fs)
        }
        #expect(result.trimmed == "Hello")
    }

    @Test @MainActor
    func toggleInlineCodeProducesCodeMarkdown() {
        let result = applyToAll("Hello") { tv, fs in
            EditorFormatting.toggleInlineCode(tv, fontSize: fs)
        }
        #expect(result.trimmed == "`Hello`")
    }

    @Test @MainActor
    func toggleInlineCodeTwiceIsNoOp() {
        let result = applyToAll("Hello") { tv, fs in
            EditorFormatting.toggleInlineCode(tv, fontSize: fs)
            EditorFormatting.toggleInlineCode(tv, fontSize: fs)
        }
        #expect(result.trimmed == "Hello")
    }

    @Test @MainActor
    func boldAndItalicCombined() {
        let result = applyToAll("Hello") { tv, fs in
            EditorFormatting.toggleBold(tv, fontSize: fs)
            EditorFormatting.toggleItalic(tv, fontSize: fs)
        }
        #expect(result.trimmed == "***Hello***")
    }

    // MARK: - Link

    @Test @MainActor
    func applyLinkToSelection() {
        let result = applyToAll("Hello") { tv, _ in
            EditorFormatting.applyLink(tv, url: "https://example.com")
        }
        #expect(result.trimmed.contains("[Hello](https://example.com)"))
    }

    @Test @MainActor
    func removeLinkRestoresPlainText() {
        let result = applyToAll("Hello") { tv, _ in
            EditorFormatting.applyLink(tv, url: "https://example.com")
            // Re-select all after link was applied
            tv.setSelectedRange(NSRange(location: 0, length: tv.string.count))
            EditorFormatting.removeLink(tv)
        }
        // After removing link, text should serialize without link syntax
        #expect(!result.trimmed.contains("["))
        #expect(result.trimmed.contains("Hello"))
    }

    // MARK: - Block formatting

    @Test @MainActor
    func setHeading1() {
        let result = applyToAll("Hello") { tv, fs in
            EditorFormatting.setHeading(tv, level: 1, fontSize: fs)
        }
        #expect(result.trimmed == "# Hello")
    }

    @Test @MainActor
    func setHeading2() {
        let result = applyToAll("Hello") { tv, fs in
            EditorFormatting.setHeading(tv, level: 2, fontSize: fs)
        }
        #expect(result.trimmed == "## Hello")
    }

    @Test @MainActor
    func setHeadingThenPlain() {
        let result = applyToAll("Hello") { tv, fs in
            EditorFormatting.setHeading(tv, level: 1, fontSize: fs)
            EditorFormatting.setPlain(tv, fontSize: fs)
        }
        #expect(result.trimmed == "Hello")
    }

    @Test @MainActor
    func setUnorderedList() {
        let result = applyToAll("Hello") { tv, fs in
            EditorFormatting.toggleUnorderedList(tv, fontSize: fs)
        }
        #expect(result.trimmed == "- Hello")
    }

    @Test @MainActor
    func toggleUnorderedListTwiceIsNoOp() {
        let result = applyToAll("Hello") { tv, fs in
            EditorFormatting.toggleUnorderedList(tv, fontSize: fs)
            EditorFormatting.toggleUnorderedList(tv, fontSize: fs)
        }
        #expect(result.trimmed == "Hello")
    }

    @Test @MainActor
    func setOrderedList() {
        let result = applyToAll("Hello") { tv, fs in
            EditorFormatting.toggleOrderedList(tv, fontSize: fs)
        }
        #expect(result.trimmed == "1. Hello")
    }

    @Test @MainActor
    func toggleOrderedListTwiceIsNoOp() {
        let result = applyToAll("Hello") { tv, fs in
            EditorFormatting.toggleOrderedList(tv, fontSize: fs)
            EditorFormatting.toggleOrderedList(tv, fontSize: fs)
        }
        #expect(result.trimmed == "Hello")
    }

    @Test @MainActor
    func setBlockquote() {
        let result = applyToAll("Hello") { tv, fs in
            EditorFormatting.toggleBlockquote(tv, fontSize: fs)
        }
        #expect(result.trimmed == "> Hello")
    }

    @Test @MainActor
    func toggleBlockquoteTwiceIsNoOp() {
        let result = applyToAll("Hello") { tv, fs in
            EditorFormatting.toggleBlockquote(tv, fontSize: fs)
            EditorFormatting.toggleBlockquote(tv, fontSize: fs)
        }
        #expect(result.trimmed == "Hello")
    }

    @Test @MainActor
    func setCodeBlock() {
        let result = applyToAll("Hello") { tv, fs in
            EditorFormatting.toggleCodeBlock(tv, fontSize: fs)
        }
        #expect(result.trimmed == "```\nHello\n```")
    }

    @Test @MainActor
    func toggleCodeBlockTwiceIsNoOp() {
        let result = applyToAll("Hello") { tv, fs in
            EditorFormatting.toggleCodeBlock(tv, fontSize: fs)
            EditorFormatting.toggleCodeBlock(tv, fontSize: fs)
        }
        #expect(result.trimmed == "Hello")
    }

    // MARK: - State query

    @Test @MainActor
    func stateReflectsBold() {
        let tv = makeTextView("Hello")
        tv.setSelectedRange(NSRange(location: 0, length: tv.string.count))
        EditorFormatting.toggleBold(tv, fontSize: 14)
        let state = EditorFormatting.currentState(for: tv)
        #expect(state.isBold)
        #expect(!state.isItalic)
    }

    @Test @MainActor
    func stateReflectsHeading() {
        let tv = makeTextView("Hello")
        tv.setSelectedRange(NSRange(location: 0, length: tv.string.count))
        EditorFormatting.setHeading(tv, level: 2, fontSize: 14)
        let state = EditorFormatting.currentState(for: tv)
        #expect(state.headingLevel == 2)
        // Heading bold is structural, not user-toggled
        #expect(!state.isBold)
    }

    @Test @MainActor
    func stateReflectsList() {
        let tv = makeTextView("Hello")
        tv.setSelectedRange(NSRange(location: 0, length: tv.string.count))
        EditorFormatting.toggleUnorderedList(tv, fontSize: 14)
        let state = EditorFormatting.currentState(for: tv)
        #expect(state.isUnorderedList)
    }

    // MARK: - Emphasis with spaces at its edges (W40.fix-notes-bold-space)

    /// A style applied to a selection with a space at either edge writes the space outside the delimiters, and the
    /// text comes back styled with no asterisks in it. `**Day **` is not bold in CommonMark: it was saved that way,
    /// reopened as literal `**Day **`, and escaped to `\*\*Day \*\*` on the next save.
    @Test(arguments: [
        ("bold", "**Day** one", "Day ", true, false),
        ("italic", "*Day* one", "Day ", false, true),
        ("bold italic", "***Day*** one", "Day ", true, true),
    ])
    @MainActor
    func emphasisEndingInSpaceRoundTrips(_ name: String, _ expected: String, _ styled: String,
                                         _ bold: Bool, _ italic: Bool) {
        let tv = makeTextView("Day one")
        tv.setSelectedRange(NSRange(location: 0, length: styled.utf16.count))
        if bold { EditorFormatting.toggleBold(tv, fontSize: fontSize) }
        if italic { EditorFormatting.toggleItalic(tv, fontSize: fontSize) }
        let saved = MarkdownBridge.serialize(tv.textStorage!)
        #expect(saved.trimmed == expected, "\(name)")

        let reopened = MarkdownBridge.parse(markdown: saved, fontSize: fontSize)
        #expect(reopened.string.trimmed == "Day one", "\(name)")
        let traits = NSFontManager.shared.traits(of: reopened.attribute(.font, at: 0, effectiveRange: nil) as! NSFont)
        #expect(traits.contains(.boldFontMask) == bold, "\(name)")
        #expect(traits.contains(.italicFontMask) == italic, "\(name)")
        #expect(MarkdownBridge.serialize(reopened) == saved, "\(name): a second save changes nothing")
    }

    @Test @MainActor
    func boldStartingWithSpaceKeepsTheSpaceOutside() {
        let tv = makeTextView("one day")
        tv.setSelectedRange(NSRange(location: 3, length: 4))
        EditorFormatting.toggleBold(tv, fontSize: fontSize)
        let saved = MarkdownBridge.serialize(tv.textStorage!)
        #expect(saved.trimmed == "one **day**")
        #expect(MarkdownBridge.serialize(MarkdownBridge.parse(markdown: saved, fontSize: fontSize)) == saved)
    }

    @Test @MainActor
    func boldSpaceAloneWritesNoDelimiters() {
        let tv = makeTextView("one two")
        tv.setSelectedRange(NSRange(location: 3, length: 1))
        EditorFormatting.toggleBold(tv, fontSize: fontSize)
        #expect(MarkdownBridge.serialize(tv.textStorage!).trimmed == "one two")
    }

    // MARK: - Helpers

    private let fontSize: CGFloat = 14

    @MainActor
    private func makeTextView(_ markdown: String) -> EditorTextView {
        let tv = EditorTextView()
        let parsed = MarkdownBridge.parse(markdown: markdown, fontSize: fontSize)
        tv.textStorage?.setAttributedString(parsed)
        return tv
    }

    /// Parse markdown, select all, apply action, serialize, return result.
    @MainActor
    private func applyToAll(_ markdown: String,
                            action: (NSTextView, CGFloat) -> Void) -> String {
        let tv = makeTextView(markdown)
        tv.setSelectedRange(NSRange(location: 0, length: tv.string.count))
        action(tv, fontSize)
        return MarkdownBridge.serialize(tv.textStorage!)
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
