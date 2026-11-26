import Testing
import AppKit
import PDFKit
@testable import ArchiveNotes

/// W49.notes-export-print — File ▸ Export… and Print…. Every write goes to a scratch folder under the test host's
/// temporary directory; the "library" here is a scratch store made by the test.
@Suite("NoteExportTests — W49.notes-export-print")
@MainActor
struct NoteExportTests {

    private static let png: Data = {
        let image = NSImage(size: NSSize(width: 40, height: 20))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 20).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }()

    private final class Scratch {
        let root: URL
        let store: URL
        let out: URL
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("notes-export-\(UUID().uuidString)", isDirectory: true)
            store = root.appendingPathComponent("Library.archivenotes", isDirectory: true)
            out = root.appendingPathComponent("Exported", isDirectory: true)
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        /// An item folder in the scratch store, with `assets` written into its `assets/`.
        func itemDir(_ id: UUID, assets: [String: Data] = [:]) throws -> URL {
            let dir = NoteStore.itemDir(root: store, id: id)
            let assetsDir = dir.appendingPathComponent("assets", isDirectory: true)
            try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
            for (name, data) in assets { try data.write(to: assetsDir.appendingPathComponent(name)) }
            return dir
        }

        func names(_ folder: URL? = nil) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: (folder ?? out).path)) ?? []).sorted()
        }
    }

    private func item(_ title: String, tags: [String] = [], leading: String? = nil, blocks: [Block] = [],
                      id: UUID = UUID()) -> Item {
        Item(id: id, kind: .note, title: title, date: "1958-03-12", datePrecision: .day, dateUncertain: false,
             quality: nil, tags: tags, zotero: [], roundup: false, created: Date(), modified: Date(), schema: 1,
             blocks: blocks, unknownFrontMatter: [], trailingBodyRaw: leading)
    }

    private func source(_ item: Item, in scratch: Scratch, assets: [String: Data] = [:]) throws -> NoteExportSource {
        NoteExportSource(item: item, itemDirectory: try scratch.itemDir(item.id, assets: assets), dateText: "Mar 12, 1958")
    }

    private func readerBlock(_ text: String) -> Block {
        Block(kind: .readerPage,
              source: SourceAnchor(link: "archivereader://open?guid=abc&path=Box%201/letter.pdf",
                                   display: "Box 1 · letter.pdf", page: 2, thumbRef: nil, zoteroSelect: nil, noteRef: nil),
              markdown: text, unknownHeaderFields: [])
    }

    // MARK: - The Markdown every format starts from

    @Test func composedMarkdownCarriesTheNoteAndItsSourcesWithoutBlockHeaders() {
        let note = item("Letter to *Ike*", tags: ["Budget", "1958"], leading: "Opening prose.\n\n- one\n- two\n",
                        blocks: [readerBlock("Quoted **passage** from the page.\n")])
        let md = NoteExportComposer.markdown(NoteExportSource(item: note, itemDirectory: URL(fileURLWithPath: "/x"),
                                                              dateText: "Mar 12, 1958"))
        #expect(md.hasPrefix("# Letter to \\*Ike\\*\n"), "the title is a heading, its asterisks literal: \(md)")
        #expect(md.contains("Date: Mar 12, 1958"))
        #expect(md.contains("Tags: Budget, 1958"))
        #expect(md.contains("Opening prose.\n\n- one\n- two"), "the leading prose is copied verbatim")
        #expect(md.contains("> Source: Box 1 · letter.pdf, p. 2"), "each block names its source: \(md)")
        #expect(md.contains("archivereader://open?guid=abc"), "the source's link is kept")
        #expect(md.contains("Quoted **passage** from the page."), "block text is copied verbatim")
        #expect(!md.contains("<!--"), "no block header, which other readers hide and Word shows raw")
    }

    @Test func fileNamesAreSafe() {
        #expect(NoteExportComposer.fileName(for: "a/b:c") == "a-b-c")
        #expect(NoteExportComposer.fileName(for: "..hidden") == "hidden")
        #expect(NoteExportComposer.fileName(for: "   ") == "Untitled")
        #expect(NoteExportComposer.fileName(for: String(repeating: "x", count: 300)).count == 120)
    }

    // MARK: - Writing

    @Test func markdownWithoutImagesIsOneFile() throws {
        let scratch = try Scratch()
        let written = try NoteExportWriter.export([try source(item("Plain", leading: "Body text."), in: scratch)],
                                                  as: .markdown, into: scratch.out, storeRoot: scratch.store, archiveRoots: [])
        #expect(written.map(\.lastPathComponent) == ["Plain.md"])
        #expect(try String(contentsOf: written[0], encoding: .utf8).contains("Body text."))
    }

    @Test func markdownWithImagesIsAFolderWhoseLinksStillWork() throws {
        let scratch = try Scratch()
        let note = item("Pictured", leading: "Before ![A red box](assets/red.png) after.\n\n![gone](assets/missing.png)")
        let written = try NoteExportWriter.export([try source(note, in: scratch, assets: ["red.png": Self.png])],
                                                  as: .markdown, into: scratch.out, storeRoot: scratch.store, archiveRoots: [])
        #expect(written.map(\.lastPathComponent) == ["Pictured"])
        let folder = written[0]
        #expect(scratch.names(folder) == ["Pictured.md", "assets"])
        #expect(scratch.names(folder.appendingPathComponent("assets")) == ["red.png"], "only the image that exists")
        #expect(try Data(contentsOf: folder.appendingPathComponent("assets/red.png")) == Self.png)
        let md = try String(contentsOf: folder.appendingPathComponent("Pictured.md"), encoding: .utf8)
        #expect(md.contains("![A red box](assets/red.png)"), "the link is unchanged and resolves beside the file")
    }

    /// The read seam's two gates hold for Export: a `..` reference and a symlink out of `assets/` are never copied.
    @Test func markdownNeverCopiesAnImageFromOutsideTheItem() throws {
        let scratch = try Scratch()
        let other = try scratch.itemDir(UUID(), assets: ["secret.png": Self.png])
        let note = item("Escape")
        let dir = try scratch.itemDir(note.id)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("assets/link.png"),
                                                   withDestinationURL: other.appendingPathComponent("assets/secret.png"))
        let otherID = other.lastPathComponent
        var escaping = note
        escaping.trailingBodyRaw = "![a](../\(otherID)/assets/secret.png) ![b](assets/link.png) ![c](/etc/hosts)"
        let written = try NoteExportWriter.export(
            [NoteExportSource(item: escaping, itemDirectory: dir, dateText: nil)],
            as: .markdown, into: scratch.out, storeRoot: scratch.store, archiveRoots: [])
        #expect(written.map(\.lastPathComponent) == ["Escape.md"], "no image was the item's own, so no folder")
        #expect(scratch.names() == ["Escape.md"])
    }

    @Test func nothingAlreadyThereIsReplaced() throws {
        let scratch = try Scratch()
        let existing = scratch.out.appendingPathComponent("Same.txt")
        try Data("the user's own file".utf8).write(to: existing)
        try FileManager.default.createDirectory(at: scratch.out.appendingPathComponent("Pictured"),
                                                withIntermediateDirectories: false)
        let sources = [try source(item("Same", leading: "first"), in: scratch),
                       try source(item("Same", leading: "second"), in: scratch)]
        let written = try NoteExportWriter.export(sources, as: .plainText, into: scratch.out,
                                                  storeRoot: scratch.store, archiveRoots: [])
        #expect(written.map(\.lastPathComponent) == ["Same 2.txt", "Same 3.txt"])
        #expect(try String(contentsOf: existing, encoding: .utf8) == "the user's own file")
        #expect(try String(contentsOf: written[0], encoding: .utf8).contains("first"))
        #expect(try String(contentsOf: written[1], encoding: .utf8).contains("second"))

        let pictured = item("Pictured", leading: "![x](assets/red.png)")
        let folder = try NoteExportWriter.export([try source(pictured, in: scratch, assets: ["red.png": Self.png])],
                                                 as: .markdown, into: scratch.out, storeRoot: scratch.store, archiveRoots: [])
        #expect(folder.map(\.lastPathComponent) == ["Pictured 2"], "an existing folder is not written into")
        #expect(scratch.names(scratch.out.appendingPathComponent("Pictured")).isEmpty)
    }

    @Test func refusesTheLibraryAndArchiveFolders() throws {
        let scratch = try Scratch()
        let archive = scratch.root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive.appendingPathComponent("Box 1"), withIntermediateDirectories: true)
        let alias = scratch.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: scratch.store)
        let sources = [try source(item("Note"), in: scratch)]
        for folder in [scratch.store, scratch.store.appendingPathComponent("items"), alias,
                       archive, archive.appendingPathComponent("Box 1")] {
            #expect(throws: NoteExportWriter.ExportError.self, "\(folder.path) must be refused") {
                try NoteExportWriter.export(sources, as: .plainText, into: folder,
                                            storeRoot: scratch.store, archiveRoots: [archive])
            }
        }
        #expect(!FileManager.default.fileExists(atPath: archive.appendingPathComponent("Note.txt").path))
        #expect(NoteExportDestination.refusal(for: scratch.out, storeRoot: scratch.store, archiveRoots: [archive]) == nil)
        // A sibling whose name only starts like the library's is not inside it.
        let sibling = scratch.root.appendingPathComponent("Library.archivenotes copy")
        #expect(NoteExportDestination.refusal(for: sibling, storeRoot: scratch.store, archiveRoots: [archive]) == nil)
    }

    // MARK: - The formats

    @Test func plainTextRichTextAndWordKeepTheTextAndMarkTheImages() throws {
        let scratch = try Scratch()
        let note = item("Formats", leading: "A **bold** claim. ![Map of Europe](assets/red.png)",
                        blocks: [readerBlock("From the page.")])
        let src = try source(note, in: scratch, assets: ["red.png": Self.png])
        for format in [NoteExportFormat.plainText, .richText, .word] {
            let url = try #require(try NoteExportWriter.export([src], as: format, into: scratch.out,
                                                               storeRoot: scratch.store, archiveRoots: []).first)
            #expect(url.pathExtension == format.fileExtension)
            let text: String
            switch format {
            case .plainText: text = try String(contentsOf: url, encoding: .utf8)
            default:
                let type: NSAttributedString.DocumentType = format == .word ? .officeOpenXML : .rtf
                text = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
            }
            for expected in ["Formats", "A bold claim.", "[Image: Map of Europe]", "Source: Box 1 · letter.pdf, p. 2",
                             "From the page.", "Mar 12, 1958"] {
                #expect(text.contains(expected), "\(format) should contain “\(expected)”: \(text)")
            }
            #expect(!text.contains("**"), "\(format) is styled text, not Markdown")
        }
    }

    @Test func pdfIsPaginatedAndCarriesTheText() throws {
        let scratch = try Scratch()
        let long = (1...200).map { "Paragraph \($0) of a long note." }.joined(separator: "\n\n")
        let src = try source(item("Long Note", leading: long + "\n\n![box](assets/red.png)"), in: scratch,
                             assets: ["red.png": Self.png])
        let url = try #require(try NoteExportWriter.export([src], as: .pdf, into: scratch.out,
                                                           storeRoot: scratch.store, archiveRoots: []).first)
        let pdf = try #require(PDFDocument(url: url))
        #expect(pdf.pageCount > 1, "200 paragraphs need more than one page, got \(pdf.pageCount)")
        let text = pdf.string ?? ""
        #expect(text.contains("Long Note"))
        #expect(text.contains("Paragraph 1 of"))
        #expect(text.contains("Paragraph 200 of"), "nothing is cut off the last page")
        #expect(!text.contains("[Image"), "the PDF draws the image instead of naming it")
    }

    /// Review findings (W49.notes-export-print): list markers, a header-shaped line and a link's address survive.
    @Test func listsHeaderShapedLinesAndLinksSurviveTheTextFormats() throws {
        let scratch = try Scratch()
        let body = "1. Box 4\n2. Box 7\n\n- loose\n\n<!-- block: reader-page -->\n\nSee [the finding aid](https://example.org/aid)."
        let src = try source(item("Lists", leading: body), in: scratch)
        let plain = NoteExportRenderer.plainText([src])
        #expect(plain.contains("1. Box 4"), "numbers are kept: \(plain)")
        #expect(plain.contains("2. Box 7"), "numbers are kept: \(plain)")
        #expect(plain.contains("• loose"), "bullets are kept: \(plain)")
        #expect(plain.contains("<!-- block: reader-page -->"), "a typed header-shaped line stays text: \(plain)")
        #expect(plain.contains("the finding aid (https://example.org/aid)"), "plain text keeps the address: \(plain)")
        let md = NoteExportComposer.markdown(src)
        #expect(md.contains("\\<!-- block: reader-page -->"), "the Markdown export escapes it as the file does: \(md)")
        let url = try #require(try NoteExportWriter.export([src], as: .word, into: scratch.out,
                                                           storeRoot: scratch.store, archiveRoots: []).first)
        let word = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                          documentAttributes: nil).string
        #expect(word.contains("2. Box 7") && word.contains("<!-- block: reader-page -->"), "\(word)")
    }

    @Test func twoSpellingsOfOneImageAreCopiedOnce() throws {
        let scratch = try Scratch()
        let note = item("Twice", leading: "![a](assets/red.png) ![b](assets/./red.png)")
        let written = try NoteExportWriter.export([try source(note, in: scratch, assets: ["red.png": Self.png])],
                                                  as: .markdown, into: scratch.out, storeRoot: scratch.store, archiveRoots: [])
        #expect(scratch.names(written[0].appendingPathComponent("assets")) == ["red.png"])
    }

    @Test func refusesAFolderUnderASuiteRootMarker() throws {
        let scratch = try Scratch()
        let corpus = scratch.root.appendingPathComponent("Ungranted Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: corpus.appendingPathComponent("Box 2"), withIntermediateDirectories: true)
        try Data(#"{"guid":"c07b0700-2000-4000-8000-000000000009","name":"x","kind":"reader","createdAt":"2026-01-01T00:00:00Z"}"#.utf8)
            .write(to: corpus.appendingPathComponent(".archive-suite-root.json"))
        #expect(NoteExportDestination.refusal(for: corpus.appendingPathComponent("Box 2"), storeRoot: nil,
                                              archiveRoots: []) != nil, "a marked archive is refused though never granted")
        #expect(NoteExportDestination.refusal(for: scratch.out, storeRoot: nil, archiveRoots: []) == nil)
    }

    @Test func severalItemsPrintTogetherWithNothingLost() throws {
        let scratch = try Scratch()
        let a = try source(item("Alpha Note", leading: "First body."), in: scratch)
        let b = try source(item("Beta Note", leading: "Second body."), in: scratch)
        let pdf = try #require(PDFDocument(data: try NoteExportRenderer.pdfData([a, b])))
        let text = pdf.string ?? ""
        for needle in ["Alpha Note", "First body.", "Beta Note", "Second body."] {
            #expect(text.contains(needle), "the combined print should hold “\(needle)”: \(text)")
        }
        #expect(pdf.pageCount == 2, "each item starts on its own page, got \(pdf.pageCount)")
    }

    @Test func darkModeColoursPrintDark() throws {
        let text = NSMutableAttributedString(string: "ink", attributes: [.foregroundColor: NSColor.labelColor])
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            NoteExportRenderer.resolveColorsForPaper(text)
        }
        let color = try #require(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let rgb = try #require(color.usingColorSpace(.sRGB))
        #expect(rgb.brightnessComponent < 0.3, "label text must print dark on paper, got \(rgb)")
    }

    // MARK: - The model's read

    @Test func exportSourcesReadsTheStoredItemsInOrder() async throws {
        let scratch = try Scratch()
        let index = NotesIndex(url: scratch.root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: scratch.store)
        let store = NoteStore(root: scratch.store)
        let model = NotesModel(organization: org, index: index, noteStore: store)
        let first = item("First", leading: "one"), second = item("Second", leading: "two")
        _ = try await store.create(first)
        _ = try await store.create(second)
        let missing = UUID()
        let (sources, failed) = await model.exportSources(for: [second.id, missing, first.id])
        #expect(sources.map(\.item.title) == ["Second", "First"])
        #expect(sources[0].itemDirectory == NoteStore.itemDir(root: scratch.store, id: second.id))
        #expect(failed == [missing.uuidString])
        #expect(model.storeRootURL == scratch.store)
        await index.close()
    }
}
