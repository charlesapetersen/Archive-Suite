#if DEBUG // a test driver, compiled out of Release
import AppKit
import ArchiveCore
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Part of `ReOCRJobTestDriver` (`scripts/test-reocr-job.sh`), $0 and scratch-only: Improve OCR reads a page's verified
/// Preservation Copy (W49.proc-reocr-preservation, owner call 34). Each fixture is a real catalogue filing (reading PDF,
/// companion and `Preservation/` folder through `ProcessorCatalogueFiling`) in a scratch case folder.
///
///   18a. An upright JPEG original reaches the reader with its image data intact and its location metadata left out,
///        named in the review.
///   18b. A sideways original (pixels turned) and one turned by its EXIF orientation reach the reader upright.
///   18c. A multi-page PDF original gives the reader its mapped page, not its first.
///   18d. Two originals with the same intake name each reach their own page.
///   18e. A missing, altered or unmatched original, or a file with no record, falls back to the reading PDF's image and
///        the review says why.
///   18f. The Preservation folder is left exactly as it was by a run and an acceptance, and the accepted file still
///        reads its originals.
@MainActor
enum ReOCRImageInputTestDriver {
    typealias Check = (String, Bool, String) -> Void

    final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var images: [Int: Data] = [:]
        var read: ReOCRJob.Reader {
            { [self] url, pair, _ in
                let bytes = (try? Data(contentsOf: url)) ?? Data()
                lock.withLock { images[pair.imageIndex] = bytes }
                return OCRResult(text: "Read from the original of page \(pair.imageIndex + 1).", classification: nil,
                                 errorMessage: nil, errorCode: nil)
            }
        }
    }

    private static let model = LLMModel.geminiModels[0]
    nonisolated private static let rootGUID = UUID(uuidString: "0b7f3c55-2d1e-4a8b-9c6f-71e2d4a3b5c9")!

    /// A page-like picture: dark bars of uneven length on white, laid out differently for each seed and not symmetric
    /// under any quarter turn.
    static func picture(seed: Int, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1))
        // A heading block near the top left, then lines whose lengths vary with the seed.
        ctx.fill(CGRect(x: w * 0.08, y: h * 0.82, width: w * 0.45, height: h * 0.08))
        var state = UInt64(seed * 7919 + 17)
        for line in 0..<12 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let length = 0.3 + Double(state >> 40 & 0xFFFF) / 65535 * 0.55
            ctx.fill(CGRect(x: w * 0.08, y: h * (0.72 - CGFloat(line) * 0.055), width: w * CGFloat(length), height: h * 0.025))
        }
        ctx.fill(CGRect(x: w * 0.6, y: h * 0.05, width: w * 0.3, height: h * 0.06))
        return ctx.makeImage()
    }

    static func writeJPEG(_ image: CGImage, to url: URL, orientation: Int? = nil, type: UTType = .jpeg,
                          gps: Bool = false) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        if gps {
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 37.4275, kCGImagePropertyGPSLatitudeRef: "N",
                                                         kCGImagePropertyGPSLongitude: 122.1697, kCGImagePropertyGPSLongitudeRef: "W"]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func scaled(_ image: CGImage, by factor: Double) -> CGImage? {
        let w = max(1, Int(Double(image.width) * factor)), h = max(1, Int(Double(image.height) * factor))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Concentric squares: the same under every quarter turn, so no turn can be told from another.
    static func concentric(_ side: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        for ring in 0..<8 {
            let grey = ring % 2 == 0 ? 0.15 : 0.95, inset = CGFloat(ring * side / 16)
            ctx.setFillColor(CGColor(red: grey, green: grey, blue: grey, alpha: 1))
            ctx.fill(CGRect(x: inset, y: inset, width: CGFloat(side) - 2 * inset, height: CGFloat(side) - 2 * inset))
        }
        return ctx.makeImage()
    }

    /// The page photographed on a grey table: a 12% margin all round, slightly uneven.
    static func framedPhoto(_ page: CGImage) -> CGImage? {
        let w = Int(Double(page.width) * 1.24), h = Int(Double(page.height) * 1.24)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.45, green: 0.4, blue: 0.35, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(page, in: CGRect(x: Double(page.width) * 0.10, y: Double(page.height) * 0.13,
                                  width: Double(page.width), height: Double(page.height)))
        return ctx.makeImage()
    }

    /// The decoded pixels, for an equality check of two encodings of one image.
    static func pixels(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image.dataProvider?.data as Data?
    }

    static func hasGPS(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return properties[kCGImagePropertyGPSDictionary] != nil
    }

    /// How the reader's image looks against `expected`, both upright: same shape and a close grey match.
    static func looksLike(_ data: Data, _ expected: CGImage) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = ReOCRImageInput.upright(source, maxPixels: 512),
              let a = ReOCRImageInput.grey(image), let b = ReOCRImageInput.grey(expected) else { return false }
        let shape = Double(image.width) / Double(image.height) / (Double(expected.width) / Double(expected.height))
        return abs(shape - 1) < 0.05 && ReOCRImageInput.correlation(a, b) > 0.9
    }

    struct Fixture {
        let dir: URL
        let file: URL
        let preservation: URL
        let job: ReOCRJob
        var root: ReOCRJob.Root { ReOCRJob.Root(guid: ReOCRImageInputTestDriver.rootGUID, url: dir) }
    }

    /// A filed reading PDF with one image/text pair per entry of `pages`: each pair's image page shows `reading` (the
    /// upright, smaller reading copy), and the map points it at `original`'s page `index`.
    static func fixture(_ dir: URL, pages: [(reading: URL, original: URL, index: Int)]) throws -> Fixture {
        let fm = FileManager.default
        let work = dir.appendingPathComponent("work", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        var parts: [URL] = []
        for (n, page) in pages.enumerated() {
            let part = work.appendingPathComponent("part\(n + 1).pdf")
            _ = try PDFGenerator().generate(imageURL: page.reading, result: OCRResult(
                text: "Old reading of page \(n + 1).", classification: nil, errorMessage: nil, errorCode: nil),
                model: model, outputURL: part, originalFileName: page.original.lastPathComponent, pageKind: .typewritten)
            parts.append(part)
        }
        let identity = CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID())
        let document = ProcessorCatalogueRecord.Document(id: UUID(), ownerFileID: identity.fileID, fields: .init(),
                                                         enclosedWith: nil)
        let sourcePages = pages.map { _ in ProcessorCatalogueRecord.SourcePage(roles: ["image", "text"]) }
        let inputs = try pages.map {
            ProcessorPreservationFiling.LogicalPage(source: try .init(url: $0.original), originalPageIndex: $0.index)
        }
        let target = dir.appendingPathComponent("Letter.pdf")
        let preservation = try ProcessorPreservationFiling(fileID: identity.fileID, pages: sourcePages, inputs: inputs)
            .named(for: target)
        let record = try ProcessorCatalogueRecord(identity: identity, sourcePages: sourcePages, document: document,
                                                  fileFields: .init(),
                                                  preservationManifestSHA256: preservation.manifest.digest()).encoded()
        let prepared = work.appendingPathComponent("working.derivative")
        try PDFGenerator().mergeDocumentPDFs(sourcePDFs: parts, outputURL: prepared, catalogueIdentity: identity)
        let filing = try ProcessorCatalogueFiling(operationID: identity.fileID, root: dir, rootInstanceID: UUID(),
                                                  destination: target, carriesFinderTags: false)
        _ = try filing.file(preparedPDF: prepared, record: record, preservation: preservation)
        try fm.removeItem(at: work)
        let folder = dir.appendingPathComponent(PreservationCopy.directoryName)
            .appendingPathComponent(document.id.uuidString.lowercased())
            .appendingPathComponent(identity.fileID.uuidString.lowercased())
        let support = dir.deletingLastPathComponent().appendingPathComponent("support-\(dir.lastPathComponent)")
        try fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let job = ReOCRJob(writer: ReOCRFileWriter(versionsRoot: support.appendingPathComponent("Versions", isDirectory: true)),
                           scratch: support.appendingPathComponent("scratch", isDirectory: true), support: support)
        return Fixture(dir: dir, file: target, preservation: folder, job: job)
    }

    /// Every file under `folder` with its bytes and modification date.
    static func snapshot(_ folder: URL) -> [String: (Data, Date)] {
        var out: [String: (Data, Date)] = [:]
        let fm = FileManager.default
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return out }
        for case let url as URL in e {
            guard let data = try? Data(contentsOf: url),
                  let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let date = attributes[.modificationDate] as? Date else { continue }
            out[url.lastPathComponent] = (data, date)
        }
        return out
    }

    static func same(_ a: [String: (Data, Date)], _ b: [String: (Data, Date)]) -> Bool {
        a.count == b.count && a.allSatisfy { key, value in b[key].map { $0.0 == value.0 && $0.1 == value.1 } ?? false }
    }

    static func run(in base: URL, check: Check) async {
        do {
            try await runCases(in: base, check: check)
        } catch {
            check("18 Preservation Copy fixtures", false, "\(error)")
        }
    }

    private static func runCases(in base: URL, check report: Check) async throws {
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { report(name, ok, ok ? "" : detail()) }
        let fm = FileManager.default
        var serial = 0
        func folder(_ name: String) throws -> URL {
            serial += 1
            let url = base.appendingPathComponent("18-\(serial)-\(name)", isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func images(_ dir: URL, seed: Int, name: String = "IMG") throws -> (upright: CGImage, reading: URL, original: URL) {
            let intake = dir.appendingPathComponent("intake-\(seed)", isDirectory: true)
            try fm.createDirectory(at: intake, withIntermediateDirectories: true)
            guard let upright = picture(seed: seed, width: 600, height: 800),
                  let small = scaled(upright, by: 0.5) else { throw CocoaError(.fileWriteUnknown) }
            let reading = intake.appendingPathComponent("reading-\(seed).jpg")
            try writeJPEG(small, to: reading)
            let original = intake.appendingPathComponent("\(name).jpg")
            try writeJPEG(upright, to: original, gps: true)
            return (upright, reading, original)
        }

        // 18a. Upright JPEG: the image data unchanged, the location left out.
        let a = try folder("upright")
        let pa = try images(a, seed: 1)
        let fa = try fixture(a, pages: [(pa.reading, pa.original, 0)])
        let ra = Reader()
        let before = snapshot(fa.preservation)
        let review = try await fa.job.start(file: fa.file, root: fa.root, model: model, read: ra.read)
        let originalA = try Data(contentsOf: pa.original)
        check("18a the reader gets the original JPEG's image data unchanged",
              ra.images[0].flatMap(pixels) != nil && ra.images[0].flatMap(pixels) == pixels(originalA),
              "\(ra.images[0]?.count ?? 0) bytes")
        check("18a the fixture original carries a location", hasGPS(originalA))
        check("18a the location is not sent", ra.images[0].map(hasGPS) == false)
        check("18a the review names the Preservation Copy", review.results.first?.input == .preservation(name: "IMG.jpg"),
              "\(String(describing: review.results.first?.input))")
        check("18a the Preservation folder holds the original", before.count == 2)

        // 18f. Read-only: the folder is unchanged by the run and the acceptance; the improved file still reads it.
        _ = try fa.job.accept(review)
        check("18f the acceptance published the new text",
              PDFDocument(url: fa.file)?.page(at: 1)?.string?.contains("Read from the original of page 1.") == true)
        check("18f the Preservation folder is untouched by a run and an acceptance", same(before, snapshot(fa.preservation)))
        let again = Reader()
        let second = try await fa.job.start(file: fa.file, root: fa.root, model: model, read: again.read)
        check("18f the improved file still reads its Preservation Copy",
              second.results.first?.input == .preservation(name: "IMG.jpg"), "\(String(describing: second.results.first?.input))")
        try fa.job.reject(second)
        check("18f the folder is still untouched", same(before, snapshot(fa.preservation)))

        // 18b. Sideways originals reach the reader upright.
        let b = try folder("sideways")
        let pb = try images(b, seed: 2)
        guard let turnedLeft = ReOCRImageInput.rotate(pb.upright, quarterTurns: 3) else { throw CocoaError(.fileWriteUnknown) }
        let sideways = b.appendingPathComponent("intake-2/Sideways.jpg")
        try writeJPEG(turnedLeft, to: sideways)
        // EXIF 6: the stored pixels are turned left, and a viewer turns them right to show the page upright.
        let tagged = b.appendingPathComponent("intake-2/Tagged.heic")
        try writeJPEG(turnedLeft, to: tagged, orientation: 6, type: .heic)
        let pb2 = try images(b, seed: 3)
        guard let upside = ReOCRImageInput.rotate(pb2.upright, quarterTurns: 2) else { throw CocoaError(.fileWriteUnknown) }
        let upsideDown = b.appendingPathComponent("intake-3/Upside.png")
        try writeJPEG(upside, to: upsideDown, type: .png)
        // A photograph: the page on a darker table with a margin, turned right; the reading copy is cropped to the page.
        let photo = b.appendingPathComponent("intake-2/Photo.jpg")
        guard let framed = framedPhoto(pb.upright), let turnedRight = ReOCRImageInput.rotate(framed, quarterTurns: 1) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try writeJPEG(turnedRight, to: photo)
        let fb = try fixture(b, pages: [(pb.reading, sideways, 0), (pb.reading, tagged, 0), (pb2.reading, upsideDown, 0),
                                        (pb.reading, photo, 0)])
        let rb = Reader()
        let reviewB = try await fb.job.start(file: fb.file, root: fb.root, model: model, read: rb.read)
        check("18b a sideways original is turned upright", rb.images[0].map { looksLike($0, pb.upright) } == true)
        check("18b an original turned by its EXIF orientation is upright", rb.images[2].map { looksLike($0, pb.upright) } == true)
        check("18b an upside-down PNG original is turned upright", rb.images[4].map { looksLike($0, pb2.upright) } == true)
        check("18b a photograph with a table margin is turned upright",
              rb.images[6].flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
                .flatMap { ReOCRImageInput.upright($0, maxPixels: 512) }
                .flatMap { ReOCRImageInput.quarterTurns(from: $0, toMatch: pb.upright) } == 0)
        check("18b each is read from its Preservation Copy", reviewB.results.map(\.input) == [
            .preservation(name: "Sideways.jpg"), .preservation(name: "Tagged.heic"), .preservation(name: "Upside.png"),
            .preservation(name: "Photo.jpg")],
              "\(reviewB.results.map(\.input))")
        check("18b the full resolution is kept",
              rb.images[0].flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                .map { ($0[kCGImagePropertyPixelWidth] as? Int, $0[kCGImagePropertyPixelHeight] as? Int) == (600, 800) } == true)
        try fb.job.reject(reviewB)

        // 18c. A two-page PDF original: each reading page gets its mapped page.
        let c = try folder("multipage")
        let p1 = try images(c, seed: 4), p2 = try images(c, seed: 5)
        let original = PDFDocument()
        for (i, image) in [p1.upright, p2.upright].enumerated() {
            guard let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: 300, height: 400))) else {
                throw CocoaError(.fileWriteUnknown)
            }
            original.insert(page, at: i)
        }
        let scan = c.appendingPathComponent("Scan.pdf")
        guard original.write(to: scan) else { throw CocoaError(.fileWriteUnknown) }
        let fc = try fixture(c, pages: [(p2.reading, scan, 1), (p1.reading, scan, 0)])
        let rc = Reader()
        let reviewC = try await fc.job.start(file: fc.file, root: fc.root, model: model, read: rc.read)
        check("18c the two pages of the original are told apart", !looksLike(try Data(contentsOf: p1.original), p2.upright))
        check("18c the first reading page gets the PDF's second page", rc.images[0].map { looksLike($0, p2.upright)
            && !looksLike($0, p1.upright) } == true)
        check("18c the second reading page gets the PDF's first page", rc.images[2].map { looksLike($0, p1.upright)
            && !looksLike($0, p2.upright) } == true)
        check("18c both from the Preservation Copy", reviewC.results.map(\.input) == [
            .preservation(name: "Scan.pdf"), .preservation(name: "Scan.pdf")], "\(reviewC.results.map(\.input))")
        try fc.job.reject(reviewC)

        // 18d. Two originals with one intake name.
        let d = try folder("same-name")
        let d1 = try images(d, seed: 6, name: "Page"), d2 = try images(d, seed: 7, name: "Page")
        let fd = try fixture(d, pages: [(d1.reading, d1.original, 0), (d2.reading, d2.original, 0)])
        let rd = Reader()
        let reviewD = try await fd.job.start(file: fd.file, root: fd.root, model: model, read: rd.read)
        let names = try [d1.original, d2.original].map { try Data(contentsOf: $0) }
        check("18d the first page reads its own namesake", rd.images[0].flatMap(pixels) == pixels(names[0]))
        check("18d the second page reads its own namesake", rd.images[2].flatMap(pixels) == pixels(names[1]))
        check("18d the namesakes differ", pixels(names[0]) != pixels(names[1]))
        check("18d both named by their intake name", reviewD.results.map(\.input) == [
            .preservation(name: "Page.jpg"), .preservation(name: "Page.jpg")])
        try fd.job.reject(reviewD)

        // 18e. Fallbacks: missing, altered, unmatched, and no record.
        let e = try folder("fallbacks")
        let e1 = try images(e, seed: 8), e2 = try images(e, seed: 9), e3 = try images(e, seed: 10)
        guard let unrelated = concentric(800) else { throw CocoaError(.fileWriteUnknown) }
        let noise = e.appendingPathComponent("intake-10/Other.jpg")
        try writeJPEG(unrelated, to: noise)
        let fe = try fixture(e, pages: [(e1.reading, e1.original, 0), (e2.reading, e2.original, 0), (e3.reading, noise, 0)])
        let stored = try fm.contentsOfDirectory(atPath: fe.preservation.path).filter { $0 != PreservationCopy.manifestName }.sorted()
        try fm.removeItem(at: fe.preservation.appendingPathComponent(stored[0]))
        var altered = try Data(contentsOf: fe.preservation.appendingPathComponent(stored[1]))
        altered[altered.count / 2] ^= 0xFF
        try altered.write(to: fe.preservation.appendingPathComponent(stored[1]))
        let re = Reader()
        let reviewE = try await fe.job.start(file: fe.file, root: fe.root, model: model, read: re.read)
        check("18e a missing original falls back and says so", reviewE.results.first?.input == .readingPDF(.missing),
              "\(String(describing: reviewE.results.first?.input)) \(stored)")
        check("18e an altered original falls back and says so", reviewE.results.dropFirst().first?.input == .readingPDF(.unverified),
              "\(reviewE.results.map(\.input))")
        check("18e an original that matches no turn of the page falls back and says so",
              reviewE.results.last?.input == .readingPDF(.orientationUnmatched), "\(reviewE.results.map(\.input))")
        let readings = try [e1.reading, e2.reading, e3.reading].map { try Data(contentsOf: $0) }
        check("18e the fallback reads the reading PDF's own image",
              re.images[0] == readings[0] && re.images[2] == readings[1] && re.images[4] == readings[2])
        check("18e the review still has a candidate", reviewE.candidate != nil, reviewE.candidateProblem ?? "")
        check("18e the review line says why",
              reviewE.results.first?.input.summary == "Read from the reading PDF: its Preservation Copy is missing.")
        try fe.job.reject(reviewE)

        // No companion: a reading PDF without a record (the plain fixture of case 1 is covered there too).
        try fm.removeItem(at: e.appendingPathComponent("Letter.pdf.archivesuite.json"))
        let rn = Reader()
        let reviewN = try await fe.job.start(file: fe.file, root: fe.root, model: model, read: rn.read)
        check("18e a file with no record reads the reading PDF", reviewN.results.allSatisfy { $0.input == .readingPDF(.notRecorded) },
              "\(reviewN.results.map(\.input))")
        try fe.job.reject(reviewN)
    }
}
#endif
