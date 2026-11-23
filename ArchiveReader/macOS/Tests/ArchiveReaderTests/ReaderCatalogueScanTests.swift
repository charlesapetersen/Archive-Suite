import ArchiveCore
import CoreGraphics
import XCTest
@testable import ArchiveReader

final class ReaderCatalogueScanTests: XCTestCase {
    func testAllPDFsAreMembersAndOnlyVerifiedCompanionsSupplyFacets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-catalogue-\(UUID())", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileID = UUID(), contentID = UUID(), documentID = UUID()
        let packet = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"></rdf:RDF></x:xmpmeta>
            """.utf8)
        let identity = CataloguePDFIdentity(fileID: fileID, contentRevision: contentID)
        let metadata = try XCTUnwrap(identity.adding(to: packet))
        let paired = root.appendingPathComponent("Paired.pdf")
        let plain = root.appendingPathComponent("Plain.pdf")
        try writePDF(at: paired, metadata: metadata)
        try writePDF(at: plain, metadata: nil)
        let companion = root.appendingPathComponent("Paired.pdf.archivesuite.json")
        try Data("""
            {"schema":1,"fileID":"\(fileID)","contentRevision":"\(contentID)","revision":"\(UUID())",
             "parents":[],"pages":[{"id":"\(UUID())","physicalIndex":0,"documentID":"\(documentID)","role":"searchable"}],
             "documents":[{"id":"\(documentID)","ownerFileID":"\(fileID)","fields":{
               "subjects":{"state":"value","value":["Read","1957"],"fieldRevision":"\(UUID())","origin":"user"},
               "documentDate":{"state":"value","value":{"date":"1958-04","uncertain":true},
                               "fieldRevision":"\(UUID())","origin":"user"}
             }}],
             "fileFields":{"readState":{"state":"value","value":"unread","fieldRevision":"\(UUID())","origin":"user"}}}
            """.utf8).write(to: companion)
        let before = try Data(contentsOf: paired)

        let instance = UUID()
        let pass = ReaderCatalogueScan.run(root: root, instance: instance, isCancelled: { false }, onProgress: { _ in })
        XCTAssertEqual(pass.rows.map(\.name), ["Paired.pdf", "Plain.pdf"])
        let first = try XCTUnwrap(pass.rows.first)
        XCTAssertEqual(first.subjects, ["Read", "1957"])
        XCTAssertEqual(first.readState, .unread)
        XCTAssertEqual(first.tags.ownSortDate, 19580400)
        XCTAssertTrue(first.dateIsSpeculative)
        XCTAssertNil(pass.rows.last?.readState)
        XCTAssertThrowsError(try pass.rows.last?.catalogueFacts?.file.get())

        try FileManager.default.removeItem(at: companion)
        let refreshed = ReaderCatalogueScan.run(root: root, instance: instance, isCancelled: { false }, onProgress: { _ in })
        XCTAssertEqual(refreshed.rows.map(\.name), ["Paired.pdf", "Plain.pdf"])
        XCTAssertEqual(refreshed.rows.first?.subjects, [])
        XCTAssertNil(refreshed.rows.first?.readState)
        XCTAssertEqual(try Data(contentsOf: paired), before)
    }

    func testMergedFileRulesStayOnOneDocumentAndRefuseStaleSearchHits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-catalogue-merged-\(UUID())", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let identity = CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID())
        let packet = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            </rdf:RDF></x:xmpmeta>
            """.utf8)
        let pdf = root.appendingPathComponent("Merged.pdf")
        try writePDF(at: pdf, metadata: XCTUnwrap(identity.adding(to: packet)), pageCount: 2)
        let documents = [(UUID(), "1901", "Private letter"), (UUID(), "1958", "Public speech")]
        let pages = documents.enumerated().map { number, document in
            ["id": UUID().uuidString, "physicalIndex": number, "documentID": document.0.uuidString,
             "role": "searchable"] as [String: Any]
        }
        let records = documents.map { document in
            ["id": document.0.uuidString, "ownerFileID": identity.fileID.uuidString,
             "fields": [
                "documentDate": ["state": "value", "value": ["date": document.1, "uncertain": false],
                                 "fieldRevision": UUID().uuidString, "origin": "user"],
                "subjects": ["state": "value", "value": [document.2], "fieldRevision": UUID().uuidString, "origin": "user"]
             ]] as [String: Any]
        }
        let bytes = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "fileID": identity.fileID.uuidString, "contentRevision": identity.contentRevision.uuidString,
            "revision": UUID().uuidString, "parents": [], "pages": pages, "documents": records, "fileFields": [:]
        ])
        try bytes.write(to: root.appendingPathComponent("Merged.pdf.archivesuite.json"))

        let pass = ReaderCatalogueScan.run(root: root, instance: UUID(), isCancelled: { false }, onProgress: { _ in })
        let file = try XCTUnwrap(pass.rows.first)
        var filter = LibraryFilter(subjects: ["Private letter"], dateFromYear: 1958, dateToYear: 1958)
        XCTAssertFalse(filter.matches(file))
        filter.subjects = ["Public speech"]
        XCTAssertTrue(filter.matches(file))
        filter.read = .noReadState
        XCTAssertFalse(filter.matches(file), "An unassessed field cannot satisfy a negative rule.")

        var rule = SearchRule(field: .catalogueFields)
        rule.text = "Private"
        var date = SearchRule(field: .date, op: .between)
        date.text = "1958"
        date.text2 = "1958"
        let search = AdvancedSearch(rules: [rule, date]).prepared()
        let digest = try XCTUnwrap(file.catalogueFacts?.file.get().revision.companionSHA256)
        var context = RuleContext(catalogueHits: [rule.id: [UTF8Key(file.path): [documents[0].0: digest]]])
        XCTAssertFalse(search.matchesPrepared(file, context), "A date in the other document is not a match.")
        context.catalogueHits[rule.id]?[UTF8Key(file.path)] = [documents[1].0: Data([0])]
        XCTAssertFalse(search.matchesPrepared(file, context), "An old digest is not a current field match.")
        context.catalogueHits[rule.id]?[UTF8Key(file.path)] = [documents[1].0: digest]
        XCTAssertTrue(search.matchesPrepared(file, context))
    }

    @MainActor
    func testMovedCatalogueKeepsItsInstanceAndFactsButCopyCannotUseItsRepairEvidence() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-catalogue-move-\(UUID())", isDirectory: true).resolvingSymlinksInPath()
        let original = folder.appendingPathComponent("Original", isDirectory: true)
        let moved = folder.appendingPathComponent("Moved", isDirectory: true)
        let copy = folder.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let pdf = original.appendingPathComponent("Letter.pdf")
        let sidecar = original.appendingPathComponent("Letter.pdf.archivesuite.json")
        let identity = CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID())
        let page = UUID(), document = UUID()
        let packet = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            </rdf:RDF></x:xmpmeta>
            """.utf8)
        try writePDF(at: pdf, metadata: XCTUnwrap(identity.adding(to: packet)))
        let originalPDF = try Data(contentsOf: pdf)
        try Data("""
            {"schema":1,"fileID":"\(identity.fileID)","contentRevision":"\(identity.contentRevision)",
             "revision":"\(UUID())","parents":[],
             "pages":[{"id":"\(page)","physicalIndex":0,"documentID":"\(document)","role":"searchable"}],
             "documents":[{"id":"\(document)","ownerFileID":"\(identity.fileID)","fields":{}}],"fileFields":{}}
            """.utf8).write(to: sidecar)

        let suite = "ReaderCatalogueMove.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstIndexer = ContentIndexer(url: folder.appendingPathComponent("original-index.sqlite"))
        let navigation = NavigationModel(defaults: defaults, indexer: firstIndexer)
        XCTAssertNil(navigation.rootStore.setRoot(original))
        let instance = UUID()
        let priorKey = try XCTUnwrap(ReaderRootIdentity.legacyCatalogueKey(for: original))
        defaults.set(instance.uuidString, forKey: priorKey)
        defaults.set(true, forKey: priorKey + ".enabled")
        navigation.startLibrary(original)
        let root = navigation.resolvedLibraryRoot(original)
        XCTAssertNotNil(root.markerGUID)
        XCTAssertEqual(root.catalogueInstance, instance)
        let originalReader = try CatalogueReader(grantedRoot: original, rootInstanceID: instance,
                                                 mode: .adopted, identifyPDF: CataloguePDFIdentity.identify)
        let facts = try originalReader.discover().facts(at: "Letter.pdf").file.get()
        _ = try CatalogueWriter(reader: originalReader).save([
            CatalogueEdit(.file(.flagged), .set(.flag(true))),
            CatalogueEdit(.pageViewRotation(page), .set(.rotation(90)))
        ], basedOn: facts)

        let verified = originalReader.discover()
        let memory = ReaderCataloguePairMemory(url: folder.appendingPathComponent("pairs.sqlite"))
        await memory.remember(snapshot: verified)
        try FileManager.default.copyItem(at: original, to: copy)
        try FileManager.default.moveItem(at: original, to: moved)

        navigation.library.start(scope: nil)
        await firstIndexer.closeForTesting()

        let movedIndexer = ContentIndexer(url: folder.appendingPathComponent("reopened-index.sqlite"))
        let reopened = NavigationModel(defaults: defaults, indexer: movedIndexer)
        let reopenedRoot = try XCTUnwrap(reopened.rootStore.root)
        XCTAssertEqual(reopenedRoot.resolvingSymlinksInPath().path, moved.path)
        XCTAssertEqual(reopened.resolvedLibraryRoot(reopenedRoot).catalogueInstance, instance)
        let pass = ReaderCatalogueScan.run(root: moved, instance: instance, isCancelled: { false }, onProgress: { _ in })
        XCTAssertEqual(pass.rows.first?.catalogueFlag, true)
        XCTAssertEqual(pass.snapshot?.facts(at: "Letter.pdf", physicalPageIndex: 0).page?.viewRotation, 90)

        let deadline = Date().addingTimeInterval(5)
        while reopened.library.files.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let openPath = try XCTUnwrap(reopened.library.files.first).path
        let viewer = DocumentViewerModel(persists: false)
        viewer.followCatalogueRotation(reopened)
        viewer.load(DocumentSelection(filePaths: [openPath]))
        XCTAssertEqual(viewer.imageTurns, 1)
        XCTAssertEqual(viewer.pageViewTurns(path: openPath, page: 0), 1)

        XCTAssertNil(reopened.rootStore.setRoot(copy))
        XCTAssertEqual(reopened.resolvedLibraryRoot(copy).markerGUID, root.markerGUID)
        XCTAssertNil(reopened.resolvedLibraryRoot(copy).catalogueInstance)
        reopened.setCatalogueMode(true)
        let copyInstance = try XCTUnwrap(reopened.resolvedLibraryRoot(copy).catalogueInstance)
        XCTAssertNotEqual(copyInstance, instance)
        let copiedReader = try CatalogueReader(grantedRoot: copy, rootInstanceID: copyInstance,
                                               mode: .adopted, identifyPDF: CataloguePDFIdentity.identify)
        try FileManager.default.moveItem(at: copy.appendingPathComponent("Letter.pdf"),
                                         to: copy.appendingPathComponent("Renamed.pdf"))
        let wrongRoot = await memory.candidate(reader: copiedReader, root: copy, relativePath: "Renamed.pdf")
        XCTAssertNil(wrongRoot)

        let movedReader = try XCTUnwrap(pass.reader)
        let renamed = moved.appendingPathComponent("Renamed.pdf")
        try FileManager.default.moveItem(at: moved.appendingPathComponent("Letter.pdf"), to: renamed)
        XCTAssertThrowsError(try movedReader.discover().facts(at: "Renamed.pdf").file.get())
        let candidate = await memory.candidate(reader: movedReader, root: moved, relativePath: "Renamed.pdf")
        _ = try CatalogueWriter(reader: movedReader).reassociateCompanion(XCTUnwrap(candidate))
        let repaired = movedReader.discover().facts(at: "Renamed.pdf", physicalPageIndex: 0)
        guard case .value(true) = try repaired.file.get().pair.record.fileFields.flagged?.current else {
            return XCTFail("The repaired companion should retain the flag.")
        }
        XCTAssertEqual(repaired.page?.viewRotation, 90)
        XCTAssertEqual(try Data(contentsOf: renamed), originalPDF)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.appendingPathComponent(sidecar.lastPathComponent).path))
        XCTAssertFalse(viewer.canRotate, "A viewer opened in the original instance cannot edit the copy.")
        reopened.library.start(scope: nil)
        await movedIndexer.closeForTesting()
    }

    private func writePDF(at url: URL, metadata: Data?, pageCount: Int = 1) throws {
        var bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        if let metadata { pdf.addDocumentMetadata(metadata as CFData) }
        for _ in 0..<pageCount {
            pdf.beginPDFPage(nil)
            pdf.fill(bounds.insetBy(dx: 10, dy: 10))
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }
}
