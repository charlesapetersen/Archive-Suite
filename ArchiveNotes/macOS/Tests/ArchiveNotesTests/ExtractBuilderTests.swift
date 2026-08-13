import Testing
import Foundation
import ArchiveCore
@testable import ArchiveNotes

// W7-S1 — Extract data model + ExtractBuilder snapshot core. Pure/model tests + scratch-store
// persistence tests (never the real store or corpus — Prime Directive #1).

// MARK: - Fake selection seam (no live NSTextView, per plan §S1)

@MainActor
final class FakeSelectionSource: PassageSelectionSource {
    var sourceNoteId: UUID
    var sourceTitle: String
    var sourceDateDisplay: String
    var selectedRanges: [NSRange]
    var blockRanges: [(blockIndex: Int, range: NSRange)]
    private let fullText: NSString
    private let assetsForBlock: [Int: [String: Data]]

    init(sourceNoteId: UUID = UUID(),
         sourceTitle: String = "Source Note",
         sourceDateDisplay: String = "1968",
         fullText: String,
         selectedRanges: [NSRange],
         blockRanges: [(blockIndex: Int, range: NSRange)],
         assetsForBlock: [Int: [String: Data]] = [:]) {
        self.sourceNoteId = sourceNoteId
        self.sourceTitle = sourceTitle
        self.sourceDateDisplay = sourceDateDisplay
        self.fullText = fullText as NSString
        self.selectedRanges = selectedRanges
        self.blockRanges = blockRanges
        self.assetsForBlock = assetsForBlock
    }

    func snapshotMarkdown(in range: NSRange) -> (markdown: String, assets: [String: Data]) {
        let md = fullText.substring(with: range)
        let bi = blockRanges.first { NSLocationInRange(range.location, $0.range) }?.blockIndex
        return (md, bi.flatMap { assetsForBlock[$0] } ?? [:])
    }
}

// MARK: - SourceAnchor note-passage helpers

@Suite("SourceAnchor — note-passage helpers (W7-S1)")
struct SourceAnchorNotePassageTests {

    @Test("notePassage builds the canonical §8.2 URL in noteRef + a labelled display")
    func buildsCanonical() {
        let id = UUID()
        let a = SourceAnchor.notePassage(sourceNoteId: id, sourceBlockIndex: 2,
                                         sourceTitle: "Moore on Intel", sourceDateDisplay: "1968")
        #expect(a.link == nil)
        #expect(a.display == "Moore on Intel — 1968")
        #expect(a.noteRef == DurableLink.notesOpen(id: id, block: 2).url.absoluteString)
        #expect(a.noteRef?.contains("#block-2") == true)
    }

    @Test("empty date ⟹ label is just the title")
    func emptyDateLabel() {
        let a = SourceAnchor.notePassage(sourceNoteId: UUID(), sourceBlockIndex: 0,
                                         sourceTitle: "Just Title", sourceDateDisplay: "  ")
        #expect(a.display == "Just Title")
    }

    @Test("notePassageTarget parses the canonical form")
    func parsesCanonical() throws {
        let id = UUID()
        let a = SourceAnchor.notePassage(sourceNoteId: id, sourceBlockIndex: 3,
                                         sourceTitle: "T", sourceDateDisplay: "1970")
        let target = try #require(a.notePassageTarget)
        #expect(target.id == id)
        #expect(target.block == 3)
    }

    @Test("notePassageTarget tolerates the legacy note/UUID spelling (read-only)")
    func parsesLegacy() throws {
        let id = UUID()
        let a = SourceAnchor(link: nil, display: "x", page: nil, thumbRef: nil, zoteroSelect: nil,
                             noteRef: "archivenotes://note/\(id.uuidString)#block-1")
        let target = try #require(a.notePassageTarget)
        #expect(target.id == id)
        #expect(target.block == 1)
    }

    @Test("notePassageTarget rejects non-passage / malformed anchors")
    func rejectsOthers() {
        #expect(SourceAnchor(link: nil, display: nil, page: nil, thumbRef: nil, zoteroSelect: nil,
                             noteRef: "archivereader://reveal?rootGUID=x&path=y").notePassageTarget == nil)
        #expect(SourceAnchor(link: "x", display: nil, page: 1, thumbRef: nil, zoteroSelect: nil,
                             noteRef: nil).notePassageTarget == nil)
        #expect(SourceAnchor(link: nil, display: nil, page: nil, thumbRef: nil, zoteroSelect: nil,
                             noteRef: "not a url at all ::::").notePassageTarget == nil)
    }

    @Test("on-disk header round-trips the note-passage block + preserves unknown fields")
    func onDiskRoundTrip() throws {
        let id = UUID()
        let anchor = SourceAnchor.notePassage(sourceNoteId: id, sourceBlockIndex: 2,
                                              sourceTitle: "Moore", sourceDateDisplay: "1968")
        let block = Block(kind: .notePassage, source: anchor, markdown: "Body text here.\n",
                          unknownHeaderFields: [("custom", "keepme")])
        let serialized = BlockParser.serialize(leadingText: nil, blocks: [block])
        #expect(serialized.contains("<!-- block: note-passage"))
        #expect(serialized.contains("note: \(anchor.noteRef!)"))

        let (_, parsed) = BlockParser.parse(serialized)
        let rt = try #require(parsed.first)
        #expect(rt.kind == .notePassage)
        #expect(rt.source?.noteRef == anchor.noteRef)
        #expect(rt.source?.display == "Moore — 1968")
        #expect(rt.markdown == "Body text here.\n")
        #expect(rt.unknownHeaderFields.first?.0 == "custom")
        #expect(rt.unknownHeaderFields.first?.1 == "keepme")
        #expect(rt.source?.notePassageTarget?.id == id)
    }
}

// MARK: - defaultTitle

@Suite("ExtractBuilder.defaultTitle (W7-S1)")
struct ExtractTitleTests {
    private func passage(_ md: String) -> Block {
        Block(kind: .notePassage, source: nil, markdown: md, unknownHeaderFields: [])
    }
    private let epoch = Date(timeIntervalSince1970: 0)

