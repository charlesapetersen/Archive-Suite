import Foundation
import PDFKit
import AppKit

/// Renders PDF pages to temporary JPEG files for use as OCR input.
struct PDFToImageConverter {

    /// True iff `url` is a PDF with more than one page. Drives the auto-route: a dropped multi-page
    /// PDF is an assembled document, so it goes through the re-OCR transform (render each page → OCR →
    /// one interleaved image/OCR-text PDF) rather than the image/tagging pipeline. Opening the document
    /// reads only its page tree, not page content, so this is cheap enough to call once per input at
    /// run start. A non-PDF, an unreadable PDF, or a single-page PDF returns false.
    static func isMultiPagePDF(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "pdf",
              let document = PDFDocument(url: url) else { return false }
        return document.pageCount > 1
    }

    /// If the URL points to a PDF, render its first page to a temporary JPEG and return
    /// the temp file URL. For non-PDF files, returns the original URL unchanged.
    static func imageURL(for url: URL) -> URL {
        guard url.pathExtension.lowercased() == "pdf" else { return url }
        guard let jpegURL = renderFirstPage(of: url) else { return url }
        return jpegURL
    }

    /// Render the first page of a PDF to a JPEG file in the temp directory.
    /// Returns the URL of the temporary JPEG, or nil on failure.
    private static func renderFirstPage(of pdfURL: URL) -> URL? {
        guard let document = PDFDocument(url: pdfURL),
              let page = document.page(at: 0) else { return nil }
        return renderPageToJPEG(page)
    }

    /// Render EVERY page of a PDF to a temporary JPEG, preserving page order. Used by the
    /// "re-OCR multi-page PDF" mode, which OCRs each page image then rebuilds an alternating
    /// image / OCR-text PDF. Returns nil if the PDF can't be opened or has no pages, and nil
    /// (fail-loud — never a partial set) if ANY page fails to render, so the caller can't
    /// silently drop an archival page in this no-undo output path. The caller owns the returned
    /// temp files and must delete them.
    static func renderAllPages(of pdfURL: URL) -> [URL]? {
        guard let document = PDFDocument(url: pdfURL) else { return nil }
        let count = document.pageCount
        guard count > 0 else { return nil }

        var urls: [URL] = []
        urls.reserveCapacity(count)
        for i in 0..<count {
            guard let page = document.page(at: i), let jpegURL = renderPageToJPEG(page) else {
                for u in urls { try? FileManager.default.removeItem(at: u) }
                return nil
            }
            urls.append(jpegURL)
        }
        return urls
    }

    /// Render one PDF page to a temporary JPEG in the temp directory.
    /// Returns the URL of the temporary JPEG, or nil on failure.
    private static func renderPageToJPEG(_ page: PDFPage) -> URL? {
        // Size to the VISIBLE page — the media box is unrotated, so swap W/H when the page's /Rotate
        // is 90/270; otherwise a rotated scan renders with the wrong aspect and gets clipped.
        let pageRect = page.bounds(for: .mediaBox)
        let rotatedQuarter = abs(page.rotation) % 180 == 90
        let visW = rotatedQuarter ? pageRect.height : pageRect.width
        let visH = rotatedQuarter ? pageRect.width : pageRect.height
        guard visW > 0, visH > 0 else { return nil }

        // Render at ~2x for OCR quality, but clamp the long edge so an oversized page can't allocate a
        // multi-GB bitmap (matches the OCR pipeline's max dimension).
        let longEdge = max(visW, visH)
        let scale = min(2.0, CGFloat(ImageEncoding.maxOCRDimension) / longEdge)
        let width = max(1, Int(visW * scale))
        let height = max(1, Int(visH * scale))
        let pixelSize = CGSize(width: width, height: height)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        // White background (JPEG has no alpha), then composite the rotation-aware page thumbnail —
        // `PDFPage.thumbnail(of:for:)` bakes in the page's /Rotate so content stays upright.
        context.setFillColor(CGColor.white)
        context.fill(CGRect(origin: .zero, size: pixelSize))
        let thumb = page.thumbnail(of: pixelSize, for: .mediaBox)
        guard let cgThumb = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        context.draw(cgThumb, in: CGRect(origin: .zero, size: pixelSize))

        guard let cgImage = context.makeImage() else { return nil }

        // Write as JPEG
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")

        guard let dest = CGImageDestinationCreateWithURL(
            tempURL as CFURL, "public.jpeg" as CFString, 1, nil
        ) else { return nil }

        CGImageDestinationAddImage(dest, cgImage, [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ] as CFDictionary)

        guard CGImageDestinationFinalize(dest) else { return nil }
        return tempURL
    }
}
