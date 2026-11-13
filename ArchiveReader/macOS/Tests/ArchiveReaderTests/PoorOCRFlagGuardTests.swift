import XCTest
@testable import ArchiveReader
import ArchiveCore

/// W44.reocr-reader: every Reader tag write that names `OCR Poor` runs under the shared flag protocol
/// (`SPEC/improve-ocr.md` §3). Scratch roots and a scratch support folder only — never the corpus, never the
/// person's connection (the unit host's `ImproveOCRSupport.shared` uses its own defaults suite).
final class PoorOCRFlagGuardTests: XCTestCase {
    private var dir: URL!
    private var root: URL!
    private var support: URL!
    private var savedLedgerURL: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PoorOCRGuard-\(UUID().uuidString)")
        root = dir.appendingPathComponent("Archive", isDirectory: true)
        support = dir.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Box 1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        _ = try RootMarker.ensure(at: root, kind: .reader, name: "Archive")
        savedLedgerURL = AuditLedger.shared.fileURL
        AuditLedger.shared.fileURL = dir.appendingPathComponent("ledger/audit-ledger.jsonl")
        ImproveOCRSupport.shared.disconnect()
        ImproveOCRArchive.shared.rootURL = root
    }

    override func tearDownWithError() throws {
        ImproveOCRSupport.shared.disconnect()
        ImproveOCRArchive.shared.rootURL = nil
        AuditLedger.shared.fileURL = savedLedgerURL
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeFile(_ name: String, tags: [String]) throws -> URL {
        let url = root.appendingPathComponent("Box 1").appendingPathComponent(name)
        try Data("PDF-\(UUID().uuidString)".utf8).write(to: url)
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        return url
    }

    private func tags(_ url: URL) throws -> [String] {
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    private func key(_ url: URL) throws -> ImproveOCRFlagStore.FileKey {
        let guid = try XCTUnwrap(try RootMarker.read(at: root)).guid
        return try ImproveOCRFlagStore.FileKey(rootGUID: guid, root: root, file: url)
    }

    private func state(_ url: URL) throws -> ImproveOCRFlagStore.State? {
        try ImproveOCRFlagStore(support: support).peek(key(url))
    }

    func testRequestedValueFollowsTheDelta() {
        XCTAssertEqual(PoorOCRFlagGuard.requested(add: ["ocr poor"], remove: []), true)
        XCTAssertEqual(PoorOCRFlagGuard.requested(add: [], remove: ["OCR Poor"]), false)
        XCTAssertEqual(PoorOCRFlagGuard.requested(add: ["OCR Poor"], remove: ["OCR Poor"]), true)
        XCTAssertNil(PoorOCRFlagGuard.requested(add: ["OCR Poorly", "OCR Failed"], remove: ["Poor"]))
    }

    func testFlagAndUnflagAdvanceTheGenerationAndAreLedgered() throws {
        try ImproveOCRSupport.shared.connect(support)
        let url = try makeFile("a.pdf", tags: ["Unread", "OCR Failed", "Lincoln"])
        let bytes = try Data(contentsOf: url)

        let flagged = try TagWriter.apply(TagDelta(add: [DocumentTags.poorOCRTag]), to: url)
        let first = try XCTUnwrap(try state(url))
        XCTAssertEqual(first.flagged, true)
        XCTAssertEqual(first.lastOrigin, .flag)
        XCTAssertFalse(first.isPending)
        XCTAssertTrue(multisetEqual(try tags(url), ["Unread", "OCR Failed", "Lincoln", "OCR Poor"]))

        let line = try XCTUnwrap(AuditLedger.shared.allEntries().last { $0.op == .apply })
        let record = try XCTUnwrap(line.flag)
        XCTAssertEqual(record.relativePath, "Box 1/a.pdf")
        XCTAssertEqual(record.generationAfter, first.generation)
        XCTAssertNil(record.generationBefore)
        XCTAssertTrue(record.observed)

        // Flagging a flagged file still advances the generation: an acceptance must see the person's new verdict.
        let again = try TagWriter.apply(TagDelta(add: [DocumentTags.poorOCRTag]), to: url)
        XCTAssertTrue(again.isNoOp)
        let second = try XCTUnwrap(try state(url))
        XCTAssertNotEqual(second.generation, first.generation)

        // Undo is a write that names the tag too: it goes through the protocol as an unflag.
        _ = try TagWriter.applyOccurrence(flagged.occurrenceInverse, to: url, undoing: .init(flagged))
        let third = try XCTUnwrap(try state(url))
        XCTAssertEqual(third.flagged, false)
        XCTAssertEqual(third.lastOrigin, .unflag)
        XCTAssertNotEqual(third.generation, second.generation)
        XCTAssertTrue(multisetEqual(try tags(url), ["Unread", "OCR Failed", "Lincoln"]), "OCR Failed is not the flag")
        XCTAssertEqual(try Data(contentsOf: url), bytes, "the file's bytes never change")
    }

    func testAWriteThatDoesNotNameTheTagKeepsNoRecord() throws {
        try ImproveOCRSupport.shared.connect(support)
        let url = try makeFile("b.pdf", tags: ["OCR Poor"])
        _ = try TagWriter.apply(TagDelta(add: ["Lincoln"]), to: url)
        _ = try TagWriter.setReadState(.read, on: url, addIfMissing: true)
        XCTAssertNil(try state(url))
        XCTAssertNil(AuditLedger.shared.allEntries().last { $0.op == .apply }?.flag)
    }

    func testRenameIntoTheTagIsRecorded() throws {
        try ImproveOCRSupport.shared.connect(support)
        let url = try makeFile("c.pdf", tags: ["Poor scan"])
        _ = try TagWriter.renameToken(from: "Poor scan", to: DocumentTags.poorOCRTag, on: url)
        XCTAssertEqual(try state(url)?.flagged, true)
    }

    func testNeverConnectedWritesAsBefore() throws {
        let url = try makeFile("d.pdf", tags: [])
        _ = try TagWriter.apply(TagDelta(add: [DocumentTags.poorOCRTag]), to: url)
        XCTAssertEqual(try tags(url), ["OCR Poor"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Flags").path))
    }

    func testAFolderThatCannotBeUsedRefusesWithoutWriting() throws {
        try ImproveOCRSupport.shared.connect(support)
        let url = try makeFile("e.pdf", tags: ["Lincoln"])
        // The connected folder is replaced by a different store: refuse, never start a second record.
        try FileManager.default.removeItem(at: support.appendingPathComponent(ImproveOCRSupportIdentity.file))
        _ = try ImproveOCRSupportIdentity.identity(of: support, create: true)
        XCTAssertThrowsError(try TagWriter.apply(TagDelta(add: [DocumentTags.poorOCRTag]), to: url)) {
            XCTAssertTrue($0 is PoorOCRFlagGuard.Refusal)
        }
        XCTAssertEqual(try tags(url), ["Lincoln"])
        // Unrelated edits are unaffected.
        _ = try TagWriter.apply(TagDelta(add: ["Brown"]), to: url)
        XCTAssertTrue(multisetEqual(try tags(url), ["Lincoln", "Brown"]))
    }

    func testAnArchiveWithoutAnIdentityRefuses() throws {
        try ImproveOCRSupport.shared.connect(support)
        let url = try makeFile("f.pdf", tags: [])
        try FileManager.default.removeItem(at: root.appendingPathComponent(RootMarker.filename))
        XCTAssertThrowsError(try TagWriter.apply(TagDelta(add: [DocumentTags.poorOCRTag]), to: url)) {
            XCTAssertEqual($0 as? PoorOCRFlagGuard.Refusal, .noArchiveIdentity)
        }
        XCTAssertEqual(try tags(url), [])
    }

    func testAnUnfinishedActionIsReconciledBeforeTheNextOne() throws {
        try ImproveOCRSupport.shared.connect(support)
        let url = try makeFile("g.pdf", tags: ["OCR Poor"])
        // Another app began a clear and died before changing the tag.
        let store = ImproveOCRFlagStore(support: support)
        _ = try store.withLock(try key(url), app: "Archive Processor") { try $0.begin(flagged: false, origin: .acceptedClear) }
        XCTAssertEqual(try state(url)?.isPending, true)

        _ = try TagWriter.apply(TagDelta(remove: [DocumentTags.poorOCRTag]), to: url)
        let now = try XCTUnwrap(try state(url))
        XCTAssertFalse(now.isPending)
        XCTAssertEqual(now.flagged, false)
        XCTAssertEqual(now.lastOrigin, .unflag)
        XCTAssertEqual(try tags(url), [])
    }

    func testAFailedWriteLeavesNoBarrier() throws {
        try ImproveOCRSupport.shared.connect(support)
        let url = try makeFile("h.pdf", tags: [])
        let other = try makeFile("other.pdf", tags: [])
        let wrongIdentity = try XCTUnwrap(FileIdentity.capture(other))
        XCTAssertThrowsError(try TagWriter.apply(TagDelta(add: [DocumentTags.poorOCRTag]), to: url, expecting: wrongIdentity))
        let now = try XCTUnwrap(try state(url))
        XCTAssertFalse(now.isPending)
        XCTAssertEqual(now.flagged, false)
        XCTAssertEqual(now.lastOrigin, .reconciled)
        XCTAssertEqual(try tags(url), [])
    }

    // MARK: The filter

    func testPoorOCRFilterChipAndSmartFolderRule() {
        var f = LibraryFilter()
        XCTAssertFalse(f.isActive)
        f.poorOCROnly = true
        XCTAssertTrue(f.isActive)
        let chips = ActiveFilterChip.chips(filter: f, smartFolderName: nil, fullTextQuery: nil)
        XCTAssertEqual(chips.map(\.accessibilityIdentifier), ["ar.filter.poorOCR"])
        XCTAssertFalse(f.removing(.poorOCR).poorOCROnly)
        let rules = AdvancedSearch(filter: f, fullTextQuery: "").rules
        XCTAssertEqual(rules.map(\.field), [.tags])
        XCTAssertEqual(rules.first?.tags, [DocumentTags.poorOCRTag])
    }
}
