import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W47.ct-folder-date-reader: a folder date confirmed in the Reader dates the run's documents already written. On a
/// scratch tree only: a folder photo and five documents, each with its own page 2, and the folder's container file.
@MainActor
final class FolderDatingTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var savedLedgerURL: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        try await super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FolderDating-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("Box 3", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedLedgerURL = AuditLedger.shared.fileURL
        AuditLedger.shared.fileURL = root.appendingPathComponent("audit-ledger.jsonl")
    }

    override func tearDown() async throws {
        AuditLedger.shared.fileURL = savedLedgerURL
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    /// The test page is narrow (`TestPDFBuilder`), so each header line is kept short enough not to wrap into the body.
    private static func page2(_ lines: [String]) -> String {
        (["Extracted text.", "Gemini · gemini-3.7-flash · 7 November 2026"] + lines + ["", "Body text."])
            .joined(separator: "\n")
    }

    /// The files, their tags and page 2: 0001 the folder photo; 0002 undated; 0003 an estimate; 0004 its own text's
    /// year; 0005 read off the image; 0006 no text at all; 0007 a checked date.
    private func makeFolder(date: String, source: ContainerSource = .user) throws {
        let files: [(String, [String], [String]?)] = [
            ("0001.pdf", ["Unread", "Folder"], ["Classification: Folder"]),
            ("0002.pdf", ["Unread", "Harbours"], ["Classification: Document Start"]),
            ("0003.pdf", ["Unread", "1958", "Date Uncertain"],
             ["Classification: Document Start", "Date evidence: estimate; gave 1958, Date Uncertain"]),
            ("0004.pdf", ["Unread", "1961"], ["Classification: Document Start"]),
            ("0005.pdf", ["Unread", "1962"], ["Classification: Document Start", "Date evidence: image; page 1; gave 1962"]),
            ("0006.pdf", ["Unread"], nil),
            ("0007.pdf", ["Unread", "1950", "Checked Date"], ["Classification: Document Start"]),
        ]
        for (name, tags, header) in files {
            let url = folder.appendingPathComponent(name)
            let pages = header.map { ["(the page image)", Self.page2($0)] } ?? ["(the page image)"]
            try TestPDFBuilder.textPDFData(pages: pages).write(to: url)
            try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        let value = source == .user ? ContainerValue(date, source: .user, at: now)
            : ContainerValue(date, source: source, reader: FieldStatusPolicy.visionParser)
        let file = ContainerFile(runs: [
            ContainerRun(start: "0001.pdf", level: .folder, fields: ContainerFieldSet([.date: value])),
        ])
        try ContainerFileStore.write(file, directory: folder, expecting: nil)
    }

    private func stamp() -> ContainerFileStamp? {
        if case let .loaded(_, s) = ContainerFileStore.load(directory: folder) { return s }
        return nil
    }

    private func tagsOnDisk(_ name: String) throws -> Set<String> {
        Set(try URL(fileURLWithPath: folder.appendingPathComponent(name).path)
            .resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [])
    }

    private func bytes() throws -> [String: Data] {
        var out: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".pdf") {
            out[name] = try Data(contentsOf: folder.appendingPathComponent(name))
        }
        return out
    }

    private func wait(_ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !done(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testTheRunsUndatedDocumentsAreOfferedAndNothingElse() throws {
        try makeFolder(date: "1965-1967")
        let run = try XCTUnwrap(NavigationModel.folderDatingRun(tree: root, components: ["Box 3"], editedName: "0003.pdf"))
        XCTAssertEqual(run.names, ["0001.pdf", "0002.pdf", "0003.pdf", "0004.pdf", "0005.pdf", "0006.pdf", "0007.pdf"])
        XCTAssertEqual(run.date?.inherited, .year(1966, month: nil, uncertain: true))

        let files = run.names.map { name -> ArchiveFile in
            let url = folder.appendingPathComponent(name)
            let raw = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
            return ArchiveFile(url: url, name: name, fileType: "PDF", tags: DocumentTags.parse(raw: raw, labelNumber: nil),
                               contentModified: nil)
        }
        let evidence = NavigationModel.folderDatingEvidence(files.map { ($0.path, $0.url, false) }, directory: folder)
        XCTAssertEqual(evidence[files[0].path]?.containerPhoto, true)
        XCTAssertEqual(evidence[files[2].path]?.page?.hasPrefix("estimate;"), true)
        let plan = NavigationModel.folderDatingPlan(try XCTUnwrap(run.date), files: files, evidence: evidence)
        XCTAssertEqual(plan.writes.map { ($0 as NSString).lastPathComponent }, ["0002.pdf", "0003.pdf", "0006.pdf"],
                       "undated, estimated and no text; not the folder photo, the text's or image's year, a checked date")
        XCTAssertEqual(plan.records, plan.writes)
        let placeholder = NavigationModel.folderDatingEvidence([(files[2].path, files[2].url, true)], directory: folder)
        XCTAssertNil(placeholder[files[2].path]?.page, "a placeholder is never opened")
    }

    /// W49.reader-finder-year-stands: an estimated year retyped in Finder (which adds no check) no longer matches the
    /// year page 2's evidence gave, so it is the user's and the folder's date does not replace it.
    func testAYearRetypedInFinderStands() throws {
        try makeFolder(date: "1965-1967")
        let retyped = folder.appendingPathComponent("0003.pdf")
        try (retyped as NSURL).setResourceValue(["Unread", "1959", "Date Uncertain"], forKey: .tagNamesKey)
        let run = try XCTUnwrap(NavigationModel.folderDatingRun(tree: root, components: ["Box 3"], editedName: "0002.pdf"))
        let files = run.names.map { name -> ArchiveFile in
            let url = folder.appendingPathComponent(name)
            let raw = (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
            return ArchiveFile(url: url, name: name, fileType: "PDF", tags: DocumentTags.parse(raw: raw, labelNumber: nil),
                               contentModified: nil)
        }
        let evidence = NavigationModel.folderDatingEvidence(files.map { ($0.path, $0.url, false) }, directory: folder)
        let plan = NavigationModel.folderDatingPlan(try XCTUnwrap(run.date), files: files, evidence: evidence)
        XCTAssertEqual(plan.writes.map { ($0 as NSString).lastPathComponent }, ["0002.pdf", "0006.pdf"],
                       "the retyped year stands")
        var header = FieldStatusSection.HeaderFields(headers: [])
        header.dateEvidence = evidence[files[2].path]?.page
        XCTAssertEqual(header.dateEvidence?.hasPrefix("estimate;"), true)
        let date = FieldStatusList.rows(tags: files[2].tags, header: header).first { $0.field == .date }
        XCTAssertEqual(date?.status, FieldStatusPolicy.date(checked: false, evidence: nil),
                       "the Checks no longer call it the estimate's")
    }

    /// W49.reader-finder-month-stands: an estimate's `Date Uncertain` removed in Finder, or a month added there, with the
    /// year kept, no longer matches the date page 2's evidence gave, so it is the user's and the folder's date does not
    /// replace it.
    func testAMonthOrUncertaintyChangedInFinderStands() throws {
        try makeFolder(date: "1965-1967")
        for changed in [["Unread", "1958"], ["Unread", "1958", "3 March", "Date Uncertain"]] {
            try (folder.appendingPathComponent("0003.pdf") as NSURL).setResourceValue(changed, forKey: .tagNamesKey)
            let run = try XCTUnwrap(NavigationModel.folderDatingRun(tree: root, components: ["Box 3"], editedName: "0002.pdf"))
            let files = run.names.map { name -> ArchiveFile in
                let url = folder.appendingPathComponent(name)
                let raw = (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
                return ArchiveFile(url: url, name: name, fileType: "PDF", tags: DocumentTags.parse(raw: raw, labelNumber: nil),
                                   contentModified: nil)
            }
            let evidence = NavigationModel.folderDatingEvidence(files.map { ($0.path, $0.url, false) }, directory: folder)
            let plan = NavigationModel.folderDatingPlan(try XCTUnwrap(run.date), files: files, evidence: evidence)
            XCTAssertEqual(plan.writes.map { ($0 as NSString).lastPathComponent }, ["0002.pdf", "0006.pdf"],
                           "the user's \(changed) stands")
        }
    }

    func testAnUnconfirmedOrUnusableDateOffersNothing() throws {
        try makeFolder(date: "1965-1967", source: .label)
        XCTAssertNil(NavigationModel.folderDatingRun(tree: root, components: ["Box 3"], editedName: "0002.pdf"),
                     "a label read nobody confirmed")
        try ContainerFileStore.write(ContainerFile(runs: [ContainerRun(start: "0001.pdf", level: .folder,
            fields: ContainerFieldSet([.date: ContainerValue("1930-1970", source: .user, at: now)]))]),
            directory: folder, expecting: stamp())
        XCTAssertNil(NavigationModel.folderDatingRun(tree: root, components: ["Box 3"], editedName: "0002.pdf"),
                     "20 years or more")
    }

    func testDatingWritesTheTagsAndTheEvidenceAndUndoTakesTheTagsBack() throws {
        try makeFolder(date: "Feb. 1966")
        let before = try bytes()
        let model = fixtureNavigationModel(pinnedTo: root)
        wait { model.library.files.count >= 7 }
        let tree = try XCTUnwrap(model.containerTree, "the scratch root is the container tree")
        let edited = ([tree.path] + ["Box 3", "0002.pdf"]).joined(separator: "/")

        model.offerFolderDating(at: edited, window: nil)
        wait { model.folderDatingOffer != nil }
        let offer = try XCTUnwrap(model.folderDatingOffer)
        XCTAssertEqual(offer.paths.map { ($0 as NSString).lastPathComponent }, ["0002.pdf", "0003.pdf", "0006.pdf"])
        XCTAssertTrue(offer.message.contains("Feb 1966"), offer.message)

        model.applyFolderDating(offer)
        wait { model.statusMessage.hasPrefix("Dated ") }
        XCTAssertTrue(model.statusMessage.hasPrefix("Dated 3 documents"), model.statusMessage)
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours", "1966", "2 February"],
                       "a single year: its month, no Date Uncertain, no check")
        XCTAssertEqual(try tagsOnDisk("0003.pdf"), ["Unread", "1966", "2 February"], "the estimate gives way")
        XCTAssertEqual(try tagsOnDisk("0006.pdf"), ["Unread", "1966", "2 February"])
        XCTAssertEqual(try tagsOnDisk("0004.pdf"), ["Unread", "1961"])
        XCTAssertEqual(try tagsOnDisk("0005.pdf"), ["Unread", "1962"])
        XCTAssertEqual(try tagsOnDisk("0001.pdf"), ["Unread", "Folder"])
        XCTAssertEqual(try tagsOnDisk("0007.pdf"), ["Unread", "1950", "Checked Date"])
        XCTAssertEqual(try bytes(), before, "only Finder tags and .archivesuite change")

        let fields = try XCTUnwrap(ContainerFileStore.loadItemFields(directory: folder).document)
        let record = try XCTUnwrap(fields.dateRecord(for: "0003.pdf"))
        XCTAssertEqual(record, FolderDateRecord(date: "1966-02", uncertain: false,
                                                evidence: "folder; from 0001.pdf; \"Feb. 1966\"; gave 1966-02"))
        XCTAssertNil(fields.dateRecord(for: "0004.pdf"))
        let dated = DocumentTags.parse(raw: Array(try tagsOnDisk("0003.pdf")), labelNumber: nil)
        XCTAssertEqual(FieldStatusPolicy.date(checked: false, evidence: FolderDateRecord.evidence(
            record, page: "estimate; from 0002.pdf; gave 1958, Date Uncertain", tags: dated)).source,
                       FieldStatusPolicy.date(checked: false, evidence: record.evidence).source,
                       "the Checks name the folder, not the estimate page 2 still records")

        XCTAssertEqual(model.undoDepth, 1, "one Undo")
        model.undoLast()
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours"])
        XCTAssertEqual(try tagsOnDisk("0003.pdf"), ["Unread", "1958", "Date Uncertain"])
        let undone = DocumentTags.parse(raw: Array(try tagsOnDisk("0003.pdf")), labelNumber: nil)
        XCTAssertFalse(record.holds(for: undone), "the record no longer describes the file")
        XCTAssertEqual(try bytes(), before)
    }

    private func offered(_ model: NavigationModel) throws -> FolderDatingOffer {
        let tree = try XCTUnwrap(model.containerTree)
        model.offerFolderDating(at: ([tree.path] + ["Box 3", "0002.pdf"]).joined(separator: "/"), window: nil)
        wait { model.folderDatingOffer != nil }
        return try XCTUnwrap(model.folderDatingOffer)
    }

    func testAnOfferWhoseFolderDateChangedSinceDatesNothing() throws {
        try makeFolder(date: "1965-1967")
        let model = fixtureNavigationModel(pinnedTo: root)
        wait { model.library.files.count >= 7 }
        let offer = try offered(model)
        XCTAssertTrue(offer.title.contains("“Box 3”"), offer.title)
        try ContainerFileStore.write(ContainerFile(runs: [ContainerRun(start: "0001.pdf", level: .folder,
            fields: ContainerFieldSet([.date: ContainerValue("1970", source: .user, at: now)]))]),
            directory: folder, expecting: stamp())
        model.applyFolderDating(offer)
        wait { model.itemFieldEditError != nil }
        XCTAssertEqual(model.itemFieldEditError?.contains("changed since it was offered"), true,
                       model.itemFieldEditError ?? "")
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours"])
        XCTAssertNil(ContainerFileStore.loadItemFields(directory: folder).document?.dateRecord(for: "0002.pdf"))
    }

    func testAFileWhoseDateWasCheckedSinceTheOfferIsLeftWithNoRecord() throws {
        try makeFolder(date: "1965-1967")
        let model = fixtureNavigationModel(pinnedTo: root)
        wait { model.library.files.count >= 7 }
        let offer = try offered(model)
        let estimated = try XCTUnwrap(offer.paths.first { $0.hasSuffix("0003.pdf") })
        model.applyEdit(.setChecked(.date, true), paths: [estimated])
        model.applyFolderDating(offer)
        wait { model.statusMessage.hasPrefix("Dated ") }
        XCTAssertTrue(model.statusMessage.hasPrefix("Dated 2 documents"), model.statusMessage)
        XCTAssertEqual(try tagsOnDisk("0003.pdf"), ["Unread", "1958", "Date Uncertain", "Checked Date"])
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours", "1966", "Date Uncertain"])
        wait { ContainerFileStore.loadItemFields(directory: folder).document?.dateRecord(for: "0003.pdf") == nil }
        let fields = ContainerFileStore.loadItemFields(directory: folder).document
        XCTAssertNil(fields?.dateRecord(for: "0003.pdf"), "the checked file keeps no record")
        XCTAssertNotNil(fields?.dateRecord(for: "0002.pdf"))
    }

    private func setFolderDate(_ value: ContainerValue?) throws {
        try ContainerFileStore.write(ContainerFile(runs: [ContainerRun(start: "0001.pdf", level: .folder,
            fields: ContainerFieldSet(value.map { [.date: $0] } ?? [:]))]), directory: folder, expecting: stamp())
    }

    private func datedFromTheFolder(_ model: NavigationModel) throws {
        model.applyFolderDating(try offered(model))
        wait { model.statusMessage.hasPrefix("Dated ") }
        XCTAssertEqual(try tagsOnDisk("0003.pdf"), ["Unread", "1966", "2 February"])
        model.folderDatingOffer = nil
        model.statusMessage = ""
    }

    /// W49.reader-folder-date-undo: clearing the folder's date takes away exactly the dates it gave, the estimate's
    /// coming back, and leaves a date the user changed since; one Undo puts them back.
    func testClearingTheFolderDateTakesAwayTheDatesItGave() throws {
        try makeFolder(date: "Feb. 1966")
        let before = try bytes()
        let model = fixtureNavigationModel(pinnedTo: root)
        wait { model.library.files.count >= 7 }
        try datedFromTheFolder(model)
        let checked = try XCTUnwrap(model.library.files.first { $0.path.hasSuffix("0006.pdf") }?.path)
        model.applyEdit(.setChecked(.date, true), paths: [checked])
        XCTAssertEqual(try tagsOnDisk("0006.pdf"), ["Unread", "1966", "2 February", "Checked Date"])

        for cleared in [nil, ContainerValue("Feb. 1966", source: .label, reader: FieldStatusPolicy.visionParser),
                        ContainerValue("1930-1970", source: .user, at: now)] {
            try setFolderDate(cleared)
            let offer = try offered(model)
            XCTAssertNil(offer.date)
            XCTAssertEqual(offer.paths.map { ($0 as NSString).lastPathComponent }, ["0002.pdf", "0003.pdf"],
                           "the dates the folder gave and nobody checked; \(String(describing: cleared))")
            XCTAssertTrue(offer.title.hasPrefix("Take the folder's date from 2 documents"), offer.title)
            model.folderDatingOffer = nil
        }

        let depth = model.undoDepth
        model.applyFolderDating(try offered(model))
        wait { model.statusMessage.hasPrefix("Took ") }
        XCTAssertTrue(model.statusMessage.hasPrefix("Took the folder's date from 2 documents"), model.statusMessage)
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours"])
        XCTAssertEqual(try tagsOnDisk("0003.pdf"), ["Unread", "1958", "Date Uncertain"], "the estimate's date is back")
        XCTAssertEqual(try tagsOnDisk("0006.pdf"), ["Unread", "1966", "2 February", "Checked Date"], "checked stands")
        XCTAssertEqual(try tagsOnDisk("0004.pdf"), ["Unread", "1961"])
        XCTAssertEqual(try tagsOnDisk("0005.pdf"), ["Unread", "1962"])
        XCTAssertEqual(try tagsOnDisk("0007.pdf"), ["Unread", "1950", "Checked Date"])
        XCTAssertEqual(try bytes(), before, "only Finder tags and .archivesuite change")

        XCTAssertEqual(model.undoDepth, depth + 1, "one Undo")
        model.undoLast()
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours", "1966", "2 February"])
        XCTAssertEqual(try tagsOnDisk("0003.pdf"), ["Unread", "1966", "2 February"])
        let fields = try XCTUnwrap(ContainerFileStore.loadItemFields(directory: folder).document)
        let restored = DocumentTags.parse(raw: Array(try tagsOnDisk("0003.pdf")), labelNumber: nil)
        XCTAssertEqual(fields.dateRecord(for: "0003.pdf")?.holds(for: restored), true,
                       "the record speaks for the restored date again")
    }

    /// Widening the folder's date replaces the dates it gave with the wider one, and nothing the user checked.
    func testWideningTheFolderDateUpdatesTheDatesItGave() throws {
        try makeFolder(date: "Feb. 1966")
        let model = fixtureNavigationModel(pinnedTo: root)
        wait { model.library.files.count >= 7 }
        try datedFromTheFolder(model)
        try setFolderDate(ContainerValue("1960s", source: .user, at: now))
        let offer = try offered(model)
        XCTAssertEqual(offer.paths.map { ($0 as NSString).lastPathComponent }, ["0002.pdf", "0003.pdf", "0006.pdf"])
        model.applyFolderDating(offer)
        wait { model.statusMessage.hasPrefix("Dated ") }
        XCTAssertEqual(try tagsOnDisk("0003.pdf"), ["Unread", "1960s", "Date Uncertain"])
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours", "1960s", "Date Uncertain"])
        XCTAssertEqual(try tagsOnDisk("0004.pdf"), ["Unread", "1961"])
        XCTAssertEqual(try tagsOnDisk("0007.pdf"), ["Unread", "1950", "Checked Date"])
    }

    /// None Here in the Container section offers the undating; an edit of a folder that gave no date before offers none.
    func testNoneHereOffersAndAnUndatedFolderDoesNot() throws {
        try makeFolder(date: "Feb. 1966")
        let model = fixtureNavigationModel(pinnedTo: root)
        wait { model.library.files.count >= 7 }
        try datedFromTheFolder(model)
        let tree = try XCTUnwrap(model.containerTree)
        let edited = ([tree.path] + ["Box 3", "0002.pdf"]).joined(separator: "/")
        wait { !model.containerEditSaving }
        model.editContainerField(.date, .noneHere, forPath: edited)
        wait { model.folderDatingOffer != nil }
        let offer = try XCTUnwrap(model.folderDatingOffer)
        XCTAssertNil(offer.date)
        XCTAssertEqual(offer.paths.map { ($0 as NSString).lastPathComponent }, ["0002.pdf", "0003.pdf", "0006.pdf"])
        model.folderDatingOffer = nil

        // Already no date: a second None Here (a folder that dated nothing before it) offers nothing.
        wait { !model.containerEditSaving }
        model.editContainerField(.date, .noneHere, forPath: edited)
        wait { !model.containerEditSaving }
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertNil(model.folderDatingOffer)
    }
}
