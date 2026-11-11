import Foundation
import CoreML
import ImageIO
import CoreGraphics

/// PP-LCNet_x1_0_doc_ori (PaddleX, Apache-2.0), bundled as `PPLCNetDocOri.mlpackage`: a 3 MB classifier of how
/// far a page is turned clockwise (0, 90, 180, 270). It is the check on local Vision in the agreement rule
/// (`RotationMode.agreement`, W46.rotation-default), never a route alone: it flips right-to-left pages (Hebrew 73 of
/// 80 turns, `segbench-results/rotation-routes.md`). Converted and checked against Paddle by
/// `scripts/segbench/rotation_lcnet_coreml.py`; the app's answers are checked against the bench's by
/// `scripts/test-rotation-lcnet.sh`.
///
/// The input is made as PaddleX makes it (`inputImage`). Returns the clockwise correction, or nil when the model or the image cannot be loaded.
enum RotationLCNet {
    /// Where the compiled model is; the bundle's by default. A harness compiled outside the app sets this first.
    nonisolated(unsafe) static var modelURLOverride: URL?

    private static let shortSide = 256
    private static let crop = 224

    private final class Loaded: @unchecked Sendable {
        let model: MLModel?
        init() {
            let url = RotationLCNet.modelURLOverride
                ?? Bundle.main.url(forResource: "PPLCNetDocOri", withExtension: "mlmodelc")
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            model = url.flatMap { try? MLModel(contentsOf: $0, configuration: config) }
        }
    }
    private static let loaded = Loaded()
    // Prediction is blocking work; it stays off Swift's cooperative pool like Vision's (VisionQueue).
    private static let queue = VisionQueue(name: "ArchiveProcessor.RotationLCNet", width: 2)

    /// Whether the bundled model loads (false in a build without it).
    static var isAvailable: Bool { loaded.model != nil }

    static func detectCorrection(imageURL: URL) async -> Int? {
        await queue.run { inputImage(from: imageURL).flatMap { correction(for: $0) } }
    }

    /// The label's probabilities, index i = turned i * 90 clockwise; nil on failure. The correction is the
    /// complement of the most probable turn.
    static func probabilities(for image: CGImage) -> [Float]? {
        guard let model = loaded.model,
              let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              let value = try? MLFeatureValue(cgImage: image, constraint: constraint, options: nil),
              let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": value]),
              let out = try? model.prediction(from: provider),
              let probs = out.featureValue(for: "probs")?.multiArrayValue, probs.count == 4 else { return nil }
        return (0..<4).map { probs[$0].floatValue }
    }

    private static func correction(for image: CGImage) -> Int? {
        guard let p = probabilities(for: image), let turn = p.indices.max(by: { p[$0] < p[$1] }) else { return nil }
        return (360 - turn * 90) % 360
    }

    /// The model's input as PaddleX makes it, so the app answers as the bench measured: the displayed image (EXIF
    /// applied), resized to short side 256 by OpenCV's INTER_LINEAR arithmetic (`cv2.resize`: half-pixel centres,
    /// 11-bit fixed-point weights, no antialiasing), then the centre 224 x 224 (`(w - 224) // 2`).
    static func inputImage(from imageURL: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int,
              pw > 0, ph > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pw, ph),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return input(from: image)
    }

    /// `inputImage` on a decoded image.
    static func input(from image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let src = rgbaPixels(image) else { return nil }
        let scale = Double(shortSide) / Double(min(w, h))
        let dw = Int((Double(w) * scale).rounded(.toNearestOrEven)), dh = Int((Double(h) * scale).rounded(.toNearestOrEven))
        let x0 = max(0, (dw - crop) / 2), y0 = max(0, (dh - crop) / 2)
        let taps = { (dst: Int, srcLen: Int, dstLen: Int) -> (Int, Int, Int32, Int32) in
            let f = Float((Double(dst) + 0.5) * (Double(srcLen) / Double(dstLen)) - 0.5)
            var s = Int(f.rounded(.down)), frac = f - Float(s)
            if s < 0 { s = 0; frac = 0 }
            if s >= srcLen - 1 { s = srcLen - 1; frac = 0 }
            let a1 = Int32((frac * 2048).rounded()), a0 = Int32(2048) - a1
            return (s, min(s + 1, srcLen - 1), a0, a1)
        }
        let xs = (0..<crop).map { taps(x0 + $0, w, dw) }
        var out = [UInt8](repeating: 255, count: crop * crop * 4)
        for oy in 0..<crop where y0 + oy < dh {
            let (r0, r1, b0, b1) = taps(y0 + oy, h, dh)
            for ox in 0..<crop where x0 + ox < dw {
                let (c0, c1, a0, a1) = xs[ox]
                for ch in 0..<3 {
                    func row(_ r: Int) -> Int32 {
                        Int32(src[(r * w + c0) * 4 + ch]) * a0 + Int32(src[(r * w + c1) * 4 + ch]) * a1
                    }
                    // OpenCV's VResizeLinear for 8-bit: ((b0 * (S0 >> 4)) >> 16) + ((b1 * (S1 >> 4)) >> 16) + 2) >> 2
                    let v = (((b0 * (row(r0) >> 4)) >> 16) + ((b1 * (row(r1) >> 4)) >> 16) + 2) >> 2
                    out[(oy * crop + ox) * 4 + ch] = UInt8(clamping: v)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: crop, height: crop, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: crop * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The image's pixels as 8-bit RGBX, top row first.
    private static func rgbaPixels(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 255, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            // The image's own RGB space, so no colour conversion happens (OpenCV ignores embedded profiles).
            let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }
}
