import CoreGraphics
import Darwin
import Foundation

/// The independent identity in a Suite PDF. Only the companion carries current catalogue fields.
public struct CataloguePDFIdentity: Equatable, Sendable {
    public let fileID: UUID
    public let contentRevision: UUID

    public init(fileID: UUID, contentRevision: UUID) {
        self.fileID = fileID
        self.contentRevision = contentRevision
    }

    private static let namespace = "https://github.com/charlesapetersen/Archive-Suite/ns/catalogue/1.0/"
    private static let rdfNamespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private static let extensionNamespace = "http://www.aiim.org/pdfa/ns/extension/"
    private static let property = "identity"

    /// Extends a UTF-8 packet during PDF creation, preserving the existing packet and its page headers.
    /// The Archive Suite writers emit the standard RDF prefix. Refuse unknown packet shapes and existing IDs.
    public func adding(to packet: Data) -> Data? {
        guard var text = String(data: packet, encoding: .utf8),
              let existing = Self.parse(packet), existing.count == 0 else { return nil }
        var description = """
        <rdf:Description rdf:about="" xmlns:ascat="\(Self.namespace)">\
        <ascat:identity>\(fileID.uuidString) \(contentRevision.uuidString)</ascat:identity></rdf:Description>
        """
        let schema = """
        <rdf:li rdf:parseType="Resource">\
        <pdfaSchema:schema>Archive Suite catalogue identity</pdfaSchema:schema>\
        <pdfaSchema:namespaceURI>\(Self.namespace)</pdfaSchema:namespaceURI><pdfaSchema:prefix>ascat</pdfaSchema:prefix>\
        <pdfaSchema:property><rdf:Seq><rdf:li rdf:parseType="Resource">\
        <pdfaProperty:name>identity</pdfaProperty:name><pdfaProperty:valueType>Text</pdfaProperty:valueType>\
        <pdfaProperty:category>external</pdfaProperty:category>\
        <pdfaProperty:description>Suite file and content generation UUIDs</pdfaProperty:description>\
        </rdf:li></rdf:Seq></pdfaSchema:property></rdf:li>
        """
        if existing.schemaCount == 0 {
            description += """
            <rdf:Description rdf:about="" xmlns:pdfaExtension="\(Self.extensionNamespace)" \
            xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#" xmlns:pdfaProperty="http://www.aiim.org/pdfa/ns/property#">\
            <pdfaExtension:schemas><rdf:Bag>\(schema)</rdf:Bag></pdfaExtension:schemas></rdf:Description>
            """
        } else {
            // The existing searchable-page extension uses this bag. XMP permits one schemas property on the PDF.
            let closingBag = "</rdf:Bag></pdfaExtension:schemas>"
            guard existing.schemaCount == 1,
                  let end = text.range(of: closingBag), !text[end.upperBound...].contains(closingBag) else { return nil }
            text.insert(contentsOf: schema, at: end.lowerBound)
        }
        guard let end = text.range(of: "</rdf:RDF>"),
              !text[end.upperBound...].contains("</rdf:RDF>") else { return nil }
        text.insert(contentsOf: description, at: end.lowerBound)
        let candidate = Data(text.utf8)
        guard Self.parse(candidate)?.schemaCount == 1, Self.identity(inXMP: candidate) == self else { return nil }
        return candidate
    }

    /// A packet carrying `old` with this identity in its place: an explicit content operation's new generation of the
    /// same file. Only the identity text changes, so the page headers and the extension schema stay as written. Nil
    /// unless the packet carries exactly `old` once, in the form `adding(to:)` writes, and this is the same file.
    public func replacing(_ old: Self, in packet: Data) -> Data? {
        guard old.fileID == fileID, old.contentRevision != contentRevision,
              Self.identity(inXMP: packet) == old, let text = String(data: packet, encoding: .utf8) else { return nil }
        let written = "\(old.fileID.uuidString) \(old.contentRevision.uuidString)"
        guard let before = [written, written.lowercased()].map({ "<ascat:identity>\($0)</ascat:identity>" })
                .first(where: { text.contains($0) }),
              let range = text.range(of: before), !text[range.upperBound...].contains(before) else { return nil }
        let after = "<ascat:identity>\(fileID.uuidString) \(contentRevision.uuidString)</ascat:identity>"
        let candidate = Data(text.replacingCharacters(in: range, with: after).utf8)
        guard candidate.count == packet.count, Self.parse(candidate)?.schemaCount == Self.parse(packet)?.schemaCount,
              Self.identity(inXMP: candidate) == self else { return nil }
        return candidate
    }

    public static func identity(inXMP packet: Data) -> Self? {
        guard let reader = parse(packet), reader.count == 1, !reader.malformed else { return nil }
        let identifiers = reader.value.split(separator: " ", omittingEmptySubsequences: false)
        guard identifiers.count == 2,
              let fileID = UUID(uuidString: String(identifiers[0])),
              let revision = UUID(uuidString: String(identifiers[1])) else { return nil }
        return Self(fileID: fileID, contentRevision: revision)
    }