    @Test("strips markdown markers")
    func stripsMarkers() {
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage("# Hello **World**\nmore")],
                                            fallbackDate: epoch) == "Hello World")
    }

    @Test("skips leading blank + image-only lines")
    func skipsImageOnly() {
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage("\n![pic](assets/x.png)\nReal Title")],
                                            fallbackDate: epoch) == "Real Title")
    }

    /// W3.notes-thumb-line-duplicates-fu1 — a thumbnail line whose alt text carries an ESCAPED
    /// bracket (`![Moore \[draft\]](…)`, which is what a bracketed document title now writes) is
    /// still an image, so an image-only line is still empty. Against the pattern this file's other
    /// cases were written for, the escaped form survived stripping and became the extract's title.
    @Test("skips an image-only line whose alt text is escaped")
    func skipsEscapedAltImageOnly() {
        #expect(ExtractBuilder.defaultTitle(
            fromFirstLineOf: [passage("![Moore \\[draft\\]](assets/p1.png)\nReal Title")],
            fallbackDate: epoch) == "Real Title")
    }

    /// W3.notes-image-dest-paren — the stripping pattern is the same grammar, so it has to widen with
    /// the reader or the two disagree about what an image is. Both spellings, because a note can hold
    /// either: the healed angle form the emitter writes, and the bare one a hand edit leaves. Against
    /// the old `[^)]*` the tail of the path (`.png)`) survived stripping and became the extract's
    /// TITLE — and, through `sanitizedTitle`, its filename.
    @Test("skips an image-only line whose path contains a parenthesis, in both spellings")
    func skipsParenthesisedPathImageOnly() {
        #expect(ExtractBuilder.defaultTitle(
            fromFirstLineOf: [passage("![p](<assets/photo (1).png>)\nReal Title")],
            fallbackDate: epoch) == "Real Title")
        #expect(ExtractBuilder.defaultTitle(
            fromFirstLineOf: [passage("![p](assets/photo (1).png)\nReal Title")],
            fallbackDate: epoch) == "Real Title")
    }

    @Test("truncates on a word boundary at 80 chars")
    func truncates() {
        let long = String(repeating: "word ", count: 40) // 200 chars
        let t = ExtractBuilder.defaultTitle(fromFirstLineOf: [passage(long)], fallbackDate: epoch)
        #expect(t.count <= 80)
        #expect(!t.hasSuffix(" "))
        #expect(t.hasPrefix("word word"))
    }

    @Test("falls back to Extract <date> for whitespace/image-only")
    func fallback() {
        let t = ExtractBuilder.defaultTitle(fromFirstLineOf: [passage("   \n![only](assets/a.png)\n   ")],
                                            fallbackDate: epoch)
        #expect(t.hasPrefix("Extract "))
    }

    // MARK: - W3.notes-extract-title-line-split
    //
    // "First line" was computed with `split(separator: "\n")`, and Swift compares GRAPHEMES: `"\r\n"` is
    // not `"\n"`, and a lone `"\r"` is not one either. A CR/CRLF-delimited snapshot therefore did not
    // split at ALL — the loop saw one line and the extract was titled with the first 80 characters of the
    // whole passage. Reachable because PDF text extraction hands back both forms and extracts are built
    // from Reader selections. Each case below is run for all three terminators so the LF control proves
    // the assertion itself is right; only the CR and CRLF rows were red.

    @Test("titles from the FIRST line, whatever the line terminator",
          arguments: ["\n", "\r\n", "\r"])
    func firstLineForEveryTerminator(terminator: String) {
        let md = "First line\(terminator)Second line\(terminator)Third line"
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage(md)],
                                            fallbackDate: epoch) == "First line")
    }

    @Test("skips leading blank + image-only lines, whatever the line terminator",
          arguments: ["\n", "\r\n", "\r"])
    func skipsImageOnlyForEveryTerminator(terminator: String) {
        let md = "\(terminator)![pic](assets/x.png)\(terminator)Real Title"
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage(md)],
                                            fallbackDate: epoch) == "Real Title")
    }

    @Test("falls back to Extract <date> for a whitespace/image-only snapshot, whatever the terminator",
          arguments: ["\n", "\r\n", "\r"])
    func fallbackForEveryTerminator(terminator: String) {
        let md = "   \(terminator)![only](assets/a.png)\(terminator)   "
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage(md)],
                                            fallbackDate: epoch).hasPrefix("Extract "))
    }

    /// The block seam is its own case: the markdowns are joined with `"\n"`, so a block whose text ends
    /// in a lone `"\r"` produced a `"\r\n"` grapheme at the join — one line break that the old
    /// `"\n"` split could not see, welding the next block's first line onto the title.
    @Test("a block ending in a lone CR does not weld onto the next block's first line")
    func crTerminatedBlockJoinDoesNotWeld() {
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage("First line\r"),
                                                              passage("Second line")],
                                            fallbackDate: epoch) == "First line")
    }

    // MARK: - W3.notes-image-label-trailing-backslash — the title path resolves escapes
    //
    // `strippedTitleLine` deleted `*`, `_` and `` ` `` unconditionally and never unescaped anything, so
    // `MarkdownBridge.escapeMarkdown`'s own output came back through it wrong in both directions — and
    // the result is durable, becoming the extract's `title:` front matter AND (via `sanitizedTitle`,
    // which maps only `/` and `:`) its `.md` filename. Every case below is written as what the EDITOR
    // writes for ordinary typed prose, because that is what makes them reachable rather than theoretical.

    /// The plain case, and the one that motivated the item: brackets are escaped on the way out, so
    /// they have to be resolved on the way back or the backslashes are the title.
    @Test("an escaped bracket in the first line does not put a backslash in the title")
    func escapedBracketIsResolved() {
        // Typed `Real [Title]` → `escapeMarkdown` → `Real \[Title\]`.
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage(#"Real \[Title\]"#)],
                                            fallbackDate: epoch) == "Real [Title]")
    }

    /// The worse direction: deleting a marker unconditionally kept the backslash that protected it,
    /// so an escaped asterisk lost the asterisk and *gained* nothing but the escape.
    @Test("an escaped emphasis marker survives as itself, without its backslash")
    func escapedEmphasisMarkerIsLiteral() {
        // Typed `Real *not emphasis*` → `escapeMarkdown` → `Real \*not emphasis\*`.
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage(#"Real \*not emphasis\*"#)],
                                            fallbackDate: epoch) == "Real *not emphasis*")
        // Same for `_` and a backtick, which the same pass deleted.
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage(#"a \_b\_ \`c\`"#)],
                                            fallbackDate: epoch) == "a _b_ `c`")
    }

    /// An escape is what says a leading marker is not a block marker — so the escaped form must not be
    /// stripped as a bullet, and must not leave the backslash behind either.
    @Test("an escaped leading bullet is literal text, backslash and all resolved")
    func escapedLeadingBulletIsLiteral() {
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage(#"\* not a bullet"#)],
                                            fallbackDate: epoch) == "* not a bullet")
    }

    /// A backslash the operator actually typed is written doubled, and must come back single — the
    /// same growth trap `unescapeAlt` exists to prevent, one field over.
    @Test("a literal backslash comes back single, not doubled")
    func literalBackslashIsNotDoubled() {
        // Typed `C:\path` → `escapeMarkdown` → `C:\\path`.
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage(#"C:\\path"#)],
                                            fallbackDate: epoch) == #"C:\path"#)
    }

    /// Text that merely *looks* like an image is not one, and reads back as what was typed.
    @Test("an escaped image-looking line titles with the text the operator typed")
    func escapedImageLookalikeIsPlainText() {
        // Typed `![alt](x)` → `escapeMarkdown` → `!\[alt\](x)`; no `![`, so it is not a reference.
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage(#"!\[alt\](x)"#)],
                                            fallbackDate: epoch) == "![alt](x)")
    }

    /// The item's own second surface. `![a\](x)` alone is NOT an image reference — the label crosses
    /// the escaped `]` and never closes — and CommonMark renders it as the literal text `![a](x)`.
    /// That is now exactly the title, where before it was the raw markdown with the backslash in it.
    @Test("a label ending in a lone backslash titles with CommonMark's rendering of the line")
    func loneTrailingBackslashLabelReadsAsItsRendering() {
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage(#"![a\](x)"#)],
                                            fallbackDate: epoch) == "![a](x)")
    }

    /// Green before and after, on purpose: a line ending on a lone backslash has nothing to escape, so
    /// the trailing backslash is kept. This guards the tail branch the loop needs and would otherwise
    /// never exercise. (CommonMark would read a hard line break and render nothing — a deliberate
    /// departure, unreachable from the emitter, documented on `strippedInlineMarkers`.)
    @Test("a line ending on a lone backslash keeps it")
    func trailingLoneBackslashIsKept() {
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage(#"Title\"#)],
                                            fallbackDate: epoch) == #"Title\"#)
    }

    // MARK: - Code is exempt from both halves of the pass
    //
    // `MarkdownBridge` writes code content RAW — `wrapInlineCode` escapes nothing, and a code-block run
    // is `result += runText`. So a title pass that unescapes there deletes a backslash the operator
    // actually typed, and one that deletes `*`/`_` there (as the pre-fix pass did) eats their code.

    /// The regression the adversarial pass caught. Green against the PRE-fix code too — which is the
    /// point: the old pass never unescaped anything, so it got code right by accident, and a flat
    /// unescape would have broken it. This is the guard that says the fix did not trade one bug for
    /// another; only the intermediate version fails it.
    @Test("a code span's content is taken verbatim — no unescaping")
    func codeSpanContentIsVerbatim() {
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage(#"`re.sub(r'\.', '')`"#)],
                                            fallbackDate: epoch) == #"re.sub(r'\.', '')"#)
    }

    /// The mirror-image bug, PRE-EXISTING and fixed by the same rule: emphasis markers are not markers
    /// inside a code span, so deleting them ate the operator's code.
    @Test("a code span keeps the emphasis characters in its content")
    func codeSpanKeepsMarkerCharacters() {
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage("`a*b_c`")],
                                            fallbackDate: epoch) == "a*b_c")
    }

    /// `wrapInlineCode` widens the fence and pads with spaces when the text itself holds a backtick —
    /// so the reader has to un-pad, or the title gains two spaces.
    @Test("a widened code span un-pads exactly one space each side")
    func widenedCodeSpanIsUnpadded() {
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage("`` a`b ``")],
                                            fallbackDate: epoch) == "a`b")
    }

    /// An unmatched backtick has no closing run, so it is not a span. It is dropped as a stray marker
    /// (the old behaviour) rather than shown — and, crucially, the rest of the line is still processed
    /// as ordinary text, not swallowed as code.
    @Test("an unmatched backtick does not turn the rest of the line into code")
    func unmatchedBacktickIsAStrayMarker() {
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage(#"a `b \[c\]"#)],
                                            fallbackDate: epoch) == "a b [c]")
    }

    /// A fence is the one piece of the grammar a single line cannot decide, so `defaultTitle` carries
    /// it. The fence line strips to nothing, which makes the first CODE line the title — verbatim.
    @Test("a fenced block's first line titles the extract verbatim")
    func fencedBlockFirstLineIsVerbatim() {
        // A regex-ish code line: a backslash before punctuation, and an emphasis character. Pre-fix
        // the markers were deleted and the backslash kept — `a\bc`, code the operator never wrote.
        let md = "```swift\na\\*b_c\nmore\n```"
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage(md)],
                                            fallbackDate: epoch) == #"a\*b_c"#)
    }

    /// …and the fence must actually CLOSE, or every following line would be read as code.
    @Test("text after a closed fence is processed as markdown again")
    func textAfterAClosedFenceIsMarkdownAgain() {
        let md = "```\n\n```\nReal \\[Title\\]"
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage(md)],
                                            fallbackDate: epoch) == "Real [Title]")
    }

    /// The over-fix guard: an ordinary inline-code line still loses its backticks, so a code-only first
    /// line names the extract after the code rather than after a pair of delimiters.
    @Test("an ordinary code span still loses its delimiters")
    func ordinaryCodeSpanLosesItsDelimiters() {
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage("`plain code`")],
                                            fallbackDate: epoch) == "plain code")
    }

    // MARK: - W3.notes-extract-title-link-markdown — a link titles with its LABEL
    //
    // The pass stripped images, emphasis, code and leading block markers, but not LINKS — so a first
    // line that was one titled the extract with the raw construct, and `sanitizedTitle` (which maps
    // only `/` and `:`) turned that into the filename `[Label](https---example.com).md`. Reachable by
    // ordinary use: `MarkdownBridge.serialize` writes every `.link` run as `[text](url)`, and pasting
    // a URL is how one gets there. The fix REDUCES rather than deletes, because the label is what
    // CommonMark renders and usually the title the operator meant.

    @Test("a link titles the extract with its label, not the raw markdown")
    func linkTitlesWithItsLabel() {
        #expect(ExtractBuilder.defaultTitle(
            fromFirstLineOf: [passage("[Example Doc](https://example.com)\nbody")],
            fallbackDate: epoch) == "Example Doc")
    }

    /// The auto-detected paste: the editor makes the URL its own label, so the title is the URL. Still
    /// an improvement — the filename goes from `[https---example.com](https---example.com).md` to
    /// `https---example.com.md` — and it is exactly CommonMark's rendering. What remains ugly there is
    /// `sanitizedTitle`'s mapping of `:` and `/`, which is not this pass's business.
    @Test("a link whose label IS the URL titles with the URL alone")
    func selfLabelledLinkTitlesWithTheURL() {
        #expect(ExtractBuilder.defaultTitle(
            fromFirstLineOf: [passage("[https://example.com](https://example.com)")],
            fallbackDate: epoch) == "https://example.com")
    }

    /// The label is `escapeAlt`/`escapeMarkdown` output, not plain text — which is why the reduction
    /// happens BEFORE `strippedInlineMarkers` rather than after it. A bracketed document title is the
    /// reachable shape (`Moore [draft]` is written `Moore \[draft\]`).
    @Test("an escaped label is unescaped like any other inline text")
    func linkLabelGoesThroughTheEscapePass() {
        #expect(ExtractBuilder.defaultTitle(
            fromFirstLineOf: [passage(#"[Moore \[draft\]](https://example.com)"#)],
            fallbackDate: epoch) == "Moore [draft]")
        #expect(ExtractBuilder.defaultTitle(
            fromFirstLineOf: [passage("[a *b* `c`](https://example.com)")],
            fallbackDate: epoch) == "a b c")
    }

    /// A destination with balanced parentheses is one destination — the grammar owner's rule, and the
    /// case a hand-rolled `[^)]+` would have split, leaving `Foo_(bar)` welded onto the title.
    @Test("a parenthesised URL is one destination, in both spellings")
    func parenthesisedURLIsOneDestination() {
        #expect(ExtractBuilder.defaultTitle(
            fromFirstLineOf: [passage("[Foo](https://en.wikipedia.org/wiki/Foo_(bar))")],
            fallbackDate: epoch) == "Foo")
        #expect(ExtractBuilder.defaultTitle(
            fromFirstLineOf: [passage("[Foo](<https://en.wikipedia.org/wiki/Foo_(bar)>)")],
            fallbackDate: epoch) == "Foo")
    }

    /// Block markers are stripped first, so a linked heading reads as its label…
    @Test("a linked heading titles with the label")
    func linkedHeadingTitlesWithTheLabel() {
        #expect(ExtractBuilder.defaultTitle(
            fromFirstLineOf: [passage("# [Title](https://example.com)")],
            fallbackDate: epoch) == "Title")
        #expect(ExtractBuilder.defaultTitle(
            fromFirstLineOf: [passage("- [Item](https://example.com)")],
            fallbackDate: epoch) == "Item")
    }

    /// …and the ORDER is why: a `#` inside a link label is literal inline text, not a heading marker,
    /// so it must survive. Reducing links before the block-marker strip would eat it.
    @Test("a hash inside a link label is not a heading marker")
    func hashInsideALabelSurvives() {
        #expect(ExtractBuilder.defaultTitle(
            fromFirstLineOf: [passage("[# Not a heading](https://example.com)")],
            fallbackDate: epoch) == "# Not a heading")
    }

    /// An empty label renders as nothing, so the line is empty and the next one names the extract —
    /// the same rule an image-only line already followed.
    @Test("a link with an empty label reads as an empty line")
    func emptyLabelLinkIsAnEmptyLine() {
        #expect(ExtractBuilder.defaultTitle(
            fromFirstLineOf: [passage("[](https://example.com)\nReal Title")],
            fallbackDate: epoch) == "Real Title")
    }

    /// An image inside a link is CommonMark-legal and is exactly the shape a thumbnail line takes if
    /// it is ever made clickable. The image goes first, leaving an empty label, so the line is empty.
    @Test("an image wrapped in a link still reads as an empty line")
    func linkedImageIsAnEmptyLine() {
        #expect(ExtractBuilder.defaultTitle(
            fromFirstLineOf: [passage("[![pic](assets/x.png)](https://example.com)\nReal Title")],
            fallbackDate: epoch) == "Real Title")
    }

    /// The over-fix guard that matters most: an IMAGE is still DELETED, not reduced to its alt text.
    /// The two patterns differ only by the bang, so a link pass running first — or an image pass that
    /// missed — would title this `!pic`.
    @Test("an image is still deleted, and leaves no bang behind")
    func imageIsStillDeletedNotReduced() {
        #expect(ExtractBuilder.defaultTitle(
            fromFirstLineOf: [passage("![pic](assets/x.png) Caption")],
            fallbackDate: epoch) == "Caption")
        #expect(ExtractBuilder.defaultTitle(
            fromFirstLineOf: [passage("![pic](assets/x.png)\nReal Title")],
            fallbackDate: epoch) == "Real Title")
    }

    /// The other over-fix guard: brackets that are not a reference are ordinary text and stay put.
    @Test("brackets that are not a link are left alone")
    func nonLinkBracketsAreLeftAlone() {
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage("[Not a link] and text")],
                                            fallbackDate: epoch) == "[Not a link] and text")
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage("[Unclosed](no paren")],
                                            fallbackDate: epoch) == "[Unclosed](no paren")
    }

    /// **Decided out of scope** (see `defaultTitle`): an autolink is not reachable from the emitter and
    /// CommonMark renders it AS the URL, so reducing it would swap `<https---x>.md` for `https---x.md`
    /// — no real gain for a wider grammar. Pinned so the decision is visible if it is ever revisited.
    @Test("an autolink keeps its angle brackets — out of scope, by decision")
    func autolinkIsOutOfScope() {
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage("<https://example.com>")],
                                            fallbackDate: epoch) == "<https://example.com>")
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage("https://example.com")],
                                            fallbackDate: epoch) == "https://example.com")
    }

    /// **Known divergence, pinned rather than fixed** — `W3.notes-extract-title-code-span-references`.
    /// The image and link passes are line-wide regexes, so a reference inside a code span is reduced
    /// even though CommonMark renders it literally. Pre-existing in shape (the image strip has always
    /// done this) and widened here to links; fixing it means teaching the code-span scanner the
    /// reference grammar, which is a bigger change than this item. This test flips when that lands.
    @Test("a reference inside a code span is reduced anyway (known divergence)")
    func referenceInsideACodeSpanIsReducedAnyway() {
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage("`[a](b)`")],
                                            fallbackDate: epoch) == "a")
        #expect(ExtractBuilder.defaultTitle(fromFirstLineOf: [passage("`![a](b)` tail")],
                                            fallbackDate: epoch) == "tail")
    }

    /// A fenced block is exempt for real — `defaultTitle` takes those lines verbatim, so a code line
    /// that happens to be a link is the operator's code and keeps its markdown.
    @Test("a link inside a fenced block is taken verbatim")
    func linkInsideAFenceIsVerbatim() {
        #expect(ExtractBuilder.defaultTitle(
            fromFirstLineOf: [passage("```\n[a](b)\n```")],
            fallbackDate: epoch) == "[a](b)")
    }
}

