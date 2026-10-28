import AppKit
import SwiftUI
import XCTest
@testable import ArchiveNotes

/// W40.fix-notes-preview-popover-text: the chip preview's message popover was a fixed 300 × 140 with the text
/// free to truncate, and in the VM the no-access message's last line read "…not enough — choose…". The
/// popover now takes the hosting controller's preferred size and the text keeps its full wrapped height, so
/// the view must ask for enough height to show every line and the button.
@MainActor
final class PreviewMessageSizingTests: XCTestCase {
    func testNoAccessMessageGetsTheHeightItsWrappedTextNeeds() {
        let view = PreviewMessageView(
            message: ReaderPreviewPopover.noAccessMessage,
            action: .init(title: "Choose Archive Folder\u{2026}", perform: {})
        )
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        let size = host.view.fittingSize

        XCTAssertEqual(size.width, PreviewMessageView.width, accuracy: 0.5)
        // The text alone, wrapped at the view's width less its horizontal padding.
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let text = (ReaderPreviewPopover.noAccessMessage as NSString).boundingRect(
            with: NSSize(width: PreviewMessageView.width - 32, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        XCTAssertGreaterThan(text.height, font.pointSize * 3, "the message should wrap to at least four lines")
        // Text, the 12 pt gap, a bordered button and the vertical padding all have to fit.
        XCTAssertGreaterThanOrEqual(size.height, text.height + 12 + 20,
                                    "the popover is shorter than its wrapped message plus the button")
    }
}
