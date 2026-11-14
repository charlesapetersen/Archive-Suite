import PDFKit
import AppKit
import CoreText
import ArchiveCore

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
        PDFDocument(data: textPDFData(pages: pages))!
    }

    /// The PDF's bytes; `carried` (one entry per page) is written as the searchable form's XMP list
    /// (`PDFHeaderCarrier`, W42.int-s5-searchable). Quartz keeps a document's metadata outside PDF/A.
    static func textPDFData(pages: [String], carried: [String?]? = nil) -> Data {
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
        if let carried {
            let packet = Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            </rdf:RDF></x:xmpmeta>
            """.utf8)
            ctx.addDocumentMetadata(PDFHeaderCarrier.adding(pages: carried, to: packet)! as CFData)
        }
        ctx.closePDF()
        return data as Data
    }

    /// A PDF with searchable pages written to `url` (a scratch path): its bytes as drawn, so the XMP stays.
    @discardableResult
    static func write(pages: [String], carried: [String?], to url: URL) -> Bool {
        (try? textPDFData(pages: pages, carried: carried).write(to: url)) != nil
    }

    /// The same PDF, written to `url` (a scratch path) so a viewer model can load it from disk.
    @discardableResult
    static func write(pages: [String], to url: URL) -> Bool {
        textPDF(pages: pages).write(to: url)
    }
}
