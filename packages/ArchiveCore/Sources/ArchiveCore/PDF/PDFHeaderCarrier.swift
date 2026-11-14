import CoreGraphics
import Foundation

/// W42.int-s5-searchable — where a page's metadata header lives when the page has no text page: the searchable form,
/// one page per source page (`SPEC/tag-format.md` §"The searchable form"). The document's XMP carries one entry per
/// physical page, in page order: a searchable page's header, written exactly as a text page's header block (the
/// `Extracted text.` sentinel to its last field, LF-separated, no blank separator), or an empty entry for a page of
/// an image-plus-text pair, whose header stays on its own text page. A file with no such list is read as pairs.
/// XMP and not the Info dictionary: PDF/A-2 requires every Info entry to match an XMP property anyway, the list is
/// per page, and PDFium's Improve OCR revisions keep the XMP stream byte for byte.
public enum PDFHeaderCarrier {
    public static let namespace = "https://github.com/charlesapetersen/Archive-Suite/ns/pdf/1.0/"
    public static let prefix = "archivesuite"
    public static let property = "pageHeaders"

    /// One XMP `rdf:Description` holding `pages` (one entry per physical page; nil for a page of a pair), and the
    /// PDF/A extension schema that declares the property (PDF/A-2 6.6.2.3.3), to go inside the packet's `rdf:RDF`.
    public static func xmpDescriptions(pages: [String?]) -> String {
        let items = pages.map { "<rdf:li>\(escaped($0 ?? ""))</rdf:li>" }.joined()
        return """
        <rdf:Description rdf:about="" xmlns:\(prefix)="\(namespace)">\
        <\(prefix):\(property)><rdf:Seq>\(items)</rdf:Seq></\(prefix):\(property)></rdf:Description>\
        <rdf:Description rdf:about="" xmlns:pdfaExtension="http://www.aiim.org/pdfa/ns/extension/" \
        xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#" xmlns:pdfaProperty="http://www.aiim.org/pdfa/ns/property#">\
        <pdfaExtension:schemas><rdf:Bag><rdf:li rdf:parseType="Resource">\
        <pdfaSchema:schema>Archive Suite page headers</pdfaSchema:schema>\
        <pdfaSchema:namespaceURI>\(namespace)</pdfaSchema:namespaceURI><pdfaSchema:prefix>\(prefix)</pdfaSchema:prefix>\
        <pdfaSchema:property><rdf:Seq><rdf:li rdf:parseType="Resource">\
        <pdfaProperty:name>\(property)</pdfaProperty:name><pdfaProperty:valueType>Seq Text</pdfaProperty:valueType>\
        <pdfaProperty:category>external</pdfaProperty:category>\
        <pdfaProperty:description>Each page's metadata header, in page order; empty for a page of an image and text \
        pair</pdfaProperty:description></rdf:li></rdf:Seq></pdfaSchema:property></rdf:li></rdf:Bag>\
        </pdfaExtension:schemas></rdf:Description>
        """
    }

    /// `xmp` with `pages` added inside its `rdf:RDF`; nil when the packet has no `</rdf:RDF>` or already has a list.
    public static func adding(pages: [String?], to xmp: Data) -> Data? {
        let text = String(decoding: xmp, as: UTF8.self)
        guard !text.contains("xmlns:\(prefix)="), let close = text.range(of: "</rdf:RDF>", options: .backwards) else { return nil }
        return Data((text[..<close.lowerBound] + xmpDescriptions(pages: pages) + text[close.lowerBound...]).utf8)
    }

    /// The list in an XMP packet: one entry per physical page, nil for a page of a pair. Nil when the packet has none.
    public static func pages(inXMP xmp: Data) -> [String?]? {
        let reader = Reader()
        let parser = XMLParser(data: xmp)
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        guard parser.parse(), let pages = reader.pages else { return nil }
        return pages.map { $0.isEmpty ? nil : $0 }
    }

    /// The list in `document`'s catalog XMP, or nil.
    public static func pages(of document: CGPDFDocument) -> [String?]? {
        var stream: CGPDFStreamRef?
        guard let catalog = document.catalog, CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream else {
            return nil
        }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data?, format == .raw else { return nil }
        return pages(inXMP: data)
    }

    /// `s` as the list holds it once read back: characters XML cannot hold dropped, CR made LF. A writer stores this,
    /// so what it verifies on read-back is what it wrote.
    public static func storable(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            if scalar == "\r" { out += "\n"; continue }
            if scalar == "\t" || scalar == "\n" { out.unicodeScalars.append(scalar); continue }
            if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// XML 1.0 text: markup escaped, and characters XML cannot hold (C0 controls other than tab and LF) dropped.
    static func escaped(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\t", "\n": out.unicodeScalars.append(scalar)
            case "\r": out += "\n"
            default:
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var pages: [String]?
        private var inList = false
        private var item: String?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if namespaceURI == PDFHeaderCarrier.namespace, name == PDFHeaderCarrier.property, pages == nil {
                inList = true; pages = []
            } else if inList, name == "li" { item = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { item? += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if inList, name == "li", let item { pages?.append(item); self.item = nil }
            else if namespaceURI == PDFHeaderCarrier.namespace, name == PDFHeaderCarrier.property { inList = false }
        }
    }
}
