import SwiftUI
import AppKit

/// The right pane when a page pair has no OCR text page but its image page carries a text layer — a
/// single-page PDF, which is almost all of the corpus. Selectable plain text at the viewer's text size
/// (`DocumentViewerModel.textScale`), so Zoom In / Out on the text pane changes it
/// (W40.fix-reader-text-zoom: at a fixed `.body` font it did nothing visible). Read-only.
///
/// Find highlights its matches as the PDF panes do, the current hit in the find colour
/// (W40.fix-reader-find-both-panes); the image pane beside it scrolls to that hit.
struct ExtractedTextPane: View {
    let text: String
    let scale: CGFloat
    /// The searched query and which of its matches is the current hit; nil = no find highlight.
    var find: (query: String, current: Int?)? = nil

    static let baseSize = NSFont.systemFontSize

    var body: some View {
        ScrollView {
            Text(Self.highlighted(text, find: find))
                .textSelection(.enabled)
                .font(.system(size: Self.baseSize * scale))
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    /// `text` with every match of the query behind the PDF panes' match yellow, and the current hit
    /// behind the system find-highlight colour.
    static func highlighted(_ text: String, find: (query: String, current: Int?)?) -> AttributedString {
        var out = AttributedString(text)
        guard let find else { return out }
        for (k, r) in DocumentFindScanner.ranges(of: find.query, in: text).enumerated() {
            guard let lower = AttributedString.Index(r.lowerBound, within: out),
                  let upper = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lower..<upper].backgroundColor = k == find.current
                ? Color(nsColor: .findHighlightColor) : Color(nsColor: .systemYellow.withAlphaComponent(0.5))
        }
        return out
    }
}
