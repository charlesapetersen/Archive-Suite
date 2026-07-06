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
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
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
        // Decode off the main thread so grids/strips of thumbnails never stall the UI.
        .task(id: url) {
            image = await Self.loadAsync(url: url, maxSize: maxSize)
        }
    }

    /// Async loader: decodes the image thumbnail off the main actor (image case) and returns an
    /// NSImage on the caller's actor. The PDF path stays on the caller (rare, small count).
    static func loadAsync(url: URL, maxSize: Int) async -> NSImage? {
        if url.pathExtension.lowercased() == "pdf" {
            return load(url: url, maxSize: maxSize)
        }
        return await loadImageThumbnail(url: url, maxSize: maxSize)
    }

    /// Decode a raster image to a downscaled thumbnail off the main actor (via a detached task) and
    /// return an NSImage on the caller's actor. Shared by `loadAsync` and the review-row loaders so a
    /// burst of thumbnails never blocks the UI. Callers handle PDFs themselves (page rendering differs).
    static func loadImageThumbnail(url: URL, maxSize: Int) async -> NSImage? {
        let data: Data? = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceThumbnailMaxPixelSize: maxSize,
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return nil }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, cg, nil)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return out as Data
        }.value
        return data.flatMap { NSImage(data: $0) }
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
