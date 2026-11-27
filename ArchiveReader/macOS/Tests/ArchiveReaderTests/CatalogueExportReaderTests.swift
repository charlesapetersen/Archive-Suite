import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W49.storage-export: Selection ▸ Export with Catalogue Records… copies the selection's pairs, with what they depend
/// on, into a new folder outside the archive. Every tree is a scratch directory.
@MainActor
final class CatalogueExportReaderTests: XCTestCase {
    private let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("CatalogueExportReader-\(UUID().uuidString)", isDirectory: true)
    private nonisolated var root: URL { base.appendingPathComponent("Archive", isDirectory: true) }
    private nonisolated var out: URL { base.appendingPathComponent("Out", isDirectory: true) }

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testASplitMemberExportsWithItsOwnerAndSaysSo() throws {
        let box = root.appendingPathComponent("Box 17", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        let owner = (file: UUID(), content: UUID())
        let member = (file: UUID(), content: UUID())
        let document = UUID()
        // The fixture PDFs carry their identity as their bytes; the injected identify reads it back.
        for (name, item) in [("0001.pdf", member), ("0002.pdf", owner)] {
            try Data("\(item.file) \(item.content)".utf8).write(to: box.appendingPathComponent(name))
            let fields = item.file == owner.file
                ? #", "fields":{"title":{"state":"value","value":"From the owner","fieldRevision":"\#(UUID())","origin":"user"}}"#
                : ""
            try Data("""
            {"schema":1,"fileID":"\(item.file)","contentRevision":"\(item.content)","revision":"\(UUID())","parents":[],
             "pages":[{"id":"\(UUID())","physicalIndex":0,"documentID":"\(document)","role":"searchable"}],
             "documents":[{"id":"\(document)","ownerFileID":"\(owner.file)"\(fields)}],"fileFields":{}}
            """.utf8).write(to: box.appendingPathComponent(CatalogueRecord.companionFilename(forPDFFilename: name)))
        }
        let identify: CatalogueReader.IdentifyPDF = { fd, _ in
            let text = String(decoding: try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data(), as: UTF8.self)
            let parts = text.split(separator: " ").compactMap { UUID(uuidString: String($0)) }
            return parts.count == 2 ? .init(fileID: parts[0], contentRevision: parts[1], pageCount: 1) : nil
        }
        let rootPath = CorpusWalker.discoveredPathPrefix(for: root) ?? root.path
        let selected = URL(fileURLWithPath: rootPath).appendingPathComponent("Box 17/0001.pdf")
        let destination = out.appendingPathComponent(NavigationModel.catalogueExportName([selected]))
        XCTAssertEqual(destination.lastPathComponent, "0001 (with catalogue)")

        let result = NavigationModel.exportCatalogue([selected], root: root, to: destination, identifyPDF: identify)
        let manifest = try result.get()
        XCTAssertEqual(manifest.files.map(\.path), ["Box 17/0001.pdf", "Box 17/0002.pdf"])
        for name in ["0001.pdf", "0002.pdf", CatalogueRecord.companionFilename(forPDFFilename: "0002.pdf")] {
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Box 17/" + name)),
                           try Data(contentsOf: box.appendingPathComponent(name)))
        }
        XCTAssertEqual(NavigationModel.catalogueExportMessage(result, name: destination.lastPathComponent),
                       "Exported 1 document, with 1 more file their records depend on, to “0001 (with catalogue)”. "
                           + "Copy the whole folder to keep the catalogue facts.")

        // Again to the same name: refused, and the first export is untouched.
        let again = NavigationModel.exportCatalogue([selected], root: root, to: destination, identifyPDF: identify)
        XCTAssertEqual(NavigationModel.catalogueExportMessage(again, name: destination.lastPathComponent),
                       "Nothing was exported: Something already has that name. Choose a new folder name.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [destination.lastPathComponent])

        let stray = out.appendingPathComponent("stray.pdf")
        try Data("not in the archive".utf8).write(to: stray)
        let outside = NavigationModel.exportCatalogue([stray], root: root, to: out.appendingPathComponent("B"), identifyPDF: identify)
        XCTAssertThrowsError(try outside.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("B").path))
    }

    func testTheFolderNameAndTheRefusals() {
        XCTAssertEqual(NavigationModel.catalogueExportName([URL(fileURLWithPath: "/a/1.pdf"), URL(fileURLWithPath: "/a/2.pdf")]),
                       "Catalogue export")
        XCTAssertEqual(ReaderCommand.exportWithCatalogue.title, "Export with Catalogue Records…")
        XCTAssertNil(ReaderCommand.exportWithCatalogue.key)
    }
}
