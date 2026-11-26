import Foundation
import PDFKit
import Testing
@testable import ArchiveCore

/// W49.reader-catalogue-scale: a remembered read is reused only for unchanged bytes, a revised snapshot
/// reads only what it is told changed, and a memory made from one root never feeds another.
@Suite("Catalogue read memory", .timeLimit(.minutes(1)))
struct CatalogueReadMemoryTests {
    private let rootID = UUID()

    @Test func unchangedFilesSkipTheIdentityParseAndAnyChangeReadsAgain() throws {
        try withRoot { root in
            let counter = Counter()
            let a = Identity(), b = Identity()
            try writePDF(a, named: "A.pdf", in: root)
            try writePDF(b, named: "B.pdf", in: root)
            try record(for: a, title: "First").write(to: companion("A.pdf", in: root))
            let reader = try reader(root, counter: counter)
            let inventory = CatalogueReader.Inventory(relativePDFPaths: ["A.pdf", "B.pdf"], isComplete: true)

            let first = reader.snapshot(inventory)
            #expect(counter.value == 2)
            let memory = try #require(first.memory)
            #expect(memory.count == 2)

            let again = reader.snapshot(inventory, remembering: memory)
            #expect(counter.value == 2, "Unchanged PDFs are not parsed again")
            #expect(try title(again.facts(at: "A.pdf")) == "First")
            #expect(failure(again.facts(at: "B.pdf").file) == .missing(.companion))

            // A companion edit is read; the PDF's identity is still reused.
            try record(for: a, title: "Second").write(to: companion("A.pdf", in: root))
            let edited = reader.snapshot(inventory, remembering: again.memory)
            #expect(counter.value == 2)
            #expect(try title(edited.facts(at: "A.pdf")) == "Second")

            // A replaced PDF is identified again, and the new identity governs the pair.
            try writePDF(Identity(file: a.file), named: "A.pdf", in: root)
            let replaced = reader.snapshot(inventory, remembering: edited.memory)
            #expect(counter.value == 3)
            #expect(failure(replaced.facts(at: "A.pdf").file) == .invalid(.pdf))
        }
    }

    @Test func revisingCarriesUntouchedFilesAndReresolvesOwners() throws {
        try withRoot { root in
            let counter = Counter()
            let owner = Identity(), member = Identity()
            try writePDF(owner, named: "Owner.pdf", in: root)
            try writePDF(member, named: "Member.pdf", in: root)
            try record(for: owner, title: "Letter").write(to: companion("Owner.pdf", in: root))
            try record(for: member, owner: owner).write(to: companion("Member.pdf", in: root))
            let reader = try reader(root, counter: counter)
            let both = CatalogueReader.Inventory(relativePDFPaths: ["Member.pdf", "Owner.pdf"], isComplete: true)
            let first = reader.snapshot(both)
            #expect(try title(first.facts(at: "Member.pdf")) == "Letter")
            #expect(counter.value == 2)

            // An untouched file is carried even though its companion changed on disk: the caller said it did not.
            try record(for: owner, title: "Changed").write(to: companion("Owner.pdf", in: root))
            let carried = reader.snapshot(revising: first, inventory: both, rereading: [])
            #expect(try title(carried.facts(at: "Member.pdf")) == "Letter")
            #expect(counter.value == 2)

            // Rereading the owner updates the member's document too, without parsing either PDF again.
            let reread = reader.snapshot(revising: carried, inventory: both, rereading: ["Owner.pdf"])
            #expect(try title(reread.facts(at: "Member.pdf")) == "Changed")
            #expect(counter.value == 2)

            // The owner leaves the inventory: the member's document goes with it.
            let gone = CatalogueReader.Inventory(relativePDFPaths: ["Member.pdf"], isComplete: true)
            let removed = reader.snapshot(revising: reread, inventory: gone, rereading: [])
            #expect(failure(removed.facts(at: "Member.pdf").document) == .missing(.owner))

            // A new path is read even when not named.
            try writePDF(Identity(), named: "New.pdf", in: root)
            let added = CatalogueReader.Inventory(relativePDFPaths: ["Member.pdf", "New.pdf"], isComplete: true)
            let grown = reader.snapshot(revising: removed, inventory: added, rereading: [])
            #expect(counter.value == 3)
            #expect(failure(grown.facts(at: "New.pdf").file) == .missing(.companion))
        }
    }

