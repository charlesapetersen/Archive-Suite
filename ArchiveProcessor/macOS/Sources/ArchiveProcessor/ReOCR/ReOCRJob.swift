import ArchiveCore
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// MARK: - Improve OCR: one file's run, behind the dialog (W44.reocr-processor)

/// One file through Improve OCR (`execution-plans/reocr/00-plan.md` §4–5), without any UI:
///
/// 1. `start` validates the pairs, then `ReOCRFileWriter.prepare` keeps a verified copy of the file and journals it
///    before anything is read. Everything after works from that copy's bytes, so the candidate is built on exactly
///    the snapshot `accept` later checks the live file against.
/// 2. Each selected pair's image page goes to the reader as a private JPEG in `scratch` (0700, files 0600, each removed
///    after its reading): the page's own JPEG bytes when that is exactly what the page shows (`embeddedJPEG`), else a
///    300 dpi rendering. The old text pages are never read. A failure after `prepare` records the operation rejected.
/// 3. When every selected pair has a reading, the replacement pages go through `ReOCRIncrementalWriter`, which proves
///    the candidate kept the rest. One failed pair means no candidate: a partial batch cannot be accepted.
/// 4. `accept` publishes through `ReOCRFileWriter`; `reject` records the verdict and leaves the file as it is.
///
/// The reader is injected: the dialog passes the chosen route, the self-test a fake. Nothing here spends money.
struct ReOCRJob {
    let writer: ReOCRFileWriter
    /// Private scratch for the image inputs; the caller removes it.
    let scratch: URL

    typealias Reader = @Sendable (_ image: URL, _ pair: ReOCRPairs.Pair, _ kind: OCRPageKind?) async -> OCRResult

    struct PairResult: Sendable {
        let pair: ReOCRPairs.Pair
        let oldText: String
        let kind: OCRPageKind?
        /// The new text, or why there is none.
        let outcome: Result<String, ReOCRPairs.Refusal>
    }

    struct Review: Sendable {
        let operation: ReOCRFileWriter.Operation
        let results: [PairResult]
        /// Present only when every selected pair was read and the candidate passed the preservation check.
        let candidate: Data?
        let candidateProblem: String?
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case notEligible(ReOCRPairs.Refusal)
        case noSuchPair(page: Int)
        case nothingSelected
        case imageNotExtracted(page: Int)
        case noCandidate

        var description: String {
            switch self {
            case .notEligible(let r): "this file cannot be improved in place: \(r)"
            case .noSuchPair(let p): "page \(p + 1) is not a text page of this file"
            case .nothingSelected: "no page was selected"
            case .imageNotExtracted(let p): "page \(p + 1) could not be prepared for reading"
            case .noCandidate: "not every selected page was read, so there is nothing to accept"
            }
        }
    }

