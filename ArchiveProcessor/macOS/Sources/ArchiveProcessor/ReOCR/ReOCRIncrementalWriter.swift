import CoreGraphics
import CPDFium
import Foundation
import PDFKit

// MARK: - Improve OCR: the byte-preserving candidate (W44.reocr-processor)

/// Builds an Improve OCR candidate through the pinned static PDFium
/// (`scripts/bootstrap-pdfium.sh`; owner, 2026-11-12). Each replaced text page is imported from a one-page PDF made
/// by `PDFGenerator.textPageData` at its old position, the old page leaves the page tree, and PDFium saves with
/// `FPDF_INCREMENTAL` for table-based files, or a full save for cross-reference stream files.
///
/// Invisible layers are edited on the existing scan page with its page identity, geometry and annotations. The
/// old invisible objects are removed, and the new transparent layer is inserted as a Form XObject.
///
/// What PDFium writes is not trusted on its own (`SPEC/improve-ocr.md` §5): `candidate` always runs
/// `ReOCRPreservationCheck` on the result and checks every replaced page now carries the new text page's content,
/// and returns the bytes only when both hold. It works in memory and writes no file; publication is
/// `ReOCRFileWriter`'s job.
enum ReOCRIncrementalWriter {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case noReplacements
        case originalUnreadable(code: UInt)
        case encrypted
        case signed
        case replacementUnreadable(page: Int)
        case replacementNotOnePage(page: Int)
        case pageOutOfRange(page: Int)
        case importFailed(page: Int)
        case layerEditFailed(page: Int, String)
        case saveFailed
        case notPreserved([String])

