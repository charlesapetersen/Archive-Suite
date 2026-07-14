import Testing
import Foundation
import AppKit
@testable import ArchiveNotes

@Suite("MarkdownBridgeTests — W3-S2 attributed↔Markdown bridge")
struct MarkdownBridgeTests {

    // MARK: - Parse basics

    @Test @MainActor
    func parseEmptyString() {
        let result = MarkdownBridge.parse(markdown: "")
        #expect(result.length == 0)
    }

    @Test @MainActor
    func parsePlainText() {
        let result = MarkdownBridge.parse(markdown: "Hello world")
        #expect(result.string.contains("Hello world"))
        // Should have noteBlockKind stamped
        let kind = result.attribute(.noteBlockKind, at: 0, effectiveRange: nil) as? BlockKind
        #expect(kind != nil)
    }

    // MARK: - Serialize basics

    @Test @MainActor
    func serializeEmptyAttributedString() {
        let result = MarkdownBridge.serialize(NSAttributedString())
        #expect(result == "")
    }

    @Test @MainActor
    func serializePlainTextRoundTrip() {
        let md = "Hello world"
        let parsed = MarkdownBridge.parse(markdown: md)
        let serialized = MarkdownBridge.serialize(parsed)
        #expect(serialized.trimmingCharacters(in: .whitespacesAndNewlines) == md)
    }

    // MARK: - Per-construct idempotency tests

    @Test @MainActor
    func heading1() {
        assertNormalized("# Heading One", expected: "# Heading One")
    }

    @Test @MainActor
    func heading2() {
        assertNormalized("## Heading Two", expected: "## Heading Two")
    }

    @Test @MainActor
    func heading3() {
        assertNormalized("### Heading Three", expected: "### Heading Three")
    }

    @Test @MainActor
    func heading4() {
        assertNormalized("#### Heading Four", expected: "#### Heading Four")
    }

    @Test @MainActor
    func heading5() {
        assertNormalized("##### Heading Five", expected: "##### Heading Five")
    }

    @Test @MainActor
    func heading6() {
        assertNormalized("###### Heading Six", expected: "###### Heading Six")
    }

    @Test @MainActor
    func boldText() {
        assertNormalized("Some **bold** text", expected: "Some **bold** text")
    }

    @Test @MainActor
    func italicText() {
        assertNormalized("Some *italic* text", expected: "Some *italic* text")
    }

    @Test @MainActor
    func boldItalicText() {
        assertNormalized("Some ***bold italic*** text", expected: "Some ***bold italic*** text")
    }

    @Test @MainActor
    func inlineCode() {
        assertNormalized("Use `code` here", expected: "Use `code` here")
    }

    @Test @MainActor
    func linkText() {
        assertNormalized("[Click here](https://example.com)", expected: "[Click here](https://example.com)")
    }

    @Test @MainActor
    func unorderedList() {
        assertNormalized("- Item one\n- Item two\n- Item three",
                         expected: "- Item one\n- Item two\n- Item three")
    }

    @Test @MainActor
    func orderedList() {
        // Apple normalizes ordinal numbering
        assertNormalized("1. First\n2. Second\n3. Third",
                         expected: "1. First\n2. Second\n3. Third")
    }

    @Test @MainActor
    func blockquote() {
        assertNormalized("> A quoted line", expected: "> A quoted line")
    }

    @Test @MainActor
    func codeBlock() {
        assertNormalized("```\nlet x = 1\n```", expected: "```\nlet x = 1\n```")
    }

    @Test @MainActor
    func codeBlockWithLanguage() {
        assertNormalized("```swift\nlet x = 1\n```", expected: "```swift\nlet x = 1\n```")
    }

    // MARK: - Mixed document

    @Test @MainActor
    func mixedDocument() {
        let md = """
        # Title

        Some **bold** and *italic* text.

        - List item one
        - List item two

        > A quote

        ```
        code
        ```
        """
        let parsed = MarkdownBridge.parse(markdown: md)
        let serialized = MarkdownBridge.serialize(parsed)
        // Text must never be lost
        #expect(serialized.contains("Title"))
        #expect(serialized.contains("bold"))
        #expect(serialized.contains("italic"))
        #expect(serialized.contains("List item one"))
        #expect(serialized.contains("List item two"))
        #expect(serialized.contains("A quote"))
        #expect(serialized.contains("code"))
    }

    // MARK: - Second round-trip is a no-op

