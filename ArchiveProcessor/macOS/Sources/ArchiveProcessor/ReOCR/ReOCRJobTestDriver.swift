#if DEBUG // a test driver, compiled out of Release
import AppKit
import ArchiveCore
import ImageIO
import PDFKit

/// Headless, $0 self-test of one file's Improve OCR run (W44.reocr-processor), gated by `REOCR_JOB_TEST=1` (does
/// nothing in normal use), with a fake reader: no model call, no network, no window. Fixtures are Processor output in
/// `REOCR_JOB_TEST_DIR`, a scratch folder the script makes; never the corpus. Run by `scripts/test-reocr-job.sh`.
///
/// What has to be true:
///   1. A two-page file: the reader gets the page's own embedded JPEG, once; the review shows the old and new text;
///      accepting publishes the new text page.
///   2. Selecting one pair of three reads only that pair's image and changes only its text page.
///   3. One failed pair of three means no candidate: accept is refused and the file is untouched; reject records the
///      verdict and recovery reports it.
///   4. A Kind chosen by the person reaches the reader and the new header.
///   5. An ineligible file is refused before anything is kept or read.
///   6. A file changed between the run and the accept is refused at accept.
///   6b. A failure after `prepare` records the operation rejected.
///   6c. The JPEG fast path takes a page only when it shows exactly its JPEG (a full or letterboxed upright image);
///       cropped, flipped, clipped, masked, twice-drawn or text-bearing pages are rendered.
///   7. A rotated image page is rendered rather than extracted, and still reaches the reader as a JPEG.
@MainActor
enum ReOCRJobTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["REOCR_JOB_TEST"] == "1" else { return }
        didRun = true
        Task { @MainActor in await run() }
    }

    private static var lines: [String] = []
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    private static let model = LLMModel.geminiModels[0]
    private static var root = URL(fileURLWithPath: "/nonexistent")
    private static var serial = 0

    /// What the fake reader was asked, and what it answers.
    final class FakeReader: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(image: Data, imageIndex: Int, kind: OCRPageKind?)] = []
        let failing: Set<Int>
        init(failing: Set<Int> = []) { self.failing = failing }

        var read: ReOCRJob.Reader {
            { [self] url, pair, kind in
                let bytes = (try? Data(contentsOf: url)) ?? Data()
                lock.withLock { calls.append((bytes, pair.imageIndex, kind)) }
                if failing.contains(pair.imageIndex) {
                    return OCRResult(text: nil, classification: nil, errorMessage: "the reader refused", errorCode: "refused")
                }
                return OCRResult(text: "New reading of image page \(pair.imageIndex + 1).", classification: nil,
                                 errorMessage: nil, errorCode: nil)
            }
        }
    }

    private static func folder(_ name: String) throws -> URL {
        serial += 1
        let dir = root.appendingPathComponent("\(serial)-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func job(_ dir: URL) -> ReOCRJob {
        ReOCRJob(writer: ReOCRFileWriter(versionsRoot: dir.appendingPathComponent("Versions", isDirectory: true)),
                 scratch: dir.appendingPathComponent("scratch", isDirectory: true))
    }

    private static func jpeg(_ url: URL, seed: Int) throws {
        let w = 160, h = 200
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        ctx.setFillColor(CGColor(red: CGFloat(seed % 5) / 5, green: 0.5, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 10, y: 10, width: 100, height: 150))
        guard let image = ctx.makeImage(), let rep = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try rep.write(to: url)
    }

    /// A Processor file of `pairs` image/text pairs in `dir`.
    private static func file(_ dir: URL, pairs: Int) throws -> URL {
        var parts: [URL] = []
        for n in 1...pairs {
            let img = dir.appendingPathComponent("IMG\(n).jpg"), pdf = dir.appendingPathComponent("part\(n).pdf")
            try jpeg(img, seed: n)
            try PDFGenerator().generate(imageURL: img, result: OCRResult(text: "Old reading of image \(n).", classification: nil,
                                        errorMessage: nil, errorCode: nil), model: model, outputURL: pdf,
                                        originalFileName: "IMG\(n).jpg", pageKind: .typewritten)
            parts.append(pdf)
        }
        let out = dir.appendingPathComponent("Letter.pdf")
        if pairs == 1 { try FileManager.default.moveItem(at: parts[0], to: out) } else {
            try PDFGenerator().mergeDocumentPDFs(sourcePDFs: parts, outputURL: out)
            for p in parts { try FileManager.default.removeItem(at: p) }
        }
        return out
    }

    /// A one-page 200 × 250 PDF whose page draws `content` with one JPEG image XObject `/Im0`.
    private static func handPDF(content: String, jpeg: Data, imageExtra: String, resources: String) -> Data {
        let src = CGImageSourceCreateWithData(jpeg as CFData, nil)
        let props = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 1, h = props?[kCGImagePropertyPixelHeight] as? Int ?? 1
        var out = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        func obj(_ body: Data) { offsets.append(out.count); out.append(Data("\(offsets.count) 0 obj\n".utf8)); out.append(body); out.append(Data("\nendobj\n".utf8)) }
        obj(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        obj(Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8))
        obj(Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 250] /Contents 4 0 R /Resources << /XObject << /Im0 5 0 R >> \(resources) >> >>".utf8))
        var c = Data("<< /Length \(content.utf8.count) >>\nstream\n".utf8); c.append(Data(content.utf8)); c.append(Data("\nendstream".utf8))
        obj(c)
        var i = Data("<< /Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode \(imageExtra) /Length \(jpeg.count) >>\nstream\n".utf8)
        i.append(jpeg); i.append(Data("\nendstream".utf8))
        obj(i)
        let xref = out.count
        var t = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for o in offsets { t += String(format: "%010d 00000 n \n", o) }
        t += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(t.utf8))
        return out
    }

    private static func text(_ url: URL, _ page: Int) -> String {
        PDFDocument(url: url)?.page(at: page)?.string ?? ""
    }

    static func run() async {
        defer { finish() }
        guard let dir = ProcessInfo.processInfo.environment["REOCR_JOB_TEST_DIR"] else {
            check("0 REOCR_JOB_TEST_DIR is set", false); return
        }
        root = URL(fileURLWithPath: dir, isDirectory: true)
        do {
            // 1. Two pages, end to end.
            do {
                let d = try folder("two"), f = try file(d, pairs: 1), j = job(d), reader = FakeReader()
                let original = try Data(contentsOf: f)
                let review = try await j.start(file: f, model: model, read: reader.read)
                check("1 the reader is asked once, for the image page", reader.calls.map(\.imageIndex) == [0])
                let source = try Data(contentsOf: d.appendingPathComponent("IMG1.jpg"))
                check("1 the reader gets the source JPEG byte for byte", reader.calls.first?.image == source,
                      "\(reader.calls.first?.image.count ?? 0) vs \(source.count) bytes")
                check("1 the page image is removed after its reading",
                      ((try? FileManager.default.contentsOfDirectory(atPath: j.scratch.path)) ?? ["?"]).isEmpty)
                check("1 the review shows the old text", review.results.first?.oldText.contains("Old reading of image 1.") == true)
                check("1 the review shows the new text",
                      (try? review.results.first?.outcome.get())?.contains("New reading of image page 1.") == true)
                check("1 there is a candidate", review.candidate != nil, review.candidateProblem ?? "")
                check("1 the file is unchanged before accept", (try? Data(contentsOf: f)) == original)
                try j.accept(review)
                check("1 accepting publishes the new text", text(f, 1).contains("New reading of image page 1.")
                      && !text(f, 1).contains("Old reading"))
                check("1 the old file is kept", (try? Data(contentsOf: j.writer.backupURL(review.operation.journal.operationID))) == original)
            }

            // 2. One pair of three.
            do {
                let d = try folder("one-of-three"), f = try file(d, pairs: 3), j = job(d), reader = FakeReader()
                let review = try await j.start(file: f, textPages: [3], model: model, read: reader.read)
                check("2 only the selected pair's image is read", reader.calls.map(\.imageIndex) == [2])
                try j.accept(review)
                check("2 its text page changes", text(f, 3).contains("New reading of image page 3."))
                check("2 the others keep their text", text(f, 1).contains("Old reading of image 1.")
                      && text(f, 5).contains("Old reading of image 3."))
                do { _ = try await j.start(file: f, textPages: [2], model: model, read: reader.read); check("2 an image page is not selectable", false) }
                catch { check("2 an image page is not selectable", (error as? ReOCRJob.Failure) == .noSuchPair(page: 2), "\(error)") }
            }

            // 3. A failed pair.
            do {
                let d = try folder("failed-pair"), f = try file(d, pairs: 3), j = job(d), reader = FakeReader(failing: [2])
                let original = try Data(contentsOf: f)
                let review = try await j.start(file: f, model: model, read: reader.read)
                check("3 every pair is still tried", reader.calls.map(\.imageIndex) == [0, 2, 4])
                check("3 a failed pair means no candidate", review.candidate == nil)
                check("3 the failure is shown for its page", { if case .failure = review.results[1].outcome { return true }; return false }())
                do { try j.accept(review); check("3 accept is refused", false) }
                catch { check("3 accept is refused", (error as? ReOCRJob.Failure) == .noCandidate, "\(error)") }
                check("3 the file is untouched", (try? Data(contentsOf: f)) == original)
                try j.reject(review)
                check("3 the verdict is recorded", j.writer.recover() == [.rejected(review.operation.journal.operationID)])
            }

            // 4. A Kind chosen by the person.
            do {
                let d = try folder("kind"), f = try file(d, pairs: 1), j = job(d), reader = FakeReader()
                let review = try await j.start(file: f, kinds: [1: .forms], model: model, read: reader.read)
                check("4 the reader is told the chosen Kind", reader.calls.first?.kind == .forms)
                try j.accept(review)
                let header = PDFDocument(url: f)?.page(at: 1).flatMap { PDFHeaderParser.parse($0).header }
                check("4 the new header has the chosen Kind", header?.kind == .forms, "\(String(describing: header))")
            }

            // 5. Ineligible.
            do {
                let d = try folder("ineligible"), j = job(d), reader = FakeReader()
                let f = d.appendingPathComponent("raw.pdf")
                let doc = PDFDocument(); doc.insert(PDFPage(), at: 0); try doc.dataRepresentation()?.write(to: f)
                do { _ = try await j.start(file: f, model: model, read: reader.read); check("5 a one-page file is refused", false) }
                catch { check("5 a one-page file is refused", { if case ReOCRJob.Failure.notEligible = error { return true }; return false }(), "\(error)") }
                check("5 nothing was kept or read", reader.calls.isEmpty
                      && !FileManager.default.fileExists(atPath: j.writer.versionsRoot.path))
            }

            // 6. Changed between run and accept.
            do {
                let d = try folder("changed"), f = try file(d, pairs: 1), j = job(d), reader = FakeReader()
                let review = try await j.start(file: f, model: model, read: reader.read)
                let h = try FileHandle(forWritingTo: f); try h.seekToEnd(); try h.write(contentsOf: Data("\n%e\n".utf8)); try h.close()
                let edited = try Data(contentsOf: f)
                do { try j.accept(review); check("6 a changed file is refused at accept", false) }
                catch { check("6 a changed file is refused at accept", (error as? ReOCRFileWriter.Failure) == .targetChanged, "\(error)") }
                check("6 the edit stays", (try? Data(contentsOf: f)) == edited)
            }

            // 6b. A failure after prepare records the operation rejected rather than leaving it pending.
            do {
                let d = try folder("fail-after-prepare"), f = try file(d, pairs: 1), reader = FakeReader()
                let blocker = d.appendingPathComponent("not-a-folder")
                try Data("x".utf8).write(to: blocker)
                let j = ReOCRJob(writer: ReOCRFileWriter(versionsRoot: d.appendingPathComponent("Versions", isDirectory: true)),
                                 scratch: blocker.appendingPathComponent("scratch", isDirectory: true))
                do { _ = try await j.start(file: f, model: model, read: reader.read); check("6b a failure after prepare throws", false) }
                catch { check("6b a failure after prepare throws", true) }
                let r = j.writer.recover()
                check("6b the operation is recorded rejected", r.count == 1 && { if case .rejected = r[0] { return true }; return false }(), "\(r)")
                check("6b nothing was read", reader.calls.isEmpty)
            }

            // 6c. The JPEG fast path only when the page shows exactly the JPEG.
            do {
                let d = try folder("fast-path")
                let img = d.appendingPathComponent("j.jpg")
                try jpeg(img, seed: 2)
                let jpg = try Data(contentsOf: img)
                func page(_ content: String, image: String = "", resources: String = "") -> Data {
                    handPDF(content: content, jpeg: jpg, imageExtra: image, resources: resources)
                }
                check("6c a plain full-page image is extracted",
                      ReOCRJob.embeddedJPEG(page("q 200 0 0 250 0 0 cm /Im0 Do Q"), pageIndex: 0) == jpg)
                check("6c a letterboxed image inside the page is extracted",
                      ReOCRJob.embeddedJPEG(page("q 100 0 0 125 50 60 cm /Im0 Do Q"), pageIndex: 0) == jpg)
                check("6c an image cropped by the page is rendered",
                      ReOCRJob.embeddedJPEG(page("q 400 0 0 500 -100 0 cm /Im0 Do Q"), pageIndex: 0) == nil)
                check("6c a flipped image is rendered",
                      ReOCRJob.embeddedJPEG(page("q -200 0 0 250 200 0 cm /Im0 Do Q"), pageIndex: 0) == nil)
                check("6c a page that also draws text is rendered",
                      ReOCRJob.embeddedJPEG(page("q 200 0 0 250 0 0 cm /Im0 Do Q BT ET"), pageIndex: 0) == nil)
                check("6c an image clipped smaller is rendered",
                      ReOCRJob.embeddedJPEG(page("q 0 0 100 100 re W n 200 0 0 250 0 0 cm /Im0 Do Q"), pageIndex: 0) == nil)
                check("6c a clip to the whole page (as PDFKit writes) is extracted",
                      ReOCRJob.embeddedJPEG(page("q Q q 0 0 200 250 re W n q 200 0 0 250 0 0 cm /Im0 Do Q Q"), pageIndex: 0) == jpg)
                check("6c a rectangle that is filled, not clipped, is rendered",
                      ReOCRJob.embeddedJPEG(page("q 0 0 10 10 re f 200 0 0 250 0 0 cm /Im0 Do Q"), pageIndex: 0) == nil)
                check("6c a masked image is rendered",
                      ReOCRJob.embeddedJPEG(page("q 200 0 0 250 0 0 cm /Im0 Do Q", image: "/Decode [1 0 1 0 1 0]"), pageIndex: 0) == nil)
                check("6c an image drawn twice is rendered",
                      ReOCRJob.embeddedJPEG(page("q 200 0 0 250 0 0 cm /Im0 Do Q q 200 0 0 250 0 0 cm /Im0 Do Q"), pageIndex: 0) == nil)
                let rendered = d.appendingPathComponent("r.jpg")
                check("6c a rendered page still reaches the reader as a JPEG",
                      ReOCRJob.writeImageInput(page("q 200 0 0 250 0 0 cm /Im0 Do Q BT ET"), pageIndex: 0, to: rendered)
                      && CGImageSourceCreateWithURL(rendered as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? } == "public.jpeg")
            }

            // 7. A rotated image page.
            do {
                let d = try folder("rotated"), f = try file(d, pairs: 1), reader = FakeReader()
                if let doc = PDFDocument(url: f), let p = doc.page(at: 0) {
                    p.rotation = 90
                    try doc.dataRepresentation()?.write(to: f)
                }
                let data = try Data(contentsOf: f)
                check("7 a rotated page is not extracted", ReOCRJob.embeddedJPEG(data, pageIndex: 0) == nil)
                let review = try await job(d).start(file: f, model: model, read: reader.read)
                let src = reader.calls.first.flatMap { CGImageSourceCreateWithData($0.image as CFData, nil) }
                let props = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
                check("7 it is rendered upright as a JPEG", src.map { CGImageSourceGetType($0) as String? } == "public.jpeg" && w > h,
                      "\(w)x\(h)")
                check("7 its candidate is made", review.candidate != nil, review.candidateProblem ?? "")
            }
        } catch {
            check("no error is thrown", false, "\(error)")
        }
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["REOCR_JOB_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}
#endif
