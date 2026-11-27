import XCTest
import ArchiveCore
import ArchiveCoreUI
@testable import ArchiveReader

/// W40.tag-window-reader (Tier-2: a write to every file carrying a tag, and a record in the archive). Window ▸ Tags
/// over the Reader's library: its list is the main archive's tags, the suite's own apart; rename, merge and remove go
/// through `TagWriter.applyPlan` on each file's fresh read as one Undo; each is recorded for the other apps, one entry
/// per tag, withdrawn by its Undo and restored by its Redo, in catalogue mode too; another app's remove is offered and
/// applied. Scratch `mktemp` roots and a scratch ledger only, never the corpus.
@MainActor
final class TagsWindowReaderTests: XCTestCase {

    private var ledgerURL: URL!
    private var savedLedgerURL: URL!
    private var suite: String!

    override func setUp() async throws {
        try await super.setUp()
        savedLedgerURL = AuditLedger.shared.fileURL
        ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TagsWindowReaderTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("audit-ledger.jsonl")
        AuditLedger.shared.fileURL = ledgerURL
        suite = "TagsWindowReaderTests-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        AuditLedger.shared.fileURL = savedLedgerURL
        try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent())
        UserDefaults().removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    /// a: Lincoln, Slavery · b: lincoln · c: Lincoln, Douglass · d: Douglass, Red. With a durable root marker.
    private func makeRoot() throws -> (root: URL, files: [URL]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TagsWindowReaderTests-root-\(UUID().uuidString)", isDirectory: true)
        let box = root.appendingPathComponent("Box", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        _ = try RootMarker.ensure(at: root, kind: .reader, name: "Scratch")
        let tags = [["Unread", "Lincoln", "Slavery"], ["Unread", "lincoln"], ["Read", "Lincoln", "Douglass"],
                    ["Unread", "Douglass", "Red"]]
        let files = try zip(["a.pdf", "b.pdf", "c.pdf", "d.pdf"], tags).map { name, t -> URL in
            let url = box.appendingPathComponent(name)
            try Data("scratch PDF \(name)".utf8).write(to: url)
            try (url as NSURL).setResourceValue(t, forKey: .tagNamesKey)
            return url
        }
        return (root, files)
    }

    private func loadedModel(_ root: URL, _ testName: String = #function) async throws -> NavigationModel {
        let model = fixtureNavigationModel(pinnedTo: root, testName)
        model.tagChangeDefaultsSuite = suite
        try await waitUntil("library loaded") { !model.allSubjects.isEmpty }
        return model
    }

    /// The window's list, once built off the main actor, following the library as when the window shows.
    private func window(_ model: NavigationModel) async throws -> TagsWindowModel {
        let window = model.tagsWindow
        model.tagsWindowShown(true)
        try await waitUntil("the list was built") { !window.inventory.subjects.isEmpty }
        return window
    }

    private func tags(_ url: URL) -> Set<String> {
        Set((try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [])
    }

    private func log(_ root: URL) -> [TagChange] { TagChangeLog.load(root: root).document?.changes ?? [] }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), what)
    }

    /// Undo and Redo report on the main actor; wait for the reversal to have reached the disk.
    private func undo(_ model: NavigationModel, redo: Bool = false) async {
        await withCheckedContinuation { done in
            if redo { model.redoLast { done.resume() } } else { model.undoLast { done.resume() } }
        }
    }

    // MARK: The list

    func testTheListIsTheLibrarysSubjectsByIdentityWithTheSuitesOwnTagsApart() async throws {
        let fixture = try makeRoot()
        let model = try await loadedModel(fixture.root)
        let window = try await window(model)
        XCTAssertEqual(window.inventory.subjects.map(\.name), ["Douglass", "Lincoln", "Slavery"])
        let lincoln = try XCTUnwrap(window.inventory.entry(for: "LINCOLN"))
        XCTAssertEqual(lincoln.itemCount, 3, "case variants are one tag")
        XCTAssertEqual(lincoln.spellings.map(\.tag), ["Lincoln", "lincoln"])
        XCTAssertEqual(Set(window.suiteTokens.map(\.name)), ["Unread", "Read", "Red"])
        XCTAssertEqual(window.noun, .file)

        // A change to the library reaches the list.
        let d = try XCTUnwrap(model.library.files.first { $0.url.path == fixture.files[3].path })
        model.applyEdit(.addSubject("Emancipation"), to: d)
        try await waitUntil("the new tag is listed") { window.inventory.entry(for: "Emancipation") != nil }
    }

    // MARK: Changes

    func testARenameThroughTheWindowIsOneUndoAndIsRecordedWithItsGroup() async throws {
        let fixture = try makeRoot()
        let model = try await loadedModel(fixture.root)
        let window = try await window(model)
        let plan = try XCTUnwrap(window.renamePlan(try XCTUnwrap(window.inventory.entry(for: "Lincoln")),
                                                   to: "Abraham Lincoln"))
        let outcome = await window.perform(plan)
        XCTAssertEqual(outcome, .init(changed: 3, failed: 0))
        XCTAssertEqual(tags(fixture.files[1]), ["Unread", "Abraham Lincoln"])
        XCTAssertEqual(tags(fixture.files[0]), ["Unread", "Abraham Lincoln", "Slavery"], "the rest stay")
        XCTAssertEqual(window.status, "Renamed “Lincoln” to “Abraham Lincoln” on 3 files.")
        XCTAssertEqual(model.undoDepth, 1, "one Undo step")
        try await waitUntil("recorded") { log(fixture.root).count == 1 }
        XCTAssertEqual(log(fixture.root).first?.id, AuditLedger.shared.entries().first?.group)

        try await waitUntil("the list follows the rename") { window.inventory.entry(for: "Abraham Lincoln") != nil }

        await undo(model)
        XCTAssertEqual(tags(fixture.files[1]), ["Unread", "lincoln"])
        try await waitUntil("withdrawn by Undo") { log(fixture.root).first?.withdrawn == true }
        // The list follows the Undo too (the library bumps its revision before it replaces the rows).
        try await waitUntil("the list follows the Undo") {
            window.inventory.entry(for: "Abraham Lincoln") == nil && window.inventory.entry(for: "Lincoln")?.itemCount == 3
        }
        await undo(model, redo: true)
        XCTAssertEqual(tags(fixture.files[1]), ["Unread", "Abraham Lincoln"])
        try await waitUntil("restored by Redo") { log(fixture.root).first?.withdrawn == false }
    }

    func testAMergeIsOneUndoAndRecordsOneEntryPerTagAllWithdrawnByItsUndo() async throws {
        let fixture = try makeRoot()
        let model = try await loadedModel(fixture.root)
        let window = try await window(model)
        let entries = ["Lincoln", "Douglass"].compactMap { window.inventory.entry(for: $0) }
        let plan = try XCTUnwrap(window.mergePlan(entries, into: "Abolition"))
        let outcome = await window.perform(plan)
        XCTAssertEqual(outcome, .init(changed: 4, failed: 0))
        XCTAssertEqual(tags(fixture.files[2]), ["Read", "Abolition"], "one target where the first source stood")
        XCTAssertEqual(tags(fixture.files[3]), ["Unread", "Abolition", "Red"], "the colour token never moves")
        XCTAssertEqual(model.undoDepth, 1)
        try await waitUntil("recorded") { log(fixture.root).count == 2 }
        XCTAssertEqual(Set(log(fixture.root).map(\.from)), ["Lincoln", "Douglass"])
        XCTAssertEqual(Set(log(fixture.root).map(\.to)), ["Abolition"])

        await undo(model)
        XCTAssertEqual(tags(fixture.files[2]), ["Read", "Lincoln", "Douglass"])
        try await waitUntil("both withdrawn") { log(fixture.root).allSatisfy(\.withdrawn) }
        await undo(model, redo: true)
        try await waitUntil("both restored") { log(fixture.root).allSatisfy { !$0.withdrawn } }
    }

    func testARemoveTakesTheTagOffEveryFileAndIsRecordedAsARemove() async throws {
        let fixture = try makeRoot()
        let model = try await loadedModel(fixture.root)
        let window = try await window(model)
        let plan = try XCTUnwrap(window.removePlan([try XCTUnwrap(window.inventory.entry(for: "Lincoln"))]))
        XCTAssertEqual(plan.itemCount, 3)
        let outcome = await window.perform(plan)
        XCTAssertEqual(outcome, .init(changed: 3, failed: 0))
        XCTAssertEqual(tags(fixture.files[0]), ["Unread", "Slavery"])
        XCTAssertEqual(tags(fixture.files[1]), ["Unread"])
        XCTAssertEqual(tags(fixture.files[3]), ["Unread", "Douglass", "Red"], "a file without it is untouched")
        XCTAssertEqual(window.status, "Removed “Lincoln” from 3 files.")
        try await waitUntil("recorded") { log(fixture.root).count == 1 }
        let entry = try XCTUnwrap(log(fixture.root).first)
        XCTAssertTrue(entry.isRemoval)
        XCTAssertEqual(entry.from, "Lincoln")

        await undo(model)
        XCTAssertEqual(tags(fixture.files[1]), ["Unread", "lincoln"], "put back in its own spelling")
        XCTAssertEqual(tags(fixture.files[0]), ["Unread", "Lincoln", "Slavery"])
        try await waitUntil("withdrawn") { log(fixture.root).first?.withdrawn == true }
    }

    func testAPlanIsMadeOnEachFilesFreshTagsSoATagAddedSinceIsKept() async throws {
        let fixture = try makeRoot()
        let model = try await loadedModel(fixture.root)
        let window = try await window(model)
        let plan = try XCTUnwrap(window.renamePlan(try XCTUnwrap(window.inventory.entry(for: "Slavery")), to: "Bondage"))
        // Another writer adds a tag to the file after the window listed it.
        try (fixture.files[0] as NSURL).setResourceValue(["Unread", "Lincoln", "Slavery", "Added Since"],
                                                         forKey: .tagNamesKey)
        _ = await window.perform(plan)
        XCTAssertEqual(tags(fixture.files[0]), ["Unread", "Lincoln", "Bondage", "Added Since"])
    }

    func testAnotherAppsRemoveIsOfferedAndAppliedAsOneUndoWithoutBeingRecordedAgain() async throws {
        let fixture = try makeRoot()
        let model = try await loadedModel(fixture.root)
        let removal = TagChange(app: TagChangeLog.notes, from: "Douglass", to: "")
        try TagChangeLog.record([removal], root: fixture.root)
        await model.refreshTagChangeInbox()
        let offer = try XCTUnwrap(model.tagChangeOffers.first)
        XCTAssertEqual(offer.count, 2)
        XCTAssertTrue(offer.summary.hasPrefix("Notes removed “Douglass” from its items"), offer.summary)

        model.applyTagChange(offer)
        try await waitUntil("applied") { model.tagChangeOffers.isEmpty }
        XCTAssertEqual(tags(fixture.files[2]), ["Read", "Lincoln"])
        XCTAssertEqual(tags(fixture.files[3]), ["Unread", "Red"])
        XCTAssertEqual(model.undoDepth, 1)
        await model.refreshTagChangeInbox()
        XCTAssertEqual(log(fixture.root).count, 1, "applying it records nothing new")
        XCTAssertTrue(model.tagChangeOffers.isEmpty, "handled")

        try TagChangeLog.setWithdrawn([removal.id], true, root: fixture.root)
        await model.refreshTagChangeInbox()
        let notice = try XCTUnwrap(model.tagChangeOffers.first)
        XCTAssertTrue(notice.isWithdrawal && notice.summary.contains("undid removing"), notice.summary)
    }

    func testShowFilesFiltersTheListToTheTag() async throws {
        let fixture = try makeRoot()
        let model = try await loadedModel(fixture.root)
        model.showFiles(withTag: "Douglass")
        model.filterOrSortChanged()   // the navigation window's onChange(of: filter) does this in the app
        try await waitUntil("filtered") { model.displayed.count == 2 }
        XCTAssertEqual(Set(model.displayed.map(\.url.lastPathComponent)), ["c.pdf", "d.pdf"])
        // Asked for before the list is built (the window just opening): selected once it is.
        XCTAssertNil(model.tagsWindowModel)
        model.showTagInTagsWindow("douglass")
        let window = try await window(model)
        try await waitUntil("selected once built") { window.selection == [tagKey("Douglass")] }
        XCTAssertEqual(window.search, "Douglass")
        model.showSimilarInTagsWindow()
        XCTAssertTrue(window.similarOnly)
        XCTAssertEqual(window.search, "")
    }

    // MARK: Catalogue mode

    /// In catalogue mode a change edits the companions' subjects through the journal, and the journal's Undo and Redo
    /// withdraw and restore its recorded entry (the limit W40.tag-rename-suite left in KNOWN_ISSUES).
    func testInCatalogueModeTheJournalsUndoWithdrawsTheRecordedChange() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagsWindowReaderTests-catalogue-\(UUID())", isDirectory: true).resolvingSymlinksInPath()
        let root = folder.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        _ = try RootMarker.ensure(at: root, kind: .reader, name: "Scratch")
        let identity = CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID())
        let page = UUID(), document = UUID()
        let packet = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            </rdf:RDF></x:xmpmeta>
            """.utf8)
        try writePDF(at: root.appendingPathComponent("Letter.pdf"), metadata: XCTUnwrap(identity.adding(to: packet)))
        try Data("""
            {"schema":1,"fileID":"\(identity.fileID)","contentRevision":"\(identity.contentRevision)",
             "revision":"\(UUID())","parents":[],
             "pages":[{"id":"\(page)","physicalIndex":0,"documentID":"\(document)","role":"searchable"}],
             "documents":[{"id":"\(document)","ownerFileID":"\(identity.fileID)","fields":{}}],"fileFields":{}}
            """.utf8).write(to: root.appendingPathComponent("Letter.pdf.archivesuite.json"))

        let defaults = fixtureDefaults()
        let indexer = ContentIndexer(url: folder.appendingPathComponent("index.sqlite"))
        let model = NavigationModel(defaults: defaults, indexer: indexer, thumbnailer: nil)
        model.tagChangeDefaultsSuite = suite
        XCTAssertNil(model.rootStore.setRoot(root))
        let key = try XCTUnwrap(ReaderRootIdentity.legacyCatalogueKey(for: root))
        defaults.set(UUID().uuidString, forKey: key)
        defaults.set(true, forKey: key + ".enabled")
        model.startLibrary(root)
        try await waitUntil("catalogue mode") {
            model.library.usesCatalogue && model.catalogueReader != nil && model.library.files.first?.isCatalogue == true
        }
        XCTAssertNotNil(model.tagChangeRoot)
        let path = try XCTUnwrap(model.library.files.first).path
        model.applyEdit(.addSubject("Lincoln"), paths: [path])
        try await waitUntil("subject saved") { model.library.files.first?.subjects == ["Lincoln"] && !model.catalogueEditSaving }

        let window = try await window(model)
        let plan = try XCTUnwrap(window.renamePlan(try XCTUnwrap(window.inventory.entry(for: "Lincoln")), to: "Emancipation"))
        let outcome = await window.perform(plan)
        XCTAssertEqual(outcome?.changed, 1)
        try await waitUntil("renamed") { model.library.files.first?.subjects == ["Emancipation"] }
        try await waitUntil("recorded") { log(root).count == 1 }
        XCTAssertEqual(log(root).first?.from, "Lincoln")

        model.reverseCatalogueEdit(redo: false)
        try await waitUntil("undone") { model.library.files.first?.subjects == ["Lincoln"] && !model.catalogueEditSaving }
        try await waitUntil("withdrawn by the journal's Undo") { log(root).first?.withdrawn == true }
        model.reverseCatalogueEdit(redo: true)
        try await waitUntil("redone") { model.library.files.first?.subjects == ["Emancipation"] && !model.catalogueEditSaving }
        try await waitUntil("restored by its Redo") { log(root).first?.withdrawn == false }
    }

    /// A PDF whose companion holds two documents, each carrying the tag, is changed in both by one rename (the window
    /// counts a PDF's subjects from all its documents), as one journal operation: its Undo restores both and withdraws
    /// the recorded entry, and its Redo restores the entry (W40.tag-window-reader-multidoc).
    func testInCatalogueModeAChangeReachesEveryDocumentOfAPDFAsOneUndo() async throws {
        let (root, model, perDocument) = try await multiDocumentLibrary()
        let window = try await window(model)
        let plan = try XCTUnwrap(window.renamePlan(try XCTUnwrap(window.inventory.entry(for: "Lincoln")), to: "Emancipation"))
        let outcome = await window.perform(plan)
        XCTAssertEqual(outcome?.changed, 1, "one catalogue record, both its documents")
        XCTAssertEqual(outcome?.failed, 0)
        try await waitUntil("renamed in both documents") {
            perDocument() == [["Emancipation"], ["War", "Emancipation"]] && !model.catalogueEditSaving
        }
        try await waitUntil("recorded") { log(root).count == 1 }

        model.reverseCatalogueEdit(redo: false)
        try await waitUntil("both undone by one Undo") {
            perDocument() == [["Lincoln"], ["War", "lincoln"]] && !model.catalogueEditSaving
        }
        try await waitUntil("withdrawn by the journal's Undo") { log(root).first?.withdrawn == true }
        model.reverseCatalogueEdit(redo: true)
        try await waitUntil("both redone") {
            perDocument() == [["Emancipation"], ["War", "Emancipation"]] && !model.catalogueEditSaving
        }
        try await waitUntil("restored by its Redo") { log(root).first?.withdrawn == false }

        // A remove takes the tag off both; a document without it is left as it was.
        try await waitUntil("the list follows") { window.inventory.entry(for: "Emancipation") != nil }
        let remove = try XCTUnwrap(window.removePlan([try XCTUnwrap(window.inventory.entry(for: "Emancipation"))]))
        let removed = await window.perform(remove)
        XCTAssertEqual(removed?.changed, 1)
        try await waitUntil("removed from both documents") {
            perDocument() == [[], ["War"]] && !model.catalogueEditSaving
        }
    }

    /// One PDF in catalogue mode whose companion holds two documents (a page each), subjects ["Lincoln"] and
    /// ["War", "lincoln"]; `perDocument` reads each document's subjects from the library, in page order.
    private func multiDocumentLibrary() async throws -> (root: URL, model: NavigationModel, perDocument: () -> [[String]]) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagsWindowReaderTests-multidoc-\(UUID())", isDirectory: true).resolvingSymlinksInPath()
        let root = folder.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        _ = try RootMarker.ensure(at: root, kind: .reader, name: "Scratch")
        let identity = CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID())
        let pages = (UUID(), UUID()), documents = (UUID(), UUID())
        let packet = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            </rdf:RDF></x:xmpmeta>
            """.utf8)
        try writePDF(at: root.appendingPathComponent("Letters.pdf"), metadata: XCTUnwrap(identity.adding(to: packet)),
                     pages: 2)
        func subjects(_ values: String) -> String {
            #"{"subjects":{"state":"value","value":\#(values),"fieldRevision":"\#(UUID())","origin":"user"}}"#
        }
        try Data("""
            {"schema":1,"fileID":"\(identity.fileID)","contentRevision":"\(identity.contentRevision)",
             "revision":"\(UUID())","parents":[],
             "pages":[{"id":"\(pages.0)","physicalIndex":0,"documentID":"\(documents.0)","role":"searchable"},
                      {"id":"\(pages.1)","physicalIndex":1,"documentID":"\(documents.1)","role":"searchable"}],
             "documents":[{"id":"\(documents.0)","ownerFileID":"\(identity.fileID)","fields":\(subjects(#"["Lincoln"]"#))},
                          {"id":"\(documents.1)","ownerFileID":"\(identity.fileID)",
                           "fields":\(subjects(#"["War","lincoln"]"#))}],"fileFields":{}}
            """.utf8).write(to: root.appendingPathComponent("Letters.pdf.archivesuite.json"))

        let defaults = fixtureDefaults()
        let indexer = ContentIndexer(url: folder.appendingPathComponent("index.sqlite"))
        let model = NavigationModel(defaults: defaults, indexer: indexer, thumbnailer: nil)
        model.tagChangeDefaultsSuite = suite
        XCTAssertNil(model.rootStore.setRoot(root))
        let key = try XCTUnwrap(ReaderRootIdentity.legacyCatalogueKey(for: root))
        defaults.set(UUID().uuidString, forKey: key)
        defaults.set(true, forKey: key + ".enabled")
        model.startLibrary(root)
        // Each document's subjects, in page order.
        func perDocument() -> [[String]] {
            (model.library.files.first?.catalogueDocuments ?? []).map {
                (try? $0.document.get())?.document.fields?.subjects?.readerValue ?? []
            }
        }
        try await waitUntil("catalogue mode") {
            model.library.usesCatalogue && model.catalogueReader != nil && perDocument().count == 2
        }
        XCTAssertEqual(perDocument(), [["Lincoln"], ["War", "lincoln"]])
        return (root, model, perDocument)
    }


    /// Another app's rename, applied here, also reaches both documents, and the offer is settled.
    func testInCatalogueModeAnotherAppsRenameReachesEveryDocumentOfAPDF() async throws {
        let (root, model, perDocument) = try await multiDocumentLibrary()
        try TagChangeLog.record([TagChange(app: TagChangeLog.notes, from: "Lincoln", to: "Emancipation")], root: root)
        await model.refreshTagChangeInbox()
        let offer = try XCTUnwrap(model.tagChangeOffers.first)
        model.applyTagChange(offer)
        try await waitUntil("applied to both documents") {
            perDocument() == [["Emancipation"], ["War", "Emancipation"]] && !model.catalogueEditSaving
        }
        try await waitUntil("settled") { model.tagChangeOffers.isEmpty }
        await model.refreshTagChangeInbox()
        XCTAssertTrue(model.tagChangeOffers.isEmpty, "handled")
        XCTAssertEqual(log(root).count, 1, "applying it records nothing new")
    }

    private func writePDF(at url: URL, metadata: Data?, pages: Int = 1) throws {
        var bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        if let metadata { pdf.addDocumentMetadata(metadata as CFData) }
        for _ in 0..<pages {
            pdf.beginPDFPage(nil)
            pdf.fill(bounds.insetBy(dx: 10, dy: 10))
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    // MARK: Corpus size

    /// The list at the corpus's size (116k files, ~7,000 subjects in several spellings each; in memory, no disk):
    /// the inventory build (off the main actor), the window's update with its Find Similar groups and the sorted
    /// rows (on it), and a change's main-actor selection of the files to write. Prints `TAGSWINDOW` lines; the
    /// budgets are generous ceilings for the Debug build, so a regression by an order of magnitude fails.
    func testTheListAndAChangeAtCorpusSize() throws {
        let root = "/scratch/at-size/MAIN"
        let words = (0..<7_000).map { "Subject \($0 / 26) \(UnicodeScalar(UInt8(65 + $0 % 26)))" }
        var files: [ArchiveFile] = []
        files.reserveCapacity(116_000)
        for i in 0..<116_000 {
            var raw = ["Unread", "Q\(i % 5 + 1)"]
            for k in 0..<4 { raw.append(words[(i &* 31 &+ k &* 977) % words.count]) }
            if i % 10 == 0 { raw.append(words[i % words.count].lowercased()) }   // a variant spelling
            let url = URL(fileURLWithPath: "\(root)/Box \(i / 500)/\(i).pdf")
            files.append(ArchiveFile(url: url, name: url.lastPathComponent, fileType: "PDF",
                                     tags: DocumentTags.parse(raw: raw, labelNumber: nil), contentModified: nil))
        }

        let clock = ContinuousClock()
        var inventory = TagInventory(items: [])
        let build = clock.measure {
            inventory = NavigationModel.tagInventory(files, catalogue: false, mainRoot: root)
        }
        XCTAssertEqual(inventory.items.count, 116_000)
        XCTAssertGreaterThan(inventory.subjects.count, 6_000)
        var clusters: [[TagInventory.Entry]] = []
        let similar = clock.measure { clusters = inventory.similarClusters() }   // off the main actor in the app
        var window: TagsWindowModel!
        let update = clock.measure {
            window = TagsWindowModel(inventory: TagInventory(items: []), noun: .file) { _ in .init(changed: 0) }
            window.update(inventory, similarClusters: clusters)
        }
        var rows = 0
        let list = clock.measure { rows = window.rows.count }
        XCTAssertEqual(rows, inventory.subjects.count)
        window.similarOnly = true
        var similarRows = 0
        let similarList = clock.measure { similarRows = window.rows.count }
        XCTAssertGreaterThan(similarRows, 0)
        let entry = try XCTUnwrap(inventory.subjects.max { $0.itemCount < $1.itemCount })
        var plan: TagChangePlan?
        let planning = clock.measure { plan = inventory.renamePlan(entry.name, to: "Renamed Subject") }
        let keys = try XCTUnwrap(plan).sourceKeys
        let listed = Set(try XCTUnwrap(plan).itemIDs)
        var selected = 0
        let select = clock.measure {
            selected = files.filter { (listed.contains($0.path) || !$0.subjectKeys.isDisjoint(with: keys))
                && ReaderArchiveLayout.isContained($0.url, inRootPath: root) }.count
        }
        XCTAssertEqual(selected, entry.itemCount)
        print("TAGSWINDOW build=\(build) similar=\(similar) update=\(update) rows=\(list) similarRows=\(similarList) "
              + "plan=\(planning) select=\(select) subjects=\(inventory.subjects.count) carriers=\(selected)")
        XCTAssertLessThan(build, .seconds(20))
        XCTAssertLessThan(similar, .seconds(30))
        XCTAssertLessThan(update, .seconds(1), "on the main actor")
        XCTAssertLessThan(list + similarList, .seconds(2), "on the main actor, each time the list draws")
        XCTAssertLessThan(planning + select, .seconds(5))
    }
}