// MARK: - Passage building + persistence

@Suite("ExtractBuilder — passage snapshot + persistence (W7-S1)")
@MainActor
struct ExtractBuilderTests {
    private func scratch() throws -> (NoteStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtractBuilderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (NoteStore(root: tmp), tmp)
    }
    private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    @Test("payload → one note-passage block per segment, ordinals preserved")
    func payloadBlocks() {
        let nid = UUID()
        let payload = NotesPassagePayload(
            sourceNoteId: nid, sourceTitle: "Src", sourceDateDisplay: "1968",
            segments: [.init(sourceBlockIndex: 2, markdown: "First"),
                       .init(sourceBlockIndex: 5, markdown: "Second")])
        let blocks = ExtractBuilder.passageBlocks(from: payload)
        #expect(blocks.count == 2)
        #expect(blocks.allSatisfy { $0.block.kind == .notePassage })
        #expect(blocks[0].block.source?.notePassageTarget?.block == 2)
        #expect(blocks[1].block.source?.notePassageTarget?.block == 5)
        #expect(blocks[0].block.source?.notePassageTarget?.id == nid)
        #expect(blocks[0].block.markdown == "First")
    }

    @Test("empty selection → no blocks")
    func emptySelection() {
        let src = FakeSelectionSource(fullText: "abc",
                                      selectedRanges: [NSRange(location: 0, length: 0)],
                                      blockRanges: [(0, NSRange(location: 0, length: 3))])
        #expect(ExtractBuilder.passageBlocks(fromSelectionIn: src).isEmpty)
    }

