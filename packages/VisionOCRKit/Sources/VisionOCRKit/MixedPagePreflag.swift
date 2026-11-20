// MixedPagePreflag.swift — ATRIUM's page classifier as the mixed-page pre-flag (W47.wh-mixed-preflag): a typed or
// printed page whose top class is TEXT (ATRIUM's "text with handwriting") is flagged as likely to carry handwriting.
// W46.kind-atrium measured it on the 2,000 bulk pages under the owner's cut (any handwriting on a typed or printed
// page, a signature included): recall 51-60%, precision 69.8%, finite completion bounds 18-95% (precision) and 7-97%
// (recall), against the shipped kind classifier's 12-14% recall. It is only the flag, never the kind classifier
// (owner, 2026-11-19, call 15). As the bench ran it: `ufal/vit-historical-page` v4.3 (revision 543216d6b7e1), the whole
// page squeezed to 384 x 384 with Pillow's bicubic resize, ImageNet normalisation (inside the model), converted to
// Core ML by `ops/convert-atrium.py`. The base weights are CC BY-NC 4.0, so they are a separate optional download (call 12),
// never bundled.

import CoreGraphics
import CoreML
import Foundation
import ImageIO

public enum MixedPagePreflag {
    /// The weights' licence, shown with the download (call 12): ATRIUM's card is MIT, but it is fine-tuned from Meta's
    /// SWAG RegNetY-16GF weights (`timm/regnety_160.swag_ft_in1k`), which are CC BY-NC 4.0.
    public static let licence = "MIT, fine-tuned from base weights that are CC BY-NC 4.0"
    public static let classes = ["DRAW", "DRAW_L", "LINE_HW", "LINE_P", "LINE_T", "PHOTO", "PHOTO_L", "TEXT",
                                 "TEXT_HW", "TEXT_P", "TEXT_T"]
    /// ATRIUM's mixed class: its top class on a flagged page.
    public static let mixedClass = "TEXT"
    static let side = 384

    /// ATRIUM's reading of one page: its top class and the eleven probabilities, in `classes` order.
    public struct Reading: Equatable, Sendable {
        public let probabilities: [Float]
        public var top: String { classes[probabilities.indices.max { probabilities[$0] < probabilities[$1] } ?? 0] }
        /// The flag: ATRIUM's top class is its mixed class.
        public var flagged: Bool { top == MixedPagePreflag.mixedClass }
    }

    public enum Failure: Error, LocalizedError {
        case failed(String)
        public var errorDescription: String? { if case .failed(let why) = self { return why }; return nil }
    }

