import CoreGraphics
import Foundation

/// W42.int-s5 — two repairs to what Quartz's PDF/A writer (`kCGPDFContextCreatePDFA`) writes, made before an output is
/// saved (`PDFGenerator.archivalData`). Both measured on every output (macOS 27.2):
///
/// 1. It lists one object it never writes as in use at offset 0. A reader repairs such a file by reparsing it. The
///    entry is made free.
/// 2. It compresses the XMP metadata. PDFium, which writes Improve OCR's revision (`ReOCRIncrementalWriter`), rewrites
///    the metadata stream with its compressed bytes and no `/Filter`, so the revision's XMP is unreadable (the
///    preservation check refuses it: "catalog/Metadata: its stream bytes changed"). The XMP is stored unfiltered, which
///    PDF/A-2 allows, and PDFium's rewrite of it is then the same bytes.
///
/// Only Quartz's shape is touched: one `xref` table from object 0 with no `/Prev`, the last thing in the file, and a
/// metadata stream with a direct length and only `/FlateDecode`. Anything else, or a result that does not open with the
/// same pages and the same XMP, is returned as it came.
enum ArchivalFinish {
    private struct Entry { var offset: Int; var generation: Int; var inUse: Bool }

    static func finished(_ pdf: Data) -> Data {
        let pdf = Data(pdf)   // start index 0, so offsets index it directly
        guard let table = xrefTable(pdf) else { return pdf }
        var entries = table.entries

        // 1. The free list: entry 0 points at the first free object, each free one at the next, the last at 0.
        let unwritten = entries.indices.dropFirst().filter { entries[$0].inUse && entries[$0].offset == 0 }
        if !unwritten.isEmpty {
            let chain = unwritten + [0]
            entries[0].offset = chain[0]
            for (k, i) in unwritten.enumerated() { entries[i] = Entry(offset: chain[k + 1], generation: 1, inUse: false) }
        }

        // 2. The XMP, unfiltered, in place of the compressed stream; every object after it moves by the difference.
        var body = pdf[..<table.start]
        var xmp: Data?
        if let plain = unfilteredMetadata(pdf, entries: entries) {
            body = pdf[..<plain.range.lowerBound] + plain.object + pdf[plain.range.upperBound..<table.start]
            let delta = plain.object.count - plain.range.count
            for i in entries.indices where entries[i].inUse && entries[i].offset > plain.range.lowerBound {
                entries[i].offset += delta
            }
            xmp = plain.xmp
        }
        if unwritten.isEmpty && xmp == nil { return pdf }

        var out = Data(body)
        let xrefStart = out.count
        var text = "xref\n0 \(entries.count)\n"
        for e in entries {
            text += String(format: "%010d %05d ", e.offset, e.generation) + (e.inUse ? "n" : "f") + " \n"
        }
        out.append(Data(text.utf8))
        out.append(table.trailer)
        out.append(Data("startxref\n\(xrefStart)\n%%EOF\n".utf8))

        // The result must open with the same pages and, when it was rewritten, the same XMP; and since a reader quietly
        // reparses a file whose offsets are wrong, every object must also start where the table says.
        guard entries.indices.allSatisfy({ i in !entries[i].inUse
                  || (entries[i].offset < out.count && out[entries[i].offset...].starts(with: Data("\(i) 0 obj".utf8))) }),
              let before = document(pdf), let after = document(out), before.numberOfPages == after.numberOfPages,
              xmp == nil || metadata(of: after) == xmp else { return pdf }
        return out
    }

