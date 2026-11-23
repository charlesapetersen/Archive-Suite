import ArchiveCore
import Foundation

/// Initial facts for a new derivative. The durable record is validated by ArchiveCore before filing.
struct ProcessorCatalogueRecord: Encodable, Sendable {
    struct Evidence<Value: Encodable & Sendable>: Encodable, Sendable {
        let source: String
        var route: String?
        var measurementStatus: String?
        var pageID: UUID?
        var quote: String?
        var observedValue: Value?
    }

    struct Field<Value: Encodable & Sendable>: Encodable, Sendable {
        let state: String
        let value: Value?
        let origin: String
        let fieldRevision = UUID()
        var evidence: [Evidence<Value>]?

        init(_ value: Value?, origin: String, evidence: [Evidence<Value>]? = nil) {
            state = value == nil ? "cleared" : "value"
            self.value = value
            self.origin = origin
            self.evidence = evidence
        }
    }

    struct FileFields: Encodable, Sendable {
        var readState: Field<String>?
        var colour: Field<String>?
        var quality: Field<Int>?
        var ocrPoor: Field<Bool>? = nil
        var ocrFailed: Field<Bool>?
    }

    struct DocumentFields: Encodable, Sendable {
        var documentDate: Field<CatalogueRecord.DateValue>?
        var sentWith: Field<CatalogueRecord.DateValue>?
        var publicationDate: Field<CatalogueRecord.DateValue>?
        var documentKind: Field<String>?
        var itemType: Field<String>?
        var title: Field<String>?
        var byline: Field<[String]>?
        var publication: Field<String>?
        var senders: Field<[String]>?
        var recipients: Field<[String]>?
        var sendingPlaces: Field<[String]>?
        var recipientPlaces: Field<[String]>?
        var subjects: Field<[String]>?
    }

    struct DocumentReference: Encodable, Sendable {
        let documentID: UUID
        let ownerFileID: UUID
    }

    struct Document: Encodable, Sendable {
        let id: UUID
        let ownerFileID: UUID
        let fields: DocumentFields?
        var enclosedWith: DocumentReference?
    }

    struct Page: Encodable, Sendable {
        let id = UUID()
        let physicalIndex: Int
        let documentID: UUID
        let sourcePageID: UUID
        let role: String
    }

    struct SourcePage: Sendable {
        let id = UUID()
        let roles: [String]
    }

    let schema = CatalogueRecord.schema
    let fileID: UUID
    let contentRevision: UUID
    let revision = UUID()
    let parents: [UUID] = []
    let pages: [Page]
    let documents: [Document]
    let fileFields: FileFields
    let preservationManifestSHA256: Data?

    init(identity: CataloguePDFIdentity, sourcePages: [SourcePage], document: Document, fileFields: FileFields,
         preservationManifestSHA256: Data? = nil) {
        fileID = identity.fileID
        contentRevision = identity.contentRevision
        pages = sourcePages.flatMap { source in source.roles.map { (source.id, $0) } }.enumerated().map { index, page in
            Page(physicalIndex: index, documentID: document.id, sourcePageID: page.0, role: page.1)
        }
        documents = [document]
        self.fileFields = fileFields
        self.preservationManifestSHA256 = preservationManifestSHA256
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let record = try CatalogueRecord(json: encoder.encode(self))
        return record.originalJSON
    }

    static func fileFields(tags: GeneratedTags, quality: String?, unread: Bool, failed: Bool) -> FileFields {
        let rating = quality.flatMap { Int($0.dropFirst()) }
        return FileFields(
            readState: unread ? Field("unread", origin: "model") : nil,
            colour: tags.colorTag.map { Field($0.lowercased(), origin: "user") },
            quality: rating.map { Field($0 == 0 ? nil : $0, origin: "user") }
                ?? (tags.quality > 0 ? Field(tags.quality, origin: "user") : nil),
            ocrFailed: failed ? Field(true, origin: "model") : nil
        )
    }

