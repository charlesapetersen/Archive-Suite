import Foundation
import PDFKit
import Testing
@testable import ArchiveCore

@Suite("Catalogue pair and subset export", .timeLimit(.minutes(1)))
struct CatalogueExportTests {
    private let owner = Identity()
    private let member = Identity()
    private let document = UUID()
    private let page = UUID()
    private let rootID = UUID()

    @Test func aSplitMemberTravelsWithItsOwnerByteForByte() throws {
        try withRoots { root, out in
            let fm = FileManager.default
            try fm.createDirectory(at: root.appendingPathComponent("Box 1/Folder 2"), withIntermediateDirectories: true)
            let memberPath = "Box 1/Folder 2/Part.pdf"
            let ownerPath = "Box 1/Original.pdf"
            let unrelated = "Unrelated.pdf"
            let memberPDF = try writePDF(member, named: memberPath, in: root)
            let ownerPDF = try writePDF(owner, named: ownerPath, in: root)
            try writePDF(Identity(), named: unrelated, in: root)
            let memberJSON = record(for: member, owner: owner)
            // Unknown keys and exact spacing must survive: the export is the companion's bytes.
            let ownerJSON = Data(String(decoding: record(for: owner, owner: owner, title: "Original"), as: UTF8.self)
                .replacingOccurrences(of: "\"fileFields\":{}", with: "\"fileFields\":{\"readState\":{\"state\":\"value\",\"value\":\"read\",\"fieldRevision\":\"\(UUID())\",\"origin\":\"user\"}},  \"x-later\":[1]")
                .utf8)
            try memberJSON.write(to: companion(memberPath, in: root))
            try ownerJSON.write(to: companion(ownerPath, in: root))
            let context = try writeContext(in: root, folders: ["", "Box 1", "Box 1/Folder 2", "Elsewhere"])

            let destination = out.appendingPathComponent("Export")
            let manifest = try CatalogueExport.export([memberPath], from: reader(root), to: destination,
                                                      now: Date(timeIntervalSince1970: 1_800_000_000))

            #expect(manifest.snapshot && manifest.format == CatalogueExport.format)
            #expect(manifest.files.map(\.path) == [memberPath, ownerPath])
            #expect(manifest.files.map(\.role) == [.selected, .document])
            #expect(manifest.originName == root.lastPathComponent)
            #expect(try Data(contentsOf: destination.appendingPathComponent(memberPath)) == memberPDF)
            #expect(try Data(contentsOf: destination.appendingPathComponent(ownerPath)) == ownerPDF)
            #expect(try Data(contentsOf: companion(memberPath, in: destination)) == memberJSON)
            #expect(try Data(contentsOf: companion(ownerPath, in: destination)) == ownerJSON)
            #expect(!fm.fileExists(atPath: destination.appendingPathComponent(unrelated).path))

            // Folder records on the way to each file travel; others do not.
            let expectedContext = context.filter { !$0.hasPrefix("Elsewhere/") }
            #expect(Set(manifest.context) == Set(expectedContext))
            for path in expectedContext {
                #expect(try Data(contentsOf: destination.appendingPathComponent(path)) == Data(contentsOf: root.appendingPathComponent(path)))
            }
            #expect(!fm.fileExists(atPath: destination.appendingPathComponent("Elsewhere").path))

            let saved = try CatalogueExport.Manifest.decode(Data(contentsOf: destination.appendingPathComponent(CatalogueExport.manifestName)))
            #expect(saved == manifest)
            #expect(!String(decoding: try manifest.encoded(), as: UTF8.self).contains(root.path))

            // Opened as its own root, the split member still reads its owner's current fields.
            let exported = try CatalogueReader(grantedRoot: destination, rootInstanceID: UUID(), mode: .adopted,
                                               identifyPDF: Self.identify).discover()
            let facts = exported.facts(at: memberPath, physicalPageIndex: 0)
            #expect(try facts.document.get().owner.pair.occurrence.relativePath == ownerPath)
            #expect(try title(in: facts) == "Original")
            #expect(try fm.contentsOfDirectory(atPath: out.path) == ["Export"])
        }
    }