    /// Whether the model is in place. It needs nothing of the shared runtime.
    public static func isInstalled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        ModelDownloads.Item.atrium.installed(environment)
    }

    /// The download in decimal MB, or 0 once installed.
    public static var downloadMB: Int { downloadMB(environment: ProcessInfo.processInfo.environment) }

    public static func downloadMB(environment: [String: String]) -> Int {
        isInstalled(environment) ? 0 : Int((Double(ModelDownloads.Item.atrium.plan.bytes) / 1_000_000).rounded(.up))
    }

    /// Fetches and checks the model, installing it whole.
    public static func download(environment: [String: String] = ProcessInfo.processInfo.environment,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        if !isInstalled(environment) {
            let plan = ModelDownloads.Item.atrium.plan, total = Double(max(plan.bytes, 1))
            try await ModelDownloads.install(plan, home: ModelRuntime.home(environment), source: .current(environment)) {
                progress(min(1, Double($0) / total))
            }
        }
        progress(1)
    }

    static func modelURL(_ environment: [String: String]) -> URL {
        ModelRuntime.home(environment).appendingPathComponent(ModelDownloads.Item.atrium.plan.destination)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: (path: String, model: MLModel)?

    static func model(_ environment: [String: String]) throws -> MLModel {
        let url = modelURL(environment)
        lock.lock(); defer { lock.unlock() }
        if let loaded, loaded.path == url.path { return loaded.model }
        do {
            let model = try MLModel(contentsOf: url, configuration: MLModelConfiguration())
            loaded = (url.path, model)
            return model
        } catch {
            throw Failure.failed("the mixed-page pre-flag could not be loaded (\(error.localizedDescription))")
        }
    }

    /// ATRIUM's reading of the image file at `url` (the file's first image, its pixels as stored, as Pillow opens it).
    public static func read(url: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Reading {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure.failed("the page could not be opened for the mixed-page pre-flag")
        }
        return try read(image: image, environment: environment)
    }

    public static func read(image: CGImage, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Reading {
        let model = try model(environment)
        // Drawn into the page's own colour space, so no colour matching changes the stored values: Pillow, which the
        // bench resized with, ignores an embedded profile. A grey page is drawn grey; a space that cannot be drawn
        // into falls back to device RGB or grey. Kept interleaved.
        let w = image.width, h = image.height, grey = image.colorSpace?.model == .monochrome, ps = grey ? 1 : 4
        let own = image.colorSpace.flatMap { ($0.model == (grey ? .monochrome : .rgb) && $0.supportsOutput) ? $0 : nil }
        var pixels = [UInt8](repeating: 255, count: w * h * ps)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * ps,
                                      space: own ?? (grey ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()),
                                      bitmapInfo: grey ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw Failure.failed("the page could not be drawn for the mixed-page pre-flag") }
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        var sized = [UInt8](repeating: 0, count: side * side)
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { p, strides in
            let cs = strides[1], rs = strides[2]
            for c in 0..<3 {
                pixels.withUnsafeBufferPointer { src in
                    sized.withUnsafeMutableBufferPointer { dst in
                        resample(src.baseAddress!, width: w, height: h, pixelStride: ps, channel: grey ? 0 : c,
                                 to: side, side, into: dst.baseAddress!)
                    }
                }
                for y in 0..<side { for x in 0..<side { p[c * cs + y * rs + x] = Float(sized[y * side + x]) / 255 } }
            }
        }
        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["pixels": input]))
        } catch {
            throw Failure.failed("the mixed-page pre-flag failed (\(error.localizedDescription))")
        }
        guard let probs = output.featureValue(for: "probs")?.multiArrayValue, probs.count == classes.count else {
            throw Failure.failed("the mixed-page pre-flag wrote no classes")
        }
        return Reading(probabilities: (0..<classes.count).map { probs[[0, NSNumber(value: $0)]].floatValue })
    }

    /// Pillow's `Image.resize(..., BICUBIC)` of one 8-bit channel (Resample.c, Pillow 7 onwards): the a = -0.5
    /// cubic widened by the scale when shrinking, 22-bit fixed-point coefficients, the horizontal pass first, each
    /// pass rounded and clipped to 8 bits.
    public static func bicubicResize(_ src: [UInt8], width w: Int, height h: Int, to dw: Int, _ dh: Int) -> [UInt8] {
        var dst = [UInt8](repeating: 0, count: dw * dh)
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                resample(s.baseAddress!, width: w, height: h, pixelStride: 1, channel: 0, to: dw, dh, into: d.baseAddress!)
            }
        }
        return dst
    }

    private static let precision = 22

    /// Pillow's `precompute_coeffs` and `normalize_coeffs_8bpc`: for each output pixel its first input pixel and
    /// `size` fixed-point weights (zero past its own count).
    private static func coefficients(_ inSize: Int, _ outSize: Int) -> (first: [Int], count: [Int], k: [Int32], size: Int) {
        func cubic(_ v: Double) -> Double {
            let a = -0.5, x = abs(v)
            if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
            if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
            return 0
        }
        let scale = Double(inSize) / Double(outSize), filterScale = max(scale, 1), support = 2 * filterScale
        let ss = 1 / filterScale   // Pillow multiplies by the reciprocal; dividing can differ in the last bit
        let size = Int(support.rounded(.up)) * 2 + 1
        var first = [Int](repeating: 0, count: outSize), count = first
        var k = [Int32](repeating: 0, count: outSize * size)
        for i in 0..<outSize {
            let center = (Double(i) + 0.5) * scale
            let lo = max(Int(center - support + 0.5), 0), n = max(min(Int(center + support + 0.5), inSize) - lo, 0)
            var raw = [Double](repeating: 0, count: n), total = 0.0
            for j in 0..<n { raw[j] = cubic((Double(j + lo) - center + 0.5) * ss); total += raw[j] }
            for j in 0..<n {
                let v = total != 0 ? raw[j] / total : raw[j]
                k[i * size + j] = Int32(v < 0 ? -0.5 + v * Double(1 << precision) : 0.5 + v * Double(1 << precision))
            }
            first[i] = lo; count[i] = n
        }
        return (first, count, k, size)
    }

    /// One channel of an interleaved 8-bit image (`pixelStride` bytes a pixel) resized into `dst`, `dw` x `dh` bytes.
    static func resample(_ src: UnsafePointer<UInt8>, width w: Int, height h: Int, pixelStride ps: Int, channel: Int,
                         to dw: Int, _ dh: Int, into dst: UnsafeMutablePointer<UInt8>) {
        let half = Int32(1) << Int32(precision - 1), shift = Int32(precision)
        @inline(__always) func clip(_ v: Int32) -> UInt8 { v <= 0 ? 0 : UInt8(min(255, v >> shift)) }
        var mid = [UInt8](repeating: 0, count: dw * h)
        mid.withUnsafeMutableBufferPointer { m in
            let m = m.baseAddress!
            if dw == w {
                for i in 0..<(w * h) { m[i] = src[i * ps + channel] }
            } else {
                let xs = coefficients(w, dw)
                xs.k.withUnsafeBufferPointer { k in
                    for y in 0..<h {
                        let row = src + y * w * ps + channel
                        for x in 0..<dw {
                            var s = half
                            let lo = xs.first[x], kk = k.baseAddress! + x * xs.size
                            for j in 0..<xs.count[x] { s &+= Int32(row[(lo + j) * ps]) &* kk[j] }
                            m[y * dw + x] = clip(s)
                        }
                    }
                }
            }
            if dh == h {
                for i in 0..<(dw * h) { dst[i] = m[i] }
                return
            }
            let ys = coefficients(h, dh)
            ys.k.withUnsafeBufferPointer { k in
                for y in 0..<dh {
                    let lo = ys.first[y], n = ys.count[y], kk = k.baseAddress! + y * ys.size
                    for x in 0..<dw {
                        var s = half
                        for j in 0..<n { s &+= Int32(m[(lo + j) * dw + x]) &* kk[j] }
                        dst[y * dw + x] = clip(s)
                    }
                }
            }
        }
    }
}
