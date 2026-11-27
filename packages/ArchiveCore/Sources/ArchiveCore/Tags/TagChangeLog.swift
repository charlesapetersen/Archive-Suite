import Foundation

// MARK: - The suite's tag change log (W40.tag-rename-suite, Tier-2; SPEC/tag-format.md invariant 8)
//
// A rename or merge made in one app reaches the others as a record, never through another app's writer:
// `<archive root>/.archivesuite/tag-changes.json`, one entry per tag changed. Every other app reads it and, only
// after the user confirms, applies an entry to its own items with its own writer. Written through
// `ContainerFileStore` (the `.archivesuite` descriptor, `flock`, the stamp check, links and newer documents
// refused), so this adds no new way to write in the archive. Each app keeps the ids it has handled in its own
// settings (`TagChangeHandled`). Design: execution-plans/tag-rename-suite.md.

/// One tag changed by one app: every item that carried `from` (by `tagKey`) now carries `to`.
public struct TagChange: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let at: Date
    /// The app that made the change: `reader`, `notes` or `processor` (an unknown name is kept and shown as is).
    public let app: String
    public let from: String
    public let to: String
    /// The recording app undid it; Redo clears it. An app that has not applied it yet no longer offers it.
    public var withdrawn: Bool

    public init(id: UUID = UUID(), at: Date = Date(), app: String, from: String, to: String, withdrawn: Bool = false) {
        self.id = id
        self.at = at
        self.app = app
        self.from = from
        self.to = to
        self.withdrawn = withdrawn
    }

    /// A case-only change: the same tag, spelled anew.
    public var isRespelling: Bool { tagKey(from) == tagKey(to) }

    /// The app's name as the user sees it.
    public var appName: String {
        switch app {
        case TagChangeLog.reader: "the Reader"
        case TagChangeLog.notes: "Notes"
        case TagChangeLog.processor: "the Processor"
        default: app
        }
    }
}

/// The document on disk. A new field needs a `schemaVersion` bump: this build's writer drops what it does not read.
public struct TagChangeDocument: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    public var changes: [TagChange]

    public init(changes: [TagChange] = []) {
        schemaVersion = Self.schemaVersion
        self.changes = changes
    }
}

public enum TagChangeLog {
    public static let fileName = "tag-changes.json"
    /// The newest entries kept; older ones are dropped when one is added.
    public static let maxEntries = 2_000
    public static let reader = "reader", notes = "notes", processor = "processor"
    /// Times a writer re-reads and tries again, after a short random wait, when another writer changed the document
    /// in between.
    static let attempts = 20

    public static func url(in root: URL) -> URL {
        root.appendingPathComponent(ContainerFile.folderName, isDirectory: true).appendingPathComponent(fileName)
    }

    /// The log at `root`. `.missing` when no app has recorded a change there.
    public static func load(root: URL) -> ContainerLoad<TagChangeDocument> {
        ContainerFileStore.load(root.resolvingSymlinksInPath(), fileName, version: TagChangeDocument.schemaVersion)
    }

    /// Whether a change from `from` to `to` may be recorded or applied: two subjects, neither a facet token the
    /// suite writes itself (a rating, a date facet, a colour name, the item type), and not the same spelling.
    public static func isRecordable(from: String, to: String) -> Bool {
        let f = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = to.trimmingCharacters(in: .whitespacesAndNewlines)
        return !f.isEmpty && !t.isEmpty && f != t && !keepsExactCase(f) && !keepsExactCase(t)
    }

    /// Appends `changes` (those `isRecordable` allows) to the log at `root`, keeping the newest `maxEntries`.
    /// Re-reads and tries again when another writer got in between. Throws `ContainerWriteError`; the caller has
    /// already changed its own items and only reports that the other apps were not told. Call it off the main thread.
    public static func record(_ changes: [TagChange], root: URL) throws {
        let kept = changes.filter { isRecordable(from: $0.from, to: $0.to) }
        guard !kept.isEmpty else { return }
        try update(root: root) { doc in
            let known = Set(doc.changes.map(\.id))
            doc.changes.append(contentsOf: kept.filter { !known.contains($0.id) })
            if doc.changes.count > maxEntries { doc.changes.removeFirst(doc.changes.count - maxEntries) }
            return true
        }
    }

