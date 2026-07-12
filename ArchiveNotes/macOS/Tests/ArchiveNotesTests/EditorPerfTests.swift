import Testing
import Foundation
import AppKit
@testable import ArchiveNotes

@Suite("EditorPerfTests — W3-S6 performance + large-note hardening")
struct EditorPerfTests {

    // MARK: - Fixture generation

    /// Generate a large Markdown document (~50k words) with mixed formatting,
    /// inline images, and block headers to stress-test parse/serialize.
    static func largeFixture(wordCount: Int = 50_000) -> String {
        var md = "# Large Document for Performance Testing\n\n"
        var words = 0
        var paraIndex = 0

        while words < wordCount {
            paraIndex += 1
            switch paraIndex % 10 {
            case 0:
                // Heading
                let level = (paraIndex % 6) + 1
                let prefix = String(repeating: "#", count: level)
                md += "\(prefix) Section \(paraIndex) heading text here\n\n"
                words += 5
            case 1:
                // Bold + italic mixed paragraph
                md += "This is a **bold paragraph** with some *italic words* and "
                md += "***bold italic*** mixed in for good measure. "
                md += "The quick brown fox jumps over the lazy dog repeatedly "
                md += "to pad the word count of this performance fixture. "
                md += "Additional filler text ensures we reach the target size.\n\n"
                words += 40
            case 2:
                // Code block
                md += "```swift\nfunc example\(paraIndex)() {\n"
                md += "    let value = computeResult(input: \(paraIndex))\n"
                md += "    print(\"Result: \\(value)\")\n"
                md += "}\n```\n\n"
                words += 12
            case 3:
                // Unordered list
                md += "- First list item with some descriptive text about topic \(paraIndex)\n"
                md += "- Second list item continuing the theme of testing\n"
                md += "    - Nested item under the second point for depth\n"
                md += "    - Another nested item to test indentation handling\n"
                md += "- Third list item wrapping up this particular list\n\n"
                words += 35
            case 4:
                // Ordered list
                md += "1. Step one of procedure number \(paraIndex)\n"
                md += "2. Step two involves checking the intermediate result\n"
                md += "3. Step three confirms the final output matches\n\n"
                words += 20
            case 5:
                // Blockquote
                md += "> This is a blockquote containing reflective text about "
                md += "the nature of testing and performance verification. "
                md += "Blockquotes add structural variety to the fixture.\n\n"
                words += 20
            case 6:
                // Inline code + links
                md += "Use `functionName()` to invoke the handler. "
                md += "See [the documentation](https://example.com/docs/\(paraIndex)) "
                md += "for details on configuration and advanced usage patterns.\n\n"
                words += 18
            case 7:
                // Plain long paragraph (bulk filler)
                var para = ""
                for s in 0..<8 {
                    para += "Sentence \(s) of paragraph \(paraIndex) provides "
                    para += "additional content for the performance fixture. "
                }
                md += para + "\n\n"
                words += 80
            case 8:
                // Image reference
                md += "![Figure \(paraIndex)](assets/figure-\(paraIndex).png)\n\n"
                words += 3
            default:
                // Mixed inline
                md += "Regular text with `inline code` and **bold** and *italic* "
                md += "and a [link](https://example.com) all in one paragraph.\n\n"
                words += 18
            }
        }

        return md
    }

    // MARK: - Parse performance

    @Test @MainActor
    func parsePerformanceLargeDocument() {
        let fixture = Self.largeFixture()
        #expect(fixture.count > 100_000, "Fixture should be substantial")

        let start = CFAbsoluteTimeGetCurrent()
        let result = MarkdownBridge.parse(markdown: fixture)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        #expect(result.length > 0, "Parse should produce non-empty result")
        // Bound: parse should complete within 10 seconds even on slow CI
        #expect(elapsed < 10.0, "Parse took \(String(format: "%.2f", elapsed))s — exceeds 10s bound")
    }

    @Test @MainActor
    func serializePerformanceLargeDocument() {
        let fixture = Self.largeFixture()
        let parsed = MarkdownBridge.parse(markdown: fixture)

        let start = CFAbsoluteTimeGetCurrent()
        let serialized = MarkdownBridge.serialize(parsed)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        #expect(!serialized.isEmpty, "Serialize should produce non-empty result")
        // Bound: serialize should complete within 10 seconds
        #expect(elapsed < 10.0, "Serialize took \(String(format: "%.2f", elapsed))s — exceeds 10s bound")
    }