    @Test("single-block selection → one passage anchored to that block ordinal")
    func singleBlock() {
        let src = FakeSelectionSource(fullText: "Hello World",
                                      selectedRanges: [NSRange(location: 0, length: 5)],
                                      blockRanges: [(7, NSRange(location: 0, length: 11))])
        let blocks = ExtractBuilder.passageBlocks(fromSelectionIn: src)
        #expect(blocks.count == 1)
        #expect(blocks[0].block.markdown == "Hello")
        #expect(blocks[0].block.source?.notePassageTarget?.block == 7)
    }

    @Test("cross-block selection → one passage per covered block, in document order")
    func crossBlock() {
        let src = FakeSelectionSource(fullText: "AAAA\nBBBB\n",
                                      selectedRanges: [NSRange(location: 2, length: 6)],
                                      blockRanges: [(0, NSRange(location: 0, length: 5)),
                                                    (1, NSRange(location: 5, length: 5))])
        let blocks = ExtractBuilder.passageBlocks(fromSelectionIn: src)
        #expect(blocks.count == 2)
        #expect(blocks[0].block.source?.notePassageTarget?.block == 0)
        #expect(blocks[1].block.source?.notePassageTarget?.block == 1)
    }

    @Test("freeform source block still yields a note-passage anchor")
    func freeformStillPassage() {
        let src = FakeSelectionSource(fullText: "plain text",
                                      selectedRanges: [NSRange(location: 0, length: 10)],
                                      blockRanges: [(3, NSRange(location: 0, length: 10))])
        #expect(ExtractBuilder.passageBlocks(fromSelectionIn: src).first?.block.kind == .notePassage)
    }

