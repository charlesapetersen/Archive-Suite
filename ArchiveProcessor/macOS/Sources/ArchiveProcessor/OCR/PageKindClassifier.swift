import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Tells a page's kind before OCR (W41.app-page-kind), with the classifier W41.bench-kind-classifier recommended:
/// Apple Vision's signals and its image feature print, a logistic regression for the hand (handwritten, typewritten,
/// printed) and one for forms and tables. The weights are `segbench-results/kind-classifier-model.json`, bundled
/// straight from the bench; the features are measured exactly as the bench's `scripts/segbench/kind_signals/
/// kind-signals.swift` measures them, so the two must change together. On-device, no download, about 0.6 s a page.
///
/// The bench scored it leaving each folder out: the hand right on 139 of 144 pages, 13 of 14 forms found with 2
/// false calls. Its weights come from those pages, so a page the classifier is not sure of keeps the user's default
/// (`PageKindRouting`). No low-resolution flag: the bench found neither image size nor text height catches it.
struct PageKindModel: Decodable, Sendable {
    struct Regression: Decodable, Sendable {
        let classes: [String]
        let features: [String]
        let mean: [Double]
        let sd: [Double]
        let W: [[Double]]
        let b: [Double]

        /// Softmax probabilities in `classes` order; nil when `x` does not match the feature list.
        func probabilities(_ x: [Double]) -> [Double]? {
            guard x.count == features.count, mean.count == x.count, sd.count == x.count, W.count == x.count,
                  b.count == classes.count, W.allSatisfy({ $0.count == classes.count }) else { return nil }
            var scores = b
            for i in x.indices {
                let z = (x[i] - mean[i]) / sd[i]
                guard z.isFinite else { return nil }
                for k in scores.indices { scores[k] += z * W[i][k] }
            }
            let top = scores.max() ?? 0
            let e = scores.map { Foundation.exp($0 - top) }
            let sum = e.reduce(0, +)
            return e.map { $0 / sum }
        }
    }

    let measured: String
    let hand: Regression
    let form: Regression

    static let resourceName = "kind-classifier-model"

    static func decode(_ data: Data) throws -> PageKindModel { try JSONDecoder().decode(PageKindModel.self, from: data) }

    /// Loaded once; nil turns kind detection off (every page keeps the run's model).
    static let bundled: PageKindModel? = {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }()

    /// How many feature-print values the weights expect (768 for revision 2, macOS 26's default).
    var printLength: Int { hand.features.filter { $0.hasPrefix("print") }.count }

    /// What is wrong with the weights, for the self-test.
    func problems() -> [String] {
        var out: [String] = []
        let scalars = ["harmonic", "periodic", "conf", "text_px", "lines"]
        let prints = (0..<printLength).map { "print\($0)" }
        if hand.classes != ["handwritten", "typewritten", "printed"] { out.append("hand classes \(hand.classes)") }
        if form.classes != ["no", "yes"] { out.append("form classes \(form.classes)") }
        if hand.features != scalars + prints { out.append("hand features out of order") }
        if form.features != ["table_share", "table_cells"] + scalars + prints { out.append("form features out of order") }
        if printLength == 0 { out.append("no feature print") }
        for (name, r) in [("hand", hand), ("form", form)] {
            if r.probabilities([Double](repeating: 0, count: r.features.count)) == nil { out.append("\(name) shapes") }
            if r.sd.contains(where: { !($0 > 0) }) { out.append("\(name) sd not positive") }
        }
        return out
    }
}

/// The measured inputs, named as the bench names them. NaN where Vision found nothing to measure; the regressions
/// read a NaN scalar as 0, as the bench fitted them (`feats()` in kind_classifier.py).
struct PageKindSignals: Sendable, Equatable {
    var lines = 0
    var textPx = Double.nan
    var conf = Double.nan
    var periodic = Double.nan
    var harmonic = Double.nan
    var tableShare = 0.0
    var tableCells = 0
    var print: [Float] = []

    func handFeatures() -> [Double] {
        [harmonic, periodic, conf, textPx, Double(lines)].map { $0.isNaN ? 0 : $0 } + print.map(Double.init)
    }

    func formFeatures() -> [Double] { [tableShare, Double(tableCells)] + handFeatures() }
}

/// One page's kind: the guide's kind id (`OCRPageGuidance.Kind.id`) and how sure the classifier was of it.
struct PageKind: Codable, Sendable, Equatable {
    /// "handwritten", "typewritten", "printed" or "forms".
    let kind: String
    /// The probability of the call that decided it: the form regression's when it calls a form, else the hand's.
    let confidence: Double

    static let kinds = ["handwritten", "typewritten", "printed", "forms"]

    /// The bench's routing rule: a form goes to the form pick, else the page goes to its hand's.
    static func decide(hand: [Double], form: [Double], handClasses: [String]) -> PageKind? {
        guard form.count == 2, hand.count == handClasses.count,
              let top = hand.indices.max(by: { hand[$0] < hand[$1] }) else { return nil }
        if form[1] > form[0] { return PageKind(kind: "forms", confidence: form[1]) }
        return PageKind(kind: handClasses[top], confidence: hand[top])
    }