        var description: String {
            switch self {
            case .noReplacements: "no page to replace was given"
            case .originalUnreadable(let code): "PDFium cannot open the original (error \(code))"
            case .encrypted: "the original is encrypted"
            case .signed: "the original carries a digital signature"
            case .replacementUnreadable(let p): "the new text for page \(p + 1) does not open as a PDF"
            case .replacementNotOnePage(let p): "the new text for page \(p + 1) is not exactly one page"
            case .pageOutOfRange(let p): "page \(p + 1) is not in the file"
            case .importFailed(let p): "PDFium could not put the new text at page \(p + 1)"
            case .layerEditFailed(let p, let why): "the searchable text on page \(p + 1) could not be replaced: \(why)"
            case .saveFailed: "PDFium could not save the revision"
            case .notPreserved(let problems): "the candidate did not keep the original: " + problems.joined(separator: "; ")
            }
        }
    }

    /// Return a verified candidate whose page `i` (0-based) is the single page of `replacements[i]`.
    static func candidate(original: Data, replacements: [Int: Data]) throws -> Data {
        try candidate(original: original, replacements: replacements, layers: [:]).bytes
    }

    static func candidate(original: Data, replacements: [Int: Data], layers: [Int: ReOCRLayer]) throws
        -> (bytes: Data, layerPages: Set<Int>) {
        guard !replacements.isEmpty || !layers.isEmpty else { throw Failure.noReplacements }
        if isSignedOrCertified(original) { throw Failure.signed }
        let rewrite = endsInCrossReferenceStream(original)
        let flags = rewrite ? FPDF_NO_INCREMENTAL : FPDF_INCREMENTAL
        let revised = try PDFium.serialized { try revise(original, replacements, layers, flags: flags) }
        let layerPages = Set(layers.keys)
        let problems = ReOCRPreservationCheck.problems(original: original, candidate: revised,
                                                       replacing: Set(replacements.keys), editingLayers: layerPages,
                                                       requiresOriginalPrefix: !rewrite)
            + replacedPageProblems(candidate: revised, replacements: replacements)
        guard problems.isEmpty else { throw Failure.notPreserved(problems) }
        try verifyLayerObjects(revised, indexes: layerPages)
        let document = PDFDocument(data: revised)
        for index in layerPages.sorted() {
            guard let actual = document?.page(at: index)?.string, let layer = layers[index],
                  !actual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  OutputForm.holds(actual, every: layer.reading) else {
                throw Failure.layerEditFailed(page: index, "the new reading does not extract from the saved page")
            }
        }
        return (revised, layerPages)
    }

    /// Check before offering a file for OCR, and again when building its candidate.
    static func eligibility(of original: Data) -> Result<Void, Failure> {
        if isSignedOrCertified(original) { return .failure(.signed) }
        return PDFium.serialized {
            original.withUnsafeBytes { raw in
                switch openOriginal(raw) {
                case .success(let doc):
                    FPDF_CloseDocument(doc)
                    return .success(())
                case .failure(let error): return .failure(error)
                }
            }
        }
    }

    /// PDFium's signature enumeration misses fields nested under another form field. Quartz can also see
    /// certification and usage-rights signatures stored in the catalog.
    private static func isSignedOrCertified(_ data: Data) -> Bool {
        guard let doc = ReOCRPreservationCheck.document(data) else { return false }
        defer { withExtendedLifetime(doc) {} }
        guard let catalog = doc.catalog else { return false }
        var perms: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Perms", &perms), let perms {
            for key in ["DocMDP", "UR", "UR3"] {
                var value: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(perms, key, &value) { return true }
            }
        }
        var form: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form else { return false }
        var fields: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(form, "Fields", &fields), let fields else { return false }
        var visited = Set<CGPDFDictionaryRef>()
        var pending = [(fields, false)]
        while let (fields, inheritedSignatureType) = pending.popLast() {
            for index in 0..<CGPDFArrayGetCount(fields) {
                var field: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(fields, index, &field), let field,
                      visited.insert(field).inserted else { continue }
                var type: UnsafePointer<CChar>?
                let signatureType = CGPDFDictionaryGetName(field, "FT", &type)
                    ? type.map { String(cString: $0) == "Sig" } ?? false : inheritedSignatureType
                var value: CGPDFDictionaryRef?
                if signatureType && CGPDFDictionaryGetDictionary(field, "V", &value) { return true }
                var children: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(field, "Kids", &children), let children {
                    pending.append((children, signatureType))
                }
            }
        }
        return false
    }

    /// Whether the file's last cross-reference section is a stream (PDF 1.5) rather than an `xref` table. The pinned
    /// PDFium writes a broken revision after one (its new cross-reference stream has no `endobj`, and Quartz will not
    /// open the result), so use PDFium's full save for those files. The Processor's own output uses tables.
    static func endsInCrossReferenceStream(_ data: Data) -> Bool {
        let tail = data.suffix(1024)
        // No readable pointer: not this question. PDFium then refuses the file or repairs it, and a repaired file's
        // revision still has to pass the preservation check.
        guard let range = tail.range(of: Data("startxref".utf8), options: .backwards) else { return false }
        let digits = tail[range.upperBound...].drop { [0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20].contains($0) }.prefix { (0x30...0x39).contains($0) }
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

    private static func openOriginal(_ raw: UnsafeRawBufferPointer) -> Result<FPDF_DOCUMENT, Failure> {
        guard let doc = FPDF_LoadMemDocument64(raw.baseAddress, raw.count, nil) else {
            let code = FPDF_GetLastError()
            return .failure(code == UInt(FPDF_ERR_PASSWORD) ? .encrypted : .originalUnreadable(code: code))
        }
        if FPDF_GetSecurityHandlerRevision(doc) != -1 {
            FPDF_CloseDocument(doc)
            return .failure(.encrypted)
        }
        // PDFium can count empty signature fields. Require signature data in this check.
        for index in 0..<max(0, FPDF_GetSignatureCount(doc)) {
            guard let signature = FPDF_GetSignatureObject(doc, index) else { continue }
            if FPDFSignatureObj_GetContents(signature, nil, 0) > 0
                || FPDFSignatureObj_GetByteRange(signature, nil, 0) > 0 {
                FPDF_CloseDocument(doc)
                return .failure(.signed)
            }
        }
        return .success(doc)
    }

    private static func revise(_ original: Data, _ replacements: [Int: Data], _ layers: [Int: ReOCRLayer],
                               flags: Int32) throws -> Data {
        try original.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let doc = try openOriginal(raw).get()
            defer { FPDF_CloseDocument(doc) }
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
            for (index, layer) in layers.sorted(by: { $0.key < $1.key }) {
                guard index >= 0, index < count, replacements[index] == nil else { throw Failure.pageOutOfRange(page: index) }
                try editLayer(layer, in: doc, index: index)
            }
            return try PDFium.save(doc, flags: flags)
        }
    }

    private enum PageContent {
        case empty, invisibleText, visible, mixed
    }

    /// Only render-mode 3 is safe to remove. A separate form containing only invisible text is also removable
    /// (compressed Processor output and earlier revisions use such forms). Never modify a shared form in place.
    private static func content(of object: FPDF_PAGEOBJECT, depth: Int = 0) -> PageContent {
        switch FPDFPageObj_GetType(object) {
        case FPDF_PAGEOBJ_TEXT:
            return FPDFTextObj_GetTextRenderMode(object) == FPDF_TEXTRENDERMODE_INVISIBLE ? .invisibleText : .visible
        case FPDF_PAGEOBJ_FORM:
            let count = FPDFFormObj_CountObjects(object)
            guard depth < 32, count >= 0 else { return .mixed }
            var hidden = false
            var visible = false
            for index in 0..<Int(count) {
                guard let child = FPDFFormObj_GetObject(object, UInt(index)) else { return .mixed }
                switch content(of: child, depth: depth + 1) {
                case .empty: break
                case .invisibleText: hidden = true
                case .visible: visible = true
                case .mixed: return .mixed
                }
            }
            if hidden { return visible ? .mixed : .invisibleText }
            return visible ? .visible : .empty
        default:
            return .visible
        }
    }

    /// Inspect actual PDF objects. A hidden run can be present even when PDFKit cannot extract its text.
    static func hiddenTextPages(_ bytes: Data, indexes: [Int]) throws -> Set<Int> {
        try inspectLayers(bytes, indexes: Set(indexes)) { $0.contains { $0.1 == .invisibleText || $0.1 == .mixed } }
    }

    private static func verifyLayerObjects(_ bytes: Data, indexes: Set<Int>) throws {
        let correct = try inspectLayers(bytes, indexes: indexes) { objects in
            let hidden = objects.filter { $0.1 == .invisibleText }
            guard let layer = hidden.first, hidden.count == 1,
                  FPDFPageObj_GetType(layer.0) == FPDF_PAGEOBJ_FORM else { return false }
            return !objects.contains { $0.1 == .mixed }
        }
        if let bad = indexes.subtracting(correct).min() {
            throw Failure.layerEditFailed(page: bad, "the saved page does not have exactly one new invisible layer")
        }
    }

    private static func inspectLayers(_ bytes: Data, indexes: Set<Int>,
                                      matches: ([(FPDF_PAGEOBJECT, PageContent)]) -> Bool) throws -> Set<Int> {
        guard !indexes.isEmpty else { return [] }
        return try PDFium.serialized {
            try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let doc = FPDF_LoadMemDocument64(raw.baseAddress, raw.count, nil) else {
                    let code = FPDF_GetLastError()
                    throw code == UInt(FPDF_ERR_PASSWORD) ? Failure.encrypted : Failure.originalUnreadable(code: code)
                }
                defer { FPDF_CloseDocument(doc) }
                var found = Set<Int>()
                for index in indexes.sorted() {
                    guard let page = FPDF_LoadPage(doc, Int32(index)) else {
                        throw Failure.layerEditFailed(page: index, "the page could not be opened")
                    }
                    defer { FPDF_ClosePage(page) }
                    if try matches(pageObjects(page, index: index)) { found.insert(index) }
                }
                return found
            }
        }
    }

    private static func pageObjects(_ page: FPDF_PAGE, index: Int) throws -> [(FPDF_PAGEOBJECT, PageContent)] {
        let count = FPDFPage_CountObjects(page)
        guard count >= 0 else { throw Failure.layerEditFailed(page: index, "the page contents could not be read") }
        return try (0..<count).map { i in
            guard let object = FPDFPage_GetObject(page, i) else {
                throw Failure.layerEditFailed(page: index, "a page object could not be read")
            }
            return (object, content(of: object))
        }
    }

    private static func editLayer(_ layer: ReOCRLayer, in doc: FPDF_DOCUMENT, index: Int) throws {
        func failure(_ why: String) -> Failure { .layerEditFailed(page: index, why) }
        guard let page = FPDF_LoadPage(doc, Int32(index)) else { throw failure("the original page could not be opened") }
        defer { FPDF_ClosePage(page) }
        let objects = try pageObjects(page, index: index)
        guard !objects.contains(where: { $0.1 == .mixed }) else {
            throw failure("an embedded object mixes hidden text with other page content")
        }
        let hidden = objects.filter { $0.1 == .invisibleText }.map { $0.0 }

        try layer.pdf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let overlay = FPDF_LoadMemDocument64(raw.baseAddress, raw.count, nil) else {
                throw failure("the new layer could not be opened")
            }
            defer { FPDF_CloseDocument(overlay) }
            guard let xObject = FPDF_NewXObjectFromPage(doc, overlay, 0) else { throw failure("the new layer could not be imported") }
            defer { FPDF_CloseXObject(xObject) }
            guard let form = FPDF_NewFormObjectFromXObject(xObject) else { throw failure("the new layer could not be made") }
            guard content(of: form) == .invisibleText else {
                FPDFPageObj_Destroy(form)
                throw failure("the imported layer is not entirely invisible text")
            }
            FPDFPage_InsertObject(page, form)
            let t = layer.intoPage
            FPDFPageObj_Transform(form, t.a, t.b, t.c, t.d, t.tx, t.ty)
            for object in hidden {
                guard FPDFPage_RemoveObject(page, object) != 0 else { throw failure("the old layer could not be removed") }
                FPDFPageObj_Destroy(object)
            }
            guard FPDFPage_GenerateContent(page) != 0 else { throw failure("the updated page could not be saved") }
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