    /// The file's one xref table: where it starts, its entries and the `trailer` dictionary that follows them.
    private static func xrefTable(_ pdf: Data) -> (start: Int, entries: [Entry], trailer: Data)? {
        let tail = pdf.suffix(64)
        guard let sx = tail.range(of: Data("startxref".utf8), options: .backwards),
              let start = Int(String(decoding: tail[sx.upperBound...].prefix { $0 != 0x25 }, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)),
              start > 0, start < pdf.count else { return nil }
        let header = Data("xref\n0 ".utf8)
        guard pdf[start...].starts(with: header),
              let nl = pdf[(start + header.count)...].firstIndex(of: 0x0A),
              let count = Int(String(decoding: pdf[(start + header.count)..<nl], as: UTF8.self)), count > 1,
              nl + 1 + 20 * count <= pdf.count else { return nil }
        var entries: [Entry] = []
        for i in 0..<count {
            let at = nl + 1 + 20 * i
            let s = String(decoding: pdf[at..<(at + 20)], as: UTF8.self)
            let chars = Array(s)
            guard chars.count == 20, chars[10] == " ", chars[16] == " ", chars[17] == "n" || chars[17] == "f",
                  let offset = Int(String(chars[0..<10])), let generation = Int(String(chars[11..<16])) else { return nil }
            entries.append(Entry(offset: offset, generation: generation, inUse: chars[17] == "n"))
        }
        guard !entries[0].inUse, entries[0].offset == 0,
              entries.dropFirst().allSatisfy({ $0.inUse }) else { return nil }   // Quartz writes no other free entry
        let trailerStart = nl + 1 + 20 * count
        guard let sxInFile = pdf.range(of: Data("startxref".utf8), options: .backwards, in: trailerStart..<pdf.count)
        else { return nil }
        let trailer = pdf[trailerStart..<sxInFile.lowerBound]
        guard trailer.starts(with: Data("trailer".utf8)), trailer.range(of: Data("/Prev".utf8)) == nil else { return nil }
        return (start, entries, Data(trailer))
    }

    /// The catalog's metadata object rewritten unfiltered: the bytes it replaces, the new object and the XMP.
    private static func unfilteredMetadata(_ pdf: Data, entries: [Entry]) -> (range: Range<Int>, object: Data, xmp: Data)? {
        guard let doc = document(pdf), let xmp = metadata(of: doc), !xmp.isEmpty,
              let root = firstMatch(#"/Root (\d+) 0 R"#, in: xrefTable(pdf)?.trailer ?? Data()),
              root < entries.count, entries[root].inUse,
              let rootObject = object(root, at: entries[root].offset, in: pdf),
              let number = firstMatch(#"/Metadata (\d+) 0 R"#, in: pdf[rootObject]),
              number < entries.count, entries[number].inUse,
              let range = object(number, at: entries[number].offset, in: pdf) else { return nil }
        let text = String(decoding: pdf[range], as: UTF8.self)
        guard let dictEnd = text.range(of: ">>")?.lowerBound else { return nil }
        let dict = String(text[..<dictEnd])
        guard dict.contains("/Type /Metadata"), dict.contains("/Subtype /XML"), dict.contains("/Filter /FlateDecode"),
              !dict.contains("DecodeParms"), !dict.contains("["), firstMatch(#"/Length (\d+) 0 R"#, in: Data(dict.utf8)) == nil
        else { return nil }
        var object = Data("\(number) 0 obj\n<< /Type /Metadata /Subtype /XML /Length \(xmp.count) >>\nstream\n".utf8)
        object.append(xmp)
        object.append(Data("\nendstream\nendobj\n".utf8))
        return (range, object, xmp)
    }

    /// The bytes of object `number` at `offset`: from `N 0 obj` through `endobj` and its line end.
    private static func object(_ number: Int, at offset: Int, in pdf: Data) -> Range<Int>? {
        guard offset > 0, offset < pdf.count, pdf[offset...].starts(with: Data("\(number) 0 obj".utf8)) else { return nil }
        // A stream's data may hold any bytes, so step over it by its length rather than search through it.
        var from = offset
        if let s = pdf.range(of: Data("stream".utf8), in: offset..<min(pdf.count, offset + 2048)),
           let e = pdf.range(of: Data("endobj".utf8), in: offset..<min(pdf.count, offset + 2048)),
           s.lowerBound < e.lowerBound,
           let length = firstMatch(#"/Length (\d+)"#, in: pdf[offset..<s.lowerBound]) {
            var data = s.upperBound
            if pdf[data] == 0x0D { data += 1 }
            if pdf[data] == 0x0A { data += 1 }
            from = data + length
        }
        guard from <= pdf.count, let end = pdf.range(of: Data("endobj".utf8), in: from..<pdf.count) else { return nil }
        var upper = end.upperBound
        while upper < pdf.count, pdf[upper] == 0x0D || pdf[upper] == 0x0A { upper += 1 }
        return offset..<upper
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
