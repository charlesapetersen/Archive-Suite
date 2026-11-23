import ArchiveCore
import CoreGraphics
import Foundation

/// W42.int-s5 — repairs to what Quartz's PDF/A writer (`kCGPDFContextCreatePDFA`) writes, made before an output is
/// saved. Measured on every output (macOS 27.2):
///
/// 1. It lists one object it never writes as in use at offset 0. A reader repairs such a file by reparsing it. The
///    entry is made free.
/// 2. It compresses the XMP metadata. PDFium, which writes Improve OCR's revision (`ReOCRIncrementalWriter`), rewrites
///    the metadata stream with its compressed bytes and no `/Filter`, so the revision's XMP is unreadable (the
///    preservation check refuses it: "catalog/Metadata: its stream bytes changed"). The XMP is stored unfiltered, which
///    PDF/A-2 allows, and PDFium's rewrite of it is then the same bytes.
///
/// 3. W42.int-s5-searchable: when the output has searchable pages, the XMP also carries every page's header
///    (`PDFHeaderCarrier`), which Quartz's PDF/A writer will not keep from `addDocumentMetadata`.
///
/// Only Quartz's shape is touched: one `xref` table from object 0 with no `/Prev`, the last thing in the file, and a
/// metadata stream with a direct length and only `/FlateDecode`. Anything else, or a result that does not open with the
/// same pages and the same XMP, is returned as it came.
enum ArchivalFinish {
    private struct Entry { var offset: Int; var generation: Int; var inUse: Bool }

    private struct Rewrite {
        let entries: [Entry]
        let bodyEnd: Int
        let metadata: (range: Range<Int>, object: Data, xmp: Data)?
        let trailer: Data

        var prefix: Range<Int> { 0..<(metadata?.range.lowerBound ?? bodyEnd) }
        var suffix: Range<Int> { (metadata?.range.upperBound ?? bodyEnd)..<bodyEnd }

        var crossReferences: Data {
            let xrefStart = prefix.count + (metadata?.object.count ?? 0) + suffix.count
            var text = "xref\n0 \(entries.count)\n"
            for e in entries {
                text += String(format: "%010lld %05d ", Int64(e.offset), e.generation) + (e.inUse ? "n" : "f") + " \n"
            }
            return Data(text.utf8) + trailer + Data("startxref\n\(xrefStart)\n%%EOF\n".utf8)
        }

        func verifies(_ bytes: Data, document: CGPDFDocument, expectedPages: Int, pageHeaders: [String?]?,
                      catalogueIdentity: CataloguePDFIdentity?) -> Bool {
            guard document.numberOfPages == expectedPages,
                  entries.indices.allSatisfy({ i in
                      let entry = entries[i]
                      return !entry.inUse || (bytes.indices.contains(entry.offset)
                          && bytes[entry.offset...].starts(with: Data("\(i) 0 obj".utf8)))
                  }) else { return false }
            if let metadata, ArchivalFinish.metadata(of: document) != metadata.xmp { return false }
            if let pageHeaders, PDFHeaderCarrier.pages(of: document) != pageHeaders.map({ $0 == "" ? nil : $0 }) {
                return false
            }
            if let catalogueIdentity, CataloguePDFIdentity.identity(in: document) != catalogueIdentity { return false }
            return true
        }
    }

    /// The in-memory repair used for small, already in-memory edits.
    static func finished(_ pdf: Data, pageHeaders: [String?]? = nil,
                         catalogueIdentity: CataloguePDFIdentity? = nil) -> Data? {
        let pdf = Data(pdf)   // start index 0, so offsets index it directly
        let fallback = pageHeaders == nil && catalogueIdentity == nil ? pdf : nil
        guard let before = document(pdf), let rewrite = rewrite(pdf, document: before, pageHeaders: pageHeaders,
                                                               catalogueIdentity: catalogueIdentity) else { return fallback }
        var out = Data(pdf[rewrite.prefix])
        if let metadata = rewrite.metadata { out.append(metadata.object) }
        out.append(pdf[rewrite.suffix])
        out.append(rewrite.crossReferences)
        guard let after = document(out), rewrite.verifies(out, document: after, expectedPages: before.numberOfPages,
                                                           pageHeaders: pageHeaders, catalogueIdentity: catalogueIdentity)
        else { return fallback }
        return out
    }

