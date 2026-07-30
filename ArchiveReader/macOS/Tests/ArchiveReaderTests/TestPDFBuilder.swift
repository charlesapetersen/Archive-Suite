import PDFKit
import AppKit
import CoreText

/// Synthesizes real PDFs with genuinely selectable text, for tests that must exercise PDFKit's own
/// text extraction / `findString` rather than a stub. Used by the find + viewer tests.
///
/// FILE SAFETY: `write(pages:to:)` only ever writes where the caller points it — every caller uses an
/// `mktemp`-style scratch directory. Nothing here goes near a real corpus.
enum TestPDFBuilder {

    /// A multi-page PDF whose page *i* contains `pages[i]` as drawn, selectable text.
    /// Interleave image-ish and text-ish content by ordering the strings (this suite doesn't need real
    /// raster pages — the page-pair model is page-INDEX arithmetic, and text pages make assertions exact).
    static func textPDF(pages: [String]) -> PDFDocument {
        let pageRect = CGRect(x: 0, y: 0, width: 400, height: 400)
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var box = pageRect
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for text in pages {
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(string: text,
                                          attributes: [.font: NSFont.systemFont(ofSize: 14)])
            let framesetter = CTFramesetterCreateWithAttributedString(attr)
            let path = CGPath(rect: pageRect.insetBy(dx: 20, dy: 20), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return PDFDocument(data: data as Data)!
    }

    /// The same PDF, written to `url` (a scratch path) so a viewer model can load it from disk.
    @discardableResult
    static func write(pages: [String], to url: URL) -> Bool {
        textPDF(pages: pages).write(to: url)
    }
}
