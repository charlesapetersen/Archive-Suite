import Foundation

// MARK: - How a container's values are shown (W47.ct-normalise; `SPEC/containers.md` §Showing a value)
//
// The record keeps each value as written on the label or in the folder name. What a user sees is that value under
// their standard name for it, if they set one, and otherwise in title case (`TitleCase`, the suite's one rule). The
// standard names are stored per tree, beside the level map (`<root>/.archivesuite/container-names.json`), so the
// Processor, the Reader and a second Mac show the same names.

/// One standard name: the wordings a user has seen for a repository, a collection or any other field, and what to
/// show for them. `fields` normally holds only `field`; it may also say which parts of the label go into which field
/// (a repository read that also names the place), or leave `field` out to show nothing there (a collection title that
/// was really the repository).
public struct ContainerStandardName: Equatable, Sendable {
    /// The field whose value is matched.
    public var field: ContainerField
    /// The wordings as written, matched by `ContainerNames.key`. The shown value of `field` matches too.
    public var variants: [String]
    /// What to show, per field.
    public var fields: [ContainerField: String]

    public init(field: ContainerField, variants: [String], fields: [ContainerField: String]) {
        self.field = field
        self.variants = variants
        self.fields = fields
    }

    /// The usual case: `variants` are shown as `standard`.
    public init(field: ContainerField, standard: String, variants: [String]) {
        self.init(field: field, variants: variants, fields: [field: standard])
    }

    /// What to show for `f`, nil for none.
    public func shown(_ f: ContainerField) -> String? {
        guard let t = fields[f]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// The keys this entry matches.
    var keys: Set<String> {
        Set((variants + [fields[field]].compactMap { $0 }).map(ContainerNames.key).filter { !$0.isEmpty })
    }
}

/// The user's standard names for one tree.
public struct ContainerNames: Equatable, Sendable {
    public static let fileName = "container-names.json"
    public static let schemaVersion = 1

    /// Newest first (`set`); the first that matches wins.
    public private(set) var names: [ContainerStandardName]
    public var updatedAt: Date?

    /// `names` as given, newest first; `set` keeps a wording to one entry per field.
    public init(names: [ContainerStandardName] = [], updatedAt: Date? = nil) {
        self.names = names
        self.updatedAt = updatedAt
    }

    /// The matching key of a wording: case, accents and width folded, `&` read as "and", every run of punctuation
    /// and spaces one space. "Special Collections, Example Library" and "SPECIAL COLLECTIONS EXAMPLE LIBRARY" match.
    public static func key(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
        return folded.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).joined(separator: " ")
    }

    /// The entry for `written` in `field`, if any.
    public func entry(for field: ContainerField, matching written: String) -> ContainerStandardName? {
        index(for: field, matching: written).map { names[$0] }
    }

    func index(for field: ContainerField, matching written: String) -> Int? {
        let k = ContainerNames.key(written)
        guard !k.isEmpty else { return nil }
        return names.firstIndex { $0.field == field && $0.keys.contains(k) }
    }

    /// Adds `name`. A wording belongs to one entry per field, so its variants leave any other entry of that field, and
    /// an entry left with nothing to match is dropped. Empty and repeated variants are left out.
    public mutating func set(_ name: ContainerStandardName) {
        var name = name
        var seen = Set<String>()
        name.variants = name.variants.filter { let k = ContainerNames.key($0); return !k.isEmpty && seen.insert(k).inserted }
        let taken = name.keys
        names = names.compactMap { other in
            guard other.field == name.field else { return other }
            var other = other
            other.variants.removeAll { taken.contains(ContainerNames.key($0)) }
            return other.keys.subtracting(taken).isEmpty ? nil : other
        }
        guard !taken.isEmpty else { return }
        // First, so it wins where an older entry's own standard name is one of its wordings.
        names.insert(name, at: 0)
    }

    /// Removes the entry for `written` in `field`.
    public mutating func remove(field: ContainerField, matching written: String) {
        if let i = index(for: field, matching: written) { names.remove(at: i) }
    }
}