    /// Repairs a closed Quartz PDF in private scratch space. The memory maps are only used for the xref and object
    /// headers. Copy the body with bounded reads so touching its image streams does not fault in the entire map.
    /// The raw Quartz output is acceptable only if neither of the caller's metadata fields is required.
    static func finishFile(_ raw: URL, rewritten: URL, expectedPages: Int, pageHeaders: [String?]?,
                           catalogueIdentity: CataloguePDFIdentity?) throws -> URL {
        let pdf = try Data(contentsOf: raw, options: .alwaysMapped)
        guard String(decoding: pdf.suffix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix("%%EOF"),
              let before = CGPDFDocument(raw as CFURL), before.numberOfPages == expectedPages else {
            throw PDFError.writeFailed
        }
        if let rewrite = rewrite(pdf, document: before, pageHeaders: pageHeaders, catalogueIdentity: catalogueIdentity) {
            guard FileManager.default.createFile(atPath: rewritten.path, contents: nil) else { throw PDFError.writeFailed }
            try copy(rewrite, from: raw, to: rewritten)
            let bytes = try Data(contentsOf: rewritten, options: .alwaysMapped)
            if let after = CGPDFDocument(rewritten as CFURL),
               rewrite.verifies(bytes, document: after, expectedPages: expectedPages, pageHeaders: pageHeaders,
                                catalogueIdentity: catalogueIdentity) {
                return rewritten
            }
        }
        guard pageHeaders == nil, catalogueIdentity == nil else { throw PDFError.writeFailed }
        return raw
    }

    private static func copy(_ rewrite: Rewrite, from raw: URL, to rewritten: URL) throws {
        let input = try FileHandle(forReadingFrom: raw)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: rewritten)
        defer { try? output.close() }
        func copyRange(_ range: Range<Int>) throws {
            try input.seek(toOffset: UInt64(range.lowerBound))
            var remaining = range.count
            while remaining > 0 {
                try Task.checkCancellation()
                let copied = try autoreleasepool {
                    guard let chunk = try input.read(upToCount: min(remaining, 1_048_576)), !chunk.isEmpty else {
                        throw PDFError.writeFailed
                    }
                    try output.write(contentsOf: chunk)
                    return chunk.count
                }
                remaining -= copied
            }
        }
        try copyRange(rewrite.prefix)
        if let metadata = rewrite.metadata { try output.write(contentsOf: metadata.object) }
        try copyRange(rewrite.suffix)
        try output.write(contentsOf: rewrite.crossReferences)
        try output.close()
    }

    private static func rewrite(_ pdf: Data, document: CGPDFDocument, pageHeaders: [String?]?,
                                catalogueIdentity: CataloguePDFIdentity?) -> Rewrite? {
        guard let table = xrefTable(pdf) else { return nil }
        var entries = table.entries
        // Entry 0 points to the first free object, each free entry to the next, and the last to 0.
        let unwritten = entries.indices.dropFirst().filter { entries[$0].inUse && entries[$0].offset == 0 }
        if let first = unwritten.first {
            let next = unwritten.dropFirst() + [0]
            entries[0].offset = first
            for (i, offset) in zip(unwritten, next) {
                entries[i] = Entry(offset: offset, generation: 1, inUse: false)
            }
        }
        let plain = unfilteredMetadata(pdf, document: document, table: table, pageHeaders: pageHeaders,
                                       catalogueIdentity: catalogueIdentity)
        if let plain {
            let delta = plain.object.count - plain.range.count
            for i in entries.indices where entries[i].inUse && entries[i].offset > plain.range.lowerBound {
                entries[i].offset += delta
            }
        } else if pageHeaders != nil || catalogueIdentity != nil || unwritten.isEmpty { return nil }
        guard entries.allSatisfy({ (0...9_999_999_999).contains($0.offset) }) else { return nil }
        return Rewrite(entries: entries, bodyEnd: table.start, metadata: plain, trailer: table.trailer)
    }

    /// The file's one xref table: where it starts, its entries and the `trailer` dictionary that follows them.
    private typealias Xref = (start: Int, entries: [Entry], trailer: Data)

    private static func xrefTable(_ pdf: Data) -> Xref? {
        let tail = pdf.suffix(64)
        guard let sx = tail.range(of: Data("startxref".utf8), options: .backwards),
              let start = Int(String(decoding: tail[sx.upperBound...].prefix { $0 != 0x25 }, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)),
              start > 0, start < sx.lowerBound else { return nil }
        let header = Data("xref\n0 ".utf8)
        guard sx.lowerBound - start > header.count, pdf[start...].starts(with: header),
              let nl = pdf[(start + header.count)..<min(sx.lowerBound, start + header.count + 20)].firstIndex(of: 0x0A),
              let count = Int(String(decoding: pdf[(start + header.count)..<nl], as: UTF8.self)), count > 1,
              count <= (sx.lowerBound - nl - 1) / 20 else { return nil }
        var entries: [Entry] = []
        for i in 0..<count {
            let at = nl + 1 + 20 * i
            let s = String(decoding: pdf[at..<(at + 20)], as: UTF8.self)
            let chars = Array(s)
            guard chars.count == 20, chars[10] == " ", chars[16] == " ", chars[17] == "n" || chars[17] == "f",
                  let offset = Int(String(chars[0..<10])), (0..<start).contains(offset),
                  let generation = Int(String(chars[11..<16])), generation >= 0 else { return nil }
            entries.append(Entry(offset: offset, generation: generation, inUse: chars[17] == "n"))
        }
        guard !entries[0].inUse, entries[0].offset == 0,
              entries.dropFirst().allSatisfy({ $0.inUse }) else { return nil }   // Quartz writes no other free entry
        let trailerStart = nl + 1 + 20 * count
        let trailer = pdf[trailerStart..<sx.lowerBound]
        guard trailer.starts(with: Data("trailer".utf8)), trailer.range(of: Data("/Prev".utf8)) == nil else { return nil }
        return (start, entries, Data(trailer))
    }

