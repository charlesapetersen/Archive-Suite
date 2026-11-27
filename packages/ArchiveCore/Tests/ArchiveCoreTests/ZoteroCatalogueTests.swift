import Foundation
import PDFKit
import Testing
@testable import ArchiveCore

/// W49.storage-notes-zotero: Notes' source links and the Reader's export read one PDF's catalogue record through
/// `CatalogueSourceFacts`, on scratch roots only. The record alone describes an adopted PDF; a detached one exports no
/// earlier sidecar or correction as current; a legacy file is gathered as before.
@Suite("Zotero sources from the catalogue record", .timeLimit(.minutes(1)))
struct ZoteroCatalogueTests {
    private struct Identity {
        var file = UUID()
        var content = UUID()
    }

    private let letter = UUID()
    private let clipping = UUID()

    // MARK: The mapping

    @Test func recordAloneDescribesAnAdoptedPDFAndCSLMatchesTheLegacyMapping() throws {
        try withRoot { root in
            let item = Identity()
            let path = "Box 1/Letter.pdf"
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Box 1"), withIntermediateDirectories: false)
            try writePDF(item, named: path, in: root)
            try record(item, documents: [(letter, letterFields)]).write(to: companion(path, in: root))
            // Earlier stores beside it: a segment sidecar and a folder correction naming someone else.
            try Data(#"{"author_name": "Stale Sender", "format": "Memo"}"#.utf8)
                .write(to: root.appendingPathComponent("Box 1/Letter.json"))

            let resolution = resolve(path, page: nil, in: root)
            let sources = ZoteroSource.gather(resolution, pdf: root.appendingPathComponent(path),
                                              container: [.container: "Box 1"], link: "archivereader://x")
            let source = try #require(sources.only)
            #expect(source.catalogueUnavailable == nil)
            let csl = ZoteroExport.item(source)
            #expect(csl["type"] as? String == "personal_communication")
            #expect(csl["title"] as? String == "Re: the convention")
            #expect(names(csl["author"]) == ["Max Shachtman"])
            #expect(names(csl["recipient"]) == ["Albert Glotzer"])
            #expect((csl["issued"] as? [String: Any])?["date-parts"] as? [[Int]] == [[1958, 3, 12]])
            #expect(csl["archive_location"] != nil || csl["note"] != nil)
            #expect(!(csl["note"] as? String ?? "").contains("Stale Sender"))
            #expect(!(csl["note"] as? String ?? "").contains("Memo"))

            // The same facts gathered the legacy way make the same CSL item and the same connector item.
            var legacy = ZoteroSource(fileName: "Letter.pdf", tags: DocumentTags.parse(
                raw: ["1958", "3 March", "Day 12", "Sent With 1958-03-01", "Trotskyism"], labelNumber: nil),
                                      container: [.container: "Box 1"], link: "archivereader://x")
            legacy.itemFields = PDFItemFields(documentKind: "letter", title: "Re: the convention",
                                              recipientPlace: "Chicago, IL")
            var people = ZoteroSidecar()
            people.authors = ["Max Shachtman"]
            people.recipients = ["Albert Glotzer"]
            people.authorPlaces = ["New York"]
            people.recipientPlaces = ["Chicago, IL"]
            legacy.sidecar = people
            #expect(json(csl) == json(ZoteroExport.item(legacy)))
            #expect(json(ZoteroExport.connectorItems([source])) == json(ZoteroExport.connectorItems([legacy])))
        }
    }

    @Test func detachedIdentifiedPDFExportsNoEarlierFactsAndLegacyFileIsGatheredAsBefore() throws {
        try withRoot { root in
            let path = "Letter.pdf"
            try writePDF(Identity(), named: path, in: root)
            try Data(#"{"author_name": "Stale Sender"}"#.utf8).write(to: root.appendingPathComponent("Letter.json"))
            let detached = resolve(path, page: nil, in: root)
            guard case .unavailable(.missing(.companion)) = detached else {
                Issue.record("an identified PDF without its companion is not a legacy file: \(detached)")
                return
            }
            let source = try #require(ZoteroSource.gather(detached, pdf: root.appendingPathComponent(path),
                                                          container: [:]).only)
            let note = ZoteroExport.item(source)["note"] as? String ?? ""
            #expect(note.contains("Catalogue record unavailable: the catalogue companion is missing"))
            #expect(!note.contains("Stale Sender"))
            #expect(ZoteroExport.item(source)["author"] == nil)

            let legacyPath = "Old.pdf"
            try writePDF(nil, named: legacyPath, in: root)
            try Data(#"{"author_name": "Old Sender"}"#.utf8).write(to: root.appendingPathComponent("Old.json"))
            let legacy = resolve(legacyPath, page: nil, in: root)
            guard case .unadopted = legacy else {
                Issue.record("a PDF with neither companion nor identity predates the catalogue: \(legacy)")
                return
            }
            let old = try #require(ZoteroSource.gather(legacy, pdf: root.appendingPathComponent(legacyPath),
                                                       container: [:]).only)
            #expect(names(ZoteroExport.item(old)["author"]) == ["Old Sender"])

            try Data("not JSON".utf8).write(to: companion(path, in: root))
            guard case .unavailable(.invalid(.companion)) = resolve(path, page: nil, in: root) else {
                Issue.record("an unreadable companion is reported, not replaced")
                return
            }
        }
    }

    @Test func onlyAPDFProvablyWithoutIdentityIsLegacy() throws {
        try withRoot { root in
            func classify(_ path: String) -> String {
                let resolution = CatalogueSourceFacts.resolve([.init(relativePath: path)], grantedRoot: root,
                                                              inventoryForForeignOwners: false)[0]
                switch resolution {
                case .unadopted: return "legacy"
                case .catalogue: return "catalogue"
                case .unavailable(let failure): return "\(failure)"
                }
            }
            let identity = CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID())
            let packet = try #require(identity.adding(to: Data("""
                <x:xmpmeta xmlns:x="adobe:ns:meta/">
                <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                </rdf:RDF></x:xmpmeta>
                """.utf8)))
            // The production identity, read by the production reader, with its companion gone.
            try writeCGPDF(metadata: packet, to: root.appendingPathComponent("Separated.pdf"))
            #expect(classify("Separated.pdf") == "missing(ArchiveCore.ItemFacts.Artifact.companion)")
            // An identity the reader cannot accept (two of them) is not proof that there is none.
            let text = try #require(String(data: packet, encoding: .utf8))
            let element = try #require(text.range(of: "<ascat:identity>.*</ascat:identity>", options: .regularExpression))
            let doubled = text.replacingCharacters(in: element, with: String(text[element]) + String(text[element]))
            try writeCGPDF(metadata: Data(doubled.utf8), to: root.appendingPathComponent("Doubled.pdf"))
            #expect(classify("Doubled.pdf") == "invalid(ArchiveCore.ItemFacts.Artifact.pdf)")
            try Data("not a PDF".utf8).write(to: root.appendingPathComponent("Broken.pdf"))
            #expect(classify("Broken.pdf") == "invalid(ArchiveCore.ItemFacts.Artifact.pdf)")

            // A plain PDF is legacy, also through a link the catalogue's strict read refuses, but not with a
            // companion beside it.
            try writeCGPDF(metadata: nil, to: root.appendingPathComponent("Plain.pdf"))
            #expect(classify("Plain.pdf") == "legacy")
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked.pdf"),
                                                       withDestinationURL: root.appendingPathComponent("Plain.pdf"))
            #expect(classify("Linked.pdf") == "legacy")
            try Data("{}".utf8).write(to: companion("Linked.pdf", in: root))
            #expect(classify("Linked.pdf") == "invalid(ArchiveCore.ItemFacts.Artifact.pdf)")
        }
    }

    // MARK: The exact occurrence

    @Test func pageLinkNamesItsDocumentAndAFileLinkDescribesEach() throws {
        try withRoot { root in
            let item = Identity()
            let path = "Merged.pdf"
            try writePDF(item, named: path, in: root, pageCount: 2)
            try record(item, documents: [(letter, letterFields), (clipping, clippingFields)])
                .write(to: companion(path, in: root))

            let second = try #require(sources(resolve(path, page: 2, in: root), path, root).only)
            #expect(ZoteroExport.item(second)["type"] as? String == "article-newspaper")
            #expect(ZoteroExport.item(second)["container-title"] as? String == "Labor Action")
            #expect((ZoteroExport.item(second)["issued"] as? [String: Any])?["literal"] as? String == "1950s")

            let both = sources(resolve(path, page: nil, in: root), path, root)
            #expect(both.map { ZoteroExport.item($0)["type"] as? String } == ["personal_communication", "article-newspaper"])

            let outside = try #require(sources(resolve(path, page: 5, in: root), path, root).only)
            #expect(outside.catalogueUnavailable == "the linked page is not in the catalogue record")
            #expect(CatalogueSourceFacts.year(resolve(path, page: 1, in: root)) == 1958)
            #expect(CatalogueSourceFacts.year(resolve(path, page: 2, in: root)) == nil, "a decade names no year")
            #expect(CatalogueSourceFacts.year(resolve(path, page: nil, in: root)) == nil, "the documents disagree")
        }
    }

    @Test func duplicateBasenameAndRootMoveKeepTheExactOccurrence() throws {
        try withRoot { parent in
            let root = parent.appendingPathComponent("Archive", isDirectory: true)
            for folder in ["Archive", "Archive/A", "Archive/B"] {
                try FileManager.default.createDirectory(at: parent.appendingPathComponent(folder), withIntermediateDirectories: false)
            }
            let a = Identity(), b = Identity()
            try writePDF(a, named: "A/Letter.pdf", in: root)
            try record(a, documents: [(letter, letterFields)]).write(to: companion("A/Letter.pdf", in: root))
            try writePDF(b, named: "B/Letter.pdf", in: root)
            try record(b, documents: [(clipping, clippingFields)]).write(to: companion("B/Letter.pdf", in: root))

            #expect(titles(resolve("B/Letter.pdf", page: nil, in: root), "B/Letter.pdf", root) == ["Strike ends"])
            // A link to a path that is not there is not repaired from a same-named file elsewhere.
            guard case .unavailable(.missing(.pdf)) = resolve("Letter.pdf", page: nil, in: root) else {
                Issue.record("a stale link must not resolve to another occurrence")
                return
            }

            let moved = parent.appendingPathComponent("Moved Archive", isDirectory: true)
            try FileManager.default.moveItem(at: root, to: moved)
            #expect(titles(resolve("A/Letter.pdf", page: nil, in: moved), "A/Letter.pdf", moved) == ["Re: the convention"])
        }
    }

    @Test func splitDocumentWalksForItsOwnerOnlyWhenAllowed() throws {
        try withRoot { root in
            let owner = Identity(), member = Identity()
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Originals"), withIntermediateDirectories: false)
            try writePDF(owner, named: "Originals/Owner.pdf", in: root)
            try record(owner, documents: [(letter, letterFields)]).write(to: companion("Originals/Owner.pdf", in: root))
            try writePDF(member, named: "Part.pdf", in: root)
            try record(member, documents: [(letter, nil)], ownerOf: [letter: owner.file]).write(to: companion("Part.pdf", in: root))

            let quick = CatalogueSourceFacts.resolve([.init(relativePath: "Part.pdf")], grantedRoot: root,
                                                     inventoryForForeignOwners: false, identifyPDF: Self.identify)[0]
            #expect(sources(quick, "Part.pdf", root).only?.catalogueUnavailable
                    == "the file that holds the document's facts was not looked for")
            #expect(CatalogueSourceFacts.year(quick) == nil)
            #expect(titles(resolve("Part.pdf", page: nil, in: root), "Part.pdf", root) == ["Re: the convention"])
        }
    }

    // MARK: Fixtures

    private var letterFields: String {
        """
        "documentDate":\(field(#"{"date":"1958-03-12","uncertain":false}"#)),
        "sentWith":\(field(#"{"date":"1958-03-01","uncertain":false}"#)),
        "documentKind":\(field(#""Letter""#)), "title":\(field(#""Re: the convention""#)),
        "senders":\(field(#"["Max Shachtman"]"#)), "recipients":\(field(#"["Albert Glotzer"]"#)),
        "sendingPlaces":\(field(#"["New York"]"#)), "recipientPlaces":\(field(#"["Chicago, IL"]"#)),
        "subjects":\(field(#"["Trotskyism"]"#)), "byline":{"state":"cleared","fieldRevision":"\(UUID())","origin":"user"}
        """
    }

    private var clippingFields: String {
        """
        "documentDate":\(field(#"{"date":"1950s","uncertain":false}"#)),
        "documentKind":\(field(#""newspaper article""#)), "title":\(field(#""Strike ends""#)),
        "publication":\(field(#""Labor Action""#))
        """
    }

    private func field(_ value: String) -> String {
        #"{"state":"value","value":\#(value),"fieldRevision":"\#(UUID())","origin":"user"}"#
    }

    /// One page per document, in order. A document with nil fields is owned by `ownerOf[id]`.
    private func record(_ item: Identity, documents: [(UUID, String?)], ownerOf: [UUID: UUID] = [:]) -> Data {
        let pages = documents.enumerated().map { index, document in
            #"{"id":"\#(UUID())","physicalIndex":\#(index),"documentID":"\#(document.0)","role":"searchable"}"#
        }
        let entries = documents.map { id, fields in
            let owner = ownerOf[id] ?? item.file
            return #"{"id":"\#(id)","ownerFileID":"\#(owner)""# + (fields.map { #", "fields":{\#($0)}"# } ?? "") + "}"
        }
        return Data("""
        {"schema":1,"fileID":"\(item.file)","contentRevision":"\(item.content)","revision":"\(UUID())","parents":[],
         "pages":[\(pages.joined(separator: ","))],"documents":[\(entries.joined(separator: ","))],"fileFields":{}}
        """.utf8)
    }

    private func resolve(_ path: String, page: Int?, in root: URL) -> CatalogueSourceFacts.Resolution {
        CatalogueSourceFacts.resolve([.init(relativePath: path, page: page)], grantedRoot: root,
                                     inventoryForForeignOwners: true, identifyPDF: Self.identify)[0]
    }

    private func sources(_ resolution: CatalogueSourceFacts.Resolution, _ path: String, _ root: URL) -> [ZoteroSource] {
        ZoteroSource.gather(resolution, pdf: root.appendingPathComponent(path), container: [:])
    }

    private func titles(_ resolution: CatalogueSourceFacts.Resolution, _ path: String, _ root: URL) -> [String?] {
        sources(resolution, path, root).map { ZoteroExport.item($0)["title"] as? String }
    }

    private func names(_ any: Any?) -> [String] {
        (any as? [[String: String]] ?? []).compactMap { $0["literal"] }
    }

    private func json(_ any: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    // Identity carried in a real scratch PDF's title and subject, independent of the JSON (as CatalogueReaderTests).
    private static func identify(_ fd: Int32, _: CatalogueAssociation.Occurrence) throws -> CatalogueReader.PDFIdentity? {
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let bytes = try file.readToEnd(), let pdf = PDFDocument(data: bytes),
              let fileString = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
              let contentString = pdf.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String,
              let fileID = UUID(uuidString: fileString), let content = UUID(uuidString: contentString) else { return nil }
        return .init(fileID: fileID, contentRevision: content, pageCount: pdf.pageCount)
    }

    private func writePDF(_ identity: Identity?, named name: String, in root: URL, pageCount: Int = 1) throws {
        let pdf = PDFDocument()
        for index in 0..<pageCount { pdf.insert(PDFPage(), at: index) }
        if let identity {
            pdf.documentAttributes = [PDFDocumentAttribute.titleAttribute: identity.file.uuidString,
                                      PDFDocumentAttribute.subjectAttribute: identity.content.uuidString]
        }
        try #require(pdf.dataRepresentation()).write(to: root.appendingPathComponent(name))
    }

    private func writeCGPDF(metadata: Data?, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 60, height: 60)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        if let metadata { context.addDocumentMetadata(metadata as CFData) }
        context.beginPDFPage(nil)
        context.fill(box.insetBy(dx: 10, dy: 10))
        context.endPDFPage()
        context.closePDF()
    }

    private func companion(_ path: String, in root: URL) -> URL {
        root.appendingPathComponent(CatalogueRecord.companionFilename(forPDFFilename: path))
    }

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zotero-catalogue-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
