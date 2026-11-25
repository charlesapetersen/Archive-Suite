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
    private func makeFolder(date: String, source: ContainerSource = .user, in directory: URL? = nil) throws {
        let folder: URL = directory ?? self.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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

    private func tagsOnDisk(_ name: String, in directory: URL? = nil) throws -> Set<String> {
        Set(try URL(fileURLWithPath: (directory ?? folder).appendingPathComponent(name).path)
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

    /// W49.reader-folder-date-day-first: a numeric folder date reads in the collection's order, as Process Files and
    /// Live Capture read it: "6/2/61" is June month first, February where the collection's record says day first.
    func testANumericFolderDateReadsInTheCollectionsOrder() throws {
        try makeFolder(date: "6/2/61")
        func month() throws -> Int? {
            let run = try XCTUnwrap(NavigationModel.folderDatingRun(tree: root, components: ["Box 3"], editedName: "0002.pdf"))
            guard case let .year(1961, month, uncertain: false)? = run.date?.inherited else { return nil }
            return month
        }
        XCTAssertEqual(try month(), 6, "no collection record: month first")
        let record = root.appendingPathComponent(".archivesuite/collection-settings.json")
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        func order(_ dayFirst: Bool) throws {
            try Data(("""
            {"collection":{"entries":{"numericDatesDayFirst":{"source":{"setByUser":{"_0":"2026-11-24T10:00:00Z"}},\
            "value":{"type":"bool","value":\(dayFirst)}}},"id":"C","kind":"collection","name":"Letters"},"schemaVersion":1}
            """).utf8).write(to: record)
        }
        try order(true)
        XCTAssertEqual(try month(), 2, "the collection's numeric dates are day first")
        try order(false)
        XCTAssertEqual(try month(), 6)
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
        let stamped = folder.appendingPathComponent("0008.pdf")
        let stampTags = ["Unread", "1960", "5 May", "Day 2", "Date Uncertain"]
        let page2 = Self.page2(["Classification: Document Start",
                                "Date evidence: stamp; page 1; gave 1960-05-02, Date Uncertain"])
        try TestPDFBuilder.textPDFData(pages: ["(the page image)", page2]).write(to: stamped)
        try (stamped as NSURL).setResourceValue(stampTags, forKey: .tagNamesKey)
        let before = try bytes()
        let model = fixtureNavigationModel(pinnedTo: root)
        wait { model.library.files.count >= 8 }
        let tree = try XCTUnwrap(model.containerTree, "the scratch root is the container tree")
        let edited = ([tree.path] + ["Box 3", "0002.pdf"]).joined(separator: "/")

        model.offerFolderDating(at: edited, window: nil)
        wait { model.folderDatingOffer != nil }
        let offer = try XCTUnwrap(model.folderDatingOffer)
        XCTAssertEqual(offer.paths.map { ($0 as NSString).lastPathComponent }, ["0002.pdf", "0003.pdf", "0006.pdf"])
        XCTAssertTrue(offer.message.contains("Feb 1966"), offer.message)
        XCTAssertTrue(offer.message.contains("text, page image or stamp"), offer.message)

        model.applyFolderDating(offer)
        wait { model.statusMessage.hasPrefix("Dated ") }
        XCTAssertTrue(model.statusMessage.hasPrefix("Dated 3 documents"), model.statusMessage)
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours", "1966", "2 February"],
                       "a single year: its month, no Date Uncertain, no check")
        XCTAssertEqual(try tagsOnDisk("0003.pdf"), ["Unread", "1966", "2 February"], "the estimate gives way")
        XCTAssertEqual(try tagsOnDisk("0006.pdf"), ["Unread", "1966", "2 February"])
        XCTAssertEqual(try tagsOnDisk("0004.pdf"), ["Unread", "1961"])
        XCTAssertEqual(try tagsOnDisk("0005.pdf"), ["Unread", "1962"])
        XCTAssertEqual(try tagsOnDisk(stamped.lastPathComponent), Set(stampTags))
        XCTAssertEqual(try tagsOnDisk("0001.pdf"), ["Unread", "Folder"])
        XCTAssertEqual(try tagsOnDisk("0007.pdf"), ["Unread", "1950", "Checked Date"])
        XCTAssertEqual(try bytes(), before, "only Finder tags and .archivesuite change")

        let fields = try XCTUnwrap(ContainerFileStore.loadItemFields(directory: folder).document)
        let record = try XCTUnwrap(fields.dateRecord(for: "0003.pdf"))
        XCTAssertEqual(record, FolderDateRecord(date: "1966-02", uncertain: false,
                                                evidence: "folder; from 0001.pdf; \"Feb. 1966\"; gave 1966-02",
                                                replaced: .init(date: "1958", uncertain: true)),
                       "the estimate's date is kept as the one replaced")
        XCTAssertNil(fields.dateRecord(for: "0002.pdf")?.replaced, "an undated file replaced none")
        XCTAssertNil(fields.dateRecord(for: "0004.pdf"))
        XCTAssertNil(fields.dateRecord(for: stamped.lastPathComponent))
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
        wait { ContainerFileStore.loadItemFields(directory: folder).document?.dateRecord(for: "0003.pdf")?.retired == true }
        XCTAssertEqual(ContainerFileStore.loadItemFields(directory: folder).document?.dateRecord(for: "0003.pdf")?.retired,
                       true, "W49.reader-folder-date-undo-fu: Undo Tag Change retires the record")
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
        let restored = DocumentTags.parse(raw: Array(try tagsOnDisk("0003.pdf")), labelNumber: nil)
        wait { self.record("0003.pdf")?.holds(for: restored) == true }
        XCTAssertEqual(record("0003.pdf")?.holds(for: restored), true, "the record speaks for the restored date again")
    }

    private func record(_ name: String) -> FolderDateRecord? {
        ContainerFileStore.loadItemFields(directory: folder).document?.dateRecord(for: name)
    }

    private func tags(_ name: String) throws -> DocumentTags {
        DocumentTags.parse(raw: Array(try tagsOnDisk(name)), labelNumber: nil)
    }

    /// W49.reader-folder-date-undo-fu: taking the folder's dates away retires their records, so the same date typed
    /// again in Finder is the user's; Undo Tag Change revives them, Redo retires them again.
    func testTakingTheDatesAwayRetiresTheRecordsAndUndoRevivesThem() throws {
        try makeFolder(date: "Feb. 1966")
        let model = fixtureNavigationModel(pinnedTo: root)
        wait { model.library.files.count >= 7 }
        try datedFromTheFolder(model)
        try setFolderDate(nil)
        model.applyFolderDating(try offered(model))
        wait { model.statusMessage.hasPrefix("Took ") }
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours"])
        wait { self.record("0002.pdf")?.retired == true }
        XCTAssertEqual(record("0002.pdf")?.retired, true)
        XCTAssertEqual(record("0003.pdf")?.retired, true)

        model.undoLast()
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours", "1966", "2 February"])
        wait { self.record("0002.pdf")?.retired == false }
        XCTAssertEqual(record("0002.pdf")?.holds(for: try tags("0002.pdf")), true, "Undo revives the record")

        model.redoLast()
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours"])
        wait { self.record("0002.pdf")?.retired == true }
        XCTAssertEqual(record("0002.pdf")?.retired, true, "Redo retires it again")

        // The same date typed in Finder: the record carries it, but no longer speaks for it.
        try (folder.appendingPathComponent("0002.pdf") as NSURL)
            .setResourceValue(["Unread", "Harbours", "1966", "2 February"], forKey: .tagNamesKey)
        let retyped = try tags("0002.pdf")
        let kept = try XCTUnwrap(record("0002.pdf"))
        XCTAssertTrue(kept.carries(retyped))
        XCTAssertNil(FolderDateRecord.evidence(kept, page: nil, tags: retyped))
        XCTAssertFalse(ContainerFolderDate.folderGave(retyped, evidence: FolderDateRecord.evidence(kept, page: nil,
                                                                                                  tags: retyped)))
    }

    /// W49.reader-folder-date-undo-fu (review): a record retired by one change is revived only by that change's own
    /// reversal, never by undoing an unrelated edit that happens to leave the folder's date on the file.
    func testOnlyTheRetiringChangesReversalRevivesARecord() throws {
        try makeFolder(date: "Feb. 1966")
        let model = fixtureNavigationModel(pinnedTo: root)
        wait { model.library.files.count >= 7 }
        try datedFromTheFolder(model)
        model.undoLast()
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours"])
        wait { self.record("0002.pdf")?.retired == true }
        XCTAssertEqual(record("0002.pdf")?.retired, true)

        // The user types the same date in Finder, then changes it in the Inspector and undoes that.
        try (folder.appendingPathComponent("0002.pdf") as NSURL)
            .setResourceValue(["Unread", "Harbours", "1966", "2 February"], forKey: .tagNamesKey)
        let path = try XCTUnwrap(model.library.files.first { $0.path.hasSuffix("0002.pdf") }?.path)
        wait { model.library.files.first { $0.path == path }?.tags.year == 1966 }
        model.applyEdit(.setDate(try XCTUnwrap(ArchiveDate(year: 1967))), paths: [path])
        XCTAssertTrue(try tagsOnDisk("0002.pdf").contains("1967"))
        model.undoLast()
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours", "1966", "2 February"])
        NavigationModel.folderDateRecordQueue.sync {}
        XCTAssertEqual(record("0002.pdf")?.retired, true, "the user's date stays the user's")
    }

    /// W49.reader-folder-date-undo-fu2: a folder's date removed in Finder and typed there again is the user's. The
    /// library watcher sees the date change and retires the record for good; a Finder edit that leaves the date alone
    /// keeps it.
    func testADateRemovedAndRetypedInFinderIsTheUsers() throws {
        try makeFolder(date: "Feb. 1966")
        let model = fixtureNavigationModel(pinnedTo: root)
        wait { model.library.files.count >= 7 }
        try datedFromTheFolder(model)
        XCTAssertEqual(record("0002.pdf")?.holds(for: try tags("0002.pdf")), true)
        func row(_ name: String) -> ArchiveFile? { model.library.files.first { $0.path.hasSuffix("/" + name) } }
        // As the watcher reports a Finder edit (the test host's FSEvents are not relied on).
        func seen(_ names: String...) {
            let paths = names.map { folder.appendingPathComponent($0).path }
            model.library.receiveWatchRequestForTesting(CorpusWatchRequest(paths: CorpusWatchPathSet(paths)))
        }

        try (folder.appendingPathComponent("0003.pdf") as NSURL)
            .setResourceValue(["Unread", "1966", "2 February", "Harbours"], forKey: .tagNamesKey)
        try (folder.appendingPathComponent("0002.pdf") as NSURL)
            .setResourceValue(["Unread", "Harbours"], forKey: .tagNamesKey)
        seen("0002.pdf", "0003.pdf")
        wait { row("0002.pdf")?.tags.year == nil && row("0003.pdf")?.tags.subjects.isEmpty == false }
        XCTAssertNil(row("0002.pdf")?.tags.year)
        wait { self.record("0002.pdf")?.retired == true }
        XCTAssertEqual(record("0002.pdf")?.retiredBy, FolderDateRecord.externalRetirement)
        XCTAssertEqual(record("0003.pdf")?.retired, false, "a subject added in Finder leaves the folder's date")

        try (folder.appendingPathComponent("0002.pdf") as NSURL)
            .setResourceValue(["Unread", "Harbours", "1966", "2 February"], forKey: .tagNamesKey)
        seen("0002.pdf")
        wait { row("0002.pdf")?.tags.year == 1966 }
        NavigationModel.folderDateRecordQueue.sync {}
        let retyped = try tags("0002.pdf")
        let kept = try XCTUnwrap(record("0002.pdf"))
        XCTAssertEqual(kept.retiredBy, FolderDateRecord.externalRetirement)
        XCTAssertNil(FolderDateRecord.evidence(kept, page: nil, tags: retyped), "the retyped date is the user's")

        // Taking the folder's date away leaves the user's date and takes the one the folder still gives.
        try setFolderDate(nil)
        let offer = try offered(model)
        let names = offer.paths.map { ($0 as NSString).lastPathComponent }
        XCTAssertTrue(names.contains("0003.pdf"), "\(names)")
        XCTAssertFalse(names.contains("0002.pdf"), "\(names)")
    }

    /// W49.reader-folder-date-undo-fu2 (review): a record the Reader retired that then sees its file's date changed in
    /// Finder is the user's for good, so the Undo of the change that retired it does not revive it.
    func testAFinderDateChangeOnARetiredRecordIsNotRevivedByUndo() throws {
        try makeFolder(date: "Feb. 1966")
        let model = fixtureNavigationModel(pinnedTo: root)
        wait { model.library.files.count >= 7 }
        try datedFromTheFolder(model)
        try setFolderDate(nil)
        model.applyFolderDating(try offered(model))
        wait { model.statusMessage.hasPrefix("Took ") }
        wait { self.record("0002.pdf")?.retired == true }
        let url = folder.appendingPathComponent("0002.pdf")
        func finder(_ tags: [String], year: Int?) throws {
            try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
            model.library.receiveWatchRequestForTesting(CorpusWatchRequest(paths: CorpusWatchPathSet([url.path])))
            wait { model.library.files.first { $0.path.hasSuffix("/0002.pdf") }?.tags.year == year }
            NavigationModel.folderDateRecordQueue.sync {}
        }
        try finder(["Unread", "Harbours", "1970"], year: 1970)
        XCTAssertEqual(record("0002.pdf")?.retiredBy, FolderDateRecord.externalRetirement)
        try finder(["Unread", "Harbours"], year: nil)

        model.undoLast()
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours", "1966", "2 February"])
        NavigationModel.folderDateRecordQueue.sync {}
        XCTAssertEqual(record("0002.pdf")?.retiredBy, FolderDateRecord.externalRetirement, "not revived")
    }

    /// W49.reader-folder-date-undo-fu: a stamp's or estimate's date the user deleted before the folder dated the file is
    /// not put back when the folder's date is taken away.
    func testADateDeletedBeforeTheFolderDatedTheFileIsNotPutBack() throws {
        try makeFolder(date: "Feb. 1966")
        try (folder.appendingPathComponent("0003.pdf") as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        let model = fixtureNavigationModel(pinnedTo: root)
        wait { model.library.files.count >= 7 }
        try datedFromTheFolder(model)
        XCTAssertNil(record("0003.pdf")?.replaced)
        try setFolderDate(nil)
        model.applyFolderDating(try offered(model))
        wait { model.statusMessage.hasPrefix("Took ") }
        XCTAssertEqual(try tagsOnDisk("0003.pdf"), ["Unread"], "not page 2's estimate")
    }

    /// W49.reader-folder-date-undo-fu: the Container section's Undo of a date edit offers as the edit did, and so
    /// does its Redo.
    func testContainerUndoAndRedoOfADateEditOffer() throws {
        try makeFolder(date: "Feb. 1966")
        let model = fixtureNavigationModel(pinnedTo: root)
        wait { model.library.files.count >= 7 }
        try datedFromTheFolder(model)
        let undo = UndoManager()
        undo.groupsByEvent = false
        let tree = try XCTUnwrap(model.containerTree)
        let edited = ([tree.path] + ["Box 3", "0002.pdf"]).joined(separator: "/")
        wait { !model.containerEditSaving }
        model.editContainerField(.date, .noneHere, forPath: edited, undo: undo)
        wait { model.folderDatingOffer != nil }
        let away = try XCTUnwrap(model.folderDatingOffer)
        XCTAssertNil(away.date)
        model.applyFolderDating(away)
        wait { model.statusMessage.hasPrefix("Took ") }
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours"])

        wait { !model.containerEditSaving }
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        wait { model.folderDatingOffer != nil }
        let back = try XCTUnwrap(model.folderDatingOffer, "Undo of None Here offers the folder's date again")
        XCTAssertNotNil(back.date)
        XCTAssertEqual(back.paths.map { ($0 as NSString).lastPathComponent }, ["0002.pdf", "0003.pdf", "0006.pdf"])
        model.applyFolderDating(back)
        wait { model.statusMessage.hasPrefix("Dated ") }
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours", "1966", "2 February"])
        XCTAssertEqual(try tagsOnDisk("0003.pdf"), ["Unread", "1966", "2 February"])

        wait { !model.containerEditSaving }
        model.folderDatingOffer = nil
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        wait { model.folderDatingOffer != nil }
        XCTAssertNil(try XCTUnwrap(model.folderDatingOffer, "Redo offers to take them away").date)
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
    /// W49.reader-set-selection-date-offer: a date set for a selection that makes several runs, in two folders, makes
    /// one offer for them all; it dates each run's documents in one ledger group (one Undo), and a folder whose date
    /// changed since the offer stops it everywhere.
    func testADateSetForASelectionOfSeveralRunsOffersThemAll() throws {
        try makeFolder(date: "1940s", source: .label)
        let other = root.appendingPathComponent("Box 4", isDirectory: true)
        try makeFolder(date: "1940s", source: .label, in: other)
        let model = fixtureNavigationModel(pinnedTo: root)
        wait { model.library.files.count >= 14 }
        let tree = try XCTUnwrap(model.containerTree)
        wait { model.containerCatalog.rootPath == tree.path }
        func path(_ dir: String, _ name: String) -> String { ([tree.path] + [dir, name]).joined(separator: "/") }
        // Box 3: two stretches (0002-0003, 0006), so two runs; Box 4: one.
        let selected = [path("Box 3", "0002.pdf"), path("Box 3", "0003.pdf"), path("Box 3", "0006.pdf"),
                        path("Box 4", "0002.pdf")]

        func offer(_ date: String) throws -> FolderDatingOffer {
            wait { !model.containerEditSaving }
            model.setContainerFieldForSelection(.date, date, paths: selected)
            wait { model.folderDatingOffer != nil }
            return try XCTUnwrap(model.folderDatingOffer, "a selection of several runs is offered; "
                                 + "\(model.containerEditError ?? "") \(model.statusMessage)")
        }
        let first = try offer("Feb. 1966")
        XCTAssertEqual(first.parts.map(\.directory), [["Box 3"], ["Box 3"], ["Box 4"]])
        XCTAssertEqual(first.parts.map(\.editedName), ["0002.pdf", "0006.pdf", "0002.pdf"])
        XCTAssertEqual(first.paths.map { (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent
                                          + "/" + ($0 as NSString).lastPathComponent },
                       ["Box 3/0002.pdf", "Box 3/0003.pdf", "Box 3/0006.pdf", "Box 4/0002.pdf"],
                       "each run's undated and estimated documents, none outside the selection")
        XCTAssertEqual(first.title, "Date 4 documents in 2 folders from their folders?")
        XCTAssertTrue(first.message.contains("“Box 3”, “Box 4”"), first.message)

        // Box 4's date changed between the offer and the answer: nothing is dated, in either folder.
        model.folderDatingOffer = nil
        let box4 = try XCTUnwrap(ContainerFileStore.load(directory: other).document)
        var runs = box4.runs
        let i = try XCTUnwrap(runs.firstIndex { $0.start == "0002.pdf" })
        runs[i] = ContainerRun(start: "0002.pdf", level: .folder,
                               fields: ContainerFieldSet([.date: ContainerValue("1970", source: .user, at: now)]))
        guard case let .loaded(_, stamp4) = ContainerFileStore.load(directory: other) else { return XCTFail("Box 4") }
        try ContainerFileStore.write(ContainerFile(runs: runs), directory: other, expecting: stamp4)
        model.applyFolderDating(first)
        wait { model.itemFieldEditError != nil }
        XCTAssertEqual(model.itemFieldEditError?.contains("changed since it was offered"), true,
                       model.itemFieldEditError ?? "")
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours"])
        XCTAssertNil(ContainerFileStore.loadItemFields(directory: folder).document?.dateRecord(for: "0002.pdf"))

        let offered = try offer("Feb. 1966")
        XCTAssertEqual(offered.paths.count, 4)
        let depth = model.undoDepth
        model.applyFolderDating(offered)
        wait { model.statusMessage.hasPrefix("Dated ") }
        XCTAssertTrue(model.statusMessage.hasPrefix("Dated 4 documents"), model.statusMessage)
        XCTAssertTrue(model.statusMessage.contains("from the folders"), model.statusMessage)
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours", "1966", "2 February"])
        XCTAssertEqual(try tagsOnDisk("0003.pdf"), ["Unread", "1966", "2 February"])
        XCTAssertEqual(try tagsOnDisk("0006.pdf"), ["Unread", "1966", "2 February"])
        XCTAssertEqual(try tagsOnDisk("0002.pdf", in: other), ["Unread", "Harbours", "1966", "2 February"])
        XCTAssertEqual(try tagsOnDisk("0003.pdf", in: other), ["Unread", "1958", "Date Uncertain"], "not selected")
        XCTAssertEqual(try tagsOnDisk("0006.pdf", in: other), ["Unread"], "not selected")
        let fields = try XCTUnwrap(ContainerFileStore.loadItemFields(directory: folder).document)
        XCTAssertEqual(fields.dateRecord(for: "0006.pdf")?.evidence, "folder; from 0006.pdf; \"Feb. 1966\"; gave 1966-02",
                       "each run's record names its own start")
        XCTAssertNotNil(ContainerFileStore.loadItemFields(directory: other).document?.dateRecord(for: "0002.pdf"))

        XCTAssertEqual(model.undoDepth, depth + 1, "one Undo")
        model.undoLast()
        XCTAssertEqual(try tagsOnDisk("0002.pdf"), ["Unread", "Harbours"])
        XCTAssertEqual(try tagsOnDisk("0003.pdf"), ["Unread", "1958", "Date Uncertain"])
        XCTAssertEqual(try tagsOnDisk("0006.pdf"), ["Unread"])
        XCTAssertEqual(try tagsOnDisk("0002.pdf", in: other), ["Unread", "Harbours"])
    }
    /// An offer whose runs take different dates, or where some take the folder's dates away (an Undo across runs),
    /// names every date and says each file takes its own folder's, and asks to update rather than date.
    func testAnOfferOfSeveralDatesAndAnUndatingSaysSo() throws {
        let a = try XCTUnwrap(ContainerFolderDate.parse("1950", start: "0001.pdf"))
        let b = try XCTUnwrap(ContainerFolderDate.parse("1962", start: "0005.pdf"))
        func part(_ date: ContainerFolderDate?, _ dir: String, _ names: [String]) -> FolderDatingOffer.Part {
            .init(date: date, directory: [dir], editedName: names[0], paths: names.map { "/t/\(dir)/\($0)" },
                  recorded: date == nil ? [] : names.map { "/t/\(dir)/\($0)" })
        }
        let two = FolderDatingOffer(parts: [part(a, "Box 3", ["0002.pdf"]), part(b, "Box 3", ["0006.pdf", "0007.pdf"])],
                                    treePath: "/t", evidence: [:], window: nil)
        XCTAssertEqual(two.title, "Date 3 documents in “Box 3” from the folder?")
        XCTAssertTrue(two.message.hasPrefix("The folders are dated “1950”, “1962”."), two.message)
        XCTAssertTrue(two.message.contains("each would take its own folder's date"), two.message)
        XCTAssertFalse(two.message.contains("would be dated 1950"), two.message)
        XCTAssertEqual(two.confirmTitle, "Date 3 Documents")

        let mixed = FolderDatingOffer(parts: [part(a, "Box 3", ["0002.pdf"]), part(nil, "Box 4", ["0003.pdf"])],
                                      treePath: "/t", evidence: [:], window: nil)
        XCTAssertEqual(mixed.title, "Update 2 documents in 2 folders from their folders?")
        XCTAssertTrue(mixed.message.contains("would be dated 1950"), mixed.message)
        XCTAssertTrue(mixed.message.contains("1 document dated from a folder that no longer gives a date goes back"),
                      mixed.message)
        XCTAssertEqual(mixed.confirmTitle, "Update 2 Documents")
        XCTAssertEqual(mixed.done(2), "Updated 2 documents from their folders")
    }
}
