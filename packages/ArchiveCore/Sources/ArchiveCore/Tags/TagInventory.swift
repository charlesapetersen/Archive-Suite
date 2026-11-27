import Foundation

// MARK: - Every tag in use, and the changes the Tags window makes (W40.tag-window-core, Tier-2)
//
// The model behind the shared Tags window (ArchiveCoreUI `TagsWindow`). Each app builds it from its own items
// (the Reader's tagged files, Notes' notes and extracts, the Processor's vocabularies) as `(id, tags)` pairs, and
// executes a `TagChangePlan` through its own audited writer (TagWriter, Notes' front matter): the plan is a pure
// value, applied to each item's FRESHLY READ tags inside that writer, so a tag added since the inventory was built
// is never lost. Tags are one tag by `tagKey` (SPEC/tag-format.md invariant 4). Tokens the suite writes itself
// (ratings, dates, read state, item type, colour names, field checks, the OCR flags) are listed apart and no plan
// touches them (invariant 8). Design: the W40.tag-window-core entry in SUITE_TODO_DONE.md.

/// Every tag carried by a set of items, by identity.
public struct TagInventory: Sendable {
    /// One item as the app sees it: a stable id (a path, a note's UUID, a vocabulary name) and its tags verbatim.
    public struct Item: Sendable, Equatable {
        public let id: String
        public let tags: [String]

        public init(id: String, tags: [String]) {
            self.id = id
            self.tags = tags
        }
    }

    /// One tag: every spelling of it in use, and the items that carry it.
    public struct Entry: Sendable, Equatable, Identifiable {
        /// The `tagKey`.
        public let id: String
        /// The spelling most items use (a tie goes to the one that sorts first): how the window shows it.
        public let name: String
        /// Each spelling and how many items carry it, most used first.
        public let spellings: [TagSimilarity.TagVariant]
        /// The items carrying it, in the order they were given.
        public let itemIDs: [String]
        /// A token the suite writes itself: shown apart, never changed here.
        public let isSuiteToken: Bool

        public var itemCount: Int { itemIDs.count }
        /// Some item spells it another way.
        public var hasVariantSpellings: Bool { spellings.count > 1 }
    }

    public let items: [Item]
    /// Subject tags, by name (`localizedStandardCompare`).
    public let subjects: [Entry]
    /// The suite's own tokens, by name.
    public let suiteTokens: [Entry]
    private let byKey: [String: Entry]
    /// How the app spells a name it writes (Notes title-cases every subject); the Reader writes it as typed.
    private let spell: @Sendable (String) -> String

