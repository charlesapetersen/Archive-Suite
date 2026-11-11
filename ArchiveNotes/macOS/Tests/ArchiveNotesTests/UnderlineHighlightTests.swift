import Testing
import Foundation
import AppKit
@testable import ArchiveNotes

// W40.notes-underline-highlight (owner's Notes session 2, row 7). CommonMark has no underline or highlight, so Notes
// writes them as the HTML tags most renderers show: `<u>…</u>` and `<mark>…</mark>`. These pin the Markdown each
// toggle writes, that it reads back as the same style with a second save changing nothing, and that a note keeps
// both through a save to disk and a fresh store's reload (a quit and reopen).

@Suite("Underline and highlight — W40.notes-underline-highlight")
@MainActor
struct UnderlineHighlightTests {

    private let fontSize: CGFloat = 14

    private func makeTextView(_ markdown: String) -> EditorTextView {
        let tv = EditorTextView()
        tv.textStorage?.setAttributedString(MarkdownBridge.parse(markdown: markdown, fontSize: fontSize))
        return tv
    }

    private func saved(_ tv: NSTextView) -> String {
        MarkdownBridge.serialize(tv.textStorage!).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isUnderlined(_ text: NSAttributedString, at i: Int) -> Bool {
        InlineTagStyle.underline.isOn(text.attributes(at: i, effectiveRange: nil))
    }

    private func isHighlighted(_ text: NSAttributedString, at i: Int) -> Bool {
        InlineTagStyle.highlight.isOn(text.attributes(at: i, effectiveRange: nil))
    }

    /// Saved once, reopened, saved again: the same text, and no change on the second save.
    private func expectStable(_ markdown: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let reopened = MarkdownBridge.parse(markdown: markdown, fontSize: fontSize)
        #expect(MarkdownBridge.serialize(reopened) == markdown, sourceLocation: sourceLocation)
    }

    // MARK: - The toggles

    @Test func underlineWritesTheTag() {
        let tv = makeTextView("Hello")
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        EditorFormatting.toggleUnderline(tv)
        #expect(saved(tv) == "<u>Hello</u>")
        #expect(EditorFormatting.currentState(for: tv).isUnderline)
        EditorFormatting.toggleUnderline(tv)
        #expect(saved(tv) == "Hello")
        #expect(!EditorFormatting.currentState(for: tv).isUnderline)
    }

    @Test func highlightWritesTheTag() {
        let tv = makeTextView("Hello")
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        EditorFormatting.toggleHighlight(tv)
        #expect(saved(tv) == "<mark>Hello</mark>")
        #expect(EditorFormatting.currentState(for: tv).isHighlight)
        #expect(tv.textStorage!.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
                == InlineTagStyle.highlightColor)
        EditorFormatting.toggleHighlight(tv)
        #expect(saved(tv) == "Hello")
        #expect(tv.textStorage!.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
    }

    @Test func toggleIsUndoable() {
        let tv = makeTextView("Hello")
        tv.allowsUndo = true
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        EditorFormatting.toggleUnderline(tv)
        tv.undoManager?.undo()
        #expect(saved(tv) == "Hello")
    }

    @Test func partOfAWordWithBoldInside() {
        let tv = makeTextView("one two three")
        tv.setSelectedRange(NSRange(location: 4, length: 3))
        EditorFormatting.toggleBold(tv, fontSize: fontSize)
        EditorFormatting.toggleUnderline(tv)
        EditorFormatting.toggleHighlight(tv)
        let md = saved(tv)
        #expect(md == "one <u><mark>**two**</mark></u> three")
        let reopened = MarkdownBridge.parse(markdown: md, fontSize: fontSize)
        #expect(reopened.string == "one two three")
        #expect(isUnderlined(reopened, at: 4) && isHighlighted(reopened, at: 4))
        #expect(!isUnderlined(reopened, at: 3) && !isHighlighted(reopened, at: 7))
        let font = reopened.attribute(.font, at: 4, effectiveRange: nil) as! NSFont
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        expectStable(md)
    }

