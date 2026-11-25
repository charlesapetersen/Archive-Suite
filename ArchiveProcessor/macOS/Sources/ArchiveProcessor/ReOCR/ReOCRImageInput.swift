import ArchiveCore
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Improve OCR: the image a page is read from (W49.proc-reocr-preservation, owner call 34)

/// Which image Improve OCR sends to the reader for one image page (`SPEC/improve-ocr.md` §5):
///
/// - the page's verified full-resolution **Preservation Copy** when the file's catalogue record maps the page to one
///   (`SPEC/catalogue.md` §Preservation copies): the mapped original, the mapped page of a multi-page PDF original,
///   read through `PreservationCopy.open` against the snapshot's embedded identity, so the bytes are the ones the map's
///   digest names and nothing is downloaded or written in the Preservation folder;
/// - otherwise the reading PDF's own image page (`ReOCRJob.writeImageInput`), with the reason recorded so the review can
///   say which pages fell back and why.
///
/// The original is turned to match the reading page, which was made upright when the file was made (the reader runs with
/// rotation off). The turn is found by searching a small grey rendition of the original, at each quarter turn, for the
/// reading page at several sizes and every position (the reading copy may be cropped from it); a page whose best turn
/// is not clearly better than the others falls back rather than risk a sideways reading. The whole original is sent: the
/// Processor files one reading page per intake image (a PDF original maps a page per page), so the original holds no
/// other page's text; a future feature that splits one image into several reading pages must send only the matched
/// region instead. The input goes through the same reader, with the same request constraints (its size target) and the
/// collection's sharing settings, as the reading PDF's image would.
enum ReOCRImageInput {
    enum Source: Sendable, Equatable {
        /// The Preservation Copy's intake file name.
        case preservation(name: String)
        /// The reading PDF's image page, and why the Preservation Copy was not used.
        case readingPDF(Fallback)

        var summary: String {
            switch self {
            case .preservation(let name): "Read from the Preservation Copy \u{201C}\(name)\u{201D}."
            case .readingPDF(let why): "Read from the reading PDF: \(why.description)."
            }
        }
    }

    enum Fallback: Error, Sendable, Equatable, CustomStringConvertible {
        case notRecorded
        case missing
        case offline
        case unverified
        case unreadable
        case orientationUnmatched

        init(_ failure: PreservationCopy.Failure) {
            switch failure {
            case .notRecorded: self = .notRecorded
            case .missing: self = .missing
            case .offline: self = .offline
            case .unverified: self = .unverified
            }
        }

        var description: String {
            switch self {
            case .notRecorded: "no Preservation Copy is recorded for this page"
            case .missing: "its Preservation Copy is missing"
            case .offline: "its Preservation Copy is not downloaded, and Improve OCR does not download it"
            case .unverified: "its Preservation Copy could not be verified"
            case .unreadable: "its Preservation Copy could not be opened as an image"
            case .orientationUnmatched: "its Preservation Copy could not be matched to the page's orientation"
            }
        }
    }

    /// The file's verified association with its Preservation Copies, for the snapshot being read.
    struct Lookup: Sendable {
        let root: URL
        let relativePath: String
        let expected: CataloguePDFIdentity

        /// Nil when the snapshot carries no catalogue identity: no copy can be verified against it.
        init?(root: URL, relativePath: String, snapshot: Data) {
            guard let document = ReOCRPreservationCheck.document(snapshot),
                  let identity = CataloguePDFIdentity.identity(in: document) else { return nil }
            self.root = root
            self.relativePath = relativePath
            expected = identity
        }

        /// Throws only `CancellationError`: a cancelled run reads nothing more, rather than falling back.
        func original(physicalPageIndex: Int) throws -> Result<PreservationCopy.Original, Fallback> {
            do {
                let instance = UUID()
                let reader = try CatalogueReader(grantedRoot: root, rootInstanceID: instance, mode: .adopted,
                                                 identifyPDF: CataloguePDFIdentity.identify)
                let occurrence = CatalogueAssociation.Occurrence(rootInstanceID: instance, relativePath: relativePath)
                return .success(try PreservationCopy.open(in: reader, at: occurrence,
                                                          physicalPageIndex: physicalPageIndex, expected: expected))
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as PreservationCopy.Failure {
                return .failure(Fallback(failure))
            } catch ItemFacts.Unavailable.offline {
                return .failure(.offline)
            } catch ItemFacts.Unavailable.missing {
                return .failure(.missing)
            } catch {
                return .failure(.unverified)
            }
        }
    }