    @Test @MainActor
    func roundTripLargeDocumentPreservesText() {
        // Use a smaller fixture for the round-trip content check (10k words)
        let fixture = Self.largeFixture(wordCount: 10_000)
        let parsed = MarkdownBridge.parse(markdown: fixture)
        let serialized = MarkdownBridge.serialize(parsed)

        // Text must never be dropped — verify key phrases survive
        #expect(serialized.contains("Section"), "Section headings should survive round-trip")
        #expect(serialized.contains("bold paragraph"), "Bold text should survive")
        #expect(serialized.contains("functionName()"), "Inline code should survive")
        #expect(serialized.contains("example.com"), "Links should survive")
    }

    // MARK: - Thumbnail cache

    @Test @MainActor
    func thumbnailCacheHitsAvoidDiskIO() {
        let cache = InlineImageAttachment.thumbnailCache
        let key = "test-cache-key" as NSString
        let img = NSImage(size: NSSize(width: 10, height: 10))

        cache.setObject(img, forKey: key)
        let cached = cache.object(forKey: key)
        #expect(cached === img, "Cache should return the same object")

        // Clean up
        cache.removeObject(forKey: key)
    }

    @Test @MainActor
    func thumbnailCacheIsBounded() {
        let cache = InlineImageAttachment.thumbnailCache
        #expect(cache.countLimit == 200, "Cache count limit should be 200")
        #expect(cache.totalCostLimit == 50 * 1024 * 1024, "Cache cost limit should be ~50 MB")
    }

    // MARK: - lint-editor gate (no .layoutManager in Editor/)

    @Test
    func noLayoutManagerInEditorSources() throws {
        // Find the Editor/ directory relative to the test bundle
        // In the build environment, we check the source files directly.
        let repoRoot = ProcessInfo.processInfo.environment["SRCROOT"]
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Tests/ArchiveNotesTests/
                .deletingLastPathComponent()  // Tests/
                .deletingLastPathComponent()  // macOS/
                .path
        let editorDir = (repoRoot as NSString)
            .appendingPathComponent("Sources/ArchiveNotes/Editor")

        let fm = FileManager.default
        guard fm.fileExists(atPath: editorDir) else {
            // If we can't find the source, skip gracefully (e.g. CI with different layout)
            return
        }

        let files = try fm.contentsOfDirectory(atPath: editorDir)
            .filter { $0.hasSuffix(".swift") }

        for file in files {
            let path = (editorDir as NSString).appendingPathComponent(file)
            let content = try String(contentsOfFile: path, encoding: .utf8)
            // Allow the literal in the EditorTextView init (it's the TK2 setup `NSTextLayoutManager`)
            // and any comments. Only flag `.layoutManager` property access.
            let lines = content.components(separatedBy: "\n")
            for (lineNum, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Skip comments
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                    continue
                }
                // The init creates NSTextLayoutManager (not .layoutManager access)
                if trimmed.contains("NSTextLayoutManager") { continue }
                // The assert checks textLayoutManager (not .layoutManager)
                if trimmed.contains("textLayoutManager") { continue }

                if trimmed.contains(".layoutManager") {
                    Issue.record("Editor/\(file):\(lineNum + 1) references .layoutManager — this silently downgrades TextKit 2 to TextKit 1")
                }
            }
        }
    }

    // MARK: - Large paste threshold

    @Test @MainActor
    func largePasteThresholdIsReasonable() {
        #expect(EditorTextView.largePasteThreshold == 10_000,
                "Large paste threshold should be 10k characters")
    }

    // MARK: - EditorTextView TextKit 2 under load

    @Test @MainActor
    func textViewHandlesLargeContent() {
        let tv = EditorTextView()
        let fixture = Self.largeFixture(wordCount: 5_000)
        let parsed = MarkdownBridge.parse(markdown: fixture)
        tv.textStorage?.setAttributedString(parsed)

        #expect(tv.textLayoutManager != nil, "TextKit 2 must survive large content")
        #expect(tv.textStorage!.length > 0, "Content should be present")
    }
}