    /// The catalog's metadata object rewritten unfiltered: the bytes it replaces, the new object and the XMP.
    private static func unfilteredMetadata(_ pdf: Data, document: CGPDFDocument, table: Xref,
                                           pageHeaders: [String?]?, catalogueIdentity: CataloguePDFIdentity?)
        -> (range: Range<Int>, object: Data, xmp: Data)? {
        func bounds(of number: Int) -> Range<Int>? {
            guard table.entries.indices.contains(number), table.entries[number].inUse else { return nil }
            let start = table.entries[number].offset
            guard start > 0, pdf[start...].starts(with: Data("\(number) 0 obj".utf8)) else { return nil }
            let upper = table.entries.lazy.filter { $0.inUse && $0.offset > start }.map(\.offset).min() ?? table.start
            return start..<upper
        }
        guard let quartz = metadata(of: document), !quartz.isEmpty,
              let headerPacket = pageHeaders == nil ? quartz : PDFHeaderCarrier.adding(pages: pageHeaders ?? [], to: quartz),
              let xmp = catalogueIdentity == nil ? headerPacket : catalogueIdentity?.adding(to: headerPacket),
              let root = firstMatch(#"/Root (\d+) 0 R"#, in: table.trailer),
              let rootBounds = bounds(of: root),
              let rootEnd = pdf.range(of: Data("endobj".utf8), in: rootBounds),
              let number = firstMatch(#"/Metadata (\d+) 0 R"#, in: pdf[rootBounds.lowerBound..<rootEnd.lowerBound]),
              let metadataBounds = bounds(of: number),
              let stream = pdf.range(of: Data("stream".utf8), in: metadataBounds) else { return nil }
        let dict = String(decoding: pdf[metadataBounds.lowerBound..<stream.lowerBound], as: UTF8.self)
        guard dict.contains("/Type /Metadata"), dict.contains("/Subtype /XML"), dict.contains("/Filter /FlateDecode"),
              !dict.contains("DecodeParms"), !dict.contains("["),
              firstMatch(#"/Length (\d+) 0 R"#, in: Data(dict.utf8)) == nil,
              let length = firstMatch(#"/Length (\d+)"#, in: Data(dict.utf8)) else { return nil }

        // Stream data may contain delimiters. Skip its direct length before reading the closing tokens.
        var dataStart = stream.upperBound
        guard dataStart < metadataBounds.upperBound, pdf[dataStart] == 0x0D || pdf[dataStart] == 0x0A else { return nil }
        if pdf[dataStart] == 0x0D { dataStart += 1 }
        if dataStart < metadataBounds.upperBound, pdf[dataStart] == 0x0A { dataStart += 1 }
        guard length <= metadataBounds.upperBound - dataStart else { return nil }
        let afterData = (dataStart + length)..<metadataBounds.upperBound
        guard let end = pdf.range(of: Data("endstream".utf8), in: afterData),
              let objectEnd = pdf.range(of: Data("endobj".utf8), in: end.upperBound..<metadataBounds.upperBound)
        else { return nil }
        var upper = objectEnd.upperBound
        while upper < metadataBounds.upperBound, pdf[upper] == 0x0D || pdf[upper] == 0x0A { upper += 1 }
        let range = metadataBounds.lowerBound..<upper
        var object = Data("\(number) 0 obj\n<< /Type /Metadata /Subtype /XML /Length \(xmp.count) >>\nstream\n".utf8)
        object.append(xmp)
        object.append(Data("\nendstream\nendobj\n".utf8))
        return (range, object, xmp)
    }

    private static func firstMatch(_ pattern: String, in data: Data) -> Int? {
        let s = String(decoding: data, as: UTF8.self)
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }

    private static func document(_ pdf: Data) -> CGPDFDocument? {
        CGDataProvider(data: pdf as CFData).flatMap(CGPDFDocument.init)
    }

    /// The catalog's XMP, decoded.
    private static func metadata(of doc: CGPDFDocument) -> Data? {
        var stream: CGPDFStreamRef?
        guard let catalog = doc.catalog, CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data?, format == .raw else { return nil }
        return data
    }
}
