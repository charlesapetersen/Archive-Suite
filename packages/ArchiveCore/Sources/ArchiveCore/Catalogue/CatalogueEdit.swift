import Foundation

/// A batch of user edits to one verified companion. Document fields target their owning record.
public struct CatalogueEdit: Sendable {
    public enum FileField: String, Sendable { case readState, flagged, colour, quality, ocrPoor }
    public enum DocumentField: String, Sendable {
        case documentDate, sentWith, publicationDate, documentKind, itemType, title, byline, publication
        case senders, recipients, sendingPlaces, recipientPlaces, subjects
    }

    public enum Target: Hashable, Sendable {
        case file(FileField)
        case document(UUID, DocumentField)

        fileprivate var location: (document: UUID?, key: String) {
            switch self {
            case .file(let field): (nil, field.rawValue)
            case .document(let id, let field): (id, field.rawValue)
            }
        }
    }

    public enum Value: Equatable, Sendable {
        case text(String)
        case names([String])
        case flag(Bool)
        case rating(Int)
        case date(CatalogueRecord.DateValue)
    }

    public enum Change: Sendable {
        case set(Value)
        case clear
        case check(Bool)
    }

    public enum Invalid: Error, Equatable {
        case repeatedTarget(Target)
        case unavailableTarget(Target)
        case incompatibleValue(Target)
        case unsupportedFieldData(Target)
        case unassessedField(Target)
    }

    public let target: Target
    public let change: Change

    public init(_ target: Target, _ change: Change) {
        self.target = target
        self.change = change
    }
}

struct CatalogueEditPatch {
    let edits: [CatalogueEdit]

    func applying(to record: CatalogueRecord) throws -> CatalogueRecord {
        var contents = try Fields(record)
        var changed = false
        var seen: Set<CatalogueEdit.Target> = []
        for edit in edits {
            guard seen.insert(edit.target).inserted else { throw CatalogueEdit.Invalid.repeatedTarget(edit.target) }
            let prior = try contents.value(at: edit.target)
            let replacement = try edit.apply(prior)
            if prior != replacement {
                try contents.set(replacement, at: edit.target)
                changed = true
            }
        }
        return changed ? try contents.record(parent: record.revision) : record
    }

    func conflicts(base: CatalogueRecord, current: CatalogueRecord) throws -> [CatalogueEdit.Target] {
        let before = try Fields(base)
        let now = try Fields(current)
        return try edits.compactMap { edit in
            let prior = try before.value(at: edit.target)
            // Ownership lost since the user opened the edit is itself a conflict.
            do {
                return try prior == now.value(at: edit.target) ? nil : edit.target
            } catch CatalogueEdit.Invalid.unavailableTarget {
                return edit.target
            }
        }
    }

    private struct Fields {
        private var root: CatalogueJSON.Object
        private var documents: [Data]
        private let ownerIndices: [UUID: Int]
        private var fileFields: CatalogueJSON.Object?
        private var changedDocuments: [UUID: CatalogueJSON.Object] = [:]

        init(_ record: CatalogueRecord) throws {
            root = try CatalogueJSON.Object(record.originalJSON)
            guard let rawDocuments = root["documents"] else { throw CatalogueRecord.Invalid.inconsistentRecord }
            documents = try CatalogueJSON.entries(in: rawDocuments)
            ownerIndices = Dictionary(uniqueKeysWithValues: record.documents.enumerated().compactMap { index, document in
                document.ownerFileID == record.fileID ? (document.id, index) : nil
            })
        }

        func value(at target: CatalogueEdit.Target) throws -> Data? {
            let value = try fields(at: target)[target.location.key]
            return value == Data("null".utf8) ? nil : value
        }

        mutating func set(_ value: Data?, at target: CatalogueEdit.Target) throws {
            var fields = try fields(at: target)
            let (document, key) = target.location
            fields[key] = value
            if let document {
                changedDocuments[document] = fields
            } else {
                fileFields = fields
            }
        }

        private func fields(at target: CatalogueEdit.Target) throws -> CatalogueJSON.Object {
            guard let id = target.location.document else {
                if let fileFields { return fileFields }
                guard let rawFields = root["fileFields"] else { throw CatalogueRecord.Invalid.inconsistentRecord }
                return try CatalogueJSON.Object(rawFields)
            }
            if let changed = changedDocuments[id] { return changed }
            guard let index = ownerIndices[id] else { throw CatalogueEdit.Invalid.unavailableTarget(target) }
            let document = try CatalogueJSON.Object(documents[index])
            guard let rawFields = document["fields"] else { throw CatalogueRecord.Invalid.inconsistentRecord }
            return try CatalogueJSON.Object(rawFields)
        }

