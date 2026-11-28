import Foundation

/// The per-PDF catalogue defined in SPEC/catalogue.md. Decode validates the entire record before
/// exposing fields. Its original bytes are the lossless representation for an unchanged export.
public struct CatalogueRecord: Sendable {
    public static let schema = 1
    public static let maximumBytes = 16 * 1024 * 1024

    public enum Invalid: Error, Equatable {
        case malformedJSON
        case inputLimit
        case unsupportedSchema(Int)
        case inconsistentRecord
    }

    public struct DateValue: Codable, Sendable, Equatable {
        public let date: ArchiveDate
        public let uncertain: Bool

        public init(date: ArchiveDate, uncertain: Bool) {
            self.date = date
            self.uncertain = uncertain
        }
    }

    public struct Evidence<Value: Decodable & Sendable>: Decodable, Sendable {
        public let source: String
        public let route: String?
        public let measurementStatus: String?
        public let runID: UUID?
        public let supportsRevision: UUID?
        public let pageID: UUID?
        /// Normalized coordinates in source-page orientation, measured from the top left.
        public let region: Region?
        public let quote: String?
        /// A proposed or historical reading. Effective values come from Field.current.
        public let observedValue: Value?
    }

    public struct Region: Decodable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Keys.self)
            x = try values.decode(Double.self, forKey: .x)
            y = try values.decode(Double.self, forKey: .y)
            width = try values.decode(Double.self, forKey: .width)
            height = try values.decode(Double.self, forKey: .height)
            guard x >= 0, y >= 0, width > 0, height > 0, x + width <= 1, y + height <= 1 else {
                throw Invalid.inconsistentRecord
            }
        }

        private enum Keys: String, CodingKey { case x, y, width, height }
    }

    public struct Field<Value: Decodable & Sendable>: Decodable, Sendable {
        public enum Current: Sendable {
            case value(Value)
            case cleared
        }

        public let current: Current
        public let fieldRevision: UUID
        /// An extensible source code. An unknown origin confers no privileges.
        public let origin: String
        public let checkedRevision: UUID?
        public let evidence: [Evidence<Value>]
        public var isChecked: Bool { checkedRevision == fieldRevision }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Keys.self)
            switch try values.decode(State.self, forKey: .state) {
            case .value:
                current = .value(try values.decode(Value.self, forKey: .value))
            case .cleared:
                guard !values.contains(.value) else { throw Invalid.inconsistentRecord }
                current = .cleared
            }
            fieldRevision = try values.decode(UUID.self, forKey: .fieldRevision)
            origin = try values.decode(String.self, forKey: .origin)
            checkedRevision = try values.decodeIfPresent(UUID.self, forKey: .checkedRevision)
            evidence = try values.decodeIfPresent([Evidence<Value>].self, forKey: .evidence) ?? []
        }

        private enum Keys: String, CodingKey { case state, value, fieldRevision, origin, checkedRevision, evidence }
        private enum State: String, Decodable { case value, cleared }
    }

    public struct FileFields: Decodable, Sendable {
        public let readState: Field<String>?
        public let flagged: Field<Bool>?
        public let colour: Field<String>?
        public let quality: Field<Int>?
        public let ocrPoor: Field<Bool>?
        public let ocrFailed: Field<Bool>?
    }

    public struct DocumentFields: Decodable, Sendable {
        public let documentDate: Field<DateValue>?
        public let sentWith: Field<DateValue>?
        public let publicationDate: Field<DateValue>?
        public let documentKind: Field<String>?
        public let itemType: Field<String>?
        public let title: Field<String>?
        public let byline: Field<[String]>?
        public let publication: Field<String>?
        public let senders: Field<[String]>?
        public let recipients: Field<[String]>?
        public let sendingPlaces: Field<[String]>?
        public let recipientPlaces: Field<[String]>?
        public let subjects: Field<[String]>?
    }

    public struct DocumentReference: Decodable, Sendable, Hashable {
        public let documentID: UUID
        public let ownerFileID: UUID
    }

    public struct Document: Decodable, Sendable {
        public let id: UUID
        public let ownerFileID: UUID
        /// An owned document has a fields object, even if empty. Other members carry only the reference.
        public let fields: DocumentFields?
        public let enclosedWith: DocumentReference?
    }

    public struct Page: Decodable, Sendable {
        /// Page roles that accept a viewer rotation (`SPEC/catalogue.md`, S-066).
        public static let rotatableRoles: Set<String> = ["image", "text", "searchable", "page"]

        public let id: UUID
        public let physicalIndex: Int
        public let documentID: UUID
        /// Image and transcription pages in a pair can share one source-page ID.
        public let sourcePageID: UUID?
        public let role: String
        public let viewRotation: Int?
    }

    private struct Header: Decodable { let schema: Int }

    private struct Payload: Decodable, Sendable {
        let fileID: UUID
        let contentRevision: UUID
        let revision: UUID
        let parents: [UUID]
        let pages: [Page]
        let documents: [Document]
        let fileFields: FileFields
        let preservationManifestSHA256: Data?
    }

    private let payload: Payload
    private let documentsByID: [UUID: Document]
    public let originalJSON: Data
    public var fileID: UUID { payload.fileID }
    public var contentRevision: UUID { payload.contentRevision }
    public var revision: UUID { payload.revision }
    public var parents: [UUID] { payload.parents }
    public var pages: [Page] { payload.pages }
    public var documents: [Document] { payload.documents }
    public var fileFields: FileFields { payload.fileFields }
    public var preservationManifestSHA256: Data? { payload.preservationManifestSHA256 }

    public static let companionSuffix = ".archivesuite.json"

    public static func companionFilename(forPDFFilename filename: String) -> String {
        filename + companionSuffix
    }

    /// Whether a file's name is a catalogue companion's (`<PDF filename>.archivesuite.json`).
    public static func isCompanionFilename(_ filename: String) -> Bool {
        filename.count > companionSuffix.count && filename.hasSuffix(companionSuffix)
    }

    public func document(id: UUID) -> Document? { documentsByID[id] }

    public init(json: Data) throws {
        try CatalogueJSON.check(json, maximumBytes: Self.maximumBytes)
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: json)
        guard header.schema == Self.schema else { throw Invalid.unsupportedSchema(header.schema) }
        let payload = try decoder.decode(Payload.self, from: json)

        var documentsByID: [UUID: Document] = [:]
        for document in payload.documents {
            let owned = document.ownerFileID == payload.fileID
            guard documentsByID.updateValue(document, forKey: document.id) == nil,
                  owned == (document.fields != nil), owned || document.enclosedWith == nil,
                  document.enclosedWith?.documentID != document.id else { throw Invalid.inconsistentRecord }
        }
        let pageCount = payload.pages.count
        guard pageCount > 0, payload.preservationManifestSHA256.map({ $0.count == 32 }) ?? true,
              Set(payload.pages.map(\.id)).count == pageCount,
              Set(payload.pages.map(\.physicalIndex)).count == pageCount,
              Set(payload.pages.map(\.documentID)) == Set(documentsByID.keys),
              !payload.parents.contains(payload.revision),
              Set(payload.parents).count == payload.parents.count else { throw Invalid.inconsistentRecord }
        for page in payload.pages {
            guard (0..<pageCount).contains(page.physicalIndex),
                  [0, 90, 180, 270].contains(page.viewRotation ?? 0) else { throw Invalid.inconsistentRecord }
        }
        if let quality = payload.fileFields.quality {
            if case .value(let rating) = quality.current, !(1...3).contains(rating) {
                throw Invalid.inconsistentRecord
            }
            guard quality.evidence.compactMap(\.observedValue).allSatisfy((1...3).contains) else {
                throw Invalid.inconsistentRecord
            }
        }
        self.payload = payload
        self.documentsByID = documentsByID
        originalJSON = json
    }
}
