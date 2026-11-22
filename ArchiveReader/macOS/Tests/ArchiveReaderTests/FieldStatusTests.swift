import XCTest
import SwiftUI
import ArchiveCore
import ArchiveCoreUI
@testable import ArchiveReader

/// W40.reader-field-status: the Inspector's checks. The rows a file shows, its page-2 fields read off a scratch PDF,
/// the `Checked <Field>` tags a date edit and "Mark checked" write (scratch `mktemp` files only; the audit ledger is
/// redirected away from the real one), and the section drawing, light and dark.
@MainActor
final class FieldStatusTests: XCTestCase {
    private var savedLedgerURL: URL!
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FieldStatusTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        savedLedgerURL = AuditLedger.shared.fileURL
        AuditLedger.shared.fileURL = scratch.appendingPathComponent("audit-ledger.jsonl")
    }

    override func tearDown() async throws {
        AuditLedger.shared.fileURL = savedLedgerURL
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    private static let page2 = """
        Extracted text.
        Gemini · gemini-3.7-flash · 7 November 2026
        Classification: Document Start
        Date evidence: image; page 1; "1958"; gave 1958
        Document kind: letter
        Recipient place: Boston, Massachusetts

        Dear Dean, the harbour report follows.
        """

    private func header() -> FieldStatusSection.HeaderFields {
        var h = FieldStatusSection.HeaderFields(headers: [])
        h.itemFields = PDFItemFields(documentKind: "letter", recipientPlace: "Boston, Massachusetts")
        h.dateEvidence = "image; page 1; top right; \"12 March 1958\"; gave 1958-03-12"
        return h
    }

    func testOneFileListsItsDatesThenItsItemFieldsWithTheirStates() {
        let tags = DocumentTags.parse(raw: ["1958", "3 March", "Day 12", "Checked Date", "Checked Recipient Place",
                                            "Harbours"], labelNumber: nil)
        let rows = FieldStatusList.rows(tags: tags, header: header())
        XCTAssertEqual(rows.map(\.field), [.date, .documentKind, .recipientPlace])
        XCTAssertEqual(rows.map(\.status.level), [.checked, .unchecked, .checked])
        XCTAssertEqual(rows[0].value, "Mar 12, 1958")
        XCTAssertEqual(rows[1].value, "letter")
        // Unchecked, the date is lower confidence and says it was read off the image.
        let unchecked = FieldStatusList.rows(tags: DocumentTags.parse(raw: ["1958", "3 March", "Day 12"], labelNumber: nil),
                                             header: header())
        XCTAssertEqual(unchecked[0].status.level, .lowerConfidence)
        XCTAssertTrue(unchecked[0].status.source.contains("image"))
        // No header yet (or no PDF): the dates alone.
        XCTAssertEqual(FieldStatusList.rows(tags: tags, header: nil).map(\.field), [.date])
        XCTAssertTrue(FieldStatusList.rows(tags: DocumentTags.parse(raw: ["Harbours"], labelNumber: nil),
                                           header: nil).isEmpty)
    }

    func testTheFieldsAreReadOffTheFilesPageTwo() throws {
        let url = scratch.appendingPathComponent("letter.pdf")
        try TestPDFBuilder.textPDFData(pages: ["(the page image)", Self.page2]).write(to: url)
        let before = try Data(contentsOf: url)
        let read = try XCTUnwrap(FieldStatusSection.HeaderFields.read(url, isDataless: false))
        XCTAssertEqual(read.itemFields.documentKind, "letter")
        XCTAssertEqual(read.itemFields.recipientPlace, "Boston, Massachusetts")
        XCTAssertEqual(read.dateEvidence?.hasPrefix("image;"), true)
        XCTAssertEqual(try Data(contentsOf: url), before, "reading never changes the file")
        XCTAssertEqual(FieldStatusSection.HeaderFields.read(url, isDataless: true)?.itemFields, PDFItemFields(),
                       "a placeholder is never opened (only the user's values beside it are read)")
        let jpeg = scratch.appendingPathComponent("marker.jpg")
        try Data("not a pdf".utf8).write(to: jpeg)
        XCTAssertNil(FieldStatusSection.HeaderFields.read(jpeg, isDataless: false))
    }

    func testMacFieldsReadFromPDFAndUseTheExistingChecks() throws {
        let url = scratch.appendingPathComponent("mac.pdf")
        let page = Self.page2.replacingOccurrences(of: "Document kind: letter", with: """
            Document kind (lower confidence): report
            Byline (lower confidence): Mary Jones
            Publication date (lower confidence): 1967-03
            """)
        try TestPDFBuilder.textPDFData(pages: ["(the page image)", page]).write(to: url)
        let read = try XCTUnwrap(FieldStatusSection.HeaderFields.read(url, isDataless: false))
        let tags = DocumentTags.parse(raw: ["Checked Byline"], labelNumber: nil)
        let rows = FieldStatusList.rows(tags: tags, header: read)
        XCTAssertEqual(rows.map(\.field), [.documentKind, .byline, .publicationDate, .recipientPlace])
        XCTAssertEqual(rows.map(\.value), ["report", "Mary Jones", "1967-03", "Boston, Massachusetts"])
        XCTAssertEqual(rows.map(\.status.level), [.lowerConfidence, .checked, .lowerConfidence, .unchecked])
        XCTAssertTrue(rows[0].status.detail.contains("76 owner-checked values"))
        XCTAssertTrue(rows[2].status.detail.contains("Qwen3.5 4B"))
    }

    func testADateEditAndMarkCheckedWriteOnlyTheCheckTags() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FieldStatusTests-root-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let box = root.appendingPathComponent("Box", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        let url = box.appendingPathComponent("letter.pdf")
        try Data("scratch PDF".utf8).write(to: url)
        // A read-state tag, which the library lists a file by.
        try (url as NSURL).setResourceValue(["Unread", "1958", "Harbours"], forKey: .tagNamesKey)
        let bytes = try Data(contentsOf: url)
        let model = fixtureNavigationModel(pinnedTo: root)
        let deadline = Date().addingTimeInterval(5)
        while model.library.files.isEmpty, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        let path = try XCTUnwrap(model.library.files.first?.path)

        model.applyEdit(.setDate(ArchiveDate(year: 1958, month: 3)!), paths: [path])
        XCTAssertEqual(try tagsOnDisk(url), ["Unread", "1958", "3 March", "Checked Date", "Harbours"].sorted())
        XCTAssertEqual(model.libraryFiles(atPaths: [path]).first?.tags.checkedFields, [.date])

        model.applyEdit(.setChecked(.recipientPlace, true), paths: [path])
        XCTAssertEqual(try tagsOnDisk(url), ["Unread", "1958", "3 March", "Checked Date", "Harbours", "Checked Recipient Place"].sorted())
        model.applyEdit(.setChecked(.date, false), paths: [path])
        XCTAssertEqual(try tagsOnDisk(url), ["Unread", "1958", "3 March", "Harbours", "Checked Recipient Place"].sorted())
        XCTAssertEqual(model.undoDepth, 3, "each edit is one undo step")
        // Undo puts the check back, and says it was a check, not a subject.
        model.undoLast()
        XCTAssertTrue(try tagsOnDisk(url).contains("Checked Date"))
        XCTAssertTrue(model.statusMessage.contains("Checks:"), model.statusMessage)
        XCTAssertFalse(model.statusMessage.contains("Subjects"), model.statusMessage)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "only Finder metadata was edited")
    }

    func testTheChecksDrawAtTheInspectorWidth() throws {
        let tags = DocumentTags.parse(raw: ["1958", "Checked Date", "Sent With 1957-03"], labelNumber: nil)
        var header = header()
        header.itemFields.lowerConfidence = [.documentKind]
        for scheme in [ColorScheme.light, .dark] {
            let view = NSHostingView(rootView: FieldStatusList(tags: tags, header: header, apply: { _ in })
                .padding().frame(width: 340).background(.background).environment(\.colorScheme, scheme))
            let png = try XCTUnwrap(RenderProbe.pngData(fromAppKitView: view, size: CGSize(width: 340, height: 300)))
            writeRenderArtifact(png, named: "field-status-\(scheme).png")
            assertRendersNonBlank(RenderProbe.cgImage(fromPNG: png), "field checks \(scheme)")
        }
    }

    /// Sorted: a date edit removes and re-adds the year, so the order on disk is not the point here.
    private func tagsOnDisk(_ url: URL) throws -> [String] {
        (try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []).sorted()
    }
}