    @Test func anOwnerTakesEveryMemberAndAnEnclosureTakesItsCover() throws {
        try withRoots { root, out in
            let ownerPath = "Original.pdf"
            let memberPath = "Part.pdf"
            try writePDF(owner, named: ownerPath, in: root)
            try writePDF(member, named: memberPath, in: root)
            try record(for: owner, owner: owner, title: "Original").write(to: companion(ownerPath, in: root))
            try record(for: member, owner: owner).write(to: companion(memberPath, in: root))
            let first = try CatalogueExport.export([ownerPath], from: reader(root), to: out.appendingPathComponent("A"))
            #expect(first.files.map(\.path) == [ownerPath, memberPath])

            // The enclosure's own file declares an edge to a cover document owned by another file.
            let enclosure = Identity()
            let cover = UUID()
            let coverPath = "Cover.pdf"
            let enclosurePath = "Enclosure.pdf"
            try writePDF(enclosure, named: enclosurePath, in: root)
            let edge = #", "enclosedWith":{"documentID":"\#(cover)","ownerFileID":"\#(cover)"}"#
            try record(for: enclosure, owner: enclosure, title: "Enclosure", document: UUID(), enclosure: edge)
                .write(to: companion(enclosurePath, in: root))
            // The cover file's ID doubles as its document's ID; both are just UUIDs.
            let coverIdentity = Identity(file: cover, content: UUID())
            try writePDF(coverIdentity, named: coverPath, in: root)
            try record(for: coverIdentity, owner: coverIdentity, title: "Cover", document: cover)
                .write(to: companion(coverPath, in: root))
            let second = try CatalogueExport.export([enclosurePath], from: reader(root), to: out.appendingPathComponent("B"))
            #expect(second.files.map(\.path) == [enclosurePath, coverPath])
            #expect(second.files.map(\.role) == [.selected, .enclosure])
        }
    }