    /// `spell` is the app's rule for a name it writes, so a plan's target, count and log entries are what the app's
    /// writer will actually write.
    public init(items: [Item], spell: @escaping @Sendable (String) -> String = { $0 }) {
        self.items = items
        self.spell = spell
        var order: [String] = []
        var holders: [String: [String]] = [:]
        var spelt: [String: [String: Int]] = [:]
        for item in items {
            var seen = Set<String>()
            var seenSpelling = Set<String>()
            // Verbatim, as every app keys tags (`tagKey` does not trim): a padded token is its own tag here too.
            for tag in item.tags {
                guard !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let key = tagKey(tag)
                if holders[key] == nil { order.append(key) }
                if seen.insert(key).inserted { holders[key, default: []].append(item.id) }
                if seenSpelling.insert(tag).inserted { spelt[key, default: [:]][tag, default: 0] += 1 }
            }
        }
        var subjects: [Entry] = []
        var suite: [Entry] = []
        var byKey: [String: Entry] = [:]
        for key in order {
            let spellings = (spelt[key] ?? [:])
                .map { TagSimilarity.TagVariant(tag: $0.key, count: $0.value) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
            let name = spellings.first?.tag ?? key
            let entry = Entry(id: key, name: name, spellings: spellings, itemIDs: holders[key] ?? [],
                              isSuiteToken: spellings.contains { Self.isSuiteToken($0.tag) })
            byKey[key] = entry
            if entry.isSuiteToken { suite.append(entry) } else { subjects.append(entry) }
        }
        let byName: (Entry, Entry) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.subjects = subjects.sorted(by: byName)
        self.suiteTokens = suite.sorted(by: byName)
        self.byKey = byKey
    }

    /// The entry for a tag in any spelling, or nil when no item carries it.
    public func entry(for tag: String) -> Entry? {
        byKey[tagKey(tag)] ?? byKey[tagKey(tag.trimmingCharacters(in: .whitespacesAndNewlines))]
    }

    /// The entry with this `tagKey` (an `Entry.id`).
    public func entry(forKey key: String) -> Entry? { byKey[key] }

    /// The near-duplicate groups among the subjects (`TagSimilarity`), each a list of entries, most carried first.
    /// Two spellings of one tag are one entry already, so a group here is always two or more different tags.
    public func similarClusters() -> [[Entry]] {
        var counts: [String: Int] = [:]
        for entry in subjects { counts[entry.name] = entry.itemCount }
        return TagSimilarity.clusters(subjectCounts: counts).compactMap { cluster in
            let entries = cluster.compactMap { entry(for: $0.tag) }
            return entries.count > 1 ? entries : nil
        }
    }

    /// A tag the suite writes itself, which the window never renames, merges or removes: a rating, a date facet,
    /// a read state, an item type, a Finder colour name, a field check, `Date Uncertain`, the Sent With tokens and
    /// the OCR flags. Anything `DocumentTags.parse` claims for a facet, plus the flags it keeps as subjects.
    public static func isSuiteToken(_ tag: String) -> Bool {
        let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if keepsExactCase(t) || isReadStateWord(t) { return true }
        if isSameTag(t, DocumentTags.poorOCRTag) || isSameTag(t, Self.ocrFailedTag) { return true }
        return DocumentTags.parse(raw: [t], labelNumber: nil).subjects.isEmpty
    }

    /// The Processor's failed-OCR token (`GeneratedTags.allTags`).
    public static let ocrFailedTag = "OCR Failed"

    // MARK: Plans

    /// The spelling a typed name takes: an existing tag's spelling when one is carried (renaming into it merges
    /// into it, as the Reader's rename does), else the name as typed, trimmed, in the app's spelling.
    public func spelling(for typed: String) -> String {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return entry(for: t)?.name ?? spell(t)
    }

    /// Rename `tag` to `typed` on every item carrying it. Into another existing tag, it merges into that tag's
    /// spelling; to a different case of itself, it re-spells it everywhere. Nil when nothing would change, or when
    /// either side is one of the suite's own tokens.
    public func renamePlan(_ tag: String, to typed: String) -> TagChangePlan? {
        guard let source = entry(for: tag) else { return nil }
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = isSameTag(t, source.name) ? spell(t) : spelling(for: t)
        return plan(.rename, sources: [source], target: target)
    }

    /// Merge `tags` into one spelling, `typed` (one of them, any other existing tag, or a new name).
    public func mergePlan(_ tags: [String], into typed: String) -> TagChangePlan? {
        var sources: [Entry] = []
        for tag in tags {
            guard let e = entry(for: tag) else { continue }
            if !sources.contains(where: { $0.id == e.id }) { sources.append(e) }
        }
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // Into one of the merged tags: the spelling as typed, so choosing a variant re-spells the rest.
        let target = sources.contains(where: { isSameTag($0.name, t) }) ? spell(t) : spelling(for: t)
        return plan(sources.count > 1 ? .merge : .rename, sources: sources, target: target)
    }

    /// Remove `tags` from every item carrying any of them.
    public func removePlan(_ tags: [String]) -> TagChangePlan? {
        var sources: [Entry] = []
        for tag in tags {
            guard let e = entry(for: tag) else { continue }
            if !sources.contains(where: { $0.id == e.id }) { sources.append(e) }
        }
        return plan(.remove, sources: sources, target: nil)
    }

    private func plan(_ kind: TagChangePlan.Kind, sources: [Entry], target: String?) -> TagChangePlan? {
        guard !sources.isEmpty, sources.allSatisfy({ !$0.isSuiteToken }) else { return nil }
        if let target {
            guard !target.isEmpty, !Self.isSuiteToken(target) else { return nil }
        }
        let plan = TagChangePlan(kind: kind, sources: sources.map(\.name), sourceKeys: Set(sources.map(\.id)),
                                 target: target, itemIDs: [])
        let carrying = Set(sources.flatMap(\.itemIDs))
        let ids = items.filter { carrying.contains($0.id) && plan.applied(to: $0.tags) != nil }.map(\.id)
        guard !ids.isEmpty else { return nil }
        return TagChangePlan(kind: kind, sources: plan.sources, sourceKeys: plan.sourceKeys, target: target,
                             itemIDs: ids)
    }
}

/// One change the Tags window makes, as a pure value: which tags go, the one spelling that replaces them (none
/// for a remove), and the items that carry them now. The app's writer runs `applied(to:)` on each item's freshly
/// read tags, as one Undo step; `itemIDs` is what the window counts and confirms, not a licence to write an item
/// whose fresh tags no longer carry a source (`applied` returns nil for it).
public struct TagChangePlan: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case rename, merge, remove
    }

    public let kind: Kind
    /// The tags changed, in the spelling the window showed.
    public let sources: [String]
    /// Their `tagKey`s.
    public let sourceKeys: Set<String>
    /// The spelling they become; nil for a remove.
    public let target: String?
    /// The items carrying a source when the plan was made.
    public let itemIDs: [String]

    public var itemCount: Int { itemIDs.count }

    /// `tags` with the change made, or nil when it changes nothing. Only tokens of a source tag move, and nothing
    /// else changes place. A rename or merge puts the target where the first source token stood, once; an item that
    /// already carries the target (another tag) keeps its own token as it is. A target that is one of the sources
    /// re-spells every spelling of it.
    public func applied(to tags: [String]) -> [String]? {
        func key(_ s: String) -> String { tagKey(s) }
        // A suite token is never moved, even one that shares a key with a source (the inventory lists such a key
        // apart, so this only guards a token that appeared since it was built).
        func moves(_ s: String) -> Bool { sourceKeys.contains(key(s)) && !TagInventory.isSuiteToken(s) }
        guard tags.contains(where: moves) else { return nil }
        var out: [String] = []
        if let target {
            let targetKey = key(target)
            let keepsTarget = !sourceKeys.contains(targetKey) && tags.contains { key($0) == targetKey }
            var placed = keepsTarget
            for tag in tags {
                if moves(tag) {
                    if !placed { out.append(target) }
                    placed = true
                } else {
                    out.append(tag)
                }
            }
        } else {
            out = tags.filter { !moves($0) }
        }
        return out == tags ? nil : out
    }

    /// The entries this change adds to the suite's change log (`TagChangeLog`), one per source tag; a remove's have an
    /// empty `to` (schema 2). The writer records them only when it changed an item.
    public func logEntries(app: String, at date: Date = Date()) -> [TagChange] {
        sources.map { TagChange(at: date, app: app, from: $0, to: target ?? "") }.filter(TagChangeLog.isRecordable)
    }

    /// How the change reads in a confirmation or a status line, for an item noun ("file", "note").
    public func summary(noun: TagNoun) -> String {
        let quoted = sources.map { "“\($0)”" }
        let what = quoted.count <= 3 ? ListFormatter.localizedString(byJoining: quoted)
                                     : "\(quoted.count) tags"
        let on = noun.count(itemCount)
        switch kind {
        case .rename: return "Rename \(what) to “\(target ?? "")” on \(on)"
        case .merge: return "Merge \(what) into “\(target ?? "")” on \(on)"
        case .remove: return "Remove \(what) from \(on)"
        }
    }
}

/// What an app calls its items, for counts: "1 file", "12 notes and extracts".
public struct TagNoun: Sendable, Equatable {
    public let singular: String
    public let plural: String

    public init(_ singular: String, plural: String? = nil) {
        self.singular = singular
        self.plural = plural ?? singular + "s"
    }

    public func count(_ n: Int) -> String { "\(n) \(n == 1 ? singular : plural)" }

    public static let file = TagNoun("file")
    public static let note = TagNoun("note")
    public static let vocabularyList = TagNoun("list")
}