    @Test("inline-image bytes are snapshotted (copied) into the passage")
    func assetsCarried() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let src = FakeSelectionSource(fullText: "see ![p](assets/p.png)",
                                      selectedRanges: [NSRange(location: 0, length: 22)],
                                      blockRanges: [(0, NSRange(location: 0, length: 22))],
                                      assetsForBlock: [0: ["p.png": bytes]])
        #expect(ExtractBuilder.passageBlocks(fromSelectionIn: src).first?.pendingAssets["p.png"] == bytes)
    }

    @Test("createExtract persists a byte-stable extract that reloads identically")
    func createRoundTrip() async throws {
        let (store, tmp) = try scratch(); defer { cleanup(tmp) }
        let fixed = Date(timeIntervalSince1970: 1_000_000_000)
        let builder = ExtractBuilder(store: store, now: { fixed })
        let payload = NotesPassagePayload(
            sourceNoteId: UUID(), sourceTitle: "Moore on Intel culture", sourceDateDisplay: "1968",
            segments: [.init(sourceBlockIndex: 2, markdown: "Moore says he and Noyce were responsible…\n")])
        let created = try await builder.createExtract(from: ExtractBuilder.passageBlocks(from: payload))

        #expect(created.kind == .extract)
        #expect(created.datePrecision == .day)
        #expect(created.title == "Moore says he and Noyce were responsible…")
        #expect(created.blocks.count == 1)

        let reloaded = try await store.load(created.id)
        #expect(reloaded.kind == .extract)
        #expect(reloaded.blocks == created.blocks)
        #expect(reloaded.blocks.first?.source?.notePassageTarget?.block == 2)
        #expect(FrontMatterCodec.encode(reloaded) == FrontMatterCodec.encode(created))
    }

    @Test("createExtract copies inline-image bytes into the new extract's assets/ (independent copy)")
    func createCopiesAssets() async throws {
        let (store, tmp) = try scratch(); defer { cleanup(tmp) }
        let fixed = Date(timeIntervalSince1970: 1_000_000_000)
        let builder = ExtractBuilder(store: store, now: { fixed })
        let bytes = Data([1, 2, 3, 4, 5])
        let payload = NotesPassagePayload(
            sourceNoteId: UUID(), sourceTitle: "T", sourceDateDisplay: "",
            segments: [.init(sourceBlockIndex: 0, markdown: "![p](assets/p.png)\n", assetPNGs: ["p.png": bytes])])
        let created = try await builder.createExtract(from: ExtractBuilder.passageBlocks(from: payload))

        let assetURL = await store.assetsDir(created.id).appendingPathComponent("p.png")
        let onDisk = try #require(FileManager.default.contents(atPath: assetURL.path))
        #expect(onDisk == bytes)
        #expect(created.blocks.first?.markdown.contains("assets/p.png") == true)
    }

    @Test("append adds cross-note segments to an existing extract + bumps modified")
    func appendSegments() async throws {
        let (store, tmp) = try scratch(); defer { cleanup(tmp) }
        let t0 = Date(timeIntervalSince1970: 1000)
        let created = try await ExtractBuilder(store: store, now: { t0 }).createExtract(
            from: ExtractBuilder.passageBlocks(from: NotesPassagePayload(
                sourceNoteId: UUID(), sourceTitle: "Note A", sourceDateDisplay: "1968",
                segments: [.init(sourceBlockIndex: 0, markdown: "From A\n")])))

        let t1 = Date(timeIntervalSince1970: 2000)
        try await ExtractBuilder(store: store, now: { t1 }).append(
            toExtract: created.id,
            passages: ExtractBuilder.passageBlocks(from: NotesPassagePayload(
                sourceNoteId: UUID(), sourceTitle: "Note B", sourceDateDisplay: "1972",
                segments: [.init(sourceBlockIndex: 3, markdown: "From B\n")])))

        let reloaded = try await store.load(created.id)
        #expect(reloaded.blocks.count == 2)
        #expect(reloaded.blocks[0].markdown == "From A\n")
        #expect(reloaded.blocks[1].markdown == "From B\n")
        #expect(reloaded.modified.timeIntervalSince1970 == 2000)
        #expect(reloaded.blocks[0].source?.notePassageTarget?.id
                != reloaded.blocks[1].source?.notePassageTarget?.id)
    }

    // MARK: - Extract-paste inline-image byte import (W14.3)

    /// The extract host must exist (its assets/ dir is the paste target). Returns a scratch NoteStore, a
    /// created extract Item, and an ItemAssetStore aimed at it — the production paste-import wiring.
    private func pasteFixture() async throws -> (store: NoteStore, tmp: URL, extractID: UUID, assets: ItemAssetStore) {
        let (store, tmp) = try scratch()
        let extract = try await ExtractBuilder(store: store, now: { Date(timeIntervalSince1970: 1000) })
            .createExtract(from: ExtractBuilder.passageBlocks(from: NotesPassagePayload(
                sourceNoteId: UUID(), sourceTitle: "Host", sourceDateDisplay: "1968",
                segments: [.init(sourceBlockIndex: 0, markdown: "seed\n")])))
        let assets = ItemAssetStore(store: store, root: store.rootURL, itemID: extract.id)
        return (store, tmp, extract.id, assets)
    }

    @Test("extract-paste imports the payload's inline-image bytes into the extract's own assets/ (no collision → ref unchanged)")
    func pasteImportsBytesNoCollision() async throws {
        let f = try await pasteFixture(); defer { cleanup(f.tmp) }
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D])
        let payload = NotesPassagePayload(
            sourceNoteId: UUID(), sourceTitle: "Src", sourceDateDisplay: "1970",
            segments: [.init(sourceBlockIndex: 0, markdown: "![q](assets/q.png)\n", assetPNGs: ["q.png": bytes])])

        let markdown = ExtractBuilder.pastedExtractMarkdown(from: payload) { data, bare in
            try? f.assets.addAsset(data, preferredName: bare)
        }
        await f.assets.awaitPendingWrites()

        #expect(markdown.contains("](assets/q.png)"))    // no collision → original ref preserved
        let dir = await f.store.assetsDir(f.extractID)
        #expect(try Data(contentsOf: dir.appendingPathComponent("q.png")) == bytes)  // bytes landed, self-contained
    }

    @Test("extract-paste disambiguates a name collision: bytes land at the new name, ref is rewritten, existing file untouched")
    func pasteRewritesRefOnCollision() async throws {
        let f = try await pasteFixture(); defer { cleanup(f.tmp) }
        // A same-named asset already lives in the extract (an earlier paste) — the new paste MUST NOT clobber it.
        let existing = Data("OLD".utf8)
        _ = try await f.store.importAsset(existing, preferredName: "p.png", into: f.extractID)
        let pasted = Data("NEW".utf8)
        let payload = NotesPassagePayload(
            sourceNoteId: UUID(), sourceTitle: "Src", sourceDateDisplay: "1970",
            segments: [.init(sourceBlockIndex: 2, markdown: "see ![p](assets/p.png)\n", assetPNGs: ["p.png": pasted])])

        let markdown = ExtractBuilder.pastedExtractMarkdown(from: payload) { data, bare in
            try? f.assets.addAsset(data, preferredName: bare)
        }
        await f.assets.awaitPendingWrites()

        #expect(markdown.contains("](assets/p-1.png)"))  // rewritten to the disambiguated name
        #expect(!markdown.contains("](assets/p.png)"))
        let dir = await f.store.assetsDir(f.extractID)
        #expect(try Data(contentsOf: dir.appendingPathComponent("p-1.png")) == pasted)   // new bytes at new name
        #expect(try Data(contentsOf: dir.appendingPathComponent("p.png")) == existing)   // pre-existing bytes untouched
    }

    @Test("importingAssetsVia rewrites only collided refs; a nil (failed) import leaves that ref as-is — no crash")
    func pasteRewriteLogicAndNilResilience() {
        let payload = NotesPassagePayload(
            sourceNoteId: UUID(), sourceTitle: "Src", sourceDateDisplay: "1970",
            segments: [.init(sourceBlockIndex: 0,
                             markdown: "![a](assets/a.png) then ![b](assets/b.png)\n",
                             assetPNGs: ["a.png": Data([1]), "b.png": Data([2])])])
        // a.png "collides" → stored as a-1.png; b.png import "fails" (nil) → its ref is preserved verbatim.
        let markdown = ExtractBuilder.pastedExtractMarkdown(from: payload) { _, bare in
            bare == "a.png" ? "assets/a-1.png" : nil
        }
        #expect(markdown.contains("](assets/a-1.png)"))  // collided ref rewritten
        #expect(!markdown.contains("](assets/a.png)"))
        #expect(markdown.contains("](assets/b.png)"))    // failed import → original ref left dangling, not dropped
    }

    /// W3.notes-image-dest-paren — the coupled consumer. This re-key is a plain string match, so it
    /// has to spell the destination the way the emitter does: an asset whose name needs the
    /// angle-bracket form is written `](<assets/photo (1).png>)`, and a hand-rolled `](ref)` would
    /// silently find nothing — leaving the copied bytes referenced at the ORIGINAL name, i.e. a
    /// missing-asset placeholder in the new extract.
    @Test("A parenthesised asset name is re-keyed too — the destination is spelled by the grammar owner")
    func pasteRewritesAParenthesisedRef() {
        let payload = NotesPassagePayload(
            sourceNoteId: UUID(), sourceTitle: "Src", sourceDateDisplay: "1970",
            segments: [.init(sourceBlockIndex: 0,
                             markdown: "![a](<assets/photo (1).png>)\n",
                             assetPNGs: ["photo (1).png": Data([1])])])
        let markdown = ExtractBuilder.pastedExtractMarkdown(from: payload) { _, _ in
            "assets/photo (1)-1.png"
        }
        #expect(markdown.contains("](<assets/photo (1)-1.png>)"),
                "the collided ref was not rewritten: \(markdown.debugDescription)")
        #expect(!markdown.contains("](<assets/photo (1).png>)"),
                "the original ref survived, so the copy dangles: \(markdown.debugDescription)")
    }
}

