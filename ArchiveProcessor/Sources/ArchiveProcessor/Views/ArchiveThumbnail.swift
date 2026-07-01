import SwiftUI
import AppKit
import ImageIO
import PDFKit

/// Reusable thumbnail for review UIs — loads a downscaled image (or first PDF page),
/// with optional on-screen rotation. Shared by the box/folder confirmation and manual
/// tagging sheets.
struct ArchiveThumbnail: View {
    let url: URL
    var maxSize: Int = 800
    var rotationDegrees: Int = 0

    var body: some View {
        if let nsImage = Self.load(url: url, maxSize: maxSize) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .rotationEffect(.degrees(Double(rotationDegrees)))
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.1))
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }

    static func load(url: URL, maxSize: Int) -> NSImage? {
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            let scale = CGFloat(maxSize) / max(bounds.width, bounds.height)
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = NSImage(size: size)
            image.lockFocus()
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.setFillColor(CGColor.white)
                ctx.fill(CGRect(origin: .zero, size: size))
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx)
            }
            image.unlockFocus()
            return image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
