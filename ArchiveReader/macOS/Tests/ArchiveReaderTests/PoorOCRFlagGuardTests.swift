import CryptoKit
import XCTest
@testable import ArchiveReader
import ArchiveCore

private enum SHA256Hex {
    static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

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
        XCTAssertEqual(record.observed, true)
        XCTAssertTrue(record.finished)

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

    // MARK: Which archive a file belongs to

    func testTheNearestMarkerKeysTheFileAsTheProcessorDoes() throws {
        try ImproveOCRSupport.shared.connect(support)
        // A granted folder whose subfolder was granted, and marked, before (the common-parent upgrade).
        let inner = root.appendingPathComponent("Box 1")
        let innerMarker = try RootMarker.ensure(at: inner, kind: .reader, name: "Box 1")
        let url = try makeFile("n.pdf", tags: [])
        XCTAssertEqual(ImproveOCRArchive.shared.root(for: url), .root(.init(url: inner.standardizedFileURL.resolvingSymlinksInPath(), guid: innerMarker.guid)))
        _ = try TagWriter.apply(TagDelta(add: [DocumentTags.poorOCRTag]), to: url)
        let key = try ImproveOCRFlagStore.FileKey(rootGUID: innerMarker.guid, root: inner, file: url)
        XCTAssertEqual(key.relativePath, "n.pdf")
        XCTAssertEqual(try ImproveOCRFlagStore(support: support).peek(key)?.flagged, true)
    }

    func testAFileOutsideTheGrantedRootHasNoArchive() throws {
        let outside = dir.appendingPathComponent("elsewhere.pdf")
        try Data("x".utf8).write(to: outside)
        XCTAssertEqual(ImproveOCRArchive.shared.root(for: outside), .outside)
        ImproveOCRArchive.shared.rootURL = nil
        XCTAssertEqual(ImproveOCRArchive.shared.root(for: outside), .outside)
    }

    // MARK: The hand-off

    func testASmallSelectionTravelsInTheLink() throws {
        let a = try makeFile("a & b.pdf", tags: []), b = try makeFile("c.pdf", tags: [])
        let id = UUID()
        let link = try ImproveOCRHandoff.link(for: [a, b], archive: .shared, support: support, requestID: id)
        guard case let .inline(rid, guid, paths) = try ImproveOCRRequest(url: link) else { return XCTFail("\(link)") }
        XCTAssertEqual(rid, id)
        XCTAssertEqual(guid, try XCTUnwrap(try RootMarker.read(at: root)).guid)
        XCTAssertEqual(paths, ["Box 1/a & b.pdf", "Box 1/c.pdf"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent(ImproveOCRManifest.folder).path))
    }

    func testALargeSelectionIsStagedAsAPrivateManifest() throws {
        var files: [URL] = []
        for i in 0..<(ImproveOCRRequest.maxInlineFiles + 1) { files.append(try makeFile("p\(i).pdf", tags: [])) }
        let id = UUID()
        let link = try ImproveOCRHandoff.link(for: files, archive: .shared, support: support, requestID: id)
        XCTAssertEqual(try ImproveOCRRequest(url: link), .manifest(requestID: id))
        let staged = ImproveOCRManifest.url(for: id, in: support)
        XCTAssertEqual(staged.lastPathComponent, id.uuidString.lowercased() + ".json")
        let manifest = try ImproveOCRManifest.decode(try Data(contentsOf: staged), expecting: id, now: Date())
        XCTAssertEqual(manifest.entries.count, files.count)
        let first = try XCTUnwrap(manifest.entries.first)
        XCTAssertEqual(first.relativePath, "Box 1/p0.pdf")
        let bytes = try Data(contentsOf: files[0])
        XCTAssertEqual(first.byteCount, Int64(bytes.count))
        XCTAssertEqual(first.sha256, SHA256Hex.of(bytes))
        let attrs = try FileManager.default.attributesOfItem(atPath: staged.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: staged.deletingLastPathComponent().path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testTwoArchivesInOneSelectionAreRefused() throws {
        let inner = root.appendingPathComponent("Box 1")
        _ = try RootMarker.ensure(at: inner, kind: .reader, name: "Box 1")
        let a = try makeFile("a.pdf", tags: [])
        let top = root.appendingPathComponent("top.pdf")
        try Data("t".utf8).write(to: top)
        XCTAssertThrowsError(try ImproveOCRHandoff.link(for: [a, top], archive: .shared, support: support)) {
            XCTAssertEqual($0 as? ImproveOCRHandoff.Problem, .twoArchives)
        }
    }

    // MARK: Receipts

    private func receipt(_ path: String, guid: UUID? = nil) throws -> ImproveOCRReceipt {
        let g = try guid ?? XCTUnwrap(try RootMarker.read(at: root)).guid
        let data = try JSONSerialization.data(withJSONObject: [
            "operationID": UUID().uuidString, "rootGUID": g.uuidString, "relativePath": path, "textPages": [1],
            "beforeSHA256": String(repeating: "a", count: 64), "afterSHA256": String(repeating: "b", count: 64),
            "outcome": "published", "date": "2026-11-13T00:00:00Z"])
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(ImproveOCRReceipt.self, from: data)
    }

    func testAReceiptFindsTheLibraryRowEvenInAnotherUnicodeSpelling() throws {
        let decomposed = "Cafe\u{301}.pdf"          // as a walker may list it
        let url = try makeFile(decomposed, tags: [])
        let rows = [(path: url.path, nfc: url.path.precomposedStringWithCanonicalMapping)]
        let r = try receipt("Box 1/Caf\u{e9}.pdf")   // FileKey spells it as stored, NFC in the receipt
        let got = ImproveOCRReceiptInbox.disposition(of: r, archive: .shared, rows: { rows })
        guard case .refresh(let path) = got else { return XCTFail("\(got)") }
        XCTAssertEqual(URL(fileURLWithPath: path).standardizedFileURL, url.standardizedFileURL)
    }

    func testAReceiptForAGoneFileIsDroppedAndOneForAnotherArchiveWaits() throws {
        XCTAssertEqual(ImproveOCRReceiptInbox.disposition(of: try receipt("Box 1/gone.pdf"), archive: .shared, rows: { [] }), .drop)
        XCTAssertEqual(ImproveOCRReceiptInbox.disposition(of: try receipt("Box 1/a.pdf", guid: UUID()), archive: .shared,
                                                          rows: { [] }), .notHere)
        XCTAssertEqual(ImproveOCRReceiptInbox.disposition(of: try receipt("../escape.pdf"), archive: .shared, rows: { [] }), .drop)
        XCTAssertEqual(ImproveOCRReceiptInbox.disposition(of: nil, archive: .shared, rows: { [] }), .notHere,
                       "a receipt this build cannot read is left for a later one")
    }

    func testSeenReceiptsAreKeptAllAndSkippedOnesAreNotRead() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PoorOCRGuardTests-\(UUID().uuidString)"))
        let inbox = ImproveOCRReceiptInbox(defaults: defaults)
        let folder = support.appendingPathComponent(ImproveOCRReceipt.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = UUID(), b = UUID()
        for id in [a, b] { try Data("{}".utf8).write(to: folder.appendingPathComponent("\(id.uuidString).json")) }
        XCTAssertEqual(Set(inbox.unseen(in: support, skipping: []).map(\.id)), [a, b])
        XCTAssertEqual(inbox.unseen(in: support, skipping: [a]).map(\.id), [b])
        inbox.markSeen((0..<6000).map { _ in UUID() } + [a])
        XCTAssertEqual(inbox.unseen(in: support, skipping: []).map(\.id), [b], "no seen ID is ever forgotten")
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