    /// Writes the image the reader gets for `pageIndex` of `pdf` to `url`: the Preservation Copy when `lookup` maps the
    /// page to one that verifies and matches, else the PDF's own image page. Nil when neither could be written; throws
    /// only `CancellationError`.
    static func write(_ pdf: Data, pageIndex: Int, lookup: Lookup?, to url: URL) throws -> Source? {
        var fallback = Fallback.notRecorded
        if let lookup {
            switch try lookup.original(physicalPageIndex: pageIndex) {
            case .success(let original):
                try Task.checkCancellation()
                if let why = writeOriginal(original, matching: pdf, pageIndex: pageIndex, to: url) {
                    try? FileManager.default.removeItem(at: url)
                    fallback = why
                } else if chmod(url.path, 0o600) == 0 {
                    return .preservation(name: original.selection.source.name)
                } else {
                    try? FileManager.default.removeItem(at: url)
                    fallback = .unreadable
                }
            case .failure(let why):
                fallback = why
            }
        }
        return ReOCRJob.writeImageInput(pdf, pageIndex: pageIndex, to: url) ? .readingPDF(fallback) : nil
    }

    /// The file's path under `root` with each component spelled as given (the catalogue reader compares the names as
    /// stored), after both are resolved; nil when it is not inside.
    static func storedPath(of file: URL, in root: URL) -> String? {
        let r = (root.resolvingSymlinksInPath().standardizedFileURL.path as NSString).pathComponents
        let f = (file.resolvingSymlinksInPath().standardizedFileURL.path as NSString).pathComponents
        guard f.count > r.count, Array(f.prefix(r.count)) == r else { return nil }
        return f.dropFirst(r.count).joined(separator: "/")
    }

    /// The long side an original is decoded at, at most: far above a phone photograph or a 600 dpi letter scan, and a
    /// bound on the memory one page takes. The reader's own size target reduces it further before any request.
    static let maximumPixels = 12_000