    /// Marks the entries `ids` withdrawn (an Undo in the app that recorded them) or not (its Redo). Entries no longer
    /// in the log are ignored, and a log with none of them is not rewritten.
    public static func setWithdrawn(_ ids: Set<UUID>, _ withdrawn: Bool, root: URL) throws {
        guard !ids.isEmpty else { return }
        try update(root: root, creating: false) { doc in
            var changed = false
            for i in doc.changes.indices where ids.contains(doc.changes[i].id) && doc.changes[i].withdrawn != withdrawn {
                doc.changes[i].withdrawn = withdrawn
                changed = true
            }
            return changed
        }
    }

    /// What an app has to do with the log when it opens: the entries to offer (Apply or Skip), the withdrawals of
    /// entries it applied (told once), and the entries it settles without asking. `carried` is the `tagKey` of
    /// every subject on its items. Entries are taken oldest first against that set as each offer would change it,
    /// so `A`→`B` then `B`→`C` offers both. Settled without asking: an entry it can never apply (a facet token, and a
    /// re-spelling when `ignoresRespelling`: Notes title-cases every subject anyway). Passed over without settling: a
    /// withdrawn entry it never applied (a Redo may restore it) and one no item carries now.
    public static func inbox(_ doc: TagChangeDocument, app: String, handled: Set<UUID>, applied: Set<UUID>,
                             carried: Set<String>, ignoresRespelling: Bool = false) -> TagChangeInbox {
        var box = TagChangeInbox()
        var keys = carried
        for change in doc.changes where change.app != app {
            if change.withdrawn, applied.contains(change.id) {
                box.withdrawals.append(change)
                continue
            }
            guard !handled.contains(change.id) else { continue }
            // Settled for good only when it can never apply here. A withdrawn entry may be redone, and a tag nothing
            // carries now may be carried later (or the library was not loaded yet), so those are only passed over.
            guard isRecordable(from: change.from, to: change.to), !(ignoresRespelling && change.isRespelling) else {
                box.settled.append(change.id)
                continue
            }
            guard !change.withdrawn, keys.contains(tagKey(change.from)) else { continue }
            box.offers.append(change)
            if !change.isRespelling { keys.remove(tagKey(change.from)) }
            keys.insert(tagKey(change.to))
        }
        return box
    }

    // MARK: Following without asking (the Processor, which has vocabularies and no items)

    /// The archive a folder belongs to: the nearest folder at or above `directory` holding a Reader root marker,
    /// where the log lives. Nil when there is none below the volume's top.
    public static func archiveRoot(containing directory: URL) -> (guid: UUID, url: URL)? {
        var folder = directory.resolvingSymlinksInPath().standardizedFileURL
        for _ in 0..<64 {
            if let marker = try? RootMarker.read(at: folder), marker.kind == .reader { return (marker.guid, folder) }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path || parent.pathComponents.count < 2 { return nil }
            folder = parent
        }
        return nil
    }

