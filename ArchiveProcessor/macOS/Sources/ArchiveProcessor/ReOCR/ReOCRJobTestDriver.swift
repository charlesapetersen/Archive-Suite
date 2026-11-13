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
///   8. After publication the receipt is written and the reviewed `OCR Poor` generation cleared, other tags kept; a
///      flag set again during the read, or another app's unfinished action, leaves the flag; an unflagged file has
///      nothing to clear; a file outside its root is refused.
///   9. After a crash past the swap, launch recovery publishes, writes the receipt and clears the flag, once.
///   13. The dialog's model: Kind groups, a Kind change re-ranks, the estimate, Run's blocker, per-Kind readers and models.
///   12. A real reader on this Mac (Apple Vision, $0) through the row factory reads the page and is named in the header.
///   11. The saved support connection resolves, follows a moved folder, refuses a different store, forgets on disconnect.
///   10. Restore puts the original back with later tag edits kept and the flag re-added; refused on a changed file or
///       a second time; no re-flag after a later flag action or when the original was not flagged.
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

    private static let rootGUID = UUID(uuidString: "5d1e0c2a-7b44-4c1e-9a0f-3c2b1a0d9e8f")!

    /// The case folder stands in for the archive root; the shared support folder sits beside it, outside.
    private static func support(_ dir: URL) -> URL {
        let url = root.appendingPathComponent("support-\(dir.lastPathComponent)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func job(_ dir: URL) -> ReOCRJob {
        ReOCRJob(writer: ReOCRFileWriter(versionsRoot: dir.appendingPathComponent("Versions", isDirectory: true)),
                 scratch: dir.appendingPathComponent("scratch", isDirectory: true), support: support(dir))
    }

    private static func archive(_ dir: URL) -> ReOCRJob.Root { ReOCRJob.Root(guid: rootGUID, url: dir) }

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

    /// A JPEG of large black typed words on white, for Apple Vision to read.
    private static func typedPage(_ url: URL, _ text: String) throws {
        let w = 1700, h = 2200
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let s = NSAttributedString(string: text, attributes: [.font: NSFont(name: "Courier", size: 64) ?? NSFont.systemFont(ofSize: 64),
                                                             .foregroundColor: NSColor.black])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(s), CFRange(location: 0, length: s.length),
                                             CGPath(rect: CGRect(x: 120, y: 600, width: w - 240, height: 1400), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        guard let image = ctx.makeImage(), let rep = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try rep.write(to: url)
    }

    private static func tag(_ url: URL, _ tags: [String]) throws {
        _ = try CoordinatedTagWriter.write(url) { _, label in (tags, label) }
    }

    private static func tags(_ url: URL) -> [String] { TagReading.read(url).tagNames ?? [] }

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
                let review = try await j.start(file: f, root: archive(d), model: model, read: reader.read)
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
                _ = try j.accept(review)
                check("1 accepting publishes the new text", text(f, 1).contains("New reading of image page 1.")
                      && !text(f, 1).contains("Old reading"))
                check("1 the old file is kept", (try? Data(contentsOf: j.writer.backupURL(review.operation.journal.operationID))) == original)
            }

            // 2. One pair of three.
            do {
                let d = try folder("one-of-three"), f = try file(d, pairs: 3), j = job(d), reader = FakeReader()
                let review = try await j.start(file: f, root: archive(d), textPages: [3], model: model, read: reader.read)
                check("2 only the selected pair's image is read", reader.calls.map(\.imageIndex) == [2])
                _ = try j.accept(review)
                check("2 its text page changes", text(f, 3).contains("New reading of image page 3."))
                check("2 the others keep their text", text(f, 1).contains("Old reading of image 1.")
                      && text(f, 5).contains("Old reading of image 3."))
                do { _ = try await j.start(file: f, root: archive(d), textPages: [2], model: model, read: reader.read); check("2 an image page is not selectable", false) }
                catch { check("2 an image page is not selectable", (error as? ReOCRJob.Failure) == .noSuchPair(page: 2), "\(error)") }
            }

            // 3. A failed pair.
            do {
                let d = try folder("failed-pair"), f = try file(d, pairs: 3), j = job(d), reader = FakeReader(failing: [2])
                let original = try Data(contentsOf: f)
                let review = try await j.start(file: f, root: archive(d), model: model, read: reader.read)
                check("3 every pair is still tried", reader.calls.map(\.imageIndex) == [0, 2, 4])
                check("3 a failed pair means no candidate", review.candidate == nil)
                check("3 the failure is shown for its page", { if case .failure = review.results[1].outcome { return true }; return false }())
                do { _ = try j.accept(review); check("3 accept is refused", false) }
                catch { check("3 accept is refused", (error as? ReOCRJob.Failure) == .noCandidate, "\(error)") }
                check("3 the file is untouched", (try? Data(contentsOf: f)) == original)
                try j.reject(review)
                check("3 the verdict is recorded", j.writer.recover() == [.rejected(review.operation.journal.operationID)])
            }

            // 4. A Kind chosen by the person.
            do {
                let d = try folder("kind"), f = try file(d, pairs: 1), j = job(d), reader = FakeReader()
                let review = try await j.start(file: f, root: archive(d), kinds: [1: .forms], model: model, read: reader.read)
                check("4 the reader is told the chosen Kind", reader.calls.first?.kind == .forms)
                _ = try j.accept(review)
                let header = PDFDocument(url: f)?.page(at: 1).flatMap { PDFHeaderParser.parse($0).header }
                check("4 the new header has the chosen Kind", header?.kind == .forms, "\(String(describing: header))")
            }

            // 5. Ineligible.
            do {
                let d = try folder("ineligible"), j = job(d), reader = FakeReader()
                let f = d.appendingPathComponent("raw.pdf")
                let doc = PDFDocument(); doc.insert(PDFPage(), at: 0); try doc.dataRepresentation()?.write(to: f)
                do { _ = try await j.start(file: f, root: archive(d), model: model, read: reader.read); check("5 a one-page file is refused", false) }
                catch { check("5 a one-page file is refused", { if case ReOCRJob.Failure.notEligible = error { return true }; return false }(), "\(error)") }
                check("5 nothing was kept or read", reader.calls.isEmpty
                      && !FileManager.default.fileExists(atPath: j.writer.versionsRoot.path))
            }

            // 6. Changed between run and accept.
            do {
                let d = try folder("changed"), f = try file(d, pairs: 1), j = job(d), reader = FakeReader()
                let review = try await j.start(file: f, root: archive(d), model: model, read: reader.read)
                let h = try FileHandle(forWritingTo: f); try h.seekToEnd(); try h.write(contentsOf: Data("\n%e\n".utf8)); try h.close()
                let edited = try Data(contentsOf: f)
                do { _ = try j.accept(review); check("6 a changed file is refused at accept", false) }
                catch { check("6 a changed file is refused at accept", (error as? ReOCRFileWriter.Failure) == .targetChanged, "\(error)") }
                check("6 the edit stays", (try? Data(contentsOf: f)) == edited)
            }

            // 6b. A failure after prepare records the operation rejected rather than leaving it pending.
            do {
                let d = try folder("fail-after-prepare"), f = try file(d, pairs: 1), reader = FakeReader()
                let blocker = d.appendingPathComponent("not-a-folder")
                try Data("x".utf8).write(to: blocker)
                let j = ReOCRJob(writer: ReOCRFileWriter(versionsRoot: d.appendingPathComponent("Versions", isDirectory: true)),
                                 scratch: blocker.appendingPathComponent("scratch", isDirectory: true), support: support(d))
                do { _ = try await j.start(file: f, root: archive(d), model: model, read: reader.read); check("6b a failure after prepare throws", false) }
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

            // 8. After publication: the receipt, and the reviewed flag cleared, other tags kept.
            do {
                let d = try folder("flag-cleared"), f = try file(d, pairs: 1), j = job(d), reader = FakeReader()
                try tag(f, ["Q2", "OCR Poor", "1952"])
                let k = try ImproveOCRFlagStore.FileKey(rootGUID: rootGUID, root: d, file: f)
                // The Reader's flag action, recorded as the protocol says.
                let flaggedGen = try j.flags.withLock(k, app: "Reader") { l in
                    try l.commit(l.begin(flagged: true, origin: .flag), observedFlagged: true).generation
                }
                let review = try await j.start(file: f, root: archive(d), model: model, read: reader.read)
                check("8 the review saw the Reader's generation", review.reviewedGeneration == flaggedGen && review.flaggedAtReview)
                let done = try j.accept(review)
                check("8 the flag is cleared", done.flag == .cleared, "\(done.flag)")
                check("8 the other tags stay", multisetEqual(tags(f), ["Q2", "1952"]), "\(tags(f))")
                let st = try j.flags.withLock(k, app: "Reader") { try $0.state() }
                check("8 the clear is a new generation, recorded unflagged", st.generation != flaggedGen && st.flagged == false)
                let receipt = try? ImproveOCRReceipt.read(ImproveOCRReceipt.url(for: done.journal.operationID, in: j.support))
                check("8 the receipt names the file and both digests", done.receiptProblem == nil && receipt?.relativePath == "Letter.pdf"
                      && receipt?.beforeSHA256 == done.journal.original.sha256 && receipt?.afterSHA256 == done.journal.candidateSHA256
                      && receipt?.textPages == [1] && receipt?.outcome == .published, "\(String(describing: receipt))")
                check("8 a retry of its own finished clear reports it cleared", j.clearFlag(review, done.journal) == .cleared)
            }
            do {
                let d = try folder("flag-again"), f = try file(d, pairs: 1), j = job(d), reader = FakeReader()
                try tag(f, ["OCR Poor"])
                let k = try ImproveOCRFlagStore.FileKey(rootGUID: rootGUID, root: d, file: f)
                let review = try await j.start(file: f, root: archive(d), model: model, read: reader.read)
                // The person flags it again while the re-read runs.
                _ = try j.flags.withLock(k, app: "Reader") { l in try l.commit(l.begin(flagged: true, origin: .flag), observedFlagged: true) }
                let done = try j.accept(review)
                check("8 a flag set again during the read is left", { if case .changedSinceReview = done.flag { return true }; return false }()
                      && tags(f) == ["OCR Poor"], "\(done.flag) \(tags(f))")
                check("8 the text is accepted all the same", text(f, 1).contains("New reading of image page 1."))
            }
            do {
                let d = try folder("finder-flag"), f = try file(d, pairs: 1), j = job(d), reader = FakeReader()
                let review = try await j.start(file: f, root: archive(d), model: model, read: reader.read)
                try tag(f, ["OCR Poor"])   // flagged in Finder while it is read: no suite event
                let done = try j.accept(review)
                check("8 a flag set outside the suite during the read is left", { if case .changedSinceReview = done.flag { return true }; return false }()
                      && tags(f) == ["OCR Poor"], "\(done.flag) \(tags(f))")
            }
            do {
                let d = try folder("resume-clear"), f = try file(d, pairs: 1), j = job(d), reader = FakeReader()
                try tag(f, ["OCR Poor", "Q1"])
                let review = try await j.start(file: f, root: archive(d), model: model, read: reader.read)
                // Published, then the Processor died just after beginning its clear.
                let journal = try j.writer.accept(review.operation, candidate: review.candidate ?? Data())
                _ = try j.flags.withLock(review.key, app: "Processor") {
                    try $0.begin(flagged: false, origin: .acceptedClear, operationID: journal.operationID)
                }
                let outcome = j.clearFlag(review, journal)
                check("8 an interrupted clear of its own is resumed", outcome == .cleared && tags(f) == ["Q1"], "\(outcome) \(tags(f))")
                let st = try j.flags.withLock(review.key, app: "Reader") { try $0.state() }
                check("8 and leaves no barrier", !st.isPending && st.flagged == false)
            }
            do {
                let d = try folder("unflagged"), f = try file(d, pairs: 1), j = job(d), reader = FakeReader()
                let done = try j.accept(try await j.start(file: f, root: archive(d), model: model, read: reader.read))
                check("8 an unflagged file has nothing to clear", done.flag == .notFlagged && done.receiptProblem == nil, "\(done.flag)")
            }
            do {
                let d = try folder("pending"), f = try file(d, pairs: 1), j = job(d), reader = FakeReader()
                try tag(f, ["OCR Poor"])
                let k = try ImproveOCRFlagStore.FileKey(rootGUID: rootGUID, root: d, file: f)
                let review = try await j.start(file: f, root: archive(d), model: model, read: reader.read)
                _ = try j.flags.withLock(k, app: "Reader") { try $0.begin(flagged: false, origin: .unflag) }   // dies mid-action
                let done = try j.accept(review)
                check("8 an unfinished action elsewhere leaves the flag", { if case .changedSinceReview = done.flag { return true }; return false }()
                      && tags(f) == ["OCR Poor"], "\(done.flag)")
            }
            do {
                let d = try folder("outside-root"), f = try file(d, pairs: 1), reader = FakeReader()
                let other = try folder("other-root")
                do { _ = try await job(d).start(file: f, root: archive(other), model: model, read: reader.read); check("8 a file outside its root is refused", false) }
                catch { check("8 a file outside its root is refused", (error as? ImproveOCRFlagStore.StoreError) == .notInRoot && reader.calls.isEmpty, "\(error)") }
            }

            // 9. Launch recovery finishes a publication a crash cut short: the receipt and the flag.
            do {
                let d = try folder("recover"), f = try file(d, pairs: 1), j = job(d), reader = FakeReader()
                try tag(f, ["OCR Poor", "Q3"])
                let review = try await j.start(file: f, root: archive(d), model: model, read: reader.read)
                _ = try? j.writer.accept(review.operation, candidate: review.candidate ?? Data(),
                                         faults: { if $0 == .afterSwap { throw ReOCRFileWriter.InjectedCrash() } })
                let id = review.operation.journal.operationID
                check("9 the crash left no receipt", !FileManager.default.fileExists(atPath: ImproveOCRReceipt.url(for: id, in: j.support).path))
                let r = j.recover()
                check("9 recovery publishes, writes the receipt and clears the flag",
                      r.count == 1 && r[0].writer == .published(id) && r[0].receiptProblem == nil && r[0].flag == .cleared, "\(r)")
                check("9 the tags are right after recovery", tags(f) == ["Q3"], "\(tags(f))")
                check("9 the receipt is there", (try? ImproveOCRReceipt.read(ImproveOCRReceipt.url(for: id, in: j.support)))?.afterSHA256
                      == (try? j.writer.read(id))?.candidateSHA256)
                let again = j.recover()
                check("9 a second recovery changes nothing", again.count == 1 && again[0].writer == .alreadyPublished(id)
                      && again[0].flag == .cleared && tags(f) == ["Q3"], "\(again)")
                let record = try? j.writer.readRecord(ReOCRJob.Record.self, named: ReOCRJob.Record.file, for: id)
                check("9 the job's record is settled", record?.receiptWritten == true && record?.flag == .cleared)
                // Put back in Finder after the clear; a record that lost its outcome must not clear it again.
                try tag(f, ["Q3", "OCR Poor"])
                if var unsettled = record {
                    unsettled.flag = nil
                    try j.writer.writeRecord(unsettled, named: ReOCRJob.Record.file, for: id)
                }
                let third = j.recover()
                check("9 a flag put back after the clear is not cleared again",
                      { if case .changedSinceReview = third.first?.flag { return true }; return false }() && tags(f).contains("OCR Poor"),
                      "\(third) \(tags(f))")
                check("9 the journal cannot be overwritten as a record",
                      (try? j.writer.writeRecord(["x": 1], named: "journal.json", for: id)) == nil)
            }

            // 10. Restore.
            do {
                let d = try folder("restore"), f = try file(d, pairs: 1), j = job(d), reader = FakeReader()
                try tag(f, ["OCR Poor", "Q2"])
                let original = try Data(contentsOf: f)
                let done = try j.accept(try await j.start(file: f, root: archive(d), model: model, read: reader.read))
                let accepted = try Data(contentsOf: f)
                try tag(f, ["Q2", "Added after"])   // an unrelated edit after acceptance
                let r = try j.restore(done.journal.operationID)
                check("10 restore puts the original bytes back", (try? Data(contentsOf: f)) == original)
                check("10 it keeps later tag edits and puts the flag back",
                      multisetEqual(tags(f), ["Q2", "Added after", "OCR Poor"]) && r.flag == .reflagged, "\(r.flag) \(tags(f))")
                check("10 the accepted revision is kept", (try? Data(contentsOf: j.writer.backupURL(r.journal.operationID))) == accepted)
                let receipt = try? ImproveOCRReceipt.read(ImproveOCRReceipt.url(for: r.journal.operationID, in: j.support))
                check("10 a restore receipt is written", r.receiptProblem == nil && receipt?.outcome == .restored
                      && receipt?.afterSHA256 == done.journal.original.sha256)
                let rec = j.recover()
                check("10 recovery after a restore changes nothing", multisetEqual(tags(f), ["Q2", "Added after", "OCR Poor"])
                      && rec.allSatisfy { $0.receiptProblem == nil }, "\(rec) \(tags(f))")
                do { _ = try j.restore(r.journal.operationID); check("10 a restore cannot itself be restored", false) }
                catch { check("10 a restore cannot itself be restored", (try? Data(contentsOf: f)) == original) }
                do { _ = try j.restore(done.journal.operationID); check("10 a second restore is refused", false) }
                catch { check("10 a second restore is refused", { if case ReOCRJob.Failure.notRestorable = error { return true }; return false }()) }
            }
            do {
                let d = try folder("restore-changed"), f = try file(d, pairs: 1), j = job(d), reader = FakeReader()
                let done = try j.accept(try await j.start(file: f, root: archive(d), model: model, read: reader.read))
                let h = try FileHandle(forWritingTo: f); try h.seekToEnd(); try h.write(contentsOf: Data("\n%e\n".utf8)); try h.close()
                let edited = try Data(contentsOf: f)
                do { _ = try j.restore(done.journal.operationID); check("10 restore of a changed file is refused", false) }
                catch { check("10 restore of a changed file is refused", (try? Data(contentsOf: f)) == edited) }
                let pendingOps = j.recover().filter { if case .notPublished = $0.writer { return true }; return false }
                check("10 a refused restore leaves no operation waiting for review", pendingOps.isEmpty, "\(pendingOps)")
            }
            do {
                let d = try folder("restore-unflagged-later"), f = try file(d, pairs: 1), j = job(d), reader = FakeReader()
                try tag(f, ["OCR Poor"])
                let done = try j.accept(try await j.start(file: f, root: archive(d), model: model, read: reader.read))
                // The person unflags it explicitly in the Reader after acceptance (it was already clear).
                let k = try ImproveOCRFlagStore.FileKey(rootGUID: rootGUID, root: d, file: f)
                _ = try j.flags.withLock(k, app: "Reader") { l in
                    try l.commit(l.begin(flagged: false, origin: .unflag), observedFlagged: false)
                }
                let r = try j.restore(done.journal.operationID)
                check("10 a flag action after the clear means no re-flag",
                      { if case .changedSinceClear = r.flag { return true }; return false }() && !tags(f).contains("OCR Poor"), "\(r.flag)")
            }
            do {
                let d = try folder("restore-never-flagged"), f = try file(d, pairs: 1), j = job(d), reader = FakeReader()
                let done = try j.accept(try await j.start(file: f, root: archive(d), model: model, read: reader.read))
                let r = try j.restore(done.journal.operationID)
                check("10 an original that was not flagged is not flagged", r.flag == .notNeeded && tags(f).isEmpty)
            }

            // 11. The saved connection to the shared support folder.
            do {
                let suite = "ImproveOCR.test.\(UUID().uuidString)"
                guard let defaults = UserDefaults(suiteName: suite) else { check("11 a scratch defaults suite", false); return }
                defer { defaults.removePersistentDomain(forName: suite) }
                let c = ReOCRSupportConnection(defaults: defaults)
                check("11 nothing connected yet", (try? c.resolve()) == nil && { do { _ = try c.resolve(); return false }
                    catch { return (error as? ReOCRSupportConnection.Problem) == .notConnected } }())
                let d = try folder("support-conn")
                let made = try c.connect(d)
                check("11 connecting makes the store's identity", (try? ImproveOCRSupportIdentity.identity(of: d, create: false)) == made.storeID)
                check("11 it resolves to the same store", (try? c.resolve())?.storeID == made.storeID)
                let moved = root.appendingPathComponent("support-conn-moved", isDirectory: true)
                try FileManager.default.moveItem(at: d, to: moved)
                let afterMove = try? c.resolve()
                check("11 a moved folder is followed", afterMove?.storeID == made.storeID
                      && afterMove?.url.standardizedFileURL.lastPathComponent == "support-conn-moved", "\(String(describing: afterMove))")
                try FileManager.default.removeItem(at: moved.appendingPathComponent(ImproveOCRSupportIdentity.file))
                _ = try ImproveOCRSupportIdentity.identity(of: moved, create: true)   // replaced by another store
                do { _ = try c.resolve(); check("11 a different store is refused", false) }
                catch { check("11 a different store is refused", (error as? ReOCRSupportConnection.Problem) == .differentStore, "\(error)") }
                c.disconnect()
                check("11 disconnecting forgets it", { do { _ = try c.resolve(); return false }
                    catch { return (error as? ReOCRSupportConnection.Problem) == .notConnected } }())
            }

            // 12. A real reader on this Mac ($0, no network): Apple Vision through the row factory, end to end.
            do {
                let d = try folder("vision"), j = job(d)
                let img = d.appendingPathComponent("typed.jpg"), pdf = d.appendingPathComponent("Letter.pdf")
                try typedPage(img, "IMPROVED READING OF THE LETTER 1952")
                try PDFGenerator().generate(imageURL: img, result: OCRResult(text: "garbled old text", classification: nil,
                                            errorMessage: nil, errorCode: nil), model: model, outputURL: pdf,
                                            originalFileName: "typed.jpg", pageKind: .typewritten)
                let vision = LLMModel.appleVisionModels[0]
                let row = ReOCRRanking.Row(id: "vision", name: vision.displayName, appRoute: nil, provider: .appleVision,
                                           modelID: vision.id, figure: nil, sample: nil, caveats: [], usdPer1000: 0,
                                           estimateUSD: 0, readiness: .ready, tie: .notMeasured, isCurrent: false)
                guard let read = ReOCRJob.reader(for: row, apiKey: "") else { check("12 the Vision row has a reader", false); return }
                let review = try await j.start(file: pdf, root: archive(d), model: vision, read: read)
                let newText = (try? review.results.first?.outcome.get()) ?? ""
                check("12 Vision reads the image page", newText.uppercased().contains("IMPROVED READING"), newText)
                check("12 a candidate is made", review.candidate != nil, review.candidateProblem ?? "")
                _ = try j.accept(review)
                let header = PDFDocument(url: pdf)?.page(at: 1).flatMap { PDFHeaderParser.parse($0).header }
                check("12 the header names Vision as the reader", header?.provenance?.model == vision.displayName,
                      "\(String(describing: header?.provenance))")
                var notReady = row
                notReady = ReOCRRanking.Row(id: row.id, name: row.name, appRoute: "gemini|x", provider: .gemini, modelID: "x",
                                            figure: nil, sample: nil, caveats: [], usdPer1000: nil, estimateUSD: nil,
                                            readiness: .needsSetup("needs a Gemini key"), tie: .notMeasured, isCurrent: false)
                check("12 a row that needs setup has no reader", ReOCRJob.reader(for: notReady, apiKey: "k") == nil)
            }

            // 13. The dialog's model: groups by Kind, a Kind change re-ranks, the estimate, Run's blocker, the run.
            do {
                guard let table = SettingsRouteTable.bundled else { check("13 the bundled route table loads", false); return }
                let d = try folder("dialog"), reader = FakeReader()
                let typed = try file(d, pairs: 1)
                let unknown = d.appendingPathComponent("Unknown.pdf")
                let img = d.appendingPathComponent("u.jpg"); try jpeg(img, seed: 9)
                try PDFGenerator().generate(imageURL: img, result: OCRResult(text: "old", classification: nil, errorMessage: nil,
                                            errorCode: nil), model: model, outputURL: unknown, originalFileName: "u.jpg")
                let raw = d.appendingPathComponent("raw.pdf")
                let one = PDFDocument(); one.insert(PDFPage(), at: 0); try one.dataRepresentation()?.write(to: raw)
                var res = SettingsResources(macMemoryGB: 16)
                res.keys = ["gemini", "openai", "anthropic", "mistral", "openrouter"]
                let m = ReOCRDialogModel(files: [typed, unknown, raw], table: table, pairs: OCRPairMatrix.bundled,
                                         resources: res, staysOnMac: false)
                check("13 every file is listed, the raw one refused", m.files.count == 3
                      && { if case .failure = m.files[2].eligibility { return true }; return false }())
                check("13 the header's Kind is used, the unknown page waits", m.groups.map(\.kind) == [.typewritten, nil], "\(m.groups.map(\.kind))")
                check("13 Run waits for a Kind", m.runBlocker?.contains("Kind") == true, m.runBlocker ?? "")
                m.setKind(.handwritten, file: unknown.path)
                check("13 choosing a Kind re-groups", m.groups.map(\.kind) == [.handwritten, .typewritten] || m.groups.map(\.kind) == [.typewritten, .handwritten],
                      "\(m.groups.map(\.kind))")
                let hand = m.groups.first { $0.kind == .handwritten }
                let direct = ReOCRRanking.rank(kind: .handwritten, pages: 1, table: table, pairs: OCRPairMatrix.bundled,
                                               resources: res, staysOnMac: false)
                check("13 and re-ranks for the new Kind", hand?.ranking?.kind == .handwritten
                      && hand?.ranking?.rows.map(\.id) == direct.rows.map(\.id) && !(direct.rows.isEmpty))
                m.setKind(.forms, file: unknown.path)
                let forms = ReOCRRanking.rank(kind: .forms, pages: 1, table: table, pairs: OCRPairMatrix.bundled,
                                              resources: res, staysOnMac: false)
                check("13 a second change re-ranks again", m.groups.first { $0.kind == .forms }?.ranking?.rows.map(\.id) == forms.rows.map(\.id))
                let est = m.estimate
                check("13 the estimate is a sum or says what is unpriced", est.usd >= 0 && est.unpricedPages >= 0)
                lines.append("INFO 13 estimate: $\(est.usd), \(est.unpricedPages) unpriced; blocker: \(m.runBlocker ?? "none")")
                if m.runBlocker == nil {
                    let j = job(d)
                    let runs = await m.run(job: j, root: archive(d), model: model, readerFor: { _ in reader.read })
                    check("13 Run reads the two eligible files", runs.count == 2 && runs.allSatisfy { (try? $0.outcome.get())?.candidate != nil },
                          "\(runs.map { $0.error ?? "\($0.outcome)" })")
                    check("13 each page reaches its reader with its Kind", Set(reader.calls.compactMap(\.kind)) == [.typewritten, .forms])
                    if let r = runs.first(where: { $0.fileID == unknown.path }), let review = try? r.outcome.get(),
                       let row = m.groups.first(where: { $0.kind == .forms }).flatMap({ m.chosenRow($0) }) {
                        _ = try j.accept(review)
                        let h = PDFDocument(url: unknown)?.page(at: 1).flatMap { PDFHeaderParser.parse($0).header }
                        check("13 the new header names the chosen row's model and the Kind",
                              h?.kind == .forms && h?.provenance?.model == row.provider.models.first { $0.id == row.modelID }?.displayName,
                              "\(String(describing: h)) \(row.id)")
                    }
                } else {
                    check("13 with every key, a ready reader exists for each Kind", false, m.runBlocker ?? "")
                }
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
                let review = try await job(d).start(file: f, root: archive(d), model: model, read: reader.read)
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