// MARK: - Extract-references-notes-only invariant

@Suite("ExtractBuilder.coercedToNotesOnly — extracts reference notes only (W7-S1)")
struct ExtractRejectsNonNoteAnchorsTests {

    @Test("valid note-passage block is preserved")
    func keepsNotePassage() {
        let a = SourceAnchor.notePassage(sourceNoteId: UUID(), sourceBlockIndex: 1,
                                         sourceTitle: "T", sourceDateDisplay: "1968")
        let out = ExtractBuilder.coercedToNotesOnly([Block(kind: .notePassage, source: a,
                                                           markdown: "x", unknownHeaderFields: [])])
        #expect(out.first?.kind == .notePassage)
        #expect(out.first?.source != nil)
    }

    @Test("reader-page block coerces to freeform (source dropped, text preserved)")
    func coercesReader() {
        let b = Block(kind: .readerPage,
                      source: SourceAnchor(link: "archivereader://reveal?x=1", display: "Doc", page: 3,
                                           thumbRef: nil, zoteroSelect: nil, noteRef: nil),
                      markdown: "quote", unknownHeaderFields: [])
        let out = ExtractBuilder.coercedToNotesOnly([b])
        #expect(out.first?.kind == .freeform)
        #expect(out.first?.source == nil)
        #expect(out.first?.markdown == "quote")
    }

    @Test("zotero block coerces to freeform")
    func coercesZotero() {
        let b = Block(kind: .zoteroItem,
                      source: SourceAnchor(link: nil, display: "cite", page: nil, thumbRef: nil,
                                           zoteroSelect: "zotero://select/x", noteRef: nil),
                      markdown: "z", unknownHeaderFields: [])
        #expect(ExtractBuilder.coercedToNotesOnly([b]).first?.kind == .freeform)
    }