    /// `list` (a subject list such as the Processor's controlled vocabulary) with every entry keyed as `from`
    /// replaced by `to` where the first one stood, or `to`'s existing entry kept when the list already holds it.
    public static func renamed(_ list: [String], from: String, to: String) -> [String] {
        func key(_ s: String) -> String { tagKey(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let (fromKey, toKey) = (key(from), key(to))
        guard list.contains(where: { key($0) == fromKey }) else { return list }
        let hasTarget = fromKey != toKey && list.contains { key($0) == toKey }
        var out: [String] = []
        var placed = false
        for entry in list {
            if key(entry) == fromKey {
                if !placed, !hasTarget { out.append(to) }
                placed = true
            } else {
                out.append(entry)
            }
        }
        return out
    }

    /// Applies every unhandled entry of other apps in `doc` to `vocabulary` and `controlled`, oldest first, with no
    /// question: a vocabulary is a list of spellings, not of anyone's items. A withdrawal of an entry applied before
    /// puts `from` back in both (`to` stays: it may be in use by then). Returns the new controlled list, the ids to add
    /// to the handled and applied lists, and the withdrawals put back, which the caller removes from both lists so a
    /// later Redo applies again.
    public static func follow(_ doc: TagChangeDocument, app: String, handled: Set<UUID>, applied: Set<UUID>,
                              vocabulary: TagVocabulary, controlled: [String]) -> TagChangeFollow {
        var result = TagChangeFollow(controlled: controlled)
        for change in doc.changes where change.app != app && isRecordable(from: change.from, to: change.to) {
            if change.withdrawn {
                guard applied.contains(change.id) else { continue }   // never applied: nothing to put back
                vocabulary.add(rawTags: [change.from])
                let fromKey = tagKey(change.from)
                if !result.controlled.isEmpty, !result.controlled.contains(where: { tagKey($0) == fromKey }) {
                    result.controlled.append(change.from)
                }
                result.unapplied.append(change.id)
                continue
            }
            guard !handled.contains(change.id) else { continue }
            vocabulary.rename(from: change.from, to: change.to)
            result.controlled = renamed(result.controlled, from: change.from, to: change.to)
            result.handled.append(change.id)
            result.applied.append(change.id)
        }
        return result
    }

    /// Read, change and write back under the lock, again from a fresh read when another writer got in between.
    /// `edit` returns whether it changed anything; nothing is written when it did not. `creating: false` leaves a
    /// missing log missing.
    private static func update(root: URL, creating: Bool = true,
                               _ edit: (inout TagChangeDocument) -> Bool) throws {
        let dir = root.resolvingSymlinksInPath()
        for attempt in 1...attempts {
            var doc: TagChangeDocument
            let stamp: ContainerFileStamp?
            switch load(root: dir) {
            case .missing:
                guard creating else { return }
                doc = TagChangeDocument()
                stamp = nil
            case .loaded(let d, let s):
                doc = d
                stamp = s
            case .newer:
                throw ContainerWriteError.refusedExisting("of a newer schemaVersion")
            case .unreadable(let why):
                throw ContainerWriteError.refusedExisting(why)
            }
            guard edit(&doc) else { return }
            do {
                try ContainerFileStore.write(doc, in: dir, name: fileName, version: TagChangeDocument.schemaVersion,
                                             expecting: stamp)
                return
            } catch ContainerWriteError.changedSinceRead where attempt < attempts {
                usleep(UInt32.random(in: 2_000...20_000))
                continue
            }
        }
    }
}

/// `TagChangeLog.follow`'s answer.
public struct TagChangeFollow: Equatable, Sendable {
    public var controlled: [String]
    public var handled: [UUID] = []
    public var applied: [UUID] = []
    /// Withdrawals put back: no longer applied.
    public var unapplied: [UUID] = []

    public init(controlled: [String]) { self.controlled = controlled }
}

/// `TagChangeLog.inbox`'s answer.
public struct TagChangeInbox: Equatable, Sendable {
    public var offers: [TagChange] = []
    public var withdrawals: [TagChange] = []
    public var settled: [UUID] = []

    public init() {}

    public var isEmpty: Bool { offers.isEmpty && withdrawals.isEmpty }
}

/// The ids of log entries one app has handled at one archive root (applied, skipped, dropped, or its own), kept in
/// that app's own settings under the root marker's guid, so a moved archive keeps its list. `applied` is the
/// subset it applied, so a later withdrawal of one of them is told to the user once (`TagChangeHandled.applied`).
public struct TagChangeHandled: Sendable {
    /// More than the log keeps, so an id is never forgotten while its entry is still in the log.
    public static let limit = 2 * TagChangeLog.maxEntries
    private let key: String
    private let suiteName: String?

    /// `suiteName` nil is the app's standard defaults; tests pass their own.
    public init(rootGUID: String, suiteName: String? = nil) {
        self.init(key: "tagChangesHandled." + rootGUID, suiteName: suiteName)
    }

    private init(key: String, suiteName: String?) {
        self.key = key
        self.suiteName = suiteName
    }

    /// The entries this app applied at the root: a withdrawal of one is shown once, then it is removed from here.
    public static func applied(rootGUID: String, suiteName: String? = nil) -> TagChangeHandled {
        TagChangeHandled(key: "tagChangesApplied." + rootGUID, suiteName: suiteName)
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public var ids: Set<UUID> {
        Set((defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
    }

    /// Adds `ids`, newest last, dropping the oldest past `limit`.
    public func insert<S: Sequence>(_ new: S) where S.Element == UUID {
        var list = defaults.stringArray(forKey: key) ?? []
        let have = Set(list)
        for id in new where !have.contains(id.uuidString) { list.append(id.uuidString) }
        if list.count > Self.limit { list.removeFirst(list.count - Self.limit) }
        defaults.set(list, forKey: key)
    }

    public func remove<S: Sequence>(_ gone: S) where S.Element == UUID {
        let drop = Set(gone.map(\.uuidString))
        guard !drop.isEmpty else { return }
        defaults.set((defaults.stringArray(forKey: key) ?? []).filter { !drop.contains($0) }, forKey: key)
    }
}