    public static func identity(in document: CGPDFDocument) -> Self? {
        var stream: CGPDFStreamRef?
        guard let catalog = document.catalog, CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream else {
            return nil
        }
        var format = CGPDFDataFormat.raw
        guard let packet = CGPDFStreamCopyData(stream, &format), format == .raw else { return nil }
        return identity(inXMP: packet as Data)
    }

    /// True only when the PDF at `url` opens without a download (an encrypted one with the empty password), has
    /// pages, and its catalog's metadata, if any, is XMP with no catalogue identity element at all
    /// (W49.storage-notes-zotero). A PDF this cannot read is not proven to predate the catalogue.
    public static func provablyAbsent(at url: URL) -> Bool {
        CorpusWalker.withDatalessMaterializationDisabled {
            guard let document = CGPDFDocument(url as CFURL),
                  !document.isEncrypted || document.isUnlocked || document.unlockWithPassword(""),
                  document.numberOfPages > 0, let catalog = document.catalog else { return false }
            var object: CGPDFObjectRef?
            guard CGPDFDictionaryGetObject(catalog, "Metadata", &object) else { return true }
            var stream: CGPDFStreamRef?
            var format = CGPDFDataFormat.raw
            guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream,
                  let packet = CGPDFStreamCopyData(stream, &format), format == .raw,
                  let reader = parse(packet as Data) else { return false }
            return reader.count == 0
        }
    }

    /// Reads from the already opened, verified file. Core Graphics reads at offsets, leaving its owner's position
    /// unchanged and avoiding a full in-memory copy of a multi-page scan.
    public static func identify(_ descriptor: Int32, at _: CatalogueAssociation.Occurrence) -> CatalogueReader.PDFIdentity? {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0 else { return nil }
        return withUnsafePointer(to: descriptor) { context in
            var callbacks = CGDataProviderDirectCallbacks(
                version: 0, getBytePointer: nil, releaseBytePointer: nil,
                getBytesAtPosition: { context, buffer, position, count in
                    guard let context else { return 0 }
                    let fd = context.load(as: Int32.self)
                    var received = 0
                    while received < count {
                        let read = pread(fd, buffer.advanced(by: received), count - received, position + off_t(received))
                        if read < 0 && errno == EINTR { continue }
                        guard read > 0 else { break }
                        received += read
                    }
                    return received
                }, releaseInfo: nil
            )
            guard let provider = CGDataProvider(directInfo: UnsafeMutableRawPointer(mutating: context),
                                                size: info.st_size, callbacks: &callbacks),
                  let document = CGPDFDocument(provider), !document.isEncrypted,
                  document.numberOfPages > 0, let identity = identity(in: document) else { return nil }
            return CatalogueReader.PDFIdentity(fileID: identity.fileID, contentRevision: identity.contentRevision,
                                              pageCount: document.numberOfPages)
        }
    }

    private static func parse(_ packet: Data) -> PacketReader? {
        guard packet.count <= 16 * 1024 * 1024 else { return nil }
        let reader = PacketReader()
        let parser = XMLParser(data: packet)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        return parser.parse() ? reader : nil
    }

    private final class PacketReader: NSObject, XMLParserDelegate {
        var count = 0
        var schemaCount = 0
        var malformed = false
        var value = ""
        private var depth = 0
        private var rdfDepth: Int?
        private var descriptionDepth: Int?
        private var valueDepth: Int?
        private var namespaces: [String: [String]] = [:]

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
            namespaces[prefix, default: []].append(namespaceURI)
        }

        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
            _ = namespaces[prefix]?.popLast()
        }

        private func hasName(_ attribute: String, _ name: String, in namespace: String) -> Bool {
            guard let colon = attribute.firstIndex(of: ":"), attribute[attribute.index(after: colon)...] == name else {
                return false
            }
            return namespaces[String(attribute[..<colon])]?.last == namespace
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            depth += 1
            if valueDepth != nil { malformed = true }
            if namespaceURI == extensionNamespace, name == "schemas" { schemaCount += 1 }
            if attributes.keys.contains(where: { hasName($0, property, in: namespace) }) {
                count += 1
                malformed = true
            }
            if namespaceURI == rdfNamespace, name == "RDF" { rdfDepth = depth }
            if namespaceURI == rdfNamespace, name == "Description", rdfDepth == depth - 1,
               attributes.contains(where: { $0.value.isEmpty && hasName($0.key, "about", in: rdfNamespace) }) {
                descriptionDepth = depth
            }
            if namespaceURI == namespace, name == property {
                count += 1
                guard count == 1, descriptionDepth == depth - 1, attributes.isEmpty else { malformed = true; return }
                valueDepth = depth
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if valueDepth != nil { malformed = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard valueDepth != nil, !malformed else { return }
            if value.utf8.count + string.utf8.count <= 73 { value += string }
            else { malformed = true }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if valueDepth == depth { valueDepth = nil }
            if descriptionDepth == depth { descriptionDepth = nil }
            if rdfDepth == depth { rdfDepth = nil }
            depth -= 1
        }
    }
}