    static func documentFields(tags: GeneratedTags, type: ItemType?, dateIsUserSet: Bool, subjectsAreUserSet: Bool,
                               dating: DateRoute.Decision?, itemFields: ItemFieldResult?, entities: EntityResult?) -> DocumentFields {
        var fields = DocumentFields()
        if let date = tags.machineDate.flatMap(ArchiveDate.parse(wireValue:)) {
            let decisionDate = dating.flatMap { d in
                d.decade.flatMap(ArchiveDate.init(decade:))
                    ?? d.year.flatMap { ArchiveDate(year: $0, month: d.month, day: d.day) }
            }
            let evidence = dating.map { reading in
                [Evidence(source: reading.evidenceClass.rawValue,
                          route: reading.route.isEmpty ? nil : reading.route,
                          measurementStatus: reading.measured ? "measured" : nil, quote: reading.quote,
                          observedValue: decisionDate.map { CatalogueRecord.DateValue(date: $0, uncertain: reading.dateUncertain) })]
            }
            fields.documentDate = Field(.init(date: date, uncertain: tags.dateUncertain),
                                        origin: dateIsUserSet ? "user" : "model", evidence: evidence)
        }
        if let date = tags.sentWith {
            fields.sentWith = Field(.init(date: date, uncertain: tags.sentWithUncertain), origin: "model")
        }
        fields.itemType = type.map { Field($0.rawValue, origin: "user") }
        fields.subjects = nonempty(tags.subjectTags).map { Field($0, origin: subjectsAreUserSet ? "user" : "model") }

        func item<Value>(_ key: ItemFieldPolicy.Field, _ value: Value?) -> Field<Value>? {
            guard let value, let result = itemFields else { return nil }
            return Field(value, origin: "model",
                         evidence: [Evidence(source: "item-fields", route: result.route, quote: result.filled?.quotes[key.rawValue])])
        }
        let filled = itemFields?.filled
        fields.documentKind = item(.kind, filled?.kind) ?? tags.format.map { Field($0, origin: "model") }
        fields.title = item(.title, filled?.title)
        fields.byline = item(.byline, nonempty(filled?.byline ?? []))
        fields.publication = item(.publication, filled?.publication) ?? tags.publicationName.map { Field($0, origin: "model") }
        if let date = filled?.publicationDate.flatMap(ArchiveDate.parse(wireValue:)) {
            fields.publicationDate = item(.publicationDate, CatalogueRecord.DateValue(date: date, uncertain: false))
        }
        fields.recipientPlaces = item(.recipientPlace, nonempty(filled?.recipientPlace ?? []))
            ?? names([], fallback: tags.recipientLocation, route: nil)
        if let entities, case .extracted(let read) = entities.outcome, read.mentions == nil {
            fields.senders = entities.decision.senderWithheld == nil
                ? names(read.senders, fallback: tags.authorName, route: entities.decision.route) : nil
            fields.recipients = names(read.recipients, fallback: tags.recipientName, route: entities.decision.route)
            fields.sendingPlaces = names(read.sendingPlaces, fallback: tags.authorLocation, route: entities.decision.route)
        } else {
            fields.senders = names([], fallback: tags.authorName, route: nil)
            fields.recipients = names([], fallback: tags.recipientName, route: nil)
            fields.sendingPlaces = names([], fallback: tags.authorLocation, route: nil)
        }
        return fields
    }

    /// Copy Source Tags explicitly carries established tags onto the derivative. Interpret the
    /// same facets as Reader so its catalogue view agrees with the optional Finder projection.
    static func applySourceTags(_ tags: DocumentTags, document: inout DocumentFields, file: inout FileFields) {
        let date = tags.decade.flatMap(ArchiveDate.init(decade:))
            ?? tags.year.flatMap { ArchiveDate(year: $0, month: tags.month?.number, day: tags.day) }
        document.documentDate = date.map { Field(.init(date: $0, uncertain: tags.dateUncertain), origin: "import") }
        document.sentWith = tags.sentWith.map { Field(.init(date: $0, uncertain: tags.sentWithUncertain), origin: "import") }
        document.subjects = nonempty(tags.subjects).map { Field($0, origin: "import") }
        if let type = tags.itemType {
            document.itemType = Field(type.rawValue, origin: "import")
        }
        file.readState = tags.readState.map { Field($0.rawValue.lowercased(), origin: "import") }
        file.quality = tags.quality.map { Field($0, origin: "import") }
        file.ocrPoor = tags.hasPoorOCR ? Field(true, origin: "import") : nil
    }

    private static func names(_ read: [EntityExtractor.Name], fallback: String?, route: String?) -> Field<[String]>? {
        guard !read.isEmpty else { return fallback.map { Field([$0], origin: "model") } }
        let evidence: [Evidence<[String]>] = read.map { name in
            let source = switch name.evidence {
            case .quoted: "entity-quote"
            case .inferred: "entity-inference"
            }
            return Evidence(source: source, route: route, measurementStatus: name.confidence,
                            quote: name.quote, observedValue: [name.name])
        }
        return Field(read.map(\.name), origin: "model", evidence: evidence)
    }

    private static func nonempty<T>(_ array: [T]) -> [T]? { array.isEmpty ? nil : array }
}