    @Test("note-passage with a malformed target coerces to freeform")
    func coercesMalformedPassage() {
        let b = Block(kind: .notePassage,
                      source: SourceAnchor(link: nil, display: "x", page: nil, thumbRef: nil,
                                           zoteroSelect: nil, noteRef: "archivereader://reveal?x=1"),
                      markdown: "m", unknownHeaderFields: [])
        #expect(ExtractBuilder.coercedToNotesOnly([b]).first?.kind == .freeform)
    }

    // W3.notes-extract-smuggles-a-source-header — the coercion also looks one level DOWN.

    @Test("a header nested inside a kept passage's markdown is stripped; the text stays")
    func flattensNestedHeaderInsideAKeptPassage() throws {
        let nested = Block(kind: .readerPage,
                           source: SourceAnchor(link: "archivereader://reveal?x=1", display: "Doc",
                                                page: 3, thumbRef: nil, zoteroSelect: nil, noteRef: nil),
                           markdown: "Quoted body.\n", unknownHeaderFields: [])
        let passage = Block(kind: .notePassage,
                            source: SourceAnchor.notePassage(sourceNoteId: UUID(), sourceBlockIndex: 1,
                                                             sourceTitle: "T", sourceDateDisplay: "1968"),
                            markdown: BlockParser.serialize(leadingText: nil, blocks: [nested]),
                            unknownHeaderFields: [])
        let out = try #require(ExtractBuilder.coercedToNotesOnly([passage]).first)
        #expect(out.kind == .notePassage)                     // still a passage…
        #expect(out.source?.notePassageTarget != nil)         // …with its own anchor intact
        #expect(!out.markdown.contains("<!-- block:"))        // …and no foreign header inside it
        #expect(out.markdown == "Quoted body.\n")             // text preserved verbatim
    }

    @Test("leading text before a nested header survives, on its own line")
    func flattensKeepingLeadingText() throws {
        let nested = Block(kind: .zoteroItem,
                           source: SourceAnchor(link: nil, display: "cite", page: nil, thumbRef: nil,
                                                zoteroSelect: "zotero://select/items/ABC", noteRef: nil),
                           markdown: "Cited.", unknownHeaderFields: [])
        let b = Block(kind: .freeform, source: nil,
                      markdown: BlockParser.serialize(leadingText: "Lead.\n", blocks: [nested]),
                      unknownHeaderFields: [])
        let out = try #require(ExtractBuilder.coercedToNotesOnly([b]).first)
        #expect(out.markdown == "Lead.\nCited.")
    }

    @Test("markdown with no nested header is returned byte-identical")
    func leavesCleanMarkdownAlone() throws {
        let b = Block(kind: .notePassage,
                      source: SourceAnchor.notePassage(sourceNoteId: UUID(), sourceBlockIndex: 0,
                                                       sourceTitle: "T", sourceDateDisplay: ""),
                      markdown: "Plain body\nwith two lines.\n", unknownHeaderFields: [])
        #expect(ExtractBuilder.coercedToNotesOnly([b]).first?.markdown == "Plain body\nwith two lines.\n")
    }
}

// MARK: - W3.notes-extract-smuggles-a-source-header (the invariant, asserted on DISK)

/// `coercedToNotesOnly` guards the invariant one block at a time; it cannot see a header nested
/// *inside* a block's markdown. That is how a whole-block selection used to smuggle the source
/// note's own `reader-page` / `zotero-*` header into an extract — `blockRanges` starts each segment
/// at its chip, so `MarkdownBridge.serialize` re-emitted the header as body text. The acceptance
/// bar is therefore the bytes on disk, not the block list.
@Suite("Extract round-trip — no foreign block header survives anywhere in a saved extract")
@MainActor
struct ExtractNestedSourceHeaderTests {
    private func scratch() throws -> (NoteStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtractNestedHeaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (NoteStore(root: tmp), tmp)
    }
    private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    /// A note whose blocks are a reader-page and a zotero-item, rendered exactly as the editor
    /// renders it (chip + body per block).
    private func renderedTwoSourceBlocks() -> NSAttributedString {
        let reader = Block(kind: .readerPage,
                           source: SourceAnchor(link: "archivereader://reveal?x=1", display: "Doc1",
                                                page: 1, thumbRef: nil, zoteroSelect: nil, noteRef: nil),
                           markdown: "Quoted body.\n", unknownHeaderFields: [])
        let zotero = Block(kind: .zoteroItem,
                           source: SourceAnchor(link: nil, display: "cite", page: nil, thumbRef: nil,
                                                zoteroSelect: "zotero://select/items/ABC", noteRef: nil),
                           markdown: "Cited body.", unknownHeaderFields: [])
        return MarkdownBridge.parse(markdown: BlockParser.serialize(leadingText: nil,
                                                                    blocks: [reader, zotero]))
    }

    @Test("select-all → createExtract: the .md on disk holds only note-passage headers")
    func selectAllRoundTrip() async throws {
        let (store, tmp) = try scratch(); defer { cleanup(tmp) }
        let rendered = renderedTwoSourceBlocks()
        let source = EditorPassageSource(
            sourceNoteId: UUID(), sourceTitle: "Src", sourceDateDisplay: "1968",
            rendered: rendered,
            selectedRanges: [NSRange(location: 0, length: rendered.length)],
            assetBytes: { _ in nil })
        let builder = ExtractBuilder(store: store, now: { Date(timeIntervalSince1970: 1_000_000_000) })
        let created = try await builder.createExtract(fromSelectionIn: source)

        let raw = try String(contentsOf: await store.mdURL(for: created.id), encoding: .utf8)
        #expect(!raw.contains("block: reader-page"), "reader-page header smuggled into:\n\(raw)")
        #expect(!raw.contains("block: zotero-"), "zotero header smuggled into:\n\(raw)")
        #expect(raw.contains("Quoted body."))          // the TEXT is never dropped
        #expect(raw.contains("Cited body."))

        let reloaded = try await store.load(created.id)
        #expect(reloaded.blocks.count == 2)            // one passage per covered source block, no more
        #expect(reloaded.blocks.allSatisfy { $0.kind == .notePassage })
        #expect(reloaded.blocks.allSatisfy { $0.source?.notePassageTarget != nil })
    }