// Strict, as the level map: a field or key this build does not know makes the document unreadable, so it is left alone
// rather than read wrongly or overwritten.
extension ContainerStandardName: Codable {
    private enum CodingKeys: String, CodingKey { case field, variants, fields }

    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(["field", "variants", "fields"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode([String: String].self, forKey: .fields)
        var fields: [ContainerField: String] = [:]
        for (key, value) in raw {
            guard let f = ContainerField(rawValue: key) else {
                throw DecodingError.dataCorruptedError(forKey: .fields, in: c, debugDescription: "unknown field \(key)")
            }
            fields[f] = value
        }
        self.init(field: try c.decode(ContainerField.self, forKey: .field),
                  variants: try c.decode([String].self, forKey: .variants), fields: fields)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(field, forKey: .field)
        try c.encode(variants, forKey: .variants)
        try c.encode(Dictionary(uniqueKeysWithValues: fields.map { ($0.key.rawValue, $0.value) }), forKey: .fields)
    }
}

extension ContainerNames: Codable {
    private enum CodingKeys: String, CodingKey { case schemaVersion, names, updatedAt }

    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(["schemaVersion", "names", "updatedAt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(names: try c.decode([ContainerStandardName].self, forKey: .names),
                  updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ContainerNames.schemaVersion, forKey: .schemaVersion)
        try c.encode(names, forKey: .names)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}

/// One field as shown.
public struct ContainerShownValue: Equatable, Sendable {
    public var text: String
    /// The value as written in the record; nil when the text was filled by another field's standard name.
    public var asWritten: String?
    /// The text is the user's standard name, not the written value in title case.
    public var byStandardName: Bool
}

public enum ContainerDisplay {
    /// A written value as shown when no standard name applies: title case if it is wholly in capitals.
    public static func shown(_ written: String, keeping: Set<String> = []) -> String {
        TitleCase.titleCased(written, keeping: keeping)
    }

    /// Every field of `record` as shown. A matched standard name gives its field's text, and fills the other fields it
    /// names where the record has no value of its own (a user's "none here" counts as one), the newest entry first.
    /// Everything else is the
    /// written value in title case. Nothing here changes the record.
    public static func values(_ record: ResolvedContainer, names: ContainerNames? = nil,
                              keeping: Set<String> = []) -> [ContainerField: ContainerShownValue] {
        var out: [ContainerField: ContainerShownValue] = [:]
        var matched: [(index: Int, field: ContainerField)] = []
        for field in ContainerField.allCases {
            guard let written = record.shown(field) else { continue }
            guard let names, let i = names.index(for: field, matching: written) else {
                out[field] = ContainerShownValue(text: shown(written, keeping: keeping), asWritten: written,
                                                 byStandardName: false)
                continue
            }
            if let text = names.names[i].shown(field) {
                out[field] = ContainerShownValue(text: text, asWritten: written, byStandardName: true)
            }
            matched.append((i, field))
        }
        // Fills from the matched entries, newest first.
        for (i, field) in matched.sorted(by: { $0.index < $1.index }) {
            for other in ContainerField.allCases where other != field && out[other] == nil && record.values[other] == nil {
                if let text = names?.names[i].shown(other) {
                    out[other] = ContainerShownValue(text: text, asWritten: nil, byStandardName: true)
                }
            }
        }
        return out
    }

    /// `ResolvedContainer.disagreements`, with two wordings under one standard name, or differing only in case,
    /// punctuation or spacing, taken as agreeing. A field whose value the user set or confirmed is settled, not a
    /// disagreement (W47.ct-reader-edit): the user chose among the candidates, and a later read that differs is its own
    /// warning (`ContainerWarning.Kind.readDisagreesWithUser`).
    public static func disagreements(_ record: ResolvedContainer, names: ContainerNames? = nil) -> [ContainerField] {
        ContainerField.allCases.filter { field in
            if record.values[field]?.source == .user { return false }
            let named = Set((record.candidates[field] ?? []).compactMap { value -> String? in
                guard let written = value.shown else { return nil }
                if let i = names?.index(for: field, matching: written) { return "#\(i)" }
                return ContainerNames.key(written)
            })
            return named.count > 1
        }
    }
}