    @Test func memoryRoundTripsAndServesAWarmSnapshotOnlyForItsOwnRoot() throws {
        try withRoot { root in
            let counter = Counter()
            let item = Identity()
            try writePDF(item, named: "Item.pdf", in: root)
            try writePDF(nil, named: "Plain.pdf", in: root)
            try record(for: item, title: "Kept").write(to: companion("Item.pdf", in: root))
            let reader = try reader(root, counter: counter)
            let inventory = CatalogueReader.Inventory(relativePDFPaths: ["Item.pdf", "Plain.pdf"], isComplete: true)
            let memory = try #require(reader.snapshot(inventory).memory)

            let encoded = try PropertyListEncoder().encode(memory)
            let decoded = try PropertyListDecoder().decode(CatalogueReader.ReadMemory.self, from: encoded)
            let warm = try #require(reader.rememberedSnapshot(decoded))
            let parses = counter.value
            #expect(try title(warm.facts(at: "Item.pdf")) == "Kept")
            #expect(failure(warm.facts(at: "Plain.pdf").file) == .missing(.companion))
            #expect(warm.inventory.relativePDFPaths == ["Item.pdf", "Plain.pdf"])

            // Reading with the decoded memory still parses nothing that did not change.
            _ = reader.snapshot(inventory, remembering: decoded)
            #expect(counter.value == parses)

            // Another instance, or another directory at the same path, gets nothing from it.
            let other = try CatalogueReader(grantedRoot: root, rootInstanceID: UUID(), mode: .adopted,
                                            identifyPDF: counter.identify)
            #expect(other.rememberedSnapshot(decoded) == nil)
            _ = other.snapshot(CatalogueReader.Inventory(relativePDFPaths: ["Item.pdf"], isComplete: true),
                               remembering: decoded)
            #expect(counter.value == parses + 1)

            let moved = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-old")
            try FileManager.default.moveItem(at: root, to: moved)
            defer { try? FileManager.default.removeItem(at: moved) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try writePDF(item, named: "Item.pdf", in: root)
            let replacement = try self.reader(root, counter: counter)
            #expect(replacement.rememberedSnapshot(decoded) == nil)
        }
    }

    // MARK: - Fixtures

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }

        func identify(_ fd: Int32, _: CatalogueAssociation.Occurrence) throws -> CatalogueReader.PDFIdentity? {
            lock.withLock { count += 1 }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            guard let bytes = try file.readToEnd(), let pdf = PDFDocument(data: bytes),
                  let fileString = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
                  let contentString = pdf.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String,
                  let fileID = UUID(uuidString: fileString), let content = UUID(uuidString: contentString) else { return nil }
            return .init(fileID: fileID, contentRevision: content, pageCount: pdf.pageCount)
        }
    }

    private struct Identity {
        var file = UUID()
        var content = UUID()
    }

    private let page = UUID()
    private let document = UUID()

    private func reader(_ root: URL, counter: Counter) throws -> CatalogueReader {
        try CatalogueReader(grantedRoot: root, rootInstanceID: rootID, mode: .adopted, identifyPDF: counter.identify)
    }

    private func writePDF(_ identity: Identity?, named name: String, in root: URL) throws {
        let pdf = PDFDocument()
        pdf.insert(PDFPage(), at: 0)
        if let identity {
            pdf.documentAttributes = [PDFDocumentAttribute.titleAttribute: identity.file.uuidString,
                                      PDFDocumentAttribute.subjectAttribute: identity.content.uuidString]
        }
        try #require(pdf.dataRepresentation()).write(to: root.appendingPathComponent(name))
    }

    /// A member's record names its owner's document; an owner's record holds the title.
    private func record(for item: Identity, owner: Identity? = nil, title: String = "") -> Data {
        let ownerFile = owner?.file ?? item.file
        let fields = owner == nil
            ? #", "fields":{"title":{"state":"value","value":"\#(title)","fieldRevision":"\#(UUID())","origin":"user"}}"#
            : ""
        return Data("""
        {"schema":1,"fileID":"\(item.file)","contentRevision":"\(item.content)","revision":"\(UUID())","parents":[],
         "pages":[{"id":"\(owner == nil ? page : UUID())","physicalIndex":0,"documentID":"\(document)","role":"searchable"}],
         "documents":[{"id":"\(document)","ownerFileID":"\(ownerFile)"\(fields)}],"fileFields":{}}
        """.utf8)
    }

    private func title(_ facts: ItemFacts) throws -> String? {
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

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalogue-memory-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
