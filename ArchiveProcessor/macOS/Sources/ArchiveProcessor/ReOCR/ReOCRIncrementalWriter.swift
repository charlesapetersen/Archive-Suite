import CoreGraphics
import CPDFium
import Foundation

// MARK: - Improve OCR: the byte-preserving candidate (W44.reocr-processor)

/// Builds an Improve OCR candidate as an **incremental revision** of the original, through the pinned static PDFium
/// (`scripts/bootstrap-pdfium.sh`; owner, 2026-11-12). Each replaced text page is imported from a one-page PDF made
/// by `PDFGenerator.textPageData` at its old position, the old page leaves the page tree, and PDFium saves with
/// `FPDF_INCREMENTAL`, which writes the original file first and appends the revision after it.
///
/// What PDFium writes is not trusted on its own (`execution-plans/reocr/00-plan.md` §5): `candidate` always runs
/// `ReOCRPreservationCheck` on the result and checks every replaced page now carries the new text page's content,
/// and returns the bytes only when both hold. It works in memory and writes no file; publication is
/// `ReOCRFileWriter`'s job.
enum ReOCRIncrementalWriter {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case noReplacements
        case originalUnreadable(code: UInt)
        case encrypted
        case signed
        case crossReferenceStream
        case replacementUnreadable(page: Int)
        case replacementNotOnePage(page: Int)
        case pageOutOfRange(page: Int)
        case importFailed(page: Int)
        case saveFailed
        case notPreserved([String])