    /// **W3.notes-image-label-trailing-backslash — the Tier-2 disk check.** The title path's output is
    /// not an in-memory nicety: it is written to the extract's `title:` front matter *and* projected
    /// into the `.md` filename, and `sanitizedTitle` maps only `/` and `:` — so a backslash the title
    /// pass failed to resolve lands in a real filename on a real disk. Copying a passage of ordinary
    /// prose containing brackets is the reachable route (`escapeMarkdown` writes them escaped), so this
    /// goes through the whole `createExtract` → write → reload cycle on a scratch store and reads the
    /// RAW bytes back. Pre-fix both assertions are `Real \[Title\]`.
    @Test("an escaped first line lands unescaped in the front matter AND the filename")
    func escapedFirstLineIsResolvedOnDisk() async throws {
        let (store, tmp) = try scratch(); defer { cleanup(tmp) }
        let payload = NotesPassagePayload(
            sourceNoteId: UUID(), sourceTitle: "Src", sourceDateDisplay: "1968",
            // What the editor writes when the operator types `Real [Title]` as the first line.
            segments: [.init(sourceBlockIndex: 0, markdown: #"Real \[Title\]"# + "\nbody\n")])
        let builder = ExtractBuilder(store: store, now: { Date(timeIntervalSince1970: 1_000_000_000) })
        let created = try await builder.createExtract(from: ExtractBuilder.passageBlocks(from: payload))

        let url = try await store.mdURL(for: created.id)
        #expect(url.lastPathComponent == "Real [Title].md",
                "the filename kept the escapes: \(url.lastPathComponent)")

        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("title: Real [Title]\n"),
                "the front matter kept the escapes:\n\(raw)")

        // And it survives the round trip, so the next save is not a rename.
        let reloaded = try await store.load(created.id)
        #expect(reloaded.title == "Real [Title]")
    }

    /// **W3.notes-extract-title-link-markdown — the Tier-2 disk check, with its reachability proved
    /// rather than asserted.** The markdown is not hand-written here: it comes out of
    /// `MarkdownBridge.serialize`, which is what turns a pasted URL (an `.link` run in the editor)
    /// into `[Label](https://example.com)`. That construct then named the extract AND its file, the
    /// scheme's `/` becoming `-` in `sanitizedTitle` — pre-fix, both assertions below read
    /// `[Example Doc](https---example.com)`.
    @Test("a pasted link lands on disk as its label, in the front matter AND the filename")
    func linkFirstLineIsReducedToItsLabelOnDisk() async throws {
        let (store, tmp) = try scratch(); defer { cleanup(tmp) }

        // What the editor actually emits for a link run — the emitter, not a guess about it.
        let run = NSMutableAttributedString(string: "Example Doc")
        run.addAttribute(.link, value: URL(string: "https://example.com")!,
                         range: NSRange(location: 0, length: run.length))
        let emitted = MarkdownBridge.serialize(run)
        #expect(emitted.contains("[Example Doc](https://example.com)"),
                "the emitter no longer writes this shape — re-check the premise: \(emitted)")

        let payload = NotesPassagePayload(
            sourceNoteId: UUID(), sourceTitle: "Src", sourceDateDisplay: "1968",
            segments: [.init(sourceBlockIndex: 0, markdown: emitted + "\nbody\n")])
        let builder = ExtractBuilder(store: store, now: { Date(timeIntervalSince1970: 1_000_000_000) })
        let created = try await builder.createExtract(from: ExtractBuilder.passageBlocks(from: payload))

        let url = try await store.mdURL(for: created.id)
        #expect(url.lastPathComponent == "Example Doc.md",
                "raw markdown reached the filename: \(url.lastPathComponent)")

        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("title: Example Doc\n"), "raw markdown reached the front matter:\n\(raw)")
        #expect(raw.contains("[Example Doc](https://example.com)"),
                "the BODY must keep the link — only the title is reduced:\n\(raw)")

        // Survives the round trip, so the next save is not a rename.
        let reloaded = try await store.load(created.id)
        #expect(reloaded.title == "Example Doc")
    }

    /// The choke-point half: even a passage handed straight to `createExtract` — bypassing the
    /// selection snapshot entirely — cannot write a foreign header, because `persist` runs the
    /// coercion. This is the case the paste path's `coercedToNotesOnly` never covered.
    @Test("a hand-built passage carrying a nested header still persists clean")
    func handBuiltPassageIsCoercedOnPersist() async throws {
        let (store, tmp) = try scratch(); defer { cleanup(tmp) }
        let nested = Block(kind: .readerPage,
                           source: SourceAnchor(link: "archivereader://reveal?x=9", display: "Doc9",
                                                page: 9, thumbRef: nil, zoteroSelect: nil, noteRef: nil),
                           markdown: "Smuggled body.\n", unknownHeaderFields: [])
        let passage = Block(kind: .notePassage,
                            source: SourceAnchor.notePassage(sourceNoteId: UUID(), sourceBlockIndex: 4,
                                                             sourceTitle: "T", sourceDateDisplay: "1968"),
                            markdown: BlockParser.serialize(leadingText: nil, blocks: [nested]),
                            unknownHeaderFields: [])
        let builder = ExtractBuilder(store: store, now: { Date(timeIntervalSince1970: 1_000_000_000) })
        let created = try await builder.createExtract(from: [ExtractPassageBlock(block: passage)])

        let raw = try String(contentsOf: await store.mdURL(for: created.id), encoding: .utf8)
        #expect(!raw.contains("block: reader-page"), "reader-page header smuggled into:\n\(raw)")
        #expect(raw.contains("Smuggled body."))
        #expect(created.title == "Smuggled body.")     // the header is not title material either
        let reloaded = try await store.load(created.id)
        #expect(reloaded.blocks.count == 1)
        #expect(reloaded.blocks.first?.kind == .notePassage)
        #expect(reloaded.blocks.first?.source?.notePassageTarget?.block == 4)
    }

    @Test("append to an existing extract cannot smuggle one either")
    func appendRoundTrip() async throws {
        let (store, tmp) = try scratch(); defer { cleanup(tmp) }
        let builder = ExtractBuilder(store: store, now: { Date(timeIntervalSince1970: 1_000_000_000) })
        let seed = NotesPassagePayload(sourceNoteId: UUID(), sourceTitle: "Seed",
                                       sourceDateDisplay: "1970",
                                       segments: [.init(sourceBlockIndex: 0, markdown: "Seed body.\n")])
        let created = try await builder.createExtract(from: ExtractBuilder.passageBlocks(from: seed))

        let rendered = renderedTwoSourceBlocks()
        let source = EditorPassageSource(
            sourceNoteId: UUID(), sourceTitle: "Src", sourceDateDisplay: "1968",
            rendered: rendered,
            selectedRanges: [NSRange(location: 0, length: rendered.length)],
            assetBytes: { _ in nil })
        _ = try await builder.append(toExtract: created.id, fromSelectionIn: source)

        let raw = try String(contentsOf: await store.mdURL(for: created.id), encoding: .utf8)
        #expect(!raw.contains("block: reader-page"), "reader-page header smuggled into:\n\(raw)")
        #expect(!raw.contains("block: zotero-"), "zotero header smuggled into:\n\(raw)")
        let reloaded = try await store.load(created.id)
        #expect(reloaded.blocks.count == 3)
        #expect(reloaded.blocks.allSatisfy { $0.kind == .notePassage })
    }
}
