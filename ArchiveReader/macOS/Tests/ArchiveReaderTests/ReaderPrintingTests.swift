import XCTest
import PDFKit
import AppKit
import ArchiveCore
@testable import ArchiveReader

/// W49.reader-print-open-app: File ▸ Print… prints the archival file itself — every page of a PDF, a JPEG original
/// fitted to one page — and the menu items and document-window buttons read the command table. No operation is run,
/// so no panel or printer is involved; scratch files only.
@MainActor
final class ReaderPrintingTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("reader-print-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAPDFPrintsEveryPageWithThePanel() throws {
        let url = dir.appendingPathComponent("Box 3 letter.pdf")
        XCTAssertTrue(TestPDFBuilder.write(pages: ["scan one", "OCR one", "scan two", "OCR two"], to: url))
        let before = try Data(contentsOf: url)
        let operation = try ReaderPrinting.operation(for: url).get()
        XCTAssertTrue(operation.showsPrintPanel)
        XCTAssertEqual(operation.jobTitle, "Box 3 letter")
        var range = NSRange()
        XCTAssertTrue(operation.view?.knowsPageRange(&range) == true)
        XCTAssertEqual(range.length, 4, "every page of the PDF, not only the one on screen")
        XCTAssertEqual(try Data(contentsOf: url), before, "printing reads the file and never writes it")
    }

    func testAJPEGPrintsFittedToOnePage() throws {
        let url = dir.appendingPathComponent("letter.jpg")
        try Self.jpeg(width: 60, height: 40).write(to: url)
        let shared = (NSPrintInfo.shared.horizontalPagination, NSPrintInfo.shared.orientation)
        let operation = try ReaderPrinting.operation(for: url).get()
        let view = try XCTUnwrap(operation.view as? NSImageView)
        XCTAssertEqual(view.frame.size, NSSize(width: 60, height: 40), "drawn at its pixel size")
        XCTAssertEqual(operation.printInfo.horizontalPagination, .fit)
        XCTAssertEqual(operation.printInfo.verticalPagination, .fit)
        XCTAssertEqual(operation.printInfo.orientation, .landscape, "a wide scan prints across the page")
        XCTAssertEqual(operation.jobTitle, "letter")
        XCTAssertTrue(NSPrintInfo.shared.horizontalPagination == shared.0 && NSPrintInfo.shared.orientation == shared.1,
                      "the app's shared print settings are not changed")
    }

    func testAFileThatCannotBePrintedSaysWhy() throws {
        let missing = dir.appendingPathComponent("gone.pdf")
        XCTAssertEqual(Self.refusal(missing), .unreadable("gone.pdf"))
        let garbage = dir.appendingPathComponent("not.jpg")
        try Data("not an image".utf8).write(to: garbage)
        XCTAssertEqual(Self.refusal(garbage), .unreadable("not.jpg"))

        let locked = dir.appendingPathComponent("locked.pdf")
        try Self.writePDF(to: locked, info: [kCGPDFContextUserPassword: "secret", kCGPDFContextOwnerPassword: "owner"])
        XCTAssertEqual(Self.refusal(locked), .notPrintable("locked.pdf"))
        let noPrint = dir.appendingPathComponent("no-print.pdf")
        try Self.writePDF(to: noPrint, info: [kCGPDFContextOwnerPassword: "owner", kCGPDFContextAllowsPrinting: false])
        XCTAssertEqual(Self.refusal(noPrint), .notPrintable("no-print.pdf"))
        XCTAssertEqual(ReaderPrinting.Refusal.notPrintable("no-print.pdf").message, "“no-print.pdf” does not allow printing.")
    }

    /// The document window prints the JPEG original while it is shown, else the PDF; Open in Default App, the PDF.
    func testTheDocumentWindowPrintsTheShownFile() throws {
        let main = dir.appendingPathComponent(ReaderArchiveLayout.mainDirectoryName)
        let jpegs = dir.appendingPathComponent(ReaderArchiveLayout.jpegDirectoryName)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jpegs, withIntermediateDirectories: true)
        let pdf = main.appendingPathComponent("letter.pdf")
        XCTAssertTrue(TestPDFBuilder.write(pages: ["scan", "OCR"], to: pdf))
        let jpeg = jpegs.appendingPathComponent("letter.jpg")
        try Self.jpeg(width: 40, height: 50).write(to: jpeg)
        let index = JPEGPartnerIndex(jpegRoot: jpegs, scan: CorpusWalker.scanFingerprints(root: jpegs))
        let marker = RootMarker(guid: UUID(), name: "scratch", kind: .reader, createdAt: Date())
        let target = ArchiveLinkTarget(rootPath: dir.path, marker: marker, mainRootPath: main.path)
        let suiteName = "ReaderPrinting-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let reader = DocumentViewerModel(persists: true, imageSourcePreferences: DocumentImageSourcePreferences(defaults: defaults),
                                         thumbnailer: nil)
        XCTAssertNil(reader.printFileURL, "nothing open, nothing to print")
        reader.updateArchiveContext(target: target, index: index)
        reader.load(DocumentSelection(filePaths: [pdf.path]))
        XCTAssertEqual(reader.printFileURL?.lastPathComponent, "letter.pdf")
        reader.toggleImageSource()
        XCTAssertTrue(reader.isShowingJPEG)
        XCTAssertEqual(reader.printFileURL?.resolvingSymlinksInPath().pathComponents.suffix(2),
                       jpeg.resolvingSymlinksInPath().pathComponents.suffix(2))
        XCTAssertEqual(reader.currentURL?.lastPathComponent, "letter.pdf", "Open in Default App opens the PDF")
        reader.setShowingAllPages(true)
        XCTAssertEqual(reader.printFileURL?.lastPathComponent, "letter.pdf", "the contact sheet prints the PDF")
    }

    func testTheCommandsAreInTheTable() {
        XCTAssertEqual(ReaderCommand.print.title, "Print…")
        XCTAssertEqual(ReaderCommand.print.key, CommandKey("p"))
        XCTAssertEqual(ReaderCommand.openInDefaultApp.title, "Open in Default App")
        XCTAssertNil(ReaderCommand.openInDefaultApp.key)
        XCTAssertEqual(ReaderCommand.print.context, .menuBar)
    }

    private static func refusal(_ url: URL) -> ReaderPrinting.Refusal? {
        if case .failure(let refusal) = ReaderPrinting.operation(for: url) { return refusal }
        return nil
    }

    private static func writePDF(to url: URL, info: [CFString: Any]) throws {
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
        ctx.beginPDFPage(nil)
        ctx.setFillColor(.black)
        ctx.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
        ctx.endPDFPage()
        ctx.closePDF()
    }

    private static func jpeg(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                 bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<width { for y in 0..<height { rep.setColor(.gray, atX: x, y: y) } }
        return try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
    }
}
