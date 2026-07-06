import Foundation
import PDFKit
import AppKit

/// Renders PDF pages to temporary JPEG files for use as OCR input.
struct PDFToImageConverter {

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
