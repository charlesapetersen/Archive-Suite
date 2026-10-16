import CoreGraphics
import Foundation
import ImageIO
import Vision

// kind-signals <list.tsv> <featureprints.tsv>: W41.bench-kind-classifier. Apple Vision's own signals for the page
// kinds Vision OCR's sorter does not tell apart (typewritten against printed, forms and tables, low resolution),
// with no model beyond the OS's. Each list row is `id <TAB> image`. Prints one row a page on stdout and writes each
// page's image feature print to the second file. Reads only; writes nothing else.
//
// Per page, the image at its own size, upright by its EXIF orientation:
//   * text lines (VNRecognizeTextRequest, accurate, no language correction): how many, their height in pixels
//     (median and 10th percentile, the line box's short side, so a sideways page measures the same), mean confidence;
//   * ink periodicity, on horizontal lines of at least 15 characters (up to 60): the autocorrelation of the line's
//     column ink profile at its strongest lag between 0.3 and 0.9 line heights, and at twice that lag (harmonic).
//     A typewriter's fixed pitch repeats, so both stay high; print's proportional letters drift out of phase, so the
//     harmonic falls. (Vision's own word and line boxes were tried first and do not separate them: a word's box is
//     interpolated along its line, not measured.) Medians over the page's lines;
//   * tables (RecognizeDocumentsRequest, macOS 26): how many, their cells, the largest's rows and columns, and the
//     share of the page they cover;
//   * a feature print (VNGenerateImageFeaturePrintRequest), for a nearest-neighbour or linear classifier;
//   * seconds each step took.

func load(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceCreateThumbnailWithTransform: true,
                                 kCGImageSourceThumbnailMaxPixelSize: max(w, h)]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
}

/// The image as 8-bit grey, top row first.
struct Gray {
    let w: Int, h: Int, px: [UInt8]
    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 255, count: w * h)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.w = w; self.h = h; px = buf
    }
}

/// The autocorrelation of a line's column ink profile at its strongest lag between 0.3 and 0.9 line heights (a
/// typewriter's pitch is about half its line box), and at twice that lag: both near 1 for a fixed pitch.
func periodicity(_ g: Gray, x0: Double, x1: Double, y0: Double, y1: Double) -> (Double, Double)? {
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

func quantile(_ xs: [Double], _ q: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    return s[min(s.count - 1, Int(q * Double(s.count - 1) + 0.5))]
}

func f(_ x: Double, _ digits: Int = 3) -> String { x.isNaN ? "" : String(format: "%.\(digits)f", x) }

func tables(_ image: CGImage) -> (count: Int, cells: Int, rows: Int, cols: Int, share: Double)? {
    let done = DispatchSemaphore(value: 0)
    var out: (Int, Int, Int, Int, Double)?
    Task {
        defer { done.signal() }
        guard let obs = try? await RecognizeDocumentsRequest().perform(on: image) else { return }
        var count = 0, cells = 0, rows = 0, cols = 0, share = 0.0
        for o in obs {
            for t in o.document.tables {
                count += 1
                cells += t.rows.reduce(0) { $0 + $1.count }
                if t.rows.count * t.columns.count > rows * cols { rows = t.rows.count; cols = t.columns.count }
                let b = t.boundingRegion.boundingBox
                share += Double(b.width * b.height)
            }
        }
        out = (count, cells, rows, cols, min(share, 1))
    }
    done.wait()
    return out.map { (count: $0.0, cells: $0.1, rows: $0.2, cols: $0.3, share: $0.4) }
}

guard CommandLine.arguments.count == 3,
      let list = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8),
      FileManager.default.createFile(atPath: CommandLine.arguments[2], contents: nil),
      let prints = FileHandle(forWritingAtPath: CommandLine.arguments[2]) else {
    FileHandle.standardError.write(Data("usage: kind-signals <list.tsv> <featureprints.tsv>\n".utf8)); exit(2)
}
print(["id", "width", "height", "lines", "text_px", "text_px_p10", "conf", "periodic_lines", "periodic", "harmonic",
       "tables", "table_cells", "table_rows", "table_cols", "table_share", "s_text", "s_tables", "s_print"]
      .joined(separator: "\t"))
var measured = 0, unread = 0
for row in list.split(whereSeparator: \.isNewline) where !row.hasPrefix("#") {
    let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard fields.count >= 2 else { continue }
    measured += 1
    autoreleasepool {
        guard let image = load(fields[1]) else { print("\(fields[0])\tunread"); unread += 1; return }
        let W = Double(image.width), H = Double(image.height)
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let gray = Gray(image)

        var t0 = Date()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        try? handler.perform([text])
        let sText = Date().timeIntervalSince(t0)
        var heights: [Double] = [], confs: [Double] = []
        var periodic: [Double] = [], harmonic: [Double] = []
        for o in text.results ?? [] {
            guard let top = o.topCandidates(1).first else { continue }
            let bw = Double(o.boundingBox.width) * W, bh = Double(o.boundingBox.height) * H
            let short = min(bw, bh)
            guard short > 0 else { continue }
            heights.append(short)
            confs.append(Double(top.confidence))
            let s = top.string
            // A horizontal line's ink, column by column: how periodic it is at the pitch a typewriter would have.
            if s.count >= 15, bw > bh, periodic.count < 60, let g = gray,
               let r = periodicity(g, x0: Double(o.boundingBox.minX) * W, x1: Double(o.boundingBox.maxX) * W,
                                   y0: (1 - Double(o.boundingBox.maxY)) * H, y1: (1 - Double(o.boundingBox.minY)) * H) {
                periodic.append(r.0); harmonic.append(r.1)
            }
        }

        t0 = Date()
        let tab = tables(image)
        let sTables = Date().timeIntervalSince(t0)

        t0 = Date()
        let fp = VNGenerateImageFeaturePrintRequest()
        try? handler.perform([fp])
        let sPrint = Date().timeIntervalSince(t0)
        if let o = fp.results?.first as? VNFeaturePrintObservation, o.elementType == .float {
            let v = o.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(o.elementCount)) }
            prints.write(Data((fields[0] + "\t" + v.map { String(format: "%.5g", $0) }.joined(separator: ",") + "\n").utf8))
        }

        let conf = confs.isEmpty ? Double.nan : confs.reduce(0, +) / Double(confs.count)
        print([fields[0], "\(image.width)", "\(image.height)", "\(heights.count)", f(quantile(heights, 0.5), 1),
               f(quantile(heights, 0.1), 1), f(conf), "\(periodic.count)", f(quantile(periodic, 0.5), 4), f(quantile(harmonic, 0.5), 4),
               tab.map { "\($0.count)" } ?? "", tab.map { "\($0.cells)" } ?? "", tab.map { "\($0.rows)" } ?? "",
               tab.map { "\($0.cols)" } ?? "", tab.map { f($0.share) } ?? "", f(sText, 2), f(sTables, 2), f(sPrint, 2)]
              .joined(separator: "\t"))
        fflush(stdout)
    }
}
try? prints.close()
FileHandle.standardError.write(Data("\(measured) page(s), \(unread) unread\n".utf8))
exit(measured == 0 ? 2 : 0)
