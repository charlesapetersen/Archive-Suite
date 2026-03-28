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

        // Render at 2x scale for good OCR quality (typical archival photos are high-res)
        let pageRect = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        let width = Int(pageRect.width * scale)
        let height = Int(pageRect.height * scale)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        // White background
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Scale and draw
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)

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