    @Test func anUnreadableFileBlocksAnOwnersExportSinceItMayBeAMember() throws {
        try withRoots { root, out in
            let ownerPath = "Original.pdf"
            let memberPath = "Part.pdf"
            try writePDF(owner, named: ownerPath, in: root)
            try writePDF(member, named: memberPath, in: root)
            try record(for: owner, owner: owner, title: "Original").write(to: companion(ownerPath, in: root))
            try record(for: member, owner: owner).write(to: companion(memberPath, in: root))
            var info = stat()
            try #require(lstat(root.appendingPathComponent(memberPath).path, &info) == 0)
            let inode = info.st_ino
            let offline = try CatalogueReader(grantedRoot: root, rootInstanceID: rootID, mode: .adopted,
                                              isDataless: { $0.st_ino == inode }, identifyPDF: Self.identify)
            #expect(throws: CatalogueExport.Failure.unavailable(path: memberPath, .offline(.pdf))) {
                try CatalogueExport.export([ownerPath], from: offline, to: out.appendingPathComponent("A"))
            }
            // A plain PDF without a companion cannot be a member and does not block it.
            try writePDF(nil, named: "Plain.pdf", in: root)
            #expect(try CatalogueExport.export([ownerPath], from: reader(root), to: out.appendingPathComponent("B"))
                .files.map(\.path) == [ownerPath, memberPath])
            // An invalid companion elsewhere might be a member's, so it does.
            try Data("{".utf8).write(to: companion("Plain.pdf", in: root))
            #expect(throws: CatalogueExport.Failure.unavailable(path: "Plain.pdf", .invalid(.companion))) {
                try CatalogueExport.export([ownerPath], from: reader(root), to: out.appendingPathComponent("C"))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["B"])
        }
    }

    @Test func preservedOriginalsTravelVerified() throws {
        try withRoots { root, out in
            let path = "Reading.pdf"
            try writePDF(owner, named: path, in: root)
            var facts = try #require(JSONSerialization.jsonObject(with: record(for: owner, owner: owner)) as? [String: Any])
            var pages = try #require(facts["pages"] as? [[String: Any]])
            pages[0]["sourcePageID"] = page.uuidString
            facts["pages"] = pages
            let folderParts = PreservationCopy.folderComponents(documentID: document, fileID: owner.file)
            let folder = folderParts.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bytes = Data("exact intake payload".utf8)
            let sourceURL = folder.appendingPathComponent("source-1.pdf")
            try bytes.write(to: sourceURL)
            let input = try FileHandle(forReadingFrom: sourceURL)
            let fingerprint = try PreservationCopy.Fingerprint(reading: input.fileDescriptor)
            try input.close()
            let manifest = PreservationCopy.Manifest(fileID: owner.file,
                                                     sources: [.init(name: "Intake.pdf", format: .pdf, fingerprint: fingerprint)],
                                                     pages: [.init(id: page, sourceIndex: 0, originalPageIndex: 3)])
            facts["preservationManifestSHA256"] = try manifest.digest().base64EncodedString()
            try JSONSerialization.data(withJSONObject: facts).write(to: companion(path, in: root))
            try manifest.encoded().write(to: folder.appendingPathComponent(PreservationCopy.manifestName))

            let destination = out.appendingPathComponent("Export")
            let exported = try CatalogueExport.export([path], from: reader(root), to: destination)
            let relative = folderParts.joined(separator: "/")
            #expect(exported.files[0].preservation == [relative + "/pages.json", relative + "/source-1.pdf"])
            let check = try CatalogueReader(grantedRoot: destination, rootInstanceID: rootID, mode: .adopted, identifyPDF: Self.identify)
            let occurrence = CatalogueAssociation.Occurrence(rootInstanceID: rootID, relativePath: path)
            #expect(try PreservationCopy.open(in: check, at: occurrence, physicalPageIndex: 0).bytes == bytes)

            // A damaged original refuses the whole export and leaves nothing behind.
            try Data(repeating: 0, count: bytes.count).write(to: sourceURL)
            #expect(throws: CatalogueExport.Failure.preservation(path: path)) {
                try CatalogueExport.export([path], from: reader(root), to: out.appendingPathComponent("Damaged"))
            }
            try FileManager.default.removeItem(at: folder)
            #expect(throws: CatalogueExport.Failure.preservation(path: path)) {
                try CatalogueExport.export([path], from: reader(root), to: out.appendingPathComponent("Missing"))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["Export"])
        }
    }

    @Test func unresolvedOrUnsafeExportsAreRefusedWithoutLeavingAnything() throws {
        try withRoots { root, out in
            let fm = FileManager.default
            let memberPath = "Part.pdf"
            let ownerPath = "Original.pdf"
            try writePDF(member, named: memberPath, in: root)
            try record(for: member, owner: owner).write(to: companion(memberPath, in: root))
            let adopted = try reader(root)
            #expect(throws: CatalogueExport.Failure.unavailable(path: memberPath, .missing(.owner))) {
                try CatalogueExport.export([memberPath], from: adopted, to: out.appendingPathComponent("A"))
            }
            try writePDF(owner, named: ownerPath, in: root)
            try record(for: owner, owner: owner, title: "Original").write(to: companion(ownerPath, in: root))
            try fm.copyItem(at: root.appendingPathComponent(ownerPath), to: root.appendingPathComponent("Copy.pdf"))
            try fm.copyItem(at: companion(ownerPath, in: root), to: companion("Copy.pdf", in: root))
            #expect(throws: CatalogueExport.Failure.unavailable(path: memberPath, .ambiguous(.owner))) {
                try CatalogueExport.export([memberPath], from: adopted, to: out.appendingPathComponent("A"))
            }
            try fm.removeItem(at: root.appendingPathComponent("Copy.pdf"))
            try fm.removeItem(at: companion("Copy.pdf", in: root))

            #expect(throws: CatalogueExport.Failure.unavailable(path: "Plain.pdf", .missing(.companion))) {
                try writePDF(nil, named: "Plain.pdf", in: root)
                try CatalogueExport.export(["Plain.pdf"], from: adopted, to: out.appendingPathComponent("A"))
            }
            #expect(throws: CatalogueExport.Failure.nothingSelected) {
                try CatalogueExport.export([], from: adopted, to: out.appendingPathComponent("A"))
            }
            #expect(throws: CatalogueExport.Failure.destinationInsideArchive) {
                try CatalogueExport.export([memberPath], from: adopted, to: root.appendingPathComponent("Export"))
            }
            let existing = out.appendingPathComponent("Existing")
            try fm.createDirectory(at: existing, withIntermediateDirectories: false)
            try Data("keep".utf8).write(to: existing.appendingPathComponent("note.txt"))
            #expect(throws: CatalogueExport.Failure.destinationExists) {
                try CatalogueExport.export([memberPath], from: adopted, to: existing)
            }
            #expect(try fm.contentsOfDirectory(atPath: existing.path) == ["note.txt"])
            #expect(try fm.contentsOfDirectory(atPath: out.path) == ["Existing"])
            #expect(fm.fileExists(atPath: root.appendingPathComponent("Plain.pdf").path))

            // The archive itself is only read.
            let before = try snapshotOfFiles(root)
            _ = try CatalogueExport.export([memberPath], from: adopted, to: out.appendingPathComponent("Done"))
            #expect(try snapshotOfFiles(root) == before)
        }
    }

    @Test func aSharingCopyLeavesOutPersonalStateAndKeepsTheDescription() throws {
        try withRoots { root, out in
            let ownerPath = "Original.pdf"
            let memberPath = "Part.pdf"
            try writePDF(owner, named: ownerPath, in: root)
            try writePDF(member, named: memberPath, in: root)
            func envelope(_ value: String, checked: Bool = true, evidence: String = "") -> String {
                let revision = UUID()
                return #"{"state":"value","value":\#(value),"fieldRevision":"\#(revision)","origin":"user""#
                    + (checked ? #","checkedRevision":"\#(revision)""# : "") + evidence + "}"
            }
            let personal = #""readState":\#(envelope("\"read\"")),"flagged":\#(envelope("true")),"#
                + #""colour":\#(envelope("\"red\"")),"quality":\#(envelope("2")),"x-mood":\#(envelope("\"tired\"")),"#
                + #""ocrPoor":\#(envelope("true")),"ocrFailed":{"state":"cleared","fieldRevision":"\#(UUID())","origin":"model"}"#
            let evidence = #","evidence":[{"source":"ocr","quote":"Dear Sir","observedValue":"Letter"}]"#
            let ownerJSON = Data(String(decoding: record(for: owner, owner: owner, title: "Original"), as: UTF8.self)
                .replacingOccurrences(of: "\"fileFields\":{}", with: "\"fileFields\":{\(personal)},  \"x-later\":[1]")
                .replacingOccurrences(of: "\"fields\":{", with: "\"fields\":{\"documentKind\":\(envelope("\"Letter\"", evidence: evidence)),")
                .utf8)
            try ownerJSON.write(to: companion(ownerPath, in: root))
            try record(for: member, owner: owner).write(to: companion(memberPath, in: root))
            let archived = try CatalogueRecord(json: ownerJSON)
            let before = try snapshotOfFiles(root)

            let destination = out.appendingPathComponent("Sharing")
            let manifest = try CatalogueExport.export([memberPath], from: reader(root), to: destination,
                                                      contents: .disclosureLimited, now: Date(timeIntervalSince1970: 1_800_000_000))
            #expect(try snapshotOfFiles(root) == before)
            #expect(manifest.contents == .disclosureLimited && manifest.omitted == CatalogueExport.omittedFromSharing)
            #expect(manifest.note.contains("not the archive's own records"))
            #expect(manifest.files.map(\.path) == [memberPath, ownerPath])
            #expect(!manifest.files.contains { $0.revision == archived.revision })
            #expect(try Data(contentsOf: destination.appendingPathComponent(ownerPath)) == Data(contentsOf: root.appendingPathComponent(ownerPath)))
            let saved = try CatalogueExport.Manifest.decode(Data(contentsOf: destination.appendingPathComponent(CatalogueExport.manifestName)))
            #expect(saved == manifest)

            let shared = try CatalogueRecord(json: Data(contentsOf: companion(ownerPath, in: destination)))
            let text = String(decoding: shared.originalJSON, as: UTF8.self)
            for gone in ["readState", "flagged", "colour", "quality", "x-mood", "tired", "checkedRevision"] {
                #expect(!text.contains(gone), "\(gone) left the archive")
            }
            #expect(shared.fileFields.readState == nil && shared.fileFields.quality == nil)
            #expect(shared.fileFields.ocrPoor.map { !$0.isChecked } == true)
            if case .cleared? = shared.fileFields.ocrFailed?.current {} else { Issue.record("ocrFailed lost its clear") }
            #expect(shared.parents.isEmpty && shared.revision == manifest.files[1].revision)
            #expect(shared.fileID == archived.fileID && shared.contentRevision == archived.contentRevision)
            #expect(text.contains("\"x-later\":[1]") && text.contains("Dear Sir"))
            let kind = try #require(shared.documents.first?.fields?.documentKind)
            #expect(!kind.isChecked && kind.evidence.count == 1)

            // Opened as its own root, the member reads the owner's description through the sharing record.
            let exported = try CatalogueReader(grantedRoot: destination, rootInstanceID: UUID(), mode: .adopted,
                                               identifyPDF: Self.identify).discover()
            let facts = exported.facts(at: memberPath, physicalPageIndex: 0)
            #expect(try title(in: facts) == "Original")
            #expect(try facts.document.get().owner.revision.facts == shared.revision)

            // A whole-record folder cannot pass as a sharing copy, nor the reverse.
            let whole = try CatalogueExport.export([memberPath], from: reader(root), to: out.appendingPathComponent("Whole"))
            #expect(whole.contents == .wholeRecords && whole.omitted.isEmpty)
            let snapshot = try reader(root).discover()
            #expect(throws: CatalogueExport.Failure.self) {
                try CatalogueExport.verify(relabelled(whole, as: .disclosureLimited), at: out.appendingPathComponent("Whole"),
                                           against: snapshot, identify: Self.identify)
            }
            #expect(throws: CatalogueExport.Failure.self) {
                try CatalogueExport.verify(relabelled(manifest, as: .wholeRecords), at: destination,
                                           against: snapshot, identify: Self.identify)
            }
            try CatalogueExport.verify(manifest, at: destination, against: snapshot, identify: Self.identify)
        }
    }

    // MARK: - Fixtures

    private func relabelled(_ manifest: CatalogueExport.Manifest, as contents: CatalogueExport.Contents) -> CatalogueExport.Manifest {
        CatalogueExport.Manifest(format: manifest.format, version: manifest.version, snapshot: true, contents: contents,
                                 omitted: manifest.omitted, createdAt: manifest.createdAt, note: manifest.note,
                                 originName: manifest.originName, originRootInstanceID: manifest.originRootInstanceID,
                                 files: manifest.files, context: manifest.context)
    }

    private struct Identity {
        var file = UUID()
        var content = UUID()
    }

    private func reader(_ root: URL) throws -> CatalogueReader {
        try CatalogueReader(grantedRoot: root, rootInstanceID: rootID, mode: .adopted, identifyPDF: Self.identify)
    }

    // Identity embedded in a real scratch PDF, independent of the JSON under test (as in CatalogueReaderTests).
    private static func identify(_ fd: Int32, _: CatalogueAssociation.Occurrence) throws -> CatalogueReader.PDFIdentity? {
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let bytes = try file.readToEnd(), let pdf = PDFDocument(data: bytes),
              let fileString = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
              let contentString = pdf.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String,
              let fileID = UUID(uuidString: fileString), let content = UUID(uuidString: contentString) else { return nil }
        return .init(fileID: fileID, contentRevision: content, pageCount: pdf.pageCount)
    }

    @discardableResult
    private func writePDF(_ identity: Identity?, named name: String, in root: URL) throws -> Data {
        let pdf = PDFDocument()
        pdf.insert(PDFPage(), at: 0)
        if let identity {
            pdf.documentAttributes = [PDFDocumentAttribute.titleAttribute: identity.file.uuidString,
                                      PDFDocumentAttribute.subjectAttribute: identity.content.uuidString]
        }
        let bytes = try #require(pdf.dataRepresentation())
        try bytes.write(to: root.appendingPathComponent(name))
        return bytes
    }

    private func record(for item: Identity, owner: Identity, title: String = "", document: UUID? = nil,
                        enclosure: String = "") -> Data {
        let document = document ?? self.document
        let fields = item.file == owner.file
            ? #", "fields":{"title":{"state":"value","value":"\#(title)","fieldRevision":"\#(UUID())","origin":"user"}}"#
            : ""
        return Data("""
        {"schema":1,"fileID":"\(item.file)","contentRevision":"\(item.content)","revision":"\(UUID())","parents":[],
         "pages":[{"id":"\(page)","physicalIndex":0,"documentID":"\(document)","role":"searchable"}],
         "documents":[{"id":"\(document)","ownerFileID":"\(owner.file)"\(fields)\(enclosure)}],"fileFields":{}}
        """.utf8)
    }

    /// Writes every context record in each folder ("" is the root) and returns their relative paths.
    private func writeContext(in root: URL, folders: [String]) throws -> [String] {
        var written: [String] = []
        for folder in folders {
            let base = folder.isEmpty ? root : root.appendingPathComponent(folder)
            let metadata = base.appendingPathComponent(".archivesuite")
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
            for name in CatalogueExport.contextNames {
                try Data("{\"folder\":\"\(folder)\",\"name\":\"\(name)\"}".utf8).write(to: metadata.appendingPathComponent(name))
                written.append((folder.isEmpty ? "" : folder + "/") + ".archivesuite/" + name)
            }
            // Local state beside them never travels.
            try Data("journal".utf8).write(to: metadata.appendingPathComponent("journal.json"))
        }
        return written
    }

    private func title(in facts: ItemFacts) throws -> String? {
        guard case .value(let title)? = try facts.document.get().document.fields?.title?.current else { return nil }
        return title
    }

    private func companion(_ path: String, in root: URL) -> URL {
        root.appendingPathComponent(CatalogueRecord.companionFilename(forPDFFilename: path))
    }

    private func snapshotOfFiles(_ root: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            files[url.path] = try Data(contentsOf: url)
        }
        return files
    }

    private func withRoots(_ body: (URL, URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("catalogue-export-\(UUID())")
        let root = base.appendingPathComponent("Archive")
        let out = base.appendingPathComponent("Out")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(root, out)
    }
}