        var description: String {
            switch self {
            case .noReplacements: "no page to replace was given"
            case .originalUnreadable(let code): "PDFium cannot open the original (error \(code))"
            case .encrypted: "the original is encrypted"
            case .signed: "the original carries a digital signature"
            case .crossReferenceStream: "the original ends in a cross-reference stream, which this writer cannot extend safely"
            case .replacementUnreadable(let p): "the new text for page \(p + 1) does not open as a PDF"
            case .replacementNotOnePage(let p): "the new text for page \(p + 1) is not exactly one page"
            case .pageOutOfRange(let p): "page \(p + 1) is not in the file"
            case .importFailed(let p): "PDFium could not put the new text at page \(p + 1)"
            case .saveFailed: "PDFium could not save the revision"
            case .notPreserved(let problems): "the candidate did not keep the original: " + problems.joined(separator: "; ")
            }
        }
    }

    /// The candidate bytes: `original` byte for byte, then a revision whose page `i` (0-based) is the single page of
    /// `replacements[i]`, every other page unchanged. Throws rather than return a candidate that fails the check.
    static func candidate(original: Data, replacements: [Int: Data]) throws -> Data {
        guard !replacements.isEmpty else { throw Failure.noReplacements }
        if isSignedOrCertified(original) { throw Failure.signed }
        if endsInCrossReferenceStream(original) { throw Failure.crossReferenceStream }
        let bytes = try PDFium.serialized { try revise(original, replacements) }
        let problems = ReOCRPreservationCheck.problems(original: original, candidate: bytes,
                                                       replacing: Set(replacements.keys))
            + replacedPageProblems(candidate: bytes, replacements: replacements)
        guard problems.isEmpty else { throw Failure.notPreserved(problems) }
        return bytes
    }

    /// PDFium counts only signature fields with a value at the top of the form; a certified file (`/Perms`) or one whose
    /// form says it holds signatures (`/SigFlags` bit 1) is refused too, so no revision is ever appended to a signed
    /// document and shown as "modified after signing".
    private static func isSignedOrCertified(_ data: Data) -> Bool {
        // Hold the document: its catalog is borrowed from it and dies with it.
        guard let doc = ReOCRPreservationCheck.document(data) else { return false }
        return withExtendedLifetime(doc) { () -> Bool in
            guard let catalog = doc.catalog else { return false }
        var perms: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Perms", &perms) { return true }
        var form: CGPDFDictionaryRef?
        var flags: CGPDFInteger = 0
        if CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form,
           CGPDFDictionaryGetInteger(form, "SigFlags", &flags), flags & 1 != 0 { return true }
            return false
        }
    }

    /// Whether the file's last cross-reference section is a stream (PDF 1.5) rather than an `xref` table. The pinned
    /// PDFium writes a broken revision after one (its new cross-reference stream has no `endobj`, and Quartz will not
    /// open the result; measured 2026-11-12 on qpdf's object-stream output), so such a file is refused before PDFium
    /// sees it. The Processor's own output is written by Quartz with tables.
    static func endsInCrossReferenceStream(_ data: Data) -> Bool {
        let tail = data.suffix(1024)
        // No readable pointer: not this question. PDFium then refuses the file or repairs it, and a repaired file's
        // revision still has to pass the preservation check.
        guard let range = tail.range(of: Data("startxref".utf8), options: .backwards) else { return false }
        let digits = tail[range.upperBound...].drop { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D }.prefix { (0x30...0x39).contains($0) }
        guard let offset = Int(String(decoding: digits, as: UTF8.self)), offset >= 0, offset < data.count else { return false }
        return !data[(data.startIndex + offset)...].prefix(4).elementsEqual(Data("xref".utf8))
    }

    /// A replaced page must be the new page: the same active graph as the replacement's only page (so the same
    /// content stream, fonts and boxes) and the same pixels.
    private static func replacedPageProblems(candidate: Data, replacements: [Int: Data]) -> [String] {
        guard let doc = ReOCRPreservationCheck.document(candidate) else { return ["the candidate does not open"] }
        var out: [String] = []
        for (index, data) in replacements.sorted(by: { $0.key < $1.key }) {
            guard let src = ReOCRPreservationCheck.document(data), let want = src.page(at: 1),
                  let got = doc.page(at: index + 1) else {
                out.append("page \(index + 1): the new text page cannot be read back")
                continue
            }
            if let diff = ReOCRPreservationCheck.samePage(want, got, path: "new page \(index + 1)") { out.append(diff) }
        }
        return out
    }

    // MARK: PDFium, under one lock

    private static func revise(_ original: Data, _ replacements: [Int: Data]) throws -> Data {
        try original.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> Data in
            guard let doc = FPDF_LoadMemDocument64(raw.baseAddress, raw.count, nil) else {
                let code = FPDF_GetLastError()
                throw code == UInt(FPDF_ERR_PASSWORD) ? Failure.encrypted : Failure.originalUnreadable(code: code)
            }
            defer { FPDF_CloseDocument(doc) }
            if FPDF_GetSecurityHandlerRevision(doc) != -1 { throw Failure.encrypted }
            if FPDF_GetSignatureCount(doc) > 0 { throw Failure.signed }
            let count = Int(FPDF_GetPageCount(doc))
            for (index, data) in replacements.sorted(by: { $0.key < $1.key }) {
                guard index >= 0, index < count else { throw Failure.pageOutOfRange(page: index) }
                try data.withUnsafeBytes { (page: UnsafeRawBufferPointer) throws in
                    guard let src = FPDF_LoadMemDocument64(page.baseAddress, page.count, nil) else {
                        throw Failure.replacementUnreadable(page: index)
                    }
                    defer { FPDF_CloseDocument(src) }
                    guard FPDF_GetPageCount(src) == 1 else { throw Failure.replacementNotOnePage(page: index) }
                    // Import deep-copies the page's objects into `doc`, so `src` may close afterwards.
                    var first: Int32 = 0
                    guard FPDF_ImportPagesByIndex(doc, src, &first, 1, Int32(index)) != 0,
                          Int(FPDF_GetPageCount(doc)) == count + 1 else { throw Failure.importFailed(page: index) }
                    FPDFPage_Delete(doc, Int32(index + 1))
                    guard Int(FPDF_GetPageCount(doc)) == count else { throw Failure.importFailed(page: index) }
                }
            }
            return try PDFium.save(doc, flags: FPDF_INCREMENTAL)
        }
    }
}

/// PDFium is not thread-safe: every call goes through `serialized`, which also initializes the library once.
enum PDFium {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var initialized = false
    /// The bytes `FPDF_SaveAsCopy` hands to the write callback; touched only while `lock` is held.
    nonisolated(unsafe) private static var sink = Data()
    nonisolated(unsafe) private static var sinkFailed = false

    static func serialized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        if !initialized {
            FPDF_InitLibrary()
            initialized = true
        }
        return try body()
    }

    /// Call only inside `serialized`: the sink is shared.
    fileprivate static func save(_ doc: FPDF_DOCUMENT, flags: Int32) throws -> Data {
        sink = Data()
        sinkFailed = false
        defer { sink = Data() }
        var writer = FPDF_FILEWRITE()
        writer.version = 1
        writer.WriteBlock = { _, data, size in
            guard size == 0 || data != nil else { PDFium.sinkFailed = true; return 0 }
            if size > 0, let data { PDFium.sink.append(data.assumingMemoryBound(to: UInt8.self), count: Int(size)) }
            return 1
        }
        guard FPDF_SaveAsCopy(doc, &writer, FPDF_DWORD(flags)) != 0, !sinkFailed else {
            throw ReOCRIncrementalWriter.Failure.saveFailed
        }
        return sink
    }
}
