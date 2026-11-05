import SwiftUI
import AppKit

/// The right pane when a page pair has no OCR text page but its image page carries a text layer — a
/// single-page PDF, which is almost all of the corpus. Selectable plain text at the viewer's text size
/// (`DocumentViewerModel.textScale`), so Zoom In / Out on the text pane changes it
/// (W40.fix-reader-text-zoom: at a fixed `.body` font it did nothing visible). Read-only.
struct ExtractedTextPane: View {
    let text: String
    let scale: CGFloat

    static let baseSize = NSFont.systemFontSize

    var body: some View {
        ScrollView {
            Text(text)
                .textSelection(.enabled)
                .font(.system(size: Self.baseSize * scale))
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }
}