    /// Writes the original, turned to match the reading page, as a JPEG at `url`; nil on success, else why not.
    static func writeOriginal(_ original: PreservationCopy.Original, matching pdf: Data, pageIndex: Int,
                              to url: URL) -> Fallback? {
        guard let document = ReOCRPreservationCheck.document(pdf), let page = document.page(at: pageIndex + 1),
              let target = signatureImage(of: page) else { return .unreadable }
        // A PDF original: its mapped page, as the reading PDF's own pages are prepared (the embedded JPEG when that is
        // exactly what the page shows, else a 300 dpi rendering).
        var bytes = original.bytes
        if original.selection.source.format == .pdf {
            let page = url.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString)-original.jpg")
            defer { try? FileManager.default.removeItem(at: page) }
            guard ReOCRJob.writeImageInput(original.bytes, pageIndex: original.selection.originalPageIndex, to: page),
                  let rendered = try? Data(contentsOf: page) else { return .unreadable }
            bytes = rendered
        }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) > 0,
              let preview = upright(source, maxPixels: 256) else { return .unreadable }
        guard let turns = quarterTurns(from: preview, toMatch: target) else { return .orientationUnmatched }
        let type = CGImageSourceGetType(source) as String?
        let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation]
            as? Int ?? 1
        // An upright JPEG keeps its compressed image data as it is, nothing decoded or recompressed; only its location
        // (GPS) metadata is left out, which the reading PDF's image never carried.
        if turns == 0, orientation == 1, type == UTType.jpeg.identifier {
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return .unreadable }
            let options = [kCGImageMetadataShouldExcludeGPS: true] as CFDictionary
            var error: Unmanaged<CFError>?
            return CGImageDestinationCopyImageSource(destination, source, options, &error) ? nil : .unreadable
        }
        guard let full = upright(source, maxPixels: maximumPixels), let turned = rotate(full, quarterTurns: turns),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return .unreadable }
        // Only pixels are written, so no metadata of the original (its location included) goes along.
        CGImageDestinationAddImage(destination, turned, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? nil : .unreadable
    }

    /// The image as it is meant to be seen (its EXIF orientation applied), at most `maxPixels` on its long side.
    static func upright(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The image turned clockwise by `quarterTurns` × 90°.
    static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let k = ((quarterTurns % 4) + 4) % 4
        if k == 0 { return image }
        let w = image.width, h = image.height
        let (ow, oh) = k % 2 == 0 ? (w, h) : (h, w)
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // Quartz's y axis points up, so a clockwise turn on screen is a negative angle here.
        ctx.translateBy(x: CGFloat(ow) / 2, y: CGFloat(oh) / 2)
        ctx.rotate(by: -CGFloat(k) * .pi / 2)
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    // MARK: Orientation

    /// The original's long side in the comparison, and the sizes of the reading page tried inside it: the reading copy
    /// may be cropped from the original (a photograph's table edge, document detection), so the page is searched for at
    /// every position at each of these fractions of the largest size that fits.
    static let searchSide = 64
    static let searchScales = [1.0, 0.9, 0.8, 0.7, 0.6]
    /// The best turn must correlate at least this well with the page, and this much better than every other turn.
    static let minimumCorrelation = 0.5
    static let minimumMargin = 0.1
    /// `grey`'s square side, for a whole-image comparison.
    static let side = 32

    /// The reading page drawn as it is shown (its rotation applied), small.
    static func signatureImage(of page: CGPDFPage) -> CGImage? {
        let rect = page.getBoxRect(.cropBox)
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return nil }
        let size = page.rotationAngle % 180 == 0 ? rect.size : CGSize(width: rect.height, height: rect.width)
        let scale = 256 / max(size.width, size.height)
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0,
                                                 preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    /// How many clockwise quarter turns make `image` match `target`, or nil when no turn clearly does.
    static func quarterTurns(from image: CGImage, toMatch target: CGImage) -> Int? {
        var scores: [Double] = []
        for k in 0..<4 {
            guard let turned = rotate(image, quarterTurns: k), let score = bestMatch(of: target, in: turned) else { return nil }
            scores.append(score)
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] >= minimumCorrelation,
              scores.indices.allSatisfy({ $0 == best || scores[best] - scores[$0] >= minimumMargin }) else { return nil }
        return best
    }

    /// The highest normalized cross-correlation of `target`, at the search scales and every position, inside `image`;
    /// nil when either is flat or cannot be drawn.
    static func bestMatch(of target: CGImage, in image: CGImage) -> Double? {
        let long = Double(max(image.width, image.height))
        let gw = max(8, Int((Double(image.width) / long * Double(searchSide)).rounded()))
        let gh = max(8, Int((Double(image.height) / long * Double(searchSide)).rounded()))
        guard let field = levels(image, width: gw, height: gh) else { return nil }
        let aspect = Double(target.width) / Double(target.height)
        let fit = min(Double(gw), Double(gh) * aspect)
        var best = -1.0
        for scale in searchScales {
            let tw = Int((fit * scale).rounded()), th = Int((fit * scale / aspect).rounded())
            guard tw >= 8, th >= 8, tw <= gw, th <= gh, let template = levels(target, width: tw, height: th) else { continue }
            let tMean = template.reduce(0, +) / Double(template.count)
            let t = template.map { $0 - tMean }
            let tNorm = t.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard tNorm > 1e-6 else { return nil }
            for y in 0...(gh - th) {
                for x in 0...(gw - tw) {
                    var sum = 0.0, sumSq = 0.0, dot = 0.0
                    for row in 0..<th {
                        let base = (y + row) * gw + x, tBase = row * tw
                        for col in 0..<tw {
                            let v = field[base + col]
                            sum += v; sumSq += v * v; dot += v * t[tBase + col]
                        }
                    }
                    let n = Double(tw * th)
                    let variance = sumSq - sum * sum / n
                    guard variance > 1e-6 else { continue }
                    best = max(best, dot / (variance.squareRoot() * tNorm))
                }
            }
        }
        return best > -1 ? best : nil
    }

    /// The image's grey levels drawn at `width` × `height`, top row first.
    static func levels(_ image: CGImage, width: Int, height: Int) -> [Double]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels.map(Double.init) : nil
    }

    /// `side` × `side` grey levels, stretched to the square, normalized to mean 0 and unit variance; nil when flat.
    static func grey(_ image: CGImage) -> [Double]? {
        guard let values = levels(image, width: side, height: side) else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        guard variance > 1 else { return nil }
        let sd = variance.squareRoot()
        return values.map { ($0 - mean) / sd }
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } / Double(a.count)
    }
}