    /// `textPages` selects pairs by their text page's 0-based index (nil: every pair); `kinds` overrides a pair's
    /// Kind by the same index (absent: the header's own).
    func start(file: URL, textPages: Set<Int>? = nil, kinds: [Int: OCRPageKind] = [:], model: LLMModel,
               gatewayDisplayName: String? = nil, localAgentDisplayName: String? = nil, localAgentModelName: String? = nil,
               read: Reader) async throws -> Review {
        let live = try Data(contentsOf: file)
        let pairs: [ReOCRPairs.Pair]
        switch ReOCRPairs.validate(live) {
        case .success(let p): pairs = p
        case .failure(let r): throw Failure.notEligible(r)
        }
        if let textPages, let bad = textPages.first(where: { t in !pairs.contains { $0.textIndex == t } }) {
            throw Failure.noSuchPair(page: bad)
        }
        let selected = pairs.filter { textPages?.contains($0.textIndex) ?? true }
        guard !selected.isEmpty else { throw Failure.nothingSelected }

        let op = try writer.prepare(target: file)
        var results: [PairResult] = []
        var replacements: [Int: Data] = [:]
        let original: Data
        do {
            // From here, the verified copy: the bytes the journal's snapshot names, checked again by digest.
            original = try Data(contentsOf: writer.backupURL(op.journal.operationID))
            guard ReOCRFileWriter.hex(SHA256.hash(data: original)) == op.journal.original.sha256,
                  case .success(let checked) = ReOCRPairs.validate(original), checked == pairs else {
                throw Failure.notEligible(.unreadable)
            }
            try Self.makePrivateDirectory(scratch)
            let oldDoc = PDFDocument(data: original)
            for pair in selected {
                let kind = kinds[pair.textIndex] ?? pair.header.kind
                let oldText = oldDoc?.page(at: pair.textIndex).map { PDFHeaderParser.parse($0).body } ?? ""
                let image = scratch.appendingPathComponent("\(op.journal.operationID.uuidString)-p\(pair.imageIndex + 1).jpg")
                guard Self.writeImageInput(original, pageIndex: pair.imageIndex, to: image) else {
                    throw Failure.imageNotExtracted(page: pair.imageIndex)
                }
                let reading = await read(image, pair, kind)
                try? FileManager.default.removeItem(at: image)   // a page of the archive; not kept past its reading
                do {
                    let page = try ReOCRPairs.replacementPage(for: pair, result: reading, model: model, kind: kind,
                                                              gatewayDisplayName: gatewayDisplayName,
                                                              localAgentDisplayName: localAgentDisplayName,
                                                              localAgentModelName: localAgentModelName)
                    replacements[pair.textIndex] = page
                    // The Kind actually written, which falls back to the reader's own when none was chosen.
                    let written = PDFDocument(data: page)?.page(at: 0).flatMap { PDFHeaderParser.parse($0).header?.kind }
                    results.append(PairResult(pair: pair, oldText: oldText, kind: written, outcome: .success(reading.text ?? "")))
                } catch let r as ReOCRPairs.Refusal {
                    results.append(PairResult(pair: pair, oldText: oldText, kind: kind, outcome: .failure(r)))
                }
            }
        } catch {
            // No review comes back, so nobody could reject it: record the verdict here rather than strand the copy.
            try? writer.reject(op)
            throw error
        }
        guard replacements.count == selected.count else {
            return Review(operation: op, results: results, candidate: nil, candidateProblem: nil)
        }
        do {
            let candidate = try ReOCRIncrementalWriter.candidate(original: original, replacements: replacements)
            return Review(operation: op, results: results, candidate: candidate, candidateProblem: nil)
        } catch {
            return Review(operation: op, results: results, candidate: nil, candidateProblem: "\(error)")
        }
    }

    @discardableResult
    func accept(_ review: Review) throws -> ReOCRFileWriter.Journal {
        guard let candidate = review.candidate else { throw Failure.noCandidate }
        return try writer.accept(review.operation, candidate: candidate)
    }

    func reject(_ review: Review) throws {
        try writer.reject(review.operation)
    }

    // MARK: Image input