    @Test func typingAfterTheToggleIsUnderlined() {
        let tv = makeTextView("a")
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        EditorFormatting.toggleUnderline(tv)
        #expect(EditorFormatting.currentState(for: tv).isUnderline)
        tv.insertText(" b", replacementRange: tv.selectedRange())
        #expect(saved(tv) == "a<u> b</u>")
    }

    /// A heading, a list item and a quote keep the tags, and a line that begins with one is not escaped.
    @Test(arguments: [
        "# <u>Title</u> here",
        "- <mark>item</mark>\n- <u>two</u>",
        "<u>Starts</u> the paragraph.",
        "> <mark>quoted</mark>",
        // Outside the link: Apple's parser reads no HTML inside link text, and the serializer writes it so.
        "a <u>[link](https://example.com)</u> b",
        "<mark>`code`</mark> after",
    ])
    func blockKindsRoundTrip(_ md: String) {
        let reopened = MarkdownBridge.parse(markdown: md, fontSize: fontSize)
        #expect(!reopened.string.contains("<u>") && !reopened.string.contains("<mark>"), "\(md)")
        expectStable(md)
    }

    /// A block change clears the background under the text; the highlight shows again.
    @Test func highlightSurvivesAListToggle() {
        let tv = makeTextView("<mark>x</mark> y")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        EditorFormatting.toggleUnorderedList(tv, fontSize: fontSize)
        #expect(tv.textStorage!.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
                == InlineTagStyle.highlightColor)
        #expect(saved(tv) == "- <mark>x</mark> y")
    }

    /// A whole heading selected with its newline, as a triple-click selects it: the tag closes before the newline.
    @Test func underlinedLineWithItsNewline() {
        let tv = makeTextView("# Title\n\nbody")
        tv.setSelectedRange(NSRange(location: 0, length: 6))
        EditorFormatting.toggleUnderline(tv)
        let md = saved(tv)
        #expect(md == "# <u>Title</u>\n\nbody")
        expectStable(md)
    }

    /// Bold inside underline writes its edge spaces outside `**`; they reopen as runs of their own. Tags written
    /// around each run then changed on the second save (`<u> </u><u>**a**</u><u> </u>`).
    @Test(arguments: [(0, 7), (4, 4), (3, 5)])
    func edgeSpacesAreStable(_ location: Int, _ length: Int) {
        let tv = makeTextView("one two three")
        tv.setSelectedRange(NSRange(location: location, length: length))
        EditorFormatting.toggleBold(tv, fontSize: fontSize)
        EditorFormatting.toggleUnderline(tv)
        EditorFormatting.toggleHighlight(tv)
        let md = MarkdownBridge.serialize(tv.textStorage!)
        #expect(!md.contains("</u><u>") && !md.contains("</mark><mark>"), "\(md)")
        let reopened = MarkdownBridge.parse(markdown: md, fontSize: fontSize)
        #expect(reopened.string == "one two three")
        for i in location..<(location + length) {
            #expect(isUnderlined(reopened, at: i) && isHighlighted(reopened, at: i), "\(md) at \(i)")
        }
        expectStable(md)
    }

    @Test func imageInsideUnderlineIsStable() {
        let tv = makeTextView("a ![x](assets/p.png) b")
        tv.setSelectedRange(NSRange(location: 0, length: tv.textStorage!.length))
        EditorFormatting.toggleUnderline(tv)
        let md = MarkdownBridge.serialize(tv.textStorage!)
        #expect(md.contains("](assets/p.png)"))
        expectStable(md)
    }

    @Test func noToggleInACodeBlock() {
        let tv = makeTextView("```\ncode\n```")
        tv.setSelectedRange(NSRange(location: 0, length: 4))
        EditorFormatting.toggleUnderline(tv)
        EditorFormatting.toggleHighlight(tv)
        #expect(!isUnderlined(tv.textStorage!, at: 0) && !isHighlighted(tv.textStorage!, at: 0))
        #expect(saved(tv) == "```\ncode\n```")
    }

    @Test func searchIndexHasNoTags() {
        let item = Item(id: UUID(), kind: .note, title: "N", authors: [], date: nil,
                        datePrecision: nil, dateUncertain: false, quality: nil, tags: [], zotero: [],
                        roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [],
                        trailingBodyRaw: "wo<u>rd</u> <mark>Lincoln</mark> and typed \\<mark>")
        let body = NoteIndexRow(item: item, mtime: 0).body
        #expect(body.hasPrefix("word Lincoln and typed \\<mark>"))
    }

    // MARK: - Typed tags and hand-written HTML

    /// Text that looks like a tag is text: written escaped, it comes back as the characters typed, not styled.
    @Test func typedTagIsText() {
        let tv = makeTextView("")
        tv.insertPlainText("<u>not underline</u> and <mark>x</mark>")
        let md = saved(tv)
        let reopened = MarkdownBridge.parse(markdown: md, fontSize: fontSize)
        #expect(reopened.string == "<u>not underline</u> and <mark>x</mark>")
        #expect(!isUnderlined(reopened, at: 3) && !isHighlighted(reopened, at: 30))
        expectStable(md)
    }

    @Test func lessThanAloneIsNotEscaped() {
        let tv = makeTextView("")
        tv.insertPlainText("a < b and 3<4")
        #expect(saved(tv) == "a < b and 3<4")
    }

    /// An unpaired tag, or one in another paragraph, is raw HTML as before.
    @Test(arguments: ["a <u>b", "a <u>b\n\nc</u> d", "a </mark> b", "A\n\n<u></u>\n\nB"])
    func unpairedTagStaysRaw(_ md: String) {
        let reopened = MarkdownBridge.parse(markdown: md, fontSize: fontSize)
        #expect(reopened.string.contains("<u>") || reopened.string.contains("</mark>"), "\(md)")
        expectStable(md)
    }

    @Test func uppercaseTagIsRead() {
        let reopened = MarkdownBridge.parse(markdown: "a <U>b</U>", fontSize: fontSize)
        #expect(reopened.string == "a b")
        #expect(isUnderlined(reopened, at: 2))
    }

    @Test func extractTitleDropsTheTags() {
        let block = Block(kind: .notePassage, source: nil, markdown: "<u>Big</u> <mark>day</mark>\nmore",
                          unknownHeaderFields: [])
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [block], fallbackDate: Date()) == "Big day")
        // A typed backslash before underlined text, and a typed tag.
        let escaped = Block(kind: .notePassage, source: nil, markdown: "\\\\<u>x</u> \\<u>y", unknownHeaderFields: [])
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [escaped], fallbackDate: Date()) == "\\x <u>y")
    }

    // MARK: - Quit and reopen

    @Test func noteKeepsBothThroughSaveAndReload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-underline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        let store = NoteStore(root: root)
        let model = NotesModel(organization: org, index: index, noteStore: store)
        let item = Item(id: UUID(), kind: .note, title: "N", authors: [], date: nil,
                        datePrecision: nil, dateUncertain: false, quality: nil, tags: [], zotero: [],
                        roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [], trailingBodyRaw: "Read this part and that part.")
        _ = try await store.create(item)

        let tv = makeTextView(await model.loadBody(for: item.id) ?? "")
        tv.setSelectedRange(NSRange(location: 5, length: 9))     // "this part"
        EditorFormatting.toggleUnderline(tv)
        tv.setSelectedRange(NSRange(location: 19, length: 9))    // "that part"
        EditorFormatting.toggleHighlight(tv)
        await model.setBody(MarkdownBridge.serialize(tv.textStorage!), for: item.id)
        await index.close()

        // A fresh store over the same folder, as the app has after a relaunch.
        let reloaded = try await NoteStore(root: root).load(item.id)
        let body = reloaded.trailingBodyRaw ?? ""
        #expect(body == "Read <u>this part</u> and <mark>that part</mark>.")
        let reopened = MarkdownBridge.parse(markdown: body, fontSize: fontSize)
        #expect(reopened.string == "Read this part and that part.")
        #expect(isUnderlined(reopened, at: 5) && isUnderlined(reopened, at: 13) && !isUnderlined(reopened, at: 14))
        #expect(isHighlighted(reopened, at: 19) && isHighlighted(reopened, at: 27) && !isHighlighted(reopened, at: 28))
        #expect(MarkdownBridge.serialize(reopened) == body)
    }
}
