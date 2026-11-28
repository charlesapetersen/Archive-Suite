import Darwin
import XCTest
@testable import ArchiveCore

/// The suite's Finder mirror (W49.storage-finder-reader-mirror), on throwaway temp files only.
final class FinderMirrorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FinderMirrorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeFile(_ name: String = "Letter.pdf", tags: [String] = [], label: Int? = nil) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("PDF-BYTES-\(UUID().uuidString)".utf8).write(to: url)
        if !tags.isEmpty { try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
        if let label { try (url as NSURL).setResourceValue(label, forKey: .labelNumberKey) }
        return url
    }

    private func tags(_ url: URL) throws -> [String] {
        (try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    private func label(_ url: URL) throws -> Int? {
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.labelNumberKey]).labelNumber
    }

    private func setTags(_ url: URL, _ tags: [String]) throws {
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    private func field(_ value: String, checked: Bool = false) -> String {
        let revision = UUID()
        return """
        {"state":"value","value":\(value),"fieldRevision":"\(revision)","origin":"user"\
        \(checked ? ",\"checkedRevision\":\"\(revision)\"" : "")}
        """
    }

    private func record(date: String? = "1958-03-12", subjects: [String] = ["Berlin"], quality: Int? = 2,
                        read: String? = "Unread", colour: String? = nil, checkedDate: Bool = false) throws -> CatalogueRecord {
        let file = UUID(), document = UUID()
        var documentFields: [String] = []
        if let date { documentFields.append("\"documentDate\":\(field("{\"date\":\"\(date)\",\"uncertain\":false}", checked: checkedDate))") }
        documentFields.append("\"subjects\":\(field("[" + subjects.map { "\"\($0)\"" }.joined(separator: ",") + "]"))")
        documentFields.append("\"itemType\":\(field("\"Folder\""))")
        var fileFields: [String] = []
        if let quality { fileFields.append("\"quality\":\(field("\(quality)"))") }
        if let read { fileFields.append("\"readState\":\(field("\"\(read.lowercased())\""))") }
        if let colour { fileFields.append("\"colour\":\(field("\"\(colour)\""))") }
        return try CatalogueRecord(json: Data("""
        {"schema":1,"fileID":"\(file)","contentRevision":"\(UUID())","revision":"\(UUID())","parents":[],
         "pages":[{"id":"\(UUID())","physicalIndex":0,"documentID":"\(document)","role":"searchable"}],
         "documents":[{"id":"\(document)","ownerFileID":"\(file)","fields":{\(documentFields.joined(separator: ","))}}],
         "fileFields":{\(fileFields.joined(separator: ","))}}
        """.utf8))
    }

    private func projection(_ record: CatalogueRecord) -> FinderMirror.Projection {
        FinderMirror.projection(file: record.fileFields, document: record.documents.first?.fields)
    }

    func testProjectionWritesTheVocabularyAndParsesBackToTheSameFacts() throws {
        let projected = projection(try record(colour: "green", checkedDate: true))
        XCTAssertEqual(projected.tokens, ["1958", "3 March", "Day 12", "Berlin", "Q2", "Unread", "Folder", "Checked Date"])
        XCTAssertEqual(projected.label, .green)
        let parsed = DocumentTags.parse(raw: projected.tokens, labelNumber: projected.label?.rawValue)
        XCTAssertEqual(parsed.year, 1958)
        XCTAssertEqual(parsed.month?.number, 3)
        XCTAssertEqual(parsed.day, 12)
        XCTAssertEqual(parsed.quality, 2)
        XCTAssertEqual(parsed.readState, .unread)
        XCTAssertEqual(parsed.itemType, .folder)
        XCTAssertEqual(parsed.subjects, ["Berlin"])
        XCTAssertEqual(parsed.checkedFields, [.date])
    }

    func testFirstPublicationKeepsHandMadeTagsAndOwnsOnlyWhatItAdded() throws {
        let url = try makeFile(tags: ["ToPrint", "Berlin"])
        let outcome = try FinderMirror.publish(url, projection: projection(try record()))
        guard case .published = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(Set(try tags(url)), ["ToPrint", "Berlin", "1958", "3 March", "Day 12", "Q2", "Unread", "Folder"])
        let ledger = try XCTUnwrap(FinderMirror.readLedger(url).ledger)
        XCTAssertFalse(ledger.owned.contains("Berlin"), "a projected tag already on the file stays unowned")
        XCTAssertFalse(ledger.owned.contains("ToPrint"))
        XCTAssertTrue(ledger.owned.contains("Q2"))
    }

    func testARecordEditReplacesOnlyTheSuitesOwnStaleTokens() throws {
        let url = try makeFile(tags: ["ToPrint"])
        _ = try FinderMirror.publish(url, projection: projection(try record()))
        let outcome = try FinderMirror.publish(url, projection: projection(try record(date: "1960", subjects: ["Paris"],
                                                                                         quality: 3, read: "Read")))
        guard case .published = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(Set(try tags(url)), ["ToPrint", "1960", "Paris", "Q3", "Read", "Folder"])
    }

    func testAMirroredTagChangedInFinderIsADivergenceAndNothingIsWritten() throws {
        let url = try makeFile()
        _ = try FinderMirror.publish(url, projection: projection(try record()))
        var finder = try tags(url)
        finder.removeAll { $0 == "Q2" }
        finder.append("Q3")
        try setTags(url, finder)
        let edited = projection(try record(subjects: ["Berlin", "Bonn"]))
        let outcome = try FinderMirror.publish(url, projection: edited)
        guard case .diverged(let divergence) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(divergence.removed, ["Q2"])
        XCTAssertEqual(divergence.added, ["Q3"])
        XCTAssertEqual(Set(try tags(url)), Set(finder), "a divergence writes nothing")

        guard case .published = try FinderMirror.publish(url, projection: edited, republishing: true) else {
            return XCTFail("Re-publish should write")
        }
        let after = try tags(url)
        XCTAssertTrue(after.contains("Q2"))
        XCTAssertFalse(after.contains("Q3"))
        XCTAssertTrue(after.contains("Bonn"))
        XCTAssertNil(FinderMirror.divergence(current: after, label: try label(url),
                                             ledger: FinderMirror.readLedger(url).ledger))
    }

    func testAHandMadeTagAddedInFinderIsNotADivergence() throws {
        let url = try makeFile()
        _ = try FinderMirror.publish(url, projection: projection(try record()))
        try setTags(url, try tags(url) + ["ToPrint"])
        guard case .published = try FinderMirror.publish(url, projection: projection(try record(quality: 1))) else {
            return XCTFail("a hand-made tag is not the mirror's")
        }
        XCTAssertTrue(try tags(url).contains("ToPrint"))
        XCTAssertTrue(try tags(url).contains("Q1"))
    }

    func testRemoveSuiteTagsTakesOffOnlyOwnedTokensAndUndoPutsThemBack() throws {
        let url = try makeFile(tags: ["ToPrint", "Berlin"])
        _ = try FinderMirror.publish(url, projection: projection(try record(colour: "red")))
        XCTAssertEqual(try label(url), FinderLabel.red.rawValue)
        let removal = try XCTUnwrap(try FinderMirror.removeSuiteTags(url))
        XCTAssertEqual(Set(try tags(url)), ["ToPrint", "Berlin"])
        XCTAssertEqual(try label(url) ?? 0, 0)
        XCTAssertEqual(FinderMirror.readLedger(url), .none)
        XCTAssertNil(try FinderMirror.removeSuiteTags(url), "nothing is the suite's any more")

        try FinderMirror.restoreSuiteTags(url, removal: removal)
        XCTAssertTrue(try tags(url).contains("Q2"))
        XCTAssertEqual(try label(url), FinderLabel.red.rawValue)
        XCTAssertFalse(try XCTUnwrap(FinderMirror.readLedger(url).ledger).owned.contains("Berlin"))
    }

    func testAFileWithoutALedgerKeepsEveryTagOnRemoval() throws {
        let url = try makeFile(tags: ["1958", "Q2", "Unread"])
        XCTAssertNil(try FinderMirror.removeSuiteTags(url))
        XCTAssertEqual(Set(try tags(url)), ["1958", "Q2", "Unread"])
    }

    func testAnUnreadableLedgerIsNeverOverwrittenWithoutRepublish() throws {
        let url = try makeFile(tags: ["Q2"])
        let garbage = Data("{\"v\":99}".utf8)
        _ = url.withUnsafeFileSystemRepresentation { path in
            garbage.withUnsafeBytes { setxattr(path, FinderMirror.ledgerAttribute, $0.baseAddress, garbage.count, 0, 0) }
        }
        guard case .unknownLedger = try FinderMirror.publish(url, projection: projection(try record())) else {
            return XCTFail("a newer build's record must not be replaced")
        }
        XCTAssertEqual(try tags(url), ["Q2"])
        XCTAssertNil(try FinderMirror.removeSuiteTags(url))
        guard case .published = try FinderMirror.publish(url, projection: projection(try record()), republishing: true) else {
            return XCTFail("Re-publish replaces it")
        }
        XCTAssertNotNil(FinderMirror.readLedger(url).ledger)
    }

    func testClaimOwnsAFreshOutputsTagsButNotItsSourcesOwn() throws {
        let url = try makeFile(tags: ["1958", "Q2", "Source Tag A"])
        try FinderMirror.claim(url, excluding: ["Source Tag A"])
        XCTAssertEqual(FinderMirror.readLedger(url).ledger?.owned, ["1958", "Q2"])
        XCTAssertEqual(try tags(url), ["1958", "Q2", "Source Tag A"])
    }

    func testRepublishLeavesAHandSetColourAlone() throws {
        let url = try makeFile(tags: ["Purple"], label: FinderLabel.purple.rawValue)
        _ = try FinderMirror.publish(url, projection: projection(try record(colour: "red")))
        XCTAssertEqual(try label(url), FinderLabel.purple.rawValue, "a label the suite did not set is left")
        try setTags(url, try tags(url).filter { $0 != "Day 12" })
        guard case .published = try FinderMirror.publish(url, projection: projection(try record(colour: "red")),
                                                         republishing: true) else { return XCTFail() }
        XCTAssertEqual(try label(url), FinderLabel.purple.rawValue)
        XCTAssertTrue(try tags(url).contains("Purple"))
        XCTAssertFalse(try tags(url).contains("Red"))
        XCTAssertTrue(try tags(url).contains("Day 12"))
    }

    func testRepublishKeepsAColourChosenInFinderWhenTheSuiteSetNone() throws {
        let url = try makeFile()
        _ = try FinderMirror.publish(url, projection: projection(try record()))
        try setTags(url, try tags(url).filter { $0 != "Q2" } + ["Blue"])
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(FinderLabel.blue.rawValue, forKey: .labelNumberKey)
        guard case .published = try FinderMirror.publish(url, projection: projection(try record()),
                                                         republishing: true) else { return XCTFail() }
        XCTAssertTrue(try tags(url).contains("Blue"))
        XCTAssertEqual(try label(url), FinderLabel.blue.rawValue)
        XCTAssertTrue(try tags(url).contains("Q2"))
    }

    func testRepublishPutsBackTheSuitesOwnColour() throws {
        let url = try makeFile()
        _ = try FinderMirror.publish(url, projection: projection(try record(colour: "red")))
        try setTags(url, try tags(url).filter { $0 != "Red" } + ["Blue"])
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(FinderLabel.blue.rawValue, forKey: .labelNumberKey)
        let outcome = try FinderMirror.publish(url, projection: projection(try record(colour: "red")))
        guard case .diverged(let divergence) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(divergence.labelChanged)
        _ = try FinderMirror.publish(url, projection: projection(try record(colour: "red")), republishing: true)
        XCTAssertEqual(try label(url), FinderLabel.red.rawValue)
        XCTAssertTrue(try tags(url).contains("Red"))
        XCTAssertFalse(try tags(url).contains("Blue"))
    }

    func testOwnershipSurvivesASubjectThatOnlyChangesCase() throws {
        let url = try makeFile()
        _ = try FinderMirror.publish(url, projection: projection(try record(subjects: ["Lincoln"])))
        _ = try FinderMirror.publish(url, projection: projection(try record(subjects: ["lincoln"])))
        XCTAssertTrue(try XCTUnwrap(FinderMirror.readLedger(url).ledger).owned.contains("Lincoln"))
        _ = try FinderMirror.removeSuiteTags(url)
        XCTAssertFalse(try tags(url).contains { $0.caseInsensitiveCompare("lincoln") == .orderedSame })
    }

    func testARecordThatCannotBeSavedLeavesTheTagsAsTheyWere() throws {
        let url = try makeFile(tags: ["ToPrint"])
        // An ownership record over the 64 KB a reader accepts fails its own re-read after writing.
        let subjects = (0..<1400).map { "Subject number \($0) padding text" }
        XCTAssertThrowsError(try FinderMirror.publish(url, projection: projection(try record(subjects: subjects)))) { error in
            XCTAssertTrue("\(error)".contains("nothing was changed"), "\(error)")
        }
        XCTAssertEqual(try tags(url), ["ToPrint"])
    }

    func testAFilingThatLeavesTagsBehindLeavesTheLedgerBehindToo() throws {
        let source = try makeFile(tags: ["Q2"])
        try FinderMirror.claim(source, excluding: [])
        for carries in [false, true] {
            let target = tempDir.appendingPathComponent("copy-\(carries).pdf")
            let input = open(source.path, O_RDONLY)
            let output = open(target.path, O_RDWR | O_CREAT | O_EXCL, 0o644)
            defer { close(input); close(output) }
            XCTAssertEqual(CataloguePairFiler.copyFile(input, to: output, carriesFinderTags: carries), 0)
            XCTAssertEqual(FinderMirror.readLedger(target) == .none, !carries)
        }
    }

    // MARK: The archive's settings

    func testArchiveSettingsAreSharedFromTheRootAndOffUnlessChosen() throws {
        let root = tempDir.appendingPathComponent("Archive", isDirectory: true)
        let output = root.appendingPathComponent("Box 1/Folder 2", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        XCTAssertTrue(ArchiveSettings.mirrorsFinderTags(inFolder: output, outsideArchive: true),
                      "outside any archive the general setting decides")
        _ = try RootMarker.ensure(at: root, kind: .reader, name: "Archive")
        XCTAssertEqual(ArchiveSettings.archiveRoot(containing: output)?.standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertFalse(ArchiveSettings.mirrorsFinderTags(inFolder: output, outsideArchive: true),
                       "an archive that has not chosen does not mirror")
        try ArchiveSettings.write(ArchiveSettings(mirrorFinderTags: true), root: root)
        XCTAssertEqual(try ArchiveSettings.read(root: root)?.mirrorFinderTags, true)
        XCTAssertTrue(ArchiveSettings.mirrorsFinderTags(inFolder: output, outsideArchive: false))
        try ArchiveSettings.write(ArchiveSettings(mirrorFinderTags: false), root: root)
        XCTAssertFalse(ArchiveSettings.mirrorsFinderTags(inFolder: output, outsideArchive: true))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".archivesuite").path)
        XCTAssertEqual(leftovers, ["archive-settings.json"])
    }

    func testAnArchiveThatCannotBeToldDoesNotMirror() throws {
        let root = tempDir.appendingPathComponent("Sealed", isDirectory: true)
        let output = root.appendingPathComponent("Box", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent(RootMarker.filename)
        try Data("{}".utf8).write(to: marker)
        XCTAssertEqual(ArchiveSettings.membership(of: output), .unknown)
        XCTAssertFalse(ArchiveSettings.mirrorsFinderTags(inFolder: output, outsideArchive: true))
    }

    func testArchiveSettingsNeverWriteThroughALinkOrOverANewerDocument() throws {
        let root = tempDir.appendingPathComponent("Linked", isDirectory: true)
        let elsewhere = tempDir.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".archivesuite"), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try ArchiveSettings.write(ArchiveSettings(mirrorFinderTags: true), root: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])

        let newer = tempDir.appendingPathComponent("Newer", isDirectory: true)
        let folder = newer.appendingPathComponent(".archivesuite", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let document = folder.appendingPathComponent("archive-settings.json")
        try Data("{\"schemaVersion\":2,\"mirrorFinderTags\":true}".utf8).write(to: document)
        XCTAssertThrowsError(try ArchiveSettings.write(ArchiveSettings(mirrorFinderTags: false), root: newer)) { error in
            XCTAssertEqual(error as? ArchiveSettings.Failure, .newer(2))
        }
        XCTAssertEqual(try Data(contentsOf: document), Data("{\"schemaVersion\":2,\"mirrorFinderTags\":true}".utf8))
    }
}