    @Test @MainActor
    func secondRoundTripIsNoOp() {
        let inputs = [
            "# Heading",
            "Some **bold** and *italic* text",
            "- Item one\n- Item two",
            "1. First\n2. Second",
            "> Quote text",
            "Use `inline code` here",
            "Plain paragraph text",
        ]

        for input in inputs {
            let firstParse = MarkdownBridge.parse(markdown: input)
            let firstSerialize = MarkdownBridge.serialize(firstParse)
            let secondParse = MarkdownBridge.parse(markdown: firstSerialize)
            let secondSerialize = MarkdownBridge.serialize(secondParse)
            #expect(firstSerialize == secondSerialize,
                    "Second round-trip should be no-op for: \(input)")
        }
    }

    // MARK: - Unknown styling drops, text preserved

    @Test @MainActor
    func unknownVisualStylingIsDroppedTextPreserved() {
        // Build an NSAttributedString with unsupported styling (underline)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.textColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .noteBlockKind: BlockKind.plain
        ]
        let styled = NSAttributedString(string: "Underlined text", attributes: attrs)
        let serialized = MarkdownBridge.serialize(styled)
        // Text is preserved; underline styling is dropped (no Markdown equivalent)
        #expect(serialized.contains("Underlined text"))
        // Should NOT contain any markdown formatting markers for the underline
        #expect(!serialized.contains("**"))
        #expect(!serialized.contains("*Underlined"))
    }

    // MARK: - Apple parser semantic snapshot

    @Test @MainActor
    func applesParserSemanticSnapshot() {
        // Pin that Apple's parser produces presentationIntent for headings
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: "# Test Heading", options: options) else {
            Issue.record("Apple's markdown parser failed on a simple heading")
            return
        }

        var foundHeading = false
        for run in parsed.runs {
            if let intent = run.presentationIntent {
                for component in intent.components {
                    if case .header(level: 1) = component.kind {
                        foundHeading = true
                    }
                }
            }
        }
        #expect(foundHeading, "Apple parser must produce .header(level: 1) for '# Test Heading'")
    }

    @Test @MainActor
    func applesParserBoldSnapshot() {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: "Normal **bold** text", options: options) else {
            Issue.record("Apple parser failed")
            return
        }

        var foundBold = false
        for run in parsed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.stronglyEmphasized) {
                foundBold = true
            }
        }
        #expect(foundBold, "Apple parser must produce .stronglyEmphasized for **bold**")
    }

    // MARK: - Block kind attribute stamped correctly

    @Test @MainActor
    func headingBlockKindStamped() {
        let parsed = MarkdownBridge.parse(markdown: "# Test")
        guard parsed.length > 0 else {
            Issue.record("Parsed heading is empty")
            return
        }
        let kind = parsed.attribute(.noteBlockKind, at: 0, effectiveRange: nil) as? BlockKind
        if case .heading(1) = kind {
            // pass
        } else {
            Issue.record("Expected .heading(1), got \(String(describing: kind))")
        }
    }

    @Test @MainActor
    func inlineCodeKindStamped() {
        let parsed = MarkdownBridge.parse(markdown: "Use `code` here")
        let text = parsed.string
        guard let codeStart = text.range(of: "code") else {
            Issue.record("Could not find 'code' in parsed output")
            return
        }
        let nsRange = NSRange(codeStart, in: text)
        let isCode = parsed.attribute(.noteInlineCode, at: nsRange.location, effectiveRange: nil) as? Bool
        #expect(isCode == true, "Inline code should be stamped with .noteInlineCode")
    }

    // MARK: - Text never dropped (the critical invariant)

    @Test @MainActor
    func textNeverDroppedOnRoundTrip() {
        let complexMd = """
        # Main Title

        First paragraph with **bold**, *italic*, and `code`.

        ## Subtitle

        - List A
        - List B

        1. One
        2. Two

        > A quote with *emphasis*

        [A link](https://example.com)

        ```swift
        let x = 42
        ```

        Final paragraph.
        """

        let parsed = MarkdownBridge.parse(markdown: complexMd)
        let serialized = MarkdownBridge.serialize(parsed)

        // Every text fragment must survive
        let mustContain = [
            "Main Title", "First paragraph", "bold", "italic", "code",
            "Subtitle", "List A", "List B", "One", "Two",
            "A quote", "emphasis", "A link", "example.com",
            "let x = 42", "Final paragraph"
        ]

        for fragment in mustContain {
            #expect(serialized.contains(fragment),
                    "Text fragment '\(fragment)' must survive round-trip")
        }
    }

    // MARK: - W8-S1: attributed-side structural idempotency

    /// For a table of canonical Markdown inputs: `attributed → md → attributed'` preserves the
    /// *rendered* attributes (bold/italic/inline-code/block-kind/link) character-for-character.
    /// The existing `secondRoundTripIsNoOp` covers the string side (`md → attributed → md'`); this
    /// pins the attributed side so a serializer drift that changes styling can't slip through.
    @Test @MainActor
    func attributedIdempotentForSupportedSubset() {
        let canonical = [
            "# Heading One",
            "Some **bold** text",
            "Some *italic* text",
            "Some ***bold italic*** text",
            "Use `code` here",
            "[Click here](https://example.com)",
            "> A quoted line",
        ]
        for md in canonical {
            let a1 = MarkdownBridge.parse(markdown: md)
            let md1 = MarkdownBridge.serialize(a1)
            let a2 = MarkdownBridge.parse(markdown: md1)
            #expect(renderedFingerprint(a1) == renderedFingerprint(a2),
                    "attributed→md→attributed not stable for: \(md)")
        }
    }

    /// An unsupported attribute (underline) applied to a run in the MIDDLE of a paragraph is dropped
    /// on serialize without mangling the adjacent text or injecting stray Markdown markers.
    @Test @MainActor
    func unsupportedAttributeMidParagraphDegradesWithoutManglingAdjacent() {
        let font = NSFont.systemFont(ofSize: 14)
        let result = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: font, .noteBlockKind: BlockKind.plain]
        result.append(NSAttributedString(string: "Start ", attributes: base))
        var mid = base
        mid[.underlineStyle] = NSUnderlineStyle.single.rawValue   // unsupported
        result.append(NSAttributedString(string: "middle", attributes: mid))
        result.append(NSAttributedString(string: " end", attributes: base))

        let serialized = MarkdownBridge.serialize(result)
        #expect(serialized == "Start middle end")
    }

    /// Inline images round-trip through the bridge as a RELATIVE `assets/…` reference (never
    /// rewritten to an absolute or `file://` path).
    @Test @MainActor
    func imageReferenceStaysRelativeThroughBridge() {
        let md = "Before ![cap](assets/pic.png) after"
        let serialized = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: md))
        #expect(serialized.contains("](assets/pic.png)"))
        #expect(!serialized.contains("](/"))
        #expect(!serialized.contains("file://"))
    }

    // MARK: - Helpers

    /// A per-character fingerprint of the rendered (not semantic) attributes we model, for
    /// structural-idempotency comparison of two attributed strings.
    @MainActor
    private func renderedFingerprint(_ s: NSAttributedString) -> [String] {
        var out: [String] = []
        let ns = s.string as NSString
        for i in 0..<s.length {
            let ch = ns.substring(with: NSRange(location: i, length: 1))
            let attrs = s.attributes(at: i, effectiveRange: nil)
            let traits = (attrs[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            let bold = traits.contains(.boldFontMask)
            let italic = traits.contains(.italicFontMask)
            let code = (attrs[.noteInlineCode] as? Bool) == true
            let kind = (attrs[.noteBlockKind] as? BlockKind) ?? .plain
            let link = attrs[.link] != nil
            out.append("\(ch)|b\(bold)|i\(italic)|c\(code)|k\(kind)|l\(link)")
        }
        return out
    }

    /// Assert that parse→serialize produces the expected normalized form,
    /// and that a second round-trip is identical (fixed-point after one pass).
    @MainActor
    private func assertNormalized(_ input: String, expected: String) {
        let parsed = MarkdownBridge.parse(markdown: input)
        let serialized = MarkdownBridge.serialize(parsed)
        let trimmed = serialized.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedTrimmed = expected.trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(trimmed == expectedTrimmed,
                "Normalized output mismatch.\n  Input: \(input)\n  Got:   \(trimmed)\n  Want:  \(expectedTrimmed)")

        // Second round-trip must be a no-op
        let secondParse = MarkdownBridge.parse(markdown: serialized)
        let secondSerialize = MarkdownBridge.serialize(secondParse)
        #expect(serialized == secondSerialize,
                "Second round-trip should be no-op for: \(input)")
    }
}
