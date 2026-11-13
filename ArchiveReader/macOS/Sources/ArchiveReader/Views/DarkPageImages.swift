import AppKit
import SwiftUI
import CoreImage

/// View ▸ Invert Image Colors (W40.reader-image-invert, owner 2026-11-13: "make images readable while reducing the
/// amount of white"). A view of the page images only: the file is never changed, and Copy Image still copies the scan.
///
/// The look was chosen on corpus pages (typed, ditto, handwritten, a cover with a seal), against a plain dimmed view.
/// Dimming to half keeps the page's look but halves its contrast, and the paper is still the brightest thing on
/// screen. The inversion reads better: the paper goes near black and the ink near white. Three details make it work:
/// - It is done on sRGB values, not light. Core Image works in linear light, where a photographed page's grey paper
///   (about 0.7) inverts to a light grey, so the cube is given its colour space and does not depend on the context's.
/// - The hue is kept (Safari's smart invert): only the lightness turns over, so purple ditto ink stays purple and a
///   red stamp stays red, rather than going green and cyan.
/// - Levels first: the photographed scans' paper is grey, not white, so 0.22…0.78 is stretched to the full range
///   before the turn, and the result is kept inside 0.10…0.88, dark grey paper and soft white ink rather than glare.
enum DarkPageImages {
    static let blackPoint: Float = 0.22, whitePoint: Float = 0.78
    static let darkest: Float = 0.10, lightest: Float = 0.88

    /// The mapping on one sRGB colour, 0…1 per channel.
    static func map(_ r0: Float, _ g0: Float, _ b0: Float) -> (Float, Float, Float) {
        func level(_ v: Float) -> Float { min(1, max(0, (v - blackPoint) / (whitePoint - blackPoint))) }
        let r = level(r0), g = level(g0), b = level(b0)
        // Shifting every channel by the same amount keeps the hue and the spread; this shift sends the HSL
        // lightness (max + min) / 2 to 1 minus itself.
        let shift = 1 - max(r, g, b) - min(r, g, b)
        func out(_ v: Float) -> Float { darkest + (lightest - darkest) * min(1, max(0, v + shift)) }
        return (out(r), out(g), out(b))
    }

    static let cubeDimension = 24

    private static let cubeData: Data = {
        let n = cubeDimension
        var values = [Float]()
        values.reserveCapacity(n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let (x, y, z) = map(Float(r) / Float(n - 1), Float(g) / Float(n - 1), Float(b) / Float(n - 1))
            values += [x, y, z, 1]
        } } }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }()

    /// A fresh filter each call: a layer keeps its filter, and a shared one would carry another's input image.
    static func filter() -> CIFilter {
        let filter = CIFilter(name: "CIColorCubeWithColorSpace")!
        filter.setValue(cubeDimension, forKey: "inputCubeDimension")
        filter.setValue(cubeData, forKey: "inputCubeData")
        filter.setValue(CGColorSpace(name: CGColorSpace.sRGB)!, forKey: "inputColorSpace")
        return filter
    }

    /// Puts the filter on a view (the image pane's PDFView) or takes it off. Core Animation applies it to the view's
    /// drawing and every layer under it, so PDFKit's page tiles, the placeholder bitmap and the selection all turn.
    @MainActor static func apply(_ on: Bool, to view: NSView) {
        guard on != !(view.contentFilters.isEmpty) else { return }
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        view.contentFilters = on ? [filter()] : []
    }

    @MainActor private static let context = CIContext(options: [.cacheIntermediates: false])
    @MainActor private static let rendered: NSCache<CGImage, CGImage> = {
        let cache = NSCache<CGImage, CGImage>()
        cache.countLimit = 400   // a contact sheet of a long run of files, and no more
        return cache
    }()

    /// The same look drawn into a bitmap, for the page tiles; kept per picture, so a redraw does not render it again.
    @MainActor static func darkened(_ image: CGImage) -> CGImage {
        if let done = rendered.object(forKey: image) { return done }
        let input = CIImage(cgImage: image)
        let filter = filter()
        filter.setValue(input, forKey: kCIInputImageKey)
        guard let output = filter.outputImage,
              let done = context.createCGImage(output, from: input.extent, format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return image }
        rendered.setObject(done, forKey: image)
        return done
    }
}

/// The toolbar's Invert Image Colors button, in the document window and the preview sheet, beside the page views.
struct InvertImagesToggle: View {
    @ObservedObject var model: DocumentViewerModel
    let idPrefix: String

    var body: some View {
        Toggle(isOn: $model.invertingImages) {
            Label(ReaderCommand.invertImages.title, systemImage: "circle.lefthalf.filled")
        }
        .toggleStyle(.button)
        .help("\(ReaderCommand.invertImages.help) (\(ReaderCommand.invertImages.glyph))")
        .accessibilityIdentifier("\(idPrefix).invertImages")
    }
}