    private static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(), chmod(url.path, 0o700) == 0
        else { throw CocoaError(.fileWriteNoPermission) }
    }

    /// The image page as a JPEG file at `url`: its embedded JPEG stream byte for byte when the page is unrotated and
    /// draws exactly one image, which is a JPEG; otherwise a 300 dpi rendering of the page.
    static func writeImageInput(_ pdf: Data, pageIndex: Int, to url: URL) -> Bool {
        if let jpeg = embeddedJPEG(pdf, pageIndex: pageIndex) {
            return FileManager.default.createFile(atPath: url.path, contents: jpeg, attributes: [.posixPermissions: 0o600])
        }
        guard let doc = ReOCRPreservationCheck.document(pdf), let page = doc.page(at: pageIndex + 1) else { return false }
        return withExtendedLifetime(doc) { render(page, to: url) }
    }

    /// The page's JPEG, byte for byte, only when that is exactly what the page shows: an unrotated page whose content
    /// is `q`/`Q`, rectangular clips that hold the whole image, one `cm` that scales without turning, flipping or
    /// skewing and keeps the whole image inside the crop box, and one `Do` of its only XObject; the XObject a JPEG image with no mask or decode array and an upright
    /// orientation. Anything else (text, paths, clipping, shading, inline images, a second image) is rendered instead.
    static func embeddedJPEG(_ pdf: Data, pageIndex: Int) -> Data? {
        guard let doc = ReOCRPreservationCheck.document(pdf) else { return nil }
        return withExtendedLifetime(doc) { () -> Data? in
            guard let page = doc.page(at: pageIndex + 1), page.rotationAngle % 360 == 0, let dict = page.dictionary else {
                return nil
            }
            var resources: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources,
                  CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects,
                  CGPDFDictionaryGetCount(xobjects) == 1 else { return nil }
            final class Found { var name: String?; var stream: CGPDFStreamRef? }
            let found = Found()
            CGPDFDictionaryApplyBlock(xobjects, { key, object, info in
                let found = Unmanaged<Found>.fromOpaque(info!).takeUnretainedValue()
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(object, .stream, &stream) { found.name = String(cString: key); found.stream = stream }
                return true
            }, Unmanaged.passUnretained(found).toOpaque())
            guard let name = found.name, let stream = found.stream, let image = CGPDFStreamGetDictionary(stream) else { return nil }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(image, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" else {
                return nil
            }
            var any: CGPDFObjectRef?
            for key in ["SMask", "Mask", "Decode", "ImageMask"] where CGPDFDictionaryGetObject(image, key, &any) { return nil }
            guard let drawn = drawsOnlyImage(page, name: name) else { return nil }
            let crop = page.getBoxRect(.cropBox).insetBy(dx: -0.5, dy: -0.5)
            guard crop.contains(drawn) else { return nil }
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(stream, &format) as Data?, format == .jpegEncoded,
                  let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1 else {
                return nil
            }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            if let o = props?[kCGImagePropertyOrientation] as? Int, o != 1 { return nil }
            return data
        }
    }

    /// The rectangle the page's only `Do` of `name` covers, when the content is nothing but `q`, one upright scaling
    /// `cm`, that `Do` and `Q`; nil for anything else. Every operator that draws, clips or paints is registered so
    /// that its presence is seen (an unregistered operator would pass silently).
    private static func drawsOnlyImage(_ page: CGPDFPage, name: String) -> CGRect? {
        final class State {
            var matrix: [CGFloat]?
            var matrices = 0
            var dos: [String] = []
            var other = false
            var rects: [CGRect] = []
            var clips = 0
        }
        let state = State()
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            var values: [CGFloat] = []
            for _ in 0..<6 {
                var v: CGPDFReal = 0
                guard CGPDFScannerPopNumber(scanner, &v) else { state.other = true; return }
                values.insert(v, at: 0)
            }
            state.matrix = values
            state.matrices += 1
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            var n: UnsafePointer<CChar>?
            if CGPDFScannerPopName(scanner, &n), let n { state.dos.append(String(cString: n)) } else { state.other = true }
        }
        // A rectangle may only clip (`re W n`, as PDFKit writes around every page); it is checked below to hold the
        // whole image.
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            var v = [CGPDFReal](repeating: 0, count: 4)
            for i in (0..<4).reversed() { guard CGPDFScannerPopNumber(scanner, &v[i]) else { state.other = true; return } }
            state.rects.append(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]).standardized)
        }
        CGPDFOperatorTableSetCallback(table, "W") { _, info in
            Unmanaged<State>.fromOpaque(info!).takeUnretainedValue().clips += 1
        }
        CGPDFOperatorTableSetCallback(table, "n") { _, _ in }
        for op in ["BT", "ET", "Tj", "TJ", "'", "\"", "m", "l", "c", "v", "y", "h", "S", "s", "f", "F", "f*", "B", "B*",
                   "b", "b*", "W*", "sh", "BI", "ID", "EI", "d0", "d1", "BDC", "BMC", "DP", "MP", "gs"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in
                Unmanaged<State>.fromOpaque(info!).takeUnretainedValue().other = true
            }
        }
        let content = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(state).toOpaque())
        let scanned = CGPDFScannerScan(scanner)
        guard scanned, !state.other, state.matrices == 1, state.dos == [name], let m = state.matrix,
              m[1] == 0, m[2] == 0, m[0] > 0, m[3] > 0, state.rects.count == state.clips else { return nil }
        let drawn = CGRect(x: m[4], y: m[5], width: m[0], height: m[3])
        // The clips are in the coordinates before the one `cm` (PDFKit writes them first); a clip after it would be in
        // image space and is refused by requiring every clip to hold the drawn rectangle in page space.
        guard state.rects.allSatisfy({ $0.insetBy(dx: -0.5, dy: -0.5).contains(drawn) }) else { return nil }
        return drawn
    }

    private static func render(_ page: CGPDFPage, to url: URL) -> Bool {
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = 300.0 / 72.0
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0, w * h <= 120_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0,
                                                 preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(dest) && chmod(url.path, 0o600) == 0
    }
}