    static func label(_ kind: String) -> String {
        switch kind {
        case "handwritten": return "Handwritten"
        case "typewritten": return "Typewritten"
        case "printed": return "Printed"
        case "forms": return "Form or table"
        default: return kind
        }
    }
}

enum PageKindClassifier {
    /// The page's kind, or nil when it cannot be told here (no weights, Vision older than macOS 26, a feature print
    /// of another length, an unreadable image). nil means "unknown": the page keeps the run's model.
    static func classify(_ image: CGImage, model: PageKindModel? = PageKindModel.bundled) async -> PageKind? {
        guard let model, let s = await measure(image), s.print.count == model.printLength,
              let hand = model.hand.probabilities(s.handFeatures()),
              let form = model.form.probabilities(s.formFeatures()) else { return nil }
        return PageKind.decide(hand: hand, form: form, handClasses: model.hand.classes)
    }

    /// The image at the given path at its own size, upright by its EXIF orientation (as the bench loads it).
    static func loadImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max(w, h)]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// kind-signals.swift's measurements, minus its timings and the table counts the regressions do not read.
    static func measure(_ image: CGImage) async -> PageKindSignals? {
        guard #available(macOS 26, *) else { return nil }
        let W = Double(image.width), H = Double(image.height)
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let gray = Gray(image)
        var s = PageKindSignals()

        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        do { try handler.perform([text]) } catch { return nil }
        var heights: [Double] = [], confs: [Double] = [], periodic: [Double] = [], harmonic: [Double] = []
        for o in text.results ?? [] {
            guard let top = o.topCandidates(1).first else { continue }
            let bw = Double(o.boundingBox.width) * W, bh = Double(o.boundingBox.height) * H
            let short = min(bw, bh)
            guard short > 0 else { continue }
            heights.append(short)
            confs.append(Double(top.confidence))
            if top.string.count >= 15, bw > bh, periodic.count < 60, let g = gray,
               let r = periodicity(g, x0: Double(o.boundingBox.minX) * W, x1: Double(o.boundingBox.maxX) * W,
                                   y0: (1 - Double(o.boundingBox.maxY)) * H, y1: (1 - Double(o.boundingBox.minY)) * H) {
                periodic.append(r.0); harmonic.append(r.1)
            }
        }
        s.lines = heights.count
        s.textPx = quantile(heights, 0.5)
        s.conf = confs.isEmpty ? .nan : confs.reduce(0, +) / Double(confs.count)
        s.periodic = quantile(periodic, 0.5)
        s.harmonic = quantile(harmonic, 0.5)

        if let obs = try? await RecognizeDocumentsRequest().perform(on: image) {
            var share = 0.0
            for o in obs {
                for t in o.document.tables {
                    s.tableCells += t.rows.reduce(0) { $0 + $1.count }
                    let b = t.boundingRegion.boundingBox
                    share += Double(b.width * b.height)
                }
            }
            s.tableShare = min(share, 1)
        }

        let fp = VNGenerateImageFeaturePrintRequest()
        do { try handler.perform([fp]) } catch { return nil }
        guard let o = fp.results?.first, o.elementType == .float else { return nil }
        s.print = o.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(o.elementCount)) }
        return s
    }

    /// The image as 8-bit grey, top row first.
    struct Gray {
        let w: Int, h: Int, px: [UInt8]
        init?(_ image: CGImage) {
            let w = image.width, h = image.height
            var buf = [UInt8](repeating: 255, count: w * h)
            let ok = buf.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            self.w = w; self.h = h; px = buf
        }
    }

    /// The autocorrelation of a line's column ink profile at its strongest lag between 0.3 and 0.9 line heights,
    /// and at twice that lag (the harmonic): a typewriter's fixed pitch keeps both high, print's drifts out of phase.
    static func periodicity(_ g: Gray, x0: Double, x1: Double, y0: Double, y1: Double) -> (Double, Double)? {
        let xa = max(0, Int(x0)), xb = min(g.w, Int(x1)), ya = max(0, Int(y0)), yb = min(g.h, Int(y1))
        let lineH = Double(yb - ya)
        guard xb - xa > 40, lineH >= 8 else { return nil }
        var p = [Double](repeating: 0, count: xb - xa)
        for y in ya..<yb { let row = y * g.w; for x in xa..<xb { p[x - xa] += Double(255 - g.px[row + x]) } }
        let mean = p.reduce(0, +) / Double(p.count)
        for i in p.indices { p[i] -= mean }
        let r0 = p.reduce(0) { $0 + $1 * $1 }
        guard r0 > 0 else { return nil }
        func r(_ k: Int) -> Double {
            guard k < p.count else { return 0 }
            var s = 0.0
            for i in 0..<(p.count - k) { s += p[i] * p[i + k] }
            return s / r0
        }
        let lo = max(2, Int(0.3 * lineH)), hi = max(lo + 1, Int(0.9 * lineH))
        var best = lo, bestR = -1.0
        for k in lo...hi { let v = r(k); if v > bestR { bestR = v; best = k } }
        return (bestR, r(2 * best))
    }

    static func quantile(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return .nan }
        let s = xs.sorted()
        return s[min(s.count - 1, Int(q * Double(s.count - 1) + 0.5))]
    }
}