        mutating func record(parent: UUID) throws -> CatalogueRecord {
            if let fileFields { root["fileFields"] = try fileFields.encoded() }
            for (id, fields) in changedDocuments {
                guard let index = ownerIndices[id] else { throw CatalogueRecord.Invalid.inconsistentRecord }
                var document = try CatalogueJSON.Object(documents[index])
                document["fields"] = try fields.encoded()
                documents[index] = try document.encoded()
            }
            if !changedDocuments.isEmpty { root["documents"] = CatalogueJSON.array(documents) }
            let encoder = JSONEncoder()
            root["revision"] = try encoder.encode(UUID())
            root["parents"] = try encoder.encode([parent])
            return try CatalogueRecord(json: root.encoded())
        }
    }
}

private extension CatalogueEdit {
    func apply(_ prior: Data?) throws -> Data? {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var field = try CatalogueJSON.Object(prior ?? Data("{}".utf8))
        if let origin = field["origin"], !["user", "model", "imported"].contains(try decoder.decode(String.self, from: origin)) {
            throw Invalid.unsupportedFieldData(target)
        }
        switch change {
        case .check(let checked):
            guard let revision = field["fieldRevision"] else {
                if !checked { return prior }
                throw Invalid.unassessedField(target)
            }
            let existing = try field["checkedRevision"].flatMap { try decoder.decode(UUID?.self, from: $0) }
            let current = try decoder.decode(UUID.self, from: revision)
            if checked ? existing == current : field["checkedRevision"] == nil { return prior }
            field["checkedRevision"] = checked ? revision : nil
        case .set(let value):
            guard let encoded = try encodedValue(value, replacing: field["value"]) else {
                throw Invalid.incompatibleValue(target)
            }
            if encoded.unchanged { return prior }
            try update(&field, state: "value", value: encoded.data, encoder: encoder)
        case .clear:
            if try field["state"].map({ try decoder.decode(String.self, from: $0) }) == "cleared" { return prior }
            if target.isDate, let value = field["value"],
               try CatalogueJSON.Object(value).keys.contains(where: { !["date", "uncertain"].contains($0) }) {
                throw Invalid.unsupportedFieldData(target)
            }
            try update(&field, state: "cleared", value: nil, encoder: encoder)
        }
        return try field.encoded()
    }

    func update(_ field: inout CatalogueJSON.Object, state: String, value: Data?, encoder: JSONEncoder) throws {
        field["state"] = try encoder.encode(state)
        field["value"] = value
        field["fieldRevision"] = try encoder.encode(UUID())
        field["origin"] = try encoder.encode("user")
        field["checkedRevision"] = nil
    }

    func encodedValue(_ value: Value, replacing prior: Data?) throws -> (data: Data, unchanged: Bool)? {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        func encode<T: Codable & Equatable>(_ value: T) throws -> (Data, Bool) {
            (try encoder.encode(value), try prior.map { try decoder.decode(T.self, from: $0) } == value)
        }
        func encodeText(_ value: String) throws -> (Data, Bool) {
            let old = try prior.map { try decoder.decode(String.self, from: $0) }
            return (try encoder.encode(value), old?.utf8.elementsEqual(value.utf8) == true)
        }
        func encodeNames(_ value: [String]) throws -> (Data, Bool) {
            let old = try prior.map { try decoder.decode([String].self, from: $0) }
            let unchanged = old?.count == value.count && zip(old ?? [], value).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
            return (try encoder.encode(value), unchanged)
        }
        switch (target, value) {
        case (.file(.readState), .text(let value)) where ["read", "unread"].contains(value): return try encodeText(value)
        case (.file(.colour), .text(let value)) where ["gray", "green", "purple", "blue", "yellow", "red", "orange"].contains(value):
            return try encodeText(value)
        case (.file(.flagged), .flag(let value)), (.file(.ocrPoor), .flag(let value)): return try encode(value)
        case (.file(.quality), .rating(let value)) where (1...3).contains(value): return try encode(value)
        case (.document(_, .itemType), .text(let value)) where ["box", "folder"].contains(value): return try encodeText(value)
        case (.document(_, .documentKind), .text(let value)), (.document(_, .title), .text(let value)),
             (.document(_, .publication), .text(let value)): return try encodeText(value)
        case (.document(_, .byline), .names(let value)), (.document(_, .senders), .names(let value)),
             (.document(_, .recipients), .names(let value)), (.document(_, .sendingPlaces), .names(let value)),
             (.document(_, .recipientPlaces), .names(let value)), (.document(_, .subjects), .names(let value)):
            return try encodeNames(value)
        case (_, .date(let value)) where target.isDate:
            let old = try prior.map { try decoder.decode(CatalogueRecord.DateValue.self, from: $0) }
            var object = try CatalogueJSON.Object(prior ?? Data("{}".utf8))
            object["date"] = try encoder.encode(value.date)
            object["uncertain"] = try encoder.encode(value.uncertain)
            return (try object.encoded(), value == old)
        default: return nil
        }
    }
}

private extension CatalogueEdit.Target {
    var isDate: Bool {
        switch self {
        case .document(_, .documentDate), .document(_, .sentWith), .document(_, .publicationDate): true
        default: false
        }
    }
}
