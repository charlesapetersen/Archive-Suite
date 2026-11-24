import Foundation
import PDFKit
import Testing
@testable import ArchiveCore

@Suite("Scoped catalogue reads", .timeLimit(.minutes(1)))
struct CatalogueReaderTests {
    private let owner = Identity()
    private let member = Identity()
    private let document = UUID()
    private let page = UUID()
    private let rootID = UUID()

    @Test func legacyMissingInvalidNewerAndUnverifiedNeverProvideAdoptedFacts() throws {
        try withRoot { root in
            let path = "Letter.PDF"
            let pdf = try writePDF(owner, named: path, in: root)
            let legacy = try reader(root, mode: .legacy).discover(including: [path]).facts(at: path)
            #expect(failure(legacy.file) == .legacy)

            let adopted = try reader(root)
            // The optional legacy segment JSON has no role in adopted discovery.
            try Data("{}".utf8).write(to: root.appendingPathComponent("Letter.json"))
            #expect(failure(adopted.discover().facts(at: path).file) == .missing(.companion))

            let companion = companion(path, in: root)
            try Data("not JSON".utf8).write(to: companion)
            #expect(failure(adopted.discover().facts(at: path).document) == .invalid(.companion))
            try Data(#"{"schema":2}"#.utf8).write(to: companion)
            #expect(failure(adopted.discover().facts(at: path).document) == .newer(schema: 2))

            try record(for: owner, owner: owner).write(to: companion)
            #expect(try adopted.discover().facts(at: path).document.get().document.id == document)
            #expect(try Data(contentsOf: root.appendingPathComponent(path)) == pdf)

            // Same filename and file ID but a different content generation.
            try writePDF(Identity(file: owner.file), named: path, in: root)
            #expect(failure(adopted.discover().facts(at: path).file) == .invalid(.pdf))
            try writePDF(nil, named: path, in: root)
            #expect(failure(adopted.discover().facts(at: path).file) == .invalid(.pdf))
        }
    }

    @Test func preservationRequiresAVerifiedPageAssociationAndExactBytes() throws {
        try withRoot { root in
            let path = "Reading.pdf"
            try writePDF(owner, named: path, in: root)
            let adopted = try reader(root)
            let occurrence = CatalogueAssociation.Occurrence(rootInstanceID: rootID, relativePath: path)
            func status() throws -> PreservationCopy.Selection {
                try PreservationCopy.status(in: adopted, at: occurrence, physicalPageIndex: 0)
            }
            #expect(throws: PreservationCopy.Failure.notRecorded) { try status() }

            var facts = try #require(JSONSerialization.jsonObject(with: record(for: owner, owner: owner)) as? [String: Any])
            var pages = try #require(facts["pages"] as? [[String: Any]])
            pages[0]["sourcePageID"] = page.uuidString
            facts["pages"] = pages

            let folder = PreservationCopy.folderComponents(documentID: document, fileID: owner.file)
                .reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bytes = Data("exact intake payload".utf8)
            let sourceURL = folder.appendingPathComponent("source-1.pdf")
            try bytes.write(to: sourceURL)
            let input = try FileHandle(forReadingFrom: sourceURL)
            defer { try? input.close() }
            let fingerprint = try PreservationCopy.Fingerprint(reading: input.fileDescriptor)
            let source = PreservationCopy.Source(name: "Intake.pdf", format: .pdf, fingerprint: fingerprint)
            let map = folder.appendingPathComponent(PreservationCopy.manifestName)
            let manifest = PreservationCopy.Manifest(fileID: owner.file, sources: [source],
                                                       pages: [.init(id: page, sourceIndex: 0, originalPageIndex: 3)])
            facts["preservationManifestSHA256"] = try manifest.digest().base64EncodedString()
            try JSONSerialization.data(withJSONObject: facts).write(to: companion(path, in: root))
            #expect(throws: PreservationCopy.Failure.missing) { try status() }
            try manifest.encoded().write(to: map)

            #expect(try status().originalPageIndex == 3)
            #expect(try PreservationCopy.open(in: adopted, at: occurrence, physicalPageIndex: 0).bytes == bytes)
            #expect(adopted.discover().inventory.relativePDFPaths == [path])

            for names in [[], ["../Reading.pdf"], ["Reading.jpg"], [".hidden.pdf"], ["Reading.PDF"]] {
                let invalid = PreservationCopy.Manifest(fileID: manifest.fileID, sources: manifest.sources,
                                                        pages: manifest.pages, storedNames: names)
                var invalidFacts = facts
                invalidFacts["preservationManifestSHA256"] = try invalid.digest().base64EncodedString()
                try JSONSerialization.data(withJSONObject: invalidFacts).write(to: companion(path, in: root))
                try invalid.encoded().write(to: map)
                #expect(throws: PreservationCopy.Failure.unverified) { try status() }
            }
            try JSONSerialization.data(withJSONObject: facts).write(to: companion(path, in: root))

            // A changed page map is refused even when it still names the right source file and IDs.
            let altered = PreservationCopy.Manifest(fileID: owner.file, sources: [source],
                                                      pages: [.init(id: page, sourceIndex: 0, originalPageIndex: 2)])
            try altered.encoded().write(to: map)
            #expect(throws: PreservationCopy.Failure.unverified) { try status() }
            try manifest.encoded().write(to: map)

            var stub = stat()
            try #require(lstat(sourceURL.path, &stub) == 0)
            let inode = stub.st_ino
            let offline = try CatalogueReader(grantedRoot: root, rootInstanceID: rootID, mode: .adopted,
                                              isDataless: { $0.st_ino == inode }, identifyPDF: Self.identify)
            #expect(throws: PreservationCopy.Failure.offline) {
                try PreservationCopy.status(in: offline, at: occurrence, physicalPageIndex: 0)
            }

            try Data(repeating: 0, count: bytes.count).write(to: sourceURL)
            #expect(throws: PreservationCopy.Failure.unverified) {
                try PreservationCopy.open(in: adopted, at: occurrence, physicalPageIndex: 0)
            }
            try FileManager.default.removeItem(at: sourceURL)
            try FileManager.default.createSymbolicLink(at: sourceURL, withDestinationURL: root.appendingPathComponent(path))
            #expect(throws: PreservationCopy.Failure.unverified) { try status() }

            let fm = FileManager.default
            try fm.removeItem(at: sourceURL)
            try bytes.write(to: sourceURL)
            let moved = root.appendingPathComponent("Moved")
            try fm.createDirectory(at: moved, withIntermediateDirectories: false)
            for name in [path, companion(path, in: root).lastPathComponent, PreservationCopy.directoryName] {
                try fm.moveItem(at: root.appendingPathComponent(name), to: moved.appendingPathComponent(name))
            }
            let movedOccurrence = CatalogueAssociation.Occurrence(rootInstanceID: rootID, relativePath: "Moved/" + path)
            #expect(try PreservationCopy.open(in: adopted, at: movedOccurrence, physicalPageIndex: 0).bytes == bytes)
            try fm.copyItem(at: moved.appendingPathComponent(path), to: root.appendingPathComponent("Detached.pdf"))
            let detached = CatalogueAssociation.Occurrence(rootInstanceID: rootID, relativePath: "Detached.pdf")
            #expect(throws: PreservationCopy.Failure.notRecorded) {
                try PreservationCopy.status(in: adopted, at: detached, physicalPageIndex: 0)
            }
        }
    }

    @Test func splitDocumentReadsOnlyItsUniqueOwnerInTheGrantedRoot() throws {
        try withRoot { root in
            let adopted = try reader(root)
            let path = "Part.pdf"
            let ownerPath = "Folders/Original.pdf"
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Folders"), withIntermediateDirectories: false)
            try writePDF(member, named: path, in: root)
            try record(for: member, owner: owner).write(to: companion(path, in: root))
            let missing = adopted.discover().facts(at: path, physicalPageIndex: 0)
            #expect(try missing.file.get().pair.record.fileID == member.file)
            #expect(failure(missing.document) == .missing(.owner))

            try writePDF(owner, named: ownerPath, in: root)
            try record(for: owner, owner: owner, title: "Original").write(to: companion(ownerPath, in: root))
            let inventory = adopted.discover()
            #expect(Set(inventory.inventory.relativePDFPaths) == [path, ownerPath])
            let ready = inventory.facts(at: path, physicalPageIndex: 0)
            #expect(try ready.document.get().owner.pair.occurrence.relativePath == ownerPath)
            #expect(try title(in: ready) == "Original")

            let partial = adopted.snapshot(.init(relativePDFPaths: [path, ownerPath], isComplete: false))
            #expect(failure(partial.facts(at: path).document) == .incompleteInventory)
            #expect(try title(in: partial.facts(at: ownerPath)) == "Original")

            let repeated = adopted.snapshot(.init(relativePDFPaths: [path, ownerPath, ownerPath], isComplete: true))
            #expect(try title(in: repeated.facts(at: path)) == "Original")

            let copy = "Copy.pdf"
            try FileManager.default.copyItem(at: root.appendingPathComponent(ownerPath), to: root.appendingPathComponent(copy))
            #expect(failure(adopted.discover().facts(at: path).document) == .ambiguous(.owner))
            try FileManager.default.copyItem(at: companion(ownerPath, in: root), to: companion(copy, in: root))
            let two = adopted.discover()
            #expect(failure(two.facts(at: path).document) == .ambiguous(.owner))
            #expect(try title(in: two.facts(at: ownerPath)) == "Original")
            #expect(try title(in: two.facts(at: copy)) == "Original")

            // A split member in another grant cannot look up either of the ready copies.
            try withRoot { other in
                try writePDF(member, named: path, in: other)
                try record(for: member, owner: owner).write(to: companion(path, in: other))
                let otherReader = try reader(other, rootID: UUID())
                #expect(failure(otherReader.discover().facts(at: path).document) == .missing(.owner))
            }
        }
    }

    @Test func stalePathsSymlinksAndRootReplacementFailClosed() throws {
        try withRoot { parent in
            let root = parent.appendingPathComponent("Root")
            let outside = parent.appendingPathComponent("Outside")
            let files = FileManager.default
            try files.createDirectory(at: root, withIntermediateDirectories: false)
            try files.createDirectory(at: outside, withIntermediateDirectories: false)
            let adopted = try reader(root)
            let path = "Scan.pdf"
            try writePDF(owner, named: path, in: outside)
            try record(for: owner, owner: owner).write(to: companion(path, in: outside))
            try files.createSymbolicLink(at: root.appendingPathComponent(path), withDestinationURL: outside.appendingPathComponent(path))
            try files.createSymbolicLink(at: root.appendingPathComponent("Bridge"), withDestinationURL: outside)
            try files.createSymbolicLink(at: root.appendingPathComponent("Dangling.pdf"),
                                         withDestinationURL: outside.appendingPathComponent("Absent.pdf"))

            let snapshot = adopted.discover(including: [path, "Bridge/Scan.pdf", "../Outside/Scan.pdf", "Stale.pdf"])
            #expect(snapshot.inventory.isComplete)
            #expect(snapshot.inventory.relativePDFPaths.isEmpty)
            #expect(failure(snapshot.facts(at: path).file) == .invalid(.pdf))
            #expect(failure(snapshot.facts(at: "Bridge/Scan.pdf").file) == .invalid(.pdf))
            #expect(failure(snapshot.facts(at: "../Outside/Scan.pdf").file) == .invalid(.pdf))
            #expect(failure(snapshot.facts(at: "Stale.pdf").file) == .missing(.pdf))
            try files.removeItem(at: root.appendingPathComponent(path))
            try writePDF(owner, named: path, in: root)
            try files.createSymbolicLink(at: companion(path, in: root), withDestinationURL: companion(path, in: outside))
            #expect(failure(adopted.discover().facts(at: path).file) == .invalid(.companion))
            try files.removeItem(at: companion(path, in: root))
            try record(for: owner, owner: owner).write(to: companion(path, in: root))
            let aliased = adopted.discover(including: ["scan.pdf"]).facts(at: "scan.pdf")
            #expect(failure(aliased.file) != nil)
            let before = adopted.discover().facts(at: path).revision

            let moved = parent.appendingPathComponent("Moved")
            try files.moveItem(at: root, to: moved)
            try files.moveItem(at: outside, to: root)
            #expect(failure(adopted.discover().facts(at: path).file) == .invalid(.root))
            let reopened = try reader(moved)
            #expect(reopened.discover().facts(at: path).revision == before)
        }
    }

    @Test func placeholdersDoNotReadPDFBytesAndOfflinedOwnerCompanionsPropagate() throws {
        try withRoot { root in
            let ownerPath = "Owner.pdf"
            let path = "Member.pdf"
            try writePDF(owner, named: ownerPath, in: root)
            try record(for: owner, owner: owner).write(to: companion(ownerPath, in: root))
            try writePDF(member, named: path, in: root)
            try record(for: member, owner: owner).write(to: companion(path, in: root))
            var pdfInfo = stat()
            var recordInfo = stat()
            try #require(lstat(root.appendingPathComponent(path).path, &pdfInfo) == 0)
            try #require(lstat(companion(ownerPath, in: root).path, &recordInfo) == 0)
            let pdfInode = pdfInfo.st_ino
            let previousPolicy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            let offlinePDF = try CatalogueReader(grantedRoot: root, rootInstanceID: rootID, mode: .adopted,
                                                 isDataless: { $0.st_ino == pdfInode }) { fd, occurrence in
                #expect(occurrence.relativePath != path)
                return try Self.identify(fd, occurrence)
            }
            #expect(failure(offlinePDF.discover().facts(at: path).file) == .offline(.pdf))
            #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == previousPolicy)

            let recordInode = recordInfo.st_ino
            let offlineOwner = try CatalogueReader(grantedRoot: root, rootInstanceID: rootID, mode: .adopted,
                                                   isDataless: { $0.st_ino == recordInode },
                                                   identifyPDF: Self.identify)
            let snapshot = offlineOwner.discover()
            #expect(failure(snapshot.facts(at: ownerPath).file) == .offline(.companion))
            #expect(failure(snapshot.facts(at: path).document) == .offline(.owner))
            #expect(try reader(root).discover().facts(at: path).document.get().document.id == document)
        }
    }

    @Test func ownerOnlyRevisionChangesRefreshSplitMembersAndSurviveColdRebuild() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "Part.pdf"
        let ownerPath = "Owner.pdf"
        let ownerPDF = try writePDF(owner, named: ownerPath, in: root)
        let memberPDF = try writePDF(member, named: path, in: root)
        let revision = UUID()
        let ownerCompanion = companion(ownerPath, in: root)
        try record(for: member, owner: owner).write(to: companion(path, in: root))
        try record(for: owner, owner: owner, revision: revision, title: "Old").write(to: ownerCompanion)
        let oldStamp = try #require(FileManager.default.attributesOfItem(atPath: ownerCompanion.path)[.modificationDate] as? Date)
        let reader = try reader(root)
        let updates = CatalogueFactsUpdates(rootInstanceID: rootID)
        let first = reader.discover()
        #expect(await updates.publish(first))
        let stream = await updates.updates(at: path, physicalPageIndex: 0)
        var iterator = stream.makeAsyncIterator()
        let old = try #require(await iterator.next())
        #expect(try title(in: old) == "Old")

        // Also detect a conflicting byte sequence claiming the same JSON revision and mtime.
        try record(for: owner, owner: owner, revision: revision, title: "New").write(to: ownerCompanion)
        try FileManager.default.setAttributes([.modificationDate: oldStamp], ofItemAtPath: ownerCompanion.path)
        let refresh = reader.discover()
        let changed = refresh.facts(at: path, physicalPageIndex: 0)
        #expect(old.revision != changed.revision)
        #expect(try old.file.get().revision == changed.file.get().revision)
        #expect(await updates.publish(refresh))
        let delivered = try #require(await iterator.next())
        #expect(try title(in: delivered) == "New")

        let rebuilt = try self.reader(root).discover().facts(at: path, physicalPageIndex: 0)
        #expect(rebuilt.revision == changed.revision)
        #expect(try title(in: rebuilt) == "New")
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == memberPDF)
        #expect(try Data(contentsOf: root.appendingPathComponent(ownerPath)) == ownerPDF)

        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        #expect(await updates.publish(reader.discover()))
        let removed = try #require(await iterator.next())
        #expect(failure(removed.file) == .missing(.pdf))
    }

    @Test func enclosureUsesItsDeclaringOwnerRegardlessOfSelectedSplitMember() throws {
        try withRoot { root in
            let ownerPath = "Enclosure.pdf"
            let memberPath = "Cover and enclosure.pdf"
            let copy = "Copy.pdf"
            let cover = UUID()
            let memberPage = UUID()
            try writePDF(owner, named: ownerPath, in: root)
            try writePDF(member, named: memberPath, in: root, pageCount: 2)
            let edge = #", "enclosedWith":{"documentID":"\#(cover)","ownerFileID":"\#(member.file)"}"#
            try record(for: owner, owner: owner, title: "Enclosure", enclosure: edge)
                .write(to: companion(ownerPath, in: root))
            // The array is deliberately reversed. Page selection is by physicalIndex.
            let coverAndEnclosure = Data("""
            {"schema":1,"fileID":"\(member.file)","contentRevision":"\(member.content)","revision":"\(UUID())","parents":[],
             "pages":[{"id":"\(memberPage)","physicalIndex":1,"documentID":"\(document)","role":"searchable"},
                      {"id":"\(page)","physicalIndex":0,"documentID":"\(cover)","role":"searchable"}],
             "documents":[{"id":"\(document)","ownerFileID":"\(owner.file)"},
                          {"id":"\(cover)","ownerFileID":"\(member.file)","fields":{}}],"fileFields":{}}
            """.utf8)
            try coverAndEnclosure.write(to: companion(memberPath, in: root))
            let adopted = try reader(root)
            let one = adopted.discover()
            #expect(failure(one.facts(at: memberPath).document) == .ambiguous(.document))
            #expect(try one.facts(at: memberPath, physicalPageIndex: 0).document.get().document.id == cover)
            #expect(try one.facts(at: memberPath, physicalPageIndex: 1).enclosure?.get().document.id == cover)
            try FileManager.default.copyItem(at: root.appendingPathComponent(memberPath), to: root.appendingPathComponent(copy))
            try coverAndEnclosure.write(to: companion(copy, in: root))

            let two = adopted.discover()
            let fromOwner = two.facts(at: ownerPath)
            let fromMember = two.facts(at: memberPath, physicalPageIndex: 1)
            #expect(try title(in: fromMember) == "Enclosure")
            #expect(fromMember.page?.id == memberPage)
            #expect(fromMember.enclosure.flatMap(failure) == .ambiguous(.owner))
            #expect(fromOwner.enclosure.flatMap(failure) == .ambiguous(.owner))
        }
    }

    private struct Identity {
        var file = UUID()
        var content = UUID()
    }

    private func reader(_ root: URL, mode: CatalogueReader.Mode = .adopted, rootID: UUID? = nil) throws -> CatalogueReader {
        try CatalogueReader(grantedRoot: root, rootInstanceID: rootID ?? self.rootID, mode: mode,
                            identifyPDF: Self.identify)
    }

    // Use identity embedded in a real scratch PDF, independent of the JSON under test.
    // Title and subject are fixture carriers, not the production identity format.
    private static func identify(_ fd: Int32, _: CatalogueAssociation.Occurrence) throws -> CatalogueReader.PDFIdentity? {
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        guard let bytes = try file.readToEnd(), let pdf = PDFDocument(data: bytes),
              let fileString = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
              let contentString = pdf.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String,
              let fileID = UUID(uuidString: fileString), let content = UUID(uuidString: contentString) else { return nil }
        return .init(fileID: fileID, contentRevision: content, pageCount: pdf.pageCount)
    }

    @discardableResult
    private func writePDF(_ identity: Identity?, named name: String, in root: URL, pageCount: Int = 1) throws -> Data {
        let pdf = PDFDocument()
        for index in 0..<pageCount {
            pdf.insert(PDFPage(), at: index)
        }
        if let identity {
            pdf.documentAttributes = [PDFDocumentAttribute.titleAttribute: identity.file.uuidString,
                                      PDFDocumentAttribute.subjectAttribute: identity.content.uuidString]
        }
        let bytes = try #require(pdf.dataRepresentation())
        try bytes.write(to: root.appendingPathComponent(name))
        return bytes
    }

    private func record(for item: Identity, owner: Identity, revision: UUID = UUID(), title: String = "",
                        enclosure: String = "") -> Data {
        let fields = item.file == owner.file
            ? #", "fields":{"title":{"state":"value","value":"\#(title)","fieldRevision":"\#(revision)","origin":"user"}}"#
            : ""
        return Data("""
        {"schema":1,"fileID":"\(item.file)","contentRevision":"\(item.content)","revision":"\(revision)","parents":[],
         "pages":[{"id":"\(page)","physicalIndex":0,"documentID":"\(document)","role":"searchable"}],
         "documents":[{"id":"\(document)","ownerFileID":"\(owner.file)"\(fields)\(enclosure)}],"fileFields":{}}
        """.utf8)
    }

    private func title(in facts: ItemFacts) throws -> String? {
        guard case .value(let title)? = try facts.document.get().document.fields?.title?.current else { return nil }
        return title
    }

    private func failure<T>(_ result: Result<T, ItemFacts.Unavailable>) -> ItemFacts.Unavailable? {
        guard case .failure(let unavailable) = result else { return nil }
        return unavailable
    }

    private func companion(_ filename: String, in root: URL) -> URL {
        root.appendingPathComponent(CatalogueRecord.companionFilename(forPDFFilename: filename))
    }

    private func scratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalogue-reader-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
