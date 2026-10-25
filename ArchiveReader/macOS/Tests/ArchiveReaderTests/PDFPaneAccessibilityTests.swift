import AppKit
import PDFKit
import XCTest
@testable import ArchiveReader

@MainActor
final class PDFPaneAccessibilityTests: XCTestCase {
    func testPageTitlesLeavePDFKitsTextExposedAcrossDocumentChanges() throws {
        let view = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        let window = NSWindow(contentRect: view.bounds, styleMask: [], backing: .buffered, defer: true)
        window.contentView = view

        for (title, text) in [("Original image page", "Original fixture content"),
                              ("OCR text page", "Selectable OCR words after cycling")] {
            view.pageAccessibilityTitle = title
            view.document = TestPDFBuilder.textPDF(pages: [text])
            view.displayMode = .singlePage
            view.autoScales = true
            view.layoutDocumentView()
            let elements = descendants(of: view)
            let pages = elements.filter { $0.accessibilityRole() == .pageRole }
            XCTAssertEqual(pages.count, 1, "the page node must stay in PDFKit's tree")
            XCTAssertEqual(try XCTUnwrap(pages.first).accessibilityTitle(), title)
            let textValues = elements.filter { $0.accessibilityRole() == .staticText }
                .compactMap { $0.accessibilityValue() as? String }.joined(separator: " ")
            XCTAssertTrue(textValues.contains(text), "page naming must preserve PDFKit's text descendants")
            XCTAssertEqual(view.document?.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), text)
        }
    }

    private func descendants(of element: any NSAccessibilityProtocol) -> [any NSAccessibilityProtocol] {
        (element.accessibilityChildren() ?? []).flatMap { child -> [any NSAccessibilityProtocol] in
            guard let accessible = child as? any NSAccessibilityProtocol else { return [] }
            return [accessible] + descendants(of: accessible)
        }
    }
}
